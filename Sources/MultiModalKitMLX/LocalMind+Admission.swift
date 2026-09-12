// ADMISSION AND PRESSURE — the mind's two answers to a phone short of
// memory (4y, SPEC §187/1 and §187/3, D-107 F-1 = A and F-3 = A).
//
// Aura's R1 names the jetsam this file exists to prevent: a readiness
// check, THEN a load, with a window between them a second caller — or
// the phone itself — can fall into. And R3 names the other half: a
// memory warning arriving while a generation is running, which today
// the library reports and nothing acts on.

import Foundation
import MLX
import MultiModalKit

// MARK: - the gate (AC-258, AC-259)

/// ONE ADMISSION AT A TIME, and THAT is the mechanism — not a single
/// actor step. The `admitting` flag is raised before the check and held
/// until the load has ENDED (a lock across the whole load, released on
/// every exit), so a second caller's check runs against the number the
/// first caller's allocation left behind, never a stale one. That is
/// AC-258's "no window", made a property of this type rather than a
/// hope about scheduling. (The first cut's comment claimed the check and
/// the allocation were one step with no await between them; the review
/// read `load()` and found its first suspension is the hop INTO the
/// model, long before a byte is allocated. The flag is what the AC-258
/// test proves — remove the wait on it and that row goes red.)
///
/// PRESSURE IS NOT READ HERE. SPEC §187/1 says `admit()` reads "headroom
/// and pressure"; what shipped reads headroom, because no acceptance
/// criterion (AC-258, AC-259) names a pressure verdict at admission,
/// `MindUnavailable` has no case for one, and a level that arrives is
/// acted on by `pressure(_:)` whenever it lands — before, during or
/// after a load. What a `.warning` at the door should mean is an open
/// question, not a ruling this file may make.
///
/// Its own actor, not a field of the model, for one reason: it can be
/// PROVED without weights or a GPU. `LocalMindModel.admit(needing:)`
/// hands it the real load; the two-caller test hands it a scripted one
/// that shrinks the headroom when it begins and parks until the test
/// says so. The model's own door (`readiness()`) refuses on CI before a
/// single byte is read, so the model itself cannot carry this proof.
///
/// The shape is `WhisperEngine.decode`'s and `Retirable.value`'s: a busy
/// flag, a FIFO of waiters, a WHILE loop re-checked after every wake (the
/// reentrancy law), and every waiter woken on exit — because a woken
/// waiter here may return early, so one-at-a-time hand-off would strand
/// the rest (the lesson `Retirable` records).
actor MindAdmission {
    private let headroom: HeadroomReading
    private var admitting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(headroom: @escaping HeadroomReading) {
        self.headroom = headroom
    }

    /// Admits a load of `bytes`, or refuses it typed.
    ///
    /// F-1 = A (D-107): `bytes` is the APP's number — what it measured
    /// for itself — compared to the phone's headroom, which is bytes
    /// REMAINING (D-092: the reader already counted everything resident).
    /// Nothing is inferred from a file size (D-105). `bytes == 0` is
    /// D-105's own shape, "no claim": the load is admitted with no
    /// memory question asked.
    ///
    /// - A KNOWN headroom below `bytes` refuses:
    ///   `ReplyFailure.unavailable(.notEnoughMemory(needed:available:))`.
    ///   `.exhausted` is a known number — zero — and refuses too.
    /// - An UNKNOWN headroom (a Mac; a kernel that would not say) NEVER
    ///   refuses (AC-259, D-092): a number you do not have is not a
    ///   number you may refuse on.
    /// - Weights already RESIDENT are admitted without the question: the
    ///   headroom has already paid for them, and refusing a mind that is
    ///   loaded and answering is exactly the lock-out D-105 removed.
    ///
    /// `resident` is asked INSIDE the gate, after the wait: the holder is
    /// another actor and its answer ages, so the one that decides is read
    /// once no other admission can change it. A `retire()` racing an
    /// `admit()` from the same app is outside this contract — the two are
    /// the app's own hands, and the load door serialises what they do to
    /// the weights either way.
    func admit(needing bytes: Int,
               resident: @Sendable () async -> Bool,
               load: @Sendable () async throws -> Void) async throws {
        while admitting {
            await withCheckedContinuation { waiters.append($0) }
        }
        admitting = true
        defer {
            admitting = false
            let waking = waiters
            waiters = []
            for waiter in waking { waiter.resume() }
        }
        // THE GATE IS UP: from here until the defer above runs, no other
        // admission reads the headroom — `resident()` and `load()` both
        // suspend (each hops to another actor), and the flag is what
        // holds the door across those suspensions, not the absence of an
        // await. The load door's own dedupe (`Retirable.value`) is the
        // second guard beneath it.
        let alreadyResident = await resident()
        if bytes > 0, !alreadyResident,
           let available = headroom().bytes, available < bytes {
            throw ReplyFailure.unavailable(
                .notEnoughMemory(needed: bytes, available: available))
        }
        try await load()
    }
}

