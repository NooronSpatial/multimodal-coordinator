// The bake-off runner (D-025, AC-42): the same recorded speech through every
// engine that has its model, measured and printed as a markdown table.
//
//   swift run bakeoff [wav-file] [reference-txt]
//
// Defaults to the committed fixtures. Engines without a model are skipped
// with an honest line, never silently.
import AVFoundation
import Foundation
import MultiModalKit
import MultiModalKitTesting
import MultiModalKitTTS
import TTSKit
import Synchronization
import MultiModalKitMLX
import MultiModalKitWhisper

setbuf(stdout, nil)

let arguments = CommandLine.arguments

/// Drives one reply through a mouth and times the two moments that
/// matter: when sound STARTS, and when the room goes quiet.
/// One reply's margin, handed across threads.
///
/// `reportMargins` delivers on whatever thread finished the decode, and
/// the sweep reads on its own — so the value crosses a boundary and needs
/// the lock. The rules are this repo's usual two: nothing but the store
/// happens under it, and it is never held across a suspension point.
final class MarginBox: Sendable {
    private let box = Mutex<DecodeMargin?>(nil)
    func record(_ margin: DecodeMargin) { box.withLock { $0 = margin } }
    /// Reads AND clears: a run that reported nothing must not silently
    /// inherit the previous run's number.
    func take() -> DecodeMargin? {
        box.withLock { stored in
            let margin = stored
            stored = nil
            return margin
        }
    }
    func reset() { _ = take() }
}

func measure(_ mouth: any SpeechSynthesizing, _ text: String) async throws
    -> (firstAudio: Double, total: Double)
{
    let run = try await mouth.openUtterance()
    let clock = ContinuousClock()
    let t0 = clock.now
    var firstAudio: Duration?

    // THE READER RUNS FIRST, AND THAT IS A CORRECTION.
    //
    // The first version of this function fed the whole sentence,
    // closed it, and only THEN read the update stream. That is fair
    // to Apple, whose `feed` hands the text to the framework and
    // returns at once — and deeply unfair to the neural mouth, whose
    // `feed` does not return until the decode is finished. Its
    // `.started` was sent on time and sat buffered in the stream;
    // this function stamped it when it finally READ it. The result
    // was a first-audio number that was really a total, and a 202x
    // ratio that measured a mistake.
    //
    // The tell was in the table: neural first-audio within ~100 ms
    // of neural total, on every single row. A step trace settled it
    // — audio steps arrive every ~80 ms from the start.
    //
    // So: this task parks on the stream, and the FEEDING moves to a
    // child. The gate below is why there is no sleep here — the
    // feeder waits for a fact, not for a guess (the determinism rule).
    let gate = AsyncStream<Void>.makeStream()
    let feeder = Task {
        for await _ in gate.stream { break }
        await run.feed(text)
        await run.finishTokens()
    }
    gate.continuation.finish()      // opens the gate: the feeder may go
    for await update in run.updates {
        switch update {
        case .started: if firstAudio == nil { firstAudio = t0.duration(to: clock.now) }
        case .failed(let why): print("   ⚠️  \(why)")
        case .finished: break
        }
    }
    let total = t0.duration(to: clock.now)
    await feeder.value
    func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15
    }
    return (firstAudio.map(ms) ?? -1, ms(total))
}

// `swift run bakeoff voice-spike` — AC-102's gates, measured before any
// adoption ruling (D-045, the D-023 discipline). Two mouths, the same
// sentences, at the SEAM both implement, so the numbers are comparable
// by construction rather than by argument.
// MARK: - memory-fit: do the mind and the mouth fit together?

/// `swift run bakeoff memory-fit --model=<weights>`
///
/// From a phone crash: "Terminated due to memory issue" with the local
/// mind on 4B and the NEURAL voice selected. iOS jetsam does not
/// negotiate, so the question is arithmetic — how big is each, and do
/// they fit? This loads them one at a time and prints the footprint iOS
/// would actually judge (phys_footprint, not resident size).
if arguments.count > 1, arguments[1] == "memory-fit" {
    func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    print(String(format: "baseline            %8.0f MB", footprintMB()))

    // HELD for the whole measurement. The first version let this go out
    // of scope, the weights were freed, and the footprint went DOWN after
    // adding the voice — a measurement that flattered the answer.
    var heldMind: LocalMindModel?
    if let given = arguments.first(where: { $0.hasPrefix("--model=") }) {
        let path = String(given.dropFirst("--model=".count))
        let model = LocalMindModel(weights: URL(filePath: path))
        heldMind = model
        if MLXRuntime.isAvailable, (try? await model.ensureModel()) != nil {
            print(String(format: "+ local mind        %8.0f MB  (MLX active %d MB)",
                         footprintMB(), MLXRuntime.activeMemoryBytes / 1_048_576))
        } else {
            print("+ local mind        SKIPPED (no metallib or no weights)")
        }
    }

    let voice = NeuralVoice()
    if await voice.modelInstalled() {
        do {
            try await voice.ensureModel()
            print(String(format: "+ neural voice      %8.0f MB", footprintMB()))
        } catch {
            print("+ neural voice      FAILED: \(error)")
        }
    } else {
        print("+ neural voice      SKIPPED (not installed on this Mac)")
    }
    print(String(format: "BOTH TOGETHER       %8.0f MB", footprintMB()))
    _ = heldMind          // keep the weights alive to the very end
    print("")
    print("A Mac has no jetsam. iOS kills an app well below its RAM — the")
    print("budget is a few GB on a modern iPhone, and this total is what")
    print("counts against it.")
    exit(0)
}

// MARK: - fetch: prove the DOWNLOAD path, away from any UI

/// `swift run bakeoff fetch --repo=mlx-community/Qwen3-0.6B-4bit --into=/tmp/x`
///
/// Exists because a field report ("downloading is not starting") cannot
/// be chased through a phone's UI: this runs the same
/// `LocalMindModel.download` the app calls, prints every progress
/// callback, and says plainly whether the files landed.
if arguments.count > 1, arguments[1] == "fetch" {
    let repo = arguments.first(where: { $0.hasPrefix("--repo=") })
        .map { String($0.dropFirst("--repo=".count)) }
        ?? "mlx-community/Qwen3-0.6B-4bit"
    let into = arguments.first(where: { $0.hasPrefix("--into=") })
        .map { URL(filePath: String($0.dropFirst("--into=".count))) }
        ?? URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-fetch")
    try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)

    let model = LocalMindModel(repoID: repo, in: into)
    print("repo:      \(repo)")
    print("target:    \(model.weights.path)")
    print("installed before: \(model.modelInstalled())")

    let clock = ContinuousClock()
    let start = clock.now
    let ticks = Mutex(0)
    do {
        try await model.download { fraction in
            let n = ticks.withLock { $0 += 1; return $0 }
            if n <= 5 || n % 25 == 0 {
                print(String(format: "  progress callback #%d: %.1f%%", n, fraction * 100))
            }
        }
    } catch {
        print("FAILED after \(clock.now - start): \(error)")
        exit(1)
    }
    print("callbacks:  \(ticks.withLock { $0 })")
    print("took:       \(start.duration(to: clock.now))")
    print("installed after: \(model.modelInstalled())")
    if let listed = try? FileManager.default.contentsOfDirectory(atPath: model.weights.path) {
        print("files:      \(listed.sorted().joined(separator: ", "))")
    }
    exit(0)
}

