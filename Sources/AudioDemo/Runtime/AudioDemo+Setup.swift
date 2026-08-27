import Foundation
import MultiModalKit
import MultiModalKitWhisper

// Extends `AudioDemo` with everything that happens BEFORE the pipeline runs:
// the command-line levers, the choice of ear, the model phase, the opening
// banner, and the `--levels` probe. Plus `DemoFlags`, the parsed levers.

/// The command-line levers this demo reads for itself, parsed in one place.
struct DemoFlags {
    let arguments: [String]
    let choice: String
    let talk: Bool
    let onsetMs: Double
    let gateMs: Double
    let vadThreshold: Float
    let hangoverMs: Double
    let wantsAEC: Bool
    let levels: Bool

    init(arguments: [String]) {
        self.arguments = arguments
        talk = arguments.contains("--talk")
        // `--onset <ms>`: the F-6 field A/B flag (08-13). The A/B convicted
        // the strict window twice on this machine — "Riyadh"→"Riyat" and
        // "error rate"→"rate", both onsets clipped after a split — against
        // zero quiet-room benefit (the 0.02 gate already earned the clean
        // runs). Ruled D-036: the Mac demo runs with the window OFF; the
        // flag stays for experiments; a machine that truly needs a window
        // with soft speech reopens F-2 as a tolerance budget first.
        onsetMs = Self.number(after: "--onset", in: arguments) ?? 0.0
        // `--gate <ms>`: the reply gate (AC-81) — how long the floor must
        // stay yielded before the assistant answers. 0 = reply at the
        // final, exactly the 4a behavior. The number is the app's to earn
        // (D-027); the flag is where this machine earns it.
        gateMs = Self.number(after: "--gate", in: arguments) ?? 0.0
        // `--vad <level>`: the loudness gate itself. Born from the field
        // finding in SPEC §46a — quiet speech at 2-4x this number gets
        // FRAGMENTED into syllables that decode to nothing — and from the
        // fact that echo cancellation moved the ambient floor this number
        // was chosen against (peak 0.024 -> 0.006). The prediction to test:
        // with the canceller on, a lower gate holds quiet speech together
        // without reviving 1d's flap.
        vadThreshold = Self.number(after: "--vad", in: arguments) ?? 0.02
        // `--hangover <ms>`: how long a dip is forgiven before the utterance
        // is declared over — the fragment boundary, proven in the field
        // (SPEC §46a). 700 ms is this demo's ruled number (D-039), bracketed
        // from both sides on one voice: at 300 ms a quiet sentence shattered
        // into four pieces, at 500 ms it split in two, at 700 ms it arrived
        // whole. The LIBRARY default stays 300 ms — each product earns its
        // own number (D-028/D-036). Cost, stated where it is paid: every
        // final waits 400 ms longer than the library default would.
        hangoverMs = Self.number(after: "--hangover", in: arguments) ?? 700.0
        // Echo cancellation is ON by default here (D-038): the spike its
        // adoption was gated on passed, in the field, with a human in the
        // room — replies complete instead of barging themselves, the reply
        // stays comfortably loud, and a live voice still interrupts it.
        // `--no-aec` keeps the old door open for A/B experiments.
        wantsAEC = !arguments.contains("--no-aec")
        levels = arguments.contains("--levels")
        choice = arguments.first { !$0.hasPrefix("--") && Double($0) == nil } ?? "apple"
    }

    /// The word after a `--flag`, read as a number. `nil` when the flag is
    /// absent, is the last word, or is followed by something unreadable —
    /// in every one of those cases the caller keeps its default.
    private static func number<Value: LosslessStringConvertible>(
        after flag: String, in arguments: [String]
    ) -> Value? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1) else { return nil }
        return Value(arguments[flagIndex + 1])
    }
}

extension AudioDemo {
    /// The ear named on the command line, with the banner text that
    /// describes it. `nil` means the name was not one of ours: usage is
    /// printed and the demo declines to run.
    static func chosenEar(_ choice: String) -> (engine: any TranscriptionEngine, name: String)? {
        switch choice {
        case "apple":
            return (AppleSpeechEngine(), "Apple SpeechAnalyzer (en-US, streaming)")
        case "whisper":
            return (WhisperEngine(), "Whisper base (batch — text arrives after each pause)")
        default:
            print("usage: swift run audio-demo [apple|whisper] [--talk]   (default: apple)")
            return nil
        }
    }

