import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MultiModalKit
import Synchronization
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
    private var window: Int??             // nil = unread, .some(nil) = the config does not say
    /// A SYNCHRONOUS MIRROR of `held.isResident`, for
    /// `estimatedWorkingSetBytes()` (4v) — which the door itself no longer
    /// asks, since the second review; the estimate is a question a caller
    /// may put, not a gate (the note on that method). It is still a
    /// synchronous question, and the holder's answer is behind an actor
    /// hop; the mirror is
    /// written from this actor after every load and every retire — from
    /// the holder's own answer, read AFTER the await, so a retire that
    /// landed during a load wins. It may lag by one actor step, and the
    /// cost of the lag is bounded: the estimate is an ANSWER, and the
    /// question can be put again next turn.
    ///
    /// NONISOLATED, because its reader is: `estimatedWorkingSetBytes()`
    /// is a synchronous question and cannot hop to this actor to ask
    /// it. A `Mutex` is `Sendable` and NON-COPYABLE, and a non-copyable
    /// stored property must be BORROWED — which the compiler refuses
    /// across actor isolation — so this keyword is what lets the door,
    /// and the test that pins its two branches, hold the same one lock.
    nonisolated let resident = Mutex(false)

    // MARK: 4y — admission and pressure (SPEC §187/1, §187/3; D-107)

    /// The gate `admit(needing:)` goes through (AC-258, AC-259): one
    /// admission at a time, the check and the load's beginning in one
    /// step. It holds the injected headroom reading; the model hands it
    /// the real load. See `LocalMind+Admission.swift`.
    let admission: MindAdmission
    /// The runs alive on these weights, so a memory warning can end them
    /// all through their own latches (AC-261). Nonisolated: a run
    /// registers itself synchronously at birth, from the generator's
    /// door, and asking an actor for permission to be born would put a
    /// hop in front of every reply.
    nonisolated let liveRuns = LiveRunRegistry()
    /// The pressure subscription, alive as long as this model is. Boxed
    /// and nonisolated because it is made INSIDE `init` with a handler
    /// that captures `self` weakly — after which an actor's init may no
    /// longer touch its isolated state — and released in `deinit`.
    ///
    /// FOR THE MODEL'S WHOLE LIFE, not from load to retire, and the reason
    /// is R4: a retire is not the end of this model — the next `openReply`
    /// reloads (AC-262) — so a subscription tied to residency would have
    /// to be re-made on every reload and would miss a `.critical` that
    /// arrives between. A level that finds nothing resident and no run
    /// live costs one actor hop and does nothing.
    private nonisolated let pressureWatch = Mutex<MemoryPressureSubscription?>(nil)
    /// Generations in flight on these weights, and who is waiting for
    /// zero — the fact a live memory test gates on (`waitForIdle()`).
    var generationsInFlight = 0
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Generations that have BEGUN on these weights, ever, as a count a
    /// test can wait on (the review of this piece): a generation begins
    /// on its own task, one hop after `openReply` has returned, so "none
    /// in flight" is also true of a reply whose generation has not
    /// started yet. A test that wants the "after" of a generation reads
    /// this before the reply, waits for one more, then waits for idle.
    /// Nonisolated because the watch is its own lock (`ThresholdWatch`).
    nonisolated let generationsBegun = ThresholdWatch()
    /// Every level the ACTOR has finished acting on, in order — the event
    /// a test waits for instead of polling `isResident` (AC-262). It is
    /// nonisolated because the handler is. BOUNDED (the review of this
    /// piece): in the app nobody reads it, so an unbounded buffer would
    /// keep every transition of the model's life for no reader; a test
    /// pushes a level or two and listens at once. Sixteen levels is
    /// more than any row pushes and bytes in the app.
    nonisolated let pressureHandled: AsyncStream<MemoryPressureMonitor.Level>.Continuation
    nonisolated let pressureLevels: AsyncStream<MemoryPressureMonitor.Level>
    static let pressureLevelsKept = 16
    /// How many times `retire()` ran — a test's question (AC-262): on a
    /// machine with nothing loaded `isResident` is false before AND after
    /// a `.critical`, and only the count says the weights were let go.
    var retirements = 0

    /// Weights already on disk. Nothing is ever downloaded.
    ///
    /// - Parameters:
    ///   - headroom: how the mind reads the phone's headroom at admission
    ///     (4y, AC-258/259). The default is the one live reader —
    ///     bytes REMAINING, `nil` on a Mac (D-092). A test scripts it.
    ///   - pressure: where memory-pressure levels come from (4y,
    ///     AC-261..263). The default is the kernel's dispatch source. A
    ///     test pushes levels by hand.
    public init(weights: URL, cacheLimitBytes: Int = 20 * 1024 * 1024,
                headroom: @escaping HeadroomReading = MemoryHeadroomReader.read,
                pressure: any MemoryPressureSourcing = SystemMemoryPressureSource()) {
        self.weights = weights
        self.repoID = nil
        self.cacheLimitBytes = cacheLimitBytes
        self.admission = MindAdmission(headroom: headroom)
        (pressureLevels, pressureHandled) = AsyncStream.makeStream(
            of: MemoryPressureMonitor.Level.self,
            bufferingPolicy: .bufferingNewest(Self.pressureLevelsKept))
        watchPressure(pressure)
    }

    /// Weights this model may fetch if they are missing — Whisper's
    /// shape, which D-062 F-4 = A ruled for exactly this seam.
    ///
    /// The default directory is the app's Documents, which is where a
    /// person can also drop the folder by hand over USB.
    public init(repoID: String, in directory: URL = URL.documentsDirectory,
                cacheLimitBytes: Int = 20 * 1024 * 1024,
                headroom: @escaping HeadroomReading = MemoryHeadroomReader.read,
                pressure: any MemoryPressureSourcing = SystemMemoryPressureSource()) {
        self.repoID = repoID
        self.cacheLimitBytes = cacheLimitBytes
        self.weights = directory.appending(
            path: repoID.split(separator: "/").last.map(String.init) ?? repoID)
        self.admission = MindAdmission(headroom: headroom)
        (pressureLevels, pressureHandled) = AsyncStream.makeStream(
            of: MemoryPressureMonitor.Level.self,
            bufferingPolicy: .bufferingNewest(Self.pressureLevelsKept))
        watchPressure(pressure)
    }

    /// Subscribes to pressure for this model's life, with THE HANDLER THAT
    /// DOES NO WORK (AC-263, Aura's R3). Called from `init` once every
    /// stored property is set, so `self` may be captured — weakly, so the
    /// source's own retention of the handler cannot keep a model alive.
    ///
    /// AN UNSTRUCTURED HOP, the shape `prewarm()` already has, and why:
    /// the source calls the handler on a dispatch queue, synchronously,
    /// while the kernel is already short of memory. The handler's whole
    /// job is to get OFF that queue and onto the actor, where the work is
    /// one step of `pressure(_:)`. There is no structured parent to
    /// attach to — the handler is a callback, not a task — so the hop is
    /// a `Task`, and it is the only thing in the closure: no await of its
    /// own, no MLX call, no allocation beyond the hop itself.
    /// `MLXPressureTests` reads this function's source and fails if
    /// anything else appears between the two markers.
    ///
    /// WHAT THIS MEANS, stated rather than dressed up: the runs' tickets
    /// are raised one scheduler hop later, on the actor's step — not in
    /// the handler itself. Between the kernel's callback and that step
    /// the vendor may produce a token and a listener may hear it. The
    /// alternative — raising every run's latch synchronously in the
    /// handler, which `LiveRunRegistry.abandonAll()` could do without
    /// suspending — would finish streams, and run their termination
    /// handlers, on the kernel's queue while it is short of memory. AC-263
    /// as written ("returns within one actor hop") is the shipped shape;
    /// the other is a fork, not a fix.
    private nonisolated func watchPressure(_ source: any MemoryPressureSourcing) {
        // pressure-handler: begin
        let subscription = source.subscribe { [weak self] level in
            Task { await self?.pressure(level) }
        }
        // pressure-handler: end
        pressureWatch.withLock { $0 = subscription }
    }

    deinit {
        pressureWatch.withLock { $0 }?.cancel()
        pressureHandled.finish()
    }

    /// Honest disk check — no load is ever triggered by asking.
    ///
    /// "Installed" means OFFLINE-CAPABLE, the lesson Whisper's own audit
    /// wrote down: the weights alone are not enough, because a tokenizer
    /// that is missing its files is a silent network fetch waiting to
    /// happen. So the tokenizer's files are part of the question.
    ///
    /// Since 4v this is the Bool view of `installState()` (AC-239): a
    /// verified tree and a pre-4v tree with no manifest both count; a
    /// tree with a file missing or SHORT does not, which a name-only
    /// check could never say. The download itself lives in
    /// `LocalMindInstall.swift`, beside the manifest it writes.
    public nonisolated func modelInstalled() -> Bool {
        switch installState() {
        case .installed, .installedUnverified: true
        case .absent, .incomplete: false
        }
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
        // The typed verdict (4v, AC-238's wiring) — the same enum AND the
        // same question as the reply door, so a caller counts one kind of
        // refusal, not two. It was briefly two: the reply door added a
        // memory claim this one did not, which the second 4v review
        // showed could lock a phone out for good (the note on
        // `estimatedWorkingSetBytes()`).
        if let verdict = readiness() { throw ReplyFailure.unavailable(verdict) }
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
        let container = try await held.value {
            try await loadModelContainer(
                from: source, using: #huggingFaceTokenizerLoader())
        }
        // The mirror, from the holder's OWN answer after the await — a
        // retire that landed during the load has already emptied it.
        let nowResident = await held.isResident
        resident.withLock { $0 = nowResident }
        return container
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
        retirements += 1
        warmTask?.cancel()
        warmTask = nil
        // The holder raises its generation ticket, so a load already in
        // flight cannot resurrect what this call just retired — a guarantee
        // the hand-written version never had.
        await held.retire()
        resident.withLock { $0 = false }
    }

    /// The model's context window in tokens — `max_position_embeddings`
    /// from its `config.json` — read once and remembered, `nil` when the
    /// config does not say (AC-236). Read, never hard-coded: the same
    /// rule as `thinkTokens()`, for the same reason — a number typed here
    /// is right for one model and silently wrong for the next.
    func contextWindow() throws -> Int? {
        if let window { return window }
        let read = try ContextWindow.read(
            fromConfigAt: weights.appending(path: "config.json"))
        window = .some(read)
        return read
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
    /// The tools the app granted this mind (4w, F-2 = A) — rendered into
    /// the prompt as specs, and read by the run to execute a call. Empty
    /// by default, and an empty table changes NOTHING in the prompt or
    /// the loop (AC-227): the spec is only passed when there is one, and
    /// the call parser is only built when there is one.
    let tools: ToolTable

    init(model: LocalMindModel, instructions: String?, maxTokens: Int,
         tools: ToolTable = .empty) {
        self.model = model
        self.instructions = instructions
        self.maxTokens = maxTokens
        self.tools = tools
    }

    var unavailable: ReplyFailure? {
        // Asked at the door, EVERY time: weights can finish arriving
        // between two turns, so a cached refusal would freeze a
        // temporary state into a verdict.
        //
        // TYPED since 4v (AC-238's wiring): the three strings this source
        // used to speak — one of which told a real phone it was the
        // Simulator (D-101's F1) — are gone. The verdict is the pure
        // function over this machine's report, and the door throws it as
        // the seam's own `ReplyFailure.unavailable`, so a caller counts
        // one enum and a screen renders the one sentence that is true.
        model.readiness().map { .unavailable($0) }
    }

    /// The model's registry (4y, AC-261): a run born of this source is
    /// one a memory warning on these weights must be able to end.
    var liveRuns: LiveRunRegistry? { model.liveRuns }

    /// The chat, in the vendor's roles. Synchronous and called INSIDE the
    /// container's `perform`, because `Chat.Message` is not Sendable.
    ///
    /// THE PAST, IN ROLES (4r, F-1 = B). This is the shape the seam was
    /// widened for: the model is TOLD who said what instead of being
    /// handed a wall of text to parse.
    ///
    /// A barged reply ends in an ellipsis and nothing else (F-2 = C). It
    /// is punctuation, not English: this library does not own the app's
    /// words (D-027), and a trailing "…" reads as an unfinished
    /// utterance in every language the tokenizer knows. What it must NOT
    /// do is claim the person heard all of it.
    ///
    /// `spoken` is the RESOLVED instruction (AC-232): the caller's for
    /// this call, else this source's own, else no system message at all.
    ///
    /// INTERNAL, not private, since the 4v review: AC-232's MLX half is
    /// this line and nothing else, and `@testable` cannot reach a
    /// `private` member — so the whole of "the resolved instruction
    /// becomes the `.system` message" was unprovable, and the only test
    /// stopped one seam short, at the resolution struct.
    /// `MLXTokenSource` is itself internal, so this widens nothing a
    /// consumer can see; it widens what a test can read.
    static func messages(spoken: String?, asked: String,
                         past: [ConversationTurn]) -> [Chat.Message] {
        messages(spoken: spoken, asked: asked, past: past, exchanges: [])
    }

    func tokens(for context: ReplyContext,
                after exchanges: [ToolExchange]) -> AsyncThrowingStream<TokenEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // COUNTED, first to last (4y): the model knows a generation
                // is in flight from before the load door until after the
                // vendor's iterator is gone, so `waitForIdle()` is the
                // honest "after" of a memory measurement. Structured: the
                // count is lowered by THIS task, after the round, never by
                // a task spawned to do it.
                await model.generationBegan()
                await generate(for: context, after: exchanges, into: continuation)
                await model.generationEnded()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One round, start to finish: the load door, the prompt, the vendor's
    /// loop, and the stream's end — the body `tokens(for:after:)`'s task
    /// ran inline until 4y counted it.
    private func generate(
        for context: ReplyContext, after exchanges: [ToolExchange],
        into continuation: AsyncThrowingStream<TokenEvent, any Error>.Continuation
    ) async {
        do {
            let container = try await model.ensureModelLoaded()
            let gateTokens = try await model.thinkTokens()
            let window = try await model.contextWindow()
            // THE CALLER'S LEVERS, resolved once (AC-232..234):
            // per-call instructions and budget over this source's
            // own, sampling over the vendor's.
            let settings = MLXGenerationSettings(
                options: context.options, instructions: instructions, maxTokens: maxTokens)
            // Built INSIDE the closure: `Chat.Message` is not
            // Sendable, so only the strings cross the boundary.
            let asked = context.transcript
            let past = context.history
            // `nil` when no tool was given (AC-227): the template
            // branches on it, and a generator with no tools must
            // render exactly the prompt it rendered before 4w.
            let specs = tools.toolSpecs
            let tooled = !tools.isEmpty
            // A RUN ALREADY DEAD STOPS HERE (the review of this piece,
            // AC-261, Aura's R3). A `.warning` during the load, an early
            // barge, an early deadline: the run's latch is up and this
            // task is cancelled — and until this line nothing between
            // the load door and the vendor's loop looked. Measured: a
            // run cancelled at birth still paid the FULL prompt prefill
            // (866 MB over a 320 MB floor on a long prompt), because the
            // vendor's `TokenIterator.init` prefills synchronously and
            // the first check on the path was the drain's, one token
            // later. Worse, it held the container's serial lock the
            // whole way, so the NEXT reply queued behind a dead one.
            // Checked BEFORE the lock is asked for, so a dead run never
            // takes it; the `CancellationError` lands in a stream the
            // cancel has already finished, and is dropped there.
            try Task.checkCancellation()
            try await container.perform { (model: ModelContext) in
                let messages = Self.messages(
                    spoken: settings.instructions, asked: asked, past: past, exchanges: exchanges)
                let input = try await model.processor.prepare(
                    input: UserInput(
                        chat: messages,
                        tools: specs,
                        // LAYER 1 (§86): ask the model not to think
                        // at all. The template pre-fills a closed
                        // block. A convention, not a constraint —
                        // which is why the gate below still exists.
                        additionalContext: ["enable_thinking": false]))

                // AC-236: COUNTED BEFORE GENERATION. The vendor
                // does not throw for a prompt past the window — it
                // generates noise — so the prepared prompt is
                // measured here and refused as the typed case.
                if let refusal = PromptFit.refusal(
                    promptTokens: input.text.tokens.size, window: window) {
                    throw refusal
                }

                // THE CALL PARSER (4w, AC-222), built ONLY when a
                // tool was given — so the plain path runs the loop
                // it ran before (AC-227). `generateTokens` has no
                // `.toolCall` event (the note in `MLXTools.swift`);
                // this sieve is the vendor's own parser over our
                // gated pieces, in the format the vendor inferred
                // for these weights.
                let sieve = tooled ? ToolCallSieve(
                    format: model.configuration.toolCallFormat ?? .json, specs: specs) : nil
                try await Self.stream(
                    input: input, settings: settings, model: model,
                    filters: TokenFilters(
                        gate: gateTokens.map { ThinkGate($0) },
                        detokenizer: NaiveStreamingDetokenizer(tokenizer: model.tokenizer),
                        sieve: sieve),
                    into: continuation)
            }
            // No `.stopped` here: the reason came from the `.info`
            // event above, or it did not come at all — and a stream
            // that ends without one is `.finished(.unreported)` one
            // seam up, which is the honest word for a vendor that
            // did not say.
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// The vendor's loop, gated at the token — the body `tokens(for:)`
    /// ran inline until 4w gave it a second path. Runs INSIDE the
    /// container's `perform`, because `ModelContext` is not Sendable.
    private static func stream(
        input: LMInput, settings: MLXGenerationSettings, model: ModelContext,
        filters initialFilters: TokenFilters,
        into continuation: AsyncThrowingStream<TokenEvent, any Error>.Continuation
    ) async throws {
        var filters = initialFilters
        // THE TASK VARIANT (4y, AC-261, AC-264), and the reason: the
        // vendor's loop runs in its own task, and "if the stream is
        // terminated early ... computation will continue ... for some
        // time" (its doc). The `TokenIterator` that owns the KV cache —
        // the prefill's product — lives in that task. Before 4y this
        // source used `generateTokens`, which DROPS the task, so a cut
        // generation's memory was freed at a moment nobody could name.
        // Now the task is awaited below, and the free is a fact.
        //
        // THE LAST LOOK BEFORE THE PREFILL (the review of this piece):
        // the vendor's lock ignores cancellation — a cancelled task waits
        // its turn and enters — so a run cut while it was parked on the
        // lock arrives here alive, and this line is what keeps its
        // prefill from happening. WHAT IS MEASURED AND WHAT IS NOT (the
        // re-attack): the live row goes red only when BOTH checks are
        // removed; either one alone keeps it green, because the row cuts
        // the run before the lock and the first check catches that. This
        // second check is justified by reading the vendor's AsyncMutex,
        // not by a row — there is no hook for "parked on the lock" to
        // build one from. The pair is what is proven.
        try Task.checkCancellation()
        let (events, vendor) = try generateTokensTask(
            input: input,
            parameters: GenerateParameters(settings),
            context: model)
        // THE DRAIN is `VendorLoop.drain`'s (the review of this piece):
        // the loop, the cut, the vendor's cancel and the await that makes
        // "the KV cache is gone" a fact live there, where a scripted
        // producer can prove them. The first cut relied on the stream's
        // termination to cancel the vendor — true when the cancel lands
        // in `next()`, FALSE when it lands in the body and the loop leaves
        // by `break`: the vendor then ran to `maxTokens`.
        let cut = await VendorLoop.drain(events, vendor: vendor) { event in
            switch event {
            case .token(let id):
                for event in filters.admit(id) { continuation.yield(event) }
            case .info(let info):
                // A call the model finished with its turn
                // (the tags closed on the last token) is
                // flushed HERE, before the stop — the order
                // the vendor's own text loop keeps.
                for event in filters.finish() { continuation.yield(event) }
                // AC-235: the event this loop used to DROP
                // (`guard let id = event.token else { continue }`).
                // The vendor says why it stopped; the seam
                // says it in its own word. `.cancelled` maps
                // to nothing — a cancelled run ends with no
                // terminal, by contract.
                if let reason = StopReason(vendor: info.stopReason) {
                    continuation.yield(.stopped(reason))
                }
            }
        }
        // WHAT FREES THE PREFILL (AC-261, AC-264). The drain above ends
        // only once the vendor's task has — the iterator that owns the
        // KV cache is a local of that task. A generation that was CUT (a
        // barge, a warning, the deadline) then empties the vendor's
        // buffer pool as well (`freePrefill`'s note has the allocator's
        // rule); one that ended on its own keeps the pool, because the
        // next reply reuses it.
        if cut { MLX.Memory.clearCache() }
    }
}

/// What stands between a vendor token ID and the seam, in the order it
/// runs: the think gate (§86 layer 2), the detokenizer, and — only when
/// a tool was given (4w) — the call sieve. One value, so the loop above
/// reads as one line per event and the order cannot drift.
struct TokenFilters {
    var gate: ThinkGate?
    var detokenizer: NaiveStreamingDetokenizer
    let sieve: ToolCallSieve?

    /// One token ID in; the seam's events out — usually none or one.
    mutating func admit(_ id: Int) -> [TokenEvent] {
        // LAYER 2: the net. One integer comparison,
        // and nothing swallowed is ever detokenised.
        if gate?.admits(id) == false { return [] }
        detokenizer.append(token: id)
        // nil while a multi-token character is still
        // incomplete — exactly what accented text does.
        guard let piece = detokenizer.next(), !piece.isEmpty else { return [] }
        guard let sieve else { return [.token(piece)] }
        // With a tool: the piece is text to speak,
        // or part of a call being collected, or a
        // whole call — the sieve says which.
        return sieve.admit(piece)
    }

    /// End of sequence: nothing without a tool; the sieve's residue with.
    func finish() -> [TokenEvent] {
        sieve?.finish() ?? []
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
    ///     feature. 1024 since 4v (D-103 F-6 = A, AC-233): the cap is a
    ///     ceiling, not a target — voice replies are short by instruction
    ///     and the barge-in ends a runaway, while a text caller's whole
    ///     document needs the room.
    ///   - tools: what this mind may CALL while it answers (4w, F-2 = A,
    ///     D-101): handed here, at construction, because tools are policy
    ///     the app grants — never to the coordinator, which must not
    ///     learn a `switch` over them. Empty by default, and an empty
    ///     table leaves the prompt and the loop exactly as they were
    ///     (AC-227). The run executes a call itself and asks again with
    ///     the answer (F-1 = B); a name no tool has is answered to the
    ///     model in words (F-4 = B); at most `ToolRounds.cap` rounds per
    ///     reply.
    ///   - thermal: the thermometer (4y, AC-260). The system's by default;
    ///     a test scripts one.
    ///   - thermalPolicy: whether a reply may be generated at that heat
    ///     (D-107 F-2 = A): the shipped default refuses at `.critical`
    ///     only, because the measured phone lived at `.serious`. The
    ///     app's policy replaces it here — the coordinator never sees it
    ///     (AC-265).
    ///   - clock: what a `GenerationOptions.deadline` is measured on
    ///     (AC-264). Wall time by default; a `ManualClock` in the tests.
    public init(model: LocalMindModel,
                instructions: String? = nil,
                maxTokens: Int = 1024,
                tools: ToolTable = .empty,
                thermal: any ThermalStateProviding = SystemThermalProvider(),
                thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.init(source: MLXTokenSource(model: model,
                                         instructions: instructions,
                                         maxTokens: maxTokens,
                                         tools: tools),
                  thermal: thermal,
                  thermalPolicy: thermalPolicy,
                  clock: clock)
    }
}
