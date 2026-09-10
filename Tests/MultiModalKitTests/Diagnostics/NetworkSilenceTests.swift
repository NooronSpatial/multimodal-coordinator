import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX
@testable import MultiModalKitTTS

// THE PRIVACY HALF OF 4x, PROVEN RATHER THAN PROMISED (SPEC §181/6–7,
// AC-252, AC-253, AC-254, AC-255).
//
// Aura cannot tell a person "nothing about you was sent" on the strength
// of a README paragraph. §180 lists that sentence as UNSTATED and
// UNPROVEN, and this file is the proof half: one recorder that fails
// every request the library makes, one scanner that reads this package's
// own source for hosts, and one reader for the privacy manifests.
//
// NO TEST HERE TOUCHES THE NETWORK, and that is a design constraint
// rather than a hope. Only ONE request is ever issued — the control's,
// to `localhost` port 1, which this machine's own kernel refuses and
// which never leaves it even if the recorder is not consulted. Every
// other test asserts SILENCE: it runs a cycle and expects the recorder
// to have seen nothing. That asymmetry is deliberate. Driving a real
// weight fetch would prove more, and would download 2.3 GB the day the
// interception stopped working.

// MARK: - the recorder

/// Every request the URL Loading System offers it: recorded, then
/// FAILED. Nothing is ever sent.
///
/// `@unchecked Sendable` with the house proof: the only mutable state is
/// the `seen` array and it lives behind a `Mutex`; the instance stores
/// nothing this class adds. `URLProtocol` is not `Sendable`, so the
/// annotation is what lets a subclass of it be named from a `@Sendable`
/// context at all.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {

    /// What the loading system asked about, in arrival order.
    ///
    /// RECORDED IN `canInit`, not in `startLoading`, because `canInit` is
    /// the only hook that sees a request the protocol might decline. This
    /// one declines nothing, so the two would agree — but a query method
    /// with a side effect is worth naming rather than hiding, and the
    /// loading system may ask about the same request more than once. Both
    /// questions this file puts to the array ("was it empty?", "did it
    /// contain X?") are indifferent to a duplicate.
    private static let seen = Mutex<[URLRequest]>([])

    /// Anything this protocol claims dies here, with this error.
    enum Refusal: Error, Equatable { case noRequestMayLeaveThisTest }

    /// Clears the log and switches interception on. Paired with `stop()`
    /// through a `defer` at every call site, so a failing expectation
    /// cannot leave the process with a registered protocol.
    static func start() {
        seen.withLock { $0 = [] }
        URLProtocol.registerClass(RecordingURLProtocol.self)
    }

    /// Switches interception off and hands back what was seen. Safe to
    /// call twice — `unregisterClass` on an unregistered class is a
    /// no-op — which is what lets the `defer` above survive a test that
    /// already called it.
    @discardableResult
    static func stop() -> [URLRequest] {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        return seen.withLock { $0 }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        seen.withLock { $0.append(request) }
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: Refusal.noRequestMayLeaveThisTest)
    }

    override func stopLoading() {}
}

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
    /// any port and any trailing punctuation removed.
    ///
    /// COMMENTS ARE SCANNED TOO, and that is the rule rather than a
    /// limitation. A host written in a doc comment is a host a reader of
    /// this library will believe it can reach, so it belongs in the list
    /// — under "named, never contacted" if that is the truth.
    static func hosts(in text: String) -> Set<String> {
        var found: Set<String> = []
        for mark in ["http://", "https://"] {
            var from = text.startIndex
            while let hit = text.range(of: mark, range: from..<text.endIndex) {
                let raw = text[hit.upperBound...].prefix { !"/\\\"'`<>(),;:{}[] \t\n".contains($0) }
                let host = String(raw).lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
                if !host.isEmpty { found.insert(host) }
                from = hit.upperBound
            }
        }
        return found
    }

    /// The hosts in `text` that `document` does not mention. The whole
    /// point of AC-253: this is non-empty exactly when somebody added a
    /// host and did not write it down.
    static func undocumented(in text: String, against document: String) -> Set<String> {
        let lowered = document.lowercased()
        return hosts(in: text).filter { !lowered.contains($0) }
    }
}

// MARK: - the suite

