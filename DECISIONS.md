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

---

## D-026 — Signposts: dark audio thread, bright everywhere else (F1, F2, F5)

**Where they live (F1 = A):** pump, session, and engines only. The audio
thread stays completely dark — `os_signpost`'s fast path is cheap, but its
slow paths (full trace buffer, first-use registration, formatting) are
closed source and not documented real-time-safe. The asymmetry ruled:
nanosecond-scale numbers for a memcpy-plus-two-atomics callback, against an
audible glitch whose cause vanishes when you remove the instruments to look
for it. The capture side's story still crosses through the atomics it
already writes; ring occupancy at drain IS capture pressure, measured one
step past the legal border. *Rejected:* signposting the tap callback — the
iron laws do not take probabilistic exceptions; that absoluteness is what
makes them defensible.

**Release builds keep them (F2 = A):** near-zero when no instrument
listens, and an excellent product is diagnosable in the field, not only in
the lab.

**The seam is injected, never global (F5 = A):** a `PipelineDiagnostics`
object handed in like the clock. *Rejected:* a static logger reachable from
anywhere — globals are how observability quietly becomes coupling.

---

## D-027 — Health is a stream; thermal is observed, never obeyed (F3, F4)

**Delivery (F3 = A):** `Broadcast<HealthEvent>` — bounded, drop-oldest,
counted, no replay; D-012's rules unchanged. One delivery idiom everywhere:
a consumer that learned `listen()` once knows the whole library.

**Thermal (F4 = A): mechanism now, policy later.** The pipeline reports —
thermal transitions, ring drops, listener losses, settling-decode count —
and the CONSUMER decides. Three apps have three correct answers to
".serious" (never degrade / degrade silently / stop entirely), and a
library that silently picks one betrays the other two. Self-throttling
also turns knobs blind before INSTRUMENTS.md exists: nobody yet knows
whether the poll rhythm even registers next to one Whisper decode.
*Deferred, not rejected:* an opt-in ThermalPolicy component returns as its
own fork once the numbers exist — same destination, reached with evidence,
shipped as a choice.

**Thermal reaches the pipeline through a seam** (`ThermalStateProviding`):
the real provider wraps ProcessInfo; tests script transitions by hand. No
test ever depends on a real device's temperature.

---

## D-028 — ThermalPolicy: a seam with a conservative default (Phase 3b fork = B)

The D-027 deferral comes due: the numbers exist (INSTRUMENTS.md), and
they reveal exactly one lever — the settling decode, optional comfort
work (D-024), 110 ms ANE bursts, ×2–3 under contention; everything else
measured too cheap to matter (pump 0.1 % core) or system-owned (Apple's
settle). Ruled: an injected `ThermalPolicy` seam gating ONLY the move to
the settling table, with a shipped default — allow below `.serious`,
refuse at `.serious`/`.critical` — dormant on a cool device. Refusals
are loud: a named failure on the utterance, a health event, spans ended
at the refusal.

*Rejected — A, document-only:* every app re-implements the same policy
and the paid-for numbers stay decorative. *Rejected — C, measure-first:*
the attribution confound (a pre-warmed phone) is real, but the default
is dormant below `.serious`, so unproven need costs nothing at runtime;
attribution stays an open question in INSTRUMENTS.md rather than a
blocker. D-027's boundary holds: the pipeline never stops listening on
its own — the policy can only decline optional work, never the live
turn.

---

## D-029 — The turn seams: streaming replies, evidence-reporting synthesis (Phase 4a forks F2 = A, F4 = A)

**Date:** 2026-08-12 · **Decided by:** Ryad

`ReplyGenerating` answers with a TOKEN STREAM, not a whole string: early
synthesis start and mid-generation barge-in both need tokens as they are
born, and every seam in this library is streaming-first — a whole-reply
seam would be its first non-streaming citizen. *Rejected:* one string back
(simpler, but locks the loop into wait-for-everything and makes
mid-generation barge meaningless).

