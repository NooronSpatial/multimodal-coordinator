import Foundation
import Testing

// THE RULES THE PRIVACY PROOFS ARE MADE OF (4x, SPEC §181/6–7, AC-253,
// AC-254, AC-255).
//
// Separated from the suites that use them, and not only because the file
// grew. Each of these is a RULE, and 4x's adversarial review showed that
// a rule exercised only against today's `Sources/` can never be shown to
// bite: the first host scanner passed every real run and still let a
// credential-bearing URL through. A rule that lives in its own type can
// be run over text a test writes itself, which is the only way to prove
// it fails when it should.
//
// `PackageOnDisk` is the other half: one reader for this repository's own
// files, so two suites ask the same question the same way.

// MARK: - the host scanner (AC-253)

/// Reads text and answers "which hosts does this text name?".
///
/// PURE, and separated from the file walking on purpose: the rule this
/// milestone actually needs proven is "a NEW host makes the suite red",
/// and that rule can only be demonstrated over text a test writes
/// itself. Run over the real `Sources/` the scanner finds what is there
/// today, which proves the document is current but never proves the
/// guard bites.
enum SourceHostScanner {

    /// Every host named after `http://` or `https://`, lowercased, with
    /// any port, user info, query and fragment removed.
    ///
    /// COMMENTS ARE SCANNED TOO, and that is the rule rather than a
    /// limitation. A host written in a doc comment is a host a reader of
    /// this library will believe it can reach, so it belongs in the list
    /// — under "named, never contacted" if that is the truth.
    ///
    /// PARSED, NOT WALKED (4x's review). The first version scanned
    /// characters up to a stop set, and that set held `:` but not `@`,
    /// `?` or `#`. So `https://user:pw@telemetry.example.test/` scanned
    /// as the host `user`, and `https://a.test?id=42` as the host
    /// `a.test?id=42`. `URLComponents` already knows where a host ends;
    /// hand-rolling that knowledge was the bug.
    static func hosts(in text: String) -> Set<String> {
        var found: Set<String> = []
        for mark in ["http://", "https://"] {
            var from = text.startIndex
            while let hit = text.range(of: mark, range: from..<text.endIndex) {
                // A URL literal in source ends at whitespace, a quote or a
                // bracket — none of which may appear unescaped in a URL.
                let token = text[hit.lowerBound...].prefix { !"\\\"'`<>(),;{}[] \t\n".contains($0) }
                // A trailing full stop is a sentence's, not a host's.
                let trimmed = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if let host = URLComponents(string: trimmed)?.host?.lowercased(), !host.isEmpty {
                    found.insert(host)
                }
                from = hit.upperBound
            }
        }
        return found
    }

    /// The hosts in `text` that the document does not DECLARE. The whole
    /// point of AC-253: this is non-empty exactly when somebody added a
    /// host and did not write it down.
    ///
    /// A DECLARATION, NOT PROSE, and 4x's review is why. This used to ask
    /// `document.contains(host)`, so a brand-new `gingface.co` was
    /// "documented" by the `huggingface.co` already on the page, and the
    /// host `user` — which the old parser produced from a URL carrying a
    /// password — was "documented" by the page's own words "no user
    /// info". A substring test over prose cannot tell a host from a
    /// syllable. A list can.
    static func undocumented(in text: String, against document: String) -> Set<String> {
        hosts(in: text).subtracting(FencedList.named("hosts", in: document))
    }
}

// MARK: - a page's machine-readable half

