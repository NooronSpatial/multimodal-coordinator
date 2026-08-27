import Foundation
import MultiModalKit
import TTSKit

// `NeuralVoice`, continued: the cushion arithmetic — the real-time
// factors measured per decoder mode, and the playback lead derived
// from them.
extension NeuralVoice {
    /// The steady real-time factor MEASURED for the default decoder
    /// (AC-106: `.fused`, release build, M-series Mac, median of three
    /// runs on a long sentence). Below 1.0 means the decoder produces
    /// audio faster than the ear drinks it.
    ///
    /// Named rather than inlined because it is the one input the lead
    /// below is derived from: measure a slower machine, change this,
    /// and the cushion reappears without anyone having to remember why.
    /// The iPhone is NOT measured yet — that is AC-104.
    public nonisolated static let measuredRealTimeFactor = 0.752

    /// The default lead, DERIVED rather than picked (D-047).
    ///
    /// The sizing rule is `replyLength × (RTF − 1)`, and at 0.752 it
    /// returns **zero**: the decoder runs ahead of the ear, so there is
    /// no shortfall to bank and no reason to make anyone wait. That is
    /// why this is zero today — not a preference, an arithmetic result.
    ///
    /// It was 1500 ms while the default decoder was `.stepped` at RTF
    /// 1.066–1.25, and it cost first audio 227 ms → 1882 ms (§11).
    /// D-046 ruled to attack the decode as well as buy the cushion, and
    /// attacking it is what made the cushion unnecessary.
    ///
    /// DEPRECATED, and the deprecation is the fix. This constant sits
    /// beside `defaultLead(for:)` and reads like the safe choice, so
    /// `bakeoff voice-spike` passed it explicitly — and an explicit lead
    /// defeats the derivation by design. The instrument built to compare
    /// the decoders measured `--stepped` with `.fused`'s cushion of
    /// nothing, directly under the comment below warning about exactly
    /// that. A test could not catch it: the bug was in an executable's
    /// `main.swift`, which the package suite cannot reach. A deprecation
    /// can, because CI builds every target with warnings-as-errors.
    @available(*, deprecated, message: """
        This is .fused's cushion, not a universal default. Pass lead: nil \
        to derive it from the decoder, or defaultLead(for:) to name a \
        mode. Passing this to .stepped reintroduces the slow-voice bug.
        """)
    public nonisolated static let defaultLead = PlaybackLead.deficit(
        forReplyOf: .seconds(6), realTimeFactor: measuredRealTimeFactor)

    /// THE LEAD MUST FOLLOW THE DECODER, and once it did not.
    ///
    /// `defaultLead` is derived from `measuredRealTimeFactor`, which is
    /// `.fused`'s 0.752 — below 1.0, so the deficit is zero and no cushion
    /// is banked. But the decoder mode is a SEPARATE parameter, and Swift
    /// cannot let one default argument read another. So a caller who asked
    /// for `.stepped` silently kept `.fused`'s cushion of nothing.
    ///
    /// It was measured immediately: `--mouth=neural` on a Mac, and the
    /// speech came out slow. RTF 1.066 means the decoder makes audio
    /// slower than the ear drinks it, so the player runs dry from the
    /// first buffer — which is D-046's finding, arriving again because the
    /// derivation was fed the wrong number.
    ///
    /// AC-106's measurements, per mode, so the rule can be applied rather
    /// than remembered.
    public nonisolated static func measuredRealTimeFactor(
        for mode: Qwen3MultiCodeDecoderMode
    ) -> Double {
        #if os(iOS)
        // iPhone cold decode runs at ~1.25-1.33x (INSTRUMENTS §22, §41).
        // Sizing for a nominal 6s reply gives ~1800ms lead to prevent Turn 1 buffer underruns.
        switch mode {
        case .fused: 1.30
        default: 1.33
        }
        #else
        switch mode {
        case .fused: 0.752      // AC-106 (Mac)
        default: 1.066          // AC-106, `.stepped` (Mac)
        }
        #endif
    }

    /// The cushion this decoder actually needs, derived not guessed.
    public nonisolated static func defaultLead(
        for mode: Qwen3MultiCodeDecoderMode
    ) -> Duration {
        PlaybackLead.deficit(forReplyOf: .seconds(6),
                             realTimeFactor: measuredRealTimeFactor(for: mode))
    }
}
