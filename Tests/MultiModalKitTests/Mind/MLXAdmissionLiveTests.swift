import Foundation
import Synchronization
import Testing
@testable import MultiModalKit
@testable import MultiModalKitMLX

/// 4y against the REAL model (AC-258/259's Mac row, AC-261, AC-262,
/// AC-264): a real admission on this Mac's own headroom, a real reply
/// cut by a memory warning and by a 200 ms deadline, and MLX's own
/// `activeMemory` before and after each cut — the numbers INSTRUMENTS
/// §68 records. Gated exactly as `MLXContractLiveTests` is — on
/// `MMK_MLX_MODEL` and on `MLXRuntime.isAvailable` — because without a
/// metallib MLX aborts the process (D-061), and the skip says so loudly.
///
/// The pressure source is SCRIPTED even here: the kernel's own warning
/// cannot be asked for, and a test that waited for a real one would wait
/// for the Mac to run out of memory. What is real is everything the
/// level then reaches — the vendor's task, its KV cache, the allocator.
@Suite("4y · admission, pressure and the deadline against the real model, when this machine has it",
       .timeLimit(.minutes(5)), .serialized)
struct MLXAdmissionLiveTests {

    private static var weights: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MMK_MLX_MODEL"] else { return nil }
        let url = URL(filePath: dir)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The gate, and the reason the skip is loud (the 4h review): a
    /// silent early return prints "passed" for a proof that never ran.
    private static func live() -> URL? {
        guard let weights, MLXRuntime.isAvailable else {
            print("SKIPPED (no MMK_MLX_MODEL or no metallib) — set MMK_MLX_MODEL and run "
                  + "Scripts/metallib.sh to make this test REAL")
            return nil
        }
        return weights
    }

    private static let spoken = "Answer in plain prose. No markdown, no lists."
    private static let longQuestion = "Tell me everything you know about the history of Rome, "
        + "from its founding to the fall of the Western Empire, in as much detail as you can."

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// LOADING IS NOT WARMING (INSTRUMENTS §25): the first generation pays
    /// ~1.9 s of Metal pipeline warm-up. A 200 ms deadline against a cold
    /// pipeline would end before the first token, and "partial text" would
    /// be empty for a reason that has nothing to do with the deadline. One
    /// short reply first, so the rows measure the deadline and not Metal.
    private static func warm(_ mind: MLXReplyGenerator) async throws {
        _ = try await mind.reply(to: ReplyContext(
            transcript: "Say hi.", options: GenerationOptions(maxTokens: 3, temperature: 0)))
    }

    // MARK: - AC-258 / AC-259 on this Mac: no headroom number, so admitted

    @Test("admit(needing:) on this Mac reads no headroom, admits, and the weights are resident after")
    func admissionOnThisMacAdmitsAndLoads() async throws {
        guard let weights = Self.live() else { return }
        let model = LocalMindModel(weights: weights)
        #expect(await model.isResident == false)
        // A number far past any phone: this Mac reports no headroom
        // (D-092), so it must NOT refuse — the load door speaks instead,
        // and on this Mac it says yes.
        try await model.admit(needing: 64 * 1_073_741_824)
        #expect(await model.isResident, "admitted, and the load the admission began has landed")
        let resident = MLXRuntime.activeMemoryBytes
        print("AC-258 Mac · resident after admit: \(Self.megabytes(resident))")
        #expect(resident > 0)
        // Resident weights are admitted again without a question — the
        // idempotent half.
        try await model.admit(needing: 64 * 1_073_741_824)
        #expect(await model.isResident)
        await model.retire()
    }

    // MARK: - AC-264: a REAL reply cut at 200 ms, and the memory freed

    @Test("a REAL reply with a 200 ms deadline ends .finished(.deadline) with partial text, and the prefill is freed")
    func aRealReplyEndsOnTheDeadlineAndFreesItsPrefill() async throws {
        guard let weights = Self.live() else { return }
        let model = LocalMindModel(weights: weights)
        let mind = MLXReplyGenerator(model: model, instructions: Self.spoken)
        try await Self.warm(mind)
        await model.waitForIdle()
        let before = MLXRuntime.activeMemoryBytes
        MLXRuntime.resetPeakMemory()

        let facts = Facts()
        let peakSeen = Mutex(0)
        let run = try await mind.openReply(to: ReplyContext(
            transcript: Self.longQuestion,
            options: GenerationOptions(maxTokens: 4096, temperature: 0, deadline: .milliseconds(200))))
        let story = Task<[ReplyUpdate], any Error> {
            var updates: [ReplyUpdate] = []
            for await update in run.updates {
                updates.append(update)
                // The KV cache grows a token at a time: sampled at every
                // token, the largest reading is the active memory the
                // generation actually reached.
                peakSeen.withLock { $0 = max($0, MLXRuntime.activeMemoryBytes) }
                if case .token = update { facts.send("token \(updates.count)") }
            }
            return updates
        }
        let updates = try await Wait4y.settled(story, within: .seconds(30))
        // The AFTER is honest only once the vendor's task is gone —
        // `waitForIdle()` is that fact, not a guess about timing.
        await model.waitForIdle()
        let after = MLXRuntime.activeMemoryBytes
        let cache = MLXRuntime.cacheMemoryBytes
        let peak = max(MLXRuntime.peakMemoryBytes, peakSeen.withLock { $0 })

        let text = updates.compactMap { if case .token(let piece) = $0 { piece } else { nil } }.joined()
        print("AC-264 live · deadline 200 ms · \(updates.count - 1) tokens · said: \(text)")
        print("AC-264 live · active before \(Self.megabytes(before)) · peak during \(Self.megabytes(peak))"
              + " · active after \(Self.megabytes(after)) · cache after \(Self.megabytes(cache))")
        #expect(updates.last == ReplyUpdate.finished(.deadline), "\(updates.suffix(2))")
        #expect(!text.isEmpty, "a warm 0.6B says something inside 200 ms")
        #expect(after < peak, "the KV cache the prefill built is gone once the vendor's task is")
        // Not `== 0`: the first run of this row measured 232 BYTES in the
        // pool after the clear — one small buffer the vendor's final
        // `synchronize()` released after our `clearCache()` ran. The
        // claim that is true is that the pool holds no generation's
        // worth of buffers: kilobytes, not the ~100 MB the peak shows.
        #expect(cache < 65_536, "clearCache() emptied the vendor's pool after the cut: \(cache) bytes left")
        await model.retire()
    }