/// A fenced block in a markdown page, read as a list.
///
/// WHY A PAGE CARRIES ONE AT ALL. Twice in 4x a prose claim passed a test
/// that was checking for words rather than for meaning: a host hidden
/// inside a longer host, and a sentence CLEARING three fetches of a
/// credential using the same words a sentence accusing them would use.
/// Prose is for the reader; the block beside it is what the test reads,
/// and the two disagreeing is itself a failure worth having.
enum FencedList {
    static func named(_ tag: String, in document: String) -> [String] {
        let lowered = document.lowercased()
        guard let open = lowered.range(of: "```" + tag + "\n") else { return [] }
        let rest = lowered[open.upperBound...]
        guard let close = rest.range(of: "```") else { return [] }
        return rest[..<close.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - the required-reason cross-check (AC-255)

/// Which required-reason categories a module must declare and does not,
/// and which it declares and does not use.
///
/// PURE, for the same reason `SourceHostScanner` is: the rule that
/// matters — "a call may not appear without the category" — can only be
/// demonstrated over text a test writes itself.
enum RequiredReasonCheck {
    /// BOTH DIRECTIONS, and the first cut only managed one and a half.
    /// Its second loop asserted that the source names NO required-reason
    /// API at all, whatever a manifest declared — so a module that did
    /// the correct thing (call the API *and* declare the category) went
    /// red, and was told to declare what it had already declared. The
    /// rule is a PAIR: a call needs a category, and a category needs a
    /// call.
    static func mismatches(source: String, declared: Set<String>, triggers: [String: [String]])
    -> (undeclared: [String], unused: [String]) {
        var undeclared: [String] = []
        var unused: [String] = []
        for (category, symbols) in triggers {
            let uses = symbols.contains { source.contains($0) }
            if uses, !declared.contains(category) { undeclared.append(category) }
            if declared.contains(category), !uses { unused.append(category) }
        }
        return (undeclared.sorted(), unused.sorted())
    }
}

// MARK: - what Package.swift declares (AC-255)

/// The library targets a consumer can link, and which of them declare a
/// privacy manifest as a resource — read from `Package.swift` itself.
enum ManifestDeclarations {

    /// Every target reachable through a `.library` product, in the order
    /// the manifest names them.
    ///
    /// READ, NOT LISTED (4x's review). The first cut kept a hand-written
    /// array of six module names and compared its COUNT to the number of
    /// `.copy("PrivacyInfo.xcprivacy")` lines. That guard could not fail
    /// for the regression it exists to prevent: a seventh library product
    /// shipping no manifest left the count at six and was never looked
    /// at, while a seventh that correctly shipped one turned the suite
    /// red. A count also cannot see WHICH target a `.copy` sits on, so
    /// six declarations on the wrong six targets passed.
    static func linkedTargets(in manifest: String) -> [String] {
        var found: [String] = []
        var from = manifest.startIndex
        while let hit = manifest.range(of: ".library(", range: from..<manifest.endIndex) {
            let tail = manifest[hit.upperBound...]
            from = hit.upperBound
            guard let list = tail.range(of: "targets:"),
                  let open = tail.range(of: "[", range: list.upperBound..<tail.endIndex),
                  let close = tail.range(of: "]", range: open.upperBound..<tail.endIndex)
            else { continue }
            for name in quoted(in: String(tail[open.upperBound..<close.lowerBound]))
            where !found.contains(name) { found.append(name) }
        }
        return found
    }

    /// The linked targets whose OWN target block carries no
    /// `.copy("PrivacyInfo.xcprivacy")`. A manifest that is not declared
    /// as a resource never reaches the consumer's app.
    static func withoutADeclaredManifest(in manifest: String) -> [String] {
        var declaring: Set<String> = []
        for block in targetBlocks(in: manifest)
        where block.body.contains(".copy(\"PrivacyInfo.xcprivacy\")") {
            declaring.insert(block.name)
        }
        return linkedTargets(in: manifest).filter { !declaring.contains($0) }
    }

    /// Each target declaration, as its name and its text. The three
    /// markers never nest and never overlap, so a block runs from its own
    /// marker to the next one.
    private static func targetBlocks(in manifest: String) -> [(name: String, body: String)] {
        var starts: [String.Index] = []
        for marker in [".target(", ".executableTarget(", ".testTarget("] {
            var from = manifest.startIndex
            while let hit = manifest.range(of: marker, range: from..<manifest.endIndex) {
                starts.append(hit.lowerBound)
                from = hit.upperBound
            }
        }
        starts.sort()
        var blocks: [(String, String)] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : manifest.endIndex
            let body = String(manifest[start..<end])
            guard let label = body.range(of: "name:"),
                  let name = quoted(in: String(body[label.upperBound...])).first
            else { continue }
            blocks.append((name, body))
        }
        return blocks
    }

    /// Every double-quoted run in a fragment, in order.
    private static func quoted(in fragment: String) -> [String] {
        fragment.components(separatedBy: "\"")
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map(\.element)
    }
}

// MARK: - this repository, read from disk

/// One reader for the package's own files, shared by both privacy
/// suites so neither grows a private copy that can drift.
enum PackageOnDisk {

    // MARK: finding this package on disk

    /// The repository root, from this file's own path.
    ///
    /// `nil` when the layout is not what it was — and every test that
    /// needs the disk then says so and stops, rather than passing on an
    /// empty reading. A green test that read no files is the lying
    /// instrument this project keeps finding (`MLXMindLiveTests` says the
    /// same about its own gates).
    static let packageRoot: URL? = {
        var url = URL(filePath: #filePath)
        // …/Tests/MultiModalKitTests/Diagnostics/NetworkSilenceTests.swift
        for _ in 0..<4 { url = url.deletingLastPathComponent() }
        let manifest = url.appending(path: "Package.swift")
        return FileManager.default.fileExists(atPath: manifest.path) ? url : nil
    }()

    /// Every `.swift` file under `Sources/`, read into one string with
    /// its path in front of it, so a failure can name the file.
    static func sourceText() -> String? {
        guard let root = packageRoot else { return nil }
        let sources = root.appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(atPath: sources.path) else { return nil }
        var text = ""
        for case let name as String in walk where name.hasSuffix(".swift") {
            let file = sources.appending(path: name)
            guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text += "\n// ===== \(name) =====\n" + body
        }
        return text.isEmpty ? nil : text
    }

    /// The same walk as `sourceText()`, split by the module folder each
    /// file sits in — so a required-reason category can be checked
    /// against the target whose manifest declares it.
    static func sourcesByModule() -> [String: String] {
        guard let root = packageRoot else { return [:] }
        let sources = root.appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(atPath: sources.path) else { return [:] }
        var byModule: [String: String] = [:]
        for case let name as String in walk where name.hasSuffix(".swift") {
            guard let module = name.split(separator: "/").first.map(String.init) else { continue }
            guard let body = try? String(contentsOf: sources.appending(path: name), encoding: .utf8)
            else { continue }
            byModule[module, default: ""] += "\n// ===== \(name) =====\n" + body
        }
        return byModule
    }

    static func read(_ relativePath: String) -> String? {
        guard let root = packageRoot else { return nil }
        return try? String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    /// The skip that says so — `MLXMindLiveTests`' verb, for the same
    /// reason: Swift Testing has no skip here, so the least dishonest
    /// thing available is to print what was not proven.
    ///
    /// FOR AN ENVIRONMENT GATE ONLY. A missing `MMK_MLX_MODEL` is a fact
    /// about the machine; an unreadable `Sources/` is a broken
    /// instrument, and 4x's review found three privacy proofs using this
    /// verb for the second case — they turned GREEN when they had read
    /// nothing. Those now call `Issue.record`, like the sibling that
    /// already did it for a missing `docs/HOSTS.md`.
    static func skipping(_ what: String) -> Bool {
        print("SKIPPED (\(what)) — this test proved NOTHING on this run")
        return true
    }

    /// The library products a consumer can link, and therefore the ones
    /// that need a manifest (F-4 = A, AC-255). The executables are not on
    /// this list: nobody links a demo.
    ///
    /// READ FROM `Package.swift`, after 4x's review: a hand-written list
    /// here could not notice a SEVENTH library product, which is the one
    /// regression this criterion exists to catch.
    static func linkedModules() -> [String] {
        ManifestDeclarations.linkedTargets(in: read("Package.swift") ?? "")
    }

    /// Apple's required-reason API categories, and the symbols in THIS
    /// package's languages that trigger them. Not a complete copy of
    /// Apple's list — a complete list of what code here could plausibly
    /// call.
    static let triggers: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "creationDateKey", "contentModificationDateKey", "attributeModificationDateKey",
            ".creationDate", ".modificationDate", "NSFileCreationDate", "NSFileModificationDate",
            "getattrlist", "fstatat(", "lstat("
        ],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "volumeTotalCapacity", "NSFileSystemFreeSize",
            "NSFileSystemSize", "systemFreeSize", "statfs(", "statvfs("
        ],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults(", "UserDefaults.standard", "NSUserDefaults"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes", "UITextInputMode"]
    ]

    static func plist(forModule module: String) -> [String: Any]? {
        guard let root = packageRoot,
              let data = try? Data(contentsOf: root.appending(path: "Sources/\(module)/PrivacyInfo.xcprivacy")),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return any as? [String: Any]
    }
}
