import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX
@testable import MultiModalKitTTS

// THE SILENCE HALF OF 4x, PROVEN RATHER THAN PROMISED (SPEC §181/6,
// AC-252).
//
// Aura cannot tell a person "nothing about you was sent" on the strength
// of a README paragraph. §180 lists that sentence as UNSTATED and
// UNPROVEN, and this file is the proof half: one recorder that fails the
// requests this suite marks as its own, and the three controls that say
// what that recorder can and cannot see and what it must never do to
// anybody else. The host list, the credential caveat and the privacy
// manifests are read in `PrivacyContractTests`, which needs none of this
// machinery.
//
// NO TEST HERE TOUCHES THE NETWORK, and that is a design constraint
// rather than a hope. Exactly THREE requests are issued ON PURPOSE, all
// by the controls, and all to `localhost` port 1 — which this machine's
// own kernel refuses and which never leaves it whether the recorder is
// consulted or not. Every other test asserts SILENCE: it runs a cycle
// and expects the recorder to have seen nothing. That asymmetry is
// deliberate. Driving a real weight fetch would prove more, and would
// download 2.3 GB the day the interception stopped working.

// MARK: - the recorder

/// Every request the URL Loading System offers it, sorted into two piles:
/// the ones this suite MARKED as its own, which are recorded and FAILED,
/// and everything else, which is recorded and DECLINED — handed straight
/// back to the loading system untouched.
///
/// THE DECLINE IS THE WHOLE POINT, and it is 4x's review that put it
/// here. `URLProtocol.registerClass` is PROCESS-global, so while this
/// suite held the registry the first version claimed EVERY request in the
/// process and failed it. That is not a theory: a voice load running in
/// `RetiredVoiceIsTerminalTests` was killed by this file's `Refusal`
/// error on a clean tree, and in the same run AC-252's own silence proof
/// went red on six `huggingface.co` requests it never issued. A test that
/// breaks other tests is worse than no test.
///
/// So the rule is now: **only a request carrying this arming's marker
/// header may be failed.** Anything else is watched and waved through.
/// `anUnmarkedRequestIsWatchedButNeverFailed` is where that is proven
/// rather than promised.
///
/// `@unchecked Sendable` with the house proof: the only mutable state is
/// the `log` and it lives behind a `Mutex`; the instance stores nothing
/// this class adds. `URLProtocol` is not `Sendable`, so the annotation is
/// what lets a subclass of it be named from a `@Sendable` context at all.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {

    /// The header a request carries to say "I belong to the test that
    /// armed the recorder". A random value per arming, so a stale request
    /// from a previous arming cannot be mistaken for this one's.
    static let markerField = "X-MMK-Recorder"

    /// What one arming saw.
    ///
    /// RECORDED IN `canInit`, not in `startLoading`, because `canInit` is
    /// the only hook that sees a request the protocol DECLINES — and
    /// declining is now the common case. A query method with a side
    /// effect is worth naming rather than hiding, and the loading system
    /// may ask about the same request more than once. Every question this
    /// file puts to these arrays ("was it empty?", "did it contain X?")
    /// is indifferent to a duplicate.
    struct Capture: Sendable {
        /// Requests carrying this arming's marker: this suite's own.
        var mine: [URLRequest] = []
        /// Requests that were not this suite's, watched and waved through.
        var overheard: [URLRequest] = []
    }

    private struct Armed {
        var marker: String?
        var capture = Capture()
    }

    private static let log = Mutex(Armed())

    /// Anything this protocol claims dies here, with this error. A request
    /// that fails with anything else was NOT claimed by the recorder,
    /// which is what the decline proof reads.
    enum Refusal: Error, Equatable { case noRequestMayLeaveThisTest }

    /// Did the recorder kill this request?
    ///
    /// NOT `error as? Refusal`, and that was measured rather than
    /// guessed. `URLSession` does not hand the caller back the error
    /// object the protocol gave it: it rebuilds an `NSError` carrying the
    /// domain and code the Swift error bridged to
    /// (`…RecordingURLProtocol.Refusal`, code 0) plus its own task keys,
    /// so the cast back to the enum fails and a test written that way
    /// would report "not refused" for a request the recorder had just
    /// killed. The domain and code are taken FROM the enum, so renaming
    /// the case cannot make this quietly stop matching.
    static func isRefusal(_ error: any Error) -> Bool {
        let ours = Refusal.noRequestMayLeaveThisTest as NSError
        let theirs = error as NSError
        return theirs.domain == ours.domain && theirs.code == ours.code
    }

    /// Clears the log, mints a fresh marker and switches interception on.
    /// Paired with `stop()` through a `defer` at every call site, so a
    /// failing expectation cannot leave the process with a registered
    /// protocol.
    @discardableResult
    static func start() -> String {
        let marker = UUID().uuidString
        log.withLock { $0 = Armed(marker: marker) }
        URLProtocol.registerClass(RecordingURLProtocol.self)
        return marker
    }

    /// Switches interception off and hands back what was seen. Safe to
    /// call twice — `unregisterClass` on an unregistered class is a
    /// no-op — which is what lets the `defer` above survive a test that
    /// already called it.
    ///
    /// The marker is dropped here as well as the registration: a callback
    /// that arrives late finds no marker, so it cannot claim anything.
    @discardableResult
    static func stop() -> Capture {
        URLProtocol.unregisterClass(RecordingURLProtocol.self)
        return log.withLock { state in
            let seen = state.capture
            state.marker = nil
            return seen
        }
    }

    /// A request this suite owns: the marker header on it, so the recorder
    /// may fail it. Anything built any other way is somebody else's.
    static func markedRequest(to url: URL, marker: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(marker, forHTTPHeaderField: markerField)
        return request
    }

    override static func canInit(with request: URLRequest) -> Bool {
        log.withLock { state in
            guard let marker = state.marker else { return false }
            guard request.value(forHTTPHeaderField: markerField) == marker else {
                state.capture.overheard.append(request)
                return false
            }
            state.capture.mine.append(request)
            return true
        }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: Refusal.noRequestMayLeaveThisTest)
    }

    override func stopLoading() {}
}

