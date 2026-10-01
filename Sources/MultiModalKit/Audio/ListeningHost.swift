import AVFAudio
import Synchronization

/// What one reply gave the person to hear, in pauses (5d, ⑥; AC-341).
public struct ReplyPauses: Sendable, Equatable {
    /// Silent stretches inside the reply at least the meter's gap long.
    public let gaps: Int
    /// The longest silent stretch inside the reply, of any length.
    public let longest: Duration
    /// The quiet between the reply's first rendered sample and its first
    /// audible one — what the person still waits through after the first
    /// sound is stamped (5d piece 2; F-35 A, AC-351). Nil: nothing audible.
    public let leadingQuiet: Duration?

    public init(gaps: Int, longest: Duration, leadingQuiet: Duration? = nil) {
        self.gaps = gaps
        self.longest = longest
        self.leadingQuiet = leadingQuiet
    }
}

/// A HOST THAT LISTENS TO WHAT IT PLAYS (5d, ⑥; SPEC §225/2, F-27 A).
///
///     mouth ─attach(node)─▶ ListeningHost ─▶ the real host (an engine, the capture engine)
///                               │ a tap on the node: every buffer it plays
///                               ▼
///                         this reply's SilenceMeter
///     mouth ─detach(node)─▶ tap removed ─▶ heard(ReplyPauses) — once per reply
///
/// Both mouth families attach a fresh player node for each synthesis run and
/// give it back at the end, so one meter per node is one meter per reply,
/// whichever mouth speaks. It measures what the person HEARS: a starved
/// player renders silence, and the tap hears that silence.
///
/// `@unchecked Sendable`, with the proof written out (the house rule):
/// 1. The host's own mutable state — which node has which ear — lives in
///    the one `Mutex`, touched by attach and detach, never by the audio side.
/// 2. Each reply's meter is touched ONLY by its own node's tap, which a node
///    delivers one buffer at a time: the audio side takes no lock and
///    allocates nothing (it reads each buffer in place).
/// 3. What leaves the tap — the count and the longest stretch — is published
///    through atomics after every buffer, so `detach` reads them without
///    touching the meter. A buffer still in flight while the tap is removed
///    can be missed; it is the reply's tail, and a tail is never a pause.
public final class ListeningHost: PlaybackHost, @unchecked Sendable {
    private let host: any PlaybackHost
    private let level: Float
    private let minimumGap: Duration
    private let heard: @Sendable (ReplyPauses) -> Void
    private let ears = Mutex<[ObjectIdentifier: ReplyEar]>([:])

    /// - Parameters:
    ///   - host: where the replies really render.
    ///   - level, minimumGap: the meter's two numbers (`SilenceMeter.Config`).
    ///   - heard: called once per reply, when its node is given back, on
    ///     whatever thread the mouth gives it back on.
    public init(wrapping host: any PlaybackHost, level: Float = 0.001,
                minimumGap: Duration = .milliseconds(300),
                heard: @escaping @Sendable (ReplyPauses) -> Void) {
        self.host = host
        self.level = level
        self.minimumGap = minimumGap
        self.heard = heard
    }

    public func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws {
        try host.attachForPlayback(node, format: format)
        let ear = ReplyEar(meter: SilenceMeter(config: .init(
            level: level, minimumGap: minimumGap, sampleRate: format.sampleRate)))
        // A tap hears the node from the moment it is ATTACHED — silent
        // buffers while the first phrase is still being synthesized, before
        // `play()`. Those are the first-sound stage, not the reply's quiet
        // (the Mac harness, runs 7 and 8), so the ear is told whether the
        // player had started. `weak`: the node holds this block until detach.
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak node] buffer, _ in
            ear.hear(buffer, playing: (node as? AVAudioPlayerNode)?.isPlaying ?? true)
        }
        ears.withLock { $0[ObjectIdentifier(node)] = ear }
    }

    public func detachFromPlayback(_ node: AVAudioNode) {
        let ear = ears.withLock { $0.removeValue(forKey: ObjectIdentifier(node)) }
        if ear != nil { node.removeTap(onBus: 0) }
        host.detachFromPlayback(node)
        if let ear { heard(ear.pauses) }
    }

    public var outputSampleRate: Double { host.outputSampleRate }
}

/// One reply's ear: its meter, touched only by its tap (see `ListeningHost`'s
/// proof, points 2 and 3), and what the tap publishes after every buffer.
final class ReplyEar: @unchecked Sendable {
    private var meter: SilenceMeter
    private let sampleRate: Double
    private let gaps = Atomic<Int>(0)
    private let longestFrames = Atomic<Int>(0)
    /// The quiet before the first word, in frames; −1 until there is one.
    private let leadingFrames = Atomic<Int>(-1)

    init(meter: SilenceMeter) {
        self.meter = meter
        sampleRate = meter.config.sampleRate
    }

    /// The tap's body: the buffer read in place, the two facts published.
    /// - Parameter playing: whether the node had started playing when it
    ///   rendered `buffer`; a buffer from before is not the reply's at all.
    func hear(_ buffer: AVAudioPCMBuffer, playing: Bool = true) {
        guard playing else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        meter.feed(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        gaps.store(meter.gaps, ordering: .releasing)
        longestFrames.store(meter.longestFrames, ordering: .releasing)
        if let leading = meter.leadingFrames { leadingFrames.store(leading, ordering: .releasing) }
    }

    var pauses: ReplyPauses {
        let frames = longestFrames.load(ordering: .acquiring)
        let leading = leadingFrames.load(ordering: .acquiring)
        return ReplyPauses(gaps: gaps.load(ordering: .acquiring),
                           longest: .nanoseconds(Int64((Double(frames) / sampleRate * 1e9).rounded())),
                           leadingQuiet: leading < 0 ? nil
                               : .nanoseconds(Int64((Double(leading) / sampleRate * 1e9).rounded())))
    }
}
