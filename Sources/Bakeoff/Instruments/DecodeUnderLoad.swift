// The `decode-under-load` instrument (5d piece 5's fix, AC-377; D-147, D-148):
// is the voice's first decode slow because the mind is writing on the same GPU?
//
//   swift run -c release bakeoff decode-under-load --model=DIR [--kokoro-weights=DIR] [--draws=N]
//
// For each typical first phrase, two decodes back to back, so heat drifts
// across both alike:
//
//   ALONE        Kokoro decodes the phrase; nothing else runs
//   UNDER LOAD   the real 4B is writing a long answer (its first tokens out),
//                and Kokoro decodes the same phrase meanwhile — in one process,
//                on one GPU, as the app does it
//   VOICE FIRST  the same, with the floor taken for the decode (D-148): the
//                mind, built with that floor, waits between its tokens
//
// It prints both medians and their ratio. SPEC §266: the fix is built only if
// the ratio is at least 1.5; below that, the GPU is not the cause.
import Foundation
import KokoroSwift
import MLX
import MultiModalKit
import MultiModalKitMLX
import MultiModalKitTTS
import Synchronization

/// First phrases as the phraser cuts them: a clause mark, or ~20 characters.
private let firstPhrases = ["I'm listening.", "The first law states", "Good morning!", "Sure, here is how"]

/// What the mind is asked, so that it writes for longer than any decode.
private let longPrompt = "Tell me a long story about a sailor and the sea, in many sentences."

func runDecodeUnderLoad(_ arguments: [String]) async {
    func flag(_ name: String) -> String? {
        arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }
    let weights = flag("kokoro-weights").map { KokoroWeights(directory: URL(fileURLWithPath: $0)) }
        ?? .inApplicationSupport()
    let draws = max(1, flag("draws").flatMap(Int.init) ?? 5)
    guard let modelPath = flag("model") else {
        print("decode-under-load needs --model=DIR (the local 4B's folder)")
        exit(2)
    }
    let kokoroModel = weights.directory.appending(path: "kokoro-\(weights.precision.rawValue).safetensors")
    let voiceFile = weights.directory.appending(path: "af_heart.safetensors")
    print("\n⚖️  DECODE-UNDER-LOAD (5d piece 5's fix, AC-377) — the first phrase, alone and under the 4B's writing")
    print("    kokoro: \(kokoroModel.path(percentEncoded: false)) · mind: \(modelPath) · \(draws) draws")
    guard FileManager.default.fileExists(atPath: kokoroModel.path(percentEncoded: false)),
          let style = try? MLX.loadArrays(url: voiceFile).values.first else {
        print("the Kokoro weights are not on this Mac — run `bakeoff voice-kokoro` once to fetch and cast them")
        exit(1)
    }
    MLX.Memory.cacheLimit = 20 * 1024 * 1024
    let engine = KokoroTTS(modelPath: kokoroModel, g2p: .misaki)
    let floor = VoiceFloor()
    let mind: MLXReplyGenerator
    do {
        mind = try MLXReplyGenerator(model: LocalMindModel(weights: URL(filePath: modelPath)), maxTokens: 400,
                                     floor: floor)
    } catch {
        print("the mind could not be built: \(error)")
        exit(1)
    }

    // Both warmed once, so neither number carries a first-run cost.
    _ = decodeMilliseconds(engine, style, "Hello there.")
    if let warm = try? await mind.openReply(to: "hi") { for await _ in warm.updates {} }

    let columns = await measureDraws(draws, engine: engine, style: style, mind: mind, floor: floor)
    printVerdict(columns.alone, columns.loaded, columns.first)
    exit(0)
}

/// Every draw: each first phrase alone, under the mind's writing, and with the
/// voice first — back to back, so heat drifts across all three alike.
private func measureDraws(_ draws: Int, engine: KokoroTTS, style: MLXArray, mind: MLXReplyGenerator,
                          floor: VoiceFloor) async -> Columns {
    var columns = Columns()
    for draw in 1...draws {
        for phrase in firstPhrases {
            let lone = decodeMilliseconds(engine, style, phrase)
            guard let (busy, during) = await decodeWhileWriting(engine, style, phrase, mind: mind) else {
                print("  draw \(draw) · \"\(phrase)\" — the mind did not start writing; skipped")
                continue
            }
            guard let (held, heldDuring) = await decodeWhileWriting(engine, style, phrase, mind: mind,
                                                                    floor: floor) else { continue }
            columns.alone.append(lone)
            columns.loaded.append(busy)
            columns.first.append(held)
            print(String(format: "  draw %d · %-22@ alone %4.0f · under load %4.0f · voice first %4.0f ms",
                         draw, "\"\(phrase)\"" as NSString, lone, busy, held)
                  + " · tokens meanwhile \(during) / \(heldDuring)")
        }
    }
    return columns
}

/// The three columns of the experiment, in milliseconds.
private struct Columns {
    var alone: [Double] = []
    var loaded: [Double] = []
    var first: [Double] = []
}

/// One Kokoro decode of `text`, straight through the vendor, in milliseconds.
private func decodeMilliseconds(_ engine: KokoroTTS, _ style: MLXArray, _ text: String) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    _ = try? engine.generateAudio(voice: style, language: .enUS, text: text)
    let elapsed = start.duration(to: clock.now)
    MLX.Memory.clearCache()
    return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
}

/// The same decode while the mind writes: the reply opened, its first five
/// tokens out (steady writing), the decode timed, the reply cancelled. Nil when
/// the mind wrote nothing within ten seconds.
private func decodeWhileWriting(_ engine: KokoroTTS, _ style: MLXArray, _ text: String,
                                mind: MLXReplyGenerator, floor: VoiceFloor? = nil) async -> (Double, Int)? {
    guard let run = try? await mind.openReply(to: longPrompt) else { return nil }
    let written = Mutex(0)
    let reader = Task { for await update in run.updates { if case .token = update { written.withLock { $0 += 1 } } } }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while written.withLock({ $0 }) < 5, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
    guard written.withLock({ $0 }) >= 5 else { await run.cancel(); reader.cancel(); return nil }
    let before = written.withLock { $0 }
    let hold = floor?.take()
    let milliseconds = decodeMilliseconds(engine, style, text)
    hold?.giveBack()
    let during = written.withLock { $0 } - before
    await run.cancel()
    reader.cancel()
    return (milliseconds, during)
}

private func printVerdict(_ alone: [Double], _ loaded: [Double], _ first: [Double]) {
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    let ratio = median(alone) > 0 ? median(loaded) / median(alone) : 0
    print("\n════ THE FIRST DECODE, ALONE AND UNDER LOAD — \(alone.count) pairs ════")
    print(String(format: "  alone        median %4.0f ms · min %4.0f · max %4.0f",
                 median(alone), alone.min() ?? 0, alone.max() ?? 0))
    print(String(format: "  under load   median %4.0f ms · min %4.0f · max %4.0f",
                 median(loaded), loaded.min() ?? 0, loaded.max() ?? 0))
    print(String(format: "  voice first  median %4.0f ms · min %4.0f · max %4.0f",
                 median(first), first.min() ?? 0, first.max() ?? 0))
    print(String(format: "  ratio        ×%.2f — %@", ratio,
                 (ratio >= 1.5 ? "at or over 1.5: the GPU is shared enough; build the floor (SPEC §266)"
                               : "under 1.5: the GPU is not the cause; the piece stops here and reports") as NSString))
}
