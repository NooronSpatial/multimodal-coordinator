import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

/// THE MIND'S TEXT CONTRACT, THE SEAM HALF (4v, SPEC §174–175, D-103):
/// the options a caller can pass (AC-231), the typed terminals a run can
/// end with, and the whole reply written once over `openReply` (AC-237).
///
/// **Nothing here polls.** The cancellation test waits on EVENTS — an
/// `AsyncStream` the fake signals into — raced against a SLEEPING deadline
/// (the `AIRuntimeTests` shape, and the reason it exists: a yield-spin
/// froze CI for six hours, twice). A red test still dies in ten seconds.
@Suite(.timeLimit(.minutes(1)))
struct ReplyContractTests {

    // MARK: - AC-231: the options travel with the context

    @Test("openReply(to: String) passes the default options (AC-231)")
    func stringCallSitePassesDefaults() async throws {
        let mind = ScriptedReplyGenerator.manual(replies: 1)
        _ = try await mind.openReply(to: "a thought")
        let record = mind.record(ofReply: 0)
        #expect(record?.context.options == GenerationOptions())
        #expect(record?.context.options.instructions == nil, "nil means the generator's own")
        #expect(record?.context.options.maxTokens == nil, "nil means the generator's default")
    }

    @Test("explicit options come back from the record unchanged (AC-231)")
    func explicitOptionsAreRecorded() async throws {
        let mind = ScriptedReplyGenerator.manual(replies: 1)
        let options = GenerationOptions(instructions: "answer as JSON",
                                        maxTokens: 1024,
                                        temperature: 0.25,
                                        seed: 7)
        _ = try await mind.openReply(to: ReplyContext(transcript: "a plan", options: options))
        let record = mind.record(ofReply: 0)
        #expect(record?.context.options == options)
        #expect(record?.context.options.instructions == "answer as JSON")
        #expect(record?.context.options.maxTokens == 1024)
        #expect(record?.context.options.temperature == 0.25)
        #expect(record?.context.options.seed == 7)
    }

    @Test("GenerationOptions is a value: equal when every field is equal")
    func optionsEquality() {
        #expect(GenerationOptions() == GenerationOptions())
        #expect(GenerationOptions(maxTokens: 512) != GenerationOptions(maxTokens: 1024))
        #expect(GenerationOptions(temperature: 0.5) != GenerationOptions())
    }

    // MARK: - AC-237: the whole reply

    /// The scripted mind, wrapped so that "a reply was opened" is an EVENT
    /// the test can await. The scripted hands (`emit`/`finish`/`fail`)
    /// still belong to the inner generator.
    private static func announcing(_ inner: ScriptedReplyGenerator)
    -> (AnnouncingMind, Signals) {
        let signals = Signals()
        return (AnnouncingMind(inner: inner, signals: signals), signals)
    }

