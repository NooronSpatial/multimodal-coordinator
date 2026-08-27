// The `voice-install` instrument: put the neural voice's model on disk.
import Foundation
import MultiModalKitTTS

// `swift run bakeoff voice-install` — fetch the neural voice's model.
// It lives here rather than in a throwaway script because this is where
// the VOICE bake-off will run (AC-103), and the same tool should be able
// to put its subject on disk.
@MainActor
func runVoiceInstall() async {
    let voice = NeuralVoice()
    if await voice.modelInstalled() {
        print("✅ the neural voice's model is already on disk — nothing to fetch")
        exit(0)
    }
    print("⏬ fetching the Qwen3 neural voice (\(voice.variant.description))…")
    print("   TTSKit logs its own progress; a silent minute is not a hang.")
    do {
        _ = try await voice.ensureModel()
        let installed = await voice.modelInstalled()
        print(installed
            ? "✅ installed, and the disk check agrees"
            : "⚠️  the load succeeded but the disk check says NOT installed — "
              + "the folder this project expects is not the one TTSKit used")
        exit(installed ? 0 : 2)
    } catch {
        print("⚠️  download failed: \(error)")
        exit(1)
    }
}