/// AC-252 · AC-253 · AC-254 · AC-255 — what leaves the device, named and
/// proven.
///
/// `.serialized` because `URLProtocol.registerClass` is PROCESS-global.
/// Two tests recording at once would see each other's requests, and the
/// silence proofs would be reading somebody else's traffic.
@Suite("4x · the network, named and proven", .serialized, .timeLimit(.minutes(2)))
struct NetworkSilenceTests {

    // MARK: finding this package on disk

    /// The repository root, from this file's own path.
    ///
    /// `nil` when the layout is not what it was — and every test that
    /// needs the disk then says so and stops, rather than passing on an
    /// empty reading. A green test that read no files is the lying
    /// instrument this project keeps finding (`MLXMindLiveTests` says the
    /// same about its own gates).
    private static let packageRoot: URL? = {
        var url = URL(filePath: #filePath)
        // …/Tests/MultiModalKitTests/Diagnostics/NetworkSilenceTests.swift
        for _ in 0..<4 { url = url.deletingLastPathComponent() }
        let manifest = url.appending(path: "Package.swift")
        return FileManager.default.fileExists(atPath: manifest.path) ? url : nil
    }()

    /// Every `.swift` file under `Sources/`, read into one string with
    /// its path in front of it, so a failure can name the file.
    private static func sourceText() -> String? {
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

    private static func read(_ relativePath: String) -> String? {
        guard let root = packageRoot else { return nil }
        return try? String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    /// The skip that says so — `MLXMindLiveTests`' verb, for the same
    /// reason: Swift Testing has no skip here, so the least dishonest
    /// thing available is to print what was not proven.
    private static func skipping(_ what: String) -> Bool {
        print("SKIPPED (\(what)) — this test proved NOTHING on this run")
        return true
    }

    /// The library products a consumer can link, and therefore the ones
    /// that need a manifest (F-4 = A, AC-255). The executables are not on
    /// this list: nobody links a demo.
    private static let linkedModules = [
        "MultiModalKit", "MultiModalKitMLX", "MultiModalKitWhisper",
        "MultiModalKitTTS", "MultiModalKitTesting", "MultiModalKitBench"
    ]

    // MARK: - AC-252 · the silence, and the instrument that proves it real

    /// THE CONTROL, and without it every silence test below is worthless.
    /// `URLProtocol.registerClass` affects the shared session and
    /// sessions built on a default configuration; if a future OS stops
    /// consulting it, `#expect(seen.isEmpty)` would pass because nothing
    /// was ever OFFERED, not because nothing was sent. So one request is
    /// made on purpose and the recorder must have seen it.
    ///
    /// The address is `localhost` port 1. If interception has broken, the
    /// connection is refused by this machine's own kernel and no packet
    /// reaches any network — the one request in this file that is allowed
    /// to be made is also the one that cannot go anywhere.
    @Test("the recorder sees a request that IS made — the control for every silence proof")
    func theRecorderIsReallyIntercepting() async {
        let target = URL(string: "http://localhost:1/multimodal-coordinator-control")!
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        do {
            _ = try await URLSession.shared.data(from: target)
            Issue.record("a request to localhost:1 must not succeed")
        } catch {
            // Refused — by the recorder, or by the kernel. Which one it
            // was is exactly what the expectation below decides.
        }
        let seen = RecordingURLProtocol.stop()
        #expect(seen.contains { $0.url == target },
                "the recorder saw nothing — interception is OFF, so every silence test here is vacuous")
    }

    /// AC-252, the half that runs on EVERY machine: with weights on disk,
    /// every question this library answers about an install is answered
    /// from the disk. No metadata ping, no revision check, nothing.
    ///
    /// It is a weaker claim than the gated test below and it is the one
    /// CI actually runs, so it is worth being exact about its reach:
    /// constructing the model, `installState()`, `modelInstalled()`,
    /// `expectedBytes()`, `estimatedWorkingSetBytes()`, `readiness()` and
    /// constructing the generator. That is every door Aura's download
    /// screen touches before a person taps anything.
    @Test("an offline install cycle issues ZERO requests")
    func askingAboutAnInstallIssuesNoRequest() throws {
        let weights = try Self.makeFakeWeightTree()
        defer { try? FileManager.default.removeItem(at: weights.deletingLastPathComponent()) }

        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let model = LocalMindModel(weights: weights)
        let state = model.installState()
        let installed = model.modelInstalled()
        let expected = model.expectedBytes()
        let working = model.estimatedWorkingSetBytes()
        _ = model.readiness()
        _ = MLXReplyGenerator(model: model)
        let seen = RecordingURLProtocol.stop()

        #expect(state == .installed, "the fake tree must read as a verified install")
        #expect(installed)
        #expect(expected != nil, "a manifest is on disk, so the total is known")
        #expect(working > 0)
        let urls = seen.compactMap { $0.url?.absoluteString }.joined(separator: ", ")
        #expect(seen.isEmpty, "the install questions issued \(seen.count) request(s): \(urls)")
    }

    /// AC-252, the half that needs a real model — gated the way every
    /// live test in this repo is (`MLXMindLiveTests`, D-061): the weights
    /// through `MMK_MLX_MODEL`, and `MLXRuntime.isAvailable`, because
    /// without a `default.metallib` MLX aborts the PROCESS rather than
    /// failing a test.
    ///
    /// WHAT THIS PROVES AND WHAT IT DOES NOT. `URLProtocol` sees traffic
    /// that goes through `URLSession`'s shared session and through
    /// sessions built on a DEFAULT configuration. It does NOT see a raw
    /// BSD socket, a `Network.framework` connection, a session built with
    /// an EPHEMERAL or BACKGROUND configuration, or anything a system
    /// daemon does out-of-process on this app's behalf. So a green run
    /// here means "no request went out through the ordinary path" — which
    /// is the path both weight fetches in this package use — and never
    /// "no byte left this device".
    @Test("a REAL load-and-generate cycle issues ZERO requests")
    func aRealReplyIssuesNoRequest() async throws {
        guard let weights = Self.liveWeights else { _ = Self.skipping("no MMK_MLX_MODEL"); return }
        guard MLXRuntime.isAvailable else { _ = Self.skipping("no default.metallib"); return }

        let mind = MLXReplyGenerator(model: LocalMindModel(weights: weights))
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let reply = try await mind.reply(to: ReplyContext(
            transcript: "say hello",
            options: GenerationOptions(maxTokens: 8, temperature: 0)))
        let seen = RecordingURLProtocol.stop()

        #expect(!reply.text.isEmpty)
        let urls = seen.compactMap { $0.url?.absoluteString }.joined(separator: ", ")
        #expect(seen.isEmpty, "a load-and-generate cycle issued \(seen.count) request(s): \(urls)")
    }

    private static var liveWeights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A tree `installState()` calls `.installed`: the three files the
    /// offline-capability rule demands, one `.safetensors`, and the
    /// manifest a complete download would have written.
    private static func makeFakeWeightTree() throws -> URL {
        let base = URL(filePath: NSTemporaryDirectory())
            .appending(path: "mmk-silence-\(UUID().uuidString)", directoryHint: .isDirectory)
        let weights = base.appending(path: "model", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        var sizes: [String: Int64] = [:]
        let tree = [("config.json", "{}"), ("tokenizer.json", "{}"),
                    ("tokenizer_config.json", "{}"), ("model.safetensors", "not really weights")]
        for (name, body) in tree {
            let data = Data(body.utf8)
            try data.write(to: weights.appending(path: name))
            sizes[name] = Int64(data.count)
        }
        try InstallManifest(files: sizes).write(in: weights)
        return weights
    }

    // MARK: - AC-253 · the host list, checked against the source

    /// THE GUARD ITSELF, over text this test writes. If somebody adds a
    /// host tomorrow and does not document it, THIS is the rule that goes
    /// red — and a rule exercised only against today's `Sources/` can
    /// never be shown to bite.
    @Test("the scanner reports a host the document does not name")
    func anUndocumentedHostIsReported() {
        let sample = """
        let a = URL(string: "https://huggingface.co/repo/resolve/main/x.safetensors")!
        let b = URL(string: "https://telemetry.example.test/v1/events")!
        """
        let document = "This library contacts huggingface.co and nothing else."
        #expect(SourceHostScanner.hosts(in: sample) == ["huggingface.co", "telemetry.example.test"])
        #expect(SourceHostScanner.undocumented(in: sample, against: document) == ["telemetry.example.test"])
        #expect(SourceHostScanner.undocumented(in: sample, against: document + " telemetry.example.test").isEmpty)
    }

    /// Ports and trailing punctuation are not part of a host name — a
    /// scanner that thought otherwise would demand `huggingface.co,` in
    /// the document and go red over a comma.
    @Test("a host is a host: ports and trailing punctuation are stripped")
    func theScannerNormalisesWhatItFinds() {
        #expect(SourceHostScanner.hosts(in: "see https://huggingface.co.") == ["huggingface.co"])
        #expect(SourceHostScanner.hosts(in: "http://localhost:50060/v1") == ["localhost"])
        #expect(SourceHostScanner.hosts(in: "(https://HuggingFace.co/x)") == ["huggingface.co"])
        #expect(SourceHostScanner.hosts(in: "no url here").isEmpty)
    }

    /// AC-253 over the real thing: every host this package's own source
    /// names must appear in `docs/HOSTS.md`.
    @Test("every host in Sources/ is named in docs/HOSTS.md")
    func everyHostInSourceIsDocumented() throws {
        guard let source = Self.sourceText() else { _ = Self.skipping("Sources/ not readable"); return }
        guard let document = Self.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-253 has no list to check against")
            return
        }
        let missing = SourceHostScanner.undocumented(in: source, against: document).sorted()
        #expect(missing.isEmpty,
                "named in Sources/ and NOT in docs/HOSTS.md: \(missing.joined(separator: ", "))")
    }

    /// The other direction, and the reason the list is a DOCUMENT rather
    /// than a generated file: the host the weight fetch actually reaches
    /// is named by no literal in this package at all. It comes from the
    /// vendored hub client's default. A list built by grepping `Sources/`
    /// would have missed the single most important host in this library.
    @Test("the list names the hub the MLX weight fetch reaches, which no literal in Sources/ names")
    func theListNamesTheHubNoLiteralNames() throws {
        guard let document = Self.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-253 has no list to check against")
            return
        }
        guard let mlx = Self.read("Sources/MultiModalKitMLX/LocalMindInstall.swift") else {
            _ = Self.skipping("LocalMindInstall.swift not readable"); return
        }
        #expect(document.lowercased().contains("huggingface.co"))
        #expect(SourceHostScanner.hosts(in: mlx).isEmpty,
                "this file reaches the hub and names no host — which is exactly why the list is hand-written")
    }

    // MARK: - AC-254 · no identifier, no credential

    /// The weight URLs this library holds carry NOTHING about the caller:
    /// no query string, no user info, no fragment. A download that
    /// appended an install id would show up here.
    @Test("the weight URLs carry no identifier — no query, no user, no fragment")
    func theWeightURLsSayNothingAboutTheCaller() {
        for url in [KokoroWeights.sourceURL, KokoroWeights.voiceURL] {
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(parts?.query == nil, "\(url.lastPathComponent) carries a query string")
            #expect(parts?.user == nil)
            #expect(parts?.password == nil)
            #expect(parts?.fragment == nil)
            #expect(url.scheme == "https", "a weight download must not be plain http")
        }
    }

    /// AC-254's PROVEN half for this library's own code: neither fetch
    /// path builds a request with a credential on it, and no module here
    /// reads a device or user identifier.
    ///
    /// SOURCE-READ, NOT HEADER-READ, and the reason is in this file's
    /// opening note: asserting on a REAL request's headers means making a
    /// real request, and the day interception breaks that is a 2.3 GB
    /// download inside `swift test`. What is checked here cannot drift
    /// silently — the symbols below are the only ways to attach one.
    @Test("no module supplies a credential or reads an identifier")
    func theLibrarySuppliesNoCredentialAndReadsNoIdentifier() throws {
        guard let source = Self.sourceText() else { _ = Self.skipping("Sources/ not readable"); return }
        let forbidden = [
            "setValue(\"Bearer",             // a bearer token on a request
            "addValue(\"Bearer",
            "httpAdditionalHeaders",         // a credential hidden in a session
            "identifierForVendor",           // the device id
            "advertisingIdentifier",
            "SecItemCopyMatching",           // the keychain
            "hfToken",                       // the hub's own credential argument
            "HF_TOKEN"
        ]
        for symbol in forbidden {
            #expect(!source.contains(symbol),
                    "Sources/ names `\(symbol)` — AC-254 says the fetch carries no credential, no identifier")
        }
    }

    /// The ARGUED half, pinned so it cannot be quietly dropped: the
    /// vendored hub client resolves a token from the DEVELOPER's
    /// environment when this library passes none, and `docs/HOSTS.md`
    /// must say so. That document's caveat section has what it means and
    /// why it cannot reach a person's phone.
    @Test("the host list states the credential caveat AC-254 cannot prove away")
    func theListStatesTheCredentialCaveat() throws {
        guard let document = Self.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-254's caveat has nowhere to live")
            return
        }
        let lowered = document.lowercased()
        #expect(lowered.contains("hf_token"), "the caveat must name the environment variable")
        #expect(lowered.contains("authorization"), "the caveat must name the header it can produce")
    }

    // MARK: - AC-255 · the privacy manifests (F-4 = A)

    /// Every module a consumer links ships a `PrivacyInfo.xcprivacy`, and
    /// every one of them is DECLARED in `Package.swift`. A manifest that
    /// is not declared as a resource is a file in a folder: it never
    /// reaches the consumer's app, and the App Store never sees it.
    @Test("every linked module ships a privacy manifest, declared in Package.swift")
    func everyLinkedModuleShipsAManifest() throws {
        guard let manifestSwift = Self.read("Package.swift") else {
            _ = Self.skipping("Package.swift not readable"); return
        }
        for module in Self.linkedModules {
            let found = Self.read("Sources/\(module)/PrivacyInfo.xcprivacy")
            #expect(found != nil, "\(module) ships no PrivacyInfo.xcprivacy (AC-255, F-4 = A)")
        }
        let declared = manifestSwift.components(separatedBy: ".copy(\"PrivacyInfo.xcprivacy\")").count - 1
        #expect(declared == Self.linkedModules.count,
                "Package.swift declares \(declared) manifest resources, expected \(Self.linkedModules.count)")
    }

    /// What each manifest says: nothing collected, no tracking, no
    /// tracking domains.
    @Test("each manifest declares no collection and no tracking")
    func eachManifestCollectsNothing() throws {
        for module in Self.linkedModules {
            guard let plist = Self.plist(forModule: module) else {
                Issue.record("\(module)'s manifest is missing or is not a property list")
                continue
            }
            #expect(plist["NSPrivacyTracking"] as? Bool == false, "\(module) must declare no tracking")
            #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true,
                    "\(module) must collect nothing")
            #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true,
                    "\(module) must name no tracking domain")
        }
    }

    /// THE HALF THAT IS EASY TO GET WRONG IN THE OTHER DIRECTION. A
    /// manifest claiming a required-reason category the code does not use
    /// is as wrong as a missing one — it is an untrue statement filed with
    /// a store. So the categories are checked AGAINST the source: a
    /// category may be declared only when this package names an API that
    /// triggers it, and an API in use with no category declared is the
    /// missing-manifest bug. Today the answer to both is "none".
    @Test("a declared required-reason category is one the source actually uses")
    func noManifestClaimsAReasonTheCodeDoesNotUse() throws {
        guard let source = Self.sourceText() else { _ = Self.skipping("Sources/ not readable"); return }
        for module in Self.linkedModules {
            guard let plist = Self.plist(forModule: module) else { continue }
            let declared = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
            for category in declared {
                let triggers = Self.triggers[category] ?? []
                #expect(triggers.contains { source.contains($0) },
                        "\(module) declares \(category) and no source in this package names an API that uses it")
            }
        }
        for (category, symbols) in Self.triggers {
            let used = symbols.filter { source.contains($0) }.joined(separator: ", ")
            #expect(used.isEmpty,
                    "Sources/ now names \(used) — declare \(category), and write it into docs/HOSTS.md")
        }
    }

    /// Apple's required-reason API categories, and the symbols in THIS
    /// package's languages that trigger them. Not a complete copy of
    /// Apple's list — a complete list of what code here could plausibly
    /// call.
    private static let triggers: [String: [String]] = [
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

    private static func plist(forModule module: String) -> [String: Any]? {
        guard let root = packageRoot,
              let data = try? Data(contentsOf: root.appending(path: "Sources/\(module)/PrivacyInfo.xcprivacy")),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return any as? [String: Any]
    }
}