// MARK: - ask: talk to the second mind on this Mac

/// The Mac's way of USING the second mind rather than measuring it.
///
///   swift run bakeoff ask "what is the capital of italy?"   one question
///   swift run bakeoff ask                                   keep asking
///
/// The weights default to the Hugging Face cache, so there is nothing to
/// type on a machine that already has them. Tokens print AS THEY ARRIVE,
/// which is the seam's whole point made visible: the mouth would be
/// speaking these before the sentence exists.
if arguments.count > 1, arguments[1] == "ask" {
    func defaultWeights() -> URL? {
        if let given = arguments.first(where: { $0.hasPrefix("--model=") }) {
            return URL(filePath: String(given.dropFirst("--model=".count)))
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: ".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil) else { return nil }
        return entries.first
    }

    guard MLXRuntime.isAvailable else {
        print("no Metal shader library reachable, so MLX cannot be touched at all.")
        print("MLX ABORTS the process rather than failing (D-061), so this stops here.")
        print("fix it with:  Scripts/metallib.sh")
        exit(2)
    }
    guard let weights = defaultWeights(),
          FileManager.default.fileExists(atPath: weights.path) else {
        print("no weights found. pass --model=/path/to/Qwen3-0.6B-4bit")
        exit(2)
    }

    let model = LocalMindModel(weights: weights)
    let mind = MLXReplyGenerator(
        model: model,
        // WORD FOR WORD the demo's text by default, so this tool
        // reproduces the phone rather than approximating it — a field
        // report cannot be chased with a different prompt than the one
        // that produced it. `--system=` overrides it so a candidate fix
        // can be MEASURED against the same inputs before anyone ships it.
        instructions: arguments.first(where: { $0.hasPrefix("--system=") })
            .map { String($0.dropFirst("--system=".count)) }
            ?? "Your reply will be spoken aloud by a synthetic voice "
            + "and never shown as text. Answer in ONE short sentence. Do not "
            + "add extra facts, background or explanation unless the person "
            + "asks for them. Never use lists, bullet points, numbered items, "
            + "markdown, code, or headings.",
        maxTokens: 160)

    let clock = ContinuousClock()
    let loadStart = clock.now
    print("loading \(weights.lastPathComponent)…")
    do { _ = try await model.ensureModel() } catch {
        print("could not load the model: \(error)"); exit(2)
    }
    // LOADING IS NOT WARMING (INSTRUMENTS §25) — burn the pipeline cost
    // here, so the first real question is as fast as the second.
    if let warm = try? await mind.openReply(to: "hi") {
        for await _ in warm.updates { break }
        await warm.cancel()
    }
    let ready = loadStart.duration(to: clock.now)
    print(String(format: "MLX memory: active %d MB · peak %d MB (RESIDENT — MLX does not mmap)",
                 MLXRuntime.activeMemoryBytes / 1_048_576,
                 MLXRuntime.peakMemoryBytes / 1_048_576))
    print(String(format: "ready in %.1f s · everything below runs on this Mac, offline\n",
                 Double(ready.components.seconds)
                     + Double(ready.components.attoseconds) * 1e-18))

    // THE LOG, so a Mac session can be shared the same way the phone's
    // can. Written after every turn rather than at exit: the turn worth
    // sharing is often the one before something hangs.
    let logURL = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "mind-log.md")
    var log = "# Conversation log — bakeoff ask (Mac)\n\n"
    log += "model: \(weights.lastPathComponent)\nmind: Local (MLX)\n\n"

    func answer(_ question: String) async {
        let start = clock.now
        var first: Duration?
        var pieces = 0
        var said = ""
        do {
            let reply = try await mind.openReply(to: question)
            for await update in reply.updates {
                switch update {
                case .token(let t):
                    if first == nil { first = start.duration(to: clock.now) }
                    pieces += 1
                    said += t
                    FileHandle.standardOutput.write(Data(t.utf8))   // AS IT ARRIVES
                case .failed(let why): print("\n  ✗ \(why)")
                case .finished: break
                }
            }
        } catch {
            print("  ✗ refused at the door: \(error)")
            return
        }
        let ms = { (d: Duration) in
            Double(d.components.seconds) * 1000
                + Double(d.components.attoseconds) * 1e-15
        }
        let total = start.duration(to: clock.now)
        let after = max(ms(total) - ms(first ?? total), 0.001)
        print(String(format: "\n   [first word %.0f ms · %d pieces · %.0f/s]\n",
                     ms(first ?? total), pieces,
                     Double(max(pieces - 1, 0)) / (after / 1000)))
        log += "## \(question)\n\n\(said.isEmpty ? "_(no words)_" : said)\n\n"
        log += String(format: "first word %.0f ms · %d pieces\n\n",
                      ms(first ?? total), pieces)
        try? Data(log.utf8).write(to: logURL)
    }

    // One question on the command line, or keep asking until ctrl-D.
    let asked = arguments.dropFirst(2).filter { !$0.hasPrefix("--") }
    if !asked.isEmpty {
        await answer(asked.joined(separator: " "))
        exit(0)
    }
    print("type a question, or ctrl-D to stop.")
    while true {
        FileHandle.standardOutput.write(Data("> ".utf8))
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty
        else { break }
        await answer(line)
    }
    print("bye. log written to \(logURL.path)")
    exit(0)
}

// MARK: - mind-off (AC-130): two minds, one question, measured