    /// `Task.value` cannot be cancelled, so a bare wait on it has no cap of
    /// its own: a `reply(to:)` that regressed into a hang would outlive the
    /// suite's time limit instead of failing fast (the house rule). This
    /// races the value against a sleeping deadline — a suspension, never a
    /// spin — and the loser is cancelled.
    private static func settled<T: Sendable>(_ task: Task<T, any Error>,
                                             within deadline: Duration = .seconds(10)) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(for: deadline)
                task.cancel()
                throw WaitTimedOut(after: deadline)
            }
            // Two children, so the first answer always exists.
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    @Test("tokens then .finished(.complete) become Reply(text:stop:) (AC-237 a)")
    func wholeReplyJoinsTokens() async throws {
        let (mind, signals) = Self.announcing(ScriptedReplyGenerator.manual(replies: 1))
        let task = Task { try await mind.reply(to: ReplyContext(transcript: "capital of Italy?")) }
        // The reply is opened INSIDE `reply(to:)`; the test drives the run
        // only once the wrapper says it exists — an event, not a poll.
        #expect(await signals.heard("opened"))
        mind.emit(reply: 0, token: "Rome")
        mind.emit(reply: 0, token: " is")
        mind.emit(reply: 0, token: " the capital.")
        mind.finish(reply: 0)
        let reply = try await Self.settled(task)
        #expect(reply == Reply(text: "Rome is the capital.", stop: .complete))
    }

    @Test("a token-budget stop round-trips (AC-237 b)")
    func tokenBudgetStopRoundTrips() async throws {
        let (mind, signals) = Self.announcing(ScriptedReplyGenerator(plans: [.manual()]))
        let task = Task { try await mind.reply(to: ReplyContext(transcript: "go on")) }
        #expect(await signals.heard("opened"))
        mind.emit(reply: 0, token: "cut")
        mind.finish(reply: 0, stop: .tokenBudget)
        let reply = try await Self.settled(task)
        #expect(reply.stop == .tokenBudget)
        #expect(reply.text == "cut")
    }

    @Test("a .failed(.busy) run makes reply(to:) throw ReplyFailure.busy (AC-237 c)")
    func failureThrowsItsReason() async throws {
        let (mind, signals) = Self.announcing(ScriptedReplyGenerator.manual(replies: 1))
        let task = Task { try await mind.reply(to: ReplyContext(transcript: "doomed")) }
        #expect(await signals.heard("opened"))
        mind.fail(reply: 0, with: .busy)
        await #expect(throws: ReplyFailure.busy) { try await Self.settled(task) }
    }

    /// The run below would never finish on its own. Cancelling the CALLING
    /// task must (1) reach the run's `cancel()`, (2) end the wait, and (3)
    /// surface as `CancellationError` — never as a reply, never as a hang.
    @Test("cancelling the calling task cancels the run and throws CancellationError (AC-237 d)")
    func cancellationEndsTheRun() async throws {
        // Two facts, two instances: a `Signals` has one consumer, so each
        // wait gets its own (the AIRuntimeTests rule).
        let opened = Signals()
        let cancelled = Signals()
        let mind = HangingMind(opened: opened, cancelled: cancelled)
        let task = Task { try await mind.reply(to: ReplyContext(transcript: "forever")) }
        #expect(await opened.heard("opened"), "the run exists and its first token is out")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await Self.settled(task) }
        #expect(await cancelled.heard("run cancelled"), "the calling task's cancel reached run.cancel()")
    }

    @Test("a stream that ends with no terminal and no cancel is an engine failure")
    func noTerminalIsAnEngineFailure() async throws {
        let mind = SilentlyEndingMind()
        await #expect(throws: ReplyFailure.engine("the reply ended without a terminal")) {
            _ = try await mind.reply(to: ReplyContext(transcript: "anything"))
        }
    }

    // MARK: - the enums: values a caller can count

    @Test("StopReason and ReplyFailure round-trip as values")
    func enumsAreValues() {
        #expect(StopReason.complete == .complete)
        #expect(StopReason.tokenBudget != .unreported)
        #expect(ReplyFailure.busy == .busy)
        #expect(ReplyFailure.engine("a") == .engine("a"))
        #expect(ReplyFailure.engine("a") != .engine("b"))
        #expect(ReplyFailure.unavailable(.weightsAbsent) == .unavailable(.weightsAbsent))
        #expect(ReplyFailure.unavailable(.weightsAbsent) != .unavailable(.deviceCannotRun(.noGPU)))
        #expect(ReplyFailure.contextWindowExceeded != .refused)
    }

    /// AC-236's counting caller, the way Aura will count: three scripted
    /// runs fail in turn, and the failures a whole-reply caller catches are
    /// values — two of them `.busy`.
    @Test("a counting caller sees two .busy across three scripted runs (AC-236)")
    func twoBusyRunsCountAsTwo() async throws {
        let inner = ScriptedReplyGenerator.manual(replies: 3)
        var caught: [ReplyFailure] = []
        for (index, scripted) in [ReplyFailure.busy, .refused, .busy].enumerated() {
            let (mind, signals) = Self.announcing(inner)
            let task = Task { try await mind.reply(to: ReplyContext(transcript: "again")) }
            #expect(await signals.heard("opened"))
            inner.fail(reply: index, with: scripted)
            do {
                _ = try await Self.settled(task)
            } catch let failure as ReplyFailure {
                caught.append(failure)
            }
        }
        #expect(caught == [.busy, .refused, .busy])
        #expect(caught.filter { $0 == .busy }.count == 2)
    }

    @Test("an engine failure describes itself with the engine's own words")
    func engineFailureKeepsItsWords() {
        // The coordinator puts the description where the string used to
        // go (AC-242), so a scripted "brain died" must survive verbatim.
        #expect(ReplyFailure.engine("brain died").description == "brain died")
        #expect(ReplyFailure.contextWindowExceeded.description.contains("context window"))
        #expect(ReplyFailure.unavailable(.weightsAbsent).description
            == MindUnavailable.weightsAbsent.description)
    }

    /// AC-238's rule, pinned at the words: "Simulator" is said only when
    /// the verdict IS the Simulator. A real phone was once told it was one
    /// (D-101's F1) — that sentence must not be reachable from any other
    /// case.
    @Test("only .deviceCannotRun(.simulator) may say the word Simulator (AC-238)")
    func simulatorIsNamedOnlyWhenItIsTheVerdict() {
        let others: [MindUnavailable] = [
            .osBelowFloor(required: "iOS 18"),
            .deviceCannotRun(.noGPU),
            .notEnoughMemory(needed: 2_147_483_648, available: 1_073_741_824),
            .weightsAbsent,
            .installIncomplete(files: ["model.safetensors"])
        ]
        for verdict in others {
            #expect(!verdict.description.isEmpty)
            #expect(!verdict.description.localizedCaseInsensitiveContains("simulator"),
                    "\(verdict) must not blame the Simulator")
        }
        #expect(MindUnavailable.deviceCannotRun(.simulator).description.contains("Simulator"))
        #expect(MindUnavailable.notEnoughMemory(needed: 2_147_483_648, available: 1_073_741_824)
            .description.contains("2048"), "the numbers are in the sentence")
        #expect(MindUnavailable.installIncomplete(files: ["a.safetensors", "b.json"])
            .description.contains("a.safetensors"), "the short files are named")
    }
}

