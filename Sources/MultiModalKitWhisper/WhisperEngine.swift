import AVFoundation
import MultiModalKit
import WhisperKit

/// The second engine (D-017, D-023): Whisper, on-device via WhisperKit's
/// CoreML pipeline, behind the same seam as everything else. The session
/// cannot tell it from the Apple engine or the scripted one — which is the
/// whole point, and the conformance kit proves it.
///
/// This engine tells the truth about itself (AC-38): it emits **no**
/// partials, it wants the **whole utterance**, and it wants **16 kHz**. The
/// session already knows what to do with that shape (D-024): a decode may
/// finish after the next utterance began, and its final survives, tagged.
///
/// An actor on purpose: WhisperKit's pipeline is one mutable object, and
/// several settling decodes may exist at once (D-024) — actor isolation
/// serializes them without a single manual lock.
public actor WhisperEngine: TranscriptionEngine {
    public nonisolated let capabilities = EngineCapabilities(
        emitsPartials: false,
        wantsWholeUtterance: true,
        requiredSampleRate: 16_000
    )

    private let model: String
    private nonisolated let diagnostics: PipelineDiagnostics?
    private var pipeline: WhisperKit?

    public init(model: String = "base", diagnostics: PipelineDiagnostics? = nil) {
        self.model = model
        self.diagnostics = diagnostics
    }

    /// Honest disk check against WhisperKit's default hub location — no
    /// download is ever triggered by asking.
    public nonisolated func modelInstalled() async -> Bool {
        let folder = URL.documentsDirectory
            .appending(path: "huggingface/models/argmaxinc/whisperkit-coreml")
            .appending(path: "openai_whisper-\(model)")
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        return (contents?.isEmpty == false)
    }

    /// Downloads (Hugging Face, ~142 MB for `base`) and loads the pipeline.
    /// Idempotent; the download half is skipped when the model is on disk.
    public func ensureModel() async throws {
        _ = try await loadedPipeline()
    }

    public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun {
        if pipeline == nil {
            guard await modelInstalled() else {
                throw TranscriptionFailure.modelNotInstalled
            }
        }
        let pipeline = try await loadedPipeline()
        _ = pipeline   // loaded and cached; the run reaches it through decode(_:)

        guard let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                channels: AVAudioChannelCount(format.channels), interleaved: false),
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw TranscriptionFailure.audioFormatRejected
        }
        return WhisperRun(engine: self, converter: converter, sourceFormat: source, targetFormat: target)
    }

    private var decodeBusy = false
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []

    /// One decode at a time — ENFORCED, not assumed. The first field session
    /// caught the original sin in one screenshot: three decode spans
    /// overlapping and finishing together, because an actor does NOT hold
    /// isolation across an await — the moment transcribe() suspends, the
    /// next decode walks in. The reentrancy law, violated by its own
    /// preacher. Now a waiter queue serializes for real: while-loop re-check
    /// after every wake (the law again), FIFO wake-up, release on every
    /// exit path via defer.
    func decode(_ samples: [Float]) async throws -> String {
        let pipeline = try await loadedPipeline()
        while decodeBusy {
            await withCheckedContinuation { decodeWaiters.append($0) }
        }
        decodeBusy = true
        defer {
            decodeBusy = false
            if !decodeWaiters.isEmpty { decodeWaiters.removeFirst().resume() }
        }
        let span = diagnostics?.signposts.begin("whisper.decode")
        defer { if let span { diagnostics?.signposts.end(span) } }
        return try await decodeBody(pipeline, samples)
    }

    private func decodeBody(_ pipeline: WhisperKit, _ samples: [Float]) async throws -> String {
        do {
            let results = try await pipeline.transcribe(audioArray: samples)
            let joined = results.map(\.text).joined(separator: " ")
            // Whisper emits non-speech CONTROL tokens like [BLANK_AUDIO] or
            // [MUSIC]; they are markers, not words a person said — stripped
            // here so no consumer ever mistakes them for transcription.
            let stripped = joined.replacingOccurrences(
                of: #"\[[A-Za-z_ ]+\]"#, with: "", options: .regularExpression)
            return stripped
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        } catch {
            throw TranscriptionFailure.engineFailed(String(describing: error))
        }
    }

    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        do {
            let config = WhisperKitConfig(model: model)
            let fresh = try await WhisperKit(config)
            pipeline = fresh
            return fresh
        } catch {
            throw TranscriptionFailure.assetDownloadFailed(String(describing: error))
        }
    }
}

/// One utterance's worth of audio, accumulated, then decoded once.
///
/// `@unchecked Sendable` with the same written contract as the Apple run:
/// the session calls `feed`/`finishAudio`/`cancel` strictly serially from
/// its one loop, so the converter and the accumulator are only ever touched
/// by those serial calls. The decode task is the adapter-boundary exception
/// (like AppleRun's bridge): it runs in the background so `finishAudio`
/// returns immediately — a session loop that waited seconds for a decode
/// would block the very overlap D-024 exists for. Its only effect is
/// yielding into `updates`; a dead run's yields die at the session's ticket.
private final class WhisperRun: TranscriptionRun, @unchecked Sendable {
    let updates: AsyncStream<TranscriptionUpdate>

    private let engine: WhisperEngine
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let out: AsyncStream<TranscriptionUpdate>.Continuation
    private var accumulated: [Float] = []
    private var decodeTask: Task<Void, Never>?
    private var torndown = false

    init(engine: WhisperEngine, converter: AVAudioConverter,
         sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.engine = engine
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        var handle: AsyncStream<TranscriptionUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
    }

    func feed(_ chunk: MultiModalKit.AudioChunk) async {
        guard !torndown,
              let inBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount))
        else { return }
        inBuffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            inBuffer.floatChannelData![0].update(from: source.baseAddress!, count: chunk.frameCount)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(chunk.frameCount) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        // Same SDK quirk as the Apple adapter: the block is marked @Sendable
        // but runs synchronously inside convert() — the box writes that down.
        final class HandOff: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let hand = HandOff(inBuffer)
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if let buffer = hand.buffer {
                hand.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = .noDataNow
            return nil
        }
        guard conversionError == nil, outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData else { return }
        accumulated.append(contentsOf: UnsafeBufferPointer(
            start: channel[0], count: Int(outBuffer.frameLength)))
    }

    func finishAudio() async {
        guard !torndown else { return }
        torndown = true
        let samples = accumulated
        accumulated = []
        let engine = engine
        let out = out
        decodeTask = Task {
            do {
                let text = try await engine.decode(samples)
                out.yield(.final(text))
            } catch let failure as TranscriptionFailure {
                out.yield(.failed(failure))
            } catch {
                out.yield(.failed(.engineFailed(String(describing: error))))
            }
            out.finish()
        }
    }

    func cancel() async {
        let hadDecode = torndown
        torndown = true
        accumulated = []
        decodeTask?.cancel()
        if !hadDecode {
            out.finish()   // never decoded: the stream just ends, no final
        }
        // A cancelled decode still finishes its stream from the task; its
        // late yield, if any, dies at the session's ticket.
    }
}
