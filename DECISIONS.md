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

---

## D-013 — Event semantics: four small rulings hidden inside the red tests

Writing the expected sequences forced four choices. They are decisions, not
details, so they are written down.

**1. `speechStarted` comes BEFORE the pre-roll chunks it explains** — even
though those chunks carry earlier moments. A listener should learn *that*
speech began before audio arrives; the timestamps still tell the truth about
when each piece of sound happened. *Rejected:* pre-roll first, which keeps
moments monotonic but delivers audio nobody has been told to expect.

**2. `speechEnded` carries the moment the DECISION was made** — the end of the
chunk that spent the hangover — not the moment the sound actually stopped.
*Rejected:* stamping the start of the first quiet chunk, which would pretend
we knew the future; at that moment the pause could still have been a breath
between two words.

**3. The quiet tail inside the hangover is published as audio.** Those chunks
belong to the utterance, and a speech recogniser wants the trailing silence.
*Rejected:* holding them back, which saves a few kilobytes and damages the
thing the audio is for.

**4. `dropped` is stamped where the gap BEGINS**, not where recovery happens —
it points at the hole. A gap also clears the carried partial chunk: those
leftover frames are no longer next to what follows, and pretending otherwise
would splice two moments that never touched.

---

## D-015 — Two counters cross the boundary, not one (D-007 point 1 was wrong)

**The bug.** D-007 celebrated that only ONE value crosses the thread boundary:
`head`, stored after the copy ("first the goods, then the flag"). The reader
validated its copy by re-reading `head`. That check has a hole: the producer
publishes `head` only when its copy is **finished**, so a copy **still in
flight** is invisible. When the reader sits a full ring behind, the producer's
in-flight write lands in exactly the slots the reader is copying — and the
reader returns a mix of old and brand-new frames believing it is clean.

**How it was found.** A single order violation in the 100k-frame stress test,
once in about 35 runs. Chased instead of retried. A probe with the shape the
theory predicted — a slow producer copy (4096 frames) against fast 64-frame
reads — produced **34 violations in 20 rounds**, on demand.

**The fix (option B).** The producer now publishes its **intention** as well as
its result: `reserved` is stored (sequentially consistent) *before* the copy,
`head` (releasing) *after* it. `head` still says how far the consumer may read;
`reserved` says which slots are unsafe, including a copy happening right now.
The consumer clamps and validates against `reserved`, never against `head`.

*Rejected — a "hot zone" margin* (the reader stays `maxWriteFrames` away from
the oldest edge). It works, but it costs usable capacity and adds a second
number to the contract; the fix would be conservative instead of exact.

**The price, stated openly:** two atomics now cross the boundary instead of
one, and the hot path carries one more store. That is the honest cost of the
promise the buffer makes — it may drop, but it may never lie.

**Proof kept:** the probe became a permanent regression test
(`inFlightWritesAreNeverMixedIntoARead`). Verified with teeth: against the old
implementation it fails; against the fixed one, 20 consecutive full-suite runs
pass with zero failures.

---

## D-016 — Dependencies: a tiered policy, not a vow

The old rule ("zero third-party dependencies") came from the hiring task and
was carried into this repo unchanged. It is right for one part of the project
and wrong for the rest, so it is replaced — not deleted.

| Tier | Rule |
|---|---|
| The core library `MultiModalKit` | **Zero runtime dependencies.** No exceptions. |
| Optional engine modules (e.g. `MultiModalKitWhisper`) | Dependencies allowed — separate products, opted into by the consumer |
| Demo / example targets | Allowed freely |
| Tests and dev tooling | Allowed |

**Why the core stays clean:** in a library, dependencies are viral — every
consumer inherits them. And the core is the part that argues for itself: a
package cannot have written the ring buffer, the pump, or the ticket.

**Before adding any dependency, four questions, all must pass:**
1. Is it doing something that is *not* the point of this project?
2. Is it Swift 6 clean — zero warnings, no `@preconcurrency`?
3. Permissive licence, actually maintained?
4. Could we remove it in a day — i.e. does it live behind one of our protocols?

Question 4 is the load-bearing one. **A dependency behind a protocol is a
decision; a dependency woven through the code is a marriage.**

---

## D-017 — Two engines, one contract (F1 = B + D)

**Decision:** Phase 2 ships **Apple's `SpeechAnalyzer` + `SpeechTranscriber`**
inside the core library, and a **separate optional product** for a
Whisper-class engine. Both implement the same `TranscriptionEngine` protocol
and both must pass the same conformance kit.