// MARK: - the event a test waits on (the AIRuntimeTests shape)

/// The observer `send`s a name; the test awaits that name, racing a
/// SLEEPING deadline — a suspension, never a spin. One wait per instance:
/// an `AsyncStream` has one consumer.
private struct WaitTimedOut: Error, CustomStringConvertible {
    let after: Duration
    var description: String { "the task did not settle within \(after)" }
}

private final class Signals: Sendable {
    private let stream: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation
    init() {
        (stream, emit) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }
    func send(_ name: String) { emit.yield(name) }
    /// True when `name` arrives before the deadline. The loser of the race
    /// is cancelled, never abandoned.
    func heard(_ name: String, within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [stream] in
                for await event in stream where event == name { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - the fakes this contract needs

/// Says "opened" once the inner generator has handed a run back. The
/// scripted generator records everything but announces nothing; this is
/// the one fact `reply(to:)` hides from a test, because the open happens
/// inside it.
private struct AnnouncingMind: ReplyGenerating {
    let inner: ScriptedReplyGenerator
    let signals: Signals

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        let run = try await inner.openReply(to: context)
        signals.send("opened")
        return run
    }

    // The scripted hands, forwarded, so a test reads as one conversation.
    func emit(reply index: Int, token: String) { inner.emit(reply: index, token: token) }
    func finish(reply index: Int, stop: StopReason = .complete) { inner.finish(reply: index, stop: stop) }
    func fail(reply index: Int, with failure: ReplyFailure) { inner.fail(reply: index, with: failure) }
}

/// A mind whose run yields ONE token and then never ends on its own. It
/// says when the token was handed over and when `cancel()` was called,
/// so the test waits on facts. Conformant: cancel ends the stream without
/// a terminal — the seam's contract, and the path `reply(to:)` must turn
/// into `CancellationError`.
private struct HangingMind: ReplyGenerating {
    let opened: Signals
    let cancelled: Signals

    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        HangingRun(opened: opened, cancelled: cancelled)
    }
}

private final class HangingRun: ReplyRun, Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let out: AsyncStream<ReplyUpdate>.Continuation
    private let cancelled: Signals

    init(opened: Signals, cancelled: Signals) {
        self.cancelled = cancelled
        (updates, out) = AsyncStream.makeStream(of: ReplyUpdate.self)
        out.yield(.token("first"))
        opened.send("opened")
    }

    func cancel() async {
        cancelled.send("run cancelled")
        out.finish()
    }
}

/// A mind whose run ends its stream with NO terminal and NO cancel — the
/// shape a broken generator would have. `reply(to:)` must name it.
private struct SilentlyEndingMind: ReplyGenerating {
    func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        SilentlyEndingRun()
    }
}

private struct SilentlyEndingRun: ReplyRun {
    let updates: AsyncStream<ReplyUpdate>
    init() {
        let (stream, out) = AsyncStream.makeStream(of: ReplyUpdate.self)
        updates = stream
        out.yield(.token("half a"))
        out.finish()
    }
    func cancel() async {}
}
