import Foundation
import Testing
import TTSKit

@testable import MultiModalKitTTS

/// 4l — AC-160. The tokenizer folder must be the one TTSKit actually asks
/// for. The defect (SPEC §118): `localTokenizerFolder` guessed
/// `Qwen/Qwen3-1.7B` for the larger model, but TTSKit hard-wires ONE
/// tokenizer repo for every variant — so the guessed folder is never
/// populated, `modelInstalled()` can never say yes for 1.7B, and every
/// attempt is sent to the network. Exactly the failure the Whisper audit
/// named, reproduced by the file whose comment says it exists to prevent it.
@Suite("the tokenizer folder is the one TTSKit asks for")
struct TokenizerFolderTests {

    @Test("both variants resolve to the SAME tokenizer folder")
    func bothVariantsSameFolder() {
        let small = NeuralVoice(variant: .qwen3TTS_0_6b)
        let large = NeuralVoice(variant: .qwen3TTS_1_7b)
        #expect(small.localTokenizerFolder == large.localTokenizerFolder,
                "TTSKit downloads ONE tokenizer repo for every variant; a variant-specific folder here is a folder nobody fills")
    }

    /// The constant is QUOTED, deliberately. If a vendor bump changes the
    /// tokenizer repo, this fails loudly instead of `modelInstalled()`
    /// silently re-breaking.
    @Test("the folder ends in the vendor's constant, quoted")
    func folderEndsInVendorConstant() {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b)
        #expect(voice.localTokenizerFolder.path()
                    .hasSuffix("huggingface/models/Qwen/Qwen3-0.6B"),
                Comment(rawValue: "TTSKit's defaultTokenizerRepo is Qwen/Qwen3-0.6B for BOTH sizes — was \(voice.localTokenizerFolder.path())"))
        // And the code must READ the vendor rather than restate it: the
        // suffix above pins the value, this pins the source.
        #expect(voice.localTokenizerFolder.path()
                    .hasSuffix(TTSModelVariant.qwen3TTS_1_7b.tokenizerRepo))
    }
}

/// 4l — AC-159. The platform's `no` is honored BEFORE CoreML, and the
/// refusal is provable with no weights on disk.
///
/// The AC-145 lesson, applied: "it threw" is not the assertion, because a
/// test asserting only that passed once with the guard deleted — the error
/// arrived anyway, one full load later. The assertion is `loadAttempts == 0`:
/// the voice never REACHED for the models.
///
/// Why the verdict is injectable: CI runs on macOS, where the vendor's
/// `isAvailableOnCurrentPlatform` is ALWAYS true, so a guard wired straight
/// to it could never be watched firing here. A guard nobody can watch work
/// is not a guard.
@Suite("the platform's no is honored before CoreML")
struct PlatformRefusalTests {

    @Test("a refused variant throws OUR error and never reaches for the models")
    func refusalHappensBeforeAnyReach() async throws {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b,
                                availableOnThisPlatform: false)
        // The THROWN error is caught and its PAYLOAD asserted — not just
        // the type. The D-041 review proved the gap by mutation: with the
        // throw site hard-coding `variant: .qwen3TTS_0_6b`, every test in
        // this file stayed green, and an error whose whole purpose is to
        // name the variant would have named the wrong one.
        do {
            try await voice.ensureModel()
            Issue.record("a refused variant must throw, and this one returned")
        } catch let refusal as NeuralVoiceUnavailableOnPlatform {
            #expect(refusal.variant == .qwen3TTS_1_7b,
                    "the error must carry the variant that was REFUSED")
        }
        #expect(await voice.loadAttempts == 0,
                "a refusal AFTER loading is a 2.2 GB compile spent to learn what the vendor already said")
    }

    @Test("openUtterance refuses through the same door")
    func openRefusesToo() async throws {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b,
                                availableOnThisPlatform: false)
        await #expect(throws: NeuralVoiceUnavailableOnPlatform.self) {
            _ = try await voice.openUtterance()
        }
        #expect(await voice.loadAttempts == 0)
    }

    @Test("the error names the variant and the reason, in our words")
    func errorNamesVariantAndReason() {
        let error = NeuralVoiceUnavailableOnPlatform(variant: .qwen3TTS_1_7b)
        #expect(error.description.contains("1.7B"))
        #expect(error.description.contains("memory"))
        #expect(error.description.contains("macOS"))
        #expect(!error.description.contains("execution plan"),
                "CoreML's sentence about a symptom is exactly what this error replaces")
    }

    /// CONTROL (D-054 rule 5): with the verdict forced TRUE, execution must
    /// pass this guard — proving it is switched on rather than refusing
    /// everything. The retired latch one step BEHIND the guard is the
    /// tripwire: reaching `NeuralVoiceRetired` proves the platform guard
    /// passed a true verdict through, at zero loads and zero network.
    /// (The full-depth control — a default verdict proceeding all the way
    /// to a real load — is every live conformance test in this suite,
    /// which loads this voice on this Mac with `availableOnThisPlatform`
    /// left nil.)
    @Test("CONTROL: a true verdict passes the guard — the tripwire behind it fires instead")
    func controlTrueVerdictPasses() async throws {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b,
                                availableOnThisPlatform: true)
        await voice.retire()
        await #expect(throws: NeuralVoiceRetired.self) {
            try await voice.ensureModel()
        }
        #expect(await voice.loadAttempts == 0)
    }

    /// And the same tripwire proves nil ASKS THE VENDOR: on macOS the
    /// vendor says yes to 1.7B, so a nil verdict must also reach the
    /// tripwire rather than refuse. (The false side of the vendor default
    /// cannot be watched on a Mac — that asymmetry is WHY the verdict is
    /// injectable, and the phone's field run is where the vendor-false
    /// path shows itself: AC-161's screenshot.)
    @Test("nil verdict defaults to the vendor, which says yes on this Mac")
    func nilVerdictAsksTheVendor() async throws {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b)
        await voice.retire()
        await #expect(throws: NeuralVoiceRetired.self) {
            try await voice.ensureModel()
        }
    }

    /// The guard's order against retirement is asserted, not assumed: a
    /// voice that is BOTH retired and platform-refused says the platform's
    /// no, because the device's verdict is about the world and the latch is
    /// about one instance's lifecycle. If someone reorders the guards, the
    /// control's tripwire silently stops proving anything — this failure is
    /// what makes that reorder loud.
    @Test("platform-refused AND retired says the platform's no — order is load-bearing")
    func platformOutranksRetirement() async throws {
        let voice = NeuralVoice(variant: .qwen3TTS_1_7b,
                                availableOnThisPlatform: false)
        await voice.retire()
        await #expect(throws: NeuralVoiceUnavailableOnPlatform.self) {
            try await voice.ensureModel()
        }
    }
}