    // True when transcription can run: the model was already here, or the
    // download just put it here.
    //
    // THE CAST IS GONE (D-078). This asked the same two questions
    // through four force casts decided by a STRING, against an object
    // built somewhere else — if the two ever disagreed the app would
    // not misbehave, it would crash. `ModelBacked` is the contract
    // both engines already honoured without one, so the question is
    // now asked of the protocol and the concrete types are nobody's
    // business here.
    static func readyModel(_ engine: any TranscriptionEngine, named choice: String) async -> Bool {
        let backed = engine as? any ModelBacked
        func modelReady() async -> Bool {
            guard let backed else { return true }
            return await backed.modelInstalled()
        }
        func ensure() async throws {
            try await backed?.ensureModel()
        }
        var engineReady = await modelReady()
        if !engineReady {
            print("⏬ The \(choice) model is not on this Mac — downloading…")
            do {
                try await ensure()
                print("✅ model installed")
                engineReady = true
            } catch {
                print("⚠️  download failed: \(error)")
                print("   Running with voice detection only — transcription disabled.")
            }
        }
        return engineReady
    }

    /// The opening banner. `engine` is the ear's description, or `nil` when
    /// there is no model and transcription is off.
    static func printBanner(
        _ flags: DemoFlags, sampleRate: Double, engine: String?, voiceProcessingActive: Bool
    ) {
        print("\n🎙  Speak — the pump is listening.  (Ctrl-C to quit)")
        print("    \(Int(sampleRate)) Hz · 20 ms chunks · gate \(flags.vadThreshold)"
            + " · \(Int(flags.onsetMs)) ms onset · \(Int(flags.hangoverMs)) ms hangover"
            + " · 200 ms pre-roll")
        print("    transcription: \(engine ?? "OFF (no model)")")
        print("    voice processing: "
            + (flags.wantsAEC
                ? (voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")
                : "OFF (--no-aec) — the assistant will hear itself"))
        if flags.talk && engine != nil {
            // READ FROM THE FLAGS, not hardcoded. This line said
            // "the echo aloud (AVSpeechSynthesizer)" in every run, including
            // `--mind=local --mouth=neural`, where all three words were
            // wrong. A banner that cannot be wrong is worth more than a
            // banner that is usually right.
            func flag(_ name: String) -> String? {
                flags.arguments.first { $0.hasPrefix("--\(name)=") }
                    .map { String($0.dropFirst(name.count + 3)) }
            }
            let mindName = flag("mind") ?? "echo"
            let mouthName = flag("mouth") == "neural"
                ? "Qwen3 neural voice" : "AVSpeechSynthesizer"
            print("    turn loop: ON — \(mindName) mind, spoken by "
                + "\(mouthName); interrupt it mid-reply")
            print("    reply gate: \(Int(flags.gateMs)) ms"
                + (flags.gateMs == 0 ? " (answers at the final — 4a behavior)" : " of yielded floor"))
            print("    context: up to 16 pieces of one thought — 🧠 shows what the"
                + " generator received\n")
        } else {
            print("")
        }
    }

    /// `--levels`: the honest instrument the F-2 spike needed. The pump
    /// only publishes sound the VAD already accepted, so "no utterances"
    /// could mean cancelled echo OR a deaf microphone — indistinguishable
    /// from the pump's output. This mode reads the ring directly (the
    /// pump is not running here, so its sole-reader rule stands) and
    /// prints what the microphone ACTUALLY delivers, gate or no gate.
    static func runLevelProbe(
        reading consumer: AudioRingConsumer, wantsAEC: Bool, voiceProcessingActive: Bool
    ) async {
        print("\n📏 level probe — what the microphone really delivers, every 500 ms")
        print("    voice processing: "
            + (wantsAEC
                ? (voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")
                : "off"))
        print("    (the demo's VAD gate for reference: 0.02)   Ctrl-C to quit\n")
        var scratch = [Float](repeating: 0, count: consumer.capacity)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            var sumOfSquares: Float = 0
            var peak: Float = 0
            var frames = 0
            var dropped = 0
            scratch.withUnsafeMutableBufferPointer { buffer in
                let result = consumer.read(into: buffer)
                frames = result.framesRead
                dropped = result.framesDropped
                for frameIndex in 0..<frames {
                    sumOfSquares += buffer[frameIndex] * buffer[frameIndex]
                    peak = max(peak, abs(buffer[frameIndex]))
                }
            }
            let rms = frames > 0 ? (sumOfSquares / Float(frames)).squareRoot() : 0
            let bar = String(repeating: "█", count: min(Int(rms * 300), 30))
            print(String(format: "rms %.4f · peak %.4f · %5d frames%@  %@",
                         rms, peak, frames,
                         dropped > 0 ? " · dropped \(dropped)" : "", bar))
        }
    }
}
