// 5d — THE OBSERVER ENDING ON ITS OWN (SPEC §232; D-135).
//
//   observer returns ─▶ pump.stop() · transcription.stop() · coordinator.stop()
//                       └── the health seam's thermal watcher: ends only on a CANCEL
//
// Found by the Mac harness (INSTRUMENTS §73, run 2): `run` never came back.
// Both demos end their runtime by cancelling it, which is why nobody had.

import MultiModalKit
import MultiModalKitTesting
import Synchronization
import Testing

extension AIRuntimeTests {

    /// A thermal source shaped like the system's: a FRESH stream for every
    /// subscriber, and none of them ever ends on its own. (The scripted
    /// provider hands out one stream for its whole life, which the system's
    /// never does.)
    final class SystemLikeThermal: ThermalStateProviding {
        private let kept = Mutex<[AsyncStream<ThermalState>.Continuation]>([])
        var current: ThermalState { .nominal }
        func transitions() -> AsyncStream<ThermalState> {
            let (stream, continuation) = AsyncStream.makeStream(of: ThermalState.self)
            kept.withLock { $0.append(continuation) }
            return stream
        }
    }

    /// Runs `runtime` with an observer that returns at once, and says
    /// whether `run` came back ON ITS OWN before a sleeping deadline. On the
    /// deadline the run is cancelled, so a red test ends instead of hanging.
    static func returnsOnItsOwn(_ runtime: AIRuntime<ManualClock>,
                                within deadline: Duration = .seconds(10)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await runtime.run { _ in }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test("the observer ending on its own ends the run, with a health seam attached (AC-345)")
    func observerEndingEndsTheRun() async throws {
        let recorder = Recorder()
        let runtime = try AIRuntime(Self.configuration(
            recorder: recorder, diagnostics: PipelineDiagnostics(thermal: SystemLikeThermal())))
        #expect(await Self.returnsOnItsOwn(runtime), "run never came back after its observer returned")
        #expect(recorder.log == ["stopRendering", "releaseSource"], "and the teardown ran, in its order")
    }

    @Test("the health seam outlives the session: a second session still hears it (AC-346)")
    func healthSeamOutlivesTheSession() async throws {
        let diagnostics = PipelineDiagnostics(thermal: SystemLikeThermal())
        let first = try AIRuntime(Self.configuration(recorder: Recorder(), diagnostics: diagnostics))
        #expect(await Self.returnsOnItsOwn(first))
        let second = try AIRuntime(Self.configuration(recorder: Recorder(), diagnostics: diagnostics))
        let signals = Signals()
        let task = Task {
            await second.run { session in
                guard let health = session.health else { return }
                for await event in health.events {
                    if case .thermal = event {
                        signals.send("thermal")
                        return
                    }
                }
            }
        }
        #expect(await signals.heard("thermal"), "the seam's broadcast ended with the first session")
        task.cancel()
        await task.value
    }
}
