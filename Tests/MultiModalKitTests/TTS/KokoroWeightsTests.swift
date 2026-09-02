import Foundation
import Testing

#if canImport(MultiModalKitTTS)
@testable import MultiModalKitTTS

/// WHAT "INSTALLED" MEANS FOR THE SECOND MOUTH (4q, D-084, D-078).
///
/// No model, no network, no device. Every fact here is a file on disk and
/// a size, which is the whole point: the rule these tests pin is the one
/// that decides whether the app tries to speak with a broken download.
///
/// The fault they exist to prevent is specific and was met in 4p. The
/// vendor's `KokoroTTS.init` **force-tries** its own weight load, so a
/// truncated file — a dropped connection, a captive portal serving an
/// HTML error page — does not throw. It crashes the process. `fileExists`
/// cannot tell that apart from success; a byte count can.
@Suite(.timeLimit(.minutes(1)))
struct KokoroWeightsTests {

    /// A directory that cleans itself up, so a failing test cannot leave
    /// fixtures behind. §52's leaked-fixture lesson, applied by default.
    static func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kokoro-weights-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// A file of exactly `bytes`, made SPARSE by truncating rather than
    /// by writing. The real weights are 327 MB and these tests speak
    /// about their size, not their content — allocating a third of a
    /// gigabyte per assertion would make an honest test suite expensive
    /// enough to be skipped, which is how suites rot.
    static func write(_ url: URL, bytes: Int) {
        // `percentEncoded: false`, the same rule the type under test had
        // to learn: this helper's first version used `path()` and wrote
        // Fact 8's fixtures into a `%20` folder, so the test was red for
        // a second, different reason than the one it was written for.
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: UInt64(bytes))
        try? handle.close()
    }

    /// Fact 1. Nothing on disk is not installed — and the question costs
    /// no network, which is `ModelBacked`'s first promise.
    @Test("an empty directory is not installed")
    func anEmptyDirectoryIsNotInstalled() {
        Self.withTemporaryDirectory { directory in
            #expect(!KokoroWeights(directory: directory, precision: .float32).isInstalled())
            #expect(!KokoroWeights(directory: directory, precision: .float16).isInstalled())
        }
    }

    /// Fact 2 — **THE ONE THAT EARNS THE BYTE COUNT.**
    ///
    /// A weight file that is PRESENT but the wrong size is exactly what a
    /// half-finished download leaves behind, and it is indistinguishable
    /// from success to anything that only asks whether a file exists.
    /// Answering yes here hands a truncated file to a vendor that force
    /// tries its load, which is a crash rather than an error.
    @Test("a truncated weight file is not installed, however present it looks")
    func aTruncatedWeightFileIsNotInstalled() {
        Self.withTemporaryDirectory { directory in
            let weights = KokoroWeights(directory: directory, precision: .float32)
            Self.write(weights.voiceFile, bytes: KokoroWeights.voiceBytes)
            Self.write(weights.sourceFile, bytes: KokoroWeights.sourceBytes - 1)
            #expect(FileManager.default.fileExists(atPath: weights.sourceFile.path()),
                    "the file IS there — which is the trap")
            #expect(!weights.isInstalled(), "one byte short is not installed")
        }
    }

    /// Fact 3. The voice is not optional. A model with no voice cannot
    /// speak, so "installed" must mean both files.
    @Test("weights without a voice are not installed")
    func weightsWithoutAVoiceAreNotInstalled() {
        Self.withTemporaryDirectory { directory in
            let weights = KokoroWeights(directory: directory, precision: .float32)
            Self.write(weights.sourceFile, bytes: KokoroWeights.sourceBytes)
            #expect(!weights.isInstalled())
        }
    }

    /// Fact 4. At fp32 the download IS the model file — there is nothing
    /// to cast, so both correct files are enough.
    @Test("fp32 is installed as soon as both downloads are whole")
    func float32IsInstalledWithoutACast() {
        Self.withTemporaryDirectory { directory in
            let weights = KokoroWeights(directory: directory, precision: .float32)
            Self.write(weights.sourceFile, bytes: KokoroWeights.sourceBytes)
            Self.write(weights.voiceFile, bytes: KokoroWeights.voiceBytes)
            #expect(weights.isInstalled())
            #expect(weights.modelFile == weights.sourceFile,
                    "fp32 opens the download itself, never a copy")
        }
    }

    /// Fact 5. **fp16 needs one more file than fp32**, and until the cast
    /// exists the app is not offline-capable at that precision — even
    /// though both downloads are perfect.
    ///
    /// This is the difference D-084's default rests on: fp16 is chosen
    /// because §55 measured it ~180 MB cheaper at identical speed, and the
    /// price is a conversion step that has to be done before it counts.
    @Test("fp16 is not installed until the cast copy exists")
    func float16NeedsItsCast() {
        Self.withTemporaryDirectory { directory in
            let weights = KokoroWeights(directory: directory, precision: .float16)
            Self.write(weights.sourceFile, bytes: KokoroWeights.sourceBytes)
            Self.write(weights.voiceFile, bytes: KokoroWeights.voiceBytes)
            #expect(!weights.isInstalled(), "the downloads are whole; the cast is not made")
            #expect(weights.modelFile != weights.sourceFile,
                    "fp16 opens its own file, never the fp32 download")

            Self.write(weights.modelFile, bytes: 8)
            #expect(weights.isInstalled())
        }
    }

    /// Fact 6. Two precisions never collide on one path. They live side by
    /// side in the same directory, so switching does not mean re-fetching
    /// 327 MB.
    @Test("each precision has its own file")
    func precisionsDoNotShareAFile() {
        Self.withTemporaryDirectory { directory in
            let paths = KokoroWeights.Precision.allCases.map {
                KokoroWeights(directory: directory, precision: $0).modelFile
            }
            #expect(Set(paths).count == paths.count)
        }
    }

    /// Fact 8 — **THE FIELD BUG, PINNED. A directory with a space in its
    /// name.**
    ///
    /// iOS puts these weights under `Library/Application Support`, and
    /// the first field run of this mouth reported every file ABSENT after
    /// a seventeen-minute download that had in fact succeeded. The
    /// report printed the directory as `Application%20Support` — because
    /// `URL.path()` percent-encodes BY DEFAULT, and a path string with a
    /// literal `%20` names a folder that does not exist. `FileManager`
    /// was asked about the wrong place while the URL-based calls beside
    /// it wrote to the right one.
    ///
    /// Seven tests above passed against a temporary directory with no
    /// space in it. This one has a space, and it is the one that would
    /// have gone red on the Mac instead of on the phone. The Qwen mouth
    /// wrote the same lesson beside its own check a year ago: "writing
    /// down where a file OUGHT to be instead of asking where it IS."
    @Test("a directory with a space in its name is still checked correctly")
    func aDirectoryWithASpaceIsCheckedCorrectly() {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "kokoro weights \(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let weights = KokoroWeights(directory: parent, precision: .float16)
        Self.write(weights.sourceFile, bytes: KokoroWeights.sourceBytes)
        Self.write(weights.voiceFile, bytes: KokoroWeights.voiceBytes)
        Self.write(weights.modelFile, bytes: 8)

        #expect(weights.isInstalled(),
                "every file is present and the right size; only the path has a space")
        #expect(weights.missingReport() == nil)
    }

    /// Fact 7. The failure says the numbers, because "download failed" is
    /// not something a person can act on and "arrived as 12 bytes,
    /// expected 327,115,152" is.
    @Test("an incomplete download names both sizes")
    func incompleteDownloadNamesBothSizes() {
        let failure = KokoroWeightsFailure.incompleteDownload(
            name: "kokoro-v1_0.safetensors", got: 12, expected: 327_115_152)
        #expect(failure.description.contains("12"))
        #expect(failure.description.contains("327115152"))
    }
}
#endif
