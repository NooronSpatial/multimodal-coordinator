import AVFoundation
import Foundation
import Observation
#if os(iOS)
import Darwin
#endif

/// One measured decode, as the screen shows it.
struct SpikeRow: Sendable, Identifiable {
    let id = UUID()
    let mouth: String
    let fixture: String
    /// `false` for the warm-up, which is REPORTED and never averaged —
    /// Kokoro's vendor claim is explicitly "after warm up", and hiding a
    /// cold run would be measuring their best case and calling it the
    /// phone's.
    let counted: Bool
    let wallMilliseconds: Double
    let audioMilliseconds: Double
    /// The SHARED memory number: this process's peak footprint while the
    /// decode ran, sampled the same way for both mouths.
    let footprintPeakBytes: Int
    /// The process at REST before this decode — so the fixed cost of
    /// HOLDING a model is told apart from the transient cost of USING it.
    /// That separation is the whole question of the length sweep.
    let footprintBaselineBytes: Int
    /// The vendor's own counter, where it keeps one. MLX does, CoreML
    /// does not — so this column is empty for Qwen, and saying so is the
    /// point.
    let vendorPeakBytes: Int?
    var realTimeFactor: Double { wallMilliseconds / audioMilliseconds }
}

/// The spike's whole state (4p, D-082).
@MainActor
@Observable
final class SpikeModel {
    enum Phase: Equatable {
        case needsAssets
        case downloading(name: String, fraction: Double)
        case loadingKokoro
        case loadingQwen
        case ready
        case speaking(mouth: String, fixture: String)
        case failed(String)
    }

    /// The two sentences the cushion sweep uses, character for character.
    /// Different text would produce numbers that cannot be laid beside
    /// INSTRUMENTS §53/§54, which is the entire reason this spike exists.
    static let fixtures: [(name: String, text: String)] = [
        ("short", "The audio travels through a ring buffer."),
        ("long", "The audio travels through a ring buffer "
            + "into a pump that cuts it into small chunks, and each chunk is "
            + "handed to a listener that decides whether the person is still "
            + "speaking or has finally stopped and is waiting for an answer.")
    ]

    /// THE LENGTH LADDER (Ryad's ruling A, after the two-mouth table).
    ///
    /// Nested PREFIXES of the same sentence, not five unrelated ones:
    /// vocabulary, prosody and phoneme mix are held constant so the only
    /// thing that varies is length. The first and last rungs are the two
    /// fixtures already measured, which anchors the ladder to numbers we
    /// have rather than starting a fresh scale.
    ///
    /// The question it answers: Kokoro's peak went 900 MB at 2.7 s to
    /// 2300 MB at 13.7 s. Two points are not a curve, and the app never
    /// decodes 13.7 seconds at once — the phraser cuts replies into
    /// sentences — so what matters is the shape down at sentence size.
    static let ladder: [(name: String, text: String)] = [
        ("L1", "The audio travels."),
        ("L2", "The audio travels through a ring buffer."),
        ("L3", "The audio travels through a ring buffer into a pump."),
        ("L4", "The audio travels through a ring buffer into a pump "
            + "that cuts it into small chunks."),
        ("L5", "The audio travels through a ring buffer into a pump "
            + "that cuts it into small chunks, and each chunk is handed "
            + "to a listener."),
        ("L6", "The audio travels through a ring buffer "
            + "into a pump that cuts it into small chunks, and each chunk is "
            + "handed to a listener that decides whether the person is still "
            + "speaking or has finally stopped and is waiting for an answer.")
    ]

    /// How many COUNTED runs per sentence, after the warm-up. Three, so a
    /// median exists; a single sample is one sample wearing a median's
    /// clothes.
    static let repeats = 3

    private(set) var phase: Phase = .needsAssets
    private(set) var rows: [SpikeRow] = []
    var speakAloud = true
    /// Qwen's weights are ~1 GB and this app has its own container, so
    /// the demo's copy cannot be borrowed. Off by default: a person who
    /// only wants the Kokoro number should not be made to pay for it.
    var includeQwen = false
    /// Which weights Kokoro loads. `mlx-community/Kokoro-82M-bf16` turned
    /// out to be fp32 in disguise, so half precision is built on the
    /// phone — see `WeightPrecision`.
    var precision: WeightPrecision = .float32

    private let kokoro = KokoroEngine()
    private let qwen = QwenEngine()
    private var qwenLoaded = false
    private let player = SpikePlayer()

    init() {
        phase = SpikeAssets.allInstalled ? .loadingKokoro : .needsAssets
    }

