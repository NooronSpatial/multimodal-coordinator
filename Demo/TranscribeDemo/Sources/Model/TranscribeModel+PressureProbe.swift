import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the memory pressure probe (4i) and the one-tap
// cold-compile probe (4n): what a load costs, written to disk as it runs.
extension TranscribeModel {
    /// Where the probe writes. IN DOCUMENTS, and flushed after EVERY
    /// line, because the thing being measured is an app being killed.
    ///
    /// The MLX phone spike already paid for this lesson: two crashes
    /// produced no output at all because the trail lived in a view that
    /// died with the process. An instrument whose evidence dies with the
    /// failure it is measuring is not an instrument.
    private nonisolated var probeLog: URL {
        URL.documentsDirectory.appending(path: "pressure-probe.txt")
    }

    /// Reads back a PREVIOUS run — including one that ended in a kill.
    func loadPreviousProbe() {
        guard let text = try? String(contentsOf: probeLog, encoding: .utf8)
        else { return }
        // MARK: D, so a restored trace can never impersonate a live run on
        // the Bench screen (the 4n review, and the null-run story of §51).
        probe.lines = ["(restored from the previous run — not live)"]
            + text.split(separator: "\n").map(String.init)
    }

    private func probeSay(_ line: String) {
        probe.lines.append(line)
        // Capped, because a 250 ms sampler over a long load writes a lot,
        // and a file that grows without bound is its own bug. The OLDEST
        // lines go, never the newest — the last line before a death is
        // the whole point.
        if probe.lines.count > 4_000 { probe.lines.removeFirst(500) }
        // Append and flush NOW. Not at the end — there may not be an end.
        try? probe.lines.joined(separator: "\n")
            .write(to: probeLog, atomically: true, encoding: .utf8)
    }

    /// UNWIRED, deliberately, after it crashed the app on relaunch.
    ///
    /// Two defects I can see by reading, and one I cannot rule out
    /// without Ryad's crash log:
    ///
    /// 1. **A pressure storm.** The handler wrote a line, and `probeSay`
    ///    rewrites the WHOLE trace file. Under real pressure the source
    ///    fires repeatedly, so the instrument answered memory pressure by
    ///    doing file I/O in a loop — reacting to a fire by pouring fuel.
    /// 2. **A retain cycle.** The event handler captured `source`, which
    ///    holds the handler, so `deinit` could never run and the monitor
    ///    outlived its owner.
    ///
    /// Both are fixed in the type. It stays disconnected until a crash
    /// log says whether it was actually the cause, because re-enabling a
    /// suspect on a hunch is how a second afternoon gets lost (D-054).
    private func watchSystemPressure() {
        guard probe.monitor == nil else { return }
        probe.monitor = MemoryPressureMonitor { [weak self] level in
            Task { @MainActor in
                self?.probeSay("  *** SYSTEM MEMORY PRESSURE: \(level) ***")
            }
        }
    }

