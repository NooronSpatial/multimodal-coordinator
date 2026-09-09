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
    /// with the vendor's enum mapped onto the contract's verdict (4v,
    /// SPEC §175/5), and a scripted stream has no vendor model to be
    /// unavailable — a fact the first test run proved by dying at this
    /// door on a Mac whose model was still downloading.
    var unavailable: MindUnavailable? { get }
    /// Opens one generation and returns its CUMULATIVE snapshots — the
    /// whole reply so far, again and again, which is the shape Apple's
    /// API actually has (SPEC §71, measured in INSTRUMENTS §22).
    ///
    /// `instructions` are the RESOLVED ones for this call (AC-232: the
    /// caller's per-call text over the generator's own), passed beside
    /// the context rather than read from it so a scripted source can
    /// record exactly what the generator decided; the sampling and the
    /// budget ride on `context.options` and the real source maps them.
    func snapshots(for context: ReplyContext,
                   instructions: String?) -> AsyncThrowingStream<String, any Error>
}

/// The REAL stream: one `LanguageModelSession` per reply (D-057 F-2 = A),
/// carrying the instructions the generator resolved (F-3 = A, and since
/// 4v the caller's per-call ones when given — AC-232).
@available(macOS 26.0, iOS 26.0, *)
struct FoundationModelSnapshots: ReplySnapshotStreaming {

    var unavailable: MindUnavailable? { AppleMind.readiness() }

    func snapshots(for context: ReplyContext,
                   instructions: String?) -> AsyncThrowingStream<String, any Error> {
        // The session is born INSIDE the stream's task, not in `openReply`:
        // the coordinator awaits `openReply` inline on its one serial loop,
        // and a model warm-up in that window is 4e's blocker 3 one seam
        // over — the first turn freezing the whole conversation (AC-115,
        // measured: 1839 ms cold vs ~280 ms warm).
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = Self.session(instructions: instructions,
                                           history: context.history)
                let options = Self.vendorOptions(for: context.options)
                do {
                    for try await snapshot in session.streamResponse(to: context.transcript,
                                                                     options: options) {
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

    /// The caller's levers, in the vendor's words (AC-233, AC-234). Pure
    /// and static so a test can read what a given `GenerationOptions`
    /// becomes without a model in the room.
    ///
    /// - the budget is ALWAYS set: `maxTokens ?? 1024` (F-6 = A — the
    ///   cap is a ceiling, not a target). Before 4v the Apple mind set no
    ///   cap at all.
    /// - temperature `0` asks for `.greedy` — the vendor's own name for
    ///   "no randomness", so the same question twice gives the same bytes
    ///   (the probe AC-234 measures). Greedy has no randomness to seed,
    ///   so it wins over a seed given beside it.
    /// - a seed asks for `.random(top: 50, seed:)`. Top-50 is a
    ///   conventional nucleus for top-k sampling and is NOT what AC-234
    ///   needs; the SEED is — it is what makes "seed + 0.6 twice" give
    ///   identical text. The number is here so the seed has a mode to
    ///   ride on, not because it was tuned.
    /// - `temperature` is passed when given, widened `Float → Double`
    ///   (the vendor's type). `nil` everything else leaves the vendor's
    ///   defaults untouched: `GenerationOptions()` IS the default value
    ///   of `streamResponse(options:)`, so a field left `nil` here is the
    ///   same as not asking.
    static func vendorOptions(for options: GenerationOptions) -> FoundationModels.GenerationOptions {
        var sampling: FoundationModels.GenerationOptions.SamplingMode?
        if options.temperature == 0 {
            sampling = .greedy
        } else if let seed = options.seed {
            sampling = .random(top: Self.seededTopK, seed: seed)
        }
        return FoundationModels.GenerationOptions(
            sampling: sampling,
            temperature: options.temperature.map(Double.init),
            maximumResponseTokens: options.maxTokens ?? AppleReplyGenerator.defaultTokenBudget)
    }

    /// The `top` of `.random(top:seed:)` when a seed is given — see
    /// `vendorOptions`: a conventional value, not a measured one.
    static let seededTopK = 50

    /// One session, built from a transcript WE assembled (4r, F-1 = B).
    ///
    /// Apple's native shape for "what was said before" is
    /// `Transcript.Entry`, so the history is mapped onto it rather than
    /// flattened into the prompt — a flattened past is a past the model
    /// has to parse, and it is exactly the loss the seam was widened to
    /// avoid.
    ///
    /// **Still one session per turn (D-057 F-2 = A).** The session is not
    /// kept between replies and carries no state we did not put in it;
    /// only the entries it is born with have grown.
    ///
    /// The current thought is deliberately NOT an entry here —
    /// `streamResponse(to:)` supplies it — or the model would be shown the
    /// question twice.
    private static func session(instructions: String?,
                                history: [ConversationTurn]) -> LanguageModelSession {
        var entries: [Transcript.Entry] = []
        if let instructions {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: [])))
        }
        for turn in history {
            entries.append(.prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: turn.said))])))
            entries.append(.response(Transcript.Response(
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(
                    content: turn.replied + (turn.interrupted ? "…" : "")))])))
        }
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }
}