    /// Megabytes left before this process is killed, or nil when the
    /// platform will not say. `os_proc_available_memory` answers 0 both
    /// when it has no information AND when the process is already over
    /// its limit — the library's `MemoryHeadroom` exists to keep those two
    /// apart, and it cannot be linked here, so this reports the raw
    /// number with the ambiguity stated rather than hidden.
    var headroomMegabytes: Int? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? bytes / 1_048_576 : nil
        #else
        return nil
        #endif
    }

    var modelSizeText: String {
        String(format: "%.0f MB", Double(SpikeAssets.model.expectedBytes) / 1_000_000)
    }

    var mouthNames: [String] {
        var names = [kokoro.name]
        if includeQwen { names.append(qwen.name) }
        return names
    }

    /// Median wall ÷ audio over the counted runs, per mouth and fixture.
    /// Median rather than mean, because one thermal stall drags a mean
    /// and the Mac sweep already learned that lesson.
    func medianRTF(mouth: String, fixture: String) -> Double? {
        let values = rows
            .filter { $0.mouth == mouth && $0.fixture == fixture && $0.counted }
            .map(\.realTimeFactor).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    func peakMegabytes(mouth: String) -> Int? {
        let peaks = rows.filter { $0.mouth == mouth }.map(\.footprintPeakBytes)
        guard let peak = peaks.max() else { return nil }
        return peak / 1_048_576
    }

    func fetchAssets() async {
        for asset in [SpikeAssets.model, SpikeAssets.voice] where !SpikeAssets.isInstalled(asset) {
            phase = .downloading(name: asset.name, fraction: 0)
            do {
                try await SpikeAssets.download(asset) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(name: asset.name, fraction: fraction)
                    }
                }
            } catch {
                phase = .failed(String(describing: error))
                return
            }
        }
        await loadModel()
    }

    func loadModel() async {
        phase = .loadingKokoro
        do {
            try await kokoro.load(precision: precision)
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Rebuilds Kokoro at another precision. Converting 548 tensors takes
    /// a moment the first time and nothing afterwards.
    func reload(at precision: WeightPrecision) async {
        self.precision = precision
        rows.removeAll()
        await loadModel()
    }

    /// The length sweep: one mouth, six rungs, same stopwatch.
    func runLadder() async {
        rows.removeAll()
        for rung in Self.ladder {
            guard await measure(kokoro, rung) else { return }
        }
        phase = .ready
    }

    /// The measured pass: every mouth, every sentence, one warm-up then
    /// `repeats` counted runs.
    ///
    /// Kokoro goes first and Qwen second, always. That ORDER is a known
    /// confound — this phone heats — and it is reported rather than
    /// corrected, because every row stays on screen. The Mac sweep had to
    /// counterbalance for exactly this reason; if the two mouths land
    /// close enough for order to matter, that is the moment to spend the
    /// same effort here.
    func runAll() async {
        rows.removeAll()
        if includeQwen, !qwenLoaded {
            phase = .loadingQwen
            do {
                try await qwen.load()
                qwenLoaded = true
            } catch {
                phase = .failed("Qwen load failed: \(error)")
                return
            }
        }
        var mouths: [any SpikeMouth] = [kokoro]
        if includeQwen { mouths.append(qwen) }

        for mouth in mouths {
            for fixture in Self.fixtures {
                guard await measure(mouth, fixture) else { return }
            }
        }
        phase = .ready
    }

    /// One fixture on one mouth: warm-up plus the counted runs. Returns
    /// false when a decode failed, so the caller stops rather than
    /// reporting a half table as if it were whole.
    private func measure(_ mouth: any SpikeMouth,
                         _ fixture: (name: String, text: String)) async -> Bool {
        for attempt in 0...Self.repeats {
            phase = .speaking(mouth: mouth.name, fixture: fixture.name)
            // THE SAME STOPWATCH AND THE SAME SAMPLER FOR BOTH MOUTHS.
            // Every line from here to the row is shared code; nothing a
            // vendor does can put a thumb on this scale.
            let sampler = FootprintSampler()
            await sampler.start()
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let result = try await mouth.speak(fixture.text)
                let wall = start.duration(to: clock.now)
                let watched = await sampler.stop()
                let audioMilliseconds =
                    Double(result.samples.count) * 1000 / Double(result.sampleRate)
                guard audioMilliseconds > 0 else {
                    phase = .failed("\(mouth.name) produced no audio for \(fixture.name)")
                    return false
                }
                rows.append(SpikeRow(mouth: mouth.name,
                                     fixture: fixture.name,
                                     counted: attempt > 0,
                                     wallMilliseconds: wall.milliseconds,
                                     audioMilliseconds: audioMilliseconds,
                                     footprintPeakBytes: watched.peak,
                                     footprintBaselineBytes: watched.baseline,
                                     vendorPeakBytes: mouth.vendorPeakBytes))
                if speakAloud, attempt == Self.repeats {
                    // Only the last run is played, so listening never
                    // sits inside the timed sequence.
                    player.play(result.samples, sampleRate: result.sampleRate)
                }
            } catch {
                _ = await sampler.stop()
                phase = .failed(String(describing: error))
                return false
            }
        }
        return true
    }

    /// The report, as text he can copy out of the phone into INSTRUMENTS.
    var report: String {
        var lines = ["KOKORO SPIKE (4p) — one app, one stopwatch, one sampler",
                     "RTF is wall ÷ audio; lower is better. Peak and rest are this",
                     "PROCESS's footprint, sampled every "
                        + "\(FootprintSampler.intervalMilliseconds) ms — a spike shorter",
                     "than that interval is invisible, so a peak is a floor, never a ceiling.",
                     "Kokoro weights: \(precision.label)"
                        + (precision.bytes.map { ", \($0 / 1_048_576) MB on disk" } ?? ""),
                     "",
                     "| mouth | fixture | run | wall ms | audio ms | RTF | rest MB | peak MB | over rest MB |",
                     "|---|---|---|---|---|---|---|---|---|"]
        for row in rows {
            lines.append(String(format: "| %@ | %@ | %@ | %.0f | %.0f | %.2f | %d | %d | %d |",
                                row.mouth, row.fixture, row.counted ? "counted" : "warm-up",
                                row.wallMilliseconds, row.audioMilliseconds, row.realTimeFactor,
                                row.footprintBaselineBytes / 1_048_576,
                                row.footprintPeakBytes / 1_048_576,
                                (row.footprintPeakBytes - row.footprintBaselineBytes) / 1_048_576))
        }
        lines.append("")
        lines.append(contentsOf: slopeLines)
        for mouth in mouthNames {
            for fixture in Self.fixtures {
                if let median = medianRTF(mouth: mouth, fixture: fixture.name) {
                    lines.append(String(format: "median RTF %@ / %@: %.2f",
                                        mouth, fixture.name, median))
                }
            }
            if let peak = peakMegabytes(mouth: mouth) {
                lines.append("peak footprint \(mouth): \(peak) MB")
            }
        }
        if let headroom = headroomMegabytes { lines.append("headroom left: \(headroom) MB") }
        lines.append("MLX cache limit: \(KokoroEngine.cacheLimitBytes / 1_048_576) MB")
        lines.append("field reference: Qwen3 RTF 1.21 in the live app (INSTRUMENTS)")
        return lines.joined(separator: "\n")
    }

    /// The ladder's answer, computed rather than eyeballed: how many
    /// megabytes each extra second of speech costs, between consecutive
    /// rungs. A flat column means the cost is linear; a rising one means
    /// it is not, and either way the phrase-sized end is where the app
    /// lives.
    private var slopeLines: [String] {
        let points = Self.ladder.compactMap { rung -> (audio: Double, over: Double)? in
            let counted = rows.filter { $0.fixture == rung.name && $0.counted }
            guard let row = counted.first else { return nil }
            let over = Double(row.footprintPeakBytes - row.footprintBaselineBytes)
            return (row.audioMilliseconds / 1000, over / 1_048_576)
        }
        guard points.count > 1 else { return [] }
        var lines = ["| from → to (s of audio) | MB per extra second |", "|---|---|"]
        for (previous, next) in zip(points, points.dropFirst()) {
            let seconds = next.audio - previous.audio
            guard seconds > 0 else { continue }
            lines.append(String(format: "| %.1f → %.1f | %.0f |",
                                previous.audio, next.audio,
                                (next.over - previous.over) / seconds))
        }
        lines.append("")
        return lines
    }
}

/// Playback, kept as small as it can be: this spike measures decoders,
/// and every line of audio graph here is a line that could explain a bad
/// number with something other than the decoder.
@MainActor
final class SpikePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var started = false
    private var startedRate: Double?

    func play(_ samples: [Float], sampleRate: Int) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate),
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        // Two mouths could disagree on rate, so the graph is rebuilt when
        // it changes rather than assumed constant. Both are 24 kHz today;
        // "today" is not a guarantee, and a stale format is the fault the
        // field heard as a drunk voice.
        if started, startedRate != format.sampleRate {
            node.stop()
            engine.stop()
            started = false
        }
        if !started {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            if node.engine == nil { engine.attach(node) }
            engine.connect(node, to: engine.mainMixerNode, format: format)
            guard (try? engine.start()) != nil else { return }
            started = true
            startedRate = format.sampleRate
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }
}