    // MARK: - AC-261: a .warning during a REAL generation

    @Test("a .warning during a REAL generation ends it with no terminal, and the memory falls back")
    func aWarningDuringARealGenerationFreesItsMemory() async throws {
        guard let weights = Self.live() else { return }
        let pressure = ScriptedPressureSource()
        let model = LocalMindModel(weights: weights, pressure: pressure)
        let mind = MLXReplyGenerator(model: model, instructions: Self.spoken)
        try await Self.warm(mind)
        await model.waitForIdle()
        let before = MLXRuntime.activeMemoryBytes
        MLXRuntime.resetPeakMemory()

        let facts = Facts()
        let run = try await mind.openReply(to: ReplyContext(
            transcript: Self.longQuestion,
            options: GenerationOptions(maxTokens: 4096, temperature: 0)))
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 3"), "the real generation is in flight")
        let during = MLXRuntime.activeMemoryBytes

        pressure.push(.warning)
        #expect(await Wait4y.handled(.warning, on: model))
        let updates = try await Wait4y.settled(story, within: .seconds(30))
        await model.waitForIdle()
        let after = MLXRuntime.activeMemoryBytes
        let peak = MLXRuntime.peakMemoryBytes

        print("AC-261 live · warning after \(updates.count) tokens · active before \(Self.megabytes(before))"
              + " · during \(Self.megabytes(during)) · peak \(Self.megabytes(peak))"
              + " · after \(Self.megabytes(after)) · cache after \(Self.megabytes(MLXRuntime.cacheMemoryBytes))")
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty, "no terminal — like a barge: \(updates.suffix(1))")
        #expect(updates.count >= 3, "the tokens already spoken are kept")
        #expect(after < peak, "the prefill's memory is released")
        #expect(await model.isResident, "a warning keeps the weights")
        #expect(await model.retirements == 0)
        await model.retire()
    }

    // MARK: - AC-262: a .critical retires the weights, and the next reply reloads them

    @Test("a .critical during a REAL generation retires the weights, and the next reply reloads them")
    func aCriticalRetiresAndTheNextReplyReloads() async throws {
        guard let weights = Self.live() else { return }
        let pressure = ScriptedPressureSource()
        let model = LocalMindModel(weights: weights, pressure: pressure)
        let mind = MLXReplyGenerator(model: model, instructions: Self.spoken)
        try await Self.warm(mind)
        await model.waitForIdle()
        let resident = MLXRuntime.activeMemoryBytes

        let facts = Facts()
        let run = try await mind.openReply(to: ReplyContext(
            transcript: Self.longQuestion,
            options: GenerationOptions(maxTokens: 4096, temperature: 0)))
        let story = ReplyStory.collect(run, facts: facts)
        #expect(await facts.heard("token 3"))

        pressure.push(.critical)
        #expect(await Wait4y.handled(.critical, on: model))
        let updates = try await Wait4y.settled(story, within: .seconds(30))
        #expect(ReplyConformanceKit.terminals(in: updates).isEmpty, "no terminal")
        #expect(await model.isResident == false, "the weights were retired")
        #expect(await model.retirements == 1)
        // The container is released when the last hand lets go — the
        // vendor's task holds it until it ends. Idle is that moment.
        await model.waitForIdle()
        let afterRetire = MLXRuntime.activeMemoryBytes
        print("AC-262 live · resident \(Self.megabytes(resident))"
              + " · after critical, idle: \(Self.megabytes(afterRetire))")
        #expect(afterRetire < resident, "retired weights leave the allocator")

        // R4, non-terminal: the next reply RELOADS through the same door.
        let reply = try await mind.reply(to: ReplyContext(
            transcript: "What is the capital of Italy?",
            options: GenerationOptions(maxTokens: 16, temperature: 0)))
        print("AC-262 live · after reload, said: \(reply.text)")
        #expect(!reply.text.isEmpty)
        #expect(await model.isResident, "reloaded")
        await model.retire()
    }
}