**Why Apple's first:** it is the current API (it replaces `SFSpeechRecognizer`),
built for streaming, on-device by design, no model files in the repo, and it
gets to real words in days instead of weeks.

**The price, stated openly:** the platform floor moves to **macOS 26 / iOS 26**.
Anyone on an older OS can no longer build the library. Accepted deliberately
for a 2026 portfolio project.

**Why a second engine at all:** because two engines behind one contract turn
"the seam works" from a claim into a test, and they make a bake-off possible —
same audio, measured accuracy, latency, memory. A measurement is worth more
than an opinion.

**Rejected — `SFSpeechRecognizer` as the primary.** Keeps the old platform
floor, but it is the legacy API and the weaker streaming story. Still reachable
through the seam if Apple's new engine disappoints.

**Deferred, not rejected — writing the whole CoreML decoder ourselves** (mel
features, encoder, autoregressive decode with KV cache, tokenizer). That is a
project, not a milestone, and it belongs with the Metal/C++ phase. Until then
the optional module may lean on an existing package (allowed by D-016, tier 2)
and can be replaced later behind the identical protocol.

**Two things this ruling adds to the spec:**
- an `EngineCapabilities` value every engine declares (`emitsPartials`,
  `wantsWholeUtterance`, `requiredSampleRate`, `maximumUtterance`), so a
  streaming engine and a batch engine can both live behind one protocol;
- an **engine conformance kit**: one shared test suite every engine must pass.
  Switching engines becomes provable instead of hopeful.

**First task of the milestone: a spike.** The API is new; nothing gets
specified in code before it has been run.

---

## D-018 — The pipeline keeps its shape (F2, F3)

**Boundaries stay ours.** `EnergyVAD` decides where an utterance starts and
ends — not Apple's `SpeechDetector`, not the transcriber's own endpointing.
The boundaries stay deterministic and testable on fake time, and they are part
of what this repo is showing. *Rejected:* handing turn-taking to the engine —
it would make our own behaviour depend on a model we cannot test.

**Audio reaches every engine through an adapter.** Our chunks are converted to
whatever the engine wants (format, sample rate). *Rejected:* letting the engine
tap the microphone itself — that opens a second capture path and destroys the
"exactly one crossing" claim the whole library is built on.

---

## D-019 — The utterance ticket (F4)

Each utterance carries a number that only goes up. Every result from an engine
is checked against it in the **same actor step** that could raise it. A result
belonging to a finished or abandoned utterance is dropped and can never reach a
listener — proven by a defiant fake that answers late, on purpose.

*Rejected — trusting cancellation.* Cancellation is a request, not a kill: an
engine may still deliver one last result after being cancelled. Cancellation is
the optimisation; the ticket is the guarantee. Same law as the barge-in work.

---

## D-020 — Partials, the tail, and the ceiling (F5, F6, F7)

**Every partial is published** (F5). A UI wants them, and the bounded listener
buffers (D-012) already protect a slow consumer. Throttling can come later,
with measurements instead of a guess. Partials always **replace** — never
append: a batch engine may rewrite a whole window.

**The hangover tail is kept** (F6) — Phase 1's open question, now closed. The
300 ms of trailing quiet is fed to the engine, because recognisers use it to
settle a final result. Revisit with numbers once the real engine runs.

**An utterance has a ceiling** (F7): 30 s by default, then a `truncated` event
and the audio is released. Nothing in this library grows without a limit —
same rule as the ring (D-004) and the listener buffers (D-012).

---

## D-021 — Session semantics: four rulings found inside the red tests

