// The `install-size` instrument (4x, AC-245): what a model costs to
// download, asked BEFORE a byte moves.
//
// It exists because the number is the only honest way to ask a person for
// their data allowance, and because a number nobody measured is a number
// nobody should print. The library computes it from the repo's per-file
// metadata; this instrument is how that computation meets the real repo,
// so INSTRUMENTS §66 can carry a figure with a date beside it.
import Foundation
import MultiModalKitMLX

// MARK: - install-size: the price of the weights, before the download

@MainActor
func runInstallSize(_ arguments: [String]) async {
    let repo = arguments.first { $0.hasPrefix("--repo=") }
        .map { String($0.dropFirst("--repo=".count)) }
        ?? "mlx-community/Qwen3-4B-4bit"
    // A throwaway directory: this asks the network a question, it does not
    // fetch. If a byte ever lands here, the instrument itself is the proof
    // that `expectedInstall()` broke its promise (AC-246).
    let into = URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-install-size")
    try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
    let model = LocalMindModel(repoID: repo, in: into)

    print("repo: \(repo)")
    let clock = ContinuousClock()
    let start = clock.now
    do {
        let size = try await model.expectedInstall()
        let asked = start.duration(to: clock.now)
        print("")
        print("| file | bytes | MB |")
        print("|---|---:|---:|")
        for file in size.files {
            print("| \(file.name) | \(file.bytes) | \(installSizeMB(file.bytes)) |")
        }
        print("| **total to download** | **\(size.downloadBytes)** | **\(installSizeMB(size.downloadBytes))** |")
        print("| **total on disk** | **\(size.onDiskBytes)** | **\(installSizeMB(size.onDiskBytes))** |")
        print("")
        print("files: \(size.files.count) · asked in \(installSizeMs(asked)) ms")
        // AC-246, checked HERE too and not only in a unit test: asking must
        // not fetch. The weights directory must still be empty.
        let landed = (try? FileManager.default.contentsOfDirectory(
            atPath: model.weights.path))?.count ?? 0
        print("bytes fetched by asking: \(landed) file(s) — must be 0")
        print("install state: \(model.installState())")
    } catch {
        print("could not ask: \(error)")
        exit(2)
    }
    exit(0)
}

private func installSizeMB(_ bytes: Int64) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576)
}

private func installSizeMs(_ duration: Duration) -> Int {
    Int(Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) * 1e-15)
}
