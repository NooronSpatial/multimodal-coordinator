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
