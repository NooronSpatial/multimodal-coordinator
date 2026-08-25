import MultiModalKit
import MultiModalKitBench
import MultiModalKitTTS
import SwiftUI
import TTSKit

/// THE BENCH TAB — the instruments.
///
/// The probes used to live in the one screen's toolbar, beside the
/// conversation they were measuring. They are here now because a
/// measurement should not share a screen with something animating: D-066
/// F-1's whole argument.
///
/// **The triggers are still in a toolbar, and that is not a style choice.**
/// A button in the old bottom strip did not fire on synthetic taps in the
/// simulator while the Download button in the same build did. Rather than
/// ship a control that could not be proven to work, the trigger moved to
/// where taps are proven to fire — and that constraint travels with it.
///
/// The voice levers (AC-143) and the sweep (AC-146) arrive here next.
struct BenchTab: View {
    let model: TranscribeModel
    let mindProbe: MindProbe
    @State private var showMindProbe = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    levers
                    Divider()
                    sweep

                    if model.probeSilence == nil && model.probeStatus == nil
                        && model.shieldStatus == nil && model.shieldReport.isEmpty {
                        ContentUnavailableView(
                            "Nothing measured yet",
                            systemImage: "gauge.with.needle",
                            description: Text("Run a probe from the toolbar. "
                                + "Each one answers a single question and "
                                + "writes its numbers here."))
                            .padding(.top, 40)
                    }

                    // The probe's RESULTS live in the body; its trigger is in
                    // the toolbar, for the tap reason above.
                    if model.probeSilence != nil || model.probeStatus != nil {
                        echoProbeResults
                            .padding(.horizontal)
                    }