/// Puts the seam's two real citizens on identical prompts and reports the
/// numbers that decide whether a mind can be SPOKEN: how long until the
/// first word, and how fast the rest arrives.
///
/// It reports refusals as results, not errors. A mind that cannot answer
/// on this machine (the Mac's Foundation Models download has been stuck
/// at `modelNotReady` for days; MLX needs a metallib) is a row that says
/// so — an empty table would be a lying instrument.
if arguments.count > 1, arguments[1] == "mind-off" {
    let prompts = [
        "What is the capital of Italy?",
        "Name one thing a microphone does.",
        "In one sentence, why is the sky blue?",
    ]
    let spoken = "Your reply will be spoken aloud. Answer in one short, "
        + "plain sentence. No lists, no markdown."

    func run(_ label: String, _ mind: any ReplyGenerating) async {
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
                    case .token(let t):
                        if first == nil { first = start.duration(to: clock.now) }
                        text += t
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
                let ms = { (d: Duration) in
                    Double(d.components.seconds) * 1000
                        + Double(d.components.attoseconds) * 1e-15
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

    print("MIND-OFF (AC-130) — the same questions, both citizens of the seam.")
    print("Numbers are THIS Mac's. The phone's are not taken (D-061: that")
    print("needs a signed device build), and nothing here should be read as")
    print("a claim about a phone.")

    await run("Apple · FoundationModels", AppleReplyGenerator(instructions: spoken))

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
            let msOf = { (d: Duration) in
                Double(d.components.seconds) * 1000
                    + Double(d.components.attoseconds) * 1e-15
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
            await run("Local · MLX", MLXReplyGenerator(model: model, instructions: spoken,
                                                       maxTokens: 96))
        }
    } else {
        print("\n### Local · MLX\n  ✗ skipped — pass --model=/path/to/weights")
    }
    exit(0)
}

if arguments.count > 1, arguments[1] == "voice-spike" {
    let sentences = [
        "How is the weather today?",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
        "Should I take a jacket?",
    ]

    // Flags, so the SAME instrument can measure the before and the after
    // (AC-106) instead of two instruments being compared to each other.
    // `--stepped` reproduces the pre-D-047 baseline; the default is now
    // the library's, which is `.fused`.
    let forceStepped = arguments.contains("--stepped")
    let leadMS = arguments.first(where: { $0.hasPrefix("--lead=") })
        .flatMap { Int($0.dropFirst("--lead=".count)) }
    // `nil`, NOT a constant. An explicit lead defeats the decoder-aware
    // derivation, and this line used to pass `NeuralVoice.defaultLead` —
    // `.fused`'s zero — so `--stepped` was measured with no cushion at all.
    // Every `--stepped` number this tool produced before 2026-08-23 was
    // taken that way.
    let voice = NeuralVoice(
        lead: leadMS.map { Duration.milliseconds($0) },
        multiCodeDecoderMode: forceStepped ? .stepped : .fused)
    guard await voice.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    print("\n🎚  VOICE SPIKE (AC-102) — the numbers the adoption ruling needs")
    // The voice's OWN lead, never a recomputation of what it should be:
    // an instrument that reports a number it did not read cannot notice
    // when the two disagree, which is the whole story of this bug.
    print("    decoder: \(forceStepped ? ".stepped" : ".fused") · lead: \(voice.lead)"
        + (leadMS == nil ? " (derived)" : " (--lead)"))
    print("    warm-up excluded, same rule as BAKEOFF.md: the first load compiles graphs")
    _ = try? await measure(voice, "Warming up the neural pipeline.")   // excluded

    print("\n| sentence | mouth | first audio | total | ")
    print("|---|---|---|---|")
    var neuralFirst: [Double] = []
    var appleFirst: [Double] = []
    for text in sentences {
        let short = text.count > 34 ? String(text.prefix(34)) + "…" : text
        if let n = try? await measure(voice, text) {
            neuralFirst.append(n.firstAudio)
            print(String(format: "| %@ | neural | **%.0f ms** | %.0f ms |", short, n.firstAudio, n.total))
        }
        if let a = try? await measure(AppleSpeechSynthesizer(), text) {
            appleFirst.append(a.firstAudio)
            print(String(format: "| %@ | Apple | **%.0f ms** | %.0f ms |", short, a.firstAudio, a.total))
        }
    }
    func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    print(String(format: "\nfirst-audio mean — neural %.0f ms · Apple %.0f ms · ratio %.1fx",
                 mean(neuralFirst), mean(appleFirst),
                 mean(appleFirst) > 0 ? mean(neuralFirst) / mean(appleFirst) : 0))
    print("\nNOT measured here, and not claimed: STOP latency (request → the room")
    print("actually quiet). The seam reports its own bookkeeping instantly; proving")
    print("silence needs the microphone probe, on the device. Thermal likewise.")
    exit(0)
}

/// A tiny seeded generator, so the blind order is REPRODUCIBLE. The seed
/// is printed with the result: a listening test nobody can re-run is an
/// anecdote, and this repo does not record anecdotes as data.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// CAPTURING WHAT THE MOUTH ACTUALLY SAYS (AC-103, the objective half).
///
/// A tap on the engine's mixer, which is deliberately the LAST point
/// before the speaker: it catches the audio including our own rendering,
/// resampling and buffering, which is what a listener would really hear.
/// Capturing the model's raw 24 kHz PCM instead would flatter us by
/// measuring the decoder rather than the pipeline.
///
/// `@unchecked Sendable` with the usual proof: one `Mutex` owns every
/// mutable byte, the tap closure only appends under it, and nothing
/// suspends while it is held.
final class MixerCapture: @unchecked Sendable {
    private let collected = Mutex<(samples: [Float], rate: Double)>(([], 0))
    private let engine: AVAudioEngine

    /// THE ENGINE IS NOT STARTED HERE, and that is the whole lesson of
    /// this type. The first version called `prepare()` and `start()` in
    /// this initialiser, before any player node existed. An engine
    /// started with no source node never pulls, so the player attached
    /// afterwards never rendered — and because the buffers are now
    /// scheduled with `.dataPlayedBack`, their completions correctly
    /// never fired and the whole tool hung at 0% CPU.
    ///
    /// The old `.dataConsumed` callback would have reported those
    /// buffers "done" and produced a table of silence. The hang was the
    /// honest failure of a more honest callback.
    ///
    /// So: `NeuralVoiceRun` starts the engine, with its player already
    /// attached, and the tap goes on afterwards.
    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// The capture's true rate, learned from the first buffer rather
    /// than asked of a node that may not be configured yet.
    var sampleRate: Double { collected.withLock { $0.rate } }

    func record() {
        collected.withLock { $0 = ([], 0) }
        // `self`, not the Mutex: a Mutex is non-copyable, so a capture
        // list would try to consume it out of the object that owns it.
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [self] buffer, _ in
            guard let channel = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            // Channel 0 only: the source is mono, so the mixer's second
            // channel is a copy and averaging would buy nothing.
            let slice = Array(UnsafeBufferPointer(start: channel[0], count: frames))
            collected.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = buffer.format.sampleRate
            }
        }
    }

    func stop() -> [Float] {
        engine.mainMixerNode.removeTap(onBus: 0)
        return collected.withLock { $0.samples }
    }
}

/// Apple's mouth does NOT render through our engine, so the tap cannot
/// see it. `write` is the framework's own offline path — same synthesis,
/// no speaker. Stated as a caveat wherever its numbers appear: it is not
/// the identical code path we ship, though it is the identical voice.
func captureApple(_ text: String) async -> (samples: [Float], sampleRate: Double)? {
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    // One lock over everything mutable, `resumed` included: the callback
    // arrives on the framework's thread, and a plain `var` flag read and
    // written from there is a race that would eventually resume a
    // continuation twice — which traps.
    let box = Mutex<(samples: [Float], rate: Double, resumed: Bool)>(([], 0, false))

    let result: (samples: [Float], sampleRate: Double)? = await withCheckedContinuation {
        continuation in
        synthesizer.write(utterance) { buffer in
            // `synthesizer` is touched HERE ON PURPOSE. Nothing else
            // retains it once this function's frame is gone, and a
            // deallocated synthesizer simply never calls back — the
            // continuation then waits forever. That is precisely how
            // this tool hung the first time it ran, at 0% CPU on
            // sentence 1, and `withExtendedLifetime` below is the belt
            // to this closure's braces.
            _ = synthesizer
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                let finished: (samples: [Float], sampleRate: Double)?? = box.withLock {
                    guard !$0.resumed else { return .none }
                    $0.resumed = true
                    return .some($0.samples.isEmpty ? nil : ($0.samples, $0.rate))
                }
                if let finished { continuation.resume(returning: finished) }
                return
            }
            guard let channel = pcm.floatChannelData else { return }
            let slice = Array(UnsafeBufferPointer(start: channel[0],
                                                  count: Int(pcm.frameLength)))
            box.withLock {
                $0.samples.append(contentsOf: slice)
                $0.rate = pcm.format.sampleRate
            }
        }
    }
    withExtendedLifetime(synthesizer) {}
    return result
}

