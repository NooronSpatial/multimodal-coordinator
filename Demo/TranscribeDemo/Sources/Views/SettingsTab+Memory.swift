// `SettingsTab`, continued: memory across turns (4r).
//
// Its own file because `SettingsTab` had reached the house's 250-line
// body limit — an extension is not counted, and splitting is the honest
// fix where raising the limit would be the quiet one.

import SwiftUI

extension SettingsTab {
    /// The memory lever and the sentence that makes it a measurement.
    @ViewBuilder
    var memorySection: some View {
        // MEMORY ACROSS TURNS (4r, AC-197). Read when the
        // session starts, so it cannot change under a live
        // conversation — hence disabled while listening, like
        // the mind above it.
        HStack {
    Text("Memory").font(.subheadline)
    Spacer()
    Picker("Memory", selection: Bindable(model).memoryDepth) {
        Text("off").tag(0)
        ForEach([2, 4, 6, 8], id: \.self) { depth in
            Text("\(depth) turns").tag(depth)
        }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .disabled(model.isListening)
        }
        // History is PREFILL: every remembered exchange
        // lengthens the prompt the mind reads before its first
        // token, and the felt pause is the number this project
        // has spent three milestones on. Saying so here is what
        // makes the picker a measurement rather than a taste.
        Text(model.memoryDepth == 0
     ? "off · each question is answered on its own, as before 4r"
     : "the mind sees the last \(model.memoryDepth) exchanges "
       + "· costs felt pause, measured on this phone")
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)

    }
}
