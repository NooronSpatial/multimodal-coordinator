import SwiftUI

struct ContentView: View {
    @State private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            List {
                Section("state") { stateRow }
                if case .ready = model.phase { controls } else if isSpeaking { controls }
                if !model.rows.isEmpty { results }
                Section("what this measures") {
                    Text("RTF = decode wall time ÷ audio produced. **Lower is better**; "
                         + "1.00 is exactly real time. This phone's Qwen3 mouth measured "
                         + "**1.21** — slower than speech, which is why every cushion in "
                         + "the library exists.")
                    .font(.footnote)
                    Text("Kokoro is one-shot: it returns a whole sentence at once, so "
                         + "\"time to first audio\" and \"decode time\" are the same number.")
                    .font(.footnote)
                }
            }
            .navigationTitle("Kokoro spike")
            .task { if case .loading = model.phase { await model.loadModel() } }
        }
    }

    private var isSpeaking: Bool {
        if case .speaking = model.phase { return true }
        return false
    }

    @ViewBuilder private var stateRow: some View {
        switch model.phase {
        case .needsAssets:
            VStack(alignment: .leading, spacing: 8) {
                Text("The weights are not on this phone yet.")
                Text("\(model.modelSizeText) over the network, once. Wi-Fi.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Download the model") { Task { await model.fetchAssets() } }
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let name, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.footnote.monospaced())
                ProgressView(value: fraction)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .loading:
            Label("loading the weights…", systemImage: "hourglass")
        case .ready:
            Label("ready", systemImage: "checkmark.circle")
        case .speaking(let fixture):
            Label("decoding \(fixture)…", systemImage: "waveform")
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var controls: some View {
        Section("run") {
            Toggle("play the last run aloud", isOn: $model.speakAloud)
            Button("Measure both sentences") { Task { await model.runAll() } }
                .disabled(isSpeaking)
        }
    }

    @ViewBuilder private var results: some View {
        Section("runs") {
            ForEach(model.rows) { row in
                HStack {
                    Text(row.fixture).frame(width: 52, alignment: .leading)
                    Text(row.counted ? "counted" : "warm-up")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Spacer()
                    Text(String(format: "%.0f ms", row.wallMilliseconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(String(format: "RTF %.2f", row.realTimeFactor))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(row.realTimeFactor < 1 ? .green : .red)
                }
            }
        }
        Section("memory") {
            // The first field run sounded excellent and was then killed.
            // A speed number with no memory beside it is half a report.
            if let peak = model.peakMegabytes {
                LabeledContent("MLX peak", value: "\(peak) MB")
            }
            if let headroom = model.headroomMegabytes {
                LabeledContent("headroom left", value: "\(headroom) MB")
            } else {
                Text("headroom: the platform will not say — 0 means both "
                     + "\"no information\" and \"already over the limit\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("MLX cache limit",
                           value: "\(KokoroEngine.cacheLimitBytes / 1_048_576) MB")
        }
        Section("median of the counted runs") {
            ForEach(SpikeModel.fixtures, id: \.name) { fixture in
                if let median = model.medianRTF(of: fixture.name) {
                    HStack {
                        Text(fixture.name)
                        Spacer()
                        Text(String(format: "%.2f", median))
                            .font(.body.monospacedDigit().bold())
                            .foregroundStyle(median < 1 ? .green : .red)
                    }
                }
            }
            ShareLink(item: model.report) { Label("Copy the table out", systemImage: "square.and.arrow.up") }
        }
    }
}