// MARK: - the door (SPEC §175/5 — the Apple verdicts, typed)

/// The Apple mind's READINESS, askable on ANY operating system. The
/// generator itself is `@available(macOS 26, iOS 26)`, so a phone one
/// release too old cannot even name it — and could never be told WHY.
/// This enum is not gated: below the floor it answers
/// `.osBelowFloor(required: "iOS 26")` from the same `Platform` table
/// the readiness piece uses (`appleMindFloor`); on the floor it maps the
/// vendor's enum onto the contract's verdict, so a screen switches over
/// ONE type for every mind (AC-238's wiring).
public enum AppleMind {

    /// Why the Apple mind cannot run here — or `nil`, meaning it can.
    /// Read FRESH every time: a download can complete between two turns,
    /// and caching "unavailable" would turn a temporary state into a
    /// permanent verdict.
    public static func readiness() -> MindUnavailable? {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            // The report is read only for its PLATFORM — the number is the
            // floor's, stated by `Platform.appleMindFloor`, and the OS
            // check itself is `#available`'s, which is the compiler's
            // truth, not `ProcessInfo`'s reading of it.
            let report = DeviceReport.current(gpu: .available, install: .installed)
            return belowFloor(on: report.platform)
        }
        return verdict(for: SystemLanguageModel.default.availability)
    }

    /// The below-floor verdict for a platform — pure, so a Mac's test can
    /// read a phone's sentence.
    static func belowFloor(on platform: Platform) -> MindUnavailable {
        .osBelowFloor(required: "\(platform.name) \(platform.appleMindFloor)")
    }

    /// The vendor's enum, in the contract's words. Pure, so a test can
    /// hand it every case by hand; the `@unknown default` is the only
    /// honest answer to a NON-frozen `UnavailableReason` (AC-114).
    @available(macOS 26.0, iOS 26.0, *)
    static func verdict(for availability: SystemLanguageModel.Availability) -> MindUnavailable? {
        switch availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceCannotRun(.notEligible)
            case .appleIntelligenceNotEnabled: return .featureDisabled("Apple Intelligence")
            case .modelNotReady: return .modelDownloading
            @unknown default: return .unknown(String(describing: reason))
            }
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
@available(macOS 26.0, iOS 26.0, *)
public struct AppleReplyGenerator: ReplyGenerating {

    /// The budget when the caller sets none (F-6 = A: 1024 for everyone,
    /// a ceiling, not a target). Before 4v this mind set no cap at all.
    public static let defaultTokenBudget = 1024