// `swift run bakeoff voice-onmic` — THE COMBINATION NOTHING HAS EVER
// TESTED, and the one the iPhone keeps failing on.
//
// Every neural measurement so far rendered onto an engine the mouth
// owned. The phone renders onto the CAPTURE engine — a live
// AVAudioEngine with a voice-processing input unit and a microphone tap
// already running — and that path has produced five faults in one field
// session while never once being exercised on a machine I control.
//
// This Mac has a microphone and voice processing. So it can run exactly
// that path, here, instead of costing Ryad another rebuild.
if arguments.count > 1, arguments[1] == "voice-onmic" {
    print("\n🎤  NEURAL VOICE ON A LIVE CAPTURE ENGINE (AC-104's Mac rehearsal)")
    print("    the path the phone runs, on hardware I can watch\n")

    // THE ONE VARIABLE UNDER TEST. `--no-output-chain` builds capture
    // exactly as it was before AC-108 touched it, so the two runs differ
    // in one line and the comparison means something.
    let wantsOutputChain = !arguments.contains("--no-output-chain")
    print("    output chain: \(wantsOutputChain ? "YES (the neural path)" : "no (the pre-AC-108 path)")")
    let (producer, _) = AudioRing.create(minimumCapacity: 48_000)
    let microphone = MicrophoneSource(voiceProcessing: true,
                                      hostsPlayback: wantsOutputChain)
    do {
        try microphone.start(into: producer)
    } catch {
        print("❌ capture would not start: \(error)")
        exit(1)
    }
    print("    capture running: \(microphone.isRunning), "
          + "engine: \(microphone.engineIsRunning), "
          + "voice processing: \(microphone.voiceProcessingActive)")
    print("    input rate: \(Int(microphone.sampleRate)) Hz")

    let voice = NeuralVoice(renderingOn: microphone.playbackHost)
    guard await voice.modelInstalled() else {
        print("❌ the neural model is not installed")
        microphone.stop(); exit(1)
    }
    do { try await voice.ensureModel() }
    catch { print("❌ load failed: \(error)"); microphone.stop(); exit(1) }

    // The host's rate, read back AFTER an attach — 0 means nothing ever
    // rendered, which is itself the answer.
    func report(_ label: String) {
        print("    \(label): engine \(microphone.engineIsRunning ? "running" : "STOPPED")"
              + " · reconfigs \(microphone.configurationChanges)"
              + " · host rate \(Int(microphone.playbackHost.outputSampleRate))"
              + " · hosted \(microphone.playbackHost.hostedCount)")
    }
    report("before speaking")

    for attempt in 1...2 {
        print("\n  utterance \(attempt):")
        let run = try await voice.openUtterance()
        let clock = ContinuousClock()
        let t0 = clock.now
        var sawStarted = false
        var sawFinished = false
        var failure: String?

        let feeder = Task {
            await run.feed("Testing the neural voice on the capture engine.")
            await run.finishTokens()
        }
        for await update in run.updates {
            switch update {
            case .started: sawStarted = true
            case .finished: sawFinished = true
            case .failed(let why): failure = why
            }
        }
        await feeder.value
        let elapsed = t0.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) * 1e-15
        print(String(format: "    started %@ · finished %@ · %.0f ms%@",
                     sawStarted ? "YES" : "NO", sawFinished ? "YES" : "NO", ms,
                     failure.map { " · FAILED: \($0)" } ?? ""))
        report("    after")
    }

    microphone.stop()
    print("\n    after stop: engine \(microphone.engineIsRunning ? "running" : "stopped")"
          + " · reconfigs \(microphone.configurationChanges)")
    print("\n  READ IT AS: started NO means the reply never became audible —")
    print("  the same silence the phone shows. reconfigs above 0 means the")
    print("  engine tore its own graph down, which is the phone's vanishing")
    print("  microphone indicator. Neither can be blamed on the model.")
    exit(0)
}

// `swift run bakeoff voice-selfecho` — CAN THE ASSISTANT HEAR ITSELF? (4k, AC-154)
//
// The phone's self-barge (§37, §38) is a microphone-side question: while
// the reply plays, does mic energy cross the 0.021 gate? The echo probe
// cannot answer it for the SHIELDED arrangement — it predates the shield
// and speaks through a bare AVSpeechSynthesizer. voice-onmic cannot either:
// it proves the reply RENDERS, and never reads the microphone side at all.
// So this instrument is both halves at once: the shielded neural voice on
// the live capture engine, and the ring being read while it speaks.
//
// THE CONTROL IS THE POINT (D-054 rule 5): run it with --no-shield and the
// voice renders on its OWN engine, where the canceller cannot see it. An
// instrument that reports "clean" must be able to show "leaking" on demand,
// or its clean is indistinguishable from blindness.
//
// §23's caveat carries over verbatim: a Mac graph verdict does not transfer
// to the phone. This develops the METHOD and the fix's before/after; the
// phone's own `echo?` rows convict.
if arguments.count > 1, arguments[1] == "voice-selfecho" {
    let shielded = !arguments.contains("--no-shield")
    // THE EYES CONTROL. The first runs of this instrument found that
    // macOS's voice-processing unit cancels SYSTEM-WIDE output — even a
    // reply on the voice's own engine came back at the quiet-room level,
    // where the same arrangement on iOS measured peak 1.0 (§23). So on a
    // Mac the shield/no-shield pair cannot prove the instrument can see.
    // --no-vp turns voice processing off entirely: a raw microphone MUST
    // hear the speaker, or the instrument is blind and every "clean" it
    // ever printed was worthless.
    let rawMicrophone = arguments.contains("--no-vp")
    let gate: Float = arguments.first(where: { $0.hasPrefix("--gate=") })
        .flatMap { Float($0.dropFirst("--gate=".count)) } ?? 0.021

    print("\n🪞  SELF-ECHO (AC-154) — does the assistant's voice cross its own gate?")
    let arrangement = rawMicrophone
        ? "RAW MIC (--no-vp) — the eyes control: this MUST leak"
        : (shielded ? "SHIELDED — reply on the capture engine"
                    : "no shield — reply on the voice's OWN engine")
    print("    arrangement: \(arrangement)")
    print("    gate: \(gate)  (the demo's default is 0.021)\n")

    let (producer, consumer) = AudioRing.create(minimumCapacity: 1 << 17)
    let microphone = MicrophoneSource(voiceProcessing: !rawMicrophone,
                                      hostsPlayback: shielded)
    do { try microphone.start(into: producer) }
    catch { print("❌ capture would not start: \(error)"); exit(1) }
    // ASKED FOR is not GOT — the echo probe's lesson. Without this line a
    // loud residual is ambiguous between "canceller refused" and
    // "canceller running but never shown the reply".
    print("    voice processing: \(microphone.voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")")

    let voice = NeuralVoice(renderingOn: shielded ? microphone.playbackHost : nil)
    guard await voice.modelInstalled() else {
        print("❌ the neural model is not installed — run: swift run bakeoff voice-install")
        microphone.stop(); exit(1)
    }
    do { try await voice.ensureModel() }
    catch { print("❌ load failed: \(error)"); microphone.stop(); exit(1) }

    // The measuring loop is the echo probe's, verbatim in spirit: the pump
    // is not running, so this is the ring's sole reader and the raw truth.
    var scratch = [Float](repeating: 0, count: consumer.capacity)
    func window() -> (peak: Float, rms: Float) {
        var peak: Float = 0
        var sumOfSquares: Float = 0
        var frames = 0
        scratch.withUnsafeMutableBufferPointer { buffer in
            let result = consumer.read(into: buffer)
            for i in 0..<result.framesRead {
                let sample = buffer[i]
                peak = max(peak, abs(sample))
                sumOfSquares += sample * sample
            }
            frames = result.framesRead
        }
        return (peak, (sumOfSquares / Float(max(frames, 1))).squareRoot())
    }
    func report(_ label: String, _ windows: [(peak: Float, rms: Float)]) {
        let over = windows.filter { $0.peak > gate }.count
        let peak = windows.map(\.peak).max() ?? 0
        let worstRMS = windows.map(\.rms).max() ?? 0
        print(String(format: "    %@  peak %.4f · worst rms %.4f · %d of %d windows over the gate",
                     label, peak, worstRMS, over, windows.count))
        // WHEN, not only how many — the discriminator between the suspects
        // (§23): residual-over-gate leaks SPREAD across the reply;
        // convergence and the attach transient CLUSTER at its start.
        let crossings = windows.enumerated().filter { $0.element.peak > gate }
        if !crossings.isEmpty && crossings.count < windows.count {
            let timeline = crossings
                .map { String(format: "%.2fs@%.3f", Double($0.offset) * 0.25, $0.element.peak) }
                .joined(separator: "  ")
            print("      over the gate at: \(timeline)")
        }
    }

    // DRAIN FIRST, and the first run is why. The ring has been filling
    // since the microphone started — through the whole model load — so the
    // first read returned minutes of backlog and called the quiet room
    // peak 0.61. A baseline that contains the past is not a baseline.
    _ = window()
    print("    measuring the quiet room (2 s) — stay quiet…")
    var quiet: [(peak: Float, rms: Float)] = []
    for _ in 0..<8 {
        try? await Task.sleep(for: .milliseconds(250))
        quiet.append(window())
    }
    report("quiet room:     ", quiet)

    // ONE long sentence, the bench's own, so the phone and the Mac measure
    // the same work. The reader samples every 250 ms UNTIL the terminal —
    // gated on the fact of finishing, never on a duration guess.
    print("    speaking — stay quiet…")
    let run = try await voice.openUtterance()
    let feeder = Task {
        await run.feed("The audio travels through a ring buffer into a pump "
            + "that cuts it into small chunks.")
        await run.finishTokens()
    }
    let sampler = Task { () -> [(peak: Float, rms: Float)] in
        var samples: [(peak: Float, rms: Float)] = []
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            samples.append(window())
        }
        return samples
    }
    var failure: String?
    for await update in run.updates {
        if case .failed(let why) = update { failure = why }
    }
    await feeder.value
    sampler.cancel()
    let speaking = await sampler.value
    if let failure { print("    ⚠️  decode failed: \(failure)") }
    report("while speaking: ", speaking)

    let leakWindows = speaking.filter { $0.peak > gate }.count
    print("")
    if rawMicrophone {
        print(leakWindows > 0
            ? "    EYES: proven — the raw microphone heard the voice "
                + "(\(leakWindows) windows over the gate). Cancelled runs mean something."
            : "    EYES: FAILED — a raw microphone did not hear the voice. Either "
                + "the output is silent or this instrument is blind; NO other run "
                + "of it can be trusted until this one leaks.")
    } else if !microphone.voiceProcessingActive {
        print("    VERDICT: unusable — the platform refused voice processing, so")
        print("    nothing here says anything about the canceller.")
    } else if leakWindows == 0 {
        print("    VERDICT: no window crossed the gate — on THIS machine, this")
        print("    arrangement would never self-barge.")
    } else {
        print("    VERDICT: \(leakWindows) window(s) crossed the gate — each one is a")
        print("    would-be self-barge onset. Compare the two arrangements:")
        print("    the shield's whole claim is that this number collapses.")
    }
    microphone.stop()
    exit(0)
}

