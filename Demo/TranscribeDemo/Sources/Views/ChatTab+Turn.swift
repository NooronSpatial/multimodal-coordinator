import MultiModalKit
import SwiftUI

// `ChatTab` — the talk-back turn strip: the two toggles, the shield
// warning, the barge counters, the gate slider, the interrupted banner,
// and the turn state's own icon and label.
extension ChatTab {
    /// Milestone 4d on screen: the turn loop the Mac has had since 4a/4b,
    /// now on the phone — plus the two toggles the field run needs.

    var conversation: some View {
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
}
