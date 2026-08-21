import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MultiModalKit
import Hub
import Tokenizers

// MARK: - the runtime guard (AC-129)

/// Whether MLX can be touched AT ALL on this machine, asked BEFORE
/// touching it.
///
/// This exists because of a measured failure mode, not a hypothetical
/// one (D-061, INSTRUMENTS §24): with no `default.metallib` reachable,
/// MLX does not throw and does not fail an assertion — it **aborts the
/// process**. A crashing test runner cannot report which test killed it,
/// so the only safe order is to look for the artefact with Foundation
/// first and never call into MLX if it is missing.
///
/// The check is deliberately CONSERVATIVE. A false negative means we
/// refuse to run when we could have; a false positive means the process
/// dies. Those costs are not symmetric, so the doubt goes one way.
public enum MLXRuntime {

    /// mlx-swift's own SwiftPM bundle name, from its `Package.swift`:
    /// `.define("SWIFTPM_BUNDLE", to: "\"mlx-swift_Cmlx\"")`.
    private static let cmlxBundleName = "mlx-swift_Cmlx"

    /// `<base>/mlx-swift_Cmlx.bundle/<resources>/default.metallib`, which
    /// is the shape `try_load_bundle` builds in device.cpp.
    private static func nestedCmlxLibrary(in base: URL) -> URL? {
        let nested = base.appending(path: "\(cmlxBundleName).bundle")
        guard let bundle = Bundle(url: nested),
              let resources = bundle.resourceURL else { return nil }
        let library = resources.appending(path: "default.metallib")
        return FileManager.default.fileExists(atPath: library.path) ? library : nil
    }

    /// Where the vendor's loader looks — MIRRORED from its source, and
    /// corrected TWICE by the AC-129 control rather than by reasoning.
    ///
    /// Both corrections are worth keeping, because both were false
    /// POSITIVES, and a false positive here is a dead process:
    ///
    /// 1. The first version searched each bundle for a nested Cmlx bundle
    ///    with `url(forResource:)`, which found one MLX never loads.
    /// 2. The second version accepted ANY bundle's
    ///    `Resources/default.metallib` — and matched
    ///    **`Vision.framework/Resources/default.metallib`**, because
    ///    Apple ships its own. MLX only accepts a framework whose bundle
    ///    IDENTIFIER is mlx-swift's own, which is exactly the check that
    ///    rules Vision out.
    ///
    /// The colocated `mlx.metallib` arrangements (steps 1, 2 and 4 of
    /// `load_default_library`) are deliberately NOT checked: they exist
    /// for non-SwiftPM builds this package does not produce, and every
    /// extra place to look is another chance to say yes wrongly. The cost
    /// is a false NEGATIVE for such a build — we would skip where MLX
    /// could have run — and that is the direction this check is allowed
    /// to be wrong in.
    public static func metallibURL() -> URL? {
        let files = FileManager.default
        // The app case: an .app carrying mlx-swift_Cmlx.bundle.
        if let found = nestedCmlxLibrary(in: Bundle.main.bundleURL) { return found }
        for bundle in Bundle.allBundles {
            if let resources = bundle.resourceURL,
               let found = nestedCmlxLibrary(in: resources) { return found }
        }
        // A dynamic framework wrapping it — the IDENTIFIER must match.
        for framework in Bundle.allFrameworks
        where framework.bundleIdentifier == cmlxBundleName {
            if let resources = framework.resourceURL {
                let library = resources.appending(path: "default.metallib")
                if files.fileExists(atPath: library.path) { return library }
            }
        }
        // The `swift test` case — INSTRUMENTS §24 STAGE 1's finding.
        let cwd = URL(filePath: files.currentDirectoryPath)
            .appending(path: "default.metallib")
        return files.fileExists(atPath: cwd.path) ? cwd : nil
    }

    /// What MLX is holding, in bytes — the number that decides whether a
    /// model fits on a PHONE.
    ///
    /// It matters because MLX does not memory-map its weights: there is
    /// no `mmap` anywhere in its C++ core (measured, INSTRUMENTS §25), so
    /// everything loaded is RESIDENT, beside the audio graph, the
    /// recogniser and the mouth. On a Mac that is invisible. On a phone
    /// it is the difference between a working app and one jetsam kills.
    ///
    /// Reading these NEVER touches the GPU, but it does construct MLX's
    /// allocator — so `isAvailable` is checked first, or the process
    /// would abort on a machine with no metallib.
    public static var activeMemoryBytes: Int { isAvailable ? MLX.Memory.activeMemory : 0 }
    public static var peakMemoryBytes: Int { isAvailable ? MLX.Memory.peakMemory : 0 }

