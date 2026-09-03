import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the four voice levers and which mouth speaks:
// applying a lever set, settling it, recovering from a refusal, and
// the mouth the coordinator is handed.
extension TranscribeModel {
    /// APPLY AND WAIT — the shape AC-147 needs (SPEC §104, H-3).
    ///
    /// `restart()` gives no signal that a new configuration is up: it defers
    /// teardown into a detached Task and sets `isListening` false while the
    /// microphone is still being released. A sweep driven by that has
    /// nothing to wait ON, and the only alternatives are a delay or a retry
    /// count — both of which AC-147 forbids, and both of which are how every
    /// timing bug in this project started.
    ///
    /// So the work is a function that RETURNS when it is done, and the
    /// picker's `didSet` becomes the odd one out: it cannot await, so it
    /// spawns a task that calls the same function. One code path, two
    /// callers, and only one of them has to guess about anything.
    /// - Parameters:
    ///   - restoring: the bench giving the person's settings BACK, not a
    ///     lever change. Two behaviours differ: the AC-144 recovery must not
    ///     run (there is nothing better to fall back to — `previous` is a
    ///     bench row, and reverting to it would leave the SWEEP's last
    ///     configuration as the person's), and nothing is persisted.
    ///   - persisting: whether this configuration becomes the person's
    ///     stored choice. False for every bench-driven change: a sweep used
    ///     to write all four keys on every row, so a sweep that died left
    ///     its own last row as the person's settings.
    func apply(_ wanted: VoiceLevers,
               restoring: Bool = false,
               persisting: Bool = true) async {
        guard wanted != levers else { return }
        let previous = levers
        awaitedElsewhere = true
        levers = wanted
        awaitedElsewhere = false
        await settleLevers(from: previous,
                           restoring: restoring,
                           persisting: persisting)
    }

    func settleLevers(from previous: VoiceLevers,
                      restoring: Bool = false,
                      persisting: Bool = true) async {
        // SERIALIZED (the review). Two lever changes in quick succession —
        // a picker tapped twice, or a picker tapped during a sweep — each
        // spawned their own settleLevers, and two full 1.1 GB loads
        // overlapped. Whoever is second waits for the first to finish
        // rather than racing it.
        while settling {
            await withCheckedContinuation { settleWaiters.append($0) }
        }
        settling = true
        defer {
            settling = false
            // ALL of them, not one — the stranded-waiter lesson from the
            // same review, and the same reason: a woken waiter here can
            // return without doing any work.
            let waking = settleWaiters
            settleWaiters = []
            for waiter in waking { waiter.resume() }
        }

        // THE CONVERSATION STOPS FIRST (D-070 F-2 = C, the app half).
        //
        // This used to retire the old voice, load the new one for tens of
        // seconds, and only THEN restart. For that whole window the live
        // TurnCoordinator still held the retired voice in a `let` — and a
        // turn firing in it would build a second pipeline beside the one
        // loading. The library now refuses that (the voice is terminal),
        // but refusing mid-turn is a dead reply; not creating the window is
        // better than surviving it.
        //
        // The cost, named: changing a lever mid-conversation visibly stops
        // the conversation until the new voice is ready. That was always
        // what happened, minus the pretence that the old one still worked.
        let wasListening = isListening
        if wasListening { await stopAndWait() }

        let retiring = neuralVoice
        neuralVoice = levers.makeSpokenVoice()
        voiceState = .checking
        await retiring.retire()
        await checkVoice()
        await keepTheVoiceUsable(after: previous, recovering: !restoring)
        // PERSIST LAST, and only what a person chose. This used to be the
        // first line — persist-before-verify — so a configuration that
        // failed to load was still written to disk and came back at the
        // next launch, and every sweep row overwrote the person's settings
        // on its way past.
        if persisting, !restoring { Self.store(levers) }
        if wasListening { start() }
    }

    /// `stop()` with a signal, which `stop()` itself does not give: its
    /// teardown is deferred into a detached Task, and `isListening` goes
    /// false while the microphone is still being released (SPEC §104, H-3).
    /// `restart()` already knew this and waited on the dying pipeline —
    /// this is that wait, named and reusable.
    private func stopAndWait() async {
        let dying = pipeline
        stop()
        _ = await dying?.value
    }

    /// AC-144 — A REFUSAL MUST NOT COST THE VOICE THAT WORKED.
    ///
    /// `.fused` is offered on this phone on purpose (D-066 F-2), and on iOS
    /// 18+ it does not load:
    ///
    ///     modelLoadingFailed("MultiCodeDecoder: failed to load
    ///     MultiCodeDecoder.mlmodelc (function 'fused') … .functionName
    ///     must be nil unless the model type is ML Program.")
    ///
    /// `checkVoice()` already puts that text on screen. What it cannot do is
    /// give back the voice that was working, because by then the old one has
    /// been retired — and retiring first is not negotiable: loading the new
    /// pipeline beside the old one is two resident pipelines, which is the
    /// kill this project has recorded three times.
    ///
    /// So the recovery is to go BACK. The failed levers stay visible so the
    /// person can see what they chose and why it was refused, the error text
    /// stays on screen, and the voice that speaks is the one that worked.
    private func keepTheVoiceUsable(after previous: VoiceLevers,
                                    recovering: Bool = true) async {
        // A RESTORE HAS NOWHERE BETTER TO GO. When the bench hands the
        // person's settings back, `previous` is the sweep's last row —
        // reverting to it would install the bench's configuration as the
        // person's, which is precisely what restoring exists to undo.
        guard recovering else { return }
        guard case .failed(let reason) = voiceState else {
            leverRefusal = nil
            return
        }
        guard previous != levers else { return }
        leverRefusal = "\(describe(levers)) was refused — \(reason)"
        neuralVoice = previous.makeSpokenVoice()
        revertingLevers = true
        levers = previous
        revertingLevers = false
        Self.store(previous)      // the configuration that WORKS is the one to keep
        await checkVoice()
    }

