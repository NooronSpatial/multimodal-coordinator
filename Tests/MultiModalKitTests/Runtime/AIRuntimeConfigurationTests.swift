import MultiModalKit
import MultiModalKitTesting
import Testing

/// NO CALLER-REACHABLE TERMINATION (4v, SPEC §175 item 8, AC-241; D-101's
/// R8 row).
///
/// D-101 counted seven `precondition`s in the library and judged two of
/// them reachable by a caller's CONFIGURATION rather than by a literal a
/// caller typed: the runtime's mind/mouth pairing, and the clockless
/// coordinator's reply gate. The 4v review found three more behind
/// `TurnCoordinator.Config`'s numbers — the ledger bound and the memory's
/// two, which D-092 says the app owns — passing `AIRuntime.init` cleanly
/// and trapping inside `run()`, after the microphone was capturing. A
/// caller assembling a configuration at runtime — Aura, reading its own
/// settings — must get an error it can switch over and show, not a
/// crash it can only read in a log. These tests pin every throw and its
/// case; the preconditions that stay are listed in ARCHITECTURE.md
/// ("what the doors refuse") with the invariant each guards.
///
/// Nothing here runs a pipeline: every test is the construction alone,
/// which is the whole point — the mistake is caught before a loop
/// starts, never inside one.
@Suite(.timeLimit(.minutes(1)))
struct AIRuntimeConfigurationTests {

    static func configuration(
        mind: (any ReplyGenerating)? = nil,
        mouth: (any SpeechSynthesizing)? = nil,
        turns: TurnCoordinator<ManualClock>.Config = .init()
    ) -> AIRuntime<ManualClock>.Configuration {
        let (_, consumer) = AudioRing.create(minimumCapacity: 4_096)
        return .init(
            consumer: consumer,
            vad: EnergyVAD(config: .init(threshold: 0.25, hangoverFrames: 4)),
            ear: ScriptedTranscriber(plans: []),
            mind: mind, mouth: mouth,
            pump: .init(sampleRate: 16_000, pollInterval: .milliseconds(10),
                        chunkFrames: 320, preRollChunks: 2),
            transcription: .init(format: .init(sampleRate: 16_000, channels: 1)),
            turns: turns,
            clock: ManualClock(),
            releaseSource: {})
    }

    // MARK: - AC-241: the runtime's pairing