// MARK: - the suite

/// AC-252 — the silence, and the three controls that bound it.
///
/// `.serialized` because `URLProtocol.registerClass` is PROCESS-global.
/// Two tests in THIS suite armed at once would see each other's requests,
/// and the silence proofs would be reading somebody else's traffic.
///
/// WHAT `.serialized` DOES NOT DO, named because 4x's review found the
/// first comment claiming more than the trait delivers: it orders the
/// tests inside this suite and nothing else. Swift Testing keeps running
/// OTHER suites in parallel in the same process, and CI runs the suite
/// parallel (`swift test`, no `--no-parallel`). Round 2 of the review
/// then caught that window doing real damage — the recorder failed a
/// neural-voice load inside `RetiredVoiceIsTerminalTests`, and AC-252's
/// own silence proof went red on six `huggingface.co` requests it never
/// issued.
///
/// WHAT WAS DONE ABOUT IT, and what was not:
///
/// - **The recorder can no longer fail anybody else's request.** It
///   claims a request only when the request carries this arming's marker
///   header, which only this suite puts there; everything else is
///   declined and proceeds exactly as it would with no recorder in the
///   process. `anUnmarkedRequestIsWatchedButNeverFailed` breaks that on
///   purpose to show it holds. So the poisoning half of the race is gone
///   BY CONSTRUCTION, not by luck.
/// - **The recorder can still OVERHEAR.** `canInit` is still offered
///   every request in the process, and the silence proofs read what it
///   overheard, because that is the only way this criterion can fail at
///   all: a leak from the code under test arrives unmarked, exactly like
///   a neighbour's request does. So a suite running in parallel that
///   really does issue a request makes this one go RED. That direction
///   is the safe one — it is a loud false alarm naming the URLs it saw,
///   never a quiet false pass — but it is a flake, and it is named here
///   rather than discovered.
/// - **And the price of declining, paid openly.** The old recorder KILLED
///   a leaking request; this one only watches it. So on the day a silence
///   proof goes red for a real regression, the request it names really
///   did leave through `URLSession.shared` — the run reports it, it does
///   not prevent it. That is the cost of not being allowed to kill
///   anybody else's request, and it is the right way round: this file's
///   job is to TELL the truth about what left the device, and a guard
///   that lies to its neighbours to do it is not worth having.
/// - Making the overhearing impossible means running the whole package's
///   tests serially (`--no-parallel`), which is a CI decision and Ryad's
///   to rule, not a line to sneak in here. The other way out is AC-252 on
///   a session the library is HANDED, which is `WeightsFetching` (§181
///   item 3) and has not landed.
///
/// The one source of overheard traffic this repo actually had is gone
/// with it: the neural voice's load now names its local model and
/// tokenizer folders, the way the ear's load already did (see the field
/// note in `docs/HOSTS.md`).
@Suite("4x · the network, named and proven", .serialized, .timeLimit(.minutes(2)))
struct NetworkSilenceTests {