                    if model.shieldStatus != nil || !model.shieldReport.isEmpty {
                        Divider()
                        // A SCROLL VIEW, from the field: matrix v2's eight
                        // witness columns outgrew the old strip and pushed
                        // the last arrangements off screen — a report you
                        // cannot read is a dead instrument with extra steps.
                        // A whole tab is more room than it ever had.
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
                    }
                }
                .padding(.vertical, 10)
            }
            .navigationTitle("Bench")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // THE PRESSURE PROBE (4i, AC-132). Deliberately loads the
                // pair the app otherwise refuses, because the refusal is
                // what makes it unmeasurable. Its log is written to disk
                // line by line, so a jetsam kill still leaves the trail.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.runPressureProbe() }
                    } label: {
                        Label("Pressure probe", systemImage: "gauge.with.needle")
                    }
                    .disabled(model.isListening)
                }
                // THE MIND PROBE (4f, AC-110/AC-111): it measures a SYSTEM
                // service, so it is reachable whatever the models are doing.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMindProbe = true
                    } label: {
                        Label("Mind probe", systemImage: "brain")
                    }
                    .disabled(model.isListening)
                }
                // THE SHIELD PROBE (4g, AC-119).
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
        }
    }

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


    /// THE FOUR LEVERS (AC-143), and the line that says what is really on.
    private var levers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice levers").font(.headline)

            HStack {
                Text("Model").font(.subheadline)
                Spacer()
                Picker("Model", selection: Bindable(model).levers.model) {
                    Text("0.6B").tag(TTSModelVariant.qwen3TTS_0_6b)
                    Text("1.7B").tag(TTSModelVariant.qwen3TTS_1_7b)
                }
                .labelsHidden()
            }
            if model.levers.model == .qwen3TTS_1_7b {
                Text("The 1.7B has never been measured on this device. It is "
                     + "~3× the parameters, so expect a DOWNLOAD first and a "
                     + "slower decode — watch the RTF line in Settings.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Text("Decoder").font(.subheadline)
                Spacer()
                Picker("Decoder", selection: Bindable(model).levers.decoder) {
                    Text("stepped").tag(Qwen3MultiCodeDecoderMode.stepped)
                    Text("fused").tag(Qwen3MultiCodeDecoderMode.fused)
                }
                .labelsHidden()
            }
            // `.fused` is OFFERED even though it cannot load here (D-066
            // F-2). Hiding it would teach nobody why the library's own
            // default is missing; choosing it produces the real CoreML
            // refusal, which is evidence rather than a claim.
            if model.levers.decoder == .fused {
                Text("`.fused` does not load on iOS 18+. Selecting it here is "
                     + "how you see the refusal rather than read about it.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Text("Vocoder").font(.subheadline)
                Spacer()
                Picker("Vocoder", selection: Bindable(model).levers.vocoder) {
                    Text("latency").tag(Qwen3SpeechDecoderMode.latencyOptimized)
                    Text("throughput").tag(Qwen3SpeechDecoderMode.throughputOptimized)
                }
                .labelsHidden()
            }

            HStack {
                Text("Temperature").font(.subheadline)
                Spacer()
                Picker("Temperature", selection: Bindable(model).levers.temperature) {
                    Text("model default").tag(Float?.none)
                    Text("0").tag(Float?.some(0))
                    Text("0.7").tag(Float?.some(0.7))
                }
                .labelsHidden()
            }
            if model.levers.temperature == 0 {
                Text("Temperature 0 had the fastest first audio of all six "
                     + "configurations on the Mac — and the worst sound, "
                     + "rambling for twice as long.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Cushion").font(.subheadline)
                Spacer()
                Picker("Cushion", selection: Bindable(model).levers.lead) {
                    Text("derived").tag(Duration?.none)
                    Text("0 ms").tag(Duration?.some(.zero))
                    Text("400 ms").tag(Duration?.some(.milliseconds(400)))
                    Text("1300 ms").tag(Duration?.some(.milliseconds(1300)))
                }
                .labelsHidden()
            }
            Text("Leave the cushion derived unless you are testing it. "
                 + "Derived means this phone's own measurement once it has "
                 + "one, and the decoder's constant until then.")
                .font(.caption).foregroundStyle(.secondary)

            // AC-144. The refusal survives the recovery: the voice went
            // back to what worked, and this is the only record of what was
            // asked for and what the system said about it.
            if let refusal = model.leverRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }

            Divider()

            // READ FROM THE VOICE, never from the pickers above. They
            // disagree whenever an apply has not landed — which is exactly
            // when a person is looking at this line to find out why.
            VStack(alignment: .leading, spacing: 2) {
                Text("In force").font(.caption).foregroundStyle(.secondary)
                Text(model.voiceInForce)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.voiceInForce.contains("fused")
                                     ? .orange : .primary)
            }
        }
        .padding(.horizontal)
    }

    /// THE SWEEP (AC-146 … AC-151).
    private var sweep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sweep").font(.headline)
                Spacer()
                if model.sweepRunning {
                    Button("Stop", role: .destructive) { model.stopSweep() }
                } else {
                    Button("Run") { model.runSweep() }
                        .buttonStyle(.borderedProminent)
                        // Like every other instrument here (D-054's shape):
                        // the trigger is unavailable while the pipeline runs.
                        .disabled(model.isListening)
                }
            }

            Text("Four configurations, three runs each. `.fused` is not among "
                 + "them: a sweep that included a decoder known not to load "
                 + "here would spend a third of its time measuring a failure "
                 + "we already understand.")
                .font(.caption).foregroundStyle(.secondary)

            if model.sweepRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("\(model.sweepProgress) of \(model.sweepTotal)")
                        .font(.caption.monospaced())
                }
            }

            // AC-146: it refuses, and says why, rather than dying.
            if let refusal = model.sweepRefusal {
                Label(refusal, systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.sweepRows.isEmpty {
                // The table EXACTLY as it will be pasted, so what is read on
                // the phone and what lands in INSTRUMENTS cannot differ.
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(model.sweepMarkdown)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = model.sweepMarkdown
                } label: {
                    Label("Copy as markdown", systemImage: "doc.on.doc")
                }
                .font(.caption)
                Text("Paste it into INSTRUMENTS beside the Mac's numbers — "
                     + "same columns, same shape, so the comparison is not "
                     + "done by eye.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
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

}
