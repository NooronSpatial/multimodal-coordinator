import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the measurements: the lever sweep (AC-146 … AC-151)
// and the bake-off against the committed fixture (AC-43).
extension TranscribeModel {
    var sweepMarkdown: String { BenchTable.markdown(sweep.rows) }

    func runSweep() {
        guard !sweep.running else { return }
        let plan = BenchConfiguration.phone
        let runsEach = 3
        sweep.rows = []
        sweep.progress = 0
        sweep.total = plan.count * runsEach
        sweep.refusal = nil
        sweep.running = true
        sweep.task = Task {
            defer { sweep.running = false; sweep.task = nil }
            do {
                sweep.rows = try await BenchSweep.run(
                    plan, runsEach: runsEach, on: PhoneBenchStage(model: self))
            } catch BenchSweep.Refusal.refused(let why) {
                sweep.refusal = why
            } catch {
                sweep.refusal = "\(error)"
            }
        }
    }

    /// Cancellation keeps the rows already measured — a sweep stopped
    /// halfway still measured what it measured — and the levers still come
    /// back to what the person chose (AC-151).
    func stopSweep() { sweep.task?.cancel() }

    func noteSweepMeasurement() { sweep.progress += 1 }

    /// The voice the bench measures — the same object the conversation
    /// speaks with, never a fresh one built for the occasion. A bench that
    /// measured its own private voice would be measuring a configuration
    /// nobody is using.
    var benchVoice: NeuralVoice { neuralVoice }

    /// AC-149. `bargeCount` and `onsetsWhileSpeaking` are NOT in `start()`'s
    /// reset list, so across a sweep they accumulate and every row reports
    /// the sum of the rows before it.
    func resetBenchCounters() {
        bargeCount = 0
        onsetsWhileSpeaking = 0
    }

    /// Free dirty memory, or nil when the device will not say. NOT zero —
    /// `os_proc_available_memory` returns an ambiguous 0 on the machines
    /// that have no limit (INSTRUMENTS §30), and a bench row printing
    /// "0 MB" would be reporting a measurement it never made.
    func freeMegabytesNow() -> Int? {
        switch MemoryHeadroomReader.read() {
        case .bytes(let bytes): Int(bytes / 1_048_576)
        case .exhausted: 0
        case .unavailable: nil
        }
    }

    // MARK: - the bake-off (AC-43): the SAME committed fixture as the Mac

    /// One engine as the bake-off sees it: the label the rows carry, the
    /// engine that decodes, and whether its model is on this device.
    private struct Contender {
        let name: String
        let engine: any TranscriptionEngine
        let installed: Bool
    }

    func runBakeoff() async {
        guard !isListening, bakeoffStatus == nil else { return }
        bakeoffRows = []
        guard let wav = Bundle.main.url(forResource: "ryad-en", withExtension: "wav"),
              let refURL = Bundle.main.url(forResource: "bakeoff-reference", withExtension: "txt"),
              let reference = try? String(contentsOf: refURL, encoding: .utf8),
              let audio = try? BakeoffHarness.loadAudio(wav) else {
            bakeoffStatus = "fixtures missing from the bundle"
            return
        }

        let engines: [Contender] = [
            .init(name: "Apple SpeechAnalyzer", engine: appleEngine,
                  installed: await appleEngine.modelInstalled()),
            .init(name: "Whisper base", engine: whisperEngine,
                  installed: await whisperEngine.modelInstalled())
        ]
        for contender in engines {
            let name = contender.name
            let engine = contender.engine
            guard contender.installed else {
                bakeoffStatus = "\(name): model not installed — skipped"
                continue
            }
            bakeoffStatus = "\(name): warm-up (excluded)…"
            _ = try? await BakeoffHarness.measure(
                engine: engine, label: "warmup",
                samples: audio.samples, sampleRate: audio.sampleRate, reference: reference)
            bakeoffStatus = "\(name): measuring…"
            do {
                let row = try await BakeoffHarness.measure(
                    engine: engine, label: name,
                    samples: audio.samples, sampleRate: audio.sampleRate, reference: reference)
                bakeoffRows.append(row)
            } catch {
                bakeoffStatus = "\(name): failed — \(error)"
            }
        }
        bakeoffStatus = nil
    }

    /// The rows as a markdown table — copy straight into BAKEOFF.md.
    var bakeoffMarkdown: String {
        var lines = ["| Engine | WER | sub | ins | del | decode settle | device |",
                     "|---|---|---|---|---|---|---|"]
        for row in bakeoffRows {
            lines.append(String(
                format: "| %@ | **%.1f%%** | %d | %d | %d | %.2f s | iPhone |",
                row.engineName, row.score.wer * 100, row.score.substitutions,
                row.score.insertions, row.score.deletions, row.decodeSeconds))
        }
        return lines.joined(separator: "\n")
    }
}
