// The `graph-probe` instrument: what a player node off a running engine
// tolerates, one case per child process so an abort cannot hide the rest.
import AVFoundation
import Foundation

// `swift run bakeoff graph-probe` — WHAT A LIVE AUDIO GRAPH ACTUALLY DOES
// (D-054, and AC-109's tests rest on it).
//
// THE BILL THIS INSTRUMENT PAYS: five faults in one 4e afternoon, each
// introduced while fixing the previous one, every one a guess about what an
// `AVAudioEngine` would do, every one tested by Ryad rebuilding onto his
// phone. The rule that ended it — audio graphs are MEASURED, never reasoned
// about — needs a place to do the measuring, on this machine, one variable
// at a time. This is that place.
//
// ONE CASE PER PROCESS, and that is the whole design: AVFoundation does not
// throw on a misused node, it raises an ObjC exception and the process dies.
// A single-process probe would report only its first fault and hide every
// case after it. So the parent re-executes itself once per case and reads
// the exit status; a child that never prints SURVIVED aborted.
//
// AND IT PROVES ITS OWN EYES (rule 5: an instrument must be able to say
// whether it is switched on). A probe where nothing ever fails is
// indistinguishable from a probe that cannot see failures, so it reports
// whether it detected ANY abort. Case 5 is a deliberate control.
@MainActor
func runGraphProbe(_ arguments: [String]) async {
    // One case, run as a child. Same flag shape as `--lead=` above.
    let single = arguments.first(where: { $0.hasPrefix("--case=") })
        .flatMap { Int($0.dropFirst("--case=".count)) }

    let probes = graphProbes()

    // THE CHILD. One case, then the word that means it lived.
    if let single {
        graphProbeChild(single, probes: probes)
    }

    graphProbeParent(probes)
    exit(0)
}

/// One case: the path it walks, what the 4e record expects of it, and the
/// body a child process runs.
private struct Probe {
    let number: Int
    let what: String
    /// What the 4e record leads us to expect. Printed beside the
    /// measurement so a surprise is visible rather than absorbed.
    let expectation: String
    let body: () throws -> Void
}

private func player() -> AVAudioPlayerNode { AVAudioPlayerNode() }
private func monoFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                  channels: 1, interleaved: false)!
}
private func oneBuffer() -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat(), frameCapacity: 240)!
    buffer.frameLength = 240
    return buffer
}

@MainActor
private func graphProbes() -> [Probe] {
    [
        Probe(number: 1, what: "never attached → stop()",
              expectation: "survives") { player().stop() },
        Probe(number: 2, what: "never attached → reset()",
              expectation: "survives") { player().reset() },
        Probe(number: 3, what: "never attached → stop(), reset()  [the cancel + teardown path]",
              expectation: "survives") { let node = player(); node.stop(); node.reset() },
        Probe(number: 4, what: "attached to an engine NEVER started → stop(), reset(), detach",
              expectation: "survives") {
            let engine = AVAudioEngine(), node = player()
            engine.attach(node); node.stop(); node.reset(); engine.detach(node)
        },
        Probe(number: 5, what: "CONTROL — attach, connect, start, engine.stop(), detach",
              expectation: "4e fault #1 says ABORT") {
            let engine = AVAudioEngine(), node = player()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat())
            engine.prepare()
            try engine.start()
            engine.stop()
            engine.detach(node)
        },
        Probe(number: 6, what: "never attached → play()",
              expectation: "ABORT") { player().play() },
        Probe(number: 7, what: "never attached → scheduleBuffer",
              expectation: "ABORT") {
            player().scheduleBuffer(oneBuffer(), at: nil, options: [],
                                    completionCallbackType: .dataPlayedBack) { _ in }
        },
        Probe(number: 8, what: "attached to an engine never started → scheduleBuffer, play()",
              expectation: "survives") {
            let engine = AVAudioEngine(), node = player()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat())
            node.scheduleBuffer(oneBuffer(), at: nil, options: [],
                                completionCallbackType: .dataPlayedBack) { _ in }
            node.play()
            engine.detach(node)
        }
    ]
}

/// THE CHILD's half: one case, then the word that means it lived.
@MainActor
private func graphProbeChild(_ single: Int, probes: [Probe]) {
    guard let probe = probes.first(where: { $0.number == single }) else {
        print("no such case: \(single)")
        exit(2)
    }
    print("case \(probe.number): \(probe.what)")
    do { try probe.body() } catch {
        print("THREW \(error)")     // a thrown Swift error is not an abort
        exit(3)
    }
    print("SURVIVED")
    exit(0)
}

