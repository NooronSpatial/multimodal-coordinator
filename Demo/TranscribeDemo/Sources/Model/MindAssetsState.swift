import Observation

/// WHAT THE LOCAL MIND'S WEIGHTS ARE DOING (4h).
///
/// Three properties about one thing — are the weights here, are they
/// coming, and did asking fail. They sat forty lines apart in
/// `TranscribeModel`, so the download's progress and the sentence
/// explaining a failed download were in different neighbourhoods.
@MainActor
@Observable
final class MindAssetsState {
    /// Fraction complete while the weights come down, or nil.
    var downloadProgress: Double?

    /// STICKY on purpose, and it exists because of a field report:
    /// "downloading is not starting after i klick the button". The old
    /// version reported only through `downloadProgress`, so a failure
    /// BEFORE the first progress callback showed as a flicker and the
    /// button coming back — visually identical to the tap doing nothing.
    /// A silent failure and an ignored tap must never look the same.
    /// `refreshMind()` deliberately does not clear this.
    var downloadStatus: String?

    /// Why the local mind cannot be used here, or nil.
    var unavailable: String?

}
