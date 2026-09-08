import MultiModalKit
import MultiModalKitTesting
import Testing

/// NO CALLER-REACHABLE TERMINATION (4v, SPEC §175 item 8, AC-241; D-101's
/// R8 row).
///
/// D-101 counted seven `precondition`s in the library and judged two of
/// them reachable by a caller's CONFIGURATION rather than by a literal a
/// caller typed: the runtime's mind/mouth pairing, and the clockless
/// coordinator's reply gate. A caller assembling a configuration at
/// runtime — Aura, reading its own settings — must get an error it can
/// switch over and show, not a crash it can only read in a log. These
/// tests pin the two throws and their cases; the five preconditions that
/// stay are listed in the contract page with the invariant each guards.
///
/// Nothing here runs a pipeline: every test is the construction alone,
/// which is the whole point — the mistake is caught before a loop
/// starts, never inside one.
@Suite(.timeLimit(.minutes(1)))
struct AIRuntimeConfigurationTests {

    static func configuration(
        mind: (any ReplyGenerating)? = nil,
        mouth: (any SpeechSynthesizing)? = nil
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
            turns: .init(),
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
}
