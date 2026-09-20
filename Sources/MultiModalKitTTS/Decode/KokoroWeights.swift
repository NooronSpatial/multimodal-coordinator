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

    /// Where the two files come from and how big they are — the catalog
    /// the downloader is handed (5a, D-114 F-3 = A). The library's is the
    /// Hub mirror above; a test points it at a server of its own.
    public struct Source: Sendable, Equatable {
        public let modelURL: URL
        public let voiceURL: URL
        public let modelBytes: Int64
        public let voiceBytes: Int64

        public init(modelURL: URL, voiceURL: URL, modelBytes: Int64, voiceBytes: Int64) {
            self.modelURL = modelURL
            self.voiceURL = voiceURL
            self.modelBytes = modelBytes
            self.voiceBytes = voiceBytes
        }

        /// The mirror `mlx-audio` uses, at the sizes measured in 4q.
        public static let hub = Source(modelURL: KokoroWeights.sourceURL, voiceURL: KokoroWeights.voiceURL,
                                       modelBytes: Int64(KokoroWeights.sourceBytes),
                                       voiceBytes: Int64(KokoroWeights.voiceBytes))
    }

    public let directory: URL
    public let precision: Precision
    let source: Source
    /// The downloader the bytes go through — the library's shared
    /// background session, or a test's own.
    let downloader: ModelDownloader

    /// The app passes its own Application Support subdirectory. No default
    /// on purpose: a wrong default here writes a third of a gigabyte into
    /// someone else's folder.
    public init(directory: URL, precision: Precision = .float16) {
        self.init(directory: directory, precision: precision, source: .hub, downloader: .shared)
    }

    /// The tests' door: a source of the test's own, on a downloader of the
    /// test's own, so a 327 MB install is proved with two small files.
    init(directory: URL, precision: Precision, source: Source, downloader: ModelDownloader) {
        self.directory = directory
        self.precision = precision
        self.source = source
        self.downloader = downloader
    }

    /// What `ensure` will fetch, before it is asked — the two files'
    /// bytes, known without the network (AC-294, F-5 = A: the library
    /// chose these bytes, so it can pin them). The fp16 cast written
    /// afterwards is disk, not download, and is not in this number.
    public var expectedDownloadBytes: Int64 { source.modelBytes + source.voiceBytes }

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
    ///
    /// The sizes are the `Source`'s, not the statics': one owner for the
    /// byte truth, so the downloader's "complete" and this "installed"
    /// cannot disagree — the first 5a row caught them disagreeing, with
    /// two files complete at their declared sizes and this saying no.
    public func isInstalled() -> Bool {
        exists(voiceFile, bytes: Int(source.voiceBytes))
            && exists(sourceFile, bytes: Int(source.modelBytes))
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

    /// A file that is PRESENT and the WRONG SIZE — nothing else.
    ///
    /// `missingReport()` answers "why not installed", and absent files are
    /// most of that answer: on a first run nothing is there yet and
    /// `ensure()` is about to fetch it. Damage is the different case, and
    /// the dangerous one: the vendor force-tries its weight load, so a
    /// truncated file crashes instead of throwing. A caller that wants to
    /// warn before doing anything wants THIS, not the other.
    public func damagedReport() -> String? {
        let lines = [(sourceFile, Int(source.modelBytes)), (voiceFile, Int(source.voiceBytes))]
            .compactMap { url, expected -> String? in
                guard let found = sizeOnDisk(url), found != expected else { return nil }
                return "\(url.lastPathComponent): \(found) bytes, expected \(expected)"
            }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " · ") + " · in \(directory.path(percentEncoded: false))"
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
        for (url, expected) in [(sourceFile, Int(source.modelBytes)), (voiceFile, Int(source.voiceBytes))] {
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
    /// 327 MB wait on a phone is a bar and not a frozen screen — one
    /// fraction over BOTH files, by bytes, `1.0` once (AC-291).
    ///
    /// SINCE 5a THE BYTES GO THROUGH `ModelDownloader` (D-114 F-1 = A,
    /// F-3 = A): the transfer runs on a background session, so it goes on
    /// while the app is suspended or dead; a cancel keeps its resume data
    /// beside the file and the next call resumes (F-4 = A); a second
    /// call while one runs joins it (AC-296). Before 5a this was
    /// `URLSession.shared`, foreground only, and a stopped download was
    /// thrown away. A file that is present at the WRONG size — a
    /// truncated download — is fetched again: the downloader's own
    /// completeness check is the byte count, the same rule `isInstalled`
    /// has always used.
    ///
    /// The cast runs AFTER the transfer reports `1.0`: a bar at 100 %
    /// while fp16 is written is the honest order, because the cast is
    /// disk work, not download. It is not reached if the process died
    /// mid-transfer; the next `ensure` finds both files complete, asks
    /// the network nothing, and builds it then.
    public func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await downloader.transfer(plan, progress: progress)
        try buildCast()
    }

    /// The two files, as the downloader's plan.
    var plan: DownloadPlan {
        DownloadPlan(files: [
            DownloadPlan.File(source: source.modelURL, destination: sourceFile, expectedBytes: source.modelBytes),
            DownloadPlan.File(source: source.voiceURL, destination: voiceFile, expectedBytes: source.voiceBytes)
        ])
    }

    /// Removes exactly what `ensure` writes (AC-295): the two downloads,
    /// the cast copy and a half-written cast, and whatever the downloader
    /// keeps for a resume — a transfer in flight is stopped first. The
    /// directory itself is the app's and stays, as does anything else the
    /// app put in it. `isInstalled()` reads `false` afterwards.
    public func remove() async {
        await downloader.discard(plan)
        let files = FileManager.default
        for url in [sourceFile, voiceFile, modelFile,
                    directory.appending(path: "kokoro-\(precision.rawValue).partial.safetensors")] {
            try? files.removeItem(at: url)
        }
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
}

/// The decoder's own refusal. A download that arrived short used to be
/// a case here (`incompleteDownload`); since 5a the downloader says it,
/// as `DownloadFailure.shortFile`, with both numbers — the same sentence
/// for every engine.
public enum KokoroWeightsFailure: Error, CustomStringConvertible, Equatable {
    case voiceFileEmpty(String)

    public var description: String {
        switch self {
        case .voiceFileEmpty(let name):
            "\(name) held no arrays — that file is not a voice"
        }
    }
}
