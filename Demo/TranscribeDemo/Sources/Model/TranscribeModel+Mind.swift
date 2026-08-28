import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the mind: which generator answers, its download,
// the turns it produced, and the conversation log they leave behind.
extension TranscribeModel {
    /// Instructions are the APP's text, not the library's (D-027). The
    /// same sentence the Apple mind gets, because the constraint is the
    /// medium — this reply is heard, never read — not the model.
    /// Computed, not stored: `@Observable` cannot hold a `lazy`, and this
    /// costs nothing — the generator is a struct wrapping the SHARED
    /// actor, so every copy talks to the same loaded weights.
    private var localMind: MLXReplyGenerator {
        MLXReplyGenerator(
            model: localModel,
            instructions: "Your reply will be spoken aloud by a synthetic voice "
                + "and never shown as text. Answer in ONE short sentence. Do "
                + "not add extra facts, background or explanation unless the "
                + "person asks for them. Never use lists, bullet points, "
                + "numbered items, markdown, code, or headings.",
            maxTokens: 160)
    }

    private func record(_ turn: ConversationTurn) {
        turns.append(ConversationTurn(
            id: turns.count + 1, mind: turn.mind, heard: turn.heard,
            reply: turn.reply, firstTokenMs: turn.firstTokenMs,
            totalMs: turn.totalMs, failure: turn.failure,
            // ONLY when the local mind answered. MLX's peak is
            // process-wide, so stamping it on an Apple or Echo turn
            // reported a number that turn had nothing to do with — an
            // instrument answering a question it was not asked.
            peakMemoryMB: (turn.mind.hasPrefix("Local") && MLXRuntime.isAvailable)
                ? MLXRuntime.peakMemoryBytes / 1_048_576 : nil,
            bargedIn: turn.bargedIn,
            // WHEN, and how hot, and how much room was left. Sampled at the
            // end of the turn rather than the start: what a person felt is
            // the state the reply finished in.
            atSeconds: sessionStart.map {
                Int($0.duration(to: ContinuousClock().now)
                    .components.seconds)
            } ?? 0,
            thermal: thermalName,
            freeMB: freeMegabytesNow()))
        // A margin that fired before this row existed was parked; it can
        // only belong to the reply this row describes. Cleared ALWAYS —
        // one row is the farthest a parked margin may travel, and a
        // barged row claims nothing (its mouth was cancelled).
        if let parked = pendingVoiceMargin {
            pendingVoiceMargin = nil
            if let index = turns.indices.last, !turns[index].bargedIn {
                stamp(parked, onto: index)
            }
        }
    }

    /// Stamps the voice's numbers onto the turn that spoke them (AC-173).
    /// Only the NEWEST row is ever considered: a barged row is never
    /// touched (its mouth was cancelled — an arriving margin cannot be
    /// its), and a margin that beats its own row into existence parks in
    /// `pendingVoiceMargin` for record() to claim. The cushion comes from
    /// the MARGIN, stamped by the run that was built with it — asking the
    /// voice here returns the value the learner just adapted to, which is
    /// the NEXT reply's cushion (the review's blocker).
    func attach(_ margin: DecodeMargin) {
        guard let index = turns.indices.last,
              turns[index].voiceAudioMs == nil, !turns[index].bargedIn
        else {
            pendingVoiceMargin = margin
            return
        }
        stamp(margin, onto: index)
    }

    private func stamp(_ margin: DecodeMargin, onto index: Int) {
        turns[index].voiceAudioMs = Int(margin.audioMilliseconds.rounded())
        turns[index].voiceRTF = margin.steadyRealTimeFactor
        turns[index].cushionMs = margin.cushionMilliseconds.map { Int($0.rounded()) }
        turns[index].voiceCompleted = margin.completed
    }

