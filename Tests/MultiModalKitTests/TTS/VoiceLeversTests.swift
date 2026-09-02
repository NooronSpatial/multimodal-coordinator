import Foundation
import Testing
import TTSKit

@testable import MultiModalKitTTS

/// AC-143 — the levers reach the voice, and the screen reports the VOICE.
///
/// These run on a machine with no models installed, because `NeuralVoice`'s
/// initialiser does not load anything. Building one is free; only speaking
/// costs.
@Suite("the voice levers")
struct VoiceLeversTests {

    @Test("every lever reaches the voice that gets built")
    func leversReachTheVoice() {
        let levers = VoiceLevers(decoder: .stepped,
                                 vocoder: .throughputOptimized,
                                 temperature: 0.7,
                                 lead: .milliseconds(250))
        let voice = levers.makeVoice()
        #expect(voice.multiCodeDecoderMode == .stepped)
        #expect(voice.speechDecoderMode == .throughputOptimized)
        #expect(voice.temperature == 0.7)
        #expect(voice.lead == .milliseconds(250))
    }

    @Test("no lead given means the cushion is still derived, not zeroed")
    func absentLeadIsDerived() {
        let voice = VoiceLevers(decoder: .stepped).makeVoice()
        #expect(voice.lead == NeuralVoice.defaultLead(for: .stepped))
        #expect(voice.lead > .zero, "a zero cushion on .stepped is the slow-voice bug")
    }

    @Test("the model reaches the voice, and the display names it")
    func theModelIsALever() {
        let small = VoiceLevers(decoder: .stepped).makeVoice()
        #expect(small.variant == .qwen3TTS_0_6b)
        #expect(small.inForce.contains("0.6B"))

        let big = VoiceLevers(model: .qwen3TTS_1_7b, decoder: .stepped).makeVoice()
        #expect(big.variant == .qwen3TTS_1_7b)
        #expect(big.inForce.contains("1.7B"))
        // AC-143's rule, one lever wider: the line must report the VOICE.
        #expect(!big.inForce.contains("0.6B"))
    }

    @Test("the phone's default is not a decoder the phone cannot load")
    func phoneDefaultIsStepped() {
        #expect(VoiceLevers.phoneDefault.decoder == .stepped)
    }

    // MARK: the display reports the VOICE, not the picker

    @Test("what is in force names every lever that was actually built")
    func inForceNamesTheBuild() {
        let voice = VoiceLevers(decoder: .stepped,
                                vocoder: .throughputOptimized,
                                temperature: 0.7).makeVoice()
        let shown = voice.inForce
        #expect(shown.contains("stepped"))
        #expect(shown.contains("throughput"))
        #expect(shown.contains("0.7"))
        #expect(!shown.contains("fused"))
        #expect(!shown.contains("latency"))
    }

