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
    print("installed before: \(model.modelInstalled())")

    let clock = ContinuousClock()
    let start = clock.now
    let ticks = Mutex(0)
    do {
        try await model.download { fraction in
            let count = ticks.withLock { $0 += 1; return $0 }
            if count <= 5 || count % 25 == 0 {
                print(String(format: "  progress callback #%d: %.1f%%", count, fraction * 100))
            }
        }
    } catch {
        print("FAILED after \(clock.now - start): \(error)")
        exit(1)
    }
    print("callbacks:  \(ticks.withLock { $0 })")
    print("took:       \(start.duration(to: clock.now))")
    print("installed after: \(model.modelInstalled())")
    if let listed = try? FileManager.default.contentsOfDirectory(atPath: model.weights.path) {
        print("files:      \(listed.sorted().joined(separator: ", "))")
    }
    exit(0)
}
