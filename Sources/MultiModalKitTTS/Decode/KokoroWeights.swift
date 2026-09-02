import Foundation
import MLX
import MultiModalKit

/// Where Kokoro's weights live, and how they get there (4q, D-084).
///
/// Two files and one conversion, kept apart from the decoder because they
/// are a different job: `ModelBacked`'s doctrine is that **asking is free
/// and never downloads, fetching is explicit and idempotent**. A decoder
/// that fetched 327 MB because someone asked its sample rate would be the
/// trap D-078 named.
///
/// ## Why the app converts the weights itself
///
/// §55 measured half precision as ~180 MB cheaper and, in Ryad's words,
/// *"fp16 sound the same, i cant hear a difference"*. The obvious way to
/// get it was to download `mlx-community/Kokoro-82M-bf16`. **That
/// repository is fp32 in disguise:** 327,115,152 bytes, all 548 tensors
/// `F32`, byte for byte the same file as the fp32 mirror — checked by
/// reading both safetensors headers, not by trusting either name.
///
/// So the cast happens here, once, on the device. It costs one load and
/// one save the first time and nothing afterwards.
public struct KokoroWeights: Sendable {
    /// The precision the decoder loads. fp16 is the default because §55
    /// measured it cheaper at identical speed and Ryad heard no
    /// difference; fp32 stays reachable because "no difference" is an ear
    /// on one phone, not a proof.
    public enum Precision: String, Sendable, CaseIterable {
        case float32, float16

        var dtype: DType? { self == .float32 ? nil : .float16 }
    }

    /// The fp32 weights, from the mirror `mlx-audio` uses — and therefore
    /// the ones this Swift port was written against. Apache-2.0.
    public static let sourceURL = URL(
        string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
    /// One voice, not the set: 522 KB against 14.6 MB, and a second voice
    /// answers no question this milestone asked.
    public static let voiceURL = URL(
        string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/voices/af_heart.safetensors")!

    /// Exact sizes, because the vendor's `init` force-tries its own weight
    /// load: a truncated download — a dropped connection, a captive portal
    /// serving an error page — would CRASH rather than throw. Checking the
    /// byte count is what turns that crash into a thrown error.
    public static let sourceBytes = 327_115_152
    public static let voiceBytes = 522_339

    public let directory: URL
    public let precision: Precision

    /// The app passes its own Application Support subdirectory. No default
    /// on purpose: a wrong default here writes a third of a gigabyte into
    /// someone else's folder.
    public init(directory: URL, precision: Precision = .float16) {
        self.directory = directory
        self.precision = precision
    }

    /// The ordinary place: `Application Support/Kokoro`.
    ///
    /// A convenience, not a default — `init` still demands a directory,
    /// because a wrong default WRITES a third of a gigabyte somewhere. A
    /// caller that wants the ordinary place asks for it by name.
    public static func inApplicationSupport(precision: Precision = .float16) -> KokoroWeights {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return KokoroWeights(directory: base.appending(path: "Kokoro", directoryHint: .isDirectory),
                             precision: precision)
    }

    var sourceFile: URL { directory.appending(path: "kokoro-v1_0.safetensors") }
    var voiceFile: URL { directory.appending(path: "af_heart.safetensors") }

    /// The file the decoder actually opens: the download itself for fp32,
    /// the cast copy otherwise.
    var modelFile: URL {
        precision == .float32 ? sourceFile
            : directory.appending(path: "kokoro-\(precision.rawValue).safetensors")
    }

    /// True when this precision can speak with the network unplugged —
    /// `ModelBacked`'s meaning of installed, not "a file exists".
    public func isInstalled() -> Bool {
        exists(voiceFile, bytes: Self.voiceBytes)
            && exists(sourceFile, bytes: Self.sourceBytes)
            && (precision == .float32 || FileManager.default.fileExists(atPath: modelFile.path(percentEncoded: false)))
    }

    /// Present AND the right size. Present-but-wrong is the case that
    /// matters: it is what a half-finished download leaves behind, and it
    /// looks exactly like success to `fileExists`.
    private func exists(_ url: URL, bytes: Int) -> Bool {
        sizeOnDisk(url) == bytes
    }

    /// `percentEncoded: false` ON EVERY PATH STRING IN THIS FILE, and the
    /// reason is a field bug rather than style. `URL.path()` percent
    /// encodes by default, so under iOS's `Library/Application Support` it
    /// hands `FileManager` a string containing a literal `%20` — a folder
    /// that does not exist. The first field run downloaded 327 MB
    /// successfully into the right place and then reported every file
    /// absent, because the URL-based calls wrote there and the
    /// string-based checks looked somewhere else. Fact 8 in the tests is
    /// the directory with a space that would have caught it on the Mac.
    private func sizeOnDisk(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.size] as? Int
    }

    /// WHY `isInstalled()` said no, in a sentence a person can act on.
    ///
    /// The first field run of this mouth answered "loaded, but the disk
    /// check disagrees" — true, useless, and exactly the kind of message
    /// this project refuses in an instrument. A check that cannot say
    /// WHICH file and WHAT size it saw is not reporting, it is shrugging.
    ///
    /// Returns `nil` when everything is in place.
    public func missingReport() -> String? {
        guard !isInstalled() else { return nil }
        var lines: [String] = []
        for (url, expected) in [(sourceFile, Self.sourceBytes), (voiceFile, Self.voiceBytes)] {
            switch sizeOnDisk(url) {
            case nil:
                lines.append("\(url.lastPathComponent): absent")
            case let found? where found != expected:
                lines.append("\(url.lastPathComponent): \(found) bytes, expected \(expected)")
            default:
                continue
            }
        }
        if precision != .float32, !FileManager.default.fileExists(atPath: modelFile.path(percentEncoded: false)) {
            lines.append("\(modelFile.lastPathComponent): absent — the "
                         + "\(precision.rawValue) cast was not built")
        }
        // Absence of a reason with a failing check is itself a finding:
        // it means `isInstalled` and this report disagree, which is a bug
        // here rather than a missing file.
        guard !lines.isEmpty else {
            return "isInstalled() said no but every file checks out — that is a bug in this type"
        }
        return lines.joined(separator: " · ") + " · in \(directory.path(percentEncoded: false))"
    }

    /// Fetches what is missing and builds the cast copy. Idempotent.
    ///
    /// `progress` is called with a fraction while bytes arrive, so a
    /// 327 MB wait on a phone is a bar and not a frozen screen.
    public func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !exists(sourceFile, bytes: Self.sourceBytes) {
            try await download(Self.sourceURL, to: sourceFile,
                               bytes: Self.sourceBytes, progress: progress)
        }
        if !exists(voiceFile, bytes: Self.voiceBytes) {
            try await download(Self.voiceURL, to: voiceFile,
                               bytes: Self.voiceBytes, progress: progress)
        }
        try buildCast()
    }

