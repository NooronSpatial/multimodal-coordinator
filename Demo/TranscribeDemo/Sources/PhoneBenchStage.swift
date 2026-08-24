import Foundation
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTTS
import TTSKit

/// The device half of the sweep (D-067 F-1 = A).
///
/// `BenchSweep` holds the invariants — the order, the per-row reset, the
/// restore-whatever-happens — and they are tested on a Mac with no models.
/// This is everything those invariants need from an actual phone, and
/// nothing else. It is deliberately thin: if logic starts collecting here,
/// it belongs on the other side of the seam where it can be tested.
@MainActor
struct PhoneBenchStage: BenchStage {
    let model: TranscribeModel

    /// ONE long single-chunk sentence, the same one `voice-levers` uses, so
    /// a phone table and a Mac table are measuring the same work. Long, so
    /// the fixed prefill is amortised and steady decode is what moves;
    /// single-chunk, so the sequential/batch branch is not part of it.
    static let sentence = "The audio travels through a ring buffer into a "
        + "pump that cuts it into small chunks."

    // MARK: settings, taken and given back (AC-151)

    func snapshot() async -> VoiceLevers { model.levers }

    func restore(_ settings: VoiceLevers) async {
        // `restoring:` — this is handing the person their settings back, so
        // the AC-144 recovery must not fire (it would revert to the sweep's
        // last row) and nothing is persisted.
        await model.apply(settings, restoring: true, persisting: false)
    }

    // MARK: the refusal (AC-146)

    func refusalReason() async -> String? {
        // A SWEEP AGAINST A LIVE CONVERSATION measures neither. Every
        // sibling instrument in this app already refuses while listening
        // (the four toolbar probes carry `.disabled(model.isListening)`);
        // the sweep was the one that did not, and it also stops the
        // conversation on its first `apply`.
        if model.isListening {
            return "Stop the conversation first — a sweep reconfigures the "
                + "voice repeatedly, and it would be measuring a pipeline "
                + "that keeps restarting underneath it."
        }
        // 0. THE SIMULATOR, and this one was learned by crashing twice.
        //
        //    The model IS installed here and `modelInstalled()` correctly
        //    says so — the files are real. What is missing is a GPU that
        //    can run them, and TTSKit does not fail politely when its
        //    decode produces nothing. It dies:
        //
        //      Swift/FloatingPointRandom.swift:52: Fatal error:
        //      Can't get random value with an empty range
        //
        //    That is `fatalError` inside a dependency's sampler, so there
        //    is nothing to catch and nothing to report — the app is simply
        //    gone. Exactly the shape of D-061's MLX gate, whose comment
        //    reads: "The metallib IS present in a simulator app bundle, so
        //    a check that only looked for the file would say yes and then
        //    die on the first allocation — which is exactly what the phone
        //    spike did, twice." Same lesson, different framework: present
        //    on disk is not runnable, and only a device settles it.
        #if targetEnvironment(simulator)
        return "The neural voice cannot decode on the Simulator. Its files "
            + "are here, but there is no GPU to run them, and TTSKit dies "
            + "inside its sampler rather than failing. Run the sweep on a "
            + "device."
        #endif

        // 1. THE MEMORY HAZARD. The 4B mind holds 2225 MB of DIRTY memory
        //    (INSTRUMENTS §29) and a sweep repeatedly loading six CoreML
        //    models beside it is the kill recorded three times. Asked of the
        //    picker rather than of MLX: the question is "will this sweep
        //    have to share the device", and a selected mind is resident the
        //    moment a turn happens.
        if model.mind == .local {
            return "The sweep will not run with the local mind selected — it "
                + "holds 2.2 GB, and loading the voice beside it is the kill "
                + "recorded three times. Switch the Mind to Echo in Settings."
        }
        // 2. NO MODEL, NO MEASUREMENT — and this one was learned by
        //    crashing. The first version gated on `voiceState`, which reads
        //    `.modelMissing` rather than `.failed` when the voice is not
        //    installed, so the sweep proceeded to measure a voice that could
        //    not speak and died in the sampler with "Can't get random value
        //    with an empty range". Ask the VOICE whether it has its files,
        //    not the screen what state it is showing.
        guard await model.benchVoice.modelInstalled() else {
            return "The neural voice's model is not on this device. Install "
                + "it from Settings first — there is nothing here to measure."
        }
        return nil
    }

    // MARK: one row

    func prepare(_ configuration: BenchConfiguration) async throws {
        var wanted = model.levers
        wanted.decoder = configuration.decoder == .fused ? .fused : .stepped
        wanted.vocoder = configuration.vocoder == .throughput
            ? .throughputOptimized : .latencyOptimized
        wanted.temperature = configuration.temperature
        // The cushion stays DERIVED across a sweep. Pinning it would measure
        // four decoders through one decoder's cushion, which is the bug that
        // produced §31's wrong stepped numbers.
        wanted.lead = nil

        // Returns only when the new configuration is up — `apply` awaits the
        // retire, the load and the check. No delay, no retry count. Not
        // persisted: a sweep is not the person choosing.
        await model.apply(wanted, persisting: false)

        // ASK WHETHER THE LEVERS SURVIVED, not what the screen says.
        //
        // Two ways the state lies here. `keepTheVoiceUsable` REVERTS a
        // refused configuration and repairs `voiceState` back to `.ready`,
        // so by the time this guard runs a refusal looks like a success —
        // and the row would be attributed to a configuration that never
        // loaded. And `checkVoice()` opens with `guard mouth == .neural`,
        // so on the stored default mouth it returns `.ready` without
        // loading anything at all.
        //
        // The levers are the honest witness: the revert is what puts them
        // back, so if they still hold what was asked for, the apply stood.
        guard model.levers == wanted else {
            throw BenchRefusal.configurationRefused(
                configuration.name,
                model.leverRefusal ?? "the configuration was reverted")
        }
        guard case .ready = model.voiceState else {
            throw BenchRefusal.configurationRefused(
                configuration.name, "\(model.voiceState)")
        }
    }

    func resetCounters() async { model.resetBenchCounters() }

    func conditions() async -> BenchConditions {
        let thermal = switch model.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
        return BenchConditions(thermal: thermal,
                               freeMegabytes: model.freeMegabytesNow())
    }

    func measure() async throws -> BenchTiming {
        defer { model.noteSweepMeasurement() }
        return try await UtteranceStopwatch.time(model.benchVoice,
                                                 saying: Self.sentence,
                                                 clock: ContinuousClock())
    }
}

enum BenchRefusal: Error, CustomStringConvertible {
    case configurationRefused(String, String)

    var description: String {
        switch self {
        case .configurationRefused(let name, let why):
            "\(name) was refused — \(why)"
        }
    }
}
