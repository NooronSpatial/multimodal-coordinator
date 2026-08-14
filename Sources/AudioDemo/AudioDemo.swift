import Foundation
import MultiModalKit
import MultiModalKitWhisper
import Synchronization

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

        let microphone = MicrophoneSource()
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
            vad: EnergyVAD(config: .init(threshold: 0.02,
                                         hangoverFrames: Int(sampleRate * 0.3),
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
        print("    \(Int(sampleRate)) Hz · 20 ms chunks · \(Int(onsetMs)) ms onset · 300 ms hangover · 200 ms pre-roll")
        print("    transcription: \(transcription == nil ? "OFF (no model)" : engineName)")
        if talk && transcription != nil {
            print("    turn loop: ON — it SPEAKS the echo aloud (AVSpeechSynthesizer);"
                + " interrupt it mid-reply")
            print("    reply gate: \(Int(gateMs)) ms"
                + (gateMs == 0 ? " (answers at the final — 4a behavior)" : " of yielded floor")
                + "\n")
        } else {
            print("")
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
                        replyGenerator: PacedEchoReply(),
                        synthesizer: AppleSpeechSynthesizer(),
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
    func openReply(to transcript: String) async throws -> any ReplyRun {
        EchoRun(words: ["You", " said:"]
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
