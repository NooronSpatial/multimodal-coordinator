import AVFoundation
import Foundation
import Observation

/// One measured decode, as the screen shows it.
struct SpikeRow: Sendable, Identifiable {
    let id = UUID()
    let fixture: String
    /// `false` for the warm-up, which is REPORTED and never averaged —
    /// the vendor's own claim is "after warm up", so hiding the cold run
    /// would be measuring their best case and calling it the phone's.
    let counted: Bool
    let wallMilliseconds: Double
    let audioMilliseconds: Double
    var realTimeFactor: Double { wallMilliseconds / audioMilliseconds }
}

/// The spike's whole state (4p, D-082).
///
/// One `@MainActor @Observable` model, one actor holding the vendor. The
/// pattern is the demo app's, deliberately: this is a throwaway
/// instrument, and a throwaway instrument that behaves differently from
/// the real app measures a different app.
@MainActor
@Observable
final class SpikeModel {
    enum Phase: Equatable {
        case needsAssets
        case downloading(name: String, fraction: Double)
        case loading
        case ready
        case speaking(String)
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

    /// How many COUNTED runs per sentence, after the warm-up. Three, so a
    /// median exists; a single sample is one sample wearing a median's
    /// clothes.
    static let repeats = 3

    private(set) var phase: Phase = .needsAssets
    private(set) var rows: [SpikeRow] = []
    var speakAloud = true

    private let engine = KokoroEngine()
    private let player = SpikePlayer()

    init() {
        phase = SpikeAssets.allInstalled ? .loading : .needsAssets
    }

    var modelSizeText: String {
        String(format: "%.0f MB", Double(SpikeAssets.model.expectedBytes) / 1_000_000)
    }

    /// Median wall ÷ audio over the counted runs of one fixture, or nil
    /// while none exist. Median rather than mean, because one thermal
    /// stall would drag a mean and the sweep already learned that lesson.
    func medianRTF(of fixture: String) -> Double? {
        let values = rows.filter { $0.fixture == fixture && $0.counted }
            .map(\.realTimeFactor).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
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
        phase = .loading
        do {
            try await engine.load(model: SpikeAssets.location(of: SpikeAssets.model),
                                  voice: SpikeAssets.location(of: SpikeAssets.voice))
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// The measured pass: one warm-up per sentence, then `repeats` counted
    /// runs, in fixture order.
    ///
    /// No cool-down between runs. The Mac sweep needed one and could not
    /// afford it; here the honest move is to REPORT the order rather than
    /// pretend it does not matter — every row is on screen, so a run that
    /// drifts upward is visible instead of averaged away.
    func runAll() async {
        rows.removeAll()
        for fixture in Self.fixtures {
            for attempt in 0...Self.repeats {
                phase = .speaking(fixture.name)
                do {
                    let result = try await engine.speak(fixture.text)
                    rows.append(SpikeRow(fixture: fixture.name,
                                         counted: attempt > 0,
                                         wallMilliseconds: result.measurement.wallMilliseconds,
                                         audioMilliseconds: result.measurement.audioMilliseconds))
                    if speakAloud, attempt == Self.repeats {
                        // Only the last run is played, so listening does
                        // not sit inside the timed sequence.
                        player.play(result.samples, sampleRate: KokoroEngine.sampleRate)
                    }
                } catch {
                    phase = .failed(String(describing: error))
                    return
                }
            }
        }
        phase = .ready
    }

    /// The report, as text he can copy out of the phone into INSTRUMENTS.
    var report: String {
        var lines = ["KOKORO SPIKE (4p) — RTF is wall ÷ audio; lower is better",
                     "| fixture | run | wall ms | audio ms | RTF |",
                     "|---|---|---|---|---|"]
        for row in rows {
            lines.append(String(format: "| %@ | %@ | %.0f | %.0f | %.2f |",
                                row.fixture, row.counted ? "counted" : "warm-up",
                                row.wallMilliseconds, row.audioMilliseconds, row.realTimeFactor))
        }
        for fixture in Self.fixtures {
            if let median = medianRTF(of: fixture.name) {
                lines.append(String(format: "median RTF (%@): %.2f", fixture.name, median))
            }
        }
        lines.append("phone Qwen3 reference: RTF 1.21 (INSTRUMENTS)")
        return lines.joined(separator: "\n")
    }
}

/// Playback, kept as small as it can be: this spike measures a decoder,
/// and every line of audio graph here is a line that could explain a bad
/// number with something other than the decoder.
@MainActor
final class SpikePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var started = false

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
        if !started {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            guard (try? engine.start()) != nil else { return }
            started = true
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
    }
}
