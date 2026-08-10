import AVFoundation
import Foundation
import MultiModalKit

/// The bake-off's engine room (D-025, AC-42/43): one implementation used by
/// the macOS CLI and the iOS demo, so both platforms measure the same way —
/// same chunking, same settle definition, same scoring.
public struct BakeoffMeasurement: Sendable {
    public let engineName: String
    public let text: String
    public let score: WordErrorRate.Score
    public let decodeSeconds: Double

    public init(engineName: String, text: String,
                score: WordErrorRate.Score, decodeSeconds: Double) {
        self.engineName = engineName
        self.text = text
        self.score = score
        self.decodeSeconds = decodeSeconds
    }
}

public enum BakeoffHarness {
    /// Loads a mono WAV into Float samples at its native rate.
    public static func loadAudio(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionFailure.audioFormatRejected
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else {
            throw TranscriptionFailure.audioFormatRejected
        }
        let samples = Array(UnsafeBufferPointer(start: channel[0],
                                                count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }

    /// Feeds the whole clip through ONE run of the engine, 20 ms at a time,
    /// then settles and waits for the final. `decodeSeconds` is the wall
    /// clock from "no more audio" to the final text — the pause a user
    /// would feel after finishing a sentence.
    public static func measure(
        engine: any TranscriptionEngine, label: String,
        samples: [Float], sampleRate: Double, reference: String
    ) async throws -> BakeoffMeasurement {
        let run = try await engine.openRun(
            format: AudioStreamFormat(sampleRate: sampleRate, channels: 1))
        let chunkFrames = Int(sampleRate * 0.02)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkFrames, samples.count)
            await run.feed(AudioChunk(
                samples: Array(samples[offset..<end]),
                start: AudioTime(frames: offset, sampleRate: sampleRate)))
            offset = end
        }
        let settleStart = Date()
        await run.finishAudio()
        var text = ""
        for await update in run.updates {
            switch update {
            case .partial(let partial): text = partial
            case .final(let final): text = final
            case .failed(let failure): throw failure
            }
        }
        return BakeoffMeasurement(
            engineName: label, text: text,
            score: WordErrorRate.score(reference: reference, hypothesis: text),
            decodeSeconds: Date().timeIntervalSince(settleStart))
    }
}
