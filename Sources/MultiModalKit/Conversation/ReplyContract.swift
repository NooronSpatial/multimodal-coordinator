// THE MIND'S TEXT CONTRACT — the values that cross the reply seam
// (4v, SPEC §174–175, D-103).
//
// Before 4v the seam carried a transcript in and a string-or-nothing
// out: `.finished` said nothing about WHY, `.failed(String)` was a
// sentence no caller could switch over, and every lever the vendor
// offers (instructions, budget, sampling) was fixed at `init`. The
// caller that ships first is text-in, text-out, one whole reply
// (D-101) — so the seam learned to carry what it needs, and nothing
// the voice path did not already do.
//
// Lives beside `TurnCoordination.swift` rather than in it because that
// file is the seam's SHAPE (the protocols) and this one is its
// VOCABULARY (the values); one file for both would be a type-body-length
// argument with the linter, not a design.

// MARK: - what the caller may ask for (F-1 = A)

/// The levers a caller may set PER CALL. `nil` on every field means "the
/// generator's own" — so `.init()` is exactly the behaviour every call
/// site had before 4v (AC-231), and the coordinator passes it unchanged.
///
/// HONEST STAGING (D-103's build order — the seam first, then the
/// organs): this piece makes the levers TRAVEL — the context carries
/// them and the scripted mind records them. The real minds start
/// READING them with AC-232 (instructions), AC-233 (budget) and AC-234
/// (sampling); until those land, a value set here is carried, not yet
/// honoured, and the minds keep their `init`-time settings.
public struct GenerationOptions: Sendable, Equatable {
    /// Replaces the generator's own instructions for this call. `nil`
    /// keeps them. The TEXT is the caller's (D-027, D-057 F-3): this
    /// library ships no prompt.
    public var instructions: String?
    /// The token budget for this call; `nil` is the generator's default
    /// (1024 since F-6 = A — a ceiling, not a target).
    public var maxTokens: Int?
    /// Sampling temperature; `nil` is the vendor's default. `0` asks for
    /// the greedy path where the vendor has one (AC-234).
    public var temperature: Float?
    /// A sampling seed; `nil` leaves the vendor's randomness alone.
    public var seed: UInt64?

    public init(instructions: String? = nil,
                maxTokens: Int? = nil,
                temperature: Float? = nil,
                seed: UInt64? = nil) {
        self.instructions = instructions
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
    }
}

// MARK: - why a reply ended (F-2 = A)

/// Why a reply's stream ended WELL. One terminal, one meaning: the
/// reason rides on `.finished`, so the voice path can learn it was cut
/// by the cap without a second event to order against the first.
public enum StopReason: Sendable, Equatable {
    /// The model ended its own turn.
    case complete
    /// The token budget cut the reply short. A caller that asked for a
    /// whole document should know it did not get one.
    case tokenBudget
    /// The engine cannot say — the honest value for a mind whose API
    /// reports no reason, never a guess.
    case unreported
    /// The model DECLINED, and said so aloud (D-104, F-7 = C).
    ///
    /// Two signed things could not both be true. D-057 F-4 = A says the
    /// Apple mind SPEAKS a short refusal and completes the turn, because
    /// silence makes a refusal look like a bug; SPEC §175/3 listed
    /// `.refused` as a `ReplyFailure`, which is a turn ending with
    /// nothing said. The ruling dissolves it: a refusal is how a reply
    /// ENDS. The person still hears the sentence — voice is untouched —
    /// and a text caller reads the stop reason and can COUNT refusals
    /// without catching an error for something that is not one.
    ///
    /// The sentence a person hears is the APP's (`spokenRefusal`); this
    /// library ships no words of its own (D-027, D-057 F-3) and this
    /// case only reports WHY the reply ended. Not every mind can say it:
    /// the Apple mind reports it for the vendor's `guardrailViolation`
    /// and `refusal`, and the MLX mind never does, because Qwen gives no
    /// refusal signal — which is what `.unreported` is for.
    case refused
}

// MARK: - why a reply ended badly (F-3 = A)