// `swift run bakeoff voice-wer` — AC-103's OBJECTIVE half, and the
// instrument the fused/stepped question actually needs.
//
// speak → capture → transcribe → WER against the text we asked for.
// Intelligibility as a NUMBER, using the two transcription engines this
// repo already owns, which is the whole point: a pipeline that can
// listen can grade its own mouth.
//
// WHY SEVERAL DRAWS PER SENTENCE. §11 and §13 both recorded it: this
// model is non-deterministic in LENGTH — 8240 ms of audio for a sentence
// one run, 6480 ms the next — and the seed did not fix it. One draw per
// mouth would compare draws, not mouths. Averaging over draws is what
// makes the comparison about the decoder.
if arguments.count > 1, arguments[1] == "voice-wer" {
    let sentences = [
        "How is the weather today?",
        "I can hear you. Say that again and I will stop talking.",
        "The audio travels through a ring buffer into a pump that cuts it into small chunks.",
    ]
    let draws = 3
    let leadOverride: Duration? = {
        do { return try VoiceLevers.parsed(fromArguments: arguments).lead }
        catch { return nil }   // a bad value is reported by the parse below
    }()
    // `--lead=` is THE CONTROL for the starvation question (4l, 2026-08-27).
    // Ryad's ear caught a hitch in audio rendered on this Mac with the
    // phone's levers, and two explanations fit the same recording:
    // the bank ran dry (RTF 1.114 > 1.0 with only 800 ms banked), or the
    // throughput vocoder simply speaks in a choppier way. They are told
    // apart by ONE variable — starvation disappears when the cushion is
    // large enough, prosody does not — so the cushion had to stop being
    // a constant here. Default unchanged, so every earlier number in
    // INSTRUMENTS still describes the same run.
    let lead = leadOverride ?? Duration.milliseconds(800)

    // ONE ENGINE PER VOICE, and that is a correction. Sharing a single
    // engine put every fused utterance immediately after a stepped
    // teardown detaching a node from the same graph — and the three
    // empty captures in the first run were all fused, all following a
    // stepped draw. Whether or not that race is the cause, a measurement
    // cannot be allowed to depend on it.
    let steppedEngine = AVAudioEngine()
    let fusedEngine = AVAudioEngine()
    let steppedCapture = MixerCapture(engine: steppedEngine)
    let fusedCapture = MixerCapture(engine: fusedEngine)

    // The seam's plain implementation (AC-108). The tool still needs the
    // engine itself, because it taps the mixer — but the voice only ever
    // sees a host, so the start-order rule that hung this tool now lives
    // in one place instead of here.
    // WHICH MODEL SPEAKS (AC-163), through the library's one parser. The
    // sweep raised a question its own numbers cannot answer: 1.7B makes
    // MUCH shorter audio for the same sentence, and "compact" and
    // "dropping words" look identical on a stopwatch. This tool is the
    // one that can tell them apart, so it must be able to run either.
    let werLevers: VoiceLevers
    do {
        werLevers = try VoiceLevers.parsed(fromArguments: arguments)
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("bakeoff: \(refusal.message)\n".utf8))
        exit(2)
    }
    let werModel = werLevers.model
    // THE VOCODER IS A LEVER HERE TOO, and that is the point of this run:
    // the phone cannot load `.fused` at all, so what it ships is
    // `stepped + throughput` — a config this tool could not previously
    // render, which meant every WER number here described a mouth the
    // PHONE never uses. `--speech=throughput` renders the phone's exact
    // levers on this Mac, so a Mac ear can judge what the phone speaks.
    let stepped = NeuralVoice(variant: werModel,
                              renderingOn: AudioEnginePlaybackHost(engine: steppedEngine),
                              lead: lead, multiCodeDecoderMode: .stepped,
                              speechDecoderMode: werLevers.vocoder)
    let fused = NeuralVoice(variant: werModel,
                            renderingOn: AudioEnginePlaybackHost(engine: fusedEngine),
                            lead: lead, multiCodeDecoderMode: .fused,
                            speechDecoderMode: werLevers.vocoder)
    // `--save-audio=DIR` writes every graded capture as a WAV, so the ear
    // ruling AC-163 asks for does not depend on standing beside this Mac
    // while it speaks. Off by default: a measurement tool should not
    // litter unless asked.
    let audioDirectory: URL? = arguments
        .first { $0.hasPrefix("--save-audio=") }
        .map { URL(filePath: String($0.dropFirst("--save-audio=".count))) }
    if let audioDirectory {
        try? FileManager.default.createDirectory(
            at: audioDirectory, withIntermediateDirectories: true)
    }
    func saveWav(_ samples: [Float], rate: Double, named name: String) -> String? {
        guard let audioDirectory, rate > 0, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!,
                                               count: samples.count)
        }
        let url = audioDirectory.appending(path: "\(name).wav")
        do {
            let file = try AVAudioFile(forWriting: url,
                                       settings: format.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            try file.write(from: buffer)
            return url.lastPathComponent
        } catch {
            FileHandle.standardError.write(
                Data("   could not save \(name).wav: \(error)\n".utf8))
            return nil
        }
    }
    guard await stepped.modelInstalled() else {
        print("the neural voice's model is not installed — run: swift run bakeoff voice-install")
        exit(1)
    }

    let whisper = WhisperEngine()
    guard await whisper.modelInstalled() else {
        print("whisper's model is not installed — the grader is missing, so nothing is graded")
        exit(1)
    }

    print("\n📝  ROUND-TRIP WER (AC-103, the objective half)")
    print("    speak → capture at the mixer → transcribe → WER")
    print("    \(draws) draws per neural mouth per sentence, because the voice")
    print("    is non-deterministic in length (INSTRUMENTS §11, §13).\n")

    print("    loading…")
    do { try await stepped.ensureModel(); try await fused.ensureModel() }
    catch { print("load failed: \(error)"); exit(1) }
    _ = try? await measure(stepped, "Warming up.")
    _ = try? await measure(fused, "Warming up.")
    _ = try? await BakeoffHarness.measure(engine: whisper, label: "warmup",
                                          samples: [Float](repeating: 0, count: 16000),
                                          sampleRate: 16000, reference: "warm up")

    struct Row { let mouth: String; let sentence: Int; let draw: Int
                 let wer: Double; let heard: String }
    var rows: [Row] = []

    func grade(_ mouth: String, _ sentenceIndex: Int, _ draw: Int,
               _ samples: [Float], _ rate: Double, _ reference: String) async {
        // WHAT WAS ACTUALLY CAPTURED. An empty transcript can mean the
        // voice was unintelligible or that the tap caught nothing, and
        // those two lead to opposite conclusions. Length and peak
        // amplitude separate them on sight, so they are always printed.
        let peak = samples.map { abs($0) }.max() ?? 0
        let seconds = rate > 0 ? Double(samples.count) / rate : 0
        guard !samples.isEmpty, peak > 0.001 else {
            print(String(format: "      %@: captured %.2f s, peak %.4f — SILENT, not graded",
                         mouth, seconds, peak))
            return
        }
        let saved = saveWav(samples, rate: rate,
                            named: "s\(sentenceIndex + 1)-\(mouth)-draw\(draw)")
        do {
            let m = try await BakeoffHarness.measure(
                engine: whisper, label: mouth,
                samples: samples, sampleRate: rate, reference: reference)
            rows.append(Row(mouth: mouth, sentence: sentenceIndex, draw: draw,
                            wer: m.score.wer, heard: m.text))
            print(String(format: "      %-8@ draw %d — WER %.3f — %.2f s, peak %.3f — \"%@\"%@",
                         mouth as NSString, draw, m.score.wer, seconds, peak,
                         m.text as NSString,
                         saved.map { " → \($0)" } ?? "" as NSString as String))
        } catch {
            print("      \(mouth): transcription failed — \(error)")
        }
    }

    for (index, text) in sentences.enumerated() {
        print("\n  sentence \(index + 1): \"\(text)\"")

        // Apple's mouth, once: it is deterministic, so extra draws would
        // measure nothing. Captured through `write` rather than the tap,
        // because it does not render through our engine — same voice,
        // not the identical code path we ship.
        if let appleAudio = await captureApple(text) {
            await grade("apple", index, 1, appleAudio.samples, appleAudio.sampleRate, text)
        } else {
            print("      apple: write produced nothing — not graded")
        }

        for draw in 1...draws {
            steppedCapture.record()
            _ = try? await measure(stepped, text)
            let steppedAudio = steppedCapture.stop()
            await grade("stepped", index, draw, steppedAudio,
                        steppedCapture.sampleRate, text)

            fusedCapture.record()
            _ = try? await measure(fused, text)
            let fusedAudio = fusedCapture.stop()
            await grade("fused", index, draw, fusedAudio,
                        fusedCapture.sampleRate, text)
        }
    }

    print("\n════════════════════════════════════════════════")
    print("neural model under test: \(werModel == .qwen3TTS_1_7b ? "1.7B" : "0.6B")"
        + " · vocoder \(werLevers.vocoder == .throughputOptimized ? "throughput" : "latency")"
        + " · lead \(lead)")
    print("| mouth | draws graded | mean WER | worst |")
    print("|---|---|---|---|")
    for mouth in ["apple", "stepped", "fused"] {
        let mine = rows.filter { $0.mouth == mouth }
        guard !mine.isEmpty else { print("| \(mouth) | 0 | — | — |"); continue }
        let mean = mine.map(\.wer).reduce(0, +) / Double(mine.count)
        let worst = mine.map(\.wer).max() ?? 0
        print(String(format: "| %@ | %d | **%.3f** | %.3f |",
                     mouth, mine.count, mean, worst))
    }
    print("\n0.000 is perfect. WER can exceed 1.0 when the voice rambles")
    print("and the transcriber hears words that were never asked for.")
    exit(0)
}

