// `SettingsTab`, continued: the mind picker (4f), moved here in 4w.
//
// Its own file for the reason `SettingsTab+Memory.swift` is: the tab's
// body sits at the house's 250-line limit, and the Tools row (4w) put it
// one line over. Moving the mind's own row out — the row the memory and
// tools rows sit under — is the split that keeps the three together and
// the body honest. The row itself is unchanged.

import SwiftUI

extension SettingsTab {
    /// The mind picker, exactly as it was in the body.
    @ViewBuilder
    var mindSection: some View {
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
    }
}
