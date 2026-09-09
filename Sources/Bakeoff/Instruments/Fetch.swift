// The `fetch` instrument: the model DOWNLOAD path, run away from any UI.
import Foundation
import MultiModalKitMLX
import Synchronization

// MARK: - fetch: prove the DOWNLOAD path, away from any UI

/// `swift run bakeoff fetch --repo=mlx-community/Qwen3-0.6B-4bit --into=/tmp/x`
///
/// Exists because a field report ("downloading is not starting") cannot
/// be chased through a phone's UI: this runs the same
/// `LocalMindModel.download` the app calls, prints every progress
/// callback, and says plainly whether the files landed.
@MainActor
func runFetch(_ arguments: [String]) async {
    let repo = arguments.first(where: { $0.hasPrefix("--repo=") })
        .map { String($0.dropFirst("--repo=".count)) }
        ?? "mlx-community/Qwen3-0.6B-4bit"
    let into = arguments.first(where: { $0.hasPrefix("--into=") })
        .map { URL(filePath: String($0.dropFirst("--into=".count))) }
        ?? URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-fetch")
    try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)

    let model = LocalMindModel(repoID: repo, in: into)
    print("repo:      \(repo)")
    print("target:    \(model.weights.path)")
    print("installed before: \(model.modelInstalled())  state: \(model.installState())")

    let clock = ContinuousClock()
    let start = clock.now
    let ticks = Mutex(0)
    do {
        // BYTES, not just a fraction (4v, AC-240): this is the entry point
        // the library's own callers should use, and the one SPEC §179 asks
        // for evidence of — "the manifest written on a real download". The
        // pre-4v `download(progress:)` is still there for the demo, and
        // printing the byte fields here is what makes a real run say
        // whether the wiring carried them.
        try await model.download(reporting: { progress in
            let count = ticks.withLock { $0 += 1; return $0 }
            if count <= 5 || count % 25 == 0 {
                let bytes = progress.bytesExpected.map {
                    " (\(progress.bytesReceived ?? 0) of \($0) bytes expected)"
                } ?? " (no expected total: a first install)"
                print(String(format: "  progress callback #%d: %.1f%%",
                             count, progress.fraction * 100) + bytes)
            }
        })
    } catch {
        print("FAILED after \(clock.now - start): \(error)")
        exit(1)
    }
    print("callbacks:  \(ticks.withLock { $0 })")
    print("took:       \(start.duration(to: clock.now))")
    print("installed after: \(model.modelInstalled())  state: \(model.installState())")
    if let listed = try? FileManager.default.contentsOfDirectory(atPath: model.weights.path) {
        print("files:      \(listed.sorted().joined(separator: ", "))")
    }
    // AC-239's central promise, printed: a COMPLETE download writes
    // `manifest.json`, every file and every byte. Read from disk by name
    // — the type that writes it is internal to the library, and an
    // instrument should read what a person would read.
    let manifest = model.weights.appending(path: "manifest.json")
    if let text = try? String(contentsOf: manifest, encoding: .utf8) {
        print("manifest:   \(manifest.path)")
        print(text)
    } else {
        print("manifest:   NONE WRITTEN")
    }
    exit(0)
}
