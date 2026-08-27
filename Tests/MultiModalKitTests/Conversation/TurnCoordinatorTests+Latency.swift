// `TurnCoordinatorTests`, continued: latency reporting.

import Testing
import MultiModalKit
import MultiModalKitTesting

extension TurnCoordinatorTests {
    // MARK: - latency (R2: clock + injected reporter, exact under ManualClock)

    @Test("Turn latency = final accepted → the started evidence: exact on a manual clock")
    func turnLatencyExact() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 1), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter)
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "measure me", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // The user's wait: 250 ms of manual time before the mouth opens.
            await clock.advance(by: .milliseconds(250))
            bench.generator.emit(reply: 0, token: "tick")
            #expect(await Self.until { bench.synthesizer.utterancesOpened == 1 })
            bench.synthesizer.reportStarted(utterance: 0)
            #expect(await Self.until { await bench.coordinator.currentState == .speaking })

            bench.generator.finish(reply: 0)
            #expect(await Self.until { bench.synthesizer.record(ofUtterance: 0)?.tokensFinished == true })
            bench.synthesizer.reportFinished(utterance: 0)
            #expect(await Self.until { await bench.box.events.contains(.turnCompleted(turn: 0)) })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(reporter.turnLatencies.count == 1)
        #expect(reporter.turnLatencies.first ?? (.zero, -1) == (.milliseconds(250), 0),
                "the felt pause must be EXACTLY the manual time that passed")
        #expect(reporter.cancelLatencies.isEmpty, "no barge happened — no cancel latency")
    }

    @Test("Cancel latency is exactly zero in mock time — teardown has no clock waits; a dead turn reports nothing")
    func cancelLatencyZeroInMockTime() async {
        let clock = ManualClock()
        let reporter = RecordingLatencyReporter()
        let bench = Bench(generator: .manual(replies: 2), synthesizer: .manual(utterances: 1),
                          clock: clock, reporter: reporter)
        let listener = await bench.coordinator.listen()

        await withTaskGroup(of: Void.self) { group in
            bench.start(in: &group, listener: listener)

            bench.speak(utterance: 0, final: "doomed", at: 0)
            #expect(await Self.until { bench.generator.repliesOpened == 1 })
            // Time passes while the turn thinks — it must NOT pollute the
            // cancel measurement, which starts at the barge itself.
            await clock.advance(by: .seconds(2))

            bench.audio.yield(.speechStarted(utterance: 1, at: Self.t(96000)))   // the barge
            #expect(await Self.until { await bench.box.events.contains(.turnBarged(turn: 0)) })
            #expect(await Self.until { !reporter.cancelLatencies.isEmpty })

            bench.finishInputs()
            await bench.coordinator.stop()
        }

        #expect(reporter.cancelLatencies.count == 1)
        #expect(reporter.cancelLatencies.first ?? (.seconds(9), -1) == (.zero, 0),
                "structural teardown takes no mock time — exactly zero, or a clock wait crept in")
        #expect(reporter.turnLatencies.isEmpty,
                "the turn died before speaking — a dead turn reports no turn latency")
    }
}
