import MultiModalKit

/// KOKORO'S OWN PAUSES (5d piece 2; F-33 A, D-138).
///
///     today, every boundary:   …words][~421 ms tail][~325 ms lead][words…   ≈ 746 ms
///     kept:                    …words][the mark's pause − margin][margin][words…
///
/// Measured on this Mac by `bakeoff kokoro-pauses`
/// (docs/evidence/5d/kokoro-pauses-2026-10-01.txt): twenty whole sentences,
/// one clause mark each, synthesized as ONE utterance — the longest quiet
/// inside the words, below the meter's level. That is the pause Kokoro makes
/// at the mark when it reads straight through; a phrase boundary keeps the
/// same, and no more. A cap cut (no mark) keeps only the two margins.
///
/// Starting numbers, not a law: Ryad's ear decides at the ear gate (AC-353),
/// and a changed number is a D-entry.
extension PhraseQuiet.Config {
    public static let kokoro: PhraseQuiet.Config = {
        let margin = Duration.milliseconds(40)
        // What the person hears at a boundary that closes on each mark.
        let heard: [Character: Duration] = [
            ",": .milliseconds(137), ".": .milliseconds(185), "?": .milliseconds(204),
            "!": .milliseconds(109), ":": .milliseconds(201), ";": .milliseconds(206)
        ]
        // The tail kept after the last loud sample; the next phrase adds its margin.
        return PhraseQuiet.Config(margin: margin, pauses: heard.mapValues { $0 - margin })
    }()
}
