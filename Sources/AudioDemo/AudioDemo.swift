import Foundation
import MultiModalKit
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Synchronization
import TTSKit

/// Phase 2 live demo: microphone → ring → pump → transcription → terminal.
///
/// The [recogniser] listener from milestone 1c is no longer a stand-in: it is
/// a real `TranscriptionSession` running Apple's on-device engine. If the
/// speech model is missing, the demo offers the download and — if it fails,
/// as it repeatedly has on some networks — says so honestly and runs with
/// voice detection only. Failure is an event, not an excuse to crash.
///
/// Demo-only liberties (never taken in the library or its tests): a real
/// `ContinuousClock` drives the pump, and Foundation is imported for stdout
/// flushing. The library itself stays clock-injected.
@main
struct AudioDemo {
    static func main() async {
        setbuf(stdout, nil)

        // Engine selection: `swift run audio-demo [apple|whisper] [--talk]`.
        // Born of a real machine: this Mac's asset daemon refuses Apple's
        // model, so waiting through its failed download on every run was
        // pure ceremony — while Whisper sits installed and willing.
        // `--talk` adds the Phase 4a turn loop: a scripted echo reply,
        // "spoken" into the terminal — barge it mid-reply with your voice.
        let arguments = Array(CommandLine.arguments.dropFirst())
        let talk = arguments.contains("--talk")
        // `--onset <ms>`: the F-6 field A/B flag (08-13). The A/B convicted
        // the strict window twice on this machine — "Riyadh"→"Riyat" and
        // "error rate"→"rate", both onsets clipped after a split — against
        // zero quiet-room benefit (the 0.02 gate already earned the clean
        // runs). Ruled D-036: the Mac demo runs with the window OFF; the
        // flag stays for experiments; a machine that truly needs a window
        // with soft speech reopens F-2 as a tolerance budget first.
        var onsetMs = 0.0
        if let flagIndex = arguments.firstIndex(of: "--onset"),
           let value = arguments.indices.contains(flagIndex + 1)
               ? Double(arguments[flagIndex + 1]) : nil {
            onsetMs = value
        }
        // `--gate <ms>`: the reply gate (AC-81) — how long the floor must
        // stay yielded before the assistant answers. 0 = reply at the
        // final, exactly the 4a behavior. The number is the app's to earn
        // (D-027); the flag is where this machine earns it.
        var gateMs = 0.0
        if let flagIndex = arguments.firstIndex(of: "--gate"),
           let value = arguments.indices.contains(flagIndex + 1)
               ? Double(arguments[flagIndex + 1]) : nil {
            gateMs = value
        }
        // `--vad <level>`: the loudness gate itself. Born from the field
        // finding in SPEC §46a — quiet speech at 2-4x this number gets
        // FRAGMENTED into syllables that decode to nothing — and from the
        // fact that echo cancellation moved the ambient floor this number
        // was chosen against (peak 0.024 -> 0.006). The prediction to test:
        // with the canceller on, a lower gate holds quiet speech together
        // without reviving 1d's flap.
        var vadThreshold: Float = 0.02
        if let flagIndex = arguments.firstIndex(of: "--vad"),
           let value = arguments.indices.contains(flagIndex + 1)
               ? Float(arguments[flagIndex + 1]) : nil {
            vadThreshold = value
        }
        // `--hangover <ms>`: how long a dip is forgiven before the utterance
        // is declared over — the fragment boundary, proven in the field
        // (SPEC §46a). 700 ms is this demo's ruled number (D-039), bracketed
        // from both sides on one voice: at 300 ms a quiet sentence shattered
        // into four pieces, at 500 ms it split in two, at 700 ms it arrived
        // whole. The LIBRARY default stays 300 ms — each product earns its
        // own number (D-028/D-036). Cost, stated where it is paid: every
        // final waits 400 ms longer than the library default would.
        var hangoverMs = 700.0
        if let flagIndex = arguments.firstIndex(of: "--hangover"),
           let value = arguments.indices.contains(flagIndex + 1)
               ? Double(arguments[flagIndex + 1]) : nil {
            hangoverMs = value
        }
        let choice = arguments.first { !$0.hasPrefix("--") && Double($0) == nil } ?? "apple"
        let engine: any TranscriptionEngine
        let engineName: String
        switch choice {
        case "apple":
            engine = AppleSpeechEngine()
            engineName = "Apple SpeechAnalyzer (en-US, streaming)"
        case "whisper":
            engine = WhisperEngine()
            engineName = "Whisper base (batch — text arrives after each pause)"
        default:
            print("usage: swift run audio-demo [apple|whisper] [--talk]   (default: apple)")
            return
        }

        // The model phase comes FIRST — before the microphone exists.
        // Learned live: with the mic started first, a 15-minute failed
        // download left the ring honestly counting 43,206,464 dropped frames
        // (900 s × 48 kHz) that nobody was reading. The ring told the truth;
        // the ordering was the bug.
        func modelReady() async -> Bool {
            switch choice {
            case "apple": await (engine as! AppleSpeechEngine).modelInstalled()
            default: await (engine as! WhisperEngine).modelInstalled()
            }
        }
        func ensure() async throws {
            switch choice {
            case "apple": try await (engine as! AppleSpeechEngine).ensureModel()
            default: try await (engine as! WhisperEngine).ensureModel()
            }
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

        // ~1 second of audio at 48 kHz; rounded up to a power of two inside.
        let (producer, consumer) = AudioRing.create(minimumCapacity: 48_000)

        // Echo cancellation is ON by default here (D-038): the spike its
        // adoption was gated on passed, in the field, with a human in the
        // room — replies complete instead of barging themselves, the reply
        // stays comfortably loud, and a live voice still interrupts it.
        // `--no-aec` keeps the old door open for A/B experiments.
        let wantsAEC = !arguments.contains("--no-aec")
        let microphone = MicrophoneSource(voiceProcessing: wantsAEC)
        do {
            try microphone.start(into: producer)
        } catch {
            print("Could not start the microphone: \(error.localizedDescription)")
            print("(macOS may be asking for permission — check the prompt, then run again.)")
            return
        }

        let sampleRate = microphone.sampleRate
        let chunkFrames = Int(sampleRate * 0.02)          // 20 ms of sound per verdict
        // Field forensics (the 08-13 --talk investigation): the demo was
        // BLIND to listener overflow — the pump's broadcast drops oldest
        // silently when a listener stalls (D-012), and the session's merged
        // loop can stall on inline stage awaits (a recorded 4a known limit).
        // Health makes the invisible number visible.
        let diagnostics = PipelineDiagnostics()
        let pump = AudioPump(
            consumer: consumer,
            // 0.02 is the LAPTOP gate. The 0.01 borrowed from the iPhone
            // tuning flaps on a Mac's ambient: field run 08-13 showed the
            // post-sentence level hovering AT 0.01 — the gate opened every
            // 0.84 s like a metronome, one empty Whisper decode per tick.
            // The iPhone demo keeps 0.01; each machine earns its own number.
            // The onset window (D-035) ships OFF here — ruled D-036 after
            // the field A/B clipped word onsets twice ("Riyat", "rate")
            // for zero quiet-room benefit. The gate is this machine's
            // earned defense; `--onset <ms>` re-arms the window for
            // experiments (wire pre-roll ≥ the window per the F-4 law).
            vad: EnergyVAD(config: .init(threshold: vadThreshold,
                                         hangoverFrames: Int(sampleRate * hangoverMs / 1000),
                                         onsetFrames: Int(sampleRate * onsetMs / 1000))),
            clock: ContinuousClock(),
            config: .init(sampleRate: sampleRate, pollInterval: .milliseconds(10),
                          chunkFrames: chunkFrames, preRollChunks: 10),
            diagnostics: diagnostics)

        let transcription: TranscriptionSession? = engineReady
            ? TranscriptionSession(
                engine: engine,
                config: .init(format: .init(sampleRate: sampleRate, channels: 1)),
                diagnostics: diagnostics)
            : nil

        print("\n🎙  Speak — the pump is listening.  (Ctrl-C to quit)")
        print("    \(Int(sampleRate)) Hz · 20 ms chunks · gate \(vadThreshold)"
            + " · \(Int(onsetMs)) ms onset · \(Int(hangoverMs)) ms hangover · 200 ms pre-roll")
        print("    transcription: \(transcription == nil ? "OFF (no model)" : engineName)")
        print("    voice processing: "
            + (wantsAEC
                ? (microphone.voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")
                : "OFF (--no-aec) — the assistant will hear itself"))
        if talk && transcription != nil {
            // READ FROM THE FLAGS, not hardcoded. This line said
            // "the echo aloud (AVSpeechSynthesizer)" in every run, including
            // `--mind=local --mouth=neural`, where all three words were
            // wrong. A banner that cannot be wrong is worth more than a
            // banner that is usually right.
            func flag(_ name: String) -> String? {
                arguments.first { $0.hasPrefix("--\(name)=") }
                    .map { String($0.dropFirst(name.count + 3)) }
            }
            let mindName = flag("mind") ?? "echo"
            let mouthName = flag("mouth") == "neural"
                ? "Qwen3 neural voice" : "AVSpeechSynthesizer"
            print("    turn loop: ON — \(mindName) mind, spoken by "
                + "\(mouthName); interrupt it mid-reply")
            print("    reply gate: \(Int(gateMs)) ms"
                + (gateMs == 0 ? " (answers at the final — 4a behavior)" : " of yielded floor"))
            print("    context: up to 16 pieces of one thought — 🧠 shows what the"
                + " generator received\n")
        } else {
            print("")
        }

        // `--levels`: the honest instrument the F-2 spike needed. The pump
        // only publishes sound the VAD already accepted, so "no utterances"
        // could mean cancelled echo OR a deaf microphone — indistinguishable
        // from the pump's output. This mode reads the ring directly (the
        // pump is not running here, so its sole-reader rule stands) and
        // prints what the microphone ACTUALLY delivers, gate or no gate.
        if arguments.contains("--levels") {
            print("\n📏 level probe — what the microphone really delivers, every 500 ms")
            print("    voice processing: "
                + (wantsAEC
                    ? (microphone.voiceProcessingActive ? "ACTIVE" : "REFUSED by the platform")
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
            return
        }

        let screen = Screen()

        await withTaskGroup(of: Void.self) { group in
            let audioForScreen = await pump.listen()
            let health = diagnostics.health()          // listen BEFORE run: no replay
            group.addTask { await diagnostics.run() }
            group.addTask { await showHealth(health.events, on: screen) }
            group.addTask { await pump.run() }
            group.addTask {
                await showAudio(audioForScreen.events, on: screen, ringDrops: consumer)
            }

            if let transcription {
                let audioForSession = await pump.listen()
                let transcripts = await transcription.listen()
                group.addTask { await transcription.run(events: audioForSession.events) }
                group.addTask { await showTranscripts(transcripts.events, on: screen) }

                if talk {
                    // The Phase 4b slice (AC-84): the loop now SPEAKS —
                    // AVSpeechSynthesizer behind the same seam the scripted
                    // voice proved. Real microphone barge-in, the R2 latency
                    // seam on a real clock, and (--gate) the AC-81 reply
                    // gate: the demo reuses the exact code paths the
                    // deterministic tests prove.
                    let coordinator = TurnCoordinator(
                        replyGenerator: chosenMind(arguments, screen: screen),
                        synthesizer: chosenMouth(arguments),
                        config: .init(replyGate: .milliseconds(Int(gateMs))),
                        clock: ContinuousClock(),
                        latencyReporter: ConsoleLatency(screen: screen))
                    let audioForTurns = await pump.listen()
                    let transcriptsForTurns = await transcription.listen()
                    let turnEvents = await coordinator.listen()
                    group.addTask {
                        await coordinator.run(
                            audio: audioForTurns.events,
                            transcripts: transcriptsForTurns.events)
                    }
                    group.addTask { await showTurns(turnEvents.events, on: screen) }
                }
            }
        }
    }

    static func showTurns(_ events: AsyncStream<TurnEvent>, on screen: Screen) async {
        var reply = ""
        for await event in events {
            switch event {
            case .stateChanged(let state, _):
                await screen.set(turnState: state)
                if state == .listening || state == .idle { reply = "" }
                await screen.set(reply: reply)
            case .replyToken(let token, _):
                reply += token          // tokens carry their own spacing now
                await screen.set(reply: reply)
            case .turnCompleted(let turn):
                await screen.log("🤖 [\(turn)] \(reply)")
                reply = ""
                await screen.set(reply: "")
            case .turnBarged(let turn):
                await screen.log("✋ [\(turn)] interrupted — listening to you instead")
            case .turnFailed(let failure, let turn):
                await screen.log("⚠️  [\(turn)] turn failed: \(failure)")
            }
        }
    }

    // MARK: - the two listeners' views of the world

    /// The pipeline's own health, one line per fact — the forensics feed.
    static func showHealth(_ events: AsyncStream<HealthEvent>, on screen: Screen) async {
        for await event in events {
            switch event {
            case .thermal(let state):
                await screen.log("🩺 thermal: \(state)")
            case .ringDropped(let frames, let at):
                await screen.log("🩺 ring dropped \(frames) frames at \(format(at.seconds)) s")
            case .listenerFellBehind(let id, let total):
                await screen.log("🩺 listener \(id) fell behind — \(total) events dropped so far")
            case .settlingDecodes(let count):
                await screen.log("🩺 settling decodes: \(count)")
            case .settlingDecodeRefused(let utterance, let thermal):
                await screen.log("🩺 [\(utterance)] settling decode refused (thermal: \(thermal))")
            case .turnFailed(let turn, let failure):
                // D-059: the health-side record of a dead turn — the road
                // the mind's tripwire alarm rides.
                await screen.log("🩺 turn \(turn) FAILED: \(failure)")
            }
        }
    }

    static func showAudio(
        _ events: AsyncStream<AudioEvent>, on screen: Screen, ringDrops consumer: AudioRingConsumer
    ) async {
        // Per-utterance forensics: what did the gate actually let through?
        var utterance = -1
        var startSeconds = 0.0
        var chunks = 0
        var peak: Float = 0
        for await event in events {
            switch event {
            case .speechStarted(let number, let at):
                utterance = number
                startSeconds = at.seconds
                chunks = 0
                peak = 0
                await screen.set(speaking: true)
            case .audioSegment(let chunk):
                chunks += 1
                peak = max(peak, rms(of: chunk))
                await screen.set(level: level(of: chunk), drops: consumer.totalDropped)
            case .speechEnded(let at):
                let ms = (at.seconds - startSeconds) * 1000
                await screen.log("🔎 [\(utterance)] \(String(format: "%.0f", ms)) ms" +
                    " · peak rms \(String(format: "%.3f", peak)) · \(chunks) chunks")
                await screen.set(speaking: false)
            case .dropped(let frames, let at):
                await screen.log("⚠️  dropped \(frames) frames at \(format(at.seconds)) s")
            }
        }
    }

    static func showTranscripts(_ events: AsyncStream<TranscriptEvent>, on screen: Screen) async {
        for await event in events {
            switch event {
            case .partial(let text, _, _):
                await screen.set(partial: text)
            case .final(let text, let utterance, let at):
                await screen.log("💬 [\(utterance)] \(text)   (\(format(at.seconds)) s)")
                await screen.set(partial: "")
            case .failed(let failure, let utterance, _):
                await screen.log("⚠️  [\(utterance)] recognition failed: \(failure)")
                await screen.set(partial: "")
            case .truncated(let utterance, _):
                await screen.log("✂️  [\(utterance)] utterance hit the 30 s ceiling")
            }
        }
    }

    static func rms(of chunk: AudioChunk) -> Float {
        var sumOfSquares: Float = 0
        for sample in chunk.samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()
    }

    static func level(of chunk: AudioChunk) -> Int {
        min(Int(rms(of: chunk) * 300), 24)
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// One owner for the terminal: permanent lines above, one live status line
/// below (level bar + the current partial). Two event streams write here
/// concurrently; the actor serializes them so the screen never tears.
actor Screen {
    private var speaking = false
    private var levelBar = ""
    private var partial = ""
    private var reply = ""
    private var turnState: TurnState?
    private var drops = 0

    func set(turnState: TurnState) {
        self.turnState = turnState
        render()
    }

    func set(reply: String) {
        self.reply = reply
        render()
    }

    func set(speaking: Bool) {
        self.speaking = speaking
        if !speaking { levelBar = "" }
        render()
    }

    func set(level: Int, drops: Int) {
        self.levelBar = String(repeating: "█", count: level)
        self.drops = drops
        render()
    }

    func set(partial: String) {
        self.partial = partial
        render()
    }

    func log(_ line: String) {
        print("\r\u{1B}[K\(line)")
        render()
    }

    private func render() {
        let icon = speaking ? "🗣" : "…"
        let turnIcon = switch turnState {
        case .thinking: "  💭"
        case .speaking: "  🤖 \(reply.suffix(36))"
        default: ""
        }
        let text = partial.isEmpty ? "" : "  \(partial.suffix(48))"
        let dropText = drops > 0 ? "  dropped:\(drops)" : ""
        print("\r\u{1B}[K\(icon) [\(levelBar.padding(toLength: 24, withPad: "·", startingAt: 0))]\(text)\(turnIcon)\(dropText)",
              terminator: "")
    }
}

// MARK: - Phase 4a demo-tier stages (D-016 liberties: real clocks, an
// unstructured task per reply — never taken in the library or its tests)

/// Wall-clock latency to the terminal (R2). Demo-tier liberty: the report
/// hops to the screen actor via an unstructured task (D-016).
struct ConsoleLatency: LatencyReporter {
    let screen: Screen
    func turnLatency(_ duration: Duration, turn: Int) {
        let screen = screen
        Task { await screen.log("⏱  [\(turn)] felt pause: \(duration.formattedMs)") }
    }
    func cancelLatency(_ duration: Duration, turn: Int) {
        let screen = screen
        Task { await screen.log("⏱  [\(turn)] barge → dead in \(duration.formattedMs)") }
    }
}

extension Duration {
    var formattedMs: String {
        let ms = Double(components.seconds) * 1000
            + Double(components.attoseconds) * 1e-15
        return String(format: "%.0f ms", ms)
    }
}

/// Echoes the user's words back, one token at a time, paced so the reply
/// FEELS generated — slow enough to barge into. Tokens carry their own
/// spacing (the way real generators emit them): the phraser concatenates
/// VERBATIM and never invents a space.
struct PacedEchoReply: ReplyGenerating {
    let screen: Screen

    func openReply(to transcript: String) async throws -> any ReplyRun {
        // AC-91: the milestone made visible. This prints what actually
        // CROSSED THE SEAM — the generator's own view, which is the only
        // honest witness that the whole thought arrived. Speak two
        // sentences with a pause and this line holds both.
        await screen.log("🧠 whole thought → \"\(transcript)\"")
        return EchoRun(words: ["You", " said:"]
            + transcript.split(separator: " ").map { " " + $0 })
    }
}

private final class EchoRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(words: [String]) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        let out = handle!
        task.withLock { $0 = Task {
            for word in words {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { out.finish(); return }   // conformant:
                out.yield(.token(word))                                 // no terminal
            }
            out.yield(.finished)
            out.finish()
        } }
    }

    func cancel() async { task.withLock { $0?.cancel() } }
}

// (The 4a `TerminalVoice` — a mouth that only printed — retired here: the
// real `AppleSpeechSynthesizer` speaks behind the same seam, which was
// the seam's whole promise. Its contract lives on in the library's
// `ScriptedSynthesizer`, where the deterministic tests need it.)

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
