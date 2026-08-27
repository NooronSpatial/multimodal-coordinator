import MultiModalKitTTS
import SwiftUI
import TTSKit

// `BenchTab` — the voice levers (AC-143): the pickers that choose a
// configuration, the warnings that belong to particular choices, and
// the line that reads back what is actually in force.
extension BenchTab {
    /// Whether THIS device can have the big voice — asked once, of the
    /// vendor, which is the question the library's own guard now asks
    /// (AC-159). False on every iPhone and iPad; true on a Mac.
    private var largeModelAvailable: Bool {
        TTSModelVariant.qwen3TTS_1_7b.isAvailableOnCurrentPlatform
    }

    /// THE FOUR LEVERS (AC-143), and the line that says what is really on.
    var levers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice levers").font(.headline)

            HStack {
                Text("Model").font(.subheadline)
                Spacer()
                Picker("Model", selection: Bindable(model).levers.model) {
                    Text("0.6B").tag(TTSModelVariant.qwen3TTS_0_6b)
                    // VISIBLE AND UN-TAPPABLE on a device the vendor
                    // refuses (D-072 F-2 = B). Hiding it would teach
                    // nobody that a bigger voice exists; leaving it
                    // tappable — D-066's shape — would spend a failed
                    // 1417 MB compile to learn what TTSKit already says.
                    // That precedent's shape survives here, its reason
                    // does not: the `.fused` refusal was evidence this
                    // project NEEDED, and this one is already in hand.
                    Text(largeModelAvailable ? "1.7B" : "1.7B — macOS only")
                        .tag(TTSModelVariant.qwen3TTS_1_7b)
                        .selectionDisabled(!largeModelAvailable)
                }
                .labelsHidden()
            }
            if !largeModelAvailable {
                // OUR sentence, not CoreML's (AC-161). The field run got
                // "Failed to build the model execution plan … error code:
                // -14" — a symptom. This is the cause, from the vendor.
                Text("1.7B needs more memory than this device allows while "
                     + "compiling its CoreML plan — the vendor restricts it "
                     + "to macOS. The row stays so the bigger voice is not "
                     + "a secret.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.levers.model == .qwen3TTS_1_7b {
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
}
