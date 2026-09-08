// `SettingsTab`, continued: the language (4u).
//
// Its own file for the reason `SettingsTab+Memory.swift` is: the tab's
// body sits at the house's 250-line limit, and an extension is not
// counted. Splitting is the honest fix where raising the limit would be
// the quiet one.

import SwiftUI

extension SettingsTab {
    /// The language lever and, for Arabic, the sentence that says which
    /// organs carry it.
    @ViewBuilder
    var languageSection: some View {
    // THE LANGUAGE (4u). Read when Listen starts, like the ear.
    HStack {
        Text("Language").font(.subheadline)
        Spacer()
        Picker("Language", selection: Bindable(model).language) {
            ForEach(TranscribeModel.LanguageChoice.allCases) { language in
                Text(language.rawValue).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(model.isListening)
    }
    .padding(.horizontal)
    if model.language == .arabic {
        Text("Arabic runs on Whisper small, the Local mind and Apple's voice — "
             + "the only organs that have it. Measured in INSTRUMENTS §62.")
            .font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
    }
}