// `swift run bakeoff voice-levers` — AC-106, D-046 = B. Every decode
// lever that survived adversarial verification, measured SERIALLY on one
// machine, because two models decoding at once would corrupt both
// timings. The numbers land on stderr beside each config banner.
if arguments.count > 1, arguments[1] == "voice-levers" {
    // ONE long single-chunk sentence. Long, so the fixed prefill is
    // amortised and STEADY rtf is what moves; single-chunk, so the
    // sequential/batch branch is not part of what is being compared.
    let sentence = "The audio travels through a ring buffer into a pump "
        + "that cuts it into small chunks."
    let runsPerConfig = 3

    // WHICH MODEL SPEAKS, parsed by the library's one parser (D-072 F-3,
    // AC-163): `--voice-model=1.7b` runs the whole sweep on the big model
    // so its rows land beside 0.6B's from the same stopwatch. A value the
    // project cannot honor refuses here, never a silent 0.6B.
    let sweepModel: TTSModelVariant
    do {
        sweepModel = try VoiceLevers.parsed(fromArguments: arguments).model
    } catch let refusal as VoiceLevers.FlagError {
        FileHandle.standardError.write(Data("bakeoff: \(refusal.message)\n".utf8))
        exit(2)
    }

    struct Lever {
        let name: String
        let multi: Qwen3MultiCodeDecoderMode
        let speech: Qwen3SpeechDecoderMode
        let temperature: Float?
    }
    let levers = [
        Lever(name: "baseline (stepped + latency)", multi: .stepped,
              speech: .latencyOptimized, temperature: nil),
        Lever(name: "rank 2: fused", multi: .fused,
              speech: .latencyOptimized, temperature: nil),
        Lever(name: "rank 3: throughputOptimized", multi: .stepped,
              speech: .throughputOptimized, temperature: nil),
        Lever(name: "rank 4: fused + throughputOptimized", multi: .fused,
              speech: .throughputOptimized, temperature: nil),
        Lever(name: "rank 5: temperature 0 (on stepped)", multi: .stepped,
              speech: .latencyOptimized, temperature: 0),
        Lever(name: "rank 5b: temperature 0 (on fused)", multi: .fused,
              speech: .latencyOptimized, temperature: 0),
    ]

    func banner(_ text: String) {
        FileHandle.standardError.write(Data("\n=== \(text) ===\n".utf8))
    }

    let sweepModelName = sweepModel == .qwen3TTS_1_7b ? "1.7B" : "0.6B"
    print("\n🔧 VOICE LEVERS (AC-106) — serial, release, one machine · model \(sweepModelName)")
    print("    watch STEADY, not RTF: the whole-run factor still carries prefill")

    for lever in levers {
        banner(lever.name)
        // A seed makes the draws comparable across configs. `.fused`
        // samples in-graph, so it is NOT expected to match `.stepped`
        // sample-for-sample even seeded — the seed removes run-to-run
        // noise WITHIN a config, which is what a median needs.
        let voice = NeuralVoice(variant: sweepModel,
                                lead: .zero,
                                multiCodeDecoderMode: lever.multi,
                                speechDecoderMode: lever.speech,
                                temperature: lever.temperature,
                                seed: 20260816)
        do {
            try await voice.ensureModel()
        } catch {
            print("| \(lever.name) | LOAD FAILED — \(error) |")
            FileHandle.standardError.write(Data("   load failed: \(error)\n".utf8))
            continue
        }
        // THE STEADY NUMBERS, FROM OUR OWN INSTRUMENT (AC-163).
        //
        // This footer told the reader to "read the STEADY column from
        // stderr" — and there is no such column: it depended on the
        // VENDOR's logging, which prints nothing here today. The 4l run
        // caught it the way §30's rule predicts: the instruction pointed
        // at a number the instrument could not produce, so the sweep's
        // headline totals were the only thing to read — and totals are
        // NOT comparable across models, because a model that says the
        // same sentence in less audio finishes sooner for a reason that
        // has nothing to do with speed.
        //
        // `DecodeMargin` is ours, it is what the phone already logs, and
        // it carries the audio length that makes the ratio meaningful.
        let margins = MarginBox()
        await voice.reportMargins { margin in margins.record(margin) }
        // Warm-up, excluded: the first decode after a load compiles and
        // warms graphs, the same rule voice-spike follows.
        _ = try? await measure(voice, "Warming up.")
        margins.reset()
        // MEASURED AND PRINTED, not swallowed. This loop used to be
        // `_ = try? await measure(...)`: the result discarded, the error
        // dropped, and the numbers left entirely to TTSKit's own logging.
        // A run that FAILED printed "run 1:" and nothing — identical to a
        // run that succeeded quietly. A whole levers sweep came back with
        // six empty configs and no way to tell whether that meant silence
        // or failure.
        for run in 1...runsPerConfig {
            do {
                let timing = try await measure(voice, sentence)
                // The margin for THIS run, or the honest absence of one.
                // A row that cannot say its audio length says so, rather
                // than borrowing the previous run's number.
                let said: String
                if let margin = margins.take() {
                    said = String(format: "audio %.0f ms | steady %.3f%@",
                                  margin.audioMilliseconds,
                                  margin.steadyRealTimeFactor,
                                  margin.completed ? "" : " (INCOMPLETE)")
                } else {
                    said = "audio — | steady — (no margin reported)"
                }
                print(String(format: "| %@ | run %d | first audio %.0f ms | total %.0f ms | %@ |",
                             lever.name, run, timing.firstAudio, timing.total, said))
            } catch {
                print("| \(lever.name) | run \(run) | DECODE FAILED — \(error) |")
            }
        }
    }
    print("\nSTEADY is the column that compares: totals scale with how much"
        + " audio a model made, \(runsPerConfig) runs per config, take the median.")
    exit(0)
}

