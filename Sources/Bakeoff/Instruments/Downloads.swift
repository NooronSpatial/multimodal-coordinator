import Foundation
import MultiModalKit
import Synchronization
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import TTSKit

// WHAT A DOWNLOAD COSTS, MEASURED (5a, AC-301; INSTRUMENTS §70).
//
//   swift run bakeoff downloads [--mind=mlx-community/Qwen3-0.6B-4bit] [--voice] [--keep]
//
// Four engines, one downloader, real bytes from the real Hub — because
// the only numbers worth writing down are the ones a person's connection
// will actually produce. Everything lands in a scratch root under the
// temporary directory and is deleted afterwards (`--keep` leaves it), so
// this never touches a model somebody is using.
//
// WHAT THIS INSTRUMENT CANNOT MEASURE, and where those numbers come from
// instead: the resume overhead and the join are BYTE counts, and only a
// server that counts can give them honestly. The loopback server in the
// test suite does exactly that (`ModelDownloaderTests`,
// `MLXBackgroundInstallTests`), and §70 quotes it. What is measured here
// is wall-clock and throughput, which the loopback cannot honestly give.
//
// The neural voice is 1.1 GB and skipped unless `--voice` is passed: an
// instrument that costs a gigabyte every run is an instrument nobody
// runs.

@MainActor
func runDownloads(_ arguments: [String]) async {
    let mindRepo = arguments.first { $0.hasPrefix("--mind=") }
        .map { String($0.dropFirst("--mind=".count)) }
        ?? "mlx-community/Qwen3-0.6B-4bit"
    let withVoice = arguments.contains("--voice")
    let keep = arguments.contains("--keep")

    let root = URL(filePath: NSTemporaryDirectory()).appending(path: "mmk-downloads-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { if !keep { try? FileManager.default.removeItem(at: root) } }

    print("scratch root: \(root.path(percentEncoded: false))")
    print("mind: \(mindRepo) · neural voice: \(withVoice ? "included" : "skipped (--voice to include)")\n")

    var measured: [DownloadMeasurement] = []

    // THE EAR. Two repositories — the CoreML pipeline and the tokenizer,
    // which is a separate asset and part of "installed" since the
    // Whisper audit.
    let whisper = WhisperEngine(model: "base", installRoot: root)
    measured.append(await measure("Whisper base", engine: whisper))

    // THE MOUTH. Two static files, and the fp16 cast afterwards — which
    // is DISK work, not download, and is inside this number because it
    // is inside the wait a person sees.
    let kokoro = KokoroWeights(directory: root.appending(path: "Kokoro"))
    measured.append(await measure("Kokoro", engine: KokoroVoice(weights: kokoro)))

    // THE MIND. One repository, one request to list.
    let mind = LocalMindModel(repoID: mindRepo, in: root)
    measured.append(await measure(mindRepo, engine: mind))

    if withVoice {
        let voice = NeuralVoice(variant: .qwen3TTS_0_6b, installRoot: root)
        measured.append(await measure("Qwen3 TTS 0.6B", engine: voice))
    }

    print("\n| engine | size before the tap | listed in | transferred in | MB/s | deleted in | installed after |")
    print("|---|---:|---:|---:|---:|---:|---|")
    for row in measured { print(row.line) }
    print("\nEvery figure is this Mac, this connection, \(todayStamp()).")
    // Like every other instrument: this command is the whole run, and
    // falling through would send "downloads" to the bake-off as a WAV.
    exit(0)
}

/// One engine's numbers.
struct DownloadMeasurement {
    let name: String
    let expected: Int64?
    let listedMilliseconds: Int?
    let transferMilliseconds: Int
    let bytes: Int64
    let deleteMilliseconds: Int
    let installedAfterDelete: Bool

    var line: String {
        let size = expected.map { "\(megabytes($0)) MB" } ?? "—"
        let listed = listedMilliseconds.map { "\($0) ms" } ?? "—"
        let rate = transferMilliseconds > 0
            ? String(format: "%.1f", Double(bytes) / 1_000_000 / (Double(transferMilliseconds) / 1_000))
            : "—"
        return "| \(name) | \(size) | \(listed) | \(transferMilliseconds) ms | \(rate) | "
            + "\(deleteMilliseconds) ms | \(installedAfterDelete ? "**still installed**" : "gone") |"
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }
}

/// The measurement itself: ask the size, fetch, then delete — and print
/// the progress a person would see, so the fractions are visible and not
/// only the total.
@MainActor
private func measure(_ name: String, engine: any ModelBacked) async -> DownloadMeasurement {
    let clock = ContinuousClock()
    print("── \(name)")

    // THE SIZE BEFORE THE TAP. Free where the library pinned it; the
    // mind's costs one request, and that request is what `listed` times.
    let beforeAnyListing = engine.expectedDownloadBytes()
    var listed: Int?
    if beforeAnyListing == nil, let mind = engine as? LocalMindModel {
        let start = clock.now
        let size = try? await mind.expectedInstall()
        listed = milliseconds(clock.now - start)
        print("   listed \(size?.files.count ?? 0) files in \(listed ?? 0) ms")
    }
    let expected = engine.expectedDownloadBytes() ?? beforeAnyListing
    print("   size before the tap: \(expected.map { "\($0) bytes" } ?? "not known here")")

    let transferStart = clock.now
    // Every tenth, once — the closure runs on the downloader's own
    // task, so the last step printed lives under a lock.
    let lastPrinted = Mutex(0)
    do {
        try await engine.ensureModel { fraction in
            let step = Int(fraction * 10)
            let show = lastPrinted.withLock { last -> Bool in
                guard step > last else { return false }
                last = step
                return true
            }
            if show { print("   \(Int(fraction * 100))%") }
        }
    } catch {
        print("   FAILED: \(error)")
        return DownloadMeasurement(name: name, expected: expected, listedMilliseconds: listed,
                                   transferMilliseconds: milliseconds(clock.now - transferStart),
                                   bytes: 0, deleteMilliseconds: 0, installedAfterDelete: false)
    }
    let transfer = milliseconds(clock.now - transferStart)
    let installed = await engine.modelInstalled()
    print("   transferred in \(transfer) ms · installed: \(installed)")

    let deleteStart = clock.now
    do { try await engine.deleteModel() } catch { print("   delete FAILED: \(error)") }
    let deleted = milliseconds(clock.now - deleteStart)
    let stillThere = await engine.modelInstalled()
    print("   deleted in \(deleted) ms · installed after: \(stillThere)")

    return DownloadMeasurement(name: name, expected: expected, listedMilliseconds: listed,
                               transferMilliseconds: transfer, bytes: expected ?? 0,
                               deleteMilliseconds: deleted, installedAfterDelete: stillThere)
}

private func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
}

/// The date the numbers were taken — printed with them, because a
/// measurement without one is a claim.
private func todayStamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}
