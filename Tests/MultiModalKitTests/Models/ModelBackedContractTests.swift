import Foundation
import Testing
@testable import MultiModalKit

#if canImport(MultiModalKitWhisper)
@testable import MultiModalKitWhisper
#endif
#if canImport(MultiModalKitTTS)
import TTSKit
@testable import MultiModalKitTTS
#endif
#if canImport(MultiModalKitMLX)
@testable import MultiModalKitMLX
#endif

/// AC-291, AC-294, AC-295 on the PROTOCOL (5a, piece 5; D-114 F-6 = A):
/// every model-backed engine answers the same five questions, and a
/// caller holding `any ModelBacked` can ask them without knowing which
/// engine it has.
///
/// That is the whole reason the members went on `ModelBacked` rather
/// than beside it: the caller is a Models page with a row per engine.
/// These rows stand exactly where that page stands — behind the
/// existential — and ask only what costs nothing: the size, and the
/// install question. Nothing here downloads, and nothing here deletes.
///
/// THE APPLE ENGINE IS NOT HERE and cannot be: it needs macOS 26 and a
/// system asset, so its own rows are below, gated.
@Suite("AC-291/294/295 · the five questions, through the protocol", .timeLimit(.minutes(1)))
struct ModelBackedContractTests {

    /// Every engine this Mac can build, as `any ModelBacked`.
    static var engines: [(name: String, engine: any ModelBacked)] {
        var built: [(String, any ModelBacked)] = []
        #if canImport(MultiModalKitWhisper)
        built.append(("Whisper base", WhisperEngine(model: "base")))
        #endif
        #if canImport(MultiModalKitTTS)
        built.append(("Kokoro", KokoroVoice(weights: KokoroWeights.inApplicationSupport())))
        built.append(("the neural voice", NeuralVoice(variant: .qwen3TTS_0_6b)))
        #endif
        #if canImport(MultiModalKitMLX)
        built.append(("the mind", LocalMindModel(repoID: "nobody/Fake-Model",
                                                 in: FileManager.default.temporaryDirectory
                                                     .appending(path: "contract-\(UUID().uuidString)"))))
        #endif
        return built
    }

    @Test("asking a model-backed engine anything costs no network and no download")
    func theQuestionsAreFree() async throws {
        #expect(Self.engines.count >= 3, "the engines this Mac can build")
        for (name, engine) in Self.engines {
            // `modelInstalled()` and `expectedDownloadBytes()` are the two
            // a screen asks on appear, and neither may reach anywhere.
            _ = await engine.modelInstalled()
            let bytes = engine.expectedDownloadBytes()
            #expect(bytes == nil || bytes! > 0,
                    Comment(rawValue: "\(name): a size is a real number or nothing, never zero"))
        }
    }

    /// The engines whose repositories the LIBRARY chose can name their
    /// bytes before anything is fetched; the one whose repository the APP
    /// chooses cannot, and says so with `nil` rather than a guess
    /// (F-5 = A).
    @Test("the library's own models know their size; the app's model does not pretend to")
    func onlyTheLibrarysOwnModelsPinTheirSize() {
        #if canImport(MultiModalKitWhisper)
        #expect(WhisperEngine(model: "base").expectedDownloadBytes() == 149_484_585)
        #endif
        #if canImport(MultiModalKitTTS)
        #expect(KokoroVoice(weights: KokoroWeights.inApplicationSupport()).expectedDownloadBytes() == 327_637_491)
        #expect(NeuralVoice(variant: .qwen3TTS_0_6b).expectedDownloadBytes() == 1_102_450_874)
        #endif
        #if canImport(MultiModalKitMLX)
        let mind = LocalMindModel(repoID: "nobody/Fake-Model",
                                  in: FileManager.default.temporaryDirectory
                                      .appending(path: "contract-\(UUID().uuidString)"))
        #expect(mind.expectedDownloadBytes() == nil,
                "the app chose this repository; the library has not listed it yet")
        #endif
    }

    /// A variant nobody measured gets no number — the same rule, at the
    /// other end: `expectedDownloadBytes()` is measured, cached, or
    /// `nil`, and never arithmetic on a guess.
    @Test("a variant this library never measured answers nil, not a guess")
    func anUnmeasuredVariantAnswersNil() {
        #if canImport(MultiModalKitWhisper)
        #expect(WhisperEngine(model: "large-v3-nobody-measured").expectedDownloadBytes() == nil)
        #endif
    }
}

/// AC-294 and AC-295 for the Apple engine (5a, piece 5; D-114 F-6 = A) —
/// the one engine whose bytes are the SYSTEM's.
///
/// What can be proved on a Mac without touching a person's installed
/// speech assets is exactly this: that the size question is honest about
/// not knowing, and that releasing a reservation nobody holds is a
/// no-op rather than a throw. The two halves that need the system to
/// really install or really release — the forwarded fraction, and
/// `modelInstalled()` after a release — are Ryad's phone rows (AC-300),
/// named here rather than faked.
@Suite("AC-294/295 · the Apple engine, whose bytes are the system's",
       .enabled(if: AppleEngineAvailability.isSupported, "needs macOS 26"),
       .timeLimit(.minutes(1)))
struct AppleSpeechInstallTests {

    @Test("the size is nil, always: the system owns these bytes and this library will not guess")
    func theSizeIsNil() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(AppleSpeechEngine().expectedDownloadBytes() == nil)
        #expect(AppleSpeechEngine(locale: Locale(identifier: "de_DE")).expectedDownloadBytes() == nil)
    }

    /// The reservation is what this engine owns, and a delete gives it
    /// back. With none held, there is nothing to give back and nothing
    /// to complain about — and, crucially, no system asset is removed:
    /// they are shared with every app on the device.
    @Test("deleting with no reservation held is a no-op, and removes nothing of the system's")
    func deletingWithoutAReservationDoesNothing() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        // A locale this process has certainly not reserved.
        let engine = AppleSpeechEngine(locale: Locale(identifier: "yue_CN"))
        let before = await engine.modelInstalled()

        try await engine.deleteModel()

        #expect(await engine.modelInstalled() == before,
                "the system's assets are untouched — this call released a reservation, not a model")
    }
}

enum AppleEngineAvailability {
    static var isSupported: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { true } else { false }
    }
}