    private func sampling<T>(_ label: String,
                             _ work: () async throws -> T) async rethrows -> T {
        // ONE AT A TIME. The first AC-139 trace interleaved two samplers —
        // "+55.5s" beside "+0.0s" — because tapping the probe while the
        // LAUNCH load was still running started a second one into the same
        // file. Two writers, one file, and a trace nobody can read. Same
        // class as the double model load, one layer up.
        guard !probe.samplerBusy else {
            probeSay("  (\(label): a load is already being sampled — "
                + "not starting a second, and not touching that trace)")
            // The count belongs to the OTHER sampler; poison ours so the
            // null-run verdict stays silent instead of judging this phase
            // by a foreign number (the 4n review).
            probe.lastPhaseSamples = -1
            return try await work()
        }
        probe.samplerBusy = true
        // NOT watching system pressure here any more — see the comment on
        // `watchSystemPressure`. It is wired to nothing until it is safe.
        defer { probe.samplerBusy = false }
        probe.lastPhaseSamples = 0
        let sampler = Task { [weak self] in
            for tick in 0..<2_400 {          // 10 minutes, capped
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    self.probe.lastPhaseSamples += 1
                    self.probeSay(String(format: "    %@ +%.1fs  %@",
                                         label, Double(tick) * 0.25,
                                         self.headroomNow()))
                }
            }
        }
        defer { sampler.cancel() }
        return try await work()
    }

    /// Both numbers, because they measure different things and only one
    /// of them moved.
    ///
    /// AC-139's first trace showed headroom drifting 2322 -> 2309 MB over
    /// sixty seconds of loading six CoreML models — thirteen megabytes —
    /// while the app had previously been KILLED doing exactly this.
    /// `limit_bytes_remaining` tracks the DIRTY limit, and CoreML's
    /// weights are mapped, so they are clean and invisible to it.
    /// `phys_footprint` counts them, which is why a Mac saw 1112 MB where
    /// the phone's headroom saw 111.
    ///
    /// An instrument that cannot see the thing that kills is the shape
    /// this project keeps hunting, so both are recorded and the reader is
    /// told which is which.
    private func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private func headroomNow() -> String {
        let free: String = switch MemoryHeadroomReader.read() {
        case .bytes(let bytes): "\(bytes / 1_048_576) MB free (dirty)"
        case .exhausted: "NONE — at or over the limit"
        case .unavailable(let why): "unavailable (\(why))"
        }
        return "\(free) · footprint \(footprintMB()) MB"
    }

    /// THE THREE MEASUREMENTS, in one tap, in order, each one written to
    /// disk before the next begins.
    ///
    /// It deliberately loads the pair the demo otherwise REFUSES
    /// (memoryConflict), because refusing is what makes the pair
    /// unmeasurable — and 4i exists to find out whether the refusal is
    /// even true on this device.
    func runPressureProbe(fresh: Bool = true) async {
        // `fresh: false` is the cold probe's: it has ALREADY written its
        // header and the cache-clear report, and the first field run of
        // the ❄ came back with that report ERASED — this reset destroyed
        // the one line that says whether the clear found anything, which
        // is the line the whole control exists to produce.
        if fresh { probe.lines = [] }
        probeSay("# pressure probe — \(LocalMind.repoID)")

        // HONEST BASELINE. The first version called this "baseline" while
        // launch had ALREADY prewarmed the mind, so it measured the wrong
        // thing and said the right word. Say what is resident.
        let mindAlready = MLXRuntime.isAvailable
            && MLXRuntime.activeMemoryBytes > 100 * 1_048_576
        probeSay("mind already resident: \(mindAlready) "
            + "(MLX active \(MLXRuntime.activeMemoryBytes / 1_048_576) MB)")
        probeSay("start:               \(headroomNow())")

        // THE VOICE FIRST, and the order is the point. The previous run
        // loaded the risky thing last and died before learning the cheap
        // fact — what the neural voice actually costs ON THIS PHONE. My
        // 1112 MB is a Mac's figure, and CoreML often MAPS weights, which
        // count differently against a dirty limit than MLX's do.
        probeSay("voice installed on disk: \(await neuralVoice.modelInstalled())")
        probeSay("loading the neural voice FIRST… (if this is the last line,")
        probeSay("  it died here, and the voice alone is the problem)")
        var voicePhaseWasNull = false
        do {
            try await sampling("voice") { try await neuralVoice.ensureModel() }
            if let warning = PressurePhaseVerdict.nullRunLine(
                samples: probe.lastPhaseSamples, label: "voice") {
                probeSay(warning)
                voicePhaseWasNull = true
            }
            probeSay("+ voice loaded:      \(headroomNow())")
        } catch {
            probeSay("  voice FAILED:      \(error)")
        }

        probeSay("loading the mind… (if this is the last line, the PAIR is")
        probeSay("  the problem, and we now know the voice's real cost)")
        do {
            _ = try await sampling("mind") { try await localModel.ensureModel() }
            probeSay("+ mind loaded:       \(headroomNow())")
            probeSay("  MLX active:        \(MLXRuntime.activeMemoryBytes / 1_048_576) MB")
        } catch {
            probeSay("  mind FAILED:       \(error)")
        }

        probeSay("BOTH RESIDENT:       \(headroomNow())")
        // "survived" is only a verdict when something was at stake. A null
        // voice phase proved nothing about a load, and saying "yes" around
        // it is the §30 instrument fault in one word.
        probeSay(voicePhaseWasNull
            ? "survived: yes — but the voice phase was NULL; no load was measured"
            : "survived: yes")
    }

    /// THE ONE-TAP COLD PROBE (4n, D-074 F-1 = B). Clears the compiled-plan
    /// cache, retires the in-process voice so its warm pipeline cannot
    /// answer, builds a fresh one, and runs the pressure probe against it.
    /// The four-step manual dance (Apple mouth, kill, relaunch, tap) that
    /// produced a null run on its first field attempt becomes a procedure
    /// that cannot be done wrong.
    func runColdProbe() async {
        guard !isListening else {
            probe.lines = ["cold probe refused: the conversation is running — stop Listen first"]
            return
        }
        // THE SAME FUNNEL AS settleLevers (the 4n review). The first
        // version swapped the voice OUTSIDE it, so a lever tapped during
        // the probe raced a second full compile beside this one — the
        // overlapping-load class that produced the recorded kills.
        while settling {
            await withCheckedContinuation { settleWaiters.append($0) }
        }
        settling = true
        defer {
            settling = false
            let waking = settleWaiters
            settleWaiters = []
            for waiter in waking { waiter.resume() }
        }
        probe.lines = []
        probeSay("# cold-compile probe — D-074 = B")
        // Off the MainActor: the byte walk and the deletes are file I/O,
        // and the screen should not stutter for them. Caches AND tmp —
        // the ❄'s first surviving report proved Caches empty of the
        // compile cache, so the hunt widened (D-075).
        let report = await Task.detached {
            CompiledPlanCache(directories: [
                URL.cachesDirectory, FileManager.default.temporaryDirectory
            ]).clear()
        }.value
        probeSay(report.summary)
        probeSay("retiring the in-process voice — its warm pipeline must not answer…")
        // The screen says CHECKING for the whole probe, so Listen refuses
        // honestly instead of grabbing a half-built voice mid-compile.
        voiceState = .checking
        let retiring = neuralVoice
        await retiring.retire()
        // A FRESH voice from the same levers: nothing loaded, nothing warm.
        // The next Listen re-registers rendering and margins on whatever
        // this property holds, so no wiring is lost.
        neuralVoice = levers.makeVoice()
        await runPressureProbe(fresh: false)
        // Leave the screen's voice state honest: the probe just loaded the
        // fresh pipeline (or died trying), and checkVoice() reads reality.
        await checkVoice()
    }
}
