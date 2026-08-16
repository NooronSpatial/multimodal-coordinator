import AVFAudio
import Synchronization

/// WHERE A REPLY IS ALLOWED TO RENDER (SPEC AC-108, D-048).
///
/// D-043 measured the fact that makes this necessary: iOS voice
/// processing removes only what its OWN audio unit renders. That unit
/// belongs to the capture engine, so a reply the echo canceller can see
/// has to be rendered on that engine — not on one of the mouth's own.
///
/// **This seam does not hand the engine out**, and that is its entire
/// design. An `AVAudioEngine` handed to a caller carries its whole
/// lifecycle with it: the caller can attach before it runs, keep nodes
/// after it stops, or stop it outright. Instead a host takes two verbs
/// and keeps the ORDER — the division `AudioSessionConfiguring` already
/// uses in this library: **the library owns the sequence, the caller
/// owns the values.**
///
/// The order it keeps is not a preference. An engine started with an
/// empty graph never pulls, so a node attached afterwards renders
/// nothing, its buffers are never played, `.dataPlayedBack` completions
/// never fire, and the reply never reports `finished`. That is a hang,
/// and it cost twenty minutes of a measurement run to learn
/// (INSTRUMENTS §14). Inside a host, "attach, connect, THEN start" is
/// written once and cannot be got wrong by a caller.
///
/// **`Sendable` is load-bearing here, not decoration.** A host is
/// touched from at least two places that never meet: whoever owns the
/// capture (the app, usually on the main actor) and the mouth's own
/// serial queue, which attaches and detaches a node per reply. The
/// compiler refused the first version of this seam for exactly that
/// reason, and it was right — the node list was unguarded.
public protocol PlaybackHost: AnyObject, Sendable {
    /// Attaches `node` to the host's graph, connects it to the output at
    /// `format`, and leaves the host rendering.
    ///
    /// - Throws: `PlaybackHostFailure.notRendering` when the host cannot
    ///   render right now — a stopped microphone, for instance. Failing
    ///   loudly is the point: a silent attach yields a node on a graph
    ///   nobody pulls, and the caller waits forever for audio that will
    ///   never play.
    func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws

    /// Gives the node back. Safe to call with a node that was never
    /// attached, and safe to call twice: a mouth tears itself down on
    /// cancel, on failure and on finish, and those paths overlap.
    func detachFromPlayback(_ node: AVAudioNode)

    /// The rate the host's output actually runs at, READ BACK from the
    /// graph rather than assumed.
    ///
    /// This exists because of a field report: on iPhone the neural voice
    /// was described as "speaking in weird way like someone drunk". A
    /// 24 kHz voice played as if it were 16 kHz sounds exactly like
    /// that — slow, low, slurred — and an iOS session in `.voiceChat`
    /// mode picks its own rate. Whether the graph resampled correctly is
    /// therefore a QUESTION, and a question deserves a number on screen
    /// rather than an assumption in a comment.
    var outputSampleRate: Double { get }
}

/// A node carried under a lock.
///
/// `AVAudioNode` is not `Sendable`, and `Mutex` rightly refuses to let
/// one into guarded state without a promise. This box IS the promise,
/// and it is deliberately narrow: the node inside is touched only while
/// the owning host holds its lock, and the box exists for no other
/// reason. Anything wider would be `@unchecked Sendable` used as a way
/// of not thinking, which this repo does not do.
final class HostedNode: @unchecked Sendable {
    let node: AVAudioNode
    init(_ node: AVAudioNode) { self.node = node }
}

public enum PlaybackHostFailure: Error, Sendable, Equatable {
    /// The host is not in a state where anything can be heard. For the
    /// microphone that means capture is not running — and since the
    /// whole reason to render there is the echo canceller inside its
    /// audio unit, rendering into a stopped one would buy nothing even
    /// if it worked.
    case notRendering
}

/// THE CAPTURE ENGINE, AS A PLACE TO SPEAK FROM (AC-108, D-048).
///
/// Vended by `MicrophoneSource` rather than being it. The split is what
/// makes the seam `Sendable` without claiming that a whole audio-capture
/// object is: this handle holds nothing but the engine and a lock, and
/// the microphone tells it when capture starts and stops.
///
/// `@unchecked Sendable`, with the proof written out because that is the
/// house rule:
/// 1. Every mutable byte lives inside the one `Mutex`.
/// 2. Nothing suspends while it is held — there is no `await` in this
///    file — so the lock cannot be carried across a suspension point.
/// 3. No continuation is resumed under it.
/// 4. Graph calls (`attach`/`connect`/`detach`) are made INSIDE the lock
///    deliberately: it means this type never issues two graph mutations
///    concurrently, whatever its callers do. They are short, non-blocking
///    calls, which is the only reason holding a lock across them is
///    acceptable — and if that ever stops being true, this comment is
///    where to start.
public final class MicrophonePlaybackHost: PlaybackHost, @unchecked Sendable {
    private struct Guarded {
        var capturing = false
        var hosted: [HostedNode] = []
        var outputRate: Double = 0
    }
    private let state = Mutex(Guarded())
    /// Borrowed, never owned: `MicrophoneSource` starts and stops it.
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// How many replies currently hold a node here. The leak this seam
    /// prevents is otherwise invisible: before AC-108 the mouth attached
    /// a player per reply and detached none (INSTRUMENTS §14).
    public var hostedCount: Int { state.withLock { $0.hosted.count } }

    public var isRendering: Bool { state.withLock { $0.capturing } }