**1. A new utterance retires the settling one.** After `speechEnded` an engine
is still "settling" — its final has not arrived. The moment the NEXT
`speechStarted` lands, the old run is cancelled and its ticket dies: a late
final from it is dropped. *Rejected — true overlap* (old text arriving after
the new utterance's events): deterministic ordering wins for v1; overlap can
return as a measured fork later. Same philosophy as barge-in: newer speech
outranks stale text.

**2. A text event is stamped with the audio already fed** to its run when the
text was published — so capture→partial latency is exact arithmetic
(`at − speechStarted`). The utterance's own start is already public, so both
numbers exist.

**3. A truncated utterance still gets its final.** The ceiling publishes
`truncated`, stops feeding, and settles the run — thirty seconds of words do
not vanish because second thirty-one arrived. *Rejected:* truncate-as-abandon.

**4. An open-failure is stamped at the utterance's start** — no audio was ever
fed, so the start is the only honest moment it has.

---

## D-022 — Three findings from the 2a audit, ruled (F-a, F-b, F-c)

**1. The VAD gets its seam** (`VoiceActivityDetecting` + `SpeechTransition`).
D-018 ruled that utterance boundaries are OURS — but the pump named the
concrete `EnergyVAD` type, which made the ruling true in prose and false in
code. The pump now judges through the protocol; the adaptive or model-based
detector the field runs are already asking for can arrive without touching
the pump's signature.

**2. The fakes become their own product** (`MultiModalKitTesting`).
`ManualClock`, `FakeMicrophone` and `ScriptedTranscriber` were compiled into
the core library — every consumer shipped our test doubles. They are a gift
worth giving (consumers can test their own integrations deterministically),
but a gift is offered, not forced: a second library product in the same
package. The core stays lean; the gift stays one import away.

**3. `Broadcast` moves to `Concurrency/`.** It always was generic
infrastructure — the transcription session uses it as much as the pump does.
The folder now says so.

Also recorded from the audit, deliberately NOT changed: `AppleSpeechEngine`
is not TDD-able — `SpeechAnalyzer` is a final class with no seam behind it,
so the adapter stays deliberately THIN (convert, feed, tear down; no
decisions) and is verified by the conformance kit on real hardware. The
testing boundary is named in the README instead of pretended away.

---

## D-023 — The Whisper engine rides on WhisperKit (F1, F3, F5)

**Decision:** `MultiModalKitWhisper` (a separate product, D-016 tier 2)
wraps **WhisperKit** — since v1.0.0 part of the Argmax OSS SDK
(`argmax-oss-swift`), MIT — with the **base** model, downloaded on first use
through the dependency's own model hub and surfaced through the same
`modelInstalled()` / `ensureModel()` surface as the Apple engine. No fake
partials: `emitsPartials: false` is the truth, and UIs can say "thinking…"
because the capability flag exists.

**The four D-016 questions, answered:**
1. *Not the point of the project?* Running Whisper is not — the seam, the
   session and the measurement are. Our own CoreML port stays the Phase-4
   showcase.
2. *Swift 6 clean?* Claimed by the project as of v1.0.0 — verified by spike
   before any repo code depends on it.
3. *Licence, maintenance?* MIT; actively maintained (v1.0.0, 2026-05).
4. *Removable in a day?* Yes — it lives entirely behind
   `TranscriptionEngine`, and the conformance kit defines what any
   replacement must do.

*Rejected — whisper.cpp:* drags the Metal/C++ phase forward prematurely.
*Rejected — bundling weights:* repo bloat. *Rejected — `tiny` as default:*
it would bias the bake-off against Whisper.

---

## D-024 — Overlap for batch engines (F2; amends D-021 ruling 1)

**Decision:** retirement becomes **capabilities-driven**. For engines that
emit partials (streaming), a new `speechStarted` retires the settling run —
today's behavior, unchanged. For `wantsWholeUtterance` engines (batch), a
settling run **survives** the next `speechStarted`: its final is published
late, tagged with its own utterance number, and listeners — who already
upsert by number — place it correctly. One run feeds at a time; several may
settle. Every settling run keeps its ticket until its final, its failure,
the ceiling, or `stop()`.

**Why D-021.1 had to bend:** it was written when finals arrived in
milliseconds. A batch engine answers in seconds — under strict retirement
its results would die routinely; the second engine would be born broken.
The amendment is this new entry; the old one stands as written, per the
rule that decisions are never silently edited.

*Rejected — strict retirement for everyone:* kills batch engines.
*Rejected — serializing utterances:* queues unbounded audio and destroys
conversational latency.

---

## D-025 — The bake-off is honest or it is nothing (F4)

A fixed paragraph is written into the repo BEFORE recording — the reference
transcript is known in advance. Ryad reads it aloud; **the reader's accent
is the point of the experiment** (the finding that motivated this
milestone). Recorded once, committed as small WAV fixtures.

Measured per engine, same audio, same machine, stated: word error rate
against the reference · capture→final wall-clock latency · model size on
disk · peak memory. **Stated as NOT measured:** battery, thermal, other
languages, far-field microphones. Runners: a macOS CLI and the iOS demo's
engine picker — the iPhone being the one machine holding both models today.
