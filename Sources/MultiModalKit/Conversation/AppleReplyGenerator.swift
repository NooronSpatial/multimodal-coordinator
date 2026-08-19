import Foundation
import FoundationModels
import Synchronization

// MARK: - the decode seam (the TTSDecoding precedent, one seam over)

/// What one reply's SNAPSHOT STREAM looks like — ours, so a test can make
/// it misbehave on command (AC-111's revision case, which no real device
/// has been seen to produce, and AC-114's failures, which a real model
/// cannot be asked to perform).
///
/// Internal on purpose, the D-053 rule: its second implementation is a
/// test double, and public surface is earned by a second REAL one.
protocol ReplySnapshotStreaming: Sendable {
    /// Why a generation cannot START, or nil. Asked at the door, every
    /// time — a download can complete between two turns. It lives on the
    /// SEAM because it is a property of the source: the real one answers
    /// with Apple's enum, and a scripted stream has no Apple model to be
    /// unavailable — a fact the first test run proved by dying at this
    /// door on a Mac whose model was still downloading.
    var unavailable: (any Error)? { get }
    /// Opens one generation and returns its CUMULATIVE snapshots — the
    /// whole reply so far, again and again, which is the shape Apple's
    /// API actually has (SPEC §71, measured in INSTRUMENTS §22).
    func snapshots(for prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// The REAL stream: one `LanguageModelSession` per reply (D-057 F-2 = A),
/// carrying the app's told-it-is-speaking instructions (F-3 = A).
struct FoundationModelSnapshots: ReplySnapshotStreaming {
    let instructions: String?

    var unavailable: (any Error)? { AppleReplyGenerator.availability }

    func snapshots(for prompt: String) -> AsyncThrowingStream<String, any Error> {
        // The session is born INSIDE the stream's task, not in `openReply`:
        // the coordinator awaits `openReply` inline on its one serial loop,
        // and a model warm-up in that window is 4e's blocker 3 one seam
        // over — the first turn freezing the whole conversation (AC-115,
        // measured: 1839 ms cold vs ~280 ms warm).
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = instructions.map { LanguageModelSession(instructions: $0) }
                    ?? LanguageModelSession()
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                        try Task.checkCancellation()
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

// MARK: - the generator

/// THE MIND (SPEC §69, AC-112): Apple's on-device language model behind
/// the same `ReplyGenerating` seam the echo generators implement — final
/// transcript in, token stream out, and nothing else on the spine knows
/// the difference.
///
/// In core beside `AppleSpeechEngine`, by ruling (D-057 F-5 = A):
/// FoundationModels is a SYSTEM framework in an OS this library already
/// requires, so the zero-runtime-dependency vow (D-016) is untouched.
///
/// **Availability is a first-class state, not an error path** (AC-110) —
/// and it is a NECESSARY gate, not a sufficient one: a Simulator was
/// measured answering `.available` and then failing every generation
/// (INSTRUMENTS §22). So `openReply` refuses honestly when the enum says
/// no, and a generation that fails anyway becomes one honest `.failed`.
public struct AppleReplyGenerator: ReplyGenerating {

    /// Why a reply cannot start. The three cases are real states of a
    /// user's device, each needing different words on screen (AC-110).
    public enum Unavailable: Error, Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        /// A reason this library does not know yet — `UnavailableReason`
        /// is non-frozen, and pretending otherwise is a build break under
        /// warnings-as-errors the day Apple adds a case (AC-114).
        case unknown(String)
    }

    /// The app's told-it-is-speaking instruction (D-057 F-3 = A). The
    /// TEXT lives with the app — mechanism, not policy (D-027) — because
    /// a spoken reply's constraints (brief, no lists, no markdown) are
    /// the app's to phrase. Measured reason it matters: the probe's
    /// count-to-ten reply came back as a numbered markdown list.
    public let instructions: String?

    /// What a refusal SOUNDS like (D-057 F-4 = A): the model declining is
    /// an ordinary outcome, spoken briefly, completing the turn — because
    /// silence makes a refusal look like a bug. The sentence is the
    /// app's to replace; the default exists so the mechanism works.
    public let spokenRefusal: String

    let source: any ReplySnapshotStreaming

    public init(instructions: String? = nil,
                spokenRefusal: String = "I can't answer that.") {
        self.instructions = instructions
        self.spokenRefusal = spokenRefusal
        self.source = FoundationModelSnapshots(instructions: instructions)
    }

    /// The seam a test reaches through (@testable), never a caller.
    init(source: any ReplySnapshotStreaming,
         spokenRefusal: String = "I can't answer that.") {
        self.instructions = nil
        self.spokenRefusal = spokenRefusal
        self.source = source
    }

    /// The enum, read fresh every time — a download can complete between
    /// two turns, and caching "unavailable" would turn a temporary state
    /// into a permanent verdict.
    public static var availability: Unavailable? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .appleIntelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown(String(describing: reason))
            }
        }
    }

    /// Pays the model's warm-up OUTSIDE the first turn (AC-115). The cost
    /// is process-level — 1839 ms cold against ~280 ms warm on the
    /// measured iPhone — and whoever calls this at start-up keeps it out
    /// of the first felt pause. Safe to call when unavailable: it asks
    /// the enum first and does nothing.
    public func prewarm() {
        guard Self.availability == nil else { return }
        let session = instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        session.prewarm()
    }

    public func openReply(to transcript: String) async throws -> any ReplyRun {
        if let unavailable = source.unavailable { throw unavailable }
        return AppleReplyRun(source: source, prompt: transcript,
                             spokenRefusal: spokenRefusal)
    }
}