    @Test("a voice that keeps up says it needs no cushion")
    func fusedSaysNoCushion() {
        #expect(VoiceLevers(decoder: .fused).makeVoice().inForce
            .contains("none needed"))
    }

    @Test("a voice that cannot keep up shows the cushion in milliseconds")
    func steppedShowsItsCushion() {
        #expect(VoiceLevers(decoder: .stepped).makeVoice().inForce
            .contains("396 ms"))
    }

    /// THE ONE THAT FAILS IF THE SCREEN IS WIRED TO THE PICKER.
    ///
    /// The picker says one thing; the voice that exists says another. Only a
    /// display that reads the voice can tell them apart — and this is the
    /// case that matters, because it is what a person sees when an apply did
    /// not take.
    @Test("when the picker and the built voice disagree, the voice wins")
    func theVoiceWinsOverThePicker() {
        let whatThePickerSays = VoiceLevers(decoder: .fused,
                                            vocoder: .latencyOptimized)
        let whatWasActuallyBuilt = VoiceLevers(decoder: .stepped,
                                               vocoder: .throughputOptimized)
            .makeVoice()
        #expect(whatWasActuallyBuilt.inForce.contains("stepped"))
        #expect(!whatWasActuallyBuilt.inForce.contains("fused"))
        // And the proof that this is structural rather than careful: there
        // is no way to hand `inForce` the picker's value at all.
        #expect(whatThePickerSays.decoder != whatWasActuallyBuilt.multiCodeDecoderMode)
    }

    /// AC-144's CONTROL, and it is the half that makes the other half mean
    /// something.
    ///
    /// The phone's claim is "`.fused` does not load on iOS 18+". A claim
    /// like that is worthless unless the same code CAN load it somewhere —
    /// otherwise a refusal is indistinguishable from a broken test, a
    /// missing model, or a typo in a mode name. This machine is that
    /// somewhere: §31 measured `.fused` decoding on macOS 26, three runs,
    /// no error.
    ///
    /// Skips honestly when the model is not on disk, because "no model" is
    /// not evidence about a decoder.
    @Test("CONTROL: .fused really does load here, so an iOS refusal means something")
    func fusedLoadsOnThisMachine() async throws {
        let voice = VoiceLevers(decoder: .fused).makeVoice()
        guard await voice.modelInstalled() else { return }
        try await voice.ensureModel()
        await voice.retire()
    }

    // MARK: the one parser (D-072 F-3, AC-162)

    @Test("every flag reaches the levers, in the app's own tokens")
    func allFiveFlagsParse() throws {
        let levers = try VoiceLevers.parsed(fromArguments: [
            "--voice-model=1.7b", "--decoder=stepped", "--speech=throughput",
            "--temperature=0.5", "--lead=250ms"
        ])
        #expect(levers.model == .qwen3TTS_1_7b)
        #expect(levers.decoder == .stepped)
        #expect(levers.vocoder == .throughputOptimized)
        #expect(levers.temperature == 0.5)
        #expect(levers.lead == .milliseconds(250))
    }

    @Test("no flags means base, untouched — lead stays derivable")
    func absentFlagsKeepBase() throws {
        let levers = try VoiceLevers.parsed(fromArguments: ["--mouth=neural"])
        #expect(levers == VoiceLevers())
        #expect(levers.lead == nil, "a parser that zeroes the lead rebuilds the slow-voice bug")
    }

    @Test("the small model parses with the token the phone persists")
    func smallModelToken() throws {
        let levers = try VoiceLevers.parsed(
            fromArguments: ["--voice-model=0.6b"],
            base: VoiceLevers(model: .qwen3TTS_1_7b))
        #expect(levers.model == .qwen3TTS_0_6b)
    }

    @Test("--decoder=banana is refused in our words, never silently .fused")
    func bananaIsRefused() {
        // The D-072 rejection sentence, pinned: the hand-rolled parse
        // turned this exact string into `.fused` without complaint.
        #expect(throws: VoiceLevers.FlagError(
            flag: "decoder", given: "banana", allowed: "fused|stepped")) {
            _ = try VoiceLevers.parsed(fromArguments: ["--decoder=banana"])
        }
    }

    @Test("an unreadable number is refused, not shrugged into the default")
    func unreadableNumbersAreRefused() {
        #expect(throws: VoiceLevers.FlagError.self) {
            _ = try VoiceLevers.parsed(fromArguments: ["--temperature=warm"])
        }
        #expect(throws: VoiceLevers.FlagError.self) {
            _ = try VoiceLevers.parsed(fromArguments: ["--lead=soon"])
        }
        #expect(throws: VoiceLevers.FlagError.self) {
            _ = try VoiceLevers.parsed(fromArguments: ["--voice-model=3b"])
        }
        #expect(throws: VoiceLevers.FlagError.self) {
            _ = try VoiceLevers.parsed(fromArguments: ["--speech=fast"])
        }
    }

    @Test("the refusal names the flag, the wrong value, and the allowed tokens")
    func refusalSpeaksOurWords() {
        let error = VoiceLevers.FlagError(flag: "voice-model", given: "3b",
                                          allowed: "0.6b|1.7b")
        #expect(error.message == "--voice-model=3b — this project knows 0.6b|1.7b")
    }

    @Test("a measured cushion is labelled as measured, a typed one is not")
    func measuredCushionIsLabelled() {
        let derived = VoiceLevers(decoder: .stepped).makeVoice()
        #expect(!derived.inForce.contains("measured here"),
                "nothing has been measured yet — the constant is not a measurement")

        derived.adaptive.observe(DecodeMargin(audioMilliseconds: 6000,
                                              wallMilliseconds: 7260,
                                              prefillMilliseconds: 100,
                                              steadyRealTimeFactor: 1.21,
                                              completed: true,
                                              cushionMilliseconds: nil,
                                              requiredCushionMilliseconds: 1260))
        #expect(derived.inForce.contains("measured here"))

        let typed = VoiceLevers(decoder: .stepped, lead: .milliseconds(250)).makeVoice()
        typed.adaptive.observe(DecodeMargin(audioMilliseconds: 6000,
                                            wallMilliseconds: 7260,
                                            prefillMilliseconds: 100,
                                            steadyRealTimeFactor: 1.21))
        #expect(!typed.inForce.contains("measured here"),
                "a human's number is not this machine's measurement")
        #expect(typed.inForce.contains("250 ms"))
    }

    // MARK: - the neural-voice lever (4q, D-084)

    /// The lever's tokens are the ones the app persists and the ones the
    /// terminal accepts — the same string in both places, which is why
    /// D-072 F-1 put parsing in the library rather than in an executable.
    @Test("the voice lever parses in both directions")
    func theVoiceLeverParses() throws {
        let toKokoro = try VoiceLevers.parsed(fromArguments: ["--voice=kokoro"],
                                              base: VoiceLevers(voice: .qwen3))
        #expect(toKokoro.voice == .kokoro)
        let toQwen = try VoiceLevers.parsed(fromArguments: ["--voice=qwen3"],
                                            base: VoiceLevers(voice: .kokoro))
        #expect(toQwen.voice == .qwen3)
    }

    /// A value this project cannot honor throws, with the allowed tokens
    /// beside the wrong one. D-072 exists because a hand-rolled ternary
    /// turned `--decoder=banana` into `.fused` in silence.
    @Test("an unknown voice is refused in our words, never guessed")
    func anUnknownVoiceIsRefused() {
        #expect(throws: VoiceLevers.FlagError.self) {
            try VoiceLevers.parsed(fromArguments: ["--voice=banana"])
        }
    }

    /// **`--voice` is not `--mouth`.** The demo already spends `--mouth`
    /// on apple|neural, and the first draft of this lever stole the name:
    /// `absentFlagsKeepBase`, which passes `--mouth=neural` precisely
    /// because it is meant to be ignored, went red immediately. This test
    /// keeps that boundary explicit instead of leaving it to luck.
    @Test("--mouth is still not this lever's flag")
    func mouthIsNotThisLever() throws {
        let levers = try VoiceLevers.parsed(fromArguments: ["--mouth=neural"],
                                            base: VoiceLevers(voice: .kokoro))
        #expect(levers.voice == .kokoro, "an unrelated flag must change nothing here")
    }

    /// **Switching voices must not destroy Qwen's settings.** They mean
    /// nothing to Kokoro, so the temptation is to clear them; a person who
    /// switches back would then find their configuration gone.
    @Test("choosing Kokoro keeps Qwen's knobs untouched")
    func switchingVoicesKeepsTheOtherSettings() throws {
        let base = VoiceLevers(voice: .qwen3, model: .qwen3TTS_1_7b,
                               decoder: .stepped, vocoder: .throughputOptimized,
                               temperature: 0.5, lead: .milliseconds(400))
        let switched = try VoiceLevers.parsed(fromArguments: ["--voice=kokoro"], base: base)
        #expect(switched.voice == .kokoro)
        #expect(switched.model == .qwen3TTS_1_7b)
        #expect(switched.decoder == .stepped)
        #expect(switched.vocoder == .throughputOptimized)
        #expect(switched.temperature == 0.5)
        #expect(switched.lead == .milliseconds(400))
    }

    /// D-084's ruling as a fact rather than a paragraph: the voice a fresh
    /// configuration asks for is the one §55 measured at RTF 0.20.
    @Test("the default voice is Kokoro, which is what D-084 ruled")
    func theDefaultVoiceIsKokoro() {
        #expect(VoiceLevers().voice == .kokoro)
        #expect(VoiceLevers.phoneDefault.voice == .kokoro)
    }
}