    /// Casts every tensor and writes the file, through a temporary name so
    /// a conversion the system interrupts cannot leave a half file that
    /// `isInstalled()` would call ready.
    func buildCast() throws {
        guard let dtype = precision.dtype,
              !FileManager.default.fileExists(atPath: modelFile.path(percentEncoded: false)) else { return }
        let arrays = try MLX.loadArrays(url: sourceFile)
        let cast = arrays.mapValues { $0.asType(dtype) }
        let partial = directory.appending(path: "kokoro-\(precision.rawValue).partial.safetensors")
        try MLX.save(arrays: cast, url: partial)
        try? FileManager.default.removeItem(at: modelFile)
        try FileManager.default.moveItem(at: partial, to: modelFile)
        // The cast copies are done with, and a model load starts next.
        MLX.Memory.clearCache()
    }

    private func download(_ url: URL, to destination: URL, bytes: Int,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let reporter = DownloadProgress(expected: bytes, report: progress)
        let (temporary, _) = try await URLSession.shared.download(from: url, delegate: reporter)
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path(percentEncoded: false))
        let written = attributes?[.size] as? Int ?? 0
        guard written == bytes else {
            try? FileManager.default.removeItem(at: temporary)
            throw KokoroWeightsFailure.incompleteDownload(
                name: destination.lastPathComponent, got: written, expected: bytes)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// `@unchecked Sendable` with the house proof: both stored properties
    /// are `let`, the closure is `@Sendable`, and nothing here mutates.
    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let expected: Int
        private let report: @Sendable (Double) -> Void

        init(expected: Int, report: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.report = report
        }

        /// Required by the protocol and deliberately empty: the async call
        /// returns its OWN temporary URL, and that is the one moved. Doing
        /// anything here would be a second owner of the same bytes.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0
                ? Double(totalBytesExpectedToWrite) : Double(expected)
            report(min(1, Double(totalBytesWritten) / total))
        }
    }
}

public enum KokoroWeightsFailure: Error, CustomStringConvertible, Equatable {
    case incompleteDownload(name: String, got: Int, expected: Int)
    case voiceFileEmpty(String)

    public var description: String {
        switch self {
        case .incompleteDownload(let name, let got, let expected):
            "\(name) arrived as \(got) bytes, expected \(expected) — not used"
        case .voiceFileEmpty(let name):
            "\(name) held no arrays — that file is not a voice"
        }
    }
}