// `swift run bakeoff voice-install` — fetch the neural voice's model.
// It lives here rather than in a throwaway script because this is where
// the VOICE bake-off will run (AC-103), and the same tool should be able
// to put its subject on disk.
if arguments.count > 1, arguments[1] == "voice-install" {
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
// `swift run bakeoff graph-probe` — WHAT A LIVE AUDIO GRAPH ACTUALLY DOES
// (D-054, and AC-109's tests rest on it).
//
// THE BILL THIS INSTRUMENT PAYS: five faults in one 4e afternoon, each
// introduced while fixing the previous one, every one a guess about what an
// `AVAudioEngine` would do, every one tested by Ryad rebuilding onto his
// phone. The rule that ended it — audio graphs are MEASURED, never reasoned
// about — needs a place to do the measuring, on this machine, one variable
// at a time. This is that place.
//
// ONE CASE PER PROCESS, and that is the whole design: AVFoundation does not
// throw on a misused node, it raises an ObjC exception and the process dies.
// A single-process probe would report only its first fault and hide every
// case after it. So the parent re-executes itself once per case and reads
// the exit status; a child that never prints SURVIVED aborted.
//
// AND IT PROVES ITS OWN EYES (rule 5: an instrument must be able to say
// whether it is switched on). A probe where nothing ever fails is
// indistinguishable from a probe that cannot see failures, so it reports
// whether it detected ANY abort. Case 5 is a deliberate control.
if arguments.count > 1, arguments[1] == "graph-probe" {
    // One case, run as a child. Same flag shape as `--lead=` above.
    let single = arguments.first(where: { $0.hasPrefix("--case=") })
        .flatMap { Int($0.dropFirst("--case=".count)) }

    struct Probe {
        let number: Int
        let what: String
        /// What the 4e record leads us to expect. Printed beside the
        /// measurement so a surprise is visible rather than absorbed.
        let expectation: String
        let body: () throws -> Void
    }

    func player() -> AVAudioPlayerNode { AVAudioPlayerNode() }
    func monoFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                      channels: 1, interleaved: false)!
    }
    func oneBuffer() -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat(), frameCapacity: 240)!
        buffer.frameLength = 240
        return buffer
    }

    let probes: [Probe] = [
        Probe(number: 1, what: "never attached → stop()",
              expectation: "survives") { player().stop() },
        Probe(number: 2, what: "never attached → reset()",
              expectation: "survives") { player().reset() },
        Probe(number: 3, what: "never attached → stop(), reset()  [the cancel + teardown path]",
              expectation: "survives") { let p = player(); p.stop(); p.reset() },
        Probe(number: 4, what: "attached to an engine NEVER started → stop(), reset(), detach",
              expectation: "survives") {
            let engine = AVAudioEngine(), p = player()
            engine.attach(p); p.stop(); p.reset(); engine.detach(p)
        },
        Probe(number: 5, what: "CONTROL — attach, connect, start, engine.stop(), detach",
              expectation: "4e fault #1 says ABORT") {
            let engine = AVAudioEngine(), p = player()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: monoFormat())
            engine.prepare()
            try engine.start()
            engine.stop()
            engine.detach(p)
        },
        Probe(number: 6, what: "never attached → play()",
              expectation: "ABORT") { player().play() },
        Probe(number: 7, what: "never attached → scheduleBuffer",
              expectation: "ABORT") {
            player().scheduleBuffer(oneBuffer(), at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { _ in }
        },
        Probe(number: 8, what: "attached to an engine never started → scheduleBuffer, play()",
              expectation: "survives") {
            let engine = AVAudioEngine(), p = player()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: monoFormat())
            p.scheduleBuffer(oneBuffer(), at: nil, options: [],
                             completionCallbackType: .dataPlayedBack) { _ in }
            p.play()
            engine.detach(p)
        },
    ]

    // THE CHILD. One case, then the word that means it lived.
    if let single {
        guard let probe = probes.first(where: { $0.number == single }) else {
            print("no such case: \(single)")
            exit(2)
        }
        print("case \(probe.number): \(probe.what)")
        do { try probe.body() } catch {
            print("THREW \(error)")     // a thrown Swift error is not an abort
            exit(3)
        }
        print("SURVIVED")
        exit(0)
    }

    // THE PARENT. Re-runs itself once per case.
    print("\n🧪  GRAPH PROBE (D-054) — what a player node off a running engine tolerates")
    print("    One case per PROCESS: AVFoundation aborts rather than throwing, so a")
    print("    single-process probe would report its first fault and hide the rest.")
    print("    Executable: \(CommandLine.arguments[0])")

    var aborted: [Int] = []
    var rows: [String] = []
    for probe in probes {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["graph-probe", "--case=\(probe.number)"]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        var verdict = "?"
        do {
            try child.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            if child.terminationStatus == 0, out.contains("SURVIVED") {
                verdict = "survives"
            } else if out.contains("THREW") {
                // A THROWN SWIFT ERROR IS NOT AN ABORT, and conflating them
                // would make this instrument lie. Case 5 calls
                // `try engine.start()`, which throws on a machine with no
                // usable output device — a CI runner, or a laptop with the
                // audio device taken. Reported as an abort, that would read
                // as "detach after stop aborts here", the exact belief §20
                // refuted. Reported as untested, it says what happened.
                verdict = "did not run · " + (out.split(separator: "\n")
                    .first(where: { $0.hasPrefix("THREW") })
                    .map(String.init) ?? "threw")
            } else {
                verdict = "**ABORT**"
                aborted.append(probe.number)
                // The reason is the useful half — the ObjC assertion text
                // names the condition that failed.
                if let line = out.split(separator: "\n").first(where: {
                    $0.contains("required condition is false")
                }) {
                    verdict += " · " + line.trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "*** Terminating app due to uncaught exception "
                                              + "'com.apple.coreaudio.avfaudio', reason: ", with: "")
                }
            }
        } catch {
            verdict = "could not run child: \(error)"
        }
        rows.append(String(format: "| %d | %@ | %@ | %@ |",
                           probe.number, probe.what as NSString,
                           probe.expectation as NSString, verdict as NSString))
    }

    print("\n| case | path | expected | measured |")
    print("|---|---|---|---|")
    for row in rows { print(row) }

    print("\n════════════════════════════════════════════════")
    if aborted.isEmpty {
        print("⚠️  NO CASE ABORTED. Read this as an instrument that has NOT proven it")
        print("    can see a failure — not as a clean bill of health. Rule 5 of D-054:")
        print("    a probe that never fails is indistinguishable from a blind one.")
    } else {
        print("✅ DETECTION PROVEN — cases \(aborted.map(String.init).joined(separator: ", ")) "
              + "aborted, so this probe can see a fault.")
    }
    let unrun = rows.filter { $0.contains("did not run") }.count
    if unrun > 0 {
        print("⚠️  \(unrun) case(s) DID NOT RUN — they threw before measuring anything.")
        print("    Read those rows as absent data, not as a verdict. The usual cause is")
        print("    a machine with no usable audio output device.")
    }
    print("\nREAD IT AS: the surviving verbs are the ones a test double may call on a")
    print("node that is on no running engine. That is what makes AC-109's headless")
    print("failure-path tests legitimate, and why its scripted decoder cannot emit a")
    print("non-empty sample — `render` would reach an aborting verb.")
    print("\nNOT measured here, and not claimed: anything involving voice processing,")
    print("an iOS audio SESSION, or a real capture engine. Case 5 is a plain engine,")
    print("so if it survives, that says nothing about the same detach under VPIO —")
    print("which is where 4e's fault was actually found. That case needs a phone.")
    exit(0)
}
let wavPath = arguments.count > 1 ? arguments[1] : "Fixtures/ryad-en.wav"
let referencePath = arguments.count > 2 ? arguments[2] : "Fixtures/bakeoff-reference.txt"