@MainActor
private func graphProbeParent(_ probes: [Probe]) {
    // THE PARENT. Re-runs itself once per case.
    print("\n🧪  GRAPH PROBE (D-054) — what a player node off a running engine tolerates")
    print("    One case per PROCESS: AVFoundation aborts rather than throwing, so a")
    print("    single-process probe would report its first fault and hide the rest.")
    print("    Executable: \(CommandLine.arguments[0])")

    var aborted: [Int] = []
    var rows: [String] = []
    for probe in probes {
        let measured = graphProbeMeasure(probe)
        if measured.aborted { aborted.append(probe.number) }
        rows.append(String(format: "| %d | %@ | %@ | %@ |",
                           probe.number, probe.what as NSString,
                           probe.expectation as NSString, measured.text as NSString))
    }

    graphProbeSummary(rows: rows, aborted: aborted)
}

/// One case's measured outcome: the cell that goes in the table, and
/// whether the child aborted rather than exiting.
private struct ProbeVerdict {
    let text: String
    let aborted: Bool
}

@MainActor
private func graphProbeMeasure(_ probe: Probe) -> ProbeVerdict {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["graph-probe", "--case=\(probe.number)"]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = pipe
    var verdict = "?"
    var didAbort = false
    do {
        try child.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        if child.terminationStatus == 0, out.contains("SURVIVED") {
            verdict = "survives"
        } else if out.contains("THREW") {
            // A THROWN SWIFT ERROR IS NOT AN ABORT, and conflating them
            // would make this instrument lie. Case 5 calls
            // `try engine.start()`, which throws on a machine with no
            // usable output device — a CI runner, or a laptop with the
            // audio device taken. Reported as an abort, that would read
            // as "detach after stop aborts here", the exact belief §20
            // refuted. Reported as untested, it says what happened.
            verdict = "did not run · " + (out.split(separator: "\n")
                .first(where: { $0.hasPrefix("THREW") })
                .map(String.init) ?? "threw")
        } else {
            verdict = "**ABORT**"
            didAbort = true
            // The reason is the useful half — the ObjC assertion text
            // names the condition that failed.
            if let line = out.split(separator: "\n").first(where: {
                $0.contains("required condition is false")
            }) {
                verdict += " · " + line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "*** Terminating app due to uncaught exception "
                                          + "'com.apple.coreaudio.avfaudio', reason: ", with: "")
            }
        }
    } catch {
        verdict = "could not run child: \(error)"
    }
    return ProbeVerdict(text: verdict, aborted: didAbort)
}

@MainActor
private func graphProbeSummary(rows: [String], aborted: [Int]) {
    print("\n| case | path | expected | measured |")
    print("|---|---|---|---|")
    for row in rows { print(row) }

    print("\n════════════════════════════════════════════════")
    if aborted.isEmpty {
        print("⚠️  NO CASE ABORTED. Read this as an instrument that has NOT proven it")
        print("    can see a failure — not as a clean bill of health. Rule 5 of D-054:")
        print("    a probe that never fails is indistinguishable from a blind one.")
    } else {
        print("✅ DETECTION PROVEN — cases \(aborted.map(String.init).joined(separator: ", ")) "
              + "aborted, so this probe can see a fault.")
    }
    let unrun = rows.filter { $0.contains("did not run") }.count
    if unrun > 0 {
        print("⚠️  \(unrun) case(s) DID NOT RUN — they threw before measuring anything.")
        print("    Read those rows as absent data, not as a verdict. The usual cause is")
        print("    a machine with no usable audio output device.")
    }
    print("\nREAD IT AS: the surviving verbs are the ones a test double may call on a")
    print("node that is on no running engine. That is what makes AC-109's headless")
    print("failure-path tests legitimate, and why its scripted decoder cannot emit a")
    print("non-empty sample — `render` would reach an aborting verb.")
    print("\nNOT measured here, and not claimed: anything involving voice processing,")
    print("an iOS audio SESSION, or a real capture engine. Case 5 is a plain engine,")
    print("so if it survives, that says nothing about the same detach under VPIO —")
    print("which is where 4e's fault was actually found. That case needs a phone.")
}