// MARK: - the model's door and its hand on the runs

extension LocalMindModel {
    /// ONE admission call (Aura's R1, SPEC §187/1, AC-258, AC-259): read
    /// the phone's headroom and, in the same step, begin the load — or
    /// refuse, typed, before a byte is read. The mechanics and the rules
    /// are `MindAdmission`'s (above); this is the model handing it the
    /// real weights.
    ///
    /// The load it begins is `ensureModelLoaded()`, whose own door
    /// (`readiness()`) runs inside it too — but it is asked HERE first,
    /// before the gate: a Simulator, an absent install or a missing GPU
    /// is refused with THAT verdict, and the memory question is only
    /// ever put to a device that could load. The first cut asked memory
    /// first, and a phone with no weights was told "not enough memory"
    /// — a number about a load that could never have begun. The verdict
    /// is pure and cheap (a disk look, no MLX), so asking it twice costs
    /// nothing and the load door keeps its own guard for its other
    /// callers.
    public func admit(needing bytes: Int) async throws {
        if let verdict = readiness() { throw ReplyFailure.unavailable(verdict) }
        try await admission.admit(
            needing: bytes,
            resident: { [self] in await self.isResident },
            load: { [self] in try await self.ensureModelLoaded() })
    }

    // MARK: pressure (AC-261, AC-262)

    /// What the ACTOR does with a pressure level — the whole of the work
    /// the handler refused to do (AC-263). One step, no await until the
    /// retire: the runs are ended through their own latches, the prefill
    /// is freed, and at `.critical` the weights go too.
    ///
    /// F-3 = A (D-107): a `.warning` CANCELS the generation through the
    /// ticket — every live run ends with no terminal, the way a barge
    /// ends one — and the next turn runs clean. *Rejected:* let it
    /// finish, then release; a warning is a warning, and the finish may
    /// be the kill. `.critical` does the same and then retires the
    /// weights (AC-262); the next `openReply` reloads them through the
    /// same door as the first, which is R4's non-terminal shape.
    ///
    /// `.normal` is the kernel saying the pressure LIFTED — nothing to do.
    func pressure(_ level: MemoryPressureMonitor.Level) async {
        defer { pressureHandled.yield(level) }
        guard level != .normal else { return }
        liveRuns.abandonAll()
        freePrefill()
        guard level == .critical else { return }
        await retire()
    }

    /// Returns the vendor's buffer pool to the system (AC-261's "prefill
    /// memory is released", the half this actor can do at once).
    ///
    /// WHAT FREES THE PREFILL, exactly. The KV cache — the prefill's
    /// product — is owned by the vendor's `TokenIterator`, which lives
    /// inside the vendor's generation task and is released when that task
    /// ends. Cancelling a run cancels that task (its next token sees
    /// `Task.isCancelled`), and `MLXTokenSource.stream` AWAITS it before
    /// declaring the generation over, so the release is a fact and not a
    /// hope. The freed buffers land in MLX's pool only up to
    /// `cacheLimitBytes` (the allocator's `free`: recycle while the pool
    /// is under its limit, else release) — everything past that ceiling
    /// goes back to the system at once. This call, `MLX.Memory.clearCache`
    /// (`mlx_clear_cache`), empties the pool itself, and the source calls
    /// it again on its end path once the iterator is gone. INSTRUMENTS
    /// §68 holds the measured numbers.
    ///
    /// GUARDED, because reading or clearing the allocator constructs it,
    /// and on a machine with no metallib that aborts the process
    /// (`MLXRuntime`'s own note). No MLX, nothing to free.
    nonisolated func freePrefill() {
        guard MLXRuntime.isAvailable else { return }
        MLX.Memory.clearCache()
    }

    // MARK: the generations in flight (the fact a memory test waits for)

    /// A generation has begun on these weights.
    func generationBegan() {
        generationsInFlight += 1
    }

    /// A generation has ENDED — the vendor's task awaited, the prefill
    /// freed. Wakes every `waitForIdle()` when it was the last one.
    func generationEnded() {
        generationsInFlight -= 1
        guard generationsInFlight == 0 else { return }
        let waking = idleWaiters
        idleWaiters = []
        for waiter in waking { waiter.resume() }
    }

    /// Parks until no generation is in flight. The EVENT a live memory
    /// test gates on (AC-261, AC-264): the "after" number is only honest
    /// once the vendor's iterator — and the KV cache it owns — is gone,
    /// and this is the fact that says so. Internal, for `@testable`.
    func waitForIdle() async {
        while generationsInFlight > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }
}