`SpeechSynthesizing` REPORTS — started / finished / failed — and the
coordinator's `speaking` state follows those reports. *Rejected:* the
coordinator assuming `speaking` the moment it hands tokens over — the
house rule everywhere else is that state follows evidence, never
assumption (the pump's verdicts, the session's tickets, the thermal
baseline), and the scripted synthesizer makes the honest version fully
testable today.

---

## D-030 — TurnCoordinator lives in core; state = enum + one funnel; state is queryable, events replay nothing (Phase 4a fork F3 = A)

**Date:** 2026-08-12 · **Decided by:** Ryad

The coordinator is the library's namesake and carries zero dependency
weight (it holds seams, never engines) — it lives in `MultiModalKit`.
*Rejected:* a separate product — its argument was size, not kind.

State machine: a `TurnState` enum and ONE transition funnel validating
every change against an explicit legal-pair table; no state write outside
the funnel. One place to point at: this function IS the state machine.
*Rejected:* implicit state in control flow (transitions scatter; proving
legality means auditing every path) and a generic interpreted transition
table (machinery for machinery's sake at four states).

Late listeners: `Broadcast` stays no-replay (D-012 unchanged) — but the
current state is queryable on the actor. A late subscriber asks for NOW
and then listens; history is not replayed, it is asked for. Same shape as
the diagnostics baseline rule.

---

## D-031 — Barge-in = the pump's `speechStarted`; the ticket doctrine promoted to turns (Phase 4a fork F1 = A)

**Date:** 2026-08-12 · **Decided by:** Ryad

The barge trigger is the earliest signal the system has: the pump's
`speechStarted`. A first-partial fallback is structurally unnecessary in
THIS pipeline — no recognition exists before the pump has fired
`speechStarted`, by construction. *Rejected for 4a:* text-confirmed
barge-in (`speechStarted` + first partial) — robustness against the
assistant hearing itself, bought with latency at the most
latency-sensitive moment, for an echo that cannot exist while the stages
are scripted and silent. **The fork formally re-opens at 4b** when real
audio makes it real.

Mechanism: hybrid, as everywhere in this library — structured
cancellation reclaims resources promptly; the monotonic turn ticket,
raised in the same actor step as the retiring transition, is the
correctness invariant. Each covers the other's gap. The input side gets
the same treatment: only the CURRENT utterance's final may open thinking;
a stale settled final (D-024) is comfort text, never a reply trigger.

---

## D-032 — Turn latency: clock instants + an injectable `LatencyReporter` (R2, mid-4a)

**Date:** 2026-08-12 · **Decided by:** Ryad

Raised by Ryad during 4a review: the coordinator measured nothing. Ruled:
instants captured INSIDE the actor at the semantic boundaries — final
accepted → the synthesizer's `started` evidence (the felt pause), and
barge accepted → both stage cancels acknowledged (the interruption cost,
belonging to the turn that died) — computed as `Duration`s and handed to
an injectable `LatencyReporter`. The measurement shares the pipeline's
clock and its isolation, so it can never race the thing it measures.
Injected as a PAIR with the clock: no reporter, no clock reads — the
default coordinator stays fully clockless. *Rejected:* wall-clock
timestamps (nondeterministic, banned by the house rules) and an external
telemetry actor (a cross-actor hop at exactly the boundary being
measured — observation ordering becomes its own race).

Proven the deterministic way: a manual clock advanced 250 ms between the
final and the `started` evidence reports EXACTLY 250 ms; and cancel
latency in mock time is EXACTLY zero — structural teardown contains no
clock waits, or the test would say so.

---

## D-033 — Post-reply state: idle, not listening (R1)

**Date:** 2026-08-12 · **Decided by:** Ryad

After a reply is fully spoken the coordinator returns to `idle` —
diverging DELIBERATELY from the author's earlier private precedent, where
the same four-state machine went speaking → listening, with a silence
window as the only exit to idle. The precedent's rationale was real:
THERE, the state machine owned wakefulness — idle meant deaf — so
returning to listening was the only way to keep the conversation hot.
HERE, the pump never sleeps: the microphone hears at every moment, and
`listening` is an OBSERVATION (an utterance is in flight, its ticket
alive), never a posture. Entering it after a reply would claim an
utterance that does not exist — a ghost ticket — and leaving it again
would demand a clock in the core loop plus a policy number ("how much
silence?") that D-027 assigns to the app. The UX is identical either
way: the next word opens a turn instantly, because deafness was never
attached to the state.

*Rejected:* adopting the precedent's semantics — a silence window, an
injected clock, and a turn with no evidence behind it: three costs to
buy a word. The zero-token path (thinking → idle on an empty reply)
follows the same reasoning.

---

## D-034 — Utterance identity is born at the source (the review's mirror finding)

**Date:** 2026-08-13 · **Decided by:** Ryad

The adversarial review's major catch: the session and the coordinator each
COUNTED `speechStarted` on their own broadcast listener to derive utterance
numbers — and the transport is legally allowed to show two listeners two
different event sets (no replay; bounded drop-oldest, D-012). One event
seen by one listener and not the other desynchronized the counts FOREVER:
every reply answering the PREVIOUS question, or permanent muteness —
undetected, unhealable. The suite was green over it because a single-stream
test bench cannot express a two-listener set mismatch.

Ruled: identity travels WITH the evidence. The pump — the one place an
utterance is born — assigns its number and carries it inside
`speechStarted(utterance:at:)`. The session ADOPTS the number; the
coordinator READS it; nobody counts anything downstream. A lost onset now
costs exactly its own utterance (that final fails the identity door and
dies — correct) and the very next event heals the view. The regression
test drives the exact corruption scenario and proves the heal.

*Rejected:* detect-and-resync heuristics — shrinks the window, closes
nothing, and the doctrine demands stale events be PROVABLY inert.
*Rejected:* documenting it as a known limit — a law with a waiver is not
a law. Cost accepted: `AudioEvent.speechStarted` gained a field (pre-1.0,
we own every consumer).

---

## D-035 — The onset debounce: five rulings, all A (Milestone 1d, forks F-1..F-5)

**Date:** 2026-08-13 · **Decided by:** Ryad

Field evidence (commit 5be72ac): a 0.01 gate on the Mac's ambient flapped
`speechStarted` every 0.84 s like a metronome — and since D-031 a false
onset is a barge trigger, able to kill a live reply. Ruled: loud must
PERSIST for an onset window (frames, clockless) before `speechStarted`.
The hangover's mirror: quiet must persist to end, loud must persist to
begin. Five forks, all ruled A:

1. **Where (F-1):** inside `EnergyVAD`, beside the hangover. *Rejected:*
   a decorator VAD — the seam speaks only in transitions, so a wrapper
   would need a second RMS judge; the pump — a bridge, not a judge
   (D-018/D-022 boundary).
2. **What counts (F-2):** strictly consecutive loud frames; one quiet
   chunk kills the candidate. *Rejected:* a tolerance budget — kinder to
   breathy onsets but more knobs and harder to prove; the D-008 drawer
   (a smarter VAD later).
3. **The stamp (F-3):** the chunk that completes the window — a decision
   stamp, consistent with D-013's `speechEnded`; the seam is unchanged.
   *Rejected:* backdating via `speechStarted(framesBack:)` — the seam
   grows for one implementation's knob, and the true onset is already
   recoverable from the pre-roll chunks' own stamps.
4. **The pre-roll law (F-4):** the caller wires `preRollChunks` ≥ the
   window in chunks — documented at both configs, proven by a pump-level
   test (no beheaded words). *Rejected:* auto-sizing through a widened
   seam — every future VAD would answer a question only this one has.
5. **The default (F-5):** 0 = off; the library is byte-for-byte unchanged
   (the D-028 precedent) and each product earns its own number. The demo
   carries the field-tuned example (2,880 frames = 60 ms at 48 kHz).
   *Rejected:* default-on — silently changes every caller and adds 40 ms
   of barge latency nobody asked for.

Cost accepted and written in the spec: every TRUE onset (and therefore
every barge-in) is delayed by the window. The number must stay small,
and it is the caller's number.

---

## D-036 — The field overruled the window: OFF for the Mac demo (1d fork F-6 = B)

**Date:** 2026-08-13 · **Decided by:** Ryad

The window shipped per D-035 and the field convicted it the same day.
Ryad's report — "words get lost, quality below pre-1d" — led to a
controlled A/B (`--onset 60` vs `--onset 0`, same voice, same fixed
paragraph, forensic 🔎 lines per utterance). Verdict, two positional
repeats: **"Riyadh" → "Riyat"** and **"error rate" → "rate"** — both
word onsets clipped where an utterance opens after quiet. The mechanism:
D-035's spec priced the window as 40–80 ms of latency, but at a marginal
gate (speech peaks 0.05–0.11 against 0.02) a soft onset FLICKERS, and
F-2's strict-consecutive rule kills the candidate at every 20 ms dip —
the door opens late (clipped beyond pre-roll's reach) or never. Against
this cost the quiet-room benefit measured ZERO: the 0.02 gate alone had
already earned clean runs (5be72ac) before the window existed.

Method note, on the record: the first A/B's no-window arm showed five
noise utterances and nearly bought the window a smaller-number verdict
(40 ms) — then Ryad disclosed a confound (his kid was audible in that
arm) and the arm was re-run clean: the noise vanished with the kid, not
with the window. The confession changed the ruling. Instruments and
honesty, not impressions.

Ruled (F-6 = B): the Mac demo runs with the window OFF (`--onset` flag
kept for experiments). The library keeps the mechanism exactly as
D-035 built it — default-off, byte-for-byte, deterministically proven.

**The iOS question, answered without a test:** the iPhone demo never
carried the window (default 0 = the old door, pinned by AC-74), so 1d
changed nothing there and there is no observed disease to cure. The
deeper lesson is recorded as a standing rule: a MARGINAL-GATE machine
(the iPhone: 0.01, arm's-length soft speech) is precisely where
strict-consecutive clips worst — the machine that most wants a window
is the machine this window hurts most. If any platform's field ever
demands a window over soft speech, **fork F-2 reopens FIRST toward a
tolerance budget** (loud must dominate a window, dips forgiven —
option D, named and rejected-for-now, never silently revived).

*Rejected:* keeping 60 ms (pays a per-split clip tax for nothing in a
quiet room) · 40 ms as a compromise (its only supporting evidence died
with the confound) · building the tolerance budget now (a design round
mid-"small milestone"; it needs its own spec and its own field case).

---

## D-037 — Phase 4b ruled: the real mouth (order, and forks F-1..F-4)

**Date:** 2026-08-13 · **Decided by:** Ryad

**The order first:** TTS before the LLM. Ryad raised the fork himself.
The echo loop — the assistant hearing its own voice and barging its own
reply — is real-time audio, this project's spine, and every finding of
the 1d field session (the reply gate, the cost of a false barge) points
at the speak side. Reply generation is integration behind a proven seam
and lands better into an audible loop. Also weighed: `AVSpeechSynthesizer`
cannot fail the way this machine's model daemon does; an on-device LLM
might. *Rejected:* LLM first — earlier "wow", but it buys text while
the named hard problem waits.

**The mouth's family plan, also ruled:** `AVSpeechSynthesizer` is the
floor. TTSKit (a neural Qwen3-TTS living in the argmax-oss-swift
package we already resolve — verified in its source, not from memory)
is the named contender for a LATER milestone, gated by a spike on
three numbers: first-audio latency, stop latency, thermal under
D-028's policy — then a voice bake-off with BAKEOFF.md discipline.
SpeakerKit (Pyannote diarization, same package) is recorded as the
future candidate for multi-speaker rejection — the question the 1d
confound asked ("was that utterance the speaker, or the child?").

**F-1 = A — phrase buffer inside the mouth; per-token at the seam.**
This ruling has a history, kept honestly: Ryad first ruled C
(per-token utterances), valuing parity with the scripted demo and the
finest barge granularity. Re-opened the same day — by Ryad — on the
producer analysis: a future reply generator emits SUBWORD fragments
("con"/"curr"/"ency") with punctuation glued on, at bursty pace.
Per-token utterances would not be choppy but WRONG — a mouth
pronouncing fragments. Buffering must exist somewhere; the deep-module
answer puts it below the seam, so the coordinator keeps forwarding
every token unbuffered as it arrives (the streaming/latency law and
the mid-stream ticket proof both live on that law) while the mouth
privately assembles speakable phrases. Ruling changed to A with the
reasoning on the record. *Rejected:* per-token utterances (breaks on
subwords) · whole-reply buffering (silent for the entire generation —
the felt pause becomes the generation time).

**F-2 = A — OS voice-processing echo cancellation, spike-gated.**
The platform's own echo canceller on the microphone path, so the
assistant's output is subtracted before the VAD ever judges. SPIKE
FIRST (the D-023 discipline): voice processing can change the tap's
format and sample rate on this hardware; adoption is ruled on the
spike's evidence. *Rejected:* half-duplex deafness while speaking —
kills barge-in, the thesis of the whole pipeline; software gate
(raised threshold/window while speaking) — kept as the NAMED FALLBACK
if the spike fails, not chosen while a real canceller is available.

**F-3 = A — the reply gate is coordinator mechanism, app policy.**
A configurable gate `Duration` between a final and opening the
generator; an onset during the gate kills the pending reply silently;
default 0 = byte-for-byte 4a (the D-028 precedent). The race between
"gate expires" and "user resumed" must be decided in the same actor
that owns the turn ticket. *Rejected:* app-side filtering — an app
outside the actor cannot win that race without recreating the
coordinator's own machinery.

**F-4 = A — `.finished` is evidence, not intent.** The reply is done
when the LAST utterance's didFinish arrives, never at `finishTokens`.
D-029's principle carried through: state follows what is AUDIBLE.
*Rejected:* finishing at finishTokens — idle while sound still plays,
and a reply-done latency number that lies.

---

## D-038 — The echo canceller is adopted: the spike's gate, passed in the field

**Date:** 2026-08-14 · **Decided by:** Ryad

D-037's F-2 ruled OS voice processing as the echo defense but made
adoption conditional: "SPIKE FIRST … adoption is ruled on the spike's
evidence." The gate had three questions, and all three are now answered
with evidence rather than argument (numbers in INSTRUMENTS.md §6):

1. **Does it cancel the echo?** Measured, machine-only: speaker audio at
   the tap fell from peak 0.136 to 0.008 while the microphone kept
   delivering a live floor — the `--levels` probe exists precisely so
   "cancelled echo" cannot be confused with "dead microphone", a
   distinction that mattered again hours later when the input really did
   go silent.
2. **Is the reply still comfortably audible?** Ryad, in the room: yes.
   No instrument can answer this one; ears did.
3. **Does barge-in survive the cure?** The acid test — the voice the
   canceller must ignore and the voice it must hear arrive together.
   Ryad barged it mid-reply: it stopped. Confirmed live.

Field proof of the disease and its cure, same rig: BEFORE, every spoken
reply killed itself within a second (`✋ … barge → dead in 1 ms`) because
the pump's own `speechStarted` is the barge trigger (D-031). AFTER, two
full replies completed with the microphone live, his voice landing at
peak 0.106–0.235 against the machine's residual 0.008 — speech and echo
on opposite sides of the gate.

Ruled: the Mac demo turns voice processing ON by default (`--no-aec`
keeps the A/B door open). The LIBRARY default stays `false` — the
D-028/D-036 precedent: a zero/off option changes nothing byte-for-byte,
and each product earns its own number. The iPhone demo is untouched: it
has no talking loop yet, and enabling voice processing there also means
an `AVAudioSession` category decision that belongs with that milestone.

*Rejected:* defaulting it on in the library (silently changes every
existing caller's capture path, and the ratios measured here belong to
one rig — a Mac mini whose microphone is an iPhone over Continuity).
*Rejected:* keeping it opt-in on the demo (the demo's job is to show the
pipeline working; shipping it with a known self-barge would be a demo of
the bug).

**Not measured, and said so:** whether voice processing changes
transcription accuracy. Three clean utterances in the after run are an
anecdote, not a WER study — the BAKEOFF.md instrument exists if that
question ever needs a real answer.
