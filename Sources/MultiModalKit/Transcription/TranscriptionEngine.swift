/// The engine seam (SPEC AC-21, D-017). The session talks to THIS — never to
/// Apple's API, never to a Whisper package. Two engines, one contract, and a
/// conformance kit that both must pass.

/// What the session sends into an engine.
public struct AudioStreamFormat: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double = 48_000, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// What an engine admits about itself (AC-35, D-017). A streaming engine and
/// a batch engine can live behind one protocol only if the session never has
/// to guess which one it is holding.
public struct EngineCapabilities: Sendable, Equatable {
    /// Does text arrive while audio still flows? (Apple: yes. Whisper: no.)
    public var emitsPartials: Bool
    /// Does the engine buffer the whole utterance and decode at the end?
    public var wantsWholeUtterance: Bool
    /// A sample rate the engine insists on, if any (Whisper: 16 kHz).
    public var requiredSampleRate: Double?
    /// The longest utterance the engine itself will accept, if limited.
    public var maximumUtterance: Duration?

    public init(
        emitsPartials: Bool,
        wantsWholeUtterance: Bool = false,
        requiredSampleRate: Double? = nil,
        maximumUtterance: Duration? = nil
    ) {
        self.emitsPartials = emitsPartials
        self.wantsWholeUtterance = wantsWholeUtterance
        self.requiredSampleRate = requiredSampleRate
        self.maximumUtterance = maximumUtterance
    }
}

/// The ways a recognition really fails (AC-29). The first two shapes were
/// observed live in the SpeechAnalyzer spike — the model is an asset that may
/// be absent, and its download may die mid-flight ("final state: Network
/// Error"). Failure is an event the session survives, never a crash.
public enum TranscriptionFailure: Error, Sendable, Equatable {
    case modelNotInstalled
    case assetDownloadFailed(String)
    case audioFormatRejected
    case engineFailed(String)
}

/// What one recognition can say back. No timestamps here on purpose — the
/// engine knows nothing about audio time; the SESSION stamps events (D-011).
public enum TranscriptionUpdate: Sendable, Equatable {
    /// A hypothesis. Each partial REPLACES the previous one — never append:
    /// a batch engine may rewrite its whole window (AC-28).
    case partial(String)
    /// The settled text. After this, the run is over and says nothing more.
    case final(String)
    /// The run died. Also terminal.
    case failed(TranscriptionFailure)
}

/// ONE recognition — one utterance's worth of audio in, updates out (AC-23).
public protocol TranscriptionRun: Sendable {
    /// The run's updates. Single consumer: the session.
    var updates: AsyncStream<TranscriptionUpdate> { get }
    /// Hand the run one chunk of audio, in order.
    func feed(_ chunk: AudioChunk) async
    /// No more audio is coming — settle and emit the final.
    func finishAudio() async
    /// Abandon the run. A conformant engine then ends `updates` without a
    /// final; a defiant one may still answer late — which is exactly why the
    /// session's ticket, not this call, is the guarantee (AC-25, D-019).
    func cancel() async
}

/// A factory for recognitions. The only thing the session ever holds.
public protocol TranscriptionEngine: Sendable {
    var capabilities: EngineCapabilities { get }
    /// Opens one recognition. Throws a `TranscriptionFailure` when the engine
    /// cannot start one at all (no model, bad format).
    func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun
}

/// What the session publishes to its listeners (AC-27). Every event carries
/// the utterance's number and a moment in AUDIO time (frames ÷ sample rate):
/// for text events, the audio already fed to the engine when the text was
/// published — which makes capture→partial latency an exact number (AC-31).
public enum TranscriptEvent: Sendable, Equatable {
    case partial(String, utterance: Int, at: AudioTime)
    case final(String, utterance: Int, at: AudioTime)
    case failed(TranscriptionFailure, utterance: Int, at: AudioTime)
    case truncated(utterance: Int, at: AudioTime)
}