    // MARK: - AC-252 · the silence, and the instrument that proves it real

    /// THE FIRST CONTROL, and without it every silence test below is
    /// worthless. `URLProtocol.registerClass` affects `URLSession.shared`
    /// — and, 4x's review established, ONLY that; the second control
    /// below is where that limit is measured rather than asserted. If a
    /// future OS stops consulting the registry at all,
    /// `#expect(overheard.isEmpty)` would pass because nothing was ever
    /// OFFERED, not because nothing was sent. So one request is made on
    /// purpose and the recorder must have seen it AND failed it with its
    /// own error — the error is checked, not just the log, because a
    /// recorder that records and then declines everything would pass a
    /// log-only assertion while claiming nothing.
    ///
    /// The address is `localhost` port 1. If interception has broken, the
    /// connection is refused by this machine's own kernel and no packet
    /// reaches any network — the requests in this file that really are
    /// made are also the ones that cannot go anywhere.
    @Test("the recorder sees a MARKED request that IS made — the control for every silence proof")
    func theRecorderIsReallyIntercepting() async {
        let target = URL(string: "http://localhost:1/multimodal-coordinator-control")!
        let marker = RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        var refused = false
        do {
            _ = try await URLSession.shared.data(
                for: RecordingURLProtocol.markedRequest(to: target, marker: marker))
            Issue.record("a request to localhost:1 must not succeed")
        } catch {
            // Refused — by the recorder, or by the kernel. Which one it
            // was is exactly what the expectations below decide.
            refused = RecordingURLProtocol.isRefusal(error)
        }
        let seen = RecordingURLProtocol.stop()
        #expect(seen.mine.contains { $0.url == target },
                "the recorder saw nothing — interception is OFF, so every silence test here is vacuous")
        #expect(refused,
                "the recorder logged the request but did not CLAIM it — it can no longer fail a leak")
    }

    /// THE THIRD CONTROL, and the one round 2 of the review made
    /// necessary: an UNMARKED request must be watched and waved through.
    ///
    /// This is the poisoning proof. On a clean tree the old recorder
    /// claimed every request in the process while it was armed, and a
    /// neural-voice load in another suite died with this file's `Refusal`
    /// error. So the assertion is in two halves: the recorder must have
    /// SEEN the request (otherwise the silence proofs below are blind),
    /// and the caller must NOT have been handed `Refusal` (otherwise this
    /// suite is still breaking its neighbours).
    ///
    /// `localhost` port 1 again: really made, refused by this machine's
    /// own kernel, never leaves it.
    @Test("an unmarked request is watched but NEVER failed by the recorder")
    func anUnmarkedRequestIsWatchedButNeverFailed() async {
        let target = URL(string: "http://localhost:1/multimodal-coordinator-neighbour")!
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        var claimed = false
        do {
            _ = try await URLSession.shared.data(from: target)
            Issue.record("a request to localhost:1 must not succeed")
        } catch {
            claimed = RecordingURLProtocol.isRefusal(error)
        }
        let seen = RecordingURLProtocol.stop()
        #expect(seen.overheard.contains { $0.url == target },
                "the recorder did not even SEE an unmarked request — the silence proofs are blind")
        #expect(!claimed,
                "the recorder FAILED a request it does not own — this is the suite poisoning its neighbours")
        #expect(seen.mine.isEmpty, "an unmarked request must never be counted as this suite's own")
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
        // UNMARKED is the pile a leak lands in: nothing here puts the
        // marker header on a library's request, so a request from the
        // calls above arrives exactly like a neighbour's would. See the
        // suite comment — this can go red for a neighbour's traffic, and
        // that direction is the safe one.
        let urls = seen.overheard.compactMap { $0.url?.absoluteString }.joined(separator: ", ")
        #expect(seen.overheard.isEmpty,
                """
                the install questions issued, or a suite running in parallel issued, \
                \(seen.overheard.count) request(s): \(urls)
                """)
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
        let urls = seen.overheard.compactMap { $0.url?.absoluteString }.joined(separator: ", ")
        #expect(seen.overheard.isEmpty,
                """
                a load-and-generate cycle issued, or a suite running in parallel issued, \
                \(seen.overheard.count) request(s): \(urls)
                """)
    }

    /// AC-252 FOR THE MOUTH, and the reason it exists is that the page's
    /// headline sentence was false until this milestone's own recorder
    /// printed the URLs. "Once the weights are on disk, listening,
    /// thinking and speaking issue no requests at all" — speaking issued
    /// six, to `huggingface.co/api/models/Qwen/Qwen3-0.6B/revision/main`,
    /// because the neural voice's tokenizer was named by REPO ID rather
    /// than by folder. The fix is the ear's fix, one type over
    /// (`NeuralVoice.loadedPipeline()` now pins `modelFolder` and
    /// `tokenizerFolder`); this is the guard that keeps it fixed.
    ///
    /// GATED ON THE DISK, not on an environment variable, because that is
    /// what the claim is about: a person who already has the weights.
    /// With no model installed there is nothing to prove and the test
    /// says so rather than passing quietly.
    ///
    /// It reads `overheard` for the same reason the install cycle does —
    /// a library's request carries no marker, so a regression lands there.
    @Test("a REAL neural-voice load with the model on disk issues ZERO requests")
    func aRealVoiceLoadIssuesNoRequest() async throws {
        let voice = VoiceLevers(decoder: .fused).makeVoice()
        guard await voice.modelInstalled() else {
            _ = PackageOnDisk.skipping("the neural voice model is not installed on this machine")
            return
        }
        RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let run = try await voice.openUtterance()
        let seen = RecordingURLProtocol.stop()
        await run.cancel()
        await voice.retire()

        let urls = seen.overheard.compactMap { $0.url?.absoluteString }.joined(separator: ", ")
        #expect(seen.overheard.isEmpty,
                """
                opening an utterance with the model on disk issued, or a suite running in \
                parallel issued, \(seen.overheard.count) request(s): \(urls)
                """)
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
        let marker = RecordingURLProtocol.start()
        defer { RecordingURLProtocol.stop() }
        let ownSession = URLSession(configuration: .default)
        do {
            // The marker header is on this one, deliberately. If the
            // registry reached this session the recorder would claim it,
            // so a miss here cannot be blamed on the marker rule — it is
            // the session that is out of reach.
            _ = try await ownSession.data(
                for: RecordingURLProtocol.markedRequest(to: target, marker: marker))
            Issue.record("a request to localhost:1 must not succeed")
        } catch {
            // Refused by the kernel — the recorder never saw it to refuse.
        }
        let seen = RecordingURLProtocol.stop()
        #expect(!(seen.mine + seen.overheard).contains { $0.url == target },
                "the recorder saw a custom .default session — AC-252's stated reach is now too NARROW")
    }
}
