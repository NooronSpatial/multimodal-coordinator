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

    /// The tools this mind was GIVEN (4w, F-2 = A): handed down from the
    /// generator at construction, never per reply, so the session each
    /// reply is born with carries them and the coordinator never does.
    let tools: ToolTable

    init(tools: ToolTable = .empty) {
        self.tools = tools
    }

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
                let session = self.session(instructions: instructions,
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
    /// - a seed asks for `.random(top: 50, seed:)` — TOP-K sampling: the
    ///   model picks among its 50 likeliest next tokens. (The vendor's
    ///   other mode, `.random(probabilityThreshold:seed:)`, is top-p,
    ///   also called "nucleus" sampling; this mind does not use it.)
    ///   Fifty is a conventional width and is NOT what AC-234 needs; the
    ///   SEED is — it is what makes "seed + 0.6 twice" give identical
    ///   text. The number is here so the seed has a mode to ride on, not
    ///   because it was tuned.
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
    ///
    /// **The tools ride on the session (4w, AC-223).** The vendor has ONE
    /// `transcript:` initialiser, `init(model:tools:transcript:)`, with
    /// `tools` defaulting to `[]`; it executes them itself mid-reply
    /// (F-1 = B). A mind with NO tools hands it `[]` — the vendor's own
    /// default, so the call before 4w (`init(transcript:)`) and this one
    /// build the SAME session: measured on 2026-09-11, the two sessions'
    /// transcripts are byte-identical. That is AC-227's Mac half, "no
    /// difference by construction"; the phone number is Ryad's gate
    /// (§172c).
    ///
    /// `toolDefinitions: []` on the instructions entry, ALWAYS: the
    /// vendor fills that list itself from the tools it was handed
    /// (measured the same day: `tools: [session]` with `[]` written here
    /// yields an instructions entry whose `toolDefinitions` is
    /// `["session"]`), so a definition written here would only repeat
    /// what it already knows. Also measured: writing one anyway does NOT
    /// double it — the vendor keeps one — so the reason to leave it empty
    /// is "the vendor owns that list", not a fear of a doubled prompt.
    private func session(instructions: String?,
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
        // One call for both shapes: `.empty` maps to `[]`, which is the
        // vendor's default and the pre-4w session (see above).
        return LanguageModelSession(tools: AppleToolAdapter.adapters(for: tools),
                                    transcript: Transcript(entries: entries))
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
            // The number is the floor's, stated by `Platform.appleMindFloor`,
            // and the OS check itself is `#available`'s — the compiler's
            // truth, not `ProcessInfo`'s reading of it. The platform is a
            // compile-time fact too, so it is read as one: a first cut
            // built a whole `DeviceReport.current(...)` here, which runs a
            // memory syscall, only to read its `.platform` (the 4v review).
            return belowFloor(on: platform)
        }
        return verdict(for: SystemLanguageModel.default.availability)
    }

    /// The platform this binary was built for — the same `#if` the
    /// readiness piece's live reader uses, without the rest of the probe.
    static var platform: Platform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
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

// MARK: - the test seam's thermometer

/// A thermometer that never moves — the `@testable` initialiser's
/// default (see it for why the room's is the wrong default there).
/// Internal on purpose: an app injects the real provider or its own; a
/// scripted one for tests already lives in `MultiModalKitTesting`, which
/// this module cannot import.
struct StillThermometer: ThermalStateProviding {
    var current: ThermalState { .nominal }
    func transitions() -> AsyncStream<ThermalState> { AsyncStream { $0.finish() } }
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

    /// The tools the APP granted this mind (4w, F-2 = A, D-101): handed
    /// in here, at construction, and nowhere else — the coordinator
    /// neither holds them nor passes them, so it can never learn a
    /// `switch` over them (§3's registration rule). `.empty` is every
    /// generator before 4w, and every existing call site compiles
    /// unchanged because of the default.
    public let tools: ToolTable

    /// The thermometer and the policy this mind asks AT THE DOOR (4y,
    /// AC-260, D-107 F-2 = A), injected the way the tools are: at
    /// construction, by the app, never by the coordinator (AC-265). The
    /// defaults are the shipped ones — the real thermometer, and the
    /// policy that refuses at `.critical` only, because the measured
    /// phone sat at `.serious` for whole sessions (INSTRUMENTS §26).
    ///
    /// WHAT THIS MIND DOES NOT BUILD, and why: admission
    /// (`admit(needing:)`, AC-258/259) and memory pressure (AC-261..263)
    /// are the MLX mind's. That mind allocates 2.3 GB of weights itself
    /// and owns a prefill cache it can release; the vendor's framework
    /// behind `LanguageModelSession` manages its own memory, and this
    /// library holds no allocation to admit and no cache to free. Heat
    /// and the deadline are the two rows that apply here.
    public let thermal: any ThermalStateProviding
    public let thermalPolicy: any GenerationThermalPolicy

