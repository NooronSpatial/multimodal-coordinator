/// The platform's audio session, as a seam (SPEC AC-93, D-042 F-1 = B).
///
/// On macOS the pipeline owns the microphone until it stops. On iOS it
/// owns nothing: a call, Siri, a vanished route or a backgrounded app can
/// end capture underneath a running graph — and playing a reply while
/// recording needs a category, a mode, options, and a choice between the
/// loudspeaker and the earpiece.
///
/// Every one of those values is POLICY, and policy belongs to the app
/// (D-027). What is NOT policy is the ORDER:
///
/// ```
///   activate()          ← before anything captures
///   engine starts
///        … running …
///   engine stops
///   deactivate()        ← after everything has stopped
/// ```
///
/// Getting that order wrong — deactivating while the engine runs,
/// activating twice, configuring after the tap is installed so the format
/// shifts underneath it — is not a compile error. It is a strange bug on
/// a device. Before this seam existed the ordering was guaranteed by
/// nobody: the iOS demo made those calls by hand and the library simply
/// trusted that they had happened.
///
/// So the library calls the steps; the app supplies their contents.
/// `nil` means "no session to manage" — byte-for-byte the pre-4d capture
/// path, the D-028/D-036/D-039 precedent — which is also what macOS
/// wants, since it has no `AVAudioSession` at all.
public protocol AudioSessionConfiguring: Sendable {
    /// Configure and activate. Throwing here means capture must NOT be
    /// attempted: the caller reports the failure instead of starting a
    /// graph into a session that was never made ready.
    func activate() throws

    /// Release the session. Deliberately non-throwing: this runs on the
    /// teardown path, often while something else is already going wrong,
    /// and a failure to release must never mask the original problem or
    /// leave the caller unable to finish stopping.
    func deactivate()
}
