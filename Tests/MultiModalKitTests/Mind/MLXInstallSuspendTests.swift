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

    /// F-3 = A, enforced. `URLSessionConfiguration.background` is the one
    /// spelling that turns a foreground download into a background one,
    /// so its absence is what makes the doc comment true.
    @Test("no background URLSession is built anywhere in the MLX module")
    func noBackgroundSessionInThisModule() throws {
        let sources = try MLXModuleSource.files()
        #expect(sources.count >= 5, "the scan must actually have read the module")
        #expect(sources.keys.contains("LocalMindInstall.swift"),
                "the file the claim is about must be among the ones scanned")
        for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
            // The words are built first because a `Comment` takes one
            // literal, and this sentence is longer than a line.
            let broken = "\(name) builds a background session — F-3 = A says this library STATES "
                + "the suspend truth instead, so the doc comment above it would now be a lie"
            #expect(!text.contains("URLSessionConfiguration.background"), Comment(rawValue: broken))
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