    @Test("a mind without a mouth throws .mindWithoutMouth, at init, before any loop (AC-241)")
    func mindWithoutMouthThrows() {
        let config = Self.configuration(mind: ScriptedReplyGenerator(plans: []))
        #expect(throws: AIRuntime<ManualClock>.ConfigurationError.mindWithoutMouth) {
            _ = try AIRuntime(config)
        }
    }

    @Test("a mouth without a mind throws .mouthWithoutMind, at init, before any loop (AC-241)")
    func mouthWithoutMindThrows() {
        let config = Self.configuration(mouth: ScriptedSynthesizer(plans: []))
        #expect(throws: AIRuntime<ManualClock>.ConfigurationError.mouthWithoutMind) {
            _ = try AIRuntime(config)
        }
    }

    @Test("both organs, or neither, is a valid configuration and does not throw (F-3 = B)")
    func togetherOrNeitherDoesNotThrow() throws {
        let conversation = try AIRuntime(Self.configuration(
            mind: ScriptedReplyGenerator(plans: []), mouth: ScriptedSynthesizer(plans: [])))
        #expect(conversation.configuration.mind != nil)
        let listenOnly = try AIRuntime(Self.configuration())
        #expect(listenOnly.configuration.mind == nil)
    }

    /// The error is the message a screen shows, so the words must tell
    /// the caller what to do — not merely what went wrong.
    @Test("the runtime's error says what to do in plain words")
    func runtimeErrorDescriptionsSayWhatToDo() {
        let mindOnly = AIRuntime<ManualClock>.ConfigurationError.mindWithoutMouth
        let mouthOnly = AIRuntime<ManualClock>.ConfigurationError.mouthWithoutMind
        #expect(mindOnly.description.contains("mouth"))
        #expect(mouthOnly.description.contains("mind"))
        #expect(mindOnly != mouthOnly)
    }

    // MARK: - AC-241: the clockless coordinator's gate

    /// The clockless initializer has no clock, and a reply gate is a
    /// duration it would have to wait: the two cannot both be true. The
    /// error names the initializer to use instead.
    @Test("the clockless coordinator with a reply gate throws .replyGateNeedsAClock (AC-241)")
    func clocklessCoordinatorWithGateThrows() {
        let generator = ScriptedReplyGenerator(plans: [])
        let synthesizer = ScriptedSynthesizer(plans: [])
        #expect(throws: TurnCoordinatorConfigurationError.replyGateNeedsAClock) {
            _ = try TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer,
                                    config: .init(replyGate: .milliseconds(500)))
        }
        #expect(TurnCoordinatorConfigurationError.replyGateNeedsAClock.description.contains("clock"))
    }

    @Test("the clockless coordinator with the default (zero) gate does not throw")
    func clocklessCoordinatorWithoutGateDoesNotThrow() async throws {
        let generator = ScriptedReplyGenerator(plans: [])
        let synthesizer = ScriptedSynthesizer(plans: [])
        let coordinator = try TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer)
        let state = await coordinator.currentState
        #expect(state == .idle)
    }

    // MARK: - AC-241: the numbers the app owns (the 4v review's finding)

    /// A silent reporter for the clocked door: these tests build and
    /// never run, so nothing is ever reported.
    struct NoLatency: LatencyReporter {
        func turnLatency(_ duration: Duration, turn: Int) {}
        func cancelLatency(_ duration: Duration, turn: Int) {}
    }

    /// The hazard itself: a `Config` number the app reads from its
    /// settings used to pass `AIRuntime.init` and trap inside `run()`,
    /// after the microphone was open. The door refuses it now, wrapped
    /// so the caller learns WHICH number.
    @Test("a ledger bound of zero is refused by AIRuntime.init, not trapped in run() (AC-241)",
          arguments: [
            (TurnCoordinator<ManualClock>.Config(maxContextPieces: 0),
             TurnCoordinatorConfigurationError.contextBoundMustBePositive),
            (TurnCoordinator<ManualClock>.Config(maxMemoryTurns: -1),
             TurnCoordinatorConfigurationError.memoryTurnsMustBeNonNegative),
            (TurnCoordinator<ManualClock>.Config(maxMemoryCharacters: 0),
             TurnCoordinatorConfigurationError.memoryCharactersMustBePositive)
          ])
    func runtimeRefusesABadTurnsNumberAtInit(
        turns: TurnCoordinator<ManualClock>.Config, expected: TurnCoordinatorConfigurationError
    ) {
        let config = Self.configuration(
            mind: ScriptedReplyGenerator(plans: []), mouth: ScriptedSynthesizer(plans: []),
            turns: turns)
        #expect(throws: AIRuntime<ManualClock>.ConfigurationError.turns(expected)) {
            _ = try AIRuntime(config)
        }
    }

    /// The whole configuration is checked, a mind given or not: "the
    /// door refuses an invalid configuration" is one rule, and a wrong
    /// number is wrong before the organ that reads it is switched on.
    @Test("listen-only still has its turns numbers checked at the door (AC-241)")
    func listenOnlyIsCheckedToo() {
        let config = Self.configuration(turns: .init(maxContextPieces: -3))
        #expect(throws: AIRuntime<ManualClock>.ConfigurationError.turns(.contextBoundMustBePositive)) {
            _ = try AIRuntime(config)
        }
    }

    @Test("both coordinator doors refuse a bad number with the same error (AC-241)")
    func bothCoordinatorDoorsValidate() {
        let generator = ScriptedReplyGenerator(plans: [])
        let synthesizer = ScriptedSynthesizer(plans: [])
        #expect(throws: TurnCoordinatorConfigurationError.memoryCharactersMustBePositive) {
            _ = try TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer,
                                    config: .init(maxMemoryCharacters: 0))
        }
        #expect(throws: TurnCoordinatorConfigurationError.contextBoundMustBePositive) {
            _ = try TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer,
                                    config: .init(maxContextPieces: 0),
                                    clock: ManualClock(), latencyReporter: NoLatency())
        }
    }

    /// The clockless door checks the gate FIRST: a caller with two
    /// mistakes hears about the initializer before the number.
    @Test("the clockless door reports the gate before the bounds")
    func clocklessDoorReportsTheGateFirst() {
        let generator = ScriptedReplyGenerator(plans: [])
        let synthesizer = ScriptedSynthesizer(plans: [])
        #expect(throws: TurnCoordinatorConfigurationError.replyGateNeedsAClock) {
            _ = try TurnCoordinator(replyGenerator: generator, synthesizer: synthesizer,
                                    config: .init(replyGate: .milliseconds(1), maxContextPieces: 0))
        }
    }

    /// Zero memory turns is a conversation with no past — AC-197's
    /// baseline row — and must stay legal; the default must too.
    @Test("validate() passes the default and the legal zero-depth memory (AC-197)")
    func validatePassesTheDefaultAndZeroDepth() throws {
        try TurnCoordinator<ManualClock>.Config().validate()
        try TurnCoordinator<ManualClock>.Config(maxMemoryTurns: 0).validate()
        // The `try` IS the assertion: a zero-depth memory must pass the door.
        _ = try TurnCoordinator(
            replyGenerator: ScriptedReplyGenerator(plans: []),
            synthesizer: ScriptedSynthesizer(plans: []),
            config: .init(maxMemoryTurns: 0))
    }

    /// The error is what a screen shows: each case must name its number.
    @Test("the coordinator's errors name the number they refuse")
    func coordinatorErrorsNameTheirNumber() {
        #expect(TurnCoordinatorConfigurationError.contextBoundMustBePositive
            .description.contains("maxContextPieces"))
        #expect(TurnCoordinatorConfigurationError.memoryTurnsMustBeNonNegative
            .description.contains("maxMemoryTurns"))
        #expect(TurnCoordinatorConfigurationError.memoryCharactersMustBePositive
            .description.contains("maxMemoryCharacters"))
        #expect(AIRuntime<ManualClock>.ConfigurationError.turns(.contextBoundMustBePositive)
            .description.contains("maxContextPieces"))
    }
}
