import Foundation

// HelperRun's exact reading logic, against a process that prints one line and exits at once.
final class Run: @unchecked Sendable {
    let lock = NSLock()
    var partial = ""
    var lines: [String] = []
    var exited = false
    let done = DispatchSemaphore(value: 0)
    let pipe = Pipe()
    let process = Process()

    init() throws {
        process.executableURL = URL(filePath: "/bin/echo")
        process.arguments = ["enqueued"]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self.accept(String(bytes: data, encoding: .utf8) ?? "")
        }
        process.terminationHandler = { [self] _ in
            self.pipe.fileHandleForReading.readabilityHandler = nil
            let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
            self.accept((String(bytes: rest, encoding: .utf8) ?? "") + "\n")
            self.lock.withLock { self.exited = true }
            self.done.signal()
        }
        try process.run()
    }

    func accept(_ text: String) {
        lock.withLock {
            partial += text
            while let newline = partial.firstIndex(of: "\n") {
                lines.append(String(partial[..<newline]))
                partial = String(partial[partial.index(after: newline)...])
            }
        }
    }

    /// What exited() returns: the lines at the moment the exit is settled.
    func words() -> String {
        done.wait()
        return lock.withLock { lines.joined(separator: "\n") }
    }
}

var empty = 0
var lost = 0
let runs = 300
for _ in 0..<runs {
    guard let run = try? Run() else { continue }
    let words = run.words()
    if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
    if !words.contains("enqueued") { lost += 1 }
}
print("runs \(runs) · words came back EMPTY: \(empty) · 'enqueued' missing: \(lost)")
