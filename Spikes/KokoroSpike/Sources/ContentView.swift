import SwiftUI

struct ContentView: View {
    @State private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            List {
                Section("state") { stateRow }
                if canRun { controls }
                if !model.rows.isEmpty { results }
                Section("what this measures") {
                    Text("RTF = decode wall time ÷ audio produced. **Lower is better**; "
                         + "1.00 is exactly real time. In the live app, Qwen3 measured "
                         + "**1.21** on this phone — slower than speech, which is why "
                         + "every cushion in the library exists.")
                    .font(.footnote)
                    Text("Both mouths run through the same stopwatch and the same memory "
                         + "sampler, in this one process, back to back. Kokoro is "
                         + "one-shot, so its \"time to first audio\" and its decode time "
                         + "are the same number.")
                    .font(.footnote)
                    Text("Peak is this PROCESS's footprint, sampled every "
                         + "\(FootprintSampler.intervalMilliseconds) ms. A spike shorter "
                         + "than that is invisible, so a peak is a floor, never a ceiling.")
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Two mouths")
            .task { if case .loadingKokoro = model.phase { await model.loadModel() } }
        }
    }

    private var isBusy: Bool {
        switch model.phase {
        case .speaking, .loadingQwen, .downloading, .loadingKokoro: true
        default: false
        }
    }

    private var canRun: Bool {
        if case .ready = model.phase { return true }
        if case .speaking = model.phase { return true }
        if case .loadingQwen = model.phase { return true }
        return false
    }

    @ViewBuilder private var stateRow: some View {
        switch model.phase {
        case .needsAssets:
            VStack(alignment: .leading, spacing: 8) {
                Text("Kokoro's weights are not on this phone yet.")
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
        case .loadingKokoro:
            Label("loading Kokoro's weights…", systemImage: "hourglass")
        case .loadingQwen:
            VStack(alignment: .leading, spacing: 4) {
                Label("fetching and loading Qwen3-TTS…", systemImage: "hourglass")
                Text("~1 GB, and this app has its own container — the demo's copy "
                     + "cannot be borrowed. Once per install.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            Label("ready", systemImage: "checkmark.circle")
        case .speaking(let mouth, let fixture):
            Label("\(mouth) — decoding \(fixture)…", systemImage: "waveform")
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var controls: some View {
        Section("Kokoro weights") {
            Picker("precision", selection: Binding(
                get: { model.precision },
                set: { new in Task { await model.reload(at: new) } })) {
                    ForEach(WeightPrecision.allCases, id: \.self) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
            if let bytes = model.precision.bytes {
                LabeledContent("on disk", value: "\(bytes / 1_048_576) MB")
            }
            Text("There is no half-precision Kokoro to download — the "
                 + "`bf16` repository is fp32 in disguise (548 F32 tensors, "
                 + "the same 327,115,152 bytes). These are cast on this phone, "
                 + "once each.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        Section("run") {
            Toggle("play the last run aloud", isOn: $model.speakAloud)
            Toggle("also measure Qwen3-TTS (~1 GB download)", isOn: $model.includeQwen)
            Button("Compare the two mouths") { Task { await model.runAll() } }
                .disabled(isBusy)
            Button("Length sweep — six rungs, Kokoro only") {
                Task { await model.runLadder() }
            }
            .disabled(isBusy)
        }
    }

    @ViewBuilder private var results: some View {
        ForEach(model.mouthNames, id: \.self) { mouth in
            Section(mouth) {
                ForEach(model.rows.filter { $0.mouth == mouth }) { row in
                    HStack {
                        Text(row.fixture).frame(width: 40, alignment: .leading)
                        Text(String(format: "%.1fs", row.audioMilliseconds / 1000))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Spacer()
                        // Peak OVER rest: the transient cost of using the
                        // model, with the cost of merely holding it taken
                        // out. That difference is the ladder's question.
                        Text("+\((row.footprintPeakBytes - row.footprintBaselineBytes) / 1_048_576)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text("\(row.footprintPeakBytes / 1_048_576) MB")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(String(format: "%.2f", row.realTimeFactor))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(row.realTimeFactor < 1 ? .green : .red)
                    }
                }
                ForEach(SpikeModel.fixtures, id: \.name) { fixture in
                    if let median = model.medianRTF(mouth: mouth, fixture: fixture.name) {
                        HStack {
                            Text("median \(fixture.name)").bold()
                            Spacer()
                            Text(String(format: "%.2f", median))
                                .font(.body.monospacedDigit().bold())
                                .foregroundStyle(median < 1 ? .green : .red)
                        }
                    }
                }
                if let peak = model.peakMegabytes(mouth: mouth) {
                    LabeledContent("peak footprint", value: "\(peak) MB")
                }
            }
        }
        Section("this phone") {
            if let headroom = model.headroomMegabytes {
                LabeledContent("headroom left", value: "\(headroom) MB")
            } else {
                Text("headroom: the platform will not say — 0 means both "
                     + "\"no information\" and \"already over the limit\".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("MLX cache limit",
                           value: "\(KokoroEngine.cacheLimitBytes / 1_048_576) MB")
            ShareLink(item: model.report) {
                Label("Copy the table out", systemImage: "square.and.arrow.up")
            }
        }
    }
}
