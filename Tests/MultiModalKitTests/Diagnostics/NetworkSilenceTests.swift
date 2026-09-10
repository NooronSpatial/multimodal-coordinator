import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

// THE SILENCE HALF OF 4x, PROVEN RATHER THAN PROMISED (SPEC §181/6,
// AC-252).
//
// Aura cannot tell a person "nothing about you was sent" on the strength
// of a README paragraph. §180 lists that sentence as UNSTATED and
// UNPROVEN, and this file is the proof half: one recorder that fails
// every request the library makes, and the two controls that say what
// that recorder can and cannot see. The host list, the credential caveat
// and the privacy manifests are read in `PrivacyContractTests`, which
// needs none of this machinery.
//
// NO TEST HERE TOUCHES THE NETWORK, and that is a design constraint
// rather than a hope. Exactly TWO requests are ever issued, both by the
// controls, and both to `localhost` port 1 — which this machine's own
// kernel refuses and which never leaves it whether the recorder is
// consulted or not. Every other test asserts SILENCE: it runs a cycle
// and expects the recorder to have seen nothing. That asymmetry is
// deliberate. Driving a real weight fetch would prove more, and would
// download 2.3 GB the day the interception stopped working.

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

// MARK: - the suite

/// AC-252 — the silence, and the two controls that bound it.
///
/// `.serialized` because `URLProtocol.registerClass` is PROCESS-global.
/// Two tests in THIS suite recording at once would see each other's
/// requests, and the silence proofs would be reading somebody else's
/// traffic.
///
/// WHAT `.serialized` DOES NOT DO, named because 4x's review found the
/// first comment claiming more than the trait delivers: it orders the
/// tests inside this suite and nothing else. Swift Testing keeps running
/// OTHER suites in parallel in the same process, and CI runs the suite
/// parallel (`swift test`, no `--no-parallel`). So during the ~0.3 s
/// window this suite has the protocol registered, a request issued by a
/// concurrently running suite would be recorded here AND failed there.
/// No test in this package issues one today — `grep` for `URLSession`
/// over `Tests/` finds only this file — and 20 consecutive full-suite
/// runs were clean, so the race is LATENT rather than active. It becomes
/// real the day a gated live test's `ensureModel()` starts pinging the
/// hub again, which is exactly the regression the field note in
/// `docs/HOSTS.md` records. Making it impossible means running the whole
/// suite serially, which is a CI decision and Ryad's to rule, not a line
/// to sneak in here.
@Suite("4x · the network, named and proven", .serialized, .timeLimit(.minutes(2)))
struct NetworkSilenceTests {

    // MARK: - AC-252 · the silence, and the instrument that proves it real

    /// THE FIRST CONTROL, and without it every silence test below is
    /// worthless. `URLProtocol.registerClass` affects `URLSession.shared`
    /// — and, 4x's review established, ONLY that; the second control
    /// below is where that limit is measured rather than asserted. If a
    /// future OS stops consulting the registry at all,
    /// `#expect(seen.isEmpty)` would pass because nothing was ever
    /// OFFERED, not because nothing was sent. So one request is made on
    /// purpose and the recorder must have seen it.
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
    /// constructing the generator.
    ///
    /// That WAS every door Aura's download screen touches before a person
    /// taps anything, and §181 item 1 is about to change it:
    /// `expectedInstall()` makes one HEAD request per file BY DESIGN, so
    /// it can never join this list. When it lands, the sentence to write
    /// is "every door that is supposed to be silent", and the size call
    /// belongs to the loud half of the page.
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
    /// WHAT THIS PROVES AND WHAT IT DOES NOT — narrowed by 4x's review,
    /// which caught this comment and the page repeating the same false
    /// claim. `URLProtocol.registerClass` reaches `URLSession.shared` and
    /// NOTHING ELSE. It does not reach a session a package builds for
    /// itself, not even one built on a DEFAULT configuration, and
    /// `theRecorderIsBlindToACustomDefaultSession` below demonstrates
    /// that rather than asserting it.
    ///
    /// What that costs this test, exactly: the mind's 2.3 GB weight
    /// download runs on the vendored hub client's own `.default` session
    /// and is INVISIBLE here. So is the ear's and the second mouth's.
    /// What is visible is `URLSession.shared` — Kokoro's download, and
    /// both hub clients' `httpGet` metadata calls, which is the family
    /// the field note's revision-check bug belonged to. It also does not
    /// see a raw BSD socket, a `Network.framework` connection, a
    /// background session, or anything a system daemon does
    /// out-of-process. A green run means "nothing went out through the
    /// shared session", never "no byte left this device".
    @Test("a REAL load-and-generate cycle issues ZERO requests")
    func aRealReplyIssuesNoRequest() async throws {
        guard let weights = Self.liveWeights else { _ = PackageOnDisk.skipping("no MMK_MLX_MODEL"); return }
        guard MLXRuntime.isAvailable else { _ = PackageOnDisk.skipping("no default.metallib"); return }

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

    /// AC-252's REACH, stated by the page and proven by the control below.
    /// The first cut of `docs/HOSTS.md` said the recorder sees "sessions
    /// built on a default configuration", which is false, and on that
    /// sentence rested the claim that both weight fetches are watched.
    @Test("the page states the recorder's REAL reach, not a wider one")
    func theListStatesWhatTheRecorderCannotSee() {
        guard let document = PackageOnDisk.read("docs/HOSTS.md") else {
            Issue.record("docs/HOSTS.md is missing — AC-252's reach has nowhere to be stated")
            return
        }
        let lowered = document.lowercased()
        #expect(lowered.contains("urlsession.shared"), "the page must name the one session the recorder sees")
        #expect(lowered.contains("not through a session a package builds for itself"),
                "the page must name the blind spot the control below demonstrates")
    }

    /// THE SECOND CONTROL, and the one that bounds AC-252 honestly:
    /// `URLProtocol.registerClass` does NOT reach a session built from a
    /// default configuration. Only `URLSession.shared` consults the global
    /// registry. The mind's weight download runs on a session the vendored
    /// hub client builds for itself, so it is invisible here — and a page
    /// that claimed otherwise would be selling an unwatched path as
    /// watched.
    ///
    /// The address is `localhost` port 1 again, for the same reason: this
    /// request really is made, and this machine's own kernel refuses it.
    @Test("the recorder is BLIND to a session built the way the hub client builds one")
    func theRecorderIsBlindToACustomDefaultSession() async {
        let target = URL(string: "http://localhost:1/multimodal-coordinator-blind-spot")!
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let ownSession = URLSession(configuration: .default)
        do {
            _ = try await ownSession.data(from: target)
            Issue.record("a request to localhost:1 must not succeed")
        } catch {
            // Refused by the kernel — the recorder never saw it to refuse.
        }
        let seen = RecordingURLProtocol.stop()
        #expect(!seen.contains { $0.url == target },
                "the recorder saw a custom .default session — AC-252's stated reach is now too NARROW")
    }
}
