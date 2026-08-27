import Foundation
import MultiModalKit
import MultiModalKitMLX
import MultiModalKitTTS
import TTSKit

// The demo's organ pickers: mind, mouth, and where the local weights live.

// MARK: - choosing the organs from the command line

/// `--mind=echo|apple|local` (default: echo)
///
/// The phone picks its organs from three pickers; this is the same choice
/// on a Mac, from a terminal. Each option is a REAL implementation behind
/// the same `ReplyGenerating` seam — which is the thing 4h set out to
/// prove and the cheapest way to see it proven.
func chosenMind(_ arguments: [String], screen: Screen) -> any ReplyGenerating {
    // stderr, not the Screen: its `log` is actor-isolated, and these are
    // setup refusals that must not fight the TUI for the same lines.
    func refuse(_ why: String) {
        FileHandle.standardError.write(Data((why + "\n").utf8))
    }
    let want = arguments.first { $0.hasPrefix("--mind=") }
        .map { String($0.dropFirst("--mind=".count)) } ?? "echo"
    let spoken = "Your reply will be spoken aloud and never shown as text. "
        + "Answer in ONE short sentence. Do not add extra facts unless asked."
    switch want {
    case "apple":
        return AppleReplyGenerator(instructions: spoken)
    case "local":
        // A path is not a model. `--model=/nope` used to sail past this
        // guard — the URL is non-nil, so the refusal never fired and MLX
        // failed later with something unrecognisable. Ask the honest disk
        // check instead: config, tokenizer, tokenizer config, weights.
        if let given = defaultLocalWeights(arguments),
           !LocalMindModel(weights: given).modelInstalled() {
            refuse("--mind=local: \(given.path) is not a model — it needs "
                + "config.json, tokenizer.json, tokenizer_config.json and a "
                + ".safetensors file.")
            return PacedEchoReply(screen: screen)
        }
        guard let weights = defaultLocalWeights(arguments) else {
            // Two lines, both true. The old single line named a fetch that
            // downloads to $TMPDIR — somewhere this demo never looks — so
            // following it left the mind still refusing.
            refuse("--mind=local: no weights found. Either:")
            refuse("  swift run bakeoff fetch --repo=mlx-community/Qwen3-4B-4bit"
                + " --into=/tmp/mmk")
            refuse("  then re-run with --model=/tmp/mmk/Qwen3-4B-4bit")
            return PacedEchoReply(screen: screen)
        }
        guard MLXRuntime.isAvailable else {
            refuse("--mind=local: no Metal shader library reachable. Run "
                + "Scripts/metallib.sh first — MLX ABORTS the process rather "
                + "than failing, so this refuses instead.")
            return PacedEchoReply(screen: screen)
        }
        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights),
                                     instructions: spoken, maxTokens: 160)
        mind.prewarm()          // loading is not warming — INSTRUMENTS §25
        return mind
    default:
        return PacedEchoReply(screen: screen)
    }
}

/// `--mouth=apple|neural` (default: apple)
///
/// The neural voice's levers are exposed too, so they can be tried by ear
/// in a live conversation rather than only measured by `bakeoff
/// voice-levers`. Ryad asked for exactly this: the sweep speaks each
/// config aloud, but you cannot TALK to a sweep.
///
///   --voice-model=0.6b|1.7b          WHICH MODEL SPEAKS (default: 0.6b);
///                                    1.7b is macOS-only (D-072)
///   --decoder=fused|stepped          multi-code decoder (default: fused)
///   --speech=latency|throughput      vocoder mode (default: latency)
///   --temperature=0.7                sampling; omit for the model default
///   --lead=400ms                     override the cushion; omit to DERIVE
///                                    it from the decoder's measured RTF
///
/// Measured on this Mac, release build, three runs each (INSTRUMENTS §31):
///
///   fused                      first audio 177–187 ms · total 6578 ms
///   stepped + latency          201–224 ms · 9353 ms
///   throughputOptimized        491–571 ms · 10622 ms   (slower, both modes)
///   temperature 0 on fused     156–177 ms · 13054 ms   (not faster, talkier)
func chosenMouth(_ arguments: [String]) -> any SpeechSynthesizing {
    func flag(_ name: String) -> String? {
        arguments.first { $0.hasPrefix("--\(name)=") }
            .map { String($0.dropFirst(name.count + 3)) }
    }
    let want = flag("mouth") ?? "apple"
    guard want == "neural" else { return AppleSpeechSynthesizer() }

    // The lever flags parse in the LIBRARY (D-072 F-3): the hand-rolled
    // parse that lived here shared no code with the tested type, which is
    // how the model lever reached the phone's Bench and never reached this
    // terminal — and how `--decoder=banana` became `.fused` silently.
    //
    // The Mac's defaults are `VoiceLevers()`'s own: `.fused` + latency.
    // `.fused` fails to load on iOS 18+, but this Mac loads and decodes it
    // fine and it wins on both numbers — the phone's workaround does not
    // belong on a machine without the bug.
    let levers: VoiceLevers
    do {
        levers = try VoiceLevers.parsed(fromArguments: arguments)
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("audio-demo: \(refusal.message)\n".utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data("audio-demo: \(error)\n".utf8))
        exit(2)
    }
    let voice = levers.makeVoice()
    // The banner reads the VOICE, not the flags (AC-162): `inForce` names
    // the model too, which the hand-rolled banner never did.
    FileHandle.standardError.write(Data("voice: \(voice.inForce)\n".utf8))
    return voice
}

/// The Hugging Face cache, so a machine that already has the weights needs
/// no flag at all.
func defaultLocalWeights(_ arguments: [String]) -> URL? {
    // `--model=` FIRST, matching `bakeoff ask`. Without it this function
    // could only look in the Hugging Face cache, so the refusal below had
    // nowhere honest to point: `bakeoff fetch` writes a flat folder to
    // $TMPDIR/mmk-fetch, which this lookup can never find. The advice was
    // wrong for as long as the escape hatch was missing.
    if let given = arguments.first(where: { $0.hasPrefix("--model=") }) {
        return URL(filePath: String(given.dropFirst("--model=".count)))
    }
    let cache = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: ".cache/huggingface/hub/models--mlx-community--Qwen3-4B-4bit/snapshots")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: cache, includingPropertiesForKeys: nil) else { return nil }
    return entries.first
}