/// Why a reply FAILED. Every case is `Equatable` so a caller can count —
/// two `.busy` in a row is a fact, where two strings were only prose.
/// `.engine(String)` is the honest catch-all: the words are still there
/// for a screen, and the case is there for a switch.
public enum ReplyFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The conversation no longer fits the model's window.
    case contextWindowExceeded
    /// The mind cannot run here at all — see the verdict.
    case unavailable(MindUnavailable)
    // NO `.refused` here (D-104, F-7 = C). A guardrail or the model
    // declining is not a FAILURE: the mind speaks its refusal sentence
    // and the reply ENDS, so the case lives on `StopReason` instead.
    // Putting it here made a turn that ends with nothing said, which
    // reverses D-057 F-4 = A — the ruling that exists because silence
    // makes a refusal look like a bug.
    /// The model does not speak the language it was asked in.
    case unsupportedLanguage
    /// The engine is serving another request — rate limit or concurrency.
    case busy
    /// Everything the engine says that this library cannot type yet.
    case engine(String)

    public var description: String {
        switch self {
        case .contextWindowExceeded:
            "the conversation exceeded the model's context window"
        case .unavailable(let verdict):
            verdict.description
        case .unsupportedLanguage:
            "the model does not support this language"
        case .busy:
            "the model is busy with another request"
        case .engine(let words):
            // VERBATIM, no prefix: the coordinator puts this description
            // where the bare string went (AC-242), so a fake's "brain
            // died" reaches the turn's failure untouched, and every
            // pre-4v test keeps its meaning.
            words
        }
    }
}

// MARK: - the readiness verdict (F-5 = A, the shell; the function is AC-238's piece)

/// Why the mind cannot run on THIS device — a typed verdict, computed
/// later from a `DeviceReport` a test can write by hand. Only the enum
/// and its words live here; the pure function that produces it hangs on
/// the readiness piece.
///
/// THE WORDING RULE (AC-238): a real phone was once told it was the
/// Simulator (D-101's F1 — the demo's three strings, one of them wrong on
/// hardware). So the word "Simulator" appears in exactly one rendering,
/// the one whose verdict IS the Simulator, and a test reads every other
/// case to make sure it never says it.
public enum MindUnavailable: Error, Sendable, Equatable, CustomStringConvertible {
    /// What about the device rules the mind out.
    public enum DeviceLimit: Sendable, Equatable {
        /// The iOS Simulator's Metal driver refuses the shared-memory
        /// heap MLX asks for (D-061, INSTRUMENTS §24 stage 3).
        case simulator
        /// No GPU the runtime can use.
        case noGPU
        /// The platform's own eligibility check said no — the Apple
        /// mind's `deviceNotEligible`, which the vendor decides and this
        /// library only relays (SPEC §175/5, the Apple verdicts).
        case notEligible
    }

    /// The operating system is older than the mind's floor.
    case osBelowFloor(required: String)
    /// The hardware cannot host the runtime, whatever is installed.
    case deviceCannotRun(DeviceLimit)
    /// Loading the weights would not fit. Both numbers are BYTES.
    case notEnoughMemory(needed: Int, available: Int)
    /// Nothing is installed. Recoverable — download and ask again.
    case weightsAbsent
    /// Files are missing or shorter than the manifest says (AC-239).
    case installIncomplete(files: [String])

    // The Apple mind's verdicts (SPEC §175/5). Before 4v they were a
    // second enum on the generator with the same three sentences; now
    // one enum speaks for every mind, so a screen has one type to switch
    // over. The words are the ones the 4f review pinned, unchanged.

    /// A system feature the model needs is switched off. The string
    /// NAMES the feature, so the sentence tells the person what to
    /// switch on ("Apple Intelligence" for the Apple mind).
    case featureDisabled(String)
    /// The system is still fetching the model. Recoverable — the same
    /// question later gets a different answer, which is why no door
    /// caches it.
    case modelDownloading
    /// A reason this library cannot name. Two sources: the vendor's
    /// reason enum is NON-frozen, and pretending otherwise is a build
    /// break under warnings-as-errors the day a case is added (AC-114's
    /// lesson); and a generation that fails with "assets unavailable"
    /// after availability said yes (INSTRUMENTS §22) — the vendor states
    /// no cause, so this library claims none. The string carries
    /// whatever the vendor said.
    case unknown(String)