    /// What was asked for, in the refusal line. It names the MOUTH first
    /// now: with two vendors, "fused + throughput was refused" describes
    /// a configuration Kokoro does not have and would send a person
    /// looking for a knob that is not there.
    private func describe(_ levers: VoiceLevers) -> String {
        switch levers.voice {
        case .kokoro:
            "Kokoro"
        case .qwen3:
            "Qwen3 " + (levers.decoder == .fused ? "fused" : "stepped")
                + " + " + (levers.vocoder == .throughputOptimized
                           ? "throughput" : "latency")
        }
    }

    /// The mouth the coordinator gets. Apple's is cheap to build fresh;
    /// the neural one is the held instance for the reason above.
    func currentMouth(shieldHost: (any PlaybackHost)?) -> any SpeechSynthesizing {
        switch mouth {
        // The BEST INSTALLED voice, not the system default. The default
        // is a compact voice, which is why the field's verdict on this
        // mouth was "like a robot" (AC-105). If the phone has no
        // enhanced or premium voice downloaded, this returns a compact
        // one and nothing changes — which is why the name is on screen.
        case .apple: AppleSpeechSynthesizer(
            voiceIdentifier: appleVoiceIdentifier
                ?? AppleSpeechSynthesizer.bestInstalledVoice()?.identifier,
            // BEHIND THE SHIELD (4g, AC-121): Apple's PCM renders on the
            // capture engine too — both mouths, one road, the canceller
            // sees them all.
            renderingOn: shieldHost)
        case .neural: neuralVoice
        }
    }

    /// How big the chosen voice's download is, in that voice's own
    /// number.
    ///
    /// The screen used to say "1.1 GB" for every neural voice, which was
    /// Qwen's figure. Kokoro's is a third of that, and a person deciding
    /// whether to start a download over cellular deserves the real one.
    /// Kokoro's is DERIVED from the byte counts the library checks
    /// downloads against, so the sentence and the check cannot drift
    /// apart; Qwen's stays a written figure because TTSKit does not
    /// publish one.
    var voiceDownloadSize: String {
        switch levers.voice {
        case .kokoro:
            let bytes = KokoroWeights.sourceBytes + KokoroWeights.voiceBytes
            return "\(bytes / 1_000_000) MB"
        case .qwen3:
            return "1.1 GB"
        }
    }

    /// What the first reply after launch cost, on the voice that will
    /// speak — nil until there is a number, and nil for a mouth that
    /// keeps no such record. The cast lives here, beside `benchVoice`'s,
    /// so the view never names a vendor.
    ///
    /// Load is paid at launch; the first decode carries Metal's kernel
    /// compile; the second carries nothing — the difference is the
    /// compile, left for the reader to subtract rather than computed
    /// across two phrases of different length.
    var coldStartLine: String? {
        guard let cold = (neuralVoice as? KokoroVoice)?.coldStart,
              cold.loadMilliseconds != nil || cold.first != nil else { return nil }
        return coldStartLine(cold)
    }

    /// One line for `KokoroColdStart`, in the order the costs are paid:
    /// map, warm-up (both at launch), then the first two real replies.
    func coldStartLine(_ cold: KokoroColdStart) -> String {
        var parts: [String] = []
        // "map", not "load": MLX is lazy and this number is the mapping of
        // the weights, not the reading of them. The first field screen
        // said "load 84 ms" and that was true and misleading.
        if let map = cold.loadMilliseconds { parts.append(String(format: "map %.0f ms", map)) }
        if let warm = cold.warmUpMilliseconds {
            parts.append(String(format: "warm-up %.0f ms", warm))
        }
        if let first = cold.first {
            parts.append(String(format: "1st reply %.0f ms for %.1f s (%.2f×)",
                                first.wallMilliseconds, first.audioMilliseconds / 1000,
                                first.realTimeFactor))
            // The first PHRASE on its own: the line that settles D-085's
            // bet. A reply-level RTF averages residual cold away; this
            // does not.
            if let phrase = first.firstPhrase {
                parts.append(String(format: "its 1st phrase %.0f ms for %.1f s (%.2f×)",
                                    phrase.wallMilliseconds, phrase.audioMilliseconds / 1000,
                                    phrase.realTimeFactor))
            }
        }
        if let second = cold.second {
            parts.append(String(format: "2nd %.0f ms for %.1f s (%.2f×)",
                                second.wallMilliseconds, second.audioMilliseconds / 1000,
                                second.realTimeFactor))
        }
        return "cold: " + parts.joined(separator: " · ")
    }

    /// What the voice that exists is set to — read from the VOICE, never
    /// from `levers` (AC-143). The two disagree whenever an apply has not
    /// landed yet, and that is exactly when a person is looking.
    var voiceInForce: String { neuralVoice.inForce }

    /// What will actually speak, named. A person who cannot see
    /// "compact" has no way to tell "the app ignored my download" from
    /// "this is as good as this phone gets".
    var appleVoiceDescription: String {
        if let appleVoiceIdentifier,
           let chosen = availableAppleVoices.first(where: { $0.id == appleVoiceIdentifier }) {
            return chosen.label
        }
        guard let voice = AppleSpeechSynthesizer.bestInstalledVoice() else {
            return "no voice found"
        }
        return AppleSpeechSynthesizer.describe(voice) + " (auto)"
    }
}
