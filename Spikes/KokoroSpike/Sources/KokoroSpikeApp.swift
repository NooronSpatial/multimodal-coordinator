import SwiftUI

/// The Kokoro spike's entry point (Milestone 4p, D-082).
///
/// A throwaway instrument with one question: on Ryad's phone, does this
/// decoder run faster than speech? Everything else — voices, languages,
/// streaming, integration — is deliberately absent. See the README beside
/// this file for why it is a separate Xcode project and not a product of
/// the root package.
@main
struct KokoroSpikeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
