import Foundation
import MultiModalKit
import Synchronization

// MARK: - the internal seam (the D-053 rule, one seam over)

/// What one reply's TOKEN STREAM looks like — ours, so a test can make it
/// misbehave on command.
///
/// Internal on purpose, the same rule `ReplySnapshotStreaming` follows:
/// its second implementation is a test double, and public surface is
/// earned by a second REAL one.
///
/// Note what is NOT here. The Apple seam yields CUMULATIVE snapshots,
/// because that is the shape Apple's API has, and needs `SnapshotDiffer`
/// to turn them back into deltas. MLX emits tokens. This seam yields
/// deltas directly, which is the small piece of evidence SPEC §84 claims:
/// the second citizen fits the public seam more directly than the first.
///
/// The text arriving here is ALREADY gated — reasoning never becomes a
/// string, because only ids the `ThinkGate` admitted are ever detokenised
/// (§86 layer 2).
protocol ReplyTokenStreaming: Sendable {
    /// Why a generation cannot START, or nil. Asked at the door, every
    /// time: weights can finish downloading between two turns, so a
    /// cached refusal would freeze a temporary state into a verdict.
    var unavailable: (any Error)? { get }
    /// Opens one generation and returns its tokens, in birth order.
    func tokens(for prompt: String) -> AsyncThrowingStream<String, any Error>
}

// MARK: - the generator

/// The mind seam's SECOND real citizen (SPEC 4h, D-062 F-1 = A).
///
/// One transcript in, a token stream out — the same two requirements the
/// Apple mind implements, and the same five conformance promises.
public struct MLXReplyGenerator: ReplyGenerating {
    let source: any ReplyTokenStreaming

    /// The seam a test reaches through (`@testable`), never a caller.
    init(source: any ReplyTokenStreaming) {
        self.source = source
    }

    public func openReply(to transcript: String) async throws -> any ReplyRun {
        // At the door, every time — never cached.
        if let unavailable = source.unavailable { throw unavailable }
        return MLXReplyRun(source: source, prompt: transcript)
    }
}

/// Why this mind cannot answer right now.
///
/// Separate sentences on purpose, the AC-110 lesson: a person whose
/// device cannot host the runtime needs different words from one whose
/// weights are simply not on disk yet.
public enum MLXUnavailable: Error, Sendable, Equatable, CustomStringConvertible {
    /// The weights are not installed. Recoverable — and note that
    /// "installed" means OFFLINE-CAPABLE (D-062 F-4 = A, Whisper's rule).
    case weightsNotInstalled(String)
    /// The platform cannot host MLX at all. D-061/INSTRUMENTS §24
    /// STAGE 3: the iOS Simulator asks Metal for a Shared-storage heap
    /// and the driver requires Private. No flag changes it.
    case platformCannotRunMLX
    case unknown(String)

    public var description: String {
        switch self {
        case .weightsNotInstalled(let name):
            "the local model \(name) is not installed yet."
        case .platformCannotRunMLX:
            "this platform cannot run MLX — the simulator's Metal driver "
            + "refuses the shared-memory heap MLX requires."
        case .unknown(let why):
            "the local model is unavailable: \(why)"
        }
    }
}

// MARK: - one reply

/// ONE thought: tokens in, tokens out, exactly one terminal, and a dead
/// run stays dead.
///
/// The shape is `AppleReplyRun`'s deliberately — all state behind one
/// `Mutex`, nothing suspends under it, every terminal path through ONE
/// latch. A second citizen that invented a second shape would be a second
/// set of bugs, and the `retire()` doctrine exists because 4e's review
/// had to force this latch on after a run kept going past its own death.
final class MLXReplyRun: ReplyRun, @unchecked Sendable {
    let updates: AsyncStream<ReplyUpdate>
    private let out: AsyncStream<ReplyUpdate>.Continuation

    private struct Guarded {
        var retired = false
    }
    private let state: Mutex<Guarded>
    /// The owned worker. Cancelling it is the OPTIMISATION; `retired` is
    /// the guarantee — the ticket doctrine, and the reason a defiant
    /// source cannot be heard after a cancel.
    private let work = Mutex<Task<Void, Never>?>(nil)

    init(source: any ReplyTokenStreaming, prompt: String) {
        var handle: AsyncStream<ReplyUpdate>.Continuation!
        self.updates = AsyncStream { handle = $0 }
        self.out = handle
        self.state = Mutex(Guarded())

        let task = Task { [weak self] in
            do {
                for try await token in source.tokens(for: prompt) {
                    guard let self else { return }
                    // Two guards keep a dead run silent, the same pair
                    // `AppleReplyRun` documents: this flag re-read, AND
                    // the stream having been finished by `cancel()` — a
                    // finished AsyncStream drops every later yield. The
                    // finish is the primary guard; the flag is the belt,
                    // kept because the finish lives in another method.
                    let admitted: String? = self.state.withLock { s in
                        // An empty token is not silence to report — the
                        // detokenizer yields "" while a multi-token
                        // character is still incomplete.
                        guard !s.retired, !token.isEmpty else { return nil }
                        return token
                    }
                    guard let admitted else {
                        if self.state.withLock({ $0.retired }) { return }
                        continue
                    }
                    self.out.yield(.token(admitted))
                }
                self?.report(.finished)
            } catch {
                self?.report(.failed("local generation failed: \(error)"))
            }
        }
        work.withLock { $0 = task }
    }

    /// EVERY terminal path ends here, and only the first one acts.
    ///
    /// MEASURED REDUNDANCY, recorded rather than dressed up: mutation
    /// removed this latch and NOT ONE test went red. The reason is
    /// structural — `report` cannot be called twice (the loop either
    /// completes or throws, never both), and in the cancel-then-finish
    /// race `out.finish()` has already run, and a finished AsyncStream
    /// drops every later yield. So the FINISH is the primary guard and
    /// this latch is the belt.
    ///
    /// It stays, for the reason the 4b precedent gives: redundancy is
    /// recorded, not pretended to be load-bearing. `AppleReplyRun` needed
    /// exactly this latch forced onto it by 4e's review after a failed
    /// decode kept running and aborted the process — the structure that
    /// masks it here is not guaranteed to survive the next change.
    private func report(_ terminal: ReplyUpdate) {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            return !was
        }
        guard first else { return }
        out.yield(terminal)
        out.finish()
    }

    /// Ends the stream with NO terminal — the seam's cancel contract.
    /// The flag is raised in the SAME locked step that decides "was I
    /// first", so a token in flight sees it before its next yield.
    func cancel() async {
        let first = state.withLock { s -> Bool in
            let was = s.retired
            s.retired = true
            return !was
        }
        work.withLock { $0 }?.cancel()
        guard first else { return }
        out.finish()
    }
}
