/// A source of live audio frames (SPEC AC-6, AC-7).
///
/// An audio source pushes samples into the ring's producer handle. The real
/// implementation is the microphone; tests use a scripted fake. The seam
/// exists so that no test ever touches real audio hardware — and so the
/// capture technology can be swapped (D-001: installTap now, AVAudioSinkNode
/// later) without changing anything downstream.
public protocol AudioSource: AnyObject {
    /// Begin delivering frames into `producer`. Implementations must obey
    /// the iron laws inside their delivery callback: view the incoming
    /// buffer, copy it into the ring, return. Nothing else.
    func start(into producer: AudioRingProducer) throws

    /// Stop delivering frames. Safe to call more than once.
    func stop()
}

/// Why a source could not start.
public enum AudioSourceFailure: Error, Sendable, Equatable {
    /// The platform handed back an input format with no sample rate or
    /// no channels — a microphone that is not available, not permitted,
    /// or not yet configured.
    ///
    /// It exists because handing such a format to `installTap` does not
    /// fail, it **aborts the process**:
    ///
    ///   required condition is false:
    ///   IsFormatSampleRateAndChannelCountValid(format)
    ///
    /// A caller that cannot open a microphone deserves to be told, on
    /// screen, in words. It does not deserve a crash, and a person
    /// holding a phone deserves it least of all.
    case inputUnavailable(sampleRate: Double, channels: UInt32)
}
