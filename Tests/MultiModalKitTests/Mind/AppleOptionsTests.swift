import Foundation
import FoundationModels
import Synchronization
import Testing
@testable import MultiModalKit

// MARK: - a source that RECORDS what it was asked (AC-232/233/234's witness)

/// A snapshot source that answers one word and writes down what the
/// generator asked it to do — the resolved instructions and the
/// context's options — so the plumbing can be read back without a model
/// in the room. Its door is scriptable too (`refuse(with:)`), for the
/// verdict-at-the-door test.
final class RecordingSnapshotSource: ReplySnapshotStreaming, @unchecked Sendable {
    struct Ask: Equatable, Sendable {
        let instructions: String?
        let options: MultiModalKit.GenerationOptions
    }

    private let asks = Mutex<[Ask]>([])
    private let door = Mutex<MindUnavailable?>(nil)

    var recorded: [Ask] { asks.withLock { $0 } }
    var unavailable: MindUnavailable? { door.withLock { $0 } }
    func refuse(with verdict: MindUnavailable?) { door.withLock { $0 = verdict } }

    func snapshots(for context: ReplyContext,
                   instructions: String?) -> AsyncThrowingStream<String, any Error> {
        asks.withLock { $0.append(Ask(instructions: instructions, options: context.options)) }
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}

// MARK: - the levers reach the seam

/// AC-232 / AC-233 / AC-234, the Apple half (SPEC §175/1, D-103 F-1 = A
/// and F-6 = A): the caller's per-call levers are what the session is
/// built with. Two layers, each tested where it can be:
///
/// 1. the GENERATOR resolves instructions (`options.instructions ??
///    self.instructions`) and hands the context on — testable on any OS
///    through the recording source;
/// 2. the REAL source turns `GenerationOptions` into the vendor's — a
///    pure static, runtime-gated on OS 26 because the vendor's type is.
@Suite("AC-232/233/234 · the Apple mind honours the caller's levers",
       .timeLimit(.minutes(1)))
struct AppleOptionsTests {

    // MARK: 1. the generator resolves and forwards

    @Test("per-call instructions replace the generator's own (AC-232)")
    func perCallInstructionsWin() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let generator = AppleReplyGenerator(source: source, instructions: "speak briefly")
        let context = ReplyContext(
            transcript: "plan my week",
            options: MultiModalKit.GenerationOptions(instructions: "propose a session as JSON"))
        _ = try await generator.reply(to: context)
        #expect(source.recorded == [RecordingSnapshotSource.Ask(
            instructions: "propose a session as JSON", options: context.options)])
    }

    @Test("no per-call instructions: the generator's own are used (AC-232)")
    func generatorInstructionsAreTheFallback() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let generator = AppleReplyGenerator(source: source, instructions: "speak briefly")
        _ = try await generator.reply(to: ReplyContext(transcript: "hello"))
        #expect(source.recorded.map(\.instructions) == ["speak briefly"])
    }

    @Test("the whole options struct travels to the source untouched (AC-231's seam, read here)")
    func optionsTravel() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let source = RecordingSnapshotSource()
        let options = MultiModalKit.GenerationOptions(maxTokens: 2048, temperature: 0.5, seed: 7)
        _ = try await AppleReplyGenerator(source: source)
            .reply(to: ReplyContext(transcript: "hello", options: options))
        #expect(source.recorded.map(\.options) == [options])
    }

    // MARK: 2. the real source speaks the vendor's words

    @Test("the default budget is 1024 — set even when the caller says nothing (AC-233, F-6 = A)")
    func defaultBudgetIs1024() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(for: MultiModalKit.GenerationOptions())
        #expect(vendor.maximumResponseTokens == 1024)
        #expect(AppleReplyGenerator.defaultTokenBudget == 1024)
        #expect(vendor.sampling == nil, "no sampling asked for: the vendor's default")
        #expect(vendor.temperature == nil, "no temperature asked for: the vendor's default")
    }

    @Test("a per-call budget reaches maximumResponseTokens (AC-233)")
    func perCallBudgetReachesTheVendor() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(
            for: MultiModalKit.GenerationOptions(maxTokens: 256))
        #expect(vendor.maximumResponseTokens == 256)
    }

    @Test("temperature 0 is .greedy (AC-234)")
    func zeroTemperatureIsGreedy() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(
            for: MultiModalKit.GenerationOptions(temperature: 0))
        #expect(vendor.sampling == .greedy)
        #expect(vendor.temperature == 0)
    }

    @Test("a seed is .random(top: 50, seed:) (AC-234)")
    func seedIsSeededRandom() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(
            for: MultiModalKit.GenerationOptions(temperature: 0.5, seed: 42))
        #expect(vendor.sampling == .random(top: FoundationModelSnapshots.seededTopK, seed: 42))
        #expect(FoundationModelSnapshots.seededTopK == 50)
        // Binary-exact: 0.5 survives Float → Double unchanged.
        #expect(vendor.temperature == 0.5)
    }

    @Test("temperature 0 beside a seed: greedy wins — there is no randomness to seed")
    func greedyWinsOverASeed() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(
            for: MultiModalKit.GenerationOptions(temperature: 0, seed: 42))
        #expect(vendor.sampling == .greedy)
    }

    @Test("a temperature alone is passed through, and sampling stays the vendor's")
    func temperatureAlonePassesThrough() {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let vendor = FoundationModelSnapshots.vendorOptions(
            for: MultiModalKit.GenerationOptions(temperature: 0.25))
        #expect(vendor.temperature == 0.25)
        #expect(vendor.sampling == nil)
    }
}
