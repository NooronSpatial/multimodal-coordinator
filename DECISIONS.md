# DECISIONS

Every design fork, with the options considered and why the chosen one won.
Format: context → options → decision → why → consequences.
Decided by Ryad; options and trade-offs laid out with AI assistance.

---

## D-001 — Microphone access: start with `installTap`, upgrade later (F1)

**Options.** A: `AVAudioEngine.installTap` — easiest, Apple controls buffer
sizes, some added latency. B: `AVAudioSinkNode` — the true real-time callback,
strict rules apply fully. C: raw CoreAudio — maximum control, C API, maximum
complexity.

**Decision: A now, B as a planned documented upgrade.** C only if a concrete
need appears.

**Why.** Sound flowing in week one beats perfection in week four. The A→B
upgrade is itself valuable: a measured before/after and a war story.

**Consequences.** The capture seam must be designed so swapping A for B
changes nothing outside the capture engine (AC-7, AC-8).

---

## D-002 — Ring counters: stdlib `Atomic<Int>`, no locks (F2)

**Options.** A: `Atomic<Int>` from Swift's `Synchronization` module,
acquire/release ordering. B: any lock — rejected outright: the hot thread may
never wait.

**Decision: A.**

**Why.** The hot thread's iron law is "never wait." Atomics don't wait — they
are single CPU instructions with ordering rules. Release publishes ("bytes
are ready"), acquire observes ("I saw that"). No dependencies needed — it's
the standard library.

**Consequences.** SPSC contract only (one writer, one reader) — the simple
atomic scheme is only correct under that contract, and the API must make
breaking it hard. Head/tail padded to separate cache lines (AC-3).

---

## D-003 — Cargo: raw Float32 samples in a pre-allocated slab (F3)

**Options.** A: raw samples copied into a fixed slab; reader copies out on
the cool side. B: passing buffer objects through — allocation and reference
counting on the hot thread. Rejected by the iron laws.

**Decision: A.**

**Why.** Zero allocation on the hot path is not an optimization here — it's a
correctness rule. Copying a few kilobytes is cheap and predictable; touching
the Swift runtime from the audio callback is neither.

**Consequences.** Two copies total (hardware→ring, ring→cool side). Honest
and documented: true zero-copy is a Phase 2+ topic where it actually pays.

---

## D-004 — Backpressure: overwrite oldest, count every drop (F4)

**Options.** A: overwrite oldest — newest speech wins; dropped frames counted
and exposed. B: block the writer — never (hot thread). C: drop newest — keeps
stale audio, loses fresh words. Wrong for live conversation.

**Decision: A.**

**Why.** In a live conversation, old audio loses value by the millisecond.
And a buffer may drop, but it may never lie: the drop counter makes slowness
visible instead of silent.

**Consequences.** The reader can detect and report data loss; tests assert
exact drop counts under scripted overload.

---

## D-005 — The bridge: poll on an injected Clock (F5)

**Options.** A: the pump polls the ring every ~10 ms using an injected
`Clock` — fully deterministic tests via a hand-driven test clock; costs up to
one poll interval of latency. B: wakeup signals from the hot thread — lower
latency, harder tests, care needed with wakeup primitives on real-time
threads.

**Decision: A now; B is the documented upgrade path, to be adopted only with
a measured before/after.**

**Why.** Deterministic testing is this project's superpower and its story.
Ten milliseconds of poll latency is irrelevant for VAD; unreproducible tests
would be fatal.

**Consequences.** All time flows through the injected clock (AC-9, AC-14).
The A→B upgrade, when it comes, gets its own decision entry with numbers.

---

## D-006 — Repo is public; module naming

This is a portfolio project: public from the first commit, clean history,
no reuse of private hiring-task code — the seams are rebuilt fresh, from
understanding. Module name `MultiModalKit`; the future engine type keeps the
name `MultiModalCoordinator` (module ≠ type name, learned the hard way).

---

## D-007 — Ring implementation refinements (found while building 1a)

**1. Only ONE value crosses the thread boundary.** D-002 planned atomic head
AND tail. The build found a simpler truth: the producer never needs to read
`tail` — it always writes, overrun or not. So `tail` became a plain,
consumer-owned variable, and `head` is the single atomic handshake between
the worlds. Simpler to reason about, simpler to defend.

**2. Overruns are handled by clamp + validate-after-copy.** The reader clamps
its start to the newest ring-full (counting skipped frames as dropped),
copies, then re-reads `head`: if the producer lapped into the copied region
during the copy, those bytes are suspect — counted as dropped, one retry
from fresh data, never a spin. The buffer may drop, but it may never lie.

**3. The one `@unchecked Sendable` in the package: `RingStorage`.** The
compiler cannot prove a lock-free SPSC contract — no compiler can. The safety
argument is ours, written down: one producer moves `head`, one consumer moves
`tail`, the slab is raw memory published by a release-store and observed by
an acquire-load, and the two handles are created exactly once as a pair.
Everything else in the package stays compiler-checked.

**4. Noncopyable handles were considered and rejected — for now.** Making the
producer/consumer `~Copyable` would enforce "exactly one of each" at compile
time — but Swift tuples cannot hold noncopyable values yet, which breaks the
natural pair-returning API. Classes with a documented contract won; the
noncopyable upgrade is a tracked idea for later.

---

## D-008 — Events leave the pump through a multicast, not a single stream (A)

**Decision:** the pump publishes to a `Broadcast<AudioEvent>` — many
listeners, each with its own stream, all seeing the same sequence.

**Rejected — one `AsyncStream`, single consumer.** Cheapest option, and it
matches the ring's own one-reader shape. Rejected because the terminal demo
and a future conductor want to watch the same audio at the same time, and
splitting later would change the public seam.

**Rejected — a provider protocol returning one stream.** Same cost, nicer
name, still only one listener.

**The price, stated openly:** multicast needs a `Mutex`-guarded component and
a per-listener buffer policy. That brings back the two lock rules — never
hold the lock across a suspension point, never resume a continuation while
holding it — and the buffer question answered in D-012.

---

## D-009 — A segment is chunks plus a pre-roll (B)

**Decision:** while speech is on, audio is published chunk by chunk; and at
`speechStarted` the pump first publishes the last **2 chunks (40 ms)** it was
already holding.

**Why:** a loudness VAD can only know speech began *after* the first loud
chunk. Without a pre-roll the first syllable is cut — the difference between
a demo and something a speech recogniser can actually use.

**Rejected — one big segment at `speechEnded`.** Simple, but nothing can be
streamed and memory grows with the length of the utterance.

**Rejected — plain chunk-by-chunk.** Cheapest, but it throws away the start
of every word. The fixed-size pre-roll buffer costs a few kilobytes.

---

## D-010 — Dropped frames are an event, not a counter (C)

**Decision:** when the ring reports skipped frames, the pump publishes
`dropped(frames:at:)` at that exact point in the sequence.

**Why:** the ring already counts exactly (D-004). Putting the loss in the
timeline shows *when* the machine fell behind — a counter only shows that it
did, somewhere. Honesty stays visible instead of hiding in a getter.

**Rejected — a pollable counter.** Less code, less truth.

---

## D-011 — Time comes from sample arithmetic, never from a clock (D)

**Decision:** every event carries an `AudioTime` computed as
`framesConsumed / sampleRate`.

**Why:** it is the audio's own time, not the scheduler's. It makes
capture-to-`speechStarted` latency an exact, reproducible number in tests
instead of a measurement that shifts with machine load — and it keeps the
package's rule intact: components stay clockless, time lives with the caller.

**Rejected — a timestamp ring parallel to the audio.** More crossing state,
more to get wrong, and it would measure delivery rather than sound.

**Rejected — timestamping when the pump reads the chunk.** That measures the
poll rhythm, not when the sound actually happened.

---

## D-012 — Listener buffers are bounded, drop-oldest, and counted; events never replay

Two rulings that D-008 forced into the open.

**1. Bounded, drop-oldest, honest.** Each listener gets its own buffer of a
fixed size (64 events). When a listener reads too slowly and the buffer is
full, the **oldest** event is dropped and that listener's own `droppedEvents`
counter goes up. The pump is never blocked by a slow listener, memory can
never grow without limit, and the loss is counted instead of hidden — the
same philosophy as the ring buffer's dropped-frame counting (D-004).

*Rejected — unbounded buffers.* Simpler, and exactly the weakness found in
the hiring-task `Broadcast`: one listener that stops reading grows memory
forever. Building the fixed version here is the whole point.

**2. No replay for events.** A listener that subscribes late receives what
happens **from now on**. The hiring-task `Broadcast` replays the last value,
which is right for *state* ("you are speaking") — but these are events,
moments in time. Replaying `speechStarted` to a listener that arrived ten
seconds later would be a lie about when the sound happened.

*Deferred, not rejected:* if a UI later needs "am I speaking right now", that
is a separate **state** stream, and a state stream may replay.
