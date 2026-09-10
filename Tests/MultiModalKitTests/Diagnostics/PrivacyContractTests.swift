import Foundation
import Testing
@testable import MultiModalKitTTS

// WHAT A REQUEST CARRIES, AND WHAT THE MANIFESTS SAY (4x, SPEC §181/6–7,
// AC-253, AC-254, AC-255).
//
// The other half of `NetworkSilenceTests`. That file proves SILENCE, and
// needs a process-global `URLProtocol` to do it. This one touches no
// network machinery at all: it reads this repository's own files and
// checks that what they claim about each other is true — the host list
// against `Sources/`, the credential caveat against the page, and the six
// privacy manifests against both `Package.swift` and the code.
//
// The rules themselves live in `PrivacyRules.swift`, so each can be run
// over text a test writes itself. 4x's review is why: a guard that has
// only ever been run against the real tree has never been shown to fail.

/// AC-253 · AC-254 · AC-255 — the host list, the credential caveat and
/// the privacy manifests, each checked against the source.
///
/// No `.serialized` here, and no time limit beyond the default: nothing
/// in this suite touches process-global state. Every test reads files.
@Suite("4x · the privacy contract, checked against the source")
struct PrivacyContractTests {

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
        // The document DECLARES its hosts in a fenced block. Prose that
        // merely mentions a name no longer counts — see
        // `theScannerIsNotWalkedPastByUserInfoOrASubstring` for the two
        // ways the old substring rule could be walked past.
        let document = """
        This library contacts huggingface.co and nothing else.

        ```hosts
        huggingface.co
        ```
        """
        let both = document.replacingOccurrences(of: "```hosts\nhuggingface.co",
                                                 with: "```hosts\nhuggingface.co\ntelemetry.example.test")
        #expect(SourceHostScanner.hosts(in: sample) == ["huggingface.co", "telemetry.example.test"])
        #expect(SourceHostScanner.undocumented(in: sample, against: document) == ["telemetry.example.test"])
        #expect(SourceHostScanner.undocumented(in: sample, against: both).isEmpty)
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
        guard let source = PackageOnDisk.sourceText() else {
            Issue.record("Sources/ is not readable — this privacy proof read NOTHING")
            return
        }
        guard let document = PackageOnDisk.read("docs/HOSTS.md") else {
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
        guard let document = PackageOnDisk.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-253 has no list to check against")
            return
        }
        guard let mlx = PackageOnDisk.read("Sources/MultiModalKitMLX/LocalMindInstall.swift") else {
            _ = PackageOnDisk.skipping("LocalMindInstall.swift not readable"); return
        }
        #expect(document.lowercased().contains("huggingface.co"))
        #expect(SourceHostScanner.hosts(in: mlx).isEmpty,
                "this file reaches the hub and names no host — which is exactly why the list is hand-written")
    }

    /// THE TWO WAYS THE FIRST SCANNER COULD BE WALKED PAST.
    ///
    /// 1. A CREDENTIAL HID THE HOST. The first version walked characters
    ///    and stopped at a set holding `:` but not `@`, so
    ///    `https://user:pw@telemetry.example.test/` scanned as the host
    ///    `user` — and `user` is a substring of this page's own prose
    ///    ("no user info", "user defaults"), so the undocumented check
    ///    then found nothing. A URL carrying a password could be added to
    ///    `Sources/` and AC-253 stayed green.
    /// 2. A SUBSTRING COUNTED AS DOCUMENTED. `undocumented` asked
    ///    `document.contains(host)`, so a brand-new `gingface.co` was
    ///    "documented" by the `huggingface.co` already on the page.
    ///
    /// `?` and `#` were not stop characters either, so a query string
    /// became part of the host name.
    @Test("a credential cannot hide a host, and a substring is not a match")
    func theScannerIsNotWalkedPastByUserInfoOrASubstring() {
        let credential = #"let u = URL(string: "https://user:pw@telemetry.example.test/v1/events")!"#
        #expect(SourceHostScanner.hosts(in: credential) == ["telemetry.example.test"])
        #expect(SourceHostScanner.undocumented(in: credential, against: Self.oneHostDeclared)
                == ["telemetry.example.test"])
        let near = #"let u = URL(string: "https://gingface.co/x")!"#
        #expect(SourceHostScanner.undocumented(in: near, against: Self.oneHostDeclared) == ["gingface.co"])
        #expect(SourceHostScanner.hosts(in: #"URL(string: "https://a.example.test?id=42")"#) == ["a.example.test"])
        #expect(SourceHostScanner.hosts(in: #"URL(string: "https://b.example.test#note")"#) == ["b.example.test"])
    }

    /// A document declaring exactly one host, in the fenced block the real
    /// page carries — and with the prose that used to make `user` match.
    private static let oneHostDeclared = """
    Prose about no user info, user defaults, and huggingface.co.

    ```hosts
    huggingface.co
    ```
    """

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
    ///
    /// STILL OWED, and named here rather than left to be discovered:
    /// AC-254 (SPEC §183) asks for "the request headers … asserted in a
    /// test against the FAKE FETCHER's recorded requests". That fake is
    /// `WeightsFetching` (§181 item 3), which this half of 4x does not
    /// own and which has not landed. Nothing in this file reads a header
    /// — `RecordingURLProtocol.seen` is only ever asked "was it empty?".
    /// When the seam lands, the header assertion belongs beside its fake,
    /// and AC-254 is not complete until it exists.
    @Test("no module supplies a credential or reads an identifier")
    func theLibrarySuppliesNoCredentialAndReadsNoIdentifier() throws {
        guard let source = PackageOnDisk.sourceText() else {
            Issue.record("Sources/ is not readable — this privacy proof read NOTHING")
            return
        }
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
    ///
    /// SCOPED, after 4x's review. The first cut confined the caveat to the
    /// mind's fetch and cleared "the other three". That was wrong: the ear
    /// and the second mouth both download through the speech kit's own
    /// `HubApi`, whose `hfToken ?? hfTokenFromEnv()` reads the SAME
    /// environment sources and sets the same `Authorization` header. Three
    /// of the four fetches can carry a developer's token; only Kokoro's
    /// plain `URLSession.shared.download` cannot. So the test now asks the
    /// caveat section itself to name all three, not merely to contain two
    /// magic words somewhere on the page.
    @Test("the host list states the credential caveat AC-254 cannot prove away")
    func theListStatesTheCredentialCaveat() throws {
        guard let document = PackageOnDisk.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-254's caveat has nowhere to live")
            return
        }
        let lowered = document.lowercased()
        #expect(lowered.contains("hf_token"), "the caveat must name the environment variable")
        #expect(lowered.contains("authorization"), "the caveat must name the header it can produce")

        #expect(lowered.contains("hugging_face_hub_token"),
                "the caveat must name the second environment variable both hub clients read")

        // PROSE CANNOT BE THE GUARD HERE, and this is the exact trap the
        // first cut fell into: the sentence that CLEARED the ear and the
        // second mouth named them in the same words a sentence accusing
        // them would use. So the page declares the split in a fenced block
        // and the test reads THAT.
        let bearing = FencedList.named("token-bearing", in: document)
        let free = FencedList.named("header-free", in: document)
        #expect(bearing == ["the mind", "the ear", "the second mouth"],
                "three of the four fetches can carry a developer token; the page lists \(bearing)")
        #expect(free == ["kokoro"], "Kokoro's plain download is the only header-free fetch; the page lists \(free)")
    }

    // MARK: - AC-255 · the privacy manifests (F-4 = A)

    /// Every module a consumer links ships a `PrivacyInfo.xcprivacy`, and
    /// every one of them is DECLARED in `Package.swift`. A manifest that
    /// is not declared as a resource is a file in a folder: it never
    /// reaches the consumer's app, and the App Store never sees it.
    @Test("every linked module ships a privacy manifest, declared in Package.swift")
    func everyLinkedModuleShipsAManifest() throws {
        guard let manifestSwift = PackageOnDisk.read("Package.swift") else {
            Issue.record("Package.swift is not readable — AC-255 has nothing to check")
            return
        }
        let linked = ManifestDeclarations.linkedTargets(in: manifestSwift)
        #expect(linked.count >= 6, "Package.swift declares \(linked.count) library targets; 4x shipped six")
        for module in linked {
            let found = PackageOnDisk.read("Sources/\(module)/PrivacyInfo.xcprivacy")
            #expect(found != nil, "\(module) ships no PrivacyInfo.xcprivacy (AC-255, F-4 = A)")
        }
        let undeclared = ManifestDeclarations.withoutADeclaredManifest(in: manifestSwift)
        #expect(undeclared.isEmpty,
                "these library targets declare no manifest resource: \(undeclared.joined(separator: ", "))")
    }

    /// What each manifest says: nothing collected, no tracking, no
    /// tracking domains.
    @Test("each manifest declares no collection and no tracking")
    func eachManifestCollectsNothing() throws {
        for module in PackageOnDisk.linkedModules() {
            guard let plist = PackageOnDisk.plist(forModule: module) else {
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
        let byModule = PackageOnDisk.sourcesByModule()
        guard !byModule.isEmpty else {
            Issue.record("Sources/ is not readable — this privacy proof read NOTHING")
            return
        }
        for module in PackageOnDisk.linkedModules() {
            guard let plist = PackageOnDisk.plist(forModule: module) else { continue }
            let declared = Set((plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [])
                .compactMap { $0["NSPrivacyAccessedAPIType"] as? String })
            // PER MODULE, because a manifest speaks for its own target. A
            // category belongs to the module whose code calls the API,
            // not to whichever module happens to share the package.
            let (undeclared, unused) = RequiredReasonCheck.mismatches(
                source: byModule[module] ?? "", declared: declared, triggers: PackageOnDisk.triggers)
            let owed = undeclared.joined(separator: ", ")
            #expect(undeclared.isEmpty,
                    "Sources/\(module) uses an API needing \(owed) — declare it there, and in docs/HOSTS.md")
            #expect(unused.isEmpty,
                    "\(module) declares \(unused.joined(separator: ", ")) and names no API that uses it")
        }
    }

    /// The manifests and `docs/HOSTS.md` both claim the required-reason
    /// check runs in BOTH directions. The first version's second loop
    /// asserted that `Sources/` names NO required-reason API at all,
    /// whatever the manifests declared — so doing the correct thing (call
    /// the API *and* declare the category) still went red, and the failure
    /// message told the developer to declare what they had just declared.
    @Test("the required-reason cross-check accepts a used API that IS declared")
    func aDeclaredCategoryInUseIsNotAComplaint() {
        let source = "let flag = UserDefaults.standard.bool(forKey: \"x\")"
        let category = "NSPrivacyAccessedAPICategoryUserDefaults"

        let correct = RequiredReasonCheck.mismatches(source: source, declared: [category],
                                                     triggers: PackageOnDisk.triggers)
        #expect(correct.undeclared.isEmpty, "the category IS declared — this must not complain")
        #expect(correct.unused.isEmpty, "the API IS used — this must not complain")

        let missing = RequiredReasonCheck.mismatches(source: source, declared: [], triggers: PackageOnDisk.triggers)
        #expect(missing.undeclared == [category], "a used API with no category is the missing-manifest bug")

        let idle = RequiredReasonCheck.mismatches(source: "nothing here", declared: [category],
                                                  triggers: PackageOnDisk.triggers)
        #expect(idle.unused == [category], "a declared category the code never uses is an untrue filing")
    }

    /// The first version counted `.copy("PrivacyInfo.xcprivacy")` lines
    /// and compared the number to a HAND-WRITTEN list of six modules. A
    /// seventh library product with no manifest left the count at six and
    /// was never inspected — the guard could not fail for the regression
    /// it exists to prevent — while a seventh that correctly shipped one
    /// turned the suite red for doing the right thing. The count was also
    /// blind to WHICH target a `.copy` sat on.
    @Test("the manifest guard names a new library product that declares none")
    func aNewLibraryProductWithoutAManifestIsNamed() {
        let manifest = """
        products: [
            .library(name: "Alpha", targets: ["Alpha"]),
            .library(name: "Beta", targets: ["Beta"]),
            .executable(name: "demo", targets: ["Demo"]),
        ],
        targets: [
            .target(name: "Alpha", resources: [.copy("PrivacyInfo.xcprivacy")]),
            .target(name: "Beta", dependencies: ["Alpha"]),
            .executableTarget(name: "Demo", resources: [.copy("PrivacyInfo.xcprivacy")]),
        ]
        """
        #expect(ManifestDeclarations.linkedTargets(in: manifest) == ["Alpha", "Beta"],
                "the library products are read from the manifest, not from a list in this file")
        #expect(ManifestDeclarations.withoutADeclaredManifest(in: manifest) == ["Beta"],
                "Beta ships no manifest, and Demo's does not count for it")
    }
}
