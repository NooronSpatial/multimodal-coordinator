import MultiModalKit
import SwiftUI

/// THE SETTINGS TAB — every picker, every toggle, every download.
///
/// Two things changed by moving here, and both are improvements rather than
/// side effects:
///
/// 1. **It is no longer capped at 300 points.** The scroll was squeezed
///    because it shared a screen with the transcript; controls you cannot
///    reach are controls you do not have, and that cap was the reason the
///    scroll existed at all.
/// 2. **It is reachable when the speech model is missing.** The old screen
///    hid everything behind `engineState == .ready`, so on a device where
///    the transcriber refused to install, the person could see a download
///    prompt and nothing else. The voice and the mind can be installed from
///    here now regardless of what the ear is doing.
struct SettingsTab: View {
    let model: TranscribeModel

    var body: some View {
        NavigationStack {
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
            // TALK BACK LIVES HERE TOO (the review). Everything below is
            // gated on it, and its only other control sits inside ChatTab's
            // ready state — so on a device where the speech model has not
            // installed, the voice and mind sections were unreachable,
            // including the very downloads that would fix it.
            HStack {
                Text("Talk back").font(.subheadline)
                Spacer()
                Toggle("Talk back", isOn: Bindable(model).talkEnabled)
                    .labelsHidden()
            }

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
                        // The model picker is gone (D-064): 4B is the local
                        // mind, full stop. A picker with one option is a
                        // control that cannot be used, and 0.6B's replies
                        // were bad enough that offering them as a
                        // "fallback" would have been shipping a worse
                        // product as a feature.
                        Text("local mind: 4B · \(TranscribeModel.LocalMind.sizeOnDisk) "
                             + "· on a Mac: \(TranscribeModel.LocalMind.macBehaviour)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // AC-131: the third mind never vanishes and never
                        // dies silently. On a simulator it says WHY it
                        // cannot run (D-061, structural); with no weights
                        // it offers the one action that fixes that.
                        Text(model.mindAssets.unavailable
                             ?? "local weights ready · answers never leave this device")
                            .font(.caption2)
                            .foregroundStyle(model.mindAssets.unavailable == nil
                                             ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(Color.orange))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The status line is ALWAYS shown once there is
                        // one, whether the download is running, finished
                        // or failed. A tap must never be able to look
                        // like nothing happened.
                        if let status = model.mindAssets.downloadStatus {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(status.contains("FAILED")
                                                 || status.contains("NOT usable")
                                                 ? AnyShapeStyle(Color.red)
                                                 : AnyShapeStyle(.secondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if let fraction = model.mindAssets.downloadProgress {
                            ProgressView(value: fraction)
                        } else if model.mindAssets.unavailable?.contains("not downloaded") == true {
                            Button("Download the local mind · \(TranscribeModel.LocalMind.sizeOnDisk)") {
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
                        Text(model.mindAssets.unavailable
                             ?? "on-device model ready · answers are spoken, one session per turn")
                            .font(.caption2)
                            .foregroundStyle(model.mindAssets.unavailable == nil
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
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
