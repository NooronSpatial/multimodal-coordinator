import SwiftUI

struct ContentView: View {
    @State private var model = TranscribeModel()

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
            }
            .navigationTitle("MultiModalKit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.runEchoProbe() }
                    } label: {
                        Label(model.probeStatus == nil ? "Echo probe" : "measuring…",
                              systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(model.isListening || model.probeStatus != nil)
                }
            }
            .task { await model.checkModel() }
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
                // F-4 = A + toggle: the speaker is the default and the hard
                // echo case; both routes get measured (AC-96).
                Toggle("Speaker", isOn: Bindable(model).useSpeaker)
                    .disabled(!model.talkEnabled)
            }
            .toggleStyle(.switch)
            .font(.subheadline)

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
                         ? "→ the reply CROSSES the gate: it will barge itself"
                         : "→ the reply stays under the gate: the canceller is working")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(speaking.peak >= model.vadThreshold ? .red : .green)
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
        VStack(spacing: 16) {
            Picker("Engine", selection: Bindable(model).choice) {
                ForEach(TranscribeModel.EngineChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isListening)
            .padding(.horizontal)

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
