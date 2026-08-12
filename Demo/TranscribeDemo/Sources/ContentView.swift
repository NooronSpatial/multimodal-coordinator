import SwiftUI

struct ContentView: View {
    @State private var model = TranscribeModel()

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
                case .failed(let reason):
                    failed(reason)
                case .ready:
                    transcriber
                }
            }
            .navigationTitle("MultiModalKit")
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
