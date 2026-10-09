import Foundation
import MultiModalKit

// `audio-demo --person` (5d, SPEC §225/4; F-28 A, AC-342): the pipeline in
// Ryad's phone setup, spoken to by the scripted person, measured stage by
// stage — the same run, repeatable, before and after every fix:
//
//   swift run -c release audio-demo whisper --person --mind=local --mouth=kokoro \
//       --hangover 300 --gate 500 --window 320      (judged on loud chunks since 5d piece 3, D-140)
//
// No microphone: the person's voice reaches the ring directly, so this run
// measures the pipeline and never an echo.

extension AudioDemo {
    /// Everything the run needs, built before it starts.
    struct Harness {
        let runtime: AIRuntime<ContinuousClock>
        let script: Script
        let producer: AudioRingProducer
        let latency: HarnessLatency
    }

    static func runHarness(_ flags: DemoFlags, personAt path: String) async {
        guard let harness = await preparedHarness(flags, personAt: path) else { return }
        let script = harness.script
        print("\n🧪 THE SCRIPTED PERSON — \(path), \(script.sentences.count) sentences, \(script.turns) turns,"
              + " interrupting at \(script.interruptAt.sorted())")
        print("    hangover \(Int(flags.hangoverMs)) ms · gate \(Int(flags.gateMs)) ms"
              + " · window \(Int(flags.windowMs)) ms · vad \(flags.vadThreshold)\n")
        await converseAndMeasure(harness)
    }

    /// The person's recording, the ear, the mouth (its model fetched), and
    /// the runtime — or nil, having said why.
    static func preparedHarness(_ flags: DemoFlags, personAt path: String) async -> Harness? {
        let cut: (rate: Double, sentences: [[Float]])
        do {
            cut = try Sentences.cut(URL(filePath: path), threshold: flags.vadThreshold)
        } catch {
            print("the scripted person could not read \(path): \(error)")
            return nil
        }
        guard !cut.sentences.isEmpty else {
            print("the scripted person: \(path) holds no sentence the VAD can hear")
            return nil
        }
        guard let ear = chosenEar(flags.choice), await readyModel(ear.engine, named: flags.choice) else {
            print("the ear is missing or has no model — there is nothing to measure")
            return nil
        }
        let latency = HarnessLatency(hangover: .milliseconds(Int(flags.hangoverMs)))
        guard let mouth = await preparedMouth(flags.arguments, heard: { latency.heard($0) }) else { return nil }
        let (producer, consumer) = AudioRing.create(minimumCapacity: Int(cut.rate))
        do {
            let runtime = try AIRuntime(configuration(
                flags: flags,
                machine: Machine(ear: ear.engine, consumer: consumer, sampleRate: cut.rate,
                                 mouth: mouth, latency: latency),
                screen: Screen(), releaseSource: {}))
            let script = Script(sentences: cut.sentences, rate: cut.rate,
                                turns: flags.turns, interruptAt: flags.interruptAt)
            return Harness(runtime: runtime, script: script, producer: producer, latency: latency)
        } catch {
            print("Could not assemble the runtime: \(error)")
            return nil
        }
    }

    /// THE RUN ENDS BY CANCELLATION, as both demos end it (F-4 = A). It first
    /// ended by the observer returning — and `AIRuntime.run` never came back
    /// from that: nothing cancelled the health seam's thermal watcher. Found
    /// by this harness (2026-09-30), fixed in the runtime (SPEC §232, D-135);
    /// the harness keeps the demos' way of ending.
    static func converseAndMeasure(_ harness: Harness) async {
        let mouthpiece = Mouthpiece()
        let watch = TurnWatch()
        let script = harness.script
        let producer = harness.producer
        let (conversationOver, over) = AsyncStream.makeStream(of: Void.self)
        let run = Task {
            await harness.runtime.run { session in
                guard let events = session.turns?.events else { return }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await feed(mouthpiece, into: producer, rate: script.rate) }
                    group.addTask { for await event in events { watch.record(event) } }
                    group.addTask {
                        await converse(script, mouth: mouthpiece, watch: watch)
                        over.yield(())
                    }
                    group.addTask {
                        // A stalled run ends itself rather than hanging the terminal.
                        try? await Task.sleep(for: .seconds(script.turns * 40))
                        if !Task.isCancelled {
                            print("⚠ the run ran out of time — the summary is partial")
                            over.yield(())
                        }
                    }
                    await group.waitForAll()
                }
            }
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { run.cancel() }
        interrupt.resume()
        for await _ in conversationOver { break }
        run.cancel()
        await run.value
        print("\n(the runtime is down — teardown ran in order)")
        print(harness.latency.summary())
    }
}