guard let reference = try? String(contentsOfFile: referencePath, encoding: .utf8) else {
    print("cannot read reference: \(referencePath)"); exit(1)
}

// One harness for CLI and app: same chunking, same settle, same scoring.
let loaded: (samples: [Float], sampleRate: Double)
do { loaded = try BakeoffHarness.loadAudio(URL(fileURLWithPath: wavPath)) }
catch { print("cannot read wav: \(wavPath) — \(error)"); exit(1) }
let samples = loaded.samples
let sampleRate = loaded.sampleRate
let seconds = Double(samples.count) / sampleRate
print("audio: \(wavPath) — \(String(format: "%.1f", seconds)) s at \(Int(sampleRate)) Hz")
print("reference: \(WordErrorRate.normalize(reference).count) words\n")

func run(_ engine: any TranscriptionEngine, label: String) async throws -> BakeoffMeasurement {
    try await BakeoffHarness.measure(engine: engine, label: label,
                                     samples: samples, sampleRate: sampleRate,
                                     reference: reference)
}

var measurements: [BakeoffMeasurement] = []

// — Apple —
let apple = AppleSpeechEngine()
if await apple.modelInstalled() {
    print("apple: warm-up run (excluded from the numbers)…")
    _ = try? await run(apple, label: "warmup")
    print("apple: measured run…")
    do { measurements.append(try await run(apple, label: "Apple SpeechAnalyzer (en_US)")) }
    catch { print("apple: failed — \(error)") }
} else {
    print("apple: model not installed on this machine — skipped (runs on iPhone, or when the asset daemon heals)")
}

// — Whisper —
let whisper = WhisperEngine()
if await whisper.modelInstalled() {
    print("whisper: warm-up run (excluded — CoreML graph compilation)…")
    _ = try? await run(whisper, label: "warmup")
    print("whisper: measured run…")
    do { measurements.append(try await run(whisper, label: "Whisper base (WhisperKit)")) }
    catch { print("whisper: failed — \(error)") }
} else {
    print("whisper: model not installed — run once with ensureModel() first")
}

guard !measurements.isEmpty else { print("\nno engine could run."); exit(1) }

print("\n| Engine | WER | sub | ins | del | decode settle |")
print("|---|---|---|---|---|---|")
for m in measurements {
    print(String(format: "| %@ | **%.1f%%** | %d | %d | %d | %.2f s |",
                 m.engineName, m.score.wer * 100, m.score.substitutions,
                 m.score.insertions, m.score.deletions, m.decodeSeconds))
}
print("")
for m in measurements {
    print("— \(m.engineName) heard:\n\(m.text)\n")
}