    /// The app's told-it-is-speaking instruction (D-057 F-3 = A). The
    /// TEXT lives with the app — mechanism, not policy (D-027) — because
    /// a spoken reply's constraints (brief, no lists, no markdown) are
    /// the app's to phrase. Measured reason it matters: the probe's
    /// count-to-ten reply came back as a numbered markdown list.
    ///
    /// Since 4v these are the FALLBACK: a call whose
    /// `options.instructions` is set uses that text instead (AC-232).
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
        self.source = FoundationModelSnapshots()
    }

    /// The seam a test reaches through (@testable), never a caller.
    init(source: any ReplySnapshotStreaming,
         instructions: String? = nil,
         spokenRefusal: String = "I can't answer that.") {
        self.instructions = instructions
        self.spokenRefusal = spokenRefusal
        self.source = source
    }

    /// The verdict, read fresh every time — `AppleMind.readiness()` under
    /// the name the demo's caption already reads. Kept so the screen and
    /// a mid-session refusal keep speaking the SAME sentence (the 4f
    /// review's rule); the ungated door is `AppleMind.readiness()`.
    public static var availability: MindUnavailable? { AppleMind.readiness() }

    /// Pays the model's warm-up OUTSIDE the first turn (AC-115). The cost
    /// is process-level — 1839 ms cold against ~280 ms warm on the
    /// measured iPhone — and whoever calls this at start-up keeps it out
    /// of the first felt pause. Safe to call when unavailable: it asks
    /// the enum first and does nothing.
    public func prewarm() {
        guard AppleMind.readiness() == nil else { return }
        let session = instructions.map { LanguageModelSession(instructions: $0) }
            ?? LanguageModelSession()
        session.prewarm()
    }

    /// The door. The verdict is asked HERE, never cached (see
    /// `ReplySnapshotStreaming.unavailable`), and thrown as the contract's
    /// `ReplyFailure.unavailable` so a caller catches one type for every
    /// mind (SPEC §175/5).
    public func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        if let verdict = source.unavailable { throw ReplyFailure.unavailable(verdict) }
        // AC-232: the caller's per-call text over the generator's own.
        let resolved = context.options.instructions ?? instructions
        return AppleReplyRun(source: source, context: context,
                             instructions: resolved, spokenRefusal: spokenRefusal)
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
@available(macOS 26.0, iOS 26.0, *)
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

    init(source: any ReplySnapshotStreaming,
         context: ReplyContext,
         instructions: String?,
         spokenRefusal: String) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.state = Mutex(Guarded())
        self.spokenRefusal = spokenRefusal

        let task = Task { [weak self] in
            do {
                for try await snapshot in source.snapshots(for: context, instructions: instructions) {
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
                    let token: String? = try self.state.withLock { guarded in
                        guard !guarded.retired else { return nil }
                        let suffix = try guarded.differ.advance(to: snapshot)
                        return suffix.isEmpty ? nil : suffix
                    }
                    guard let token else {
                        if self.state.withLock({ $0.retired }) { return }
                        continue
                    }
                    self.out.yield(.token(token))
                }
                // `.unreported`: Apple's stream ends without saying why
                // (AC-235 — the vendor has no stop reason to read; the
                // SDK's interface has no `finishReason` anywhere).
                self?.report(.finished(.unreported))
            } catch let revision as SnapshotRevision {
                // The tripwire fired: the model rewrote text that may
                // already be in the room. One honest failure, showing
                // both sides — never the wrong words, spoken (D-058).
                self?.report(.failed(.engine("the model revised text already emitted — "
                    + "was: \"\(revision.emitted)\" now: \"\(revision.snapshot)\"")))
            } catch let error as LanguageModelSession.GenerationError {
                self?.settle(generation: error)
            } catch {
                self?.report(.failed(.engine("reply generation failed: \(error)")))
            }
        }
        work.withLock { $0 = task }
    }

    /// AC-114, and since 4v AC-236's table (SPEC §175/3): every case
    /// reaches an honest outcome, none is swallowed, every failure is a
    /// case a caller can count, and the enum being NON-frozen is handled
    /// rather than hoped away.
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
            // F-7 pending (SPEC §178): whether a refusal is a spoken
            // completion, a failure, or a stop reason is Ryad's to rule.
            // Until then, today's behaviour holds.
            speakRefusalAndFinish()
        case .exceededContextWindowSize:
            report(.failed(.contextWindowExceeded))
        case .assetsUnavailable:
            // The Simulator lesson (INSTRUMENTS §22): availability can
            // vouch for assets the model manager then cannot produce. The
            // contract's word for "the model is not here yet" is the
            // download's verdict — recoverable, ask again later.
            report(.failed(.unavailable(.modelDownloading)))
        case .unsupportedLanguageOrLocale:
            report(.failed(.unsupportedLanguage))
        case .rateLimited, .concurrentRequests:
            // Both are "the engine is serving another request" to a
            // caller that counts. `concurrentRequests` is ALSO a
            // coordination bug on our side — sessions are per-turn
            // (D-057 F-2), so a second request on one session should be
            // impossible — but the caller's remedy is the same: later.
            report(.failed(.busy))
        case .unsupportedGuide, .decodingFailure:
            // No guide is ever sent (the mind returns text, §176) and a
            // decoding failure has no caller-side remedy: the honest rest.
            report(.failed(.engine("generation failed: \(error.localizedDescription)")))
        @unknown default:
            report(.failed(.engine("generation failed with a case this library "
                + "does not know yet: \(error.localizedDescription)")))
        }
    }

    /// Immutable, so no lock: a `let String` crosses freely.
    private let spokenRefusal: String

    private func speakRefusalAndFinish() {
        let live = state.withLock { !$0.retired }
        guard live else { return }
        out.yield(.token(spokenRefusal))
        // `.complete`, not `.unreported`: a spoken refusal is a turn the
        // model ENDED, on purpose — the one stop reason the vendor's
        // silent API lets this mind state truthfully. F-7 pending.
        report(.finished(.complete))
    }

    /// EVERY terminal path ends here, and only the first one acts —
    /// the latch 4e's review had to force onto `NeuralVoiceRun` after a
    /// failed decode kept running and aborted the process.
    private func report(_ terminal: ReplyUpdate) {
        let first = state.withLock { guarded -> Bool in
            let was = guarded.retired
            guarded.retired = true
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
        let first = state.withLock { guarded -> Bool in
            let was = guarded.retired
            guarded.retired = true
            return !was
        }
        work.withLock { $0 }?.cancel()
        guard first else { return }
        out.finish()
    }
}
