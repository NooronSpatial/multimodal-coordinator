import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — what every picker persists: the UserDefaults keys
// and the reads that turn them back into choices.
extension TranscribeModel {
    static let voiceKey = "dev.nooron.demo.appleVoice"
    static var storedVoice: String? {
        UserDefaults.standard.string(forKey: voiceKey)
    }

    // EVERY PICKER PERSISTS (Ryad). The ear and the Apple voice already
    // did; the mind, the mouth, the shield and the two toggles did not,
    // so every launch quietly reset them and the person re-chose from a
    // screen that looked like it remembered. A control that forgets is a
    // control that lies about its own state.
    // The levers are stored as four primitives rather than one encoded
    // blob: a blob that fails to decode after a TTSKit rename would take
    // every setting with it, and these are the settings a person reaches
    // for when something is already wrong.
    private static let modelKey = "dev.nooron.demo.levers.model"
    private static let decoderKey = "dev.nooron.demo.levers.decoder"
    private static let vocoderKey = "dev.nooron.demo.levers.vocoder"
    private static let temperatureKey = "dev.nooron.demo.levers.temperature"
    private static let leadKey = "dev.nooron.demo.levers.leadMS"
    static var storedLevers: VoiceLevers {
        let defaults = UserDefaults.standard
        var levers = VoiceLevers.phoneDefault
        if defaults.string(forKey: modelKey) == "1.7b" { levers.model = .qwen3TTS_1_7b }
        // SANITIZED against the platform (AC-161). Ryad's phone had "1.7b"
        // persisted from the field failure — the tap that produced the raw
        // CoreML "-14" — so an unsanitized restore would BOOT the app into
        // a refused voice. The picker's disabled row stops new selections;
        // this stops the one already written down.
        if !levers.model.isAvailableOnCurrentPlatform { levers.model = .qwen3TTS_0_6b }
        if defaults.string(forKey: decoderKey) == "fused" { levers.decoder = .fused }
        if defaults.string(forKey: vocoderKey) == "throughput" {
            levers.vocoder = .throughputOptimized
        }
        // `object(forKey:)` first: `float(forKey:)` cannot tell "absent"
        // from "zero", and zero is a REAL temperature with a distinctive
        // sound (INSTRUMENTS §32). Reading it as "unset" would silently
        // change what the person chose.
        if defaults.object(forKey: temperatureKey) != nil {
            levers.temperature = defaults.float(forKey: temperatureKey)
        }
        if defaults.object(forKey: leadKey) != nil {
            levers.lead = .milliseconds(defaults.integer(forKey: leadKey))
        }
        return levers
    }
    static func store(_ levers: VoiceLevers) {
        let defaults = UserDefaults.standard
        defaults.set(levers.model == .qwen3TTS_1_7b ? "1.7b" : "0.6b", forKey: modelKey)
        defaults.set(levers.decoder == .fused ? "fused" : "stepped", forKey: decoderKey)
        defaults.set(levers.vocoder == .throughputOptimized ? "throughput" : "latency",
                     forKey: vocoderKey)
        if let temperature = levers.temperature {
            defaults.set(temperature, forKey: temperatureKey)
        } else {
            defaults.removeObject(forKey: temperatureKey)
        }
        if let lead = levers.lead {
            defaults.set(Int(lead.components.seconds * 1000
                + lead.components.attoseconds / 1_000_000_000_000_000), forKey: leadKey)
        } else {
            defaults.removeObject(forKey: leadKey)
        }
    }

    static let mindKey = "dev.nooron.demo.mind"
    static var storedMind: MindChoice {
        UserDefaults.standard.string(forKey: mindKey)
            .flatMap(MindChoice.init(rawValue:)) ?? .echo
    }
    static let mouthKey = "dev.nooron.demo.mouth"
    static var storedMouth: MouthChoice {
        UserDefaults.standard.string(forKey: mouthKey)
            .flatMap(MouthChoice.init(rawValue:)) ?? .apple
    }
    static let shieldKey = "dev.nooron.demo.speakerShield"
    static let talkKey = "dev.nooron.demo.talkEnabled"
    static let speakerKey = "dev.nooron.demo.useSpeaker"
    /// `object(forKey:)` and not `bool(forKey:)`: the latter answers
    /// `false` for "never set", which would silently flip a default that
    /// is deliberately `true`.
    static func storedFlag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static let engineKey = "dev.nooron.demo.engine"
    static var storedEngine: EngineChoice {
        UserDefaults.standard.string(forKey: engineKey)
            .flatMap(EngineChoice.init(rawValue:)) ?? .apple
    }

    static let gateKey = "dev.nooron.demo.vadThreshold"
    static var storedGate: Float {
        // `object(forKey:)` rather than `float(forKey:)`: the latter
        // returns 0 for "never set", and a gate of ZERO would open an
        // utterance on silence — a stored-default bug that looks exactly
        // like a broken VAD.
        guard let stored = UserDefaults.standard.object(forKey: gateKey) as? Float
        else { return 0.02 }
        return stored
    }
}
