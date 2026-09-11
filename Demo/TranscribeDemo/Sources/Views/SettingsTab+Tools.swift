// `SettingsTab`, continued: the tool spike's switch (4w).
//
// Its own file for the reason `SettingsTab+Memory.swift` is: the tab's
// body sits at the house's 250-line limit, and an extension is the
// honest way to add a row without raising it.

import SwiftUI

extension SettingsTab {
    /// The Tools switch, and the sentence that makes the phone run an
    /// experiment rather than a hope.
    @ViewBuilder
    var toolsSection: some View {
        // TOOLS (4w, F-3 = C). Read when the session starts — the
        // generator is built then, with its tools (F-2 = A) — so it is
        // disabled while listening, like the mind picker above it.
        HStack {
            Text("Tools").font(.subheadline)
            Spacer()
            Toggle("Tools", isOn: Bindable(model).toolsEnabled)
                .labelsHidden()
                .disabled(model.isListening)
        }
        // OFF is the plain path AC-227 measures against; ON hands both
        // real minds the session stub. The caption carries THE SENTENCE
        // because the spike measured the small model calling the tool
        // only when the question names it, and NEVER on a system
        // instruction alone — and it carries the OTHER half of the same
        // finding (the 4w demo review): beside this app's spoken
        // instruction the 0.6B did NOT call even when named (0/3). The
        // whole record is the suite note of `MLXToolLiveTests.swift`
        // (INSTRUMENTS §67 once written, per SPEC §172c). So the caption
        // promises no call; it says what was measured and points at the
        // log, where the phone's own answer is written per turn.
        Text(model.toolsEnabled
             ? "on · both minds get the session tool · say: "
               + "\u{201C}\(SessionStub.sentenceToSay)\u{201D} "
               + "· the log records each call · \(SessionStub.measuredNote)"
             : "off · the plain path, AC-227's baseline · no tool spec in the prompt")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
