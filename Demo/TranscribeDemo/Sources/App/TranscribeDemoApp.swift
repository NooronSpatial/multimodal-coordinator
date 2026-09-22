import MultiModalKit
import SwiftUI
import UIKit

@main
struct TranscribeDemoApp: App {
    /// THE ONE LINE AN APP WRITES FOR BACKGROUND DOWNLOADS (5a, AC-297,
    /// AC-300). SwiftUI has no hook for
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
    /// so the delegate below exists for that single method — and the
    /// delegate's body is one call into the library.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// What the system calls when a download this app started finishes while
/// the app is suspended or dead.
///
/// The system relaunches the app in the background, hands over the
/// session's identifier and a completion handler, and expects the
/// handler to be called once the session has delivered everything it was
/// holding. `ModelDownloads.handleEvents` does exactly that: it answers
/// `false` for a session that is not the library's (so an app with its
/// own background sessions keeps them), and otherwise waits for the
/// session's own "events finished" before calling back.
///
/// Nothing else in this app knows about background sessions. That is the
/// shape the library owes a caller: one line here, and a percentage on
/// the Models tab.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // UIKit hands this over as a plain closure, and the library asks
        // for a `@Sendable` one — it calls back on the main actor after
        // the session has delivered its events, from a task. The box is
        // the bridge, and it is sound for the reason the system's
        // contract gives: the handler is called EXACTLY once, and only
        // from the main thread.
        let box = UncheckedHandler(completionHandler)
        let handled = ModelDownloads.handleEvents(forBackgroundURLSession: identifier) {
            box.call()
        }
        if !handled { completionHandler() }
    }
}

/// A one-shot main-thread callback, carried across the `@Sendable`
/// boundary UIKit does not give us.
private final class UncheckedHandler: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func call() {
        MainActor.assumeIsolated { handler() }
    }
}