// MARK: - one reply

/// ONE thought (AC-112/AC-113): snapshots in, suffix tokens out, exactly
/// one terminal, and a dead run stays dead.
///
/// The shape is `NeuralVoiceRun`'s, minus the audio: all state behind one
/// `Mutex`, nothing suspends under it, every terminal path through ONE
/// latch — the `retire()` doctrine, adopted here on day one instead of
/// being retrofitted by a review (D-051's blocker 1 was exactly this
/// latch missing one caller).
final class AppleReplyRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let out: AsyncStream<ReplyUpdate>.Continuation

    private struct Guarded {
        var differ = SnapshotDiffer()
        var retired = false
    }
    private let state: Mutex<Guarded>
    /// The owned worker — stored so `cancel()` can stop it, ended by the
    /// stream running out. Cancelling it is the optimisation; the
    /// `retired` flag is the guarantee (the ticket doctrine, fourth use).
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(source: any ReplySnapshotStreaming, prompt: String, spokenRefusal: String) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.state = Mutex(Guarded())
        self.spokenRefusal = spokenRefusal

        let task = Task { [weak self] in
            do {
                for try await snapshot in source.snapshots(for: prompt) {
                    guard let self else { return }
                    // THE DIFF, WITH ITS TRIPWIRE (D-058), computed under
                    // one lock step.
                    //
                    // TWO GUARDS keep a dead run silent, and mutation
                    // testing measured their overlap rather than assuming
                    // it: this flag re-read, AND the stream `cancel()` has
                    // already finished — a finished AsyncStream drops every
                    // later yield. Remove the flag alone: masked, tests
                    // stay green. Remove the finish alone: three tests red.
                    // Remove both: three tests red. So the FINISH is the
                    // primary guard and this flag is the belt — kept
                    // because the finish lives in someone else's method,
                    // and the 4b precedent is to record redundancy, not
                    // pretend each line is load-bearing alone.
                    let token: String? = try self.state.withLock { s in
                        guard !s.retired else { return nil }
                        let suffix = try s.differ.advance(to: snapshot)
                        return suffix.isEmpty ? nil : suffix
                    }
                    guard let token else {
                        if self.state.withLock({ $0.retired }) { return }
                        continue
                    }
                    self.out.yield(.token(token))
                }
                self?.report(.finished)
            } catch let revision as SnapshotRevision {
                // The tripwire fired: the model rewrote text that may
                // already be in the room. One honest failure, showing
                // both sides — never the wrong words, spoken (D-058).
                self?.report(.failed("the model revised text already emitted — "
                    + "was: \"\(revision.emitted)\" now: \"\(revision.snapshot)\""))
            } catch let error as LanguageModelSession.GenerationError {
                self?.settle(generation: error)
            } catch {
                self?.report(.failed("reply generation failed: \(error)"))
            }
        }
        work.withLock { $0 = task }
    }

    /// AC-114: every case reaches an honest outcome, none is swallowed,
    /// and the enum being NON-frozen is handled rather than hoped away.
    ///
    /// Two cases complete the turn instead of failing it (D-057 F-4 = A):
    /// `guardrailViolation` and `refusal` are a supervised model DOING
    /// ITS JOB, and silence would make that look like a bug. The person
    /// hears one short sentence; the turn ends normally; the words stay
    /// out of the transcript's failure path.
    ///
    /// No mapping reads `Context.debugDescription` into a test-visible
    /// promise: it is an unlocalised string Apple may change (the spec's
    /// own warning). The CASE decides; the description only rides along
    /// in the failure text for a human to read.
    private func settle(generation error: LanguageModelSession.GenerationError) {
        switch error {
        case .guardrailViolation, .refusal:
            speakRefusalAndFinish()
        case .exceededContextWindowSize:
            report(.failed("the conversation exceeded the model's context window"))
        case .assetsUnavailable:
            // The Simulator lesson (INSTRUMENTS §22): availability can
            // vouch for assets the model manager then cannot produce.
            report(.failed("the model's assets are unavailable — "
                + "availability said yes and the model said no"))
        case .rateLimited:
            report(.failed("the system rate-limited generation"))
        case .concurrentRequests:
            report(.failed("a second request reached one session — "
                + "sessions are per-turn (D-057 F-2), so this is a coordination bug"))
        case .unsupportedGuide, .unsupportedLanguageOrLocale, .decodingFailure:
            report(.failed("generation failed: \(error.localizedDescription)"))
        @unknown default:
            report(.failed("generation failed with a case this library "
                + "does not know yet: \(error.localizedDescription)"))
        }
    }

    /// Immutable, so no lock: a `let String` crosses freely.
    private let spokenRefusal: String

    private func speakRefusalAndFinish() {
        let live = state.withLock { !$0.retired }
        guard live else { return }
        out.yield(.token(spokenRefusal))
        report(.finished)
    }

    /// EVERY terminal path ends here, and only the first one acts —
    /// the latch 4e's review had to force onto `NeuralVoiceRun` after a
    /// failed decode kept running and aborted the process.
    private func report(_ terminal: ReplyUpdate) {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            return !was
        }
        guard first else { return }
        out.yield(terminal)
        out.finish()
    }

    /// Ends the stream with NO terminal — the seam's cancel contract.
    /// The flag is raised in the same locked step that decides "was I
    /// first", so a snapshot mid-flight sees it before its next yield.
    func cancel() async {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            return !was
        }
        work.withLock { $0 }?.cancel()
        guard first else { return }
        out.finish()
    }
}