    private var thermalName: String {
        switch thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    func clearLog() { turns.removeAll() }

    /// The log as markdown, so it leaves the phone as DATA rather than as
    /// a photograph of a screen.
    var conversationLog: String {
        var out = "# Conversation log — MultiModalKit demo\n\n"
        out += "picker says: mind=\(mind.rawValue) · ear=\(choice.rawValue) "
        out += "· mouth=\(mouth.rawValue) · speaker shield=\(speakerShield)\n"
        out += "local model: \(LocalMind.repoID) · installed: "
        out += "\(localModel.modelInstalled()) · MLX runnable here: "
        out += "\(MLXRuntime.isAvailable)\n"
        // AC-132: the number that decides whether the mind and the neural
        // voice can coexist. It is the PHONE's dirty-memory headroom, not
        // a Mac's footprint — the distinction 4i exists for.
        switch MemoryHeadroomReader.read() {
        case .bytes(let bytes):
            out += "memory headroom: \(bytes / 1_048_576) MB before this app's limit\n"
        case .exhausted:
            out += "memory headroom: NONE — at or over the limit\n"
        case .unavailable(let why):
            out += "memory headroom: unavailable (\(why))\n"
        }
        out += "voice loaded: \(voiceState == .ready && mouth == .neural)\n"
        if MLXRuntime.isAvailable {
            out += "MLX memory now: active "
            out += "\(MLXRuntime.activeMemoryBytes / 1_048_576) MB · peak "
            out += "\(MLXRuntime.peakMemoryBytes / 1_048_576) MB\n"
        }
        if let why = mindAssets.unavailable { out += "mind unavailable: \(why)\n" }
        if let status = mindAssets.downloadStatus { out += "download: \(status)\n" }
        out += "weights expected at: \(localModel.weights.path)\n"
        out += "\nNOTE: the `mind:` line under each turn is the brain that\n"
        out += "ACTUALLY answered, taken from the generator the coordinator\n"
        out += "held — not from the picker above. If they disagree, that is\n"
        out += "the finding.\n\n"
        if !probe.lines.isEmpty {
            out += "\n## pressure probe\n\n```\n"
            out += probe.lines.joined(separator: "\n")
            out += "\n```\n\n"
        }
        if turns.isEmpty { out += "_(no turns recorded yet)_\n" }
        for turn in turns {
            out += "## turn \(turn.id)\n"
            out += "mind: **\(turn.mind)**\n\n"
            out += "heard: \(turn.heard.isEmpty ? "_(nothing)_" : turn.heard)\n\n"
            out += "reply: \(turn.reply.isEmpty ? "_(no words)_" : turn.reply)\n\n"
            let first = turn.firstTokenMs.map { "\($0) ms" } ?? "never"
            out += "at \(turn.atSeconds) s · thermal \(turn.thermal)"
            if let free = turn.freeMB { out += " · \(free) MB free" }
            out += "\n\n"
            out += "first word \(first) · total \(turn.totalMs) ms"
            if let mb = turn.peakMemoryMB { out += " · MLX peak \(mb) MB" }
            if turn.bargedIn { out += " · BARGED IN (no terminal — expected on interrupt)" }
            if let failure = turn.failure { out += " · FAILED: \(failure)" }
            out += "\n\n"
            if let audio = turn.voiceAudioMs, let rtf = turn.voiceRTF {
                out += String(format: "voice: %d ms audio · RTF %.3f", audio, rtf)
                if let cushion = turn.cushionMs { out += " · cushion \(cushion) ms" }
                if turn.voiceCompleted == false { out += " · DID NOT FINISH" }
                out += "\n\n"
            }
        }
        return out
    }

    /// THE PAIR FITS — measured, and this used to say the opposite.
    ///
    /// It reported "the 4B mind and the neural voice do not fit together"
    /// and disabled Listen, on the strength of a MAC's phys_footprint
    /// (2239 + 1112 = 3351). Ryad's phone then loaded both with **1011 MB
    /// to spare**, because the neural voice costs **111 MB** on iOS, not
    /// 1112: CoreML MAPS its weights, and mapped pages are clean, so they
    /// are not charged against a dirty memory limit. MLX has no mmap, so
    /// its 2225 MB is charged in full (INSTRUMENTS §29).
    ///
    /// What replaced the refusal is an ORDER, because the steady
    /// footprint was never the problem — the LOAD is. TTSKit compiles six
    /// CoreML models concurrently, and that transient peak is what killed
    /// the app twice: at 1105 MB free and at 2976 MB free. It survived at
    /// 3347 MB. So the voice is loaded FIRST, from maximum headroom,
    /// before the mind takes its 2.2 GB. See `RootView`'s launch sequence,
    /// where that order is now load-bearing rather than incidental.
    var memoryConflict: String? { nil }

    func downloadLocalMind() {
        guard mindAssets.downloadProgress == nil else {
            mindAssets.downloadStatus = "already downloading — ignoring the tap."
            return
        }
        mindAssets.downloadProgress = 0
        mindAssets.downloadStatus = "starting the local mind (\(LocalMind.sizeOnDisk))…"
        Task { [localModel] in
            do {
                self.mindAssets.downloadStatus = "asking Hugging Face for \(LocalMind.repoID)…"
                try await localModel.download { fraction in
                    Task { @MainActor in
                        self.mindAssets.downloadProgress = fraction
                        self.mindAssets.downloadStatus = String(
                            format: "downloading the local mind — %.0f%%",
                            fraction * 100)
                    }
                }
                self.mindAssets.downloadProgress = nil
                // Proof, not hope: the download returning is not the same
                // as the files being usable. And it must judge the model
                // it actually DOWNLOADED — `localModel` may have been
                // replaced by the picker meanwhile, and the review caught
                // the first version reporting a perfectly good download as
                // broken because it asked the wrong object.
                let installed = localModel.modelInstalled()
                self.mindAssets.downloadStatus = installed
                    ? "installed at \(localModel.weights.lastPathComponent)."
                    : "download finished but the files are NOT usable — "
                        + "expected them at \(localModel.weights.path)"
                self.refreshMind()
            } catch {
                self.mindAssets.downloadProgress = nil
                self.mindAssets.downloadStatus = "download FAILED: \(error)"
            }
        }
    }

    /// The generator the coordinator gets. BOTH minds keep 4c's honest
    /// witness — the 🧠 line shows what the ledger delivered across the
    /// seam, whichever brain answers (AC-91's proof duty, unchanged).
    var currentGenerator: any ReplyGenerating {
        let witness: @Sendable (String) -> Void = { [weak self] thought in
            Task { @MainActor in self?.wholeThought = thought }
        }
        let sink: @Sendable (ConversationTurn) -> Void = { [weak self] turn in
            Task { @MainActor in self?.record(turn) }
        }
        switch mind {
        case .echo:
            return ThoughtWitness(wrapped: PhoneEchoReply(onThought: witness),
                                  mindLabel: "Echo (a stand-in that REPEATS your words)",
                                  onThought: { _ in }, onTurn: sink)
        case .apple:
            return ThoughtWitness(wrapped: appleMind, mindLabel: "Apple",
                                  onThought: witness, onTurn: sink)
        case .local:
            return ThoughtWitness(wrapped: localMind, mindLabel: "Local (MLX)",
                                  onThought: witness, onTurn: sink)
        }
    }

    /// Reads the availability enum FRESH — a download can complete
    /// between two turns, and caching "unavailable" would turn a
    /// temporary state into a permanent verdict. When the mind is ready,
    /// the warm-up is paid here, not inside the first felt pause.
    /// Put the local mind down before the platform takes the GPU away
    /// (D-079, the review's blocker).
    ///
    /// `retire()` cancels the warm-up task AND releases the weights, and
    /// both halves are wanted here: the first is what stops Metal work
    /// that iOS is about to refuse, and the second hands 2.2 GB back to a
    /// system that is about to judge this app's footprint anyway.
    ///
    /// **The cost, named.** A retired mind is cold, so the first reply
    /// after coming back pays the load again. `rewarmMind()` below is why
    /// that is usually invisible: returning to the foreground starts the
    /// warm-up immediately, in the same window the person spends looking
    /// at the screen before they speak.
    ///
    /// The same honest limit as the rest of D-079 applies: cancellation is
    /// cooperative, so this wins the race only when MLX is between command
    /// buffers.
    func retireLocalMind() async {
        await localModel.retire()
    }

    /// The other half of `retireLocalMind()`: back in the foreground, warm
    /// the mind again so the next reply does not pay for the retirement.
    func rewarmMind() {
        guard mind == .local else { return }
        refreshMind()
    }

    func refreshMind() {
        if mind == .local {
            // THE GUARD BELONGS HERE, not only on the Listen button.
            //
            // The review caught this and it was a blocker of my own
            // making: LOADING is what costs the memory, and both models
            // load at LAUNCH — checkVoice() prepares the voice, this
            // prewarms the mind — long before anyone can tap anything.
            // Guarding the button stopped nothing. Worse, once the mind
            // and mouth started persisting, the forbidden pair survived a
            // restart, so the app would be killed on every cold start
            // with the picker permanently out of reach: a crash loop the
            // person could not escape from inside the app.
            guard memoryConflict == nil else {
                mindAssets.unavailable = memoryConflict
                return                      // load NOTHING
            }
            // The simulator answer is STRUCTURAL, not a missing file
            // (D-061): MLX wants a shared-storage Metal heap and the
            // simulator's driver refuses. Saying so beats a dead button.
            guard MLXRuntime.isAvailable else {
                mindAssets.unavailable = String(describing: MLXUnavailable.platformCannotRunMLX)
                return
            }
            guard localModel.modelInstalled() else {
                mindAssets.unavailable = "the local mind is not downloaded yet — "
                    + "tap Download (\(LocalMind.sizeOnDisk), once)."
                return
            }
            mindAssets.unavailable = nil
            localMind.prewarm()   // the measured 1.7 s load, paid off-turn
            return
        }
        guard mind == .apple else { mindAssets.unavailable = nil; return }
        switch AppleReplyGenerator.availability {
        case nil:
            mindAssets.unavailable = nil
            appleMind.prewarm()
        case .some(let reason):
            // THE LIBRARY OWNS THE WORDS (4f review): the same sentence a
            // mid-session failure prints is the one this caption shows, so
            // the two surfaces cannot drift apart.
            mindAssets.unavailable = String(describing: reason)
        }
    }
}
