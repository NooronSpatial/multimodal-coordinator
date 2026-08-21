import SwiftUI

struct ContentView: View {
    @State private var model = TranscribeModel()
    // The 4f measurement instrument, held beside the model rather than
    // inside it: it probes a SYSTEM service, touches nothing on the
    // pipeline, and leaves with the milestone-gating numbers (AC-110/111).
    @State private var mindProbe = MindProbe()
    @State private var showMindProbe = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch model.engineState {
                    case .checking:
                        ProgressView("Checking the speech model…")
                    case .modelMissing:
                        modelMissing
                    case .downloading:
                        ProgressView("Downloading the speech model…\n(system-managed; can take a while)")
                            .multilineTextAlignment(.center)
                    // The transcriber never enters `.preparing` — only the
                    // voice does — but the compiler is right to demand an
                    // answer rather than let a future state fall silently
                    // through a screen.
                    case .preparing:
                        ProgressView("Preparing the speech model…")
                            .multilineTextAlignment(.center)
                    case .failed(let reason):
                        failed(reason)
                    case .ready:
                        transcriber
                    }
                }
                .frame(maxHeight: .infinity)

                // ALWAYS reachable, deliberately: the echo probe needs no
                // speech model, and the machines where a model refuses to
                // install are exactly the ones where a measurement matters
                // most. Trapping it behind "ready" would have hidden the
                // instrument on the first device that needed it.
                // The probe's RESULTS live here; its trigger is in the
                // toolbar. A button in this bottom strip did not fire on
                // synthetic taps in the simulator — the Download button in
                // the same build did — and rather than ship a control I
                // could not prove works, the trigger moved somewhere
                // taps are reliable.
                if model.probeSilence != nil || model.probeStatus != nil {
                    Divider()
                    echoProbeResults
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                }
                if model.shieldStatus != nil || !model.shieldReport.isEmpty {
                    Divider()
                    // A SCROLL VIEW, from the field: matrix v2's eight
                    // witness columns outgrew the strip and pushed the
                    // last arrangements off screen — a report you cannot
                    // read is a dead instrument with extra steps.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if let status = model.shieldStatus {
                                Label(status, systemImage: "hourglass")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.shieldReport, id: \.self) { line in
                                Text(line)
                            }
                        }
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                    .frame(maxHeight: 230)
                }
            }
            // NO TITLE (Ryad): a large title spent a third of a phone
            // screen saying the app's own name to the person who just
            // opened it. The toolbar stays — that is where the probes and
            // the log live, and taps are proven to fire there.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // THE CONVERSATION LOG. Reachable in every state, like the
                // probes, and for the same reason: the moment worth
                // sharing is usually the moment something went wrong, and
                // a log you cannot reach then is not a log.
                //
                // It carries the brain that ACTUALLY answered each turn,
                // which is the one fact a screenshot cannot show.
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.conversationLog) {
                        Label("Share the conversation", systemImage: "text.bubble")
                    }
                    .disabled(model.turns.isEmpty)
                }
                // THE MIND PROBE (4f, AC-110/AC-111), reachable in EVERY
                // engine state for the echo probe's reason, one item over:
                // it measures a SYSTEM service, and the devices where a
                // model refuses to install are exactly the ones where the
                // availability enum matters most. In the toolbar because
                // that is where this app has PROVEN taps fire.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMindProbe = true
                    } label: {
                        Label("Mind probe", systemImage: "brain")
                    }
                    .disabled(model.isListening)
                }
                // THE SHIELD PROBE (4g, AC-119): reachable in every state,
                // like its two siblings, and for the same reason.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.runShieldProbe() }
                    } label: {
                        Label(model.shieldStatus == nil ? "Shield probe" : "measuring…",
                              systemImage: "shield.lefthalf.filled")
                    }
                    .disabled(model.isListening || model.shieldStatus != nil
                              || model.probeStatus != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.runEchoProbe() }
                    } label: {
                        Label(model.probeStatus == nil ? "Echo probe" : "measuring…",
                              systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(model.isListening || model.probeStatus != nil
                              || model.shieldStatus != nil)
                }
            }
            .sheet(isPresented: $showMindProbe) {
                NavigationStack {
                    List { MindProbeSection(probe: mindProbe) }
                        .navigationTitle("Mind probe")
                }
            }
            .task {
                // Both models are asked about at launch: the transcriber's
                // and the voice's. Asking never downloads either.
                await model.checkModel()
                await model.checkVoice()
                model.refreshMind()
            }
        }
    }

    private var modelMissing: some View {
        ContentUnavailableView {
            Label("Speech model needed", systemImage: "arrow.down.circle")
        } description: {
            Text("One download, then everything runs on this phone — nothing ever leaves it.")
        } actions: {
            Button("Download") { Task { await model.downloadModel() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private func failed(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Something failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Try again") { Task { await model.checkModel() } }
        }
    }

    /// Milestone 4d on screen: the turn loop the Mac has had since 4a/4b,
    /// now on the phone — plus the two toggles the field run needs.
    private var conversation: some View {
        VStack(spacing: 10) {
            HStack {
                Toggle("Talk back", isOn: Bindable(model).talkEnabled)
                Divider().frame(height: 20)
                // F-4 as amended by D-043: the speaker is the measured
                // broken route, kept one toggle away for measurement.
                Toggle("Speaker", isOn: Bindable(model).useSpeaker)
                    .disabled(!model.talkEnabled)
            }
            .toggleStyle(.switch)
            .font(.subheadline)

            if model.talkEnabled {
                Toggle("Speaker shield (4g) — reply rendered where the canceller sees it",
                       isOn: Bindable(model).speakerShield)
                    .toggleStyle(.switch)
                    .font(.caption)
                    .disabled(model.isListening)
            }

            // The known limit, said plainly where it bites — not buried in
            // a document the person holding the phone will never open.
            // With the shield ON the old sentence would be a stale claim:
            // the label switches to the honest in-between state until
            // AC-124 rewrites it with the measured reply number.
            if model.talkEnabled && model.useSpeaker {
                Label(model.speakerShield
                      ? "Shield ON: the probe measured a tone cancelled to 0.004–0.08 "
                        + "(vs 1.0 unshielded, INSTRUMENTS §23). The reply's own number is "
                        + "still being measured — the barge counters below tell the truth."
                      : "On speaker the reply is not cancelled (measured peak 1.0) — "
                        + "it will interrupt itself. Receiver or headphones work.",
                      systemImage: model.speakerShield
                      ? "shield.lefthalf.filled" : "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(model.speakerShield ? .blue : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.talkEnabled {
                HStack(spacing: 8) {
                    Image(systemName: turnIcon)
                        .foregroundStyle(model.turnState == .speaking ? .blue : .secondary)
                    Text(turnLabel).font(.subheadline.weight(.medium))
                    Spacer()
                    if let pause = model.feltPauseMilliseconds {
                        Text("felt pause \(pause) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // THE BARGE DIAGNOSTIC. Two counters, because they fail
                // apart: onsets is what the PUMP heard while the reply was
                // playing, barges is what the COORDINATOR did about it.
                HStack(spacing: 10) {
                    Text("onsets while speaking: \(model.onsetsWhileSpeaking)")
                        .foregroundStyle(model.onsetsWhileSpeaking > 0 ? Color.primary
                                                                       : Color.secondary)
                    Text("barges: \(model.bargeCount)")
                        .foregroundStyle(model.bargeCount > 0 ? Color.green : Color.red)
                    Spacer()
                    Text(model.lastTurnEvent).foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())

                if !model.reply.isEmpty {
                    Text(model.reply)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.blue.opacity(0.12), in: .rect(cornerRadius: 8))
                }

                // The whole thought that crossed the seam — 4c, visible
                // (AC-91). Two sentences with a pause between them belong
                // on ONE line here.
                if !model.wholeThought.isEmpty {
                    Label(model.wholeThought, systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // The gate, on screen and adjustable — a level means nothing
            // without the number it is judged against (AC-97: this device
            // earns its own).
            HStack(spacing: 8) {
                Text("gate").font(.caption).foregroundStyle(.secondary)
                Slider(value: Bindable(model).vadThreshold, in: 0.005...0.08)
                    .disabled(model.isListening)
                Text(model.vadThreshold, format: .number.precision(.fractionLength(3)))
                    .font(.caption.monospacedDigit())
            }

            // F-5 = B: nothing resumes by itself. A person decides when a
            // microphone turns back on — and resuming forgets the thought.
            if model.wasInterrupted {
                HStack {
                    Label("Interrupted — the audio was taken away",
                          systemImage: "phone.down.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Resume") { Task { await model.resumeAfterInterruption() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal)
    }

    /// AC-96's instrument: the phone speaks while reading the microphone
    /// RAW — past the VAD, so "nothing happened" can never be confused
    /// with "the microphone is deaf". Needs no speech model, so it runs
    /// even where an engine will not.
    private var echoProbeResults: some View {
        VStack(spacing: 6) {
            if let status = model.probeStatus {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let failure = model.probeFailure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let quiet = model.probeSilence, let speaking = model.probeWhileSpeaking {
                VStack(alignment: .leading, spacing: 3) {
                    // The two facts that make the numbers interpretable:
                    // which way the sound came out, and whether the
                    // canceller was actually granted (asked ≠ got).
                    HStack {
                        Text(model.probeRoute).font(.caption2)
                        Text(model.probeVoiceProcessingActive
                             ? "· voice processing ACTIVE"
                             : "· voice processing REFUSED")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(model.probeVoiceProcessingActive
                                             ? Color.secondary : Color.red)
                        Spacer()
                    }
                    probeRow("quiet room", quiet)
                    probeRow("while speaking", speaking)
                    // The verdict, in one line, so the field run does not
                    // have to interpret two numbers under pressure.
                    Text(speaking.peak >= model.vadThreshold
                         ? "→ CROSSES the gate — if you stayed quiet, it will barge itself"
                         : "→ stays under the gate on this route")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(speaking.peak >= model.vadThreshold ? .red : .green)
                    // The verdict is only true in SILENCE. A run where the
                    // person spoke measures their VOICE and reads as a
                    // failure — it misled us once, so the assumption is
                    // now printed next to the claim that depends on it.
                    Text("valid only if nobody spoke during the measurement")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func probeRow(_ label: String, _ value: (peak: Float, rms: Float)) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("peak \(value.peak, format: .number.precision(.fractionLength(4)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(value.peak >= model.vadThreshold ? .red : .primary)
            Text("rms \(value.rms, format: .number.precision(.fractionLength(4)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var turnIcon: String {
        switch model.turnState {
        case .idle: "circle"
        case .listening: "ear"
        case .thinking: "ellipsis.circle"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private var turnLabel: String {
        switch model.turnState {
        case .idle: "idle"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking — interrupt it with your voice"
        }
    }

    private var transcriber: some View {
        VStack(spacing: 12) {
            // THE SETTINGS SCROLL (Ryad). Five pickers, four toggles and
            // their captions outgrew the screen once the local model
            // picker arrived, and controls you cannot reach are controls
            // you do not have. Capped rather than greedy, so the
            // transcript — the thing people actually watch — keeps room.
            ScrollView {
                VStack(spacing: 14) {
            // INLINE ROWS (Ryad): label on the left, current value on the
            // right, one line each. Five full-width segmented bars had
            // pushed the transcript off the screen. `.labelsHidden()` is
            // deliberate — the Text carries the name, so the menu button
            // shows only the VALUE and every row reads the same way.
            HStack {
                Text("Ear").font(.subheadline)
                Spacer()
                Picker("Engine", selection: Bindable(model).choice) {
                    ForEach(TranscribeModel.EngineChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isListening)
            }
            .padding(.horizontal)

            // THE SECOND MOUTH, on screen (AC-105). Only shown when the
            // app is actually talking — a mouth picker above a silent
            // pipeline would be a control with nothing to control.
            if model.talkEnabled {
                VStack(spacing: 8) {
                    // THE MIND (4f, AC-117): what ANSWERS, above what
                    // SPEAKS — the same swap-an-organ claim the mouth
                    // picker makes, one seam up.
                    HStack {
                        Text("Mind").font(.subheadline)
                        Spacer()
                        Picker("Mind", selection: Bindable(model).mind) {
                            ForEach(TranscribeModel.MindChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(model.isListening)
                    }
                    if model.mind == .local {
                        // F-1 = C: WHICH local model, chosen here so the
                        // phone can answer what the Mac cannot. MLX keeps
                        // weights resident (no mmap), so 2.1 GB on a phone
                        // is a real question and this is the instrument
                        // that asks it. The caption carries MAC numbers
                        // and says so — they are not a phone's.
                        HStack {
                            Text("Local model").font(.subheadline)
                            Spacer()
                            Picker("Local model",
                                   selection: Bindable(model).localModelChoice) {
                                ForEach(TranscribeModel.LocalModelChoice.allCases) { size in
                                    Text(size.rawValue).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .disabled(model.isListening)
                        }
                        Text("\(model.localModelChoice.sizeOnDisk) · on a Mac: "
                             + model.localModelChoice.macBehaviour)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // AC-131: the third mind never vanishes and never
                        // dies silently. On a simulator it says WHY it
                        // cannot run (D-061, structural); with no weights
                        // it offers the one action that fixes that.
                        Text(model.mindUnavailable
                             ?? "local weights ready · answers never leave this device")
                            .font(.caption2)
                            .foregroundStyle(model.mindUnavailable == nil
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(Color.orange))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The status line is ALWAYS shown once there is
                        // one, whether the download is running, finished
                        // or failed. A tap must never be able to look
                        // like nothing happened.
                        if let status = model.localDownloadStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.contains("FAILED")
                                                 || status.contains("NOT usable")
                                                 ? AnyShapeStyle(Color.red)
                                                 : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if let fraction = model.localDownloadProgress {
                            ProgressView(value: fraction)
                        } else if model.mindUnavailable?.contains("not downloaded") == true {
                            Button("Download \(model.localModelChoice.rawValue) · \(model.localModelChoice.sizeOnDisk)") {
                                model.downloadLocalMind()
                            }
                            .font(.caption)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if model.mind == .apple {
                        // AC-110 on the main screen: the enum's reason in
                        // words, never a silent dead Listen button. And
                        // "ready" stays modest — availability is necessary,
                        // not sufficient (the Simulator lied, INSTRUMENTS
                        // §22); a failed first turn still tells the truth.
                        Text(model.mindUnavailable
                             ?? "on-device model ready · answers are spoken, one session per turn")
                            .font(.caption2)
                            .foregroundStyle(model.mindUnavailable == nil
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(Color.red))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Text("Voice").font(.subheadline)
                        Spacer()
                        Picker("Voice", selection: Bindable(model).mouth) {
                            ForEach(TranscribeModel.MouthChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(model.isListening)
                    }

                    switch model.voiceState {
                    case .modelMissing:
                        VStack(spacing: 4) {
                            Text("The neural voice needs a 1.1 GB download. "
                                 + "One time, over Wi-Fi — then it runs on this phone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Install voice") {
                                Task { await model.installVoice() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    case .downloading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Downloading the voice — a silent minute is not a hang.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .preparing:
                        HStack(spacing: 8) {
                            ProgressView()
                            // The honest sentence. Nothing is being
                            // fetched: the 1.1 GB is already on the phone
                            // and CoreML is compiling it, which happens
                            // once per launch.
                            Text("Preparing the voice — already downloaded, "
                                 + "compiling it for this device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let why):
                        Text("Voice unavailable: \(why)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    case .checking, .ready:
                        EmptyView()
                    }

                    // WHICH APPLE VOICE, and how good. "compact" here is
                    // the honest explanation for a robotic reply, and it
                    // points at a download rather than at a bug.
                    if model.mouth == .apple {
                        // THE PERSON PICKS. A long list, so a menu rather
                        // than a segmented control — and every row says
                        // its quality, because "compact" is the honest
                        // explanation for a robotic voice and it points
                        // at a download rather than at a bug.
                        Picker("Apple voice", selection: Bindable(model).appleVoiceIdentifier) {
                            Text("Best installed (auto)").tag(String?.none)
                            ForEach(model.availableAppleVoices) { voice in
                                Text(voice.label).tag(String?.some(voice.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(model.isListening)
                        Text(model.appleVoiceDescription)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // VOICE FORENSICS (AC-104). A field run came back
                    // with four adjectives — hot, late, worse, "drunk" —
                    // and no numbers. These are the numbers, on the
                    // device that produced the adjectives.
                    if model.mouth == .neural, model.voiceState == .ready {
                        VStack(alignment: .leading, spacing: 2) {
                            if let margin = model.voiceMargin {
                                Text(String(format: "decode %.2f× real time%@ · prefill %.0f ms",
                                            margin.steadyRealTimeFactor,
                                            margin.keepsUp ? "" : "  ⚠️ TOO SLOW",
                                            margin.prefillMilliseconds))
                                    .foregroundStyle(margin.keepsUp
                                                     ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(Color.red))
                            }
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }

            // THE LEVEL METER, above everything the gate controls.
            // Set the gate ABOVE the quiet number and BELOW the speaking
            // one, and the app works; there is no third rule.
            if model.isListening {
                VStack(spacing: 2) {
                    HStack {
                        Text(String(format: "mic %.3f", model.inputLevel))
                        Spacer()
                        Text(String(format: "peak %.3f", model.inputPeak))
                        Spacer()
                        if !model.engineAlive {
                            Text("ENGINE STOPPED")
                                .foregroundStyle(Color.red)
                        }
                        if model.engineReconfigurations > 0 {
                            Text("reconfig \(model.engineReconfigurations)")
                                .foregroundStyle(Color.orange)
                        }
                        Text(String(format: "gate %.3f", model.vadThreshold))
                            .foregroundStyle(model.inputLevel > model.vadThreshold
                                             ? AnyShapeStyle(Color.green)
                                             : AnyShapeStyle(.secondary))
                    }
                    .font(.caption2.monospaced())
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(model.inputLevel > model.vadThreshold ? Color.green : Color.gray)
                                .frame(width: geometry.size.width
                                       * CGFloat(min(model.inputLevel / 0.3, 1)))
                            // Where the gate sits, on the same scale.
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2)
                                .offset(x: geometry.size.width
                                        * CGFloat(min(model.vadThreshold / 0.3, 1)))
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.horizontal)
            }

            // CALIBRATE, so nobody has to guess this number again.
            if model.isListening {
                VStack(spacing: 4) {
                    Button {
                        Task { await model.calibrateGate() }
                    } label: {
                        Label(model.isCalibrating ? "Calibrating…" : "Calibrate gate",
                              systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isCalibrating)

                    if let status = model.calibrationStatus {
                        Text(status)
                            .font(.caption2.monospaced())
                            .foregroundStyle(model.isCalibrating
                                             ? AnyShapeStyle(Color.orange)
                                             : AnyShapeStyle(.secondary))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
            }

                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 300)
            .scrollBounceBehavior(.basedOnSize)

            conversation

            ScrollViewReader { proxy in
                List {
                    ForEach(model.utterances) { utterance in
                        HStack(alignment: .top) {
                            Image(systemName: icon(for: utterance))
                                .foregroundStyle(utterance.failure == nil
                                                 ? (utterance.isFinal ? .green : .orange)
                                                 : .red)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(utterance.text.isEmpty ? "…" : utterance.text)
                                    .foregroundStyle(utterance.isFinal ? .primary : .secondary)
                                if let failure = utterance.failure {
                                    Text(failure).font(.caption).foregroundStyle(.red)
                                }
                                // The Mac's 🔎 line: what actually opened
                                // this utterance, in numbers. "echo?" marks
                                // one that began while the phone was
                                // talking — the self-barge signature.
                                if utterance.peakRMS > 0 {
                                    HStack(spacing: 6) {
                                        Text("peak \(utterance.peakRMS, format: .number.precision(.fractionLength(3)))")
                                        Text("· \(utterance.milliseconds) ms")
                                        if utterance.whileSpeaking {
                                            Text("· echo?")
                                                .foregroundStyle(.red)
                                        }
                                    }
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if model.utterances.isEmpty && model.isListening {
                        Text("Say something — it stops and listens.")
                            .foregroundStyle(.secondary)
                    }

                    if !model.isListening {
                        Section("Bake-off — same fixture as the Mac") {
                            if let status = model.bakeoffStatus {
                                Label(status, systemImage: "hourglass")
                                    .foregroundStyle(.secondary)
                            } else {
                                Button {
                                    Task { await model.runBakeoff() }
                                } label: {
                                    Label("Run bake-off (both engines)", systemImage: "scalemass")
                                }
                            }
                            ForEach(model.bakeoffRows, id: \.engineName) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.engineName).font(.subheadline.bold())
                                    Text(String(format: "WER %.1f%% · %d sub · %d ins · %d del · settle %.2f s",
                                                row.score.wer * 100, row.score.substitutions,
                                                row.score.insertions, row.score.deletions,
                                                row.decodeSeconds))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !model.bakeoffRows.isEmpty {
                                ShareLink(item: model.bakeoffMarkdown) {
                                    Label("Share table (markdown)", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // Follow the conversation: any change to the utterances — a new
                // row OR a growing partial — keeps the newest text on screen.
                .onChange(of: model.utterances) {
                    guard let last = model.utterances.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            statusBar

            // The combination that gets the app KILLED, said before the
            // tap rather than found in a crash log (INSTRUMENTS §27).
            if let conflict = model.memoryConflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                model.isListening ? model.stop() : model.start()
            } label: {
                Label(model.isListening ? "Stop" : "Listen",
                      systemImage: model.isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? .red : .accentColor)
            // The other half of the mutual exclusion (4d review): the
            // probe already refused to start while listening, but nothing
            // stopped listening from starting while a probe held the
            // process-wide session.
            // And the MIND's gate (AC-110, found by the 4f review): when
            // the Apple mind is selected and unavailable, start() refuses
            // silently — so without this, tapping Listen did NOTHING, the
            // exact silent dead button AC-110 forbids. Disabled + the red
            // caption naming the reason = honest.
            .disabled(model.probeStatus != nil
                      || (model.talkEnabled && model.mind == .apple
                          && model.mindUnavailable != nil)
                      // Measured, not feared: 2239 MB + 1112 MB = 3351 MB,
                      // and jetsam killed exactly this on the phone.
                      || model.memoryConflict != nil)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(model.isSpeaking ? "speech" : "quiet",
                  systemImage: model.isSpeaking ? "waveform" : "waveform.slash")
                .foregroundStyle(model.isSpeaking ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            // The thermal badge — the health loop, visible (D-027).
            Label(thermalText, systemImage: "thermometer.medium")
                .foregroundStyle(thermalColor)
            if model.settlingCount > 0 {
                Label("decoding ×\(model.settlingCount)", systemImage: "brain")
                    .foregroundStyle(Color.orange)
                    .monospacedDigit()
            }
            Spacer()
            // The ring's honesty, on screen: frames lost, exactly counted.
            Label("dropped: \(model.droppedFrames)", systemImage: "drop")
                .foregroundStyle(model.droppedFrames == 0 ? Color.secondary : Color.red)
                .monospacedDigit()
        }
        .font(.footnote)
        .padding(.horizontal)
    }

    private var thermalText: String {
        switch model.thermal {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        }
    }

    private var thermalColor: Color {
        switch model.thermal {
        case .nominal: .secondary
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    private func icon(for utterance: TranscribeModel.Utterance) -> String {
        if utterance.failure != nil { return "xmark.circle" }
        return utterance.isFinal ? "checkmark.circle.fill" : "ellipsis.circle"
    }
}
