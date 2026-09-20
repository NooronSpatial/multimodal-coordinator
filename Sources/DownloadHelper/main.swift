import Foundation
import MultiModalKit
import Synchronization

// THE HELPER PROCESS (5a, AC-292, AC-297): the app that died, and the one
// that came back.
//
// A test cannot kill itself and come back, so this small program plays
// BOTH lives, and the test drives it twice with the same session
// identifier:
//
//   enqueue  — the first life: enqueue one file on a background session,
//              wait for the first byte to be reported, print `enqueued`,
//              and EXIT mid-transfer, on purpose. The daemon keeps moving
//              the bytes with no process of ours alive.
//   adopt    — the second life, tapped: `transfer` the same plan; it must
//              ADOPT the daemon's task (print `adopted` at the first
//              fraction) and finish it (print `landed <bytes>`).
//   wake     — the second life, woken by the system: hand a completion
//              handler to the downloader (print `attached`), and print
//              `woken` when it is called.
//
// The same executable for both lives, on purpose: the daemon scopes a
// session by its client, and a session started by one program is not
// shown to another. The test measures the rest against its server —
// one request, the bytes, the file.
//
// Usage: DownloadHelper <enqueue|adopt|wake> <session-identifier> <source-url>
//                       <destination-path> <expected-bytes>

let arguments = CommandLine.arguments
guard arguments.count == 6, let source = URL(string: arguments[3]), let bytes = Int64(arguments[5]) else {
    let usage = "usage: DownloadHelper <enqueue|adopt|wake> <identifier> <url> <destination> <bytes>\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let mode = arguments[1]
let downloader = ModelDownloader(sessionIdentifier: arguments[2])
let plan = DownloadPlan(files: [
    DownloadPlan.File(source: source, destination: URL(fileURLWithPath: arguments[4]), expectedBytes: bytes)
])

@Sendable func say(_ words: String) {
    FileHandle.standardOutput.write(Data((words + "\n").utf8))
}

let done = DispatchSemaphore(value: 0)
// DETACHED, because top-level code is main-actor code and the main
// thread is about to block on the semaphore: a `Task {}` here would
// inherit the main actor and never run.
Task.detached {
    do {
        switch mode {
        case "enqueue":
            try await downloader.transfer(plan) { fraction in
                if fraction > 0 { say("enqueued"); exit(0) }
            }
            say("finished before the first fraction — the server did not hold")
            exit(1)
        case "adopt":
            let first = Mutex(true)
            try await downloader.transfer(plan) { fraction in
                let wasFirst = first.withLock { was in defer { was = false }; return was }
                if fraction > 0, wasFirst { say("adopted at \(fraction)") }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: arguments[4])
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            say("landed \(size)")
        case "wake":
            await downloader.handleEvents { say("woken"); done.signal() }
            say("attached")
            return
        default:
            say("unknown mode \(mode)")
            exit(2)
        }
    } catch {
        say("failed: \(error)")
        exit(1)
    }
    done.signal()
}
if done.wait(timeout: .now() + 40) == .timedOut {
    say("timed out")
    exit(3)
}
exit(0)