    /// CACHED, NOT ASKED. Reading `engine.mainMixerNode` is not a free
    /// query: the mixer is created lazily and creating it CONNECTS it to
    /// the output node. On this host the engine is already running and
    /// doing echo cancellation, so a getter that looks pure would be
    /// quietly bringing the output half of a live voice-processing unit
    /// up at a moment of its own choosing — and any A/B run with that
    /// getter in it is no longer measuring the graph that produced the
    /// field report. So the rate is recorded during `attachForPlayback`,
    /// where the mixer is legitimately touched anyway, and `0` honestly
    /// means "nothing has rendered here yet".
    public var outputSampleRate: Double { state.withLock { $0.outputRate } }

    // MARK: - told by the microphone

    func captureStarted() {
        state.withLock { $0.capturing = true }
    }

    /// Capture has stopped, so every reply's node goes with it. A node
    /// left attached to a stopped engine is the leak in slow motion.
    func captureStopped() {
        state.withLock { s in
            s.capturing = false
            for hosted in s.hosted { detachIfStillOurs(hosted.node) }
            s.hosted = []
        }
    }

    /// `detach` ABORTS THE PROCESS, and it took two attempts to guard
    /// it properly — the second one is the lesson.
    ///
    /// The first guard asked `attachedNodes.contains(node)`, which is a
    /// different question from the one the assertion asks. The phone
    /// crashed again, inside this very function, because **attached is
    /// not the same as IN A CHAIN**:
    ///
    ///   required condition is false:
    ///   graphNode->IsNodeState(kAUGraphNodeState_InInputChain) ||
    ///   graphNode->IsNodeState(kAUGraphNodeState_InOutputChain)
    ///
    /// A node can be attached and wired to nothing — after a graph
    /// reconfiguration drops its connections, or when the connect never
    /// produced a valid chain in the first place, which is exactly what
    /// the `vpio render err: -1` runs were. So the connection is what
    /// gets checked now, because the connection is what the assertion
    /// is about.
    ///
    /// **The honest cost:** a node that is attached but unwired is left
    /// attached rather than detached — leaked, until the engine itself
    /// goes. That is a bounded leak traded against an unbounded crash,
    /// and the trade is deliberate. Removing the trade means the host
    /// owning ONE reusable player instead of a node per reply, which is
    /// a change to this seam's shape and therefore Ryad's to rule.
    private func detachIfStillOurs(_ node: AVAudioNode) {
        guard engine.attachedNodes.contains(node) else { return }
        guard !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty
        else { return }
        engine.detach(node)
    }

    // MARK: - the seam

    public func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws {
        try state.withLock { s in
            // There is no useful "attach anyway". The engine would not be
            // pulling, so nothing would be heard and the caller would
            // wait forever for a completion — and the echo canceller
            // that is the entire reason to render here lives in an audio
            // unit that is not running either.
            guard s.capturing else { throw PlaybackHostFailure.notRendering }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            s.outputRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
            s.hosted.append(HostedNode(node))
        }
    }

    public func detachFromPlayback(_ node: AVAudioNode) {
        state.withLock { s in
            guard s.hosted.contains(where: { $0.node === node }) else { return }
            s.hosted.removeAll { $0.node === node }
            detachIfStillOurs(node)
        }
    }
}

/// THE SEAM'S SECOND IMPLEMENTATION, which is what makes it a seam
/// rather than an interface drawn around one method (the D-017 rule,
/// applied for the fourth time in this library).
///
/// It owns a plain engine and exists for every machine with no capture
/// in the picture: the bake-off tool, a Mac demo, a test. Nothing here
/// knows about echo cancellation, because nothing here has any.
///
/// Same `@unchecked Sendable` proof as above, for the same four reasons.
public final class AudioEnginePlaybackHost: PlaybackHost, @unchecked Sendable {
    private let state = Mutex<[HostedNode]>([])
    private let engine: AVAudioEngine

    /// `nil` builds its own. Handing one in is for a caller that already
    /// has an engine and wants the reply on it — the bake-off does that,
    /// because it also taps the mixer to capture what was said.
    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public var isRendering: Bool { engine.isRunning }
    public var hostedCount: Int { state.withLock { $0.count } }

    public var outputSampleRate: Double {
        engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
    }

    public func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws {
        try state.withLock { hosted in
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            hosted.append(HostedNode(node))
            // START LAST. Touching `mainMixerNode` above has already
            // created it and connected it to the output, and the node is
            // now a live source — so the graph has something to pull
            // when it starts. Starting first is the mistake that hangs a
            // caller, and it is the one this seam exists to make
            // unrepeatable.
            guard !engine.isRunning else { return }
            engine.prepare()
            do { try engine.start() }
            catch {
                engine.detach(node)
                hosted.removeAll { $0.node === node }
                throw PlaybackHostFailure.notRendering
            }
        }
    }

    public func detachFromPlayback(_ node: AVAudioNode) {
        state.withLock { hosted in
            guard hosted.contains(where: { $0.node === node }) else { return }
            hosted.removeAll { $0.node === node }
            // Same two guards, same reason as the capture host: the
            // engine must still hold it AND it must still be wired to
            // something, because that second one is what detach asserts.
            guard engine.attachedNodes.contains(node),
                  !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty
            else { return }
            engine.detach(node)
        }
    }

    /// Stops rendering and releases every hosted node. Nodes go BEFORE
    /// the engine stops — after it, they are no longer in any chain and
    /// detaching them asserts.
    public func stopRendering() {
        state.withLock { hosted in
            for held in hosted
            where engine.attachedNodes.contains(held.node)
                && !engine.outputConnectionPoints(for: held.node, outputBus: 0).isEmpty {
                engine.detach(held.node)
            }
            hosted.removeAll()
            engine.stop()
        }
    }
}
