import MultiModalKit
import SwiftUI

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
