import Foundation
import Testing
@testable import MultiModalKitMLX

/// AC-251 (SPEC §181/4, Aura's L6) and D-106's F-3 = A: the suspend truth
/// is STATED, not engineered.
///
/// A background `URLSession` is what a 2.3 GB cellular download really
/// needs, and it is a different downloader, a delegate and a re-entry
/// path — a milestone of its own. So this library says plainly, in the
/// contract page and in `download(reporting:)`'s doc comment, that a
/// download dies when the app leaves the foreground, and the caller
/// decides what to do about it.
///
/// A STATEMENT CAN DRIFT AWAY FROM THE CODE, which is the only reason
/// these rows exist. They read the module's OWN source files from the
/// package directory and assert two things: that the doc still carries
/// the sentence, and that no background session was quietly added
/// underneath it. AC-251 asks for exactly this.
///
/// The suite is skipped, with its reason on the trait, when the package
/// sources are not where `#filePath` says they are — a binary run from
/// somewhere else can honestly say nothing about source it cannot read.
@Suite("AC-251 · the suspend truth, stated and not contradicted",
       .enabled(if: MLXModuleSource.isReadable,
                "the MultiModalKitMLX sources are not readable from this run"))
struct MLXInstallSuspendTests {

    /// F-3 = A, enforced — with the needle AC-251 asks for AND the one
    /// that can actually catch this module.
    ///
    /// AC-251 names `URLSessionConfiguration.background`, and that spelling
    /// is kept because the criterion asks for it. On its own it is a guard
    /// that cannot fire: this module never builds a `URLSession` at all.
    /// The transfer belongs to the Hub client, and the switch there is a
    /// PARAMETER with a safe default — `HubWeightsFetcher` gets the
    /// foreground session by writing `HubApi(downloadBase: base)` and
    /// naming nothing else. Turning it on is one argument, in this
    /// module's own source, and the original needle would not have seen
    /// it: the doc comment would have become a lie with the suite green.
    ///
    /// So the client's switch is the second needle. It is spelled here
    /// and NOWHERE in `Sources/MultiModalKitMLX` — the doc comment says
    /// "the client's background-session switch" in words for exactly that
    /// reason, because this row reads that file too.
    @Test("no background session is built or asked for anywhere in the MLX module")
    func noBackgroundSessionInThisModule() throws {
        let sources = try MLXModuleSource.files()
        #expect(sources.count >= 5, "the scan must actually have read the module")
        #expect(sources.keys.contains("LocalMindInstall.swift"),
                "the file the claim is about must be among the ones scanned")
        #expect(sources.keys.contains("WeightsFetching.swift"),
                "and so must the file that builds the client")
        for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
            // The words are built first because a `Comment` takes one
            // literal, and these sentences are longer than a line.
            let built = "\(name) builds a background session — F-3 = A says this library STATES "
                + "the suspend truth instead, so the doc comment above it would now be a lie"
            #expect(!text.contains("URLSessionConfiguration.background"), Comment(rawValue: built))
            let asked = "\(name) turns the hub client's background-session flag on — the same lie, "
                + "reached the way this module could really reach it: one argument, not a URLSession"
            #expect(!text.contains("useBackgroundSession"), Comment(rawValue: asked))
        }
    }

    /// The other half: the sentence is actually there. A doc comment that
    /// quietly disappeared would leave a caller with no warning at all,
    /// and no test would notice — this one does.
    @Test("the download's doc comment states what happens when the app leaves the foreground")
    func theDocCommentCarriesTheSuspendTruth() throws {
        let sources = try MLXModuleSource.files()
        let install = try #require(sources["LocalMindInstall.swift"])
        #expect(install.contains("leaves the foreground"),
                "AC-251: the suspend behaviour is stated in the doc comment")
        #expect(install.contains("the partial tree is deleted"),
                "and it says what a caller must do about it — F-2 = A means starting again")
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

    /// File name → contents, for every Swift file in the module.
    static func files() throws -> [String: String] {
        var found: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where name.hasSuffix(".swift") {
            found[name] = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        }
        return found
    }
}