    public var description: String {
        switch self {
        case .osBelowFloor(let required):
            "this device's operating system is older than the model needs — \(required) or later"
        case .deviceCannotRun(.simulator):
            "the Simulator cannot run the on-device model — its Metal driver refuses "
            + "the shared-memory heap the model needs"
        case .deviceCannotRun(.noGPU):
            "this device has no GPU the on-device model can use"
        case .deviceCannotRun(.notEligible):
            "this device cannot run the on-device model"
        case .featureDisabled(let feature):
            "\(feature) is switched off in Settings"
        case .modelDownloading:
            "the on-device model is still downloading — try later"
        case .unknown(let reason):
            "the model is unavailable: \(reason)"
        case .notEnoughMemory(let needed, let available):
            "not enough memory for the on-device model — it needs \(Self.megabytes(needed)) MB "
            + "and \(Self.megabytes(available)) MB are free"
        case .weightsAbsent:
            "the on-device model is not installed yet"
        case .installIncomplete(let files):
            "the on-device model's install is incomplete — "
            + "\(files.count) file(s) missing or short: \(files.joined(separator: ", "))"
        }
    }

    /// Whole megabytes, for a sentence a person reads. The bytes stay on
    /// the case for a caller that computes.
    private static func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }
}

// MARK: - the whole reply (F-4 = A)

/// One complete reply: the text, and why it stopped there.
public struct Reply: Sendable, Equatable {
    public let text: String
    public let stop: StopReason

    public init(text: String, stop: StopReason) {
        self.text = text
        self.stop = stop
    }
}

/// The whole reply, written ONCE over `openReply` (F-4 = A): true for
/// every mind and every fake, so a text caller and the voice coordinator
/// drain the same stream and can never drift apart.
extension ReplyGenerating {
    /// Opens a reply, drains it, and hands back the text and why it
    /// stopped (AC-237). A `.failed` terminal is THROWN as its
    /// `ReplyFailure`. Cancelling the calling task asks the run to stop
    /// and throws `CancellationError` — after `run.cancel()` has returned,
    /// so nothing the run owns outlives the call.
    ///
    /// STRUCTURED, and deliberately plain: no child task, no watcher, no
    /// lock. `ReplyRun.updates` is an `AsyncStream`, and an `AsyncStream`'s
    /// `next()` is cancellation-aware — it ends the iteration when the
    /// iterating task is cancelled, and drops every yield after that. So
    /// the caller's cancel is observed exactly where this call waits, and
    /// a DEFIANT run that keeps emitting is emitting into a stream that
    /// no longer listens. The ticket doctrine, one seam up: the task's
    /// own cancellation flag is the ticket, re-checked before every
    /// update, so an update already in the buffer when the cancel landed
    /// cannot become a result either.
    public func reply(to context: ReplyContext) async throws -> Reply {
        let run = try await openReply(to: context)
        do {
            return try await drainWholeReply(run)
        } catch is CancellationError {
            // The run is told, and this call waits for it: a conformant
            // run ends its stream without a terminal (`ReplyRun.cancel`);
            // a defiant one is already unheard.
            await run.cancel()
            throw CancellationError()
        }
    }
}

/// Concatenates tokens until the terminal. `CancellationError` is the
/// only way out that is not the run's own doing.
private func drainWholeReply(_ run: any ReplyRun) async throws -> Reply {
    var text = ""
    for await update in run.updates {
        // The ticket, re-checked after every wait (§4.1's reentrancy law).
        try Task.checkCancellation()
        switch update {
        case .token(let token):
            text += token
        case .finished(let stop):
            return Reply(text: text, stop: stop)
        case .failed(let failure):
            throw failure
        }
    }
    // The stream ended with NO terminal. A conformant run does that after
    // a cancel — and the caller's is the only one that can reach this
    // task. Anything else is a generator that broke the seam's contract,
    // and it is named rather than returned as half a reply.
    try Task.checkCancellation()
    throw ReplyFailure.engine("the reply ended without a terminal")
}