    /// True when MLX may be called. `false` means SKIP — never "try and
    /// see", because trying is what aborts the process.
    ///
    /// The simulator is refused OUTRIGHT, before the artefact is even
    /// looked for, and this is not caution — it is D-061, measured:
    /// MLX asks Metal for a heap with `ResourceStorageModeShared` because
    /// it assumes the unified memory of real Apple silicon, and
    /// `MTLSimDevice` requires `Private` and refuses. `Device.cpu` does
    /// not escape it, because the allocator is chosen at BUILD time. The
    /// metallib IS present in a simulator app bundle, so a check that
    /// only looked for the file would say yes and then die on the first
    /// allocation — which is exactly what the phone spike did, twice.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return metallibURL() != nil
        #endif
    }
}

// MARK: - the model, loaded once (D-062 F-4 = A: Whisper's shape)

/// Holds the weights for the whole conversation, because loading them per
/// turn would put hundreds of milliseconds in front of every reply.
///
/// The two public questions are Whisper's, deliberately — same names,
/// same semantics, so an app that already knows one engine knows this
/// one: `modelInstalled()` never triggers work, and `ensureModel()` is
/// idempotent.
public actor LocalMindModel {
    /// Nonisolated: it never changes, and a caller needs the path to say
    /// WHERE it is looking — a question that should not require awaiting
    /// an actor that may be busy loading 2 GB.
    public nonisolated let weights: URL
    /// The Hugging Face repo these weights come from, when the app wants
    /// the library to be able to FETCH them. `nil` means bring-your-own:
    /// the caller placed the files and no download will ever happen.
    public nonisolated let repoID: String?
    private var container: ModelContainer?
    private var think: ThinkTokens??      // nil = unread, .some(nil) = none declared

    /// Weights already on disk. Nothing is ever downloaded.
    public init(weights: URL) {
        self.weights = weights
        self.repoID = nil
    }

    /// Weights this model may fetch if they are missing — Whisper's
    /// shape, which D-062 F-4 = A ruled for exactly this seam.
    ///
    /// The default directory is the app's Documents, which is where a
    /// person can also drop the folder by hand over USB.
    public init(repoID: String, in directory: URL = URL.documentsDirectory) {
        self.repoID = repoID
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
        ) { p in progress(p.fractionCompleted) }

        guard snapshot != weights else { return }
        let files = FileManager.default
        if files.fileExists(atPath: weights.path) {
            try files.removeItem(at: weights)
        }
        try files.createDirectory(at: weights.deletingLastPathComponent(),
                                  withIntermediateDirectories: true)
        try files.moveItem(at: snapshot, to: weights)
    }

    /// Loads the weights. Idempotent; the load half is skipped when the
    /// model is already resident.
    @discardableResult
    public func ensureModel() async throws -> ModelContainer {
        if let container { return container }
        guard MLXRuntime.isAvailable else { throw MLXUnavailable.platformCannotRunMLX }
        guard modelInstalled() else {
            throw MLXUnavailable.weightsNotInstalled(weights.lastPathComponent)
        }
        // The examples set this low so a buffer cache cannot push a phone
        // into jetsam. Measured note (INSTRUMENTS §25): MLX does not mmap
        // its safetensors, so the weights are RESIDENT — on a phone this
        // sits beside a live audio graph, a recogniser and a mouth.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        let loaded = try await loadModelContainer(
            from: weights, using: #huggingFaceTokenizerLoader())
        container = loaded
        return loaded
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

    func tokens(for prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await model.ensureModel()
                    let gateTokens = try await model.thinkTokens()
                    // Built INSIDE the closure: `Chat.Message` is not
                    // Sendable, so only the strings cross the boundary.
                    let spoken = instructions
                    try await container.perform { (context: ModelContext) in
                        var messages: [Chat.Message] = []
                        if let spoken { messages.append(.system(spoken)) }
                        messages.append(.user(prompt))
                        let input = try await context.processor.prepare(
                            input: UserInput(
                                chat: messages,
                                // LAYER 1 (§86): ask the model not to think
                                // at all. The template pre-fills a closed
                                // block. A convention, not a constraint —
                                // which is why the gate below still exists.
                                additionalContext: ["enable_thinking": false]))

                        var gate = gateTokens.map { ThinkGate($0) }
                        var detokenizer = NaiveStreamingDetokenizer(
                            tokenizer: context.tokenizer)

                        for await event in try generateTokens(
                            input: input,
                            parameters: GenerateParameters(maxTokens: maxTokens),
                            context: context)
                        {
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
        Task {
            _ = try? await source.model.ensureModel()
            // LOADING IS NOT WARMING — measured by the bake-off (AC-130).
            // With the weights already resident, the FIRST generation
            // still took 1911 ms while the second took 82 ms and the
            // third 267 ms. The extra 1.8 s is Metal pipeline and graph
            // warm-up, and it is paid by whoever generates first. So this
            // burns one throwaway token here, off-turn, rather than
            // letting a person pay it in front of their first answer.
            let sacrifice = MLXTokenSource(model: source.model,
                                           instructions: nil,
                                           maxTokens: 1)
            do {
                for try await _ in sacrifice.tokens(for: "hi") { break }
            } catch { /* a warm-up that fails is not a turn that fails */ }
        }
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
