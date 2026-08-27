// The two doubles that `NeuralVoiceFailurePathTests` drives: the scripted
// decoder and the spy playback host. The suite's own file holds the facts
// they are used to pin, and the note on why every scripted step is empty.

import AVFAudio
import MultiModalKit
import Synchronization

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

// MARK: - the two doubles

/// What a decode did, or refused to do. Driven by the test.
enum DecodeScript: Sendable {
    /// Throws before producing a single step — the failure the real
    /// model could never be asked to perform.
    case throwsAtOnce(String)
    /// Steps until the run's callback returns `false`, then returns
    /// normally. The cancel case.
    case stepsUntilStopped
    /// Steps until the callback returns `false`, then throws. The
    /// "a decode that fails after a cancel" case.
    case stepsUntilStoppedThenThrows(String)
    /// A fixed number of steps, then returns normally.
    case steps(Int)
    /// One step per entry, each producing that many SAMPLES — so a test
    /// can state exactly how much audio each step made (4o, AC-174).
    /// `.steps(n)` produces empty steps, which is the right shape for the
    /// failure paths and the wrong one for measuring audio.
    case stepsProducing([Int])
}

struct DecodeFailure: Error, CustomStringConvertible {
    let description: String
}

/// A decoder the TEST drives (AC-109, D-053 F-6).
///
/// It imports nothing from TTSKit, which is the whole case for ruling
/// F-6 = B: had the seam been drawn in the vendor's types, this double
/// would have to build real `GenerationOptions` to fake a failure.
///
/// `@unchecked Sendable` with the house proof: all mutable state is
/// behind the one `Mutex`, nothing suspends while it is held, and no
/// continuation is resumed under it.
final class ScriptedDecoder: TTSDecoding, @unchecked Sendable {
    let sampleRate: Int

    private struct Guarded {
        var script: [DecodeScript]
        var decodedTexts: [String] = []
        var stepsTaken = 0
        var wasStopped = false
        var threw = false
        var capExhausted = false
    }
    private let state: Mutex<Guarded>

    /// A spin cap, so a test that would otherwise wait for a stop that
    /// never comes dies as a clean assertion instead of hanging until
    /// the suite's time limit. Fact-gated AND fail-fast, the house rule.
    private let stepCap: Int

    init(_ script: [DecodeScript], sampleRate: Int = 24_000, stepCap: Int = 100_000) {
        self.state = Mutex(Guarded(script: script))
        self.sampleRate = sampleRate
        self.stepCap = stepCap
    }

    /// Every text this decoder was actually ASKED to decode. The
    /// central assertion of this suite reads exactly one entry here.
    var decodedTexts: [String] { state.withLock { $0.decodedTexts } }
    var callCount: Int { state.withLock { $0.decodedTexts.count } }
    /// True once the run's own callback answered `false` — the decode's
    /// cancellation channel, observed from the decoder's side.
    var wasStopped: Bool { state.withLock { $0.wasStopped } }
    var threw: Bool { state.withLock { $0.threw } }
    var capExhausted: Bool { state.withLock { $0.capExhausted } }
    var stepsTaken: Int { state.withLock { $0.stepsTaken } }

    func decode(_ text: String,
                temperature: Float?,
                onStep: @escaping @Sendable ([Float]) -> Bool) async throws {
        let plan = state.withLock { guarded -> DecodeScript in
            let index = guarded.decodedTexts.count
            guarded.decodedTexts.append(text)
            // Past the end of the script a decode simply succeeds — so
            // a test that asserts "this was never decoded" fails
            // LOUDLY if the run decodes it, rather than being rescued
            // by a double that throws on everything.
            return index < guarded.script.count ? guarded.script[index] : .steps(1)
        }

        switch plan {
        case .throwsAtOnce(let why):
            state.withLock { $0.threw = true }
            throw DecodeFailure(description: why)

        case .steps(let count):
            for _ in 0..<count where !step(onStep) { return }

        case .stepsProducing(let sampleCounts):
            for count in sampleCounts {
                let keep = onStep([Float](repeating: 0, count: count))
                state.withLock {
                    $0.stepsTaken += 1
                    if !keep { $0.wasStopped = true }
                }
                if !keep { return }
            }

        case .stepsUntilStopped:
            await stepUntilStopped(onStep)

        case .stepsUntilStoppedThenThrows(let why):
            await stepUntilStopped(onStep)
            state.withLock { $0.threw = true }
            throw DecodeFailure(description: why)
        }
    }

    /// One step. ALWAYS EMPTY — see the suite's note and D-054.
    private func step(_ onStep: @escaping @Sendable ([Float]) -> Bool) -> Bool {
        let keep = onStep([])
        state.withLock {
            $0.stepsTaken += 1
            if !keep { $0.wasStopped = true }
        }
        return keep
    }

    private func stepUntilStopped(_ onStep: @escaping @Sendable ([Float]) -> Bool) async {
        for _ in 0..<stepCap {
            guard step(onStep) else { return }
            // Yields rather than sleeps: the canceller is another task
            // on the same pool, and this is what lets it in without a
            // timing guess anywhere.
            await Task.yield()
        }
        state.withLock { $0.capExhausted = true }
    }
}

/// A host that records and starts NOTHING.
///
/// The real `AudioEnginePlaybackHost` would start an engine and want an
/// output device; this one exists so the failure path is testable on a
/// headless runner. It is safe precisely because of what the probe
/// measured — the run's failure and cancel paths only `stop()`,
/// `reset()` and detach.
final class SpyPlaybackHost: PlaybackHost, @unchecked Sendable {
    private struct Guarded {
        var attachCount = 0
        var detachCount = 0
        var live: Set<ObjectIdentifier> = []
        var formatRates: [Double] = []
    }
    private let state = Mutex(Guarded())

    /// A plausible graph rate, deliberately DIFFERENT from the
    /// decoder's 24 kHz — nothing here may quietly assume they match.
    let outputSampleRate: Double = 48_000

    /// Refuses to host anything, like a stopped microphone.
    ///
    /// The real hosts THROW `PlaybackHostFailure.notRendering` rather
    /// than attaching to a graph nobody pulls, because a silent attach
    /// leaves the caller waiting forever for audio that will never
    /// play. A spy that could only succeed would have made every test
    /// here unrepresentative of that path.
    let refusing: Bool

    init(refusing: Bool = false) { self.refusing = refusing }

    var attachCount: Int { state.withLock { $0.attachCount } }
    var detachCount: Int { state.withLock { $0.detachCount } }
    var liveNodeCount: Int { state.withLock { $0.live.count } }
    /// The sample rate the run asked to render at — the run builds this
    /// from its decoder, and a mismatch is the "drunk voice" fault.
    var formatRates: [Double] { state.withLock { $0.formatRates } }

    func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws {
        if refusing { throw PlaybackHostFailure.notRendering }
        state.withLock {
            $0.attachCount += 1
            $0.live.insert(ObjectIdentifier(node))
            $0.formatRates.append(format.sampleRate)
        }
    }

    func detachFromPlayback(_ node: AVAudioNode) {
        state.withLock {
            guard $0.live.remove(ObjectIdentifier(node)) != nil else { return }
            $0.detachCount += 1
        }
    }
}
#endif
