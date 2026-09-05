import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MultiModalKit
import Hub
import Tokenizers

// MARK: - the model, loaded once (D-062 F-4 = A: Whisper's shape)

/// Holds the weights for the whole conversation, because loading them per
/// turn would put hundreds of milliseconds in front of every reply.
///
/// The two public questions are Whisper's, deliberately — same names,
/// same semantics, so an app that already knows one engine knows this
/// one: `modelInstalled()` never triggers work, and `ensureModel()` is
/// idempotent.
public actor LocalMindModel: ModelBacked {
    /// Nonisolated: it never changes, and a caller needs the path to say
    /// WHERE it is looking — a question that should not require awaiting
    /// an actor that may be busy loading 2 GB.
    public nonisolated let weights: URL
    /// The Hugging Face repo these weights come from, when the app wants
    /// the library to be able to FETCH them. `nil` means bring-your-own:
    /// the caller placed the files and no download will ever happen.
    public nonisolated let repoID: String?
    /// MLX's buffer-cache ceiling, process-global, settable by the app.
    public nonisolated let cacheLimitBytes: Int
    /// The loaded 2.2 GB, behind the shape that gets this right.
    ///
    /// Was a hand-written `container` + `loadBusy` + `loadWaiters` — the
    /// third copy of a trio that has been wrong five times (D-051), and
    /// wrong here in a way no test could see: one resume where all were
    /// needed, stranding every caller after the second. `Retirable` also
    /// brings the generation ticket this type never had, so a retire during
    /// a load can no longer be undone by that load finishing.
    ///
    /// `ModelContainer` is an actor, hence already `Sendable` — no box
    /// needed, unlike Whisper's vendor class.
    private let held = Retirable<ModelContainer>()
    /// ONE load at a time — enforced, not assumed.
    ///
    /// The 4h review caught this: `ensureModel()` checked `container`,
    /// then `await`ed `loadModelContainer`, and an actor does NOT hold
    /// isolation across an await. A prewarm in flight plus a first turn
    /// (or a Listen tap inside the measured 1.7 s load) both passed the
    /// nil check and each allocated a full copy — 2 × 2239 MB, and iOS
    /// kills this app near 3351 MB (INSTRUMENTS §27). The doc promise
    /// "the load half is skipped when the model is already resident" was
    /// true only for strictly sequential callers.
    ///
    /// The shape is `WhisperEngine.decode`'s, deliberately: a busy flag
    /// plus a FIFO waiter queue, re-checked in a WHILE loop after every
    /// wake — the reentrancy law — and released on every exit via defer.
    /// The warm-up, OWNED so it can be stopped.
    ///
    /// The review found the first version leaking an unstructured
    /// `Task {}` with no handle: switching the picker from 4B to 0.6B —
    /// the very act of trying to use less memory — left the 4B load
    /// running to completion beside the new one. Held here so `retire()`
    /// can cancel it, because the object that owns the weights is the
    /// only one that can honestly own the work that loads them.
    private var warmTask: Task<Void, Never>?
    private var think: ThinkTokens??      // nil = unread, .some(nil) = none declared

    /// Weights already on disk. Nothing is ever downloaded.
    public init(weights: URL, cacheLimitBytes: Int = 20 * 1024 * 1024) {
        self.weights = weights
        self.repoID = nil
        self.cacheLimitBytes = cacheLimitBytes
    }

    /// Weights this model may fetch if they are missing — Whisper's
    /// shape, which D-062 F-4 = A ruled for exactly this seam.
    ///
    /// The default directory is the app's Documents, which is where a
    /// person can also drop the folder by hand over USB.
    public init(repoID: String, in directory: URL = URL.documentsDirectory,
                cacheLimitBytes: Int = 20 * 1024 * 1024) {
        self.repoID = repoID
        self.cacheLimitBytes = cacheLimitBytes
        self.weights = directory.appending(
            path: repoID.split(separator: "/").last.map(String.init) ?? repoID)
    }

    /// Honest disk check — no load is ever triggered by asking.
    ///
    /// "Installed" means OFFLINE-CAPABLE, the lesson Whisper's own audit
    /// wrote down: the weights alone are not enough, because a tokenizer
    /// that is missing its files is a silent network fetch waiting to
    /// happen. So the tokenizer's files are part of the question.
    public nonisolated func modelInstalled() -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: weights.appending(path: "config.json").path),
              files.fileExists(atPath: weights.appending(path: "tokenizer.json").path),
              files.fileExists(atPath: weights.appending(path: "tokenizer_config.json").path)
        else { return false }
        let contents = (try? files.contentsOfDirectory(atPath: weights.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Downloads the weights, if this model knows where they come from.
    ///
    /// EXPLICIT, exactly as Whisper's rule requires: nothing here is ever
    /// reached by *asking* whether the model is installed. Idempotent —
    /// the download half is skipped when the files are already there.
    public func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard !modelInstalled() else { return }
        guard let repoID else {
            throw MLXUnavailable.weightsNotInstalled(weights.lastPathComponent)
        }
        let hub = HubApi(downloadBase: weights.deletingLastPathComponent())
        // The hub returns WHERE it put the snapshot. Use that.
        //
        // The first version of this searched the download base for any
        // `config.json` and moved the folder containing it. That was
        // dangerous rather than merely imprecise: an app's Documents
        // directory holds other models — this demo keeps Whisper's under
        // `huggingface/models/openai/…`, and those have a `config.json`
        // too. Directory enumeration has no defined order, so that code
        // could have moved somebody else's model. Never go looking for a
        // file when the API already told you the path.
        let snapshot = try await hub.snapshot(
            from: repoID,
            matching: ["*.safetensors", "*.json", "*.txt"]
        ) { downloadProgress in progress(downloadProgress.fractionCompleted) }

        guard snapshot != weights else { return }
        let files = FileManager.default
        if files.fileExists(atPath: weights.path) {
            try files.removeItem(at: weights)
        }
        try files.createDirectory(at: weights.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.moveItem(at: snapshot, to: weights)
    }

    /// `ModelBacked`'s half of the pair (D-078, fork B1).
    ///
    /// The protocol asks "put the weights on disk"; the method below also
    /// HANDS BACK the loaded container so a caller can run the model. Two
    /// different jobs, so the value-returning one stays this type's own
    /// and the conformance is this one line. Folding them together would
    /// have needed an `associatedtype`, which makes `any ModelBacked`
    /// nearly unusable for the caller the protocol exists to serve.
    public func ensureModel() async throws {
        _ = try await ensureModelLoaded()
    }

    /// Loads the weights. Idempotent; the load half is skipped when the
    /// model is already resident.
    @discardableResult
    public func ensureModelLoaded() async throws -> ModelContainer {
        guard MLXRuntime.isAvailable else { throw MLXUnavailable.platformCannotRunMLX }
        guard modelInstalled() else {
            throw MLXUnavailable.weightsNotInstalled(weights.lastPathComponent)
        }
        // The examples set this low so a buffer cache cannot push a phone
        // into jetsam. Measured note (INSTRUMENTS §25): MLX does not mmap
        // its safetensors, so the weights are RESIDENT — on a phone this
        // sits beside a live audio graph, a recogniser and a mouth.
        // POLICY, and it is the app's (D-027). This writes a
        // PROCESS-GLOBAL MLX setting, so a library choosing it decides
        // for every other MLX user in the app. The default matches the
        // vendor examples — small enough that a buffer cache cannot push
        // a phone into jetsam — and `cacheLimitBytes` lets the app
        // overrule it.
        MLX.Memory.cacheLimit = cacheLimitBytes
        // The waiter queue, the busy flag and the reentrancy re-check that
        // used to live here are all the holder's now — and it does the
        // re-check for every waiter, not only for the one that won.
        let source = weights
        return try await held.value {
            try await loadModelContainer(
                from: source, using: #huggingFaceTokenizerLoader())
        }
    }

    /// Are the weights resident? Asks the holder, which owns the answer.
    public var isResident: Bool {
        get async { await held.isResident }
    }

    /// Start the warm-up, at most one at a time.
    func startPrewarm(instructions: String?, maxTokens: Int) {
        guard warmTask == nil else { return }
        warmTask = Task { [weak self] in
            guard let self else { return }
            // The residency half of this guard used to be a synchronous
            // read of a stored property; the holder owns that state now, so
            // it is asked here instead. Same meaning: an already-resident
            // model needs no warm-up, and the throwaway token it would
            // burn is pure waste.
            guard await !self.isResident else { return }
            _ = try? await self.ensureModel()
            // LOADING IS NOT WARMING (INSTRUMENTS §25): with the weights
            // resident the FIRST generation still paid 1911 ms of Metal
            // pipeline warm-up while the second took 82 ms. One throwaway
            // token buys that here, off-turn.
            guard !Task.isCancelled else { return }
            let sacrifice = MLXTokenSource(model: self, instructions: instructions,
                                           maxTokens: 1)
            do {
                for try await _ in sacrifice.tokens(for: ReplyContext(transcript: "hi")) { break }
            } catch { /* a warm-up that fails is not a turn that fails */ }
            await self.clearWarmTask()
        }
    }

    private func clearWarmTask() { warmTask = nil }

    /// Stop warming and drop the weights.
    ///
    /// The app calls this before replacing one model with another, so the
    /// retired 2.2 GB is released rather than living beside its
    /// replacement — which on a phone is the whole point (INSTRUMENTS §27).
    public func retire() async {
        warmTask?.cancel()
        warmTask = nil
        // The holder raises its generation ticket, so a load already in
        // flight cannot resurrect what this call just retired — a guarantee
        // the hand-written version never had.
        await held.retire()
    }

    /// The vocabulary's reasoning markers, read once and remembered.
    /// Read, never hard-coded — AC-125's rule.
    func thinkTokens() throws -> ThinkTokens? {
        if let think { return think }
        let read = try ThinkTokens.read(
            fromTokenizerConfigAt: weights.appending(path: "tokenizer_config.json"))
        think = .some(read)
        return read
    }
}

// MARK: - the real token source

/// MLX generating on this device, gated at the token.
///
/// The order here is the milestone's whole point (SPEC §86): the gate
/// runs on the ID, so a swallowed thought never reaches the detokenizer
/// and therefore never becomes a string at all. Filtering the text
/// instead would mean holding characters back to see what they become,
/// and holding delays the mouth.
struct MLXTokenSource: ReplyTokenStreaming {
    let model: LocalMindModel
    /// Shaped for SPEECH, and the TEXT lives with the caller — D-027's
    /// mechanism/policy line, and F-3 of D-057 ruled exactly this for the
    /// first mind.
    let instructions: String?
    let maxTokens: Int

    var unavailable: (any Error)? {
        // Asked at the door, EVERY time: weights can finish arriving
        // between two turns, so a cached refusal would freeze a
        // temporary state into a verdict.
        guard MLXRuntime.isAvailable else { return MLXUnavailable.platformCannotRunMLX }
        guard model.modelInstalled() else {
            return MLXUnavailable.weightsNotInstalled(model.weights.lastPathComponent)
        }
        return nil
    }

    func tokens(for context: ReplyContext) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await model.ensureModelLoaded()
                    let gateTokens = try await model.thinkTokens()
                    // Built INSIDE the closure: `Chat.Message` is not
                    // Sendable, so only the strings cross the boundary.
                    let spoken = instructions
                    let asked = context.transcript
                    let past = context.history
                    try await container.perform { (model: ModelContext) in
                        var messages: [Chat.Message] = []
                        if let spoken { messages.append(.system(spoken)) }
                        // THE PAST, IN ROLES (4r, F-1 = B). This is the
                        // shape the seam was widened for: the model is
                        // TOLD who said what instead of being handed a
                        // wall of text to parse.
                        //
                        // A barged reply ends in an ellipsis and nothing
                        // else (F-2 = C). It is punctuation, not English:
                        // this library does not own the app's words
                        // (D-027), and a trailing "…" reads as an
                        // unfinished utterance in every language the
                        // tokenizer knows. What it must NOT do is claim
                        // the person heard all of it.
                        for turn in past {
                            messages.append(.user(turn.said))
                            messages.append(.assistant(
                                turn.replied + (turn.interrupted ? "…" : "")))
                        }
                        messages.append(.user(asked))
                        let input = try await model.processor.prepare(
                            input: UserInput(
                                chat: messages,
                                // LAYER 1 (§86): ask the model not to think
                                // at all. The template pre-fills a closed
                                // block. A convention, not a constraint —
                                // which is why the gate below still exists.
                                additionalContext: ["enable_thinking": false]))

                        var gate = gateTokens.map { ThinkGate($0) }
                        var detokenizer = NaiveStreamingDetokenizer(
                            tokenizer: model.tokenizer)

                        for await event in try generateTokens(
                            input: input,
                            parameters: GenerateParameters(maxTokens: maxTokens),
                            context: model) {
                            if Task.isCancelled { break }
                            guard let id = event.token else { continue }
                            // LAYER 2: the net. One integer comparison,
                            // and nothing swallowed is ever detokenised.
                            if gate?.admits(id) == false { continue }
                            detokenizer.append(token: id)
                            // nil while a multi-token character is still
                            // incomplete — exactly what accented text does.
                            if let piece = detokenizer.next(), !piece.isEmpty {
                                continuation.yield(piece)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - the public door

extension MLXReplyGenerator {
    /// Load the weights BEFORE the first question.
    ///
    /// Measured, and the reason this exists: cold, the first token took
    /// **1.9 s**, nearly all of it loading 334 MB. Warm, the spike
    /// measured 67 ms. A spoken assistant cannot pay a second and a half
    /// in front of its first word — this project has spent two milestones
    /// getting the felt pause to 542 ms — so the load happens while the
    /// person is still deciding to speak, exactly as `AppleReplyGenerator`
    /// prewarms its own session.
    ///
    /// Silent by design: a prewarm that throws would turn "not ready yet"
    /// into a crash at launch. The door (`unavailable`) is still the
    /// place that reports honestly, every turn.
    public func prewarm() {
        guard let source = source as? MLXTokenSource else { return }
        let model = source.model
        let instructions = source.instructions
        let maxTokens = source.maxTokens
        // The hop is unavoidable — `prewarm()` is synchronous so it
        // matches `AppleReplyGenerator.prewarm()` — but it does nothing
        // except hand the work to the ACTOR, which owns the handle and
        // can cancel it. Nothing long-running is left un-owned here.
        Task { await model.startPrewarm(instructions: instructions,
                                        maxTokens: maxTokens) }
    }

    /// The second mind, ready to answer.
    ///
    /// - Parameters:
    ///   - model: the weights, held for the whole conversation.
    ///   - instructions: how to speak. TEXT belongs to the app, never the
    ///     library (D-027, and D-057's F-3 for the first mind).
    ///   - maxTokens: a spoken reply that runs forever is a bug, not a
    ///     feature.
    public init(model: LocalMindModel,
                instructions: String? = nil,
                maxTokens: Int = 512) {
        self.init(source: MLXTokenSource(model: model,
                                         instructions: instructions,
                                         maxTokens: maxTokens))
    }
}
