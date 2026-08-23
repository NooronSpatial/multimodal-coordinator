import MultiModalKit
import SwiftUI

/// THE CHAT TAB — the transcript, the turn, and the button that starts it.
///
/// Was the whole app: one 884-line screen holding the conversation, every
/// picker and every probe. D-066 F-1 split it three ways, because a live
/// meter redrawing at 60 Hz and a stopwatch have no business sharing a
/// screen — the bench must not be timing itself while it animates.
///
/// What stayed here is what a person watches while talking. The pickers went
/// to Settings, the probes to Bench.
struct ChatTab: View {
    let model: TranscribeModel

    var body: some View {
        NavigationStack {
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
                    talking
                }
            }
            .frame(maxHeight: .infinity)
            // NO TITLE (Ryad): a large title spent a third of a phone
            // screen saying the app's own name to the person who just
            // opened it.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // THE CONVERSATION LOG, still reachable from the tab a
                // person is in when something goes wrong. It carries the
                // brain that ACTUALLY answered each turn, which is the one
                // fact a screenshot cannot show.
                //
                // NEVER disabled on "no turns": the worst failures — a mind
                // that refuses at the door, a session that never started —
                // produce ZERO turns, which is exactly when the header is
                // the evidence worth sending.
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: model.conversationLog) {
                        Label("Share the conversation", systemImage: "text.bubble")
                    }
                }
            }
        }
    }

    /// The ready state: what was `transcriber`, with the settings scroll
    /// lifted out of it and into its own tab.
    private var talking: some View {
        VStack(spacing: 12) {
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
                // WATCH THE IDENTITY, NOT THE ARRAY.
                //
                // `utterances` changes on every partial transcription
                // result — many times a second while a person speaks — and
                // each change fired an ANIMATED scroll. Several landed in
                // one frame and SwiftUI said so: "onChange(of:
                // Array<Utterance>) action tried to update multiple times
                // per frame." Watching the last id coalesces that to one
                // scroll per NEW utterance, which is the only moment the
                // target actually moves.
                .onChange(of: model.utterances.last?.id) {
                    guard let last = model.utterances.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            statusBar

            // AC-132's readout, live. The whole of 4i turns on this
            // number, and it costs one syscall to look at.
            if let mb = MemoryHeadroomReader.read().megabytes {
                Text("memory headroom: \(mb) MB")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(mb < 400 ? AnyShapeStyle(Color.orange)
                                              : AnyShapeStyle(.secondary))
            }

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
                      // ANY mind that cannot answer, not just Apple's.
                      // The review found the Local mind able to start a
                      // session in which every single turn fails at the
                      // door — a dead conversation that looks alive.
                      || (model.talkEnabled && model.mind != .echo
                          && model.mindUnavailable != nil)
                      // Measured, not feared: 2239 MB + 1112 MB = 3351 MB,
                      // and jetsam killed exactly this on the phone.
                      || model.memoryConflict != nil)
            .padding(.horizontal)
            .padding(.bottom, 8)
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
