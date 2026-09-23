import Foundation
import Synchronization

// THE RE-ENTRY DOOR (5a, SPEC §202, AC-297; D-114 F-1 = A).
//
// When a background transfer finishes while the app is dead, the
// system launches the app in the background and calls its delegate:
//
//     func application(_ application: UIApplication,
//                      handleEventsForBackgroundURLSession identifier: String,
//                      completionHandler: @escaping () -> Void) {
//         ModelDownloads.handleEvents(forBackgroundURLSession: identifier,
//                                     completionHandler: completionHandler)
//     }
//
// That one line is the whole of what an app does. The library then
// re-creates its session under the same identifier, the daemon hands
// the delegate every landing it has been holding, the files are moved
// into place, and the app's completion handler is called once the
// session says its events are done — on the main thread, as the
// system asks.

/// The library's background session, by name, and the door an app's
/// delegate hands the system's wake-up to.
public enum ModelDownloads {
    /// The identifier of the library's one background session — the
    /// app's bundle identifier, suffixed, so two apps on one phone never
    /// share a session and the system knows whom to wake.
    public static let sessionIdentifier: String =
        "\(Bundle.main.bundleIdentifier ?? "multimodal-coordinator").multimodal-coordinator.models"

    private static let cellular = Mutex(true)

    /// Whether transfers may use cellular data. The system's default is
    /// yes; an app that asks first sets this BEFORE its first transfer —
    /// the session is built once, on first use, and reads it then.
    public static func allowCellular(_ allowed: Bool) {
        cellular.withLock { $0 = allowed }
    }

    /// The app delegate's one line. Returns whether the identifier was
    /// this library's — `false` means the wake-up belongs to another
    /// session of the app's, and the handler was not touched.
    @discardableResult
    public static func handleEvents(forBackgroundURLSession identifier: String,
                                    completionHandler: @escaping @Sendable () -> Void) -> Bool {
        guard identifier == sessionIdentifier else { return false }
        Task { await ModelDownloader.shared.handleEvents(completion: completionHandler) }
        return true
    }

    /// The session's configuration: background, not discretionary (the
    /// person asked for the bytes), launch events on, cellular as set.
    ///
    /// **EXCEPT IN THE SIMULATOR, and that is measured rather than
    /// assumed.** The iOS Simulator has no background transfer daemon:
    /// every task on a background session fails at once with
    /// `NSURLErrorDomain Code=-1 "unknown error"`. The demo's Models
    /// screen showed it on the first run — the ear's 149 MB died on its
    /// first file — while the same URL on a background session on this
    /// Mac returned `200` and 243 bytes, and the same download in the
    /// simulator on a FOREGROUND session ran to 35 %, to `installed`,
    /// and deleted cleanly (`docs/evidence/5a/simulator-*.md`).
    ///
    /// So the simulator gets a foreground session, and what it loses is
    /// stated: a transfer there dies when the app is suspended, which is
    /// the only thing that platform can do. A device — the platform the
    /// milestone is FOR — keeps the background session and everything
    /// this milestone promises. The alternative was a simulator on which
    /// no model can be downloaded at all, which would make every
    /// developer's first run of this library a failure.
    static func backgroundConfiguration(identifier: String = sessionIdentifier) -> URLSessionConfiguration {
        #if targetEnvironment(simulator)
        let configuration = URLSessionConfiguration.default
        #else
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.allowsCellularAccess = cellular.withLock { $0 }
        return configuration
    }
}
