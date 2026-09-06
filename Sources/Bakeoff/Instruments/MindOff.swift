// The `mind-off` instrument: the seam's two minds on identical prompts,
// with refusals reported as results rather than as errors.
import Foundation
import MultiModalKit
import MultiModalKitMLX

// MARK: - mind-off (AC-130): two minds, one question, measured

/// Puts the seam's two real citizens on identical prompts and reports the
/// numbers that decide whether a mind can be SPOKEN: how long until the
/// first word, and how fast the rest arrives.
///
/// It reports refusals as results, not errors. A mind that cannot answer
/// on this machine (the Mac's Foundation Models download has been stuck
/// at `modelNotReady` for days; MLX needs a metallib) is a row that says
/// so — an empty table would be a lying instrument.
@MainActor
func runMindOff(_ arguments: [String]) async {
    let prompts = [
        "What is the capital of Italy?",
        "Name one thing a microphone does.",
        "In one sentence, why is the sky blue?"
    ]
    let spoken = "Your reply will be spoken aloud. Answer in one short, "
        + "plain sentence. No lists, no markdown."

    print("MIND-OFF (AC-130) — the same questions, both citizens of the seam.")
    print("Numbers are THIS Mac's. The phone's are not taken (D-061: that")
    print("needs a signed device build), and nothing here should be read as")
    print("a claim about a phone.")

    // 4s: the first citizen needs OS 26 and this instrument no longer
    // does. Saying which half of a bake-off did not run is the whole
    // honesty of a bake-off (D-054).
    if #available(macOS 26.0, *) {
        await mindOffRun("Apple · FoundationModels", AppleReplyGenerator(instructions: spoken),
                         prompts: prompts)
    } else {
        print("Apple · FoundationModels — NOT RUN: needs macOS 26, this Mac is older.")
    }

    await mindOffLocal(arguments, prompts: prompts, spoken: spoken)
    exit(0)
}

@MainActor
private func mindOffRun(_ label: String, _ mind: any ReplyGenerating,
                        prompts: [String]) async {
    print("\n### \(label)")
    for prompt in prompts {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let reply = try await mind.openReply(to: prompt)
            var first: Duration?
            var text = ""
            var pieces = 0
            var failure: String?
            for await update in reply.updates {
                switch update {
                case .token(let piece):
                    if first == nil { first = start.duration(to: clock.now) }
                    text += piece
                    pieces += 1
                case .failed(let why): failure = why
                case .finished: break
                }
            }
            let total = start.duration(to: clock.now)
            if let failure {
                print("  ✗ \(prompt) — \(failure)")
                continue
            }
            let ms = { (duration: Duration) in
                Double(duration.components.seconds) * 1000
                    + Double(duration.components.attoseconds) * 1e-15
            }
            let after = max(ms(total) - ms(first ?? total), 0.001)
            print(String(format: "  first token %6.0f ms · %3d pieces · %5.1f/s · thinks-aloud: %@",
                         ms(first ?? total), pieces,
                         Double(max(pieces - 1, 0)) / (after / 1000),
                         text.contains("<think>") ? "YES" : "no"))
            print("     \"\(text.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        } catch {
            print("  ✗ \(prompt) — refused at the door: \(error)")
        }
    }
}

@MainActor
private func mindOffLocal(_ arguments: [String], prompts: [String], spoken: String) async {
    let modelPath = arguments.first(where: { $0.hasPrefix("--model=") })
        .map { String($0.dropFirst("--model=".count)) }
    if let modelPath {
        let model = LocalMindModel(weights: URL(filePath: modelPath))
        if !MLXRuntime.isAvailable {
            print("\n### Local · MLX\n  ✗ skipped — no metallib reachable, and MLX")
            print("     ABORTS the process rather than failing (D-061). Build one")
            print("     into the working directory first.")
        } else {
            // Warm first, then measure: the cold number is a load, not a mind.
            let loadClock = ContinuousClock()
            let loadStart = loadClock.now
            _ = try? await model.ensureModel()
            let load = loadStart.duration(to: loadClock.now)
            let msOf = { (duration: Duration) in
                Double(duration.components.seconds) * 1000
                    + Double(duration.components.attoseconds) * 1e-15
            }
            // LOADING IS NOT WARMING. The first run of this tool measured
            // 1911 ms for the first question and 82 ms for the second,
            // with the weights already resident — so the first GENERATION
            // pays for Metal pipelines and graph warm-up. `prewarm()`
            // burns that here, off-turn, and this prints what it cost.
            let warmStart = loadClock.now
            let sacrifice = MLXReplyGenerator(model: model, maxTokens: 1)
            if let throwaway = try? await sacrifice.openReply(to: "hi") {
                for await _ in throwaway.updates { break }
                await throwaway.cancel()
            }
            let warm = warmStart.duration(to: loadClock.now)
            print(String(format: "\n(model load %.0f ms + pipeline warm-up %.0f ms — both paid ONCE, off-turn)",
                         msOf(load), msOf(warm)))
            await mindOffRun("Local · MLX",
                             MLXReplyGenerator(model: model, instructions: spoken,
                                               maxTokens: 96),
                             prompts: prompts)
        }
    } else {
        print("\n### Local · MLX\n  ✗ skipped — pass --model=/path/to/weights")
    }
}