    /// The clock a deadline is measured on (4y, AC-264, D-107 F-4 = A).
    /// An existential, like the scripted mind's, so the type stays the
    /// plain `AppleReplyGenerator` every caller names; the tests hand in
    /// a `ManualClock` and the deadline becomes a fact of the script.
    public let clock: any Clock<Duration>

    let source: any ReplySnapshotStreaming

    public init(instructions: String? = nil,
                spokenRefusal: String = "I can't answer that.",
                tools: ToolTable = .empty,
                thermal: any ThermalStateProviding = SystemThermalProvider(),
                thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(),
                clock: any Clock<Duration> = ContinuousClock()) {
        self.instructions = instructions
        self.spokenRefusal = spokenRefusal
        self.tools = tools
        self.thermal = thermal
        self.thermalPolicy = thermalPolicy
        self.clock = clock
        self.source = FoundationModelSnapshots(tools: tools)
    }

    /// The seam a test reaches through (@testable), never a caller. The
    /// scripted sources behind it cannot execute a vendor tool, so the
    /// table is recorded here for a test to read back and reaches no
    /// session — the adapter is proved on its own (`AppleToolTests`).
    ///
    /// The thermometer here defaults to a STILL one reading `.nominal`,
    /// not the room's: the 4y review caught the scripted mind defaulting
    /// to the real provider, which made every pre-4y test read this
    /// Mac's heat at every door and throw `.tooHot` on a hot one
    /// (Thermal.swift's doctrine — no test depends on a room's
    /// temperature). The policy default is the shipped one, so a test
    /// that says nothing about heat runs as it always did.
    init(source: any ReplySnapshotStreaming,
         instructions: String? = nil,
         spokenRefusal: String = "I can't answer that.",
         tools: ToolTable = .empty,
         thermal: any ThermalStateProviding = StillThermometer(),
         thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.instructions = instructions
        self.spokenRefusal = spokenRefusal
        self.tools = tools
        self.thermal = thermal
        self.thermalPolicy = thermalPolicy
        self.clock = clock
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
    ///
    /// HEAT FIRST (4y, AC-260, D-107 F-2 = A). The thermometer is read
    /// ONCE — one read, one decision, the reentrancy law's shape at a
    /// door with no await in it — and the injected policy is asked with
    /// that reading BEFORE the vendor's verdict: the heat question is the
    /// app's and costs a process-info read, the verdict wakes the vendor,
    /// and a phone too hot to generate should not wake it. A refusal is
    /// `ReplyFailure.tooHot(state)`, thrown here so no run exists and no
    /// session was born; the state rides on the case so a counting
    /// caller sees WHERE an app's stricter policy refused.
    public func openReply(to context: ReplyContext) async throws -> any ReplyRun {
        let heat = thermal.current
        guard thermalPolicy.allowGeneration(thermal: heat) else { throw ReplyFailure.tooHot(heat) }
        if let verdict = source.unavailable { throw ReplyFailure.unavailable(verdict) }
        // AC-232: the caller's per-call text over the generator's own.
        let resolved = context.options.instructions ?? instructions
        return AppleReplyRun(source: source, context: context,
                             instructions: resolved, spokenRefusal: spokenRefusal,
                             clock: clock)
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
///
/// Since 4y a THIRD way to end (AC-264, D-107 F-4 = A): the clock's. A
/// context that carries `options.deadline` arms a sleeper on the injected
/// clock, racing the stream; the clock winning ends the run
/// `.finished(.deadline)` with the text so far, through the same latch —
/// so the stream's finish and the clock's fire, however close, report
/// exactly one terminal between them.
///
/// **Who says the terminal: the WORKER, always.** The clock's firing does
/// no work of its own — it raises a flag under the lock and cancels the
/// worker (the shape AC-263 demands of the pressure handler: raise a
/// ticket, return), and the worker reports the ending on its own step
/// once its await ends, re-checking the flag (§4.1's reentrancy law).
/// The first cut let the sleeper yield the terminal itself, and the
/// race test caught what that opens: the worker computes a token under
/// the lock but yields it OUTSIDE it, so a token computed one instant
/// before the latch could land between the sleeper's terminal and its
/// finish — a token AFTER the terminal, seen once in twenty rounds with
/// the cancel removed. Cancellation is a request, not a kill (§4.1), so
/// the cancel cannot close that window; only one emitter can. With every
/// terminal in the worker's own program order, nothing can follow it.
@available(macOS 26.0, iOS 26.0, *)
final class AppleReplyRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let out: AsyncStream<ReplyUpdate>.Continuation

    private struct Guarded {
        var differ = SnapshotDiffer()
        var retired = false
        /// The clock's flag (4y, AC-264): raised by the sleeper when the
        /// deadline is reached, read by the worker in the SAME lock step
        /// as the latch when it concludes, and in the same step as the
        /// token diff — a token computed after the deadline is dropped,
        /// so "the text so far" means the text BEFORE the clock fired,
        /// not whatever the vendor managed before the cancel landed.
        var deadlineReached = false
        /// The deadline's sleeper (4y, AC-264), or nil when the context
        /// carried no deadline. Lives under the SAME lock as `retired` so
        /// the step that takes the latch also hands the sleeper out to be
        /// stopped — one decision, and the cancel happens outside the
        /// lock (§4.1's second lock rule).
        var sleeper: Task<Void, Never>?
    }
    private let state: Mutex<Guarded>
    /// The owned worker — stored so `cancel()` can stop it, ended by the
    /// stream running out. Cancelling it is the optimisation; the
    /// `retired` flag is the guarantee (the ticket doctrine, fourth use).
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(source: any ReplySnapshotStreaming,
         context: ReplyContext,
         instructions: String?,
         spokenRefusal: String,
         clock: any Clock<Duration>) {
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
                    //
                    // THE CLOCK'S FLAG is the third guard (4y, AC-264): a
                    // snapshot that arrives after the deadline was reached
                    // is not spoken. The loop goes on — not `return` — so
                    // the cancelled stream hands back its nil and the
                    // worker concludes below; `return` is the cancel()
                    // path's, where NO terminal is owed.
                    let token: String? = try self.state.withLock { guarded in
                        guard !guarded.retired, !guarded.deadlineReached else { return nil }
                        let suffix = try guarded.differ.advance(to: snapshot)
                        return suffix.isEmpty ? nil : suffix
                    }
                    guard let token else {
                        if self.state.withLock({ $0.retired }) { return }
                        continue
                    }
                    self.out.yield(.token(token))
                }
                // The stream ran out — the vendor's own end, or the end
                // the deadline's cancel gave it. `concludeStream` reads
                // which in the same lock step as the latch.
                self?.concludeStream()
            } catch is CancellationError {
                // The worker was cancelled while parked on the stream —
                // the deadline's doing (`expire`) or a `cancel()`; the
                // latch tells them apart and the second owes no terminal.
                self?.concludeStream()
            } catch let revision as SnapshotRevision {
                // The tripwire fired: the model rewrote text that may
                // already be in the room. One honest failure, showing
                // both sides — never the wrong words, spoken (D-058).
                self?.report(.failed(.engine("the model revised text already emitted — "
                    + "was: \"\(revision.emitted)\" now: \"\(revision.snapshot)\"")))
            } catch let error as LanguageModelSession.GenerationError {
                self?.settle(generation: error)
            } catch let error as LanguageModelSession.ToolCallError {
                // A tool the model called THREW (4w, AC-225). The adapter
                // let the throw through, the vendor ended the stream with
                // this error, and the run ends the way the scripted mind's
                // `.failsReply` does: one `.failed(.engine(_))` carrying
                // the SAME `ToolCallFailure` sentence every mind writes.
                // This ending is the INTERIM one — whether the adapter
                // should catch instead and let the model speak (the MLX
                // run's ending) is an open fork, Ryad's, written up at
                // `AppleReplyRun.toolFailure`. This arm stays under either
                // ruling: the vendor can raise the error on its own.
                self?.report(.failed(.engine(Self.toolFailure(from: error).description)))
            } catch {
                self?.report(.failed(.engine("reply generation failed: \(error)")))
            }
        }
        work.withLock { $0 = task }
        // The clock is armed AFTER the worker is stored, so a deadline
        // that fires always finds a worker to cancel.
        if let deadline = context.options.deadline {
            arm(deadline, on: clock)
        }
    }

    /// A run nobody holds sleeps for nobody: the sleeper captures `self`
    /// weakly (like the worker), so a dropped run is freed at once — and
    /// its clock is stopped here rather than left parked on a
    /// `ManualClock` until a deadline nobody will read.
    deinit {
        state.withLock { $0.sleeper }?.cancel()
    }

    // MARK: the clock's ending (4y, AC-264, D-107 F-4 = A)

    /// Sleeps `deadline` on the injected clock, racing the stream. When
    /// the clock wins, `expire()` flags the run and stops its worker, and
    /// the worker ends the run; when the stream wins, the
    /// terminal path stops this sleeper (`retire()`), so the clock is
    /// never left holding a dead reply — a sleep that is CANCELLED ends
    /// nothing, because the clock was stopped, not reached. Unstructured
    /// for the worker's reason: it must outlive `init`, and this class
    /// owns and stops it.
    ///
    /// THE REENTRANCY LAW at the arming: the worker may have ended the
    /// reply BEFORE this task was stored (a source that finishes at once
    /// does), and `retire()` found no sleeper to stop. So the store and
    /// the re-check are one lock step, and a sleeper stored into an
    /// already-retired run is cancelled on the spot.
    private func arm(_ deadline: Duration, on clock: any Clock<Duration>) {
        let sleeper = Task { [weak self] in
            do {
                try await clock.sleep(for: deadline)
            } catch {
                return   // stopped, not reached
            }
            self?.expire()
        }
        let alreadyEnded = state.withLock { guarded -> Bool in
            guarded.sleeper = sleeper
            return guarded.retired
        }
        if alreadyEnded { sleeper.cancel() }
    }

    /// The deadline was reached: the run will end `.finished(.deadline)`
    /// with what was said so far — an ENDING, like `.tokenBudget`, never
    /// a failure (F-4 = A; D-104 already ruled an ending is not one).
    ///
    /// THIS DOES NO WORK — it raises the flag and cancels the worker,
    /// the way AC-263 wants the pressure handler shaped: the WORKER says
    /// the terminal, on its own step, when the cancelled stream hands it
    /// nil (`concludeStream`). See the class comment for the token-
    /// after-terminal race a sleeper that spoke for itself opened. The
    /// flag is raised only on a run that is still alive: a run already
    /// retired (a `cancel()`, a failure) owes the clock nothing, and its
    /// worker is already stopped.
    ///
    /// WHAT THIS MIND CAN DO about the vendor's compute: cancel the
    /// stream task. The vendor's session has no "free the prefill" call
    /// this library owns — its memory is the framework's, managed behind
    /// `LanguageModelSession` — so the cancel, which reaches the
    /// session's `streamResponse` through the stream's `onTermination`,
    /// is the whole of the release. The MLX mind, which owns its cache,
    /// frees it explicitly; this one cannot and does not pretend to.
    private func expire() {
        let alive = state.withLock { guarded -> Bool in
            guard !guarded.retired else { return false }
            guarded.deadlineReached = true
            return true
        }
        guard alive else { return }
        work.withLock { $0 }?.cancel()
    }

    /// The stream is over, one way or the other, and the worker asks the
    /// latch WHY in the same lock step it takes it: the clock's flag up
    /// means `.deadline`; down means the vendor's own silent end —
    /// `.unreported` (AC-235: the vendor has no stop reason to read; the
    /// SDK's interface has no `finishReason` anywhere). Not first means a
    /// `cancel()` got here before, and no terminal is owed.
    private func concludeStream() {
        let (first, sleeper, clockWon) = retire()
        sleeper?.cancel()
        guard first else { return }
        out.yield(.finished(clockWon ? .deadline : .unreported))
        out.finish()
    }

    /// AC-114, and since 4v AC-236's table (SPEC §175/3): every case
    /// reaches an honest outcome, none is swallowed, every failure is a
    /// case a caller can count, and the enum being NON-frozen is handled
    /// rather than hoped away.
    ///
    /// Two cases END the turn instead of failing it (D-057 F-4 = A, and
    /// since D-104 with a name): `guardrailViolation` and `refusal` are a
    /// supervised model DOING ITS JOB, and silence would make that look
    /// like a bug. The person hears one short sentence; the turn ends
    /// normally as `.finished(.refused)`; the words stay out of the
    /// transcript's failure path.
    ///
    /// No mapping reads `Context.debugDescription` into a test-visible
    /// promise: it is an unlocalised string Apple may change (the spec's
    /// own warning). The CASE decides; the description only rides along
    /// in the failure text for a human to read.
    private func settle(generation error: LanguageModelSession.GenerationError) {
        switch error {
        case .guardrailViolation, .refusal:
            // RULED (D-104, SPEC §178 F-7 = C): a refusal is how a reply
            // ENDS. Both vendor cases land on the same one row.
            speakRefusalAndFinish()
        case .exceededContextWindowSize:
            report(.failed(.contextWindowExceeded))
        case .assetsUnavailable:
            // The Simulator lesson (INSTRUMENTS §22): availability can
            // vouch for assets the model manager then cannot produce. The
            // table's row is `.unavailable` (SPEC §175/3), and the verdict
            // inside it is `.unknown` with the vendor's own word: the
            // vendor said "assets unavailable" and nothing about WHY. It
            // is not `.modelDownloading` — that sentence promises "try
            // later", and on the very Simulator that taught this lesson
            // the assets never arrive (the 4v review's finding).
            report(.failed(.unavailable(.unknown(Self.assetsUnavailableWords))))
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
        // AN EMPTY SENTENCE IS NOT A TOKEN (4v review, D-104). Every
        // other emit path in this file drops empty pieces — the
        // detokenizer yields "" mid-character — and this one did not, so
        // an app that configured `spokenRefusal: ""` produced
        // `.token("")` and a person who heard nothing while the caller
        // read `.refused`. That silence is the exact shape D-057 F-4 = A
        // exists to prevent. The app may still choose to say nothing;
        // what it may not do is make the stream lie about speech.
        if !spokenRefusal.isEmpty { out.yield(.token(spokenRefusal)) }
        // RULED: `.refused` (D-104, SPEC §178 F-7 = C).
        //
        // THE VOICE IS UNCHANGED. The person still hears the app's
        // sentence, spoken by the yield above — D-057 F-4 = A is kept
        // exactly, because silence makes a refusal look like a bug. What
        // changed is that the ENDING now says why: a text caller reads
        // `stop == .refused` and can COUNT refusals, where before it saw
        // `.unreported` and could not tell a refusal from an ordinary
        // answer. `reply(to:)` still RETURNS here; it does not throw,
        // because a refusal is an outcome and not an error.
        //
        // The history this line carries: a first cut of this piece wrote
        // `.complete` — F-7 option A's answer — and the review caught it
        // as a fork ruled by the agent. It was reverted to `.unreported`
        // and left for Ryad. This value is his ruling, not an agent's.
        report(.finished(.refused))
    }

    /// The pre-4v words for the assets row, kept verbatim so the test
    /// that pinned them still reads them and a screen says the same
    /// thing it said before the failures were typed.
    static let assetsUnavailableWords =
        "its assets are unavailable — availability said yes and the model said no"

    /// EVERY terminal path ends here, and only the first one acts —
    /// the latch 4e's review had to force onto `NeuralVoiceRun` after a
    /// failed decode kept running and aborted the process.
    private func report(_ terminal: ReplyUpdate) {
        let (first, sleeper, _) = retire()
        // The stream ended: the deadline's sleeper is released BEFORE the
        // terminal goes out, so a test that reads the clock at "ended"
        // finds it empty — and a `ManualClock` never holds a dead reply.
        sleeper?.cancel()
        guard first else { return }
        out.yield(terminal)
        out.finish()
    }

    /// THE LATCH, one lock step (4y widened it from a flag to a triple):
    /// raises `retired`, answers "was I first", hands out the deadline's
    /// sleeper so the caller can stop it OUTSIDE the lock, and reads the
    /// clock's flag so `concludeStream` names the ending in the SAME step
    /// it takes the terminal — a flag raised one instant after the latch
    /// is a clock that lost, and reads as such. Every ending — the
    /// stream's, the clock's (through the worker), a cancel — passes
    /// here, which is why exactly one terminal is ever reported: two
    /// endings that happen "at once" take the lock in some order, and
    /// only the first sees `!was`.
    private func retire() -> (first: Bool, sleeper: Task<Void, Never>?, deadlineReached: Bool) {
        state.withLock { guarded in
            let was = guarded.retired
            guarded.retired = true
            return (!was, guarded.sleeper, guarded.deadlineReached)
        }
    }

    /// Ends the stream with NO terminal — the seam's cancel contract.
    /// The flag is raised in the same locked step that decides "was I
    /// first", so a snapshot mid-flight sees it before its next yield.
    /// The deadline's sleeper is stopped too (4y): a cancelled reply must
    /// not leave its clock behind.
    func cancel() async {
        let (first, sleeper, _) = retire()
        work.withLock { $0 }?.cancel()
        sleeper?.cancel()
        guard first else { return }
        out.finish()
    }
}
