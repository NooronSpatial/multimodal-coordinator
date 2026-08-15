import Testing
import Synchronization
import MultiModalKit

/// RED SUITE for the session seam (SPEC AC-93, D-042 F-1 = B).
///
/// The trick these tests use: `MicrophoneSource.start` touches real
/// hardware, and whether a microphone exists differs between this Mac and
/// a CI runner. So nothing here asserts that capture SUCCEEDS. Every
/// assertion is an INVARIANT that must hold on both paths — which makes
/// the suite meaningful everywhere instead of skipped where it matters.
@Suite(.timeLimit(.minutes(1))) struct AudioSessionSeamTests {

    /// Records what the library did to the session, and in what order.
    final class ScriptedSession: AudioSessionConfiguring, @unchecked Sendable {
        enum Step: Equatable { case activate, deactivate }
        private let store = Mutex<[Step]>([])
        private let failure: (any Error)?

        init(failsToActivate: (any Error)? = nil) { self.failure = failsToActivate }

        var steps: [Step] { store.withLock { $0 } }

        func activate() throws {
            store.withLock { $0.append(.activate) }
            if let failure { throw failure }
        }

        func deactivate() {
            store.withLock { $0.append(.deactivate) }
        }
    }

    struct SessionRefused: Error {}

    @Test("The session is activated BEFORE capture, and released after — never left active")
    func theSessionIsActivatedFirstAndAlwaysReleased() throws {
        let session = ScriptedSession()
        let microphone = MicrophoneSource(session: session)
        let (producer, _) = AudioRing.create(minimumCapacity: 4096)

        // Capture may succeed here (a Mac with a microphone) or throw (a
        // headless runner). BOTH are fine — the invariants are the same.
        let started: Bool
        do {
            try microphone.start(into: producer)
            started = true
        } catch {
            started = false
        }

        #expect(session.steps.first == .activate,
                "the session must be made ready before anything captures")

        if started {
            #expect(session.steps == [.activate],
                    "a running engine must not have its session released underneath it")
            microphone.stop()
            #expect(session.steps == [.activate, .deactivate],
                    "release happens after the engine has stopped, exactly once")
        } else {
            #expect(session.steps == [.activate, .deactivate],
                    "capture failed, so the session it opened must not be left active")
        }
    }

    // KNOWN COVERAGE GAP, stated rather than hidden (D-041's standard).
    //
    // The `else` branch above — activate succeeded, then the ENGINE failed,
    // so the session must be released — is the one invariant this suite
    // cannot force. It runs only where capture genuinely fails, i.e. a
    // machine with no input device. On the development Mac capture
    // succeeds, so a mutation that deletes the release-on-failure logic
    // passes here; it is caught only on a runner without a microphone,
    // which is an assumption about CI, not a proof.
    //
    // Making it deterministic would mean injecting the "start the engine"
    // step so a test could fail it on demand — a public hole in
    // `MicrophoneSource` whose only caller would be this file. That trade
    // is deliberately NOT taken alone: it is a design question, recorded
    // here for the adversarial review to rule on before the merge.
    //
    // What the gap costs if the logic is ever wrong: on iOS, a failed
    // start would leave the session active — another app's audio held
    // hostage by a pipeline that is not even running.

    @Test("A session that refuses to activate stops the whole start — capture is never attempted")
    func aRefusedSessionAbortsTheStart() {
        let session = ScriptedSession(failsToActivate: SessionRefused())
        let microphone = MicrophoneSource(session: session)
        let (producer, _) = AudioRing.create(minimumCapacity: 4096)

        #expect(throws: SessionRefused.self) {
            try microphone.start(into: producer)
        }
        #expect(session.steps == [.activate],
                "nothing was ever activated, so nothing may be released")
        #expect(microphone.sampleRate == 0,
                "the format must not be read from a session that was never made ready")
    }

    @Test("Starting twice activates once — the session is not re-entered")
    func startingTwiceActivatesOnce() throws {
        let session = ScriptedSession()
        let microphone = MicrophoneSource(session: session)
        let (producer, _) = AudioRing.create(minimumCapacity: 4096)

        try? microphone.start(into: producer)
        try? microphone.start(into: producer)      // the guard must hold

        #expect(session.steps.filter { $0 == .activate }.count == 1,
                "activating an already-active session is exactly the bug this seam prevents")
        microphone.stop()
    }

    @Test("stop() without start() releases nothing")
    func stopWithoutStartReleasesNothing() {
        let session = ScriptedSession()
        let microphone = MicrophoneSource(session: session)

        microphone.stop()

        #expect(session.steps.isEmpty,
                "there was no session to release — teardown must invent nothing")
    }

    @Test("No session means the pre-4d path, byte for byte")
    func noSessionIsTheOldPath() {
        // The D-028/D-036/D-039 precedent: the default changes nothing.
        // macOS has no AVAudioSession at all, so nil is also the correct
        // production value there.
        let microphone = MicrophoneSource()
        let (producer, _) = AudioRing.create(minimumCapacity: 4096)
        try? microphone.start(into: producer)
        microphone.stop()                          // must not crash, must not require a session
    }
}
