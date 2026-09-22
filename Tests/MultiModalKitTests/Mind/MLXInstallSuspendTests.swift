import Foundation
import Testing
@testable import MultiModalKitMLX

/// AC-298 (SPEC §203) — the old truth updated: the mind's transfer runs
/// on the library's BACKGROUND session, and the source says so.
///
/// From 4x to 4z this suite guarded the opposite (AC-251, D-106's
/// F-3 = A): it read the module's source and failed if a background
/// session ever appeared under a doc comment that said "this download
/// dies when the app leaves the foreground". D-114 reversed that ruling
/// — F-1 = A, F-3 = A — and the reason is measured, not argued: the
/// client's own background switch crashes the process
/// (`docs/evidence/5a/probes/probe1.out.txt`), so the transfer became
/// `ModelDownloader`'s. So the needles flip: the default fetcher must go
/// THROUGH the downloader, the doc comment must say the transfer
/// survives the background and what a stopped one keeps, and the Hub
/// client's crashing switch must still appear nowhere.
///
/// A STATEMENT CAN DRIFT AWAY FROM THE CODE, which is the only reason
/// these rows exist; they are cheap, and they catch the one regression a
/// unit test cannot — somebody putting the foreground fetcher back as
/// the default because it was simpler.
///
/// The suite is skipped, with its reason on the trait, when the package
/// sources are not where `#filePath` says they are — a binary run from
/// somewhere else can honestly say nothing about source it cannot read.
@Suite("AC-298 · the transfer survives the background, and the source says so",
       .enabled(if: MLXModuleSource.isReadable,
                "the MultiModalKitMLX sources are not readable from this run"))
struct MLXInstallSuspendTests {

    /// F-3 = A, enforced at the one line that chooses: the default
    /// fetcher `download(reporting:)` builds. `HubWeightsFetcher` may
    /// stay in the module — it does, for the callers who had it — but it
    /// may not be the default again.
    @Test("the default fetcher is the background one, and it moves bytes through ModelDownloader")
    func theDefaultFetcherIsTheBackgroundOne() throws {
        let sources = try MLXModuleSource.files()
        #expect(sources.count >= 5, "the scan must actually have read the module")
        let install = try #require(sources["LocalMindInstall.swift"])
        #expect(install.contains("using: BackgroundWeightsFetcher())"),
                "the default download goes through the background fetcher")
        #expect(!install.contains("using: HubWeightsFetcher())"),
                "and never through the foreground one — that is the regression this row exists for")
        let fetcher = try #require(sources["BackgroundWeightsFetcher.swift"])
        #expect(fetcher.contains("downloader.transfer("),
                "the background fetcher hands its plan to ModelDownloader")
        #expect(fetcher.contains("ModelDownloader"), "and names it")
    }

    /// The Hub client's switch is still the wrong door: it builds a
    /// background session and then calls the async convenience on it,
    /// which the system refuses with an exception (Fact 1). Turning it on
    /// is one argument in this module's own source, and a crash on the
    /// first download.
    @Test("the hub client's crashing background switch is asked for nowhere in the MLX module")
    func theClientsBackgroundSwitchIsNeverTurnedOn() throws {
        let sources = try MLXModuleSource.files()
        #expect(sources.keys.contains("WeightsFetching.swift"), "the file that builds the client must be scanned")
        for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
            let asked = "\(name) turns the hub client's background-session flag on — "
                + "on this OS that is NSGenericException on the first transfer, not a background download"
            #expect(!text.contains("useBackgroundSession"), Comment(rawValue: asked))
        }
    }

    /// The other half: the sentence is actually there, and it is the new
    /// one. A doc comment that quietly kept the old truth would leave a
    /// caller disabling its idle timer for a transfer that no longer
    /// needs it, and telling a person to keep the app open for nothing.
    @Test("the download's doc comment states that the transfer survives the background, and what a stopped one keeps")
    func theDocCommentCarriesTheNewTruth() throws {
        let sources = try MLXModuleSource.files()
        let install = try #require(sources["LocalMindInstall.swift"])
        #expect(install.contains("WHILE THE APP IS SUSPENDED"),
                "AC-292: the transfer goes on while the app is suspended")
        #expect(install.contains("resumes from there"),
                "AC-293: what a stopped transfer keeps, and that the next call resumes")
        #expect(!install.contains("This download\n    /// dies when the app leaves the foreground"),
                "the 4x sentence is gone, not merely contradicted")
    }
}

/// The module's own source, on disk. `#filePath` is this file's path at
/// COMPILE time, so four steps up is the package root whenever the tests
/// are built from the package — which is how CI and this Mac run them.
enum MLXModuleSource {
    static let directory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()    // Mind
        .deletingLastPathComponent()    // MultiModalKitTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // the package root
        .appending(path: "Sources/MultiModalKitMLX")

    static var isReadable: Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    /// Every Swift file in the module, keyed by its path BELOW the module
    /// directory — so a top-level file is still just its name.
    ///
    /// THE WALK IS RECURSIVE, and the 4x review was right to ask. This
    /// used one non-recursive `contentsOfDirectory`, while the row above
    /// it claims "anywhere in the MLX module". The claim held only because
    /// `Sources/MultiModalKitMLX` happens to be flat today: the day
    /// somebody adds a subdirectory, a `URLSessionConfiguration.background`
    /// inside it would pass unseen, the suite would stay green, and the
    /// doc comment F-3 = A rests on would quietly become a lie. A test
    /// whose name is wider than its reach is worse than no test.
    static func files() throws -> [String: String] {
        let root = directory.standardizedFileURL
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UnreadableModule.cannotEnumerate(root.path)
        }
        var found: [String: String] = [:]
        for case let url as URL in walk where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            let key = path.hasPrefix(root.path + "/")
                ? String(path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            found[key] = try String(contentsOf: url, encoding: .utf8)
        }
        return found
    }

    /// A directory the suite's own `.enabled(if:)` said was readable and
    /// that then would not open. Its own error so the failure names the
    /// path instead of arriving as an empty scan that proves nothing.
    enum UnreadableModule: Error { case cannotEnumerate(String) }
}
