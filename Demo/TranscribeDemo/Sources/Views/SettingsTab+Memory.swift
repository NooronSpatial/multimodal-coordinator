// `SettingsTab`, continued: memory across turns (4r).
//
// Its own file because `SettingsTab` had reached the house's 250-line
// body limit — an extension is not counted, and splitting is the honest
// fix where raising the limit would be the quiet one.

import SwiftUI

extension SettingsTab {
    /// The memory lever, and the sentence that makes it a measurement.
    @ViewBuilder
    var memorySection: some View {
        // MEMORY ACROSS TURNS (4r, AC-197). Read when the session starts,
        // so it cannot change under a live conversation — hence disabled
        // while listening, like the mind picker above it.
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
        // History is PREFILL, and after D-092 the price is a NUMBER:
        // ~0.68 ms of felt pause per character on this phone (§58b). The
        // 600-character budget is what actually bites, so printing the
        // depth alone would suggest the depth is what costs.
        Text(model.memoryDepth == 0
             ? "off · each question is answered on its own, as before 4r"
             : "up to \(model.memoryDepth) exchanges, capped at 600 characters "
               + "· about +400 ms of felt pause at most (measured)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
