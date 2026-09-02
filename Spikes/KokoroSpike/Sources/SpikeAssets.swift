import Foundation

/// The two files this spike cannot ship inside itself.
///
/// The weights are 327 MB. Committing them to a public repository to
/// measure a decoder for one afternoon would be a permanent cost for a
/// temporary question, so they are fetched once into Application Support
/// and kept there.
///
/// The sizes below are not decoration. `KokoroTTS.init` force-tries its
/// own weight load, so a truncated file — a dropped connection, a captive
/// portal serving an HTML error page — crashes the app instead of
/// throwing. Checking the byte count is what turns that crash into a
/// sentence on screen.
enum SpikeAssets {
    struct Asset: Sendable {
        let name: String
        let url: URL
        let expectedBytes: Int
    }

    /// The MLX-community conversion of hexgrad's Kokoro-82M — the same
    /// weights `mlx-audio` uses, and therefore the ones this Swift port
    /// was written against. Apache-2.0.
    static let model = Asset(
        name: "kokoro-v1_0.safetensors",
        url: URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!,
        expectedBytes: 327_115_152)

    /// One voice, not the whole set: 522 KB against 14.6 MB, and a
    /// second voice would answer no question this milestone asked.
    static let voice = Asset(
        name: "af_heart.safetensors",
        url: URL(string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/voices/af_heart.safetensors")!,
        expectedBytes: 522_339)

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appending(path: "KokoroSpike", directoryHint: .isDirectory)
    }

    static func location(of asset: Asset) -> URL {
        directory.appending(path: asset.name)
    }

    /// True when the file is present AND the right size. Present-but-wrong
    /// is the case that matters: it is what a half-finished download
    /// leaves behind, and it looks exactly like success to `exists`.
    static func isInstalled(_ asset: Asset) -> Bool {
        let path = location(of: asset)
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path.path(percentEncoded: false))[.size] as? Int else { return false }
        return size == asset.expectedBytes
    }

    static var allInstalled: Bool { isInstalled(model) && isInstalled(voice) }

    /// Downloads one asset, reporting progress as a fraction.
    ///
    /// `URLSession.download` rather than `.bytes`: the byte stream would
    /// mean 327 million async iterations for the weights, which is a slow
    /// download wearing a progress bar. The delegate reports what the
    /// session actually wrote.
    ///
    /// The size is checked before the file is moved into place, so an
    /// interrupted download can never masquerade as an installed one —
    /// which matters because the vendor's `init` force-tries its weight
    /// load and would crash rather than complain.
    static func download(_ asset: Asset,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reporter = ProgressReporter(expected: asset.expectedBytes, report: progress)
        let (temporary, _) = try await URLSession.shared.download(from: asset.url,
                                                                  delegate: reporter)
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path(percentEncoded: false))
        let written = attributes?[.size] as? Int ?? 0
        guard written == asset.expectedBytes else {
            try? FileManager.default.removeItem(at: temporary)
            throw SpikeFailure.downloadIncomplete(
                name: asset.name, got: written, expected: asset.expectedBytes)
        }
        let final = location(of: asset)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temporary, to: final)
        progress(1)
    }

    /// Progress for the async `download(from:delegate:)`.
    ///
    /// `didFinishDownloadingTo` is required by the protocol and is
    /// deliberately empty: the async call returns its OWN temporary URL,
    /// and that is the one this file moves. Doing anything here would be
    /// a second owner of the same bytes.
    ///
    /// `@unchecked Sendable` with the house proof: both stored properties
    /// are `let`, the closure is `@Sendable`, and nothing here mutates.
    private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expected: Int
        private let report: @Sendable (Double) -> Void

        init(expected: Int, report: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.report = report
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // The server's own figure when it gives one, and our recorded
            // size when it does not — never a bar that cannot reach 1.
            let total = totalBytesExpectedToWrite > 0
                ? Double(totalBytesExpectedToWrite) : Double(expected)
            report(min(1, Double(totalBytesWritten) / total))
        }
    }
}
