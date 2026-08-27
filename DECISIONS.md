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

---

## D-039 — The hangover is the fragment boundary: 700 ms for the demo (fork F-7 = A)

**Date:** 2026-08-14 · **Decided by:** Ryad

A field report — quiet speech heard by the gate and lost by the
pipeline, the speaker talking and nothing happening — was chased through
four runs, and the chase is the point of this entry as much as the
number.

**Two of my hypotheses died on the way, both mine, both by measurement.**
First: ambient noise was opening those empty utterances. Killed when the
speaker said he had been talking — same evidence, opposite meaning, the
D-036 confound lesson repeating. Second: the GATE was too high, because
the canceller had lowered the ambient floor (0.024 → 0.006) that 0.02
was chosen against. Tested at 0.008 and again at 0.012; the quiet
sentence still shattered, and two of its pieces sat at peak 0.040–0.042
— the very level that had decoded fine seconds earlier. A threshold
cannot explain a fragment that is loud enough. That is what pointed at
the dip budget instead.

**The mechanism, then.** The gate decides whether a chunk is LOUD; the
hangover decides how long a dip is FORGIVEN before the utterance is
declared over. Quiet speech is mostly forgiven silence — unvoiced
consonants, trailing vowels, thinking gaps — and those dips outlast a
300 ms budget while staying well under 700 ms. So the sentence is cut
mid-thought, the engine receives syllables, and the failure is SILENT:
no error, no event, nothing said.

**Bracketed from both sides, one voice, one room** (INSTRUMENTS.md):
300 ms shattered a quiet sentence into four pieces · 500 ms split it in
two (and split "Hello my friend, how is the weather today?" — a phrase
spoken in both runs, so a natural controlled comparison — where 700 ms
held it as one) · 700 ms delivered it whole, 2300 ms, zero empty
decodes. Ruled: the Mac demo runs at 700 ms; `--hangover <ms>` keeps
every other number one flag away.

**The library default stays 300 ms.** Third application of the same law
(D-028's nil policy, D-036's zero window): a default that shifts
silently under existing callers is a bug, and these dips belong to one
speaker in one room on one microphone.

**The cost, stated where it is paid:** the hangover sits in front of
EVERY final, so every reply waits 400 ms longer. Accepted on a
user-experience argument, not a technical one — being silently ignored
makes a user repeat themselves and lose trust, while waiting 400 ms
annoys them; and 400 ms is not where this pipeline's latency lives
anyway (the 800 ms reply gate is the larger, purely-policy number, and
is where speed should be shopped). Barge-in is untouched: it fires on
an utterance's ONSET, never its end.

*Rejected:* 500 ms (splits sentences — a split is a premature final, and
every premature final is another chance to answer half a thought) · 600
ms (saves 100 ms with no evidence behind it; a speaker's pauses vary by
the day and the margin is worth more) · keeping 300 ms as the next
milestone's problem (the demo would keep ignoring quiet speech).

**Not settled, deliberately:** the true minimum lies between 500 and 700
and was left unchased. And the deeper finding stands recorded in SPEC
§46a — this number should not be a constant at all. The same speaker
ranged from peak 0.059 to 0.263 within one run, so any fixed dip budget
is wrong for one of his own modes. Adaptation belongs to a milestone
with its own spec.

---

## D-040 — The transcript ledger: five rulings, all A (Milestone 4c, forks F-1..F-5)

**Date:** 2026-08-14 · **Decided by:** Ryad

The milestone the field specified (SPEC §46a findings 2 and 3): a turn
answers only its LAST accepted final, so a two-sentence question with a
pause in it gets an answer to sentence two. The ledger keeps what the
speaker said and hands the generator the whole thought. **The trigger
rules do not change** — a refused final still opens no turn, arms no
gate, moves no ticket. It contributes CONTENT only.

**The doctrine line this milestone rests on:** *user speech is EVIDENCE;
a turn's reply tokens are COMPUTATION.* The ticket exists to stop
cancelled computation from surfacing; words the speaker really said do
not stop being true when a ticket expires. Evidence may cross a turn
boundary; computation may not. That answers *may they live*. F-2
answers *when must they die*, and the answer is again evidence.

Five forks, ruled after a four-lens design pass in which every lens was
adversarially critiqued and all four came back `needs_revision`. Three
of those critiques changed the draft before Ryad ever saw it, and one
corrected the author's description of the actor itself (see F-5, F-2,
and the reentrancy note below).

**F-1 = A — the seam keeps `openReply(to: String)`.** The coordinator
joins the pieces; no conformer changes. *Rejected:* a `TurnTranscript`
value carrying pieces + utterance + `AudioTime` — no acceptance
criterion in THIS milestone reads those fields, and the house rule is
not to widen a seam on speculation; pre-1.0 we own every conformer, so
widening later costs three call sites and can be done with evidence.
*Rejected:* a raw `[Piece]` array — it pushes joining onto every
implementer, including a two-line echo. **Recorded as the reason B may
win later:** choosing the separator between a user's sentences IS
prompt formatting, which is policy, and A keeps that policy in the
library — a live D-027 objection, not a dismissed one.

**F-2 = A — the words die on `turnCompleted`, and only there.** That
event means the reply was FULLY SPOKEN (the D-029/F-4 evidence rule
again), so the thought was answered. The distinction that makes it
coherent: *completed* means the pipeline ran to the end — a zero-token
reply still clears, because the generator saw the whole thought and had
nothing to say — while *failed* means nothing ever processed the words,
so they stay. *Rejected:* turn-scoped (the ledger dying with
`current = nil`) — structurally elegant, but it throws the thought away
on the empty-final path, which §46a measured as the field's MOST COMMON
turn-ender (four in 85 seconds); it would fix the bug everywhere except
where it happens most. *Rejected:* a high-water mark raised when the
generator opens — the adversarial pass killed it: opening a generator
is not the user hearing an answer, and four paths (generator failure,
synthesis failure, zero-token, barge) let the open succeed while the
room stays silent. *Rejected:* time-based expiry — it needs a clock in
the core loop plus a policy number, the two costs D-033 refused.

**F-3 = A — a barge carries the interrupted thought forward. RULED
PROVISIONAL by Ryad ("A but maybe we changed later").** It is the same
rule as F-2, not an exception: words die when answered, and a barge is
the clearest case of NOT answered. Every barge in the field runs was a
CONTINUATION ("Why you interrupt me and tell me what I'm saying?").
*Rejected:* emptying on barge — it re-introduces the milestone's own
bug through a side door, discarding sentences that were never answered.
*Rejected:* carrying only never-generated pieces — it produces the
WORST result in the measured case, dropping exactly the sentence the
conversation was about. *Rejected:* an app-side knob — no evidence any
app wants the other setting (D-039's lesson).
**The signal that reopens this fork, named in advance:** a field run
where a barge CHANGES SUBJECT and the reply visibly drags the old
subject in. The demo prints the accumulated context, so this is
observable, not a matter of opinion.

**F-4 = A — bounded by piece count, drop-oldest, no eviction event.**
The bound is not speculative: it is what keeps F-2 = A safe. Without
it, 4d's language model hits its context limit → the generator throws →
`turnFailed` → F-2 KEEPS the words → the next turn sends the same
oversized prompt → wedged forever, no reply ever again. Counting
PIECES rather than characters uses an invariant the pipeline already
owns: the 30-second utterance ceiling (D-021) bounds each piece, so
bounding the count bounds the whole. *Rejected:* no bound (the wedge
above, landing on a real model in 4d, not on today's echo).
*Rejected:* a character bound (either splits a sentence or degenerates
into dropping whole pieces, which is A). *Rejected:* a time bound
(clock in the core loop — the D-033 precedent again). *Rejected:* an
eviction `TurnEvent` — the adversarial pass was right that D-010's
"loss is an event" concerned audio frames NO consumer can see, whereas
an app watching the transcript stream sees every final itself.

**F-5 = A — no flag; accumulation is always on.** This BREAKS a
precedent Ryad set three times (D-028 nil policy, D-036 zero window,
D-039 library hangover), and the break is deliberate: those three
defaulted-off a POLICY — a thermal gate, an onset window, a tuning
number. This is a CORRECTNESS fix, and a switch whose "off" position
preserves a known bug is not a feature. The proof argument decided it:
with a default-off flag the existing 28 tests would exercise NONE of
the new code, so "the suite passes untouched" would prove nothing — the
vacuous-test trap this repo has already been bitten by twice. Note also
what does NOT change: a turn with one final, following a completed
turn, produces byte-for-byte today's text. *Rejected:* default-off
(above) · default-on opt-out (breaks the precedent anyway, so it pays
A's cost and carries B's maintenance forever).
**Consequence accepted:** the existing tests that encode "only the last
final reaches the generator" are amended BY THIS RULING, visibly, in
the RED commit that enumerates them — never quietly.

**A correction to the record, from the same adversarial pass:** the
author had been describing the coordinator's reentrancy surface too
broadly. The merge loop awaits each handler INLINE, so no audio or
transcript event can interleave inside `handleTranscript` — a barge
waits its turn in the stream. Only `stop()` can enter during an await,
which is exactly what the existing post-await guards check. The
ledger's guards are specified against that real surface (AC-90).

---

## D-041 — Review before merge, always (Ryad's rule, proven the day it was made)

**Date:** 2026-08-14 · **Decided by:** Ryad

Milestone 4b shipped with an INCOMPLETE adversarial review: only two of
four planned lenses ever ran before the API overloaded. That was
disclosed in its PR and merged anyway. Milestone 4c was then presented
for merge with its DESIGN reviewed (a four-lens pass before any code
existed) but its CODE reviewed by nobody, and the author recommended
merging on green CI plus a live field run.

Ryad refused, and asked the question that became this entry: *why should
we merge before fixing the missing points — the missing review?*

The review he insisted on found, in the 4c diff, **a regression the
milestone itself had introduced**: a final that overtakes its own
`speechStarted` (the reorder window the coordinator documents) was
recorded into the LIVE turn's thought AND stashed as a future trigger,
so once that turn completed and emptied the ledger, the stashed final
was answered a SECOND time — the speaker hears one sentence answered
twice. It was reproduced by executed probe, with a control run on `main`
proving each sentence was answered exactly once there.

It also found **six tests that were green while the thing they named was
broken** — including one the author had personally weakened hours
earlier while amending tests under D-040 F-5: the amendment replaced the
only assertion sensitive to the input door, leaving a test that passed
with that door broken.

**Ruled:** a milestone is not ready to merge until its CODE has been
adversarially reviewed, not merely its design, and not merely its
acceptance criteria made green. Green CI proves the tests pass; it says
nothing about whether the tests can fail. Where a review confirms a
finding about a test, the fix is verified by MUTATION — break the
behaviour, watch the test fail — because a test that cannot fail is not
a test.

*Rejected:* merge-on-green-CI-plus-field-run (the position the author
argued; CI was green and the field run was successful while the
double-answer regression sat in the diff). *Rejected:* treating a
completed design review as a substitute for a code review — the design
pass for 4c was thorough, caught real errors, and still could not see a
bug that only exists in the wiring.

**The boundary, also ruled here:** this rule is about THIS milestone's
code. Open problems recorded elsewhere with their evidence — SPEC §46a
findings (1) and (2) — do NOT block a merge; they are the next
milestone's spec. Blocking on them would mean no milestone ever merges
and every branch grows into the big-bang PR the working method forbids.
A milestone is done when it meets ITS spec, its code has been reviewed,
and what remains open is written down honestly.

---

## D-042 — The conversation on iPhone: five rulings (Milestone 4d, forks F-1..F-5)

**Date:** 2026-08-14 · **Decided by:** Ryad

Ordering ruled first: the iPhone gets the existing conversation BEFORE a
second mouth (TTSKit) and before a language model. Milestone letters
follow execution order in this repo, so the LLM's earlier names shift to
4f and TTSKit becomes 4e — recorded in SPEC §54, not edited away.

The milestone's thesis is also its exam: the library needs NO new
capability to converse on iOS, so an honest core means the diff is
almost entirely platform reality. **If the core must change to run
there, that change is a finding** (AC-92).

**F-1 = B — the audio session reaches the library through an injected
seam.** The library CALLS the steps in order (configure → activate →
start capture → stop → deactivate); the app SUPPLIES every value. The
ordering is real mechanism and currently guaranteed by nobody: today the
iOS demo makes those calls by hand and the library simply trusts that
they happened. Getting it wrong — deactivating while the engine runs,
activating twice, configuring after start so the format shifts — is not
a compile error, it is a strange bug on a device. *Rejected:* app-only
(every app re-invents the ordering, and a configuration failure surfaces
later as an unrelated-looking capture failure). *Rejected:*
`MicrophoneSource` configuring it internally — that would put POLICY in
a type with no business choosing it, and would hard-code F-4's answer
inside the library forever.

**F-2 = A — interruptions arrive through a seam the app feeds.** iOS
posts its notification to the APP; the library would otherwise just find
its microphone dead. A platform-neutral `began`/`ended` event keeps iOS
out of the core and makes AC-94 provable with a scripted source, no
device. *Rejected:* the library subscribing to `NotificationCenter`
itself — platform code in a cross-platform core, untestable without
faking the notification centre, and (Ryad's point) it would also let the
LIBRARY decide about resuming, taking that choice away from the user.
*Rejected:* the app reacting alone — it forces every app to re-derive
library semantics (which dies first, the ticket or the mouth?), and it
loses data: `stop()` ends everything, so rebuilding the pipeline means a
NEW, EMPTY ledger, discarding words that D-040 F-2 says must survive.

**F-3 = A — an interruption ends the turn like a failure.** The ticket
dies, the mouth is silenced, one event is published, the state returns
to idle. No new state, no new legal transitions, and it inherits the
right behaviour for free: D-040 F-2 already keeps a failed turn's words,
so the speaker's sentence survives the phone call. *Rejected:*
pause-and-resume — it needs state that outlives a DEAD audio graph (the
mouth, the recognition run and the capture chain are all gone), the
mouth has no "continue from the middle" API, and it forces a fifth state
into the funnel. *Rejected:* treating it as a barge — a lie that
spreads: `turnBarged` means THE USER SPOKE, so it would corrupt the
event for every app and make the barge-latency number meaningless; and
entering `listening` afterwards would claim an utterance that does not
exist — the ghost ticket D-033 refused.

**F-4 = A + toggle — speaker by default, and BOTH routes measured.**
`.playAndRecord` defaults to the receiver, which is quiet and forces the
phone against an ear; the loudspeaker is how a voice assistant is
actually used, and it is the HARD case: output loud, next to the
microphone. That is where D-038's canceller must prove itself, because
every echo number this project owns was measured on a Mac mini whose
microphone is an iPhone over Continuity — none of it transfers. Ryad
added the toggle, so INSTRUMENTS gets two rows (receiver vs speaker
residual) in the bake-off's instrument-first spirit. *Rejected:*
receiver-only — it dodges the problem and makes the demo unshowable.

**F-5 = B — the APP decides when listening resumes, and resuming CLEARS
the thought.** (Fork raised by Ryad mid-spec.) The OS takes the session
during a call, so there is nothing to rule there; the real choice is the
other side. Auto-resume has a concrete failure mode: after a long call
the speaker may have walked away, and a microphone that reactivates
itself unannounced is the wrong default for a project whose stated bias
is on-device privacy. The clear-on-resume half closes an interaction
between two correct rulings: F-3 keeps the interrupted turn's words, so
without it a pre-call fragment would join a post-call sentence and be
answered as one nonsense thought. The ledger cannot expire by time — it
has no clock, deliberately (D-040 rejected time-based expiry) — but
"resume" is a perfectly good signal and costs nothing. *Rejected:*
auto-resume on `.shouldResume`. *Rejected:* a config knob — nobody has
asked for the other behaviour yet (D-039's lesson).

**Also carried into the definition of done (D-041):** this milestone's
CODE is adversarially reviewed before its merge, not after.

---

## D-043 — iOS cancels only what it renders: the finding ships, the fix is its own milestone

**Date:** 2026-08-15 · **Decided by:** Ryad

**The measurement** (iPhone, echo probe, gate 0.010, speaker route):

```
                     voice processing ACTIVE
quiet room       peak 0.0030   rms 0.0003     ← was 0.0092 before the canceller
while speaking   peak 1.0000   rms 0.0254     ← FULL SCALE, untouched
```

The canceller is running and demonstrably working — it took the room's
noise floor down threefold. And the assistant's own reply still arrives
at the microphone at **full scale**. Not partial cancellation: a
canceller that cannot SEE the reply.

**The mechanism.** Voice processing cancels what ITS OWN audio unit
renders. `AVSpeechSynthesizer` plays on a separate path, outside this
pipeline's `AVAudioEngine`. On macOS the D-038 spike proved cancellation
of audio from an entirely separate PROCESS, so the reference there is
system-wide — that was one platform measured, and this entry is what it
cost to have treated it as a law. **The Mac's numbers never transferred,
exactly as AC-96 insisted they might not.**

**What the measurement also kills.** Tuning. Human speech peaks around
0.1–0.3; on this route the echo peaks at 1.0. The echo is LOUDER than
the speaker, so no threshold separates them — a raised gate would
silence the person before it silenced the phone. An entire branch of
work, closed by one number.

**Ruled:** the FINDING ships with milestone 4d; the FIX is its own
milestone, and it comes AFTER TTSKit. Order from here: **4d (this) →
4e TTSKit's second mouth → 4f the echo routing fix → 4g the language
model.**

*Why the fix is deferred, in Ryad's own weighing:* it is a session of
the trickiest audio code — one component owning a single engine, the
mouth rewired from `speak()` to `write()` plus a player node, format
conversion, a new source of `.started`/`.finished` evidence (which would
reopen D-037 F-4), and all of it un-TDD-able. Against that, the phone
ALREADY converses on the receiver and on headphones, where the echo path
is weak. A precise, reproducible platform finding with an instrument
behind it is worth more right now than a rushed rewrite of the mouth.

**F-4 AMENDED BY MEASUREMENT (the D-036 precedent).** F-4 ruled the
loudspeaker as the demo's default because it is the honest hard case.
It is now the *measured broken* case: with it, the demo barges itself
out of the box. The default becomes the route that WORKS, the speaker
stays one toggle away for measurement, and the screen says why. The
original ruling and its reasoning stay on the record.

**THE CHEAP FIX WAS TRIED AND MEASURED, not assumed away.**
`.voiceChat` — the session mode built for full-duplex speech — was the
one-line hope. Same phone, same route, same probe: quiet room 0.0030 →
**0.0008** (the canceller is doing MORE work on what it can see), and
the reply still arriving at **0.9391**. The conclusion now rests on two
independent modes rather than one, which is what makes it a finding
instead of a guess. `.voiceChat` is KEPT, on the measured noise floor
alone, with no claim that it helps the echo.

**The design that a later milestone will build**, so the finding carries
its own answer: render the reply through the SAME engine that cancels —
`AVSpeechSynthesizer.write` into a player node on the pipeline's engine,
so the voice-processing unit finally has the reply as its reference.
*Rejected as permanent answers:* half-duplex while speaking (kills
barge-in, the project's thesis — already rejected in D-037 F-2) ·
receiver-only (dodges the problem and makes the demo unshowable, though
it is exactly what makes shipping the finding acceptable today).

---

## D-044 — The session's release-on-failure branch: accept the gap, name the cost

**Date:** 2026-08-15 · **Decided by:** Ryad

`MicrophoneSource.start` activates the app's audio session before it
reads the format or installs the tap, and a `defer` releases it again if
capture never begins. Those three lines matter on iOS: a failed start
that leaves the session active holds another app's audio hostage from a
pipeline that is not even running.

**The gap, as the adversarial review sharpened it.** The branch runs on
NO machine that executes the suite. Where a microphone exists, capture
succeeds and the other path is taken; where it does not, the failure
happens AT activate, not after it. The test file had already disclosed
this and guessed that CI would cover it — the review checked, and that
guess was wrong. Green CI says nothing about these three lines.

**Ruled: accept and document.** The alternative was a test-only
injection point for the "start the engine" step — a permanent hole in a
public type whose only caller would be one test file, bought to prove a
`defer`. The repo already has a category for code that only real audio
can exercise: `AppleSpeechEngine` and the mouth, kept thin,
conformance-verified on hardware, and NAMED as such (D-022's
discipline). These three lines join that list rather than bending the
public API around a test.

*Rejected:* the injection point (public surface for a test-only caller;
the first of its kind in this library, and a precedent that would
recur). *Rejected:* deleting the disclosure and calling the suite
complete — the failure is silent on the platform where it matters, and
an undocumented gap is the one thing worse than an unproven line.

**Consequences, written where they will be read:** the gap and its cost
are stated in `AudioSessionSeamTests.swift` beside the invariant, not
only here, so the next person to touch that `defer` meets the warning in
the file they are editing. The original note is kept above the ruling —
its FACTS did not change, only the reasoning that followed them.

---

## D-045 — The second mouth: five rulings (Milestone 4e, forks F-1..F-5)

**Date:** 2026-08-15 · **Decided by:** Ryad

Every seam in this library has two real implementations except one, so
"we can switch mouths" was a CLAIM where the input side had a PROOF.
4e closes it with TTSKit's neural voice (Qwen3, CoreML) from the
`argmax-oss-swift` package already resolved for WhisperKit.

**F-1 = B — we render the audio, TTSKit only decodes.** `generate`
hands back PCM chunk by chunk; `play` would render through TTSKit's own
output. B is the only path that can make the reply CANCELLABLE on iOS:
D-043 measured that voice processing removes only what its own audio
unit renders, so a reply we render ourselves is the first one the
canceller can see. It also makes `.started` real evidence (a buffer
actually scheduled) and makes `cancel()` something we can measure rather
than request. *Rejected:* `play()` — least code, and it inherits 4d's
echo problem unchanged, with `.started` degraded to "their callback
fired" and cancellation to a hope. *Rejected:* a platform split
(`play` on macOS, render on iOS) — one seam with two behaviours, and
`.started` meaning different things per platform.
**The cost, accepted knowingly:** we take back the problem TTSKit had
already solved — pre-buffering against underruns, and a 24 kHz source
feeding an engine at 48 kHz. If our rendering is choppy the neural mouth
is WORSE than Apple's for no gain. AC-102's spike measures exactly that,
and option A stays documented as the fallback.

**F-2 = A — `.started` is the first PCM actually rendered.** D-029's
rule survives the change of mouth: state follows what is AUDIBLE.
*Rejected:* reporting at generation start — earlier, and a lie, because
nothing can be heard yet; it would also corrupt the felt-pause number
that INSTRUMENTS.md has tracked since 4b.

**F-3 = A — `PlaybackStrategy.auto`.** It measures the first decode step
and pre-buffers just enough, re-assessed per chunk. *Rejected:*
`.stream` (lowest latency, choppy wherever the device cannot generate
faster than real time) and `.generateFirst` (smooth, but the felt pause
swallows the whole generation). The number is recorded either way — this
is a latency/robustness trade the spike settles, not taste.

**F-4 = A — its own opt-in product, `MultiModalKitTTS`.** Mirrors
`MultiModalKitWhisper` (D-016 tier 2, D-023's four questions). The core
keeps zero runtime dependencies. *Rejected:* folding it into the Whisper
module because both come from one package — it implements a DIFFERENT
seam, and an app that wants a voice should not be made to pull a speech
recogniser.

**F-5 = A — the bake-off measures intelligibility, and labels opinion as
opinion.** Voice quality cannot be scored honestly by assertion, but it
CAN be measured indirectly: speak the text, record it, transcribe it
with the two engines this repo already owns, and score WER against the
source. That is a real instrument, with real caveats (it measures what a
RECOGNISER understands, not what a human enjoys). Latency, size and
thermal are objective and reported directly. Anything subjective is
reported as labelled opinion. *Rejected:* refusing to score quality at
all (the easy way out, and it wastes an instrument already in the repo).
*Rejected:* a subjective rating as the headline number — precisely what
BAKEOFF.md exists to refuse.

## D-046 — The neural mouth starves: buy a lead AND attack the decode (Milestone 4e, post-AC-102)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: A and B, in the
order B then A**

**What the measurement said.** AC-102 put the neural voice's real-time
factor at **1.09–1.23** on an M-series Mac, release build (INSTRUMENTS
§10). Above 1.0 means the decoder produces audio slower than the ear
drinks it, so the player runs dry. The arithmetic proves it without an
ear: the long sentence would end at first-audio + audio = 8466 ms if
playback were gapless, and it ended at 9216 ms — decode wall time plus
one buffer. Playback is gated by decode, from the very first buffer,
because this integration starts with **zero lead**.

**A — buy a lead.** Queue audio before starting playback. First audio
rises from ~227 ms toward ~1 s; the gaps close for replies short enough
that the lead outlasts them.

**B — attack the decode speed first.** Find what TTSKit exposes that
lowers RTF, and measure it, before hiding the deficit behind a buffer.

**Both, B first.** B first because a faster decode shrinks the lead A
has to buy, and a lead sized against an un-optimised decoder is a lead
sized against a number we chose not to improve. A regardless of B's
outcome, because a streaming render path with zero pre-roll is wrong for
ANY mouth — the fault is structural, not particular to this voice.

*Rejected:* **C — rule the neural voice non-conversational** and let the
bake-off judge quality only. It costs nothing and it is honest, but it
grades the wrong thing: with no lead, AC-103 would measure a stutter
that is our bug, and AC-104 would measure it harder, because the phone
is slower than the Mac. Quality cannot be judged through a defect we
already know we own.

*Rejected as sequencing:* **A before B**, and **iPhone before either**.
A-first sizes a buffer against a decoder we have not tried to speed up.
iPhone-first measures our missing buffer on slower silicon.

### The correction this ruling carries — D-045 F-3 cannot be delivered as ruled

D-045 F-3 chose `PlaybackStrategy.auto`, praised for measuring the first
decode step and pre-buffering just enough. **It is unimplementable under
F-1 = B.** `PlaybackStrategy` governs TTSKit's OWN playback, and F-1
ruled that TTSKit never plays anything for us — it decodes, we render.
Two rulings in the same decision, and only one of them can be true.

F-1 wins, because its reason is measured (D-043: iOS voice processing
cancels only what its own audio unit renders) while F-3's was a
convenience. So F-3's ruling is void as written, and its INTENT — an
adaptive pre-buffer, sized from what the decoder is actually doing —
transfers to our code as option A. That is not a footnote to F-3; it is
the whole content of A, and D-045 F-1 already named the bill:
*"pre-buffering and resampling become ours to get wrong."*

Per this log's rule, F-3 is not edited away. It stands as ruled, with
this entry recording that it was ruled against a capability we had
already given up in the fork above it.

## D-047 — `.fused` becomes the neural voice's default, and the lead returns to zero (Milestone 4e, post-AC-103/106)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: A**

**The evidence this rests on**, all in INSTRUMENTS §12–§14:

| | `.stepped` | `.fused` |
|---|---|---|
| steady RTF (AC-106) | 1.066 | **0.752** |
| round-trip WER, 18 draws (AC-103) | 0.083 | 0.074 |
| blind listening, 3 rounds (AC-103) | 1 win | 1 win, 1 tie |

**29% faster, and no quality difference that two independent instruments
could find** — one subjective, one objective, neither looking for the
same thing. `.fused` replaces ~35 CoreML predictions per 80 ms frame
with about 5.

**THE LEAD GOES TO ZERO BY DERIVATION, NOT BY PREFERENCE.** The sizing
rule is `deficit = replyLength × (RTF − 1)`, and at 0.752 it returns
zero: the decoder runs ahead of the ear, so there is no shortfall to
bank. `NeuralVoice.defaultLead` is still computed from that rule against
a named measured factor, so the day a slower machine is measured, the
constant changes and the cushion reappears on its own. First audio
returns from 1882 ms to **229 ms**, gapless.

*Rejected:* **B — keep `.stepped` until the iPhone is measured.** It was
the strictest reading of D-045, and its bar has now been cleared on the
Mac by both instruments. Holding on would mean every remaining 4e
measurement — AC-104's iPhone numbers, the demos, the review — is taken
against a configuration we already intend to replace, which measures the
wrong thing carefully.

*Rejected:* **C — adopt `.fused` but keep a ~250 ms cushion as
insurance** for the unmeasured phone. It buys protection against a risk
nobody has measured, which is the same "insurance, not a measured cure"
label D-028's thermal policy has carried honestly since Phase 3. The
sizing rule makes the cushion one line the moment AC-104 produces a
number that asks for one. Guessing it now would only make that number
harder to read.

**Costs accepted knowingly:**
- **iOS 18 / macOS 15 floor.** `.fused` needs the multifunction CoreML
  asset and a modern runtime. The conformance kit proves the asset on
  whatever machine runs the suite rather than assuming it.
- **Undocumented path.** The mode appears in Argmax's CLI and example
  app, not their README. A package bump could change it without a
  release note, so the conformance test that loads it is the guard.
- **Output is not bit-identical** to `.stepped`: sampling moves inside
  the graph. Measured as indistinguishable, not as identical.

**What this ruling does NOT do.** It does not adopt the neural voice as
the conversational mouth — D-045 and AC-102 still require iPhone numbers,
stop latency and thermal, and none of those exist yet. This chooses which
decoder the neural voice uses when it is used at all, so that every
remaining measurement is taken against the real candidate.

**An open hazard, recorded here because it belongs to the voice and not
to either decoder.** In AC-103's draws Whisper heard `*crying*`,
`(laughing)`, `"Ha,"` and `"Uh uh, uh,"` — the model emits non-speech
vocalisations, on BOTH decoders. For an assistant that talks to people
that is a real problem, and it is owed its own fork rather than a
footnote. It does not block this ruling because it is unaffected by it.

## D-048 — AC-104 needs the capture engine, so 4f's engine sharing is pulled forward, scoped (Milestone 4e)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: B**

**Why the question forced it.** AC-104 asks whether a reply rendered
through the pipeline's OWN engine falls under the gate. D-043 measured
that iOS voice processing removes only what its own audio unit renders,
and that unit lives on `MicrophoneSource`'s engine — which is `private`.
So the reply must render *there*, or the hypothesis is not being tested.

*Rejected:* **A — the partial test**, neural voice on its own separate
engine. It is runnable the moment the demo is wired, and it would cost a
1.1 GB download and a field session to re-confirm D-043: an engine the
voice-processing unit does not render cannot be cancelled by it. A
measurement whose result is known in advance is not a measurement.

**Scoped, and the scope is the point.** ONLY the engine sharing moves
into 4e — enough for a reply to render where the canceller can see it.
4f keeps the rest of the routing fix, and keeps Apple's mouth, whose
echo problem D-043 documented and which this does not touch.

`NeuralVoice(renderingOn:)` already exists for exactly this. Its own
doc comment, written in this milestone, says: *"Sharing the CAPTURE
engine is not yet possible — `MicrophoneSource` keeps its own private —
and that is exactly the work milestone 4f carries."* This ruling is that
sentence coming due earlier than expected, which is a reason to record
it rather than to quietly delete the comment.

## D-049 — Reversing D-048: the neural voice renders on its own engine (Milestone 4e)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: A — reverse**

**This overturns D-048, which Ryad ruled B on my recommendation eight
hours earlier.** The recommendation was wrong, and it was wrong in a
specific way worth naming: I argued that option A "would cost a 1.1 GB
download and a field session to re-confirm D-043", and that a
measurement whose result is known in advance is not a measurement. What
I did not weigh was that **I had no way to test option B**, and that
every step of it would therefore be tested by a person holding a phone.

**What it cost, honestly counted.** One afternoon, five rebuilds, and
these faults — every one of them introduced by me while fixing the
previous one:

| fault | how it showed |
|---|---|
| `detach` after `engine.stop()` | process abort |
| guarded *attached* instead of *in a chain* | process abort, inside the first guard |
| no output chain at all | `vpio render err: -1`, forever, state "thinking" |
| output chain built after the tap | phone completely deaf |
| output chain at all, with voice processing | capture cannot start, state "idle" |

**The measurement that ended it** (INSTRUMENTS §17). Once the path was
finally run on a Mac — which took one command, and which I should have
written first:

| voice processing | output chain | result |
|---|---|---|
| on | **on** | **cannot start: `-10875` at `kAUInitialize`** |
| on | off | starts |
| off | on | starts |
| off | off | starts |

Voice processing and an output chain cannot coexist on one engine here.
That is the AC-108 configuration exactly.

**The ruling.** The neural voice renders on its OWN engine —
`AudioEnginePlaybackHost`, the seam's second implementation, which has
worked since the hour it was written. Its reply is therefore NOT
echo-cancelled on iOS, which is D-043's measured cost, accepted again
and knowingly.

*Rejected:* **B — keep going.** Real apps do run duplex voice processing
on iOS, so this is possible. But the deciding case cannot be tested on
this Mac (`-10875` is consistent with voice processing needing one
device for input and output; a Mac has two, a phone has one), which
means every further attempt is tested by Ryad. That is the exact
arrangement that produced the table above.

### What survives, and it is most of it

The seam is not deleted. `PlaybackHost` has two implementations, eleven
tests, and it now encodes rules that were learned the hard way. The
capture-side host stays, unused by the demo, waiting for 4f — where it
belongs, behind a harness that now exists.

**And the harness is the real deliverable of this reversal.** `bakeoff
voice-onmic` runs the capture path on a machine I control, with one
variable. Everything above was findable in one command. 4f starts there,
not on a phone.

### Bugs found on the way that have nothing to do with the ruling

They stay fixed, and they were worth the afternoon on their own:

- the tap was installed with `inputFormat` when a tap observes what a
  node PRODUCES — `outputFormat` is correct, and the two disagree the
  moment anything else touches the graph
- an invalid format handed to `installTap` ABORTS rather than throws;
  now `AudioSourceFailure.inputUnavailable`
- `AVAudioEngineConfigurationChange` was never observed, so an engine
  that killed its own graph looked like a dead microphone
- `feed` blocked the coordinator's loop for a whole phrase decode, which
  is why barge-in was late
- the gate was a guess; it is now measured, and the level is on screen

## D-050 — Qwen3 stays; its voice quality is deferred, not accepted (Milestone 4e)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: keep it, revisit later**

The neural mouth speaks on both platforms and it does not sound good.
Both halves are measured, and neither cancels the other:

| | |
|---|---|
| intelligible | round-trip WER **0.074** over 18 draws, against Apple's 0.000 (§14) |
| slow | ~2× Apple's duration for the same sentence (§14) |
| inconsistent | the same words, 8240 ms one draw and 6480 ms the next (§11) |
| strange | `*crying*`, `(laughing)`, `"Ha,"` transcribed out of its own output (§14) |

**What "keep" means here, stated so nobody has to guess later.** Both
mouths ship. The demo lets a listener switch between them and the
library's conversational default is UNCHANGED — Apple's mouth, which is
fast and robotic, remains what a fresh install talks with. The neural
voice is the seam's second real implementation, which is the thing 4e
set out to prove and did.

**What is deferred, and is now owed work rather than a closed question:**
whether this voice can be made pleasant. The levers already measured and
rejected are recorded so the next attempt does not repeat them —
temperature 0 is slower and rambles longer (§12), `.throughputOptimized`
is slower here than the vendor's own table claims (§12), and the only
other variant is the 1.7B, which is strictly more compute on a device
that already runs hot. What has NOT been tried: the voice/speaker
conditioning TTSKit exposes, and a different TTS engine entirely.

**Not rejected, because it was never proposed as an alternative:** the
milestone's claim was never "Qwen3 sounds good". It was "this pipeline
does not care which mouth you plug in", and that is now proven with two
implementations, a conformance kit, a bake-off, and field validation on
Mac and iPhone. Recording the voice as unpleasant costs that claim
nothing — and pretending otherwise would cost it everything.


## Corrections to the 4e record — found by a document-versus-code audit

**Date:** 2026-08-16 · Not a ruling. A list of places where this log said
something the code contradicts, recorded here rather than edited away,
because a decision log that quietly fixes itself is worth nothing.

Found by an adversarial audit of every document against the tree, run
before the 4e review. Nothing here was found by a test.

**1. D-049's bug list is wrong about `inputFormat` / `outputFormat`.** It
says the tap "was installed with `inputFormat` when a tap observes what a
node PRODUCES — `outputFormat` is correct". **The opposite is true.**
`installTap` asserts on the INPUT HARDWARE format
(`format.sampleRate == inputHWFormat.sampleRate`), that "fix" aborted 39
of 40 test rounds, and commit `fdf9fb7` reverted it. INSTRUMENTS §19
carries the real account. The bullet was written in the same session that
disproved it.

**2. D-049's bug list claims a watch that had been deleted.** It says
`AVAudioEngineConfigurationChange` "was never observed" and is now
observed. The registration was in fact removed when `start()` was
rewritten, leaving `removeObserver` in `stop()`, a counter with no
writer, and a screen reporting `reconfig 0` as evidence. Restored, with
`isWatchingConfiguration` so the instrument can be asked whether it is
switched on — because this milestone has now shipped a dead instrument
three separate times.

**3. D-045 F-5 asked for two graders; one was used.** The ruling says
round-trip WER is scored with "the two engines this repo already owns".
`bakeoff voice-wer` grades with Whisper alone. INSTRUMENTS §14 admits it
in its own caveats; this log did not, and the difference matters because
a single grader's bias is unmeasured.

**4. D-046's headline factor was later shown to be partly an artefact.**
It quotes RTF 1.09–1.23 as the decoder's rate. AC-106 then found that
number carried a fixed ~210 ms of prefill, and the steady rate was 1.066.
Recorded in INSTRUMENTS §12 and in the code; never in the log until now.

**5. Two counts in D-049 and D-050 are wrong.** "Eleven tests" for the
`PlaybackHost` seam was eight at the time of writing (nine now), and
D-050 attributes "rambles longer" to §12, which measures no such thing.

The rulings themselves — D-045 through D-050 — stand. What was wrong was
the supporting prose, which is exactly the part nobody re-reads.

## D-051 — The 4e review's three blockers, fixed; two notes accepted (Milestone 4e)

**Date:** 2026-08-16 · **Review by:** adversarial multi-agent pass
(D-041's rule: the review happens BEFORE merge, and every finding is
fixed or accepted in writing — never carried silently)

Thirty-four agents across five dimensions; most findings did not survive
verification. Three did, and all three were mine.

**Blocker 1 — a failed decode kept running and aborted the process.**
`report(_:terminal:)` handed the player node back to the engine and did
NOT raise the run's flag; only `cancel()` did. The drain loop re-reads
only that flag, so after `.failed` it popped the next phrase and called
`play()` on a node with no engine — which AVFoundation aborts on rather
than throwing. It also broke the doctrine written twenty lines above it:
**a run that has reported a terminal must not act again, and the flag is
the guarantee.** Fixed with one `retire()` that latches, empties the
queue and stops the worker in a single locked step, called by every
terminal path and by `cancel()`.
Second half, same blocker: the coordinator's synthesis `.failed` arm
cancelled the reply run but never the mouth, while the reply's arm has
always cancelled the mouth. Harmless only while Apple's mouth was the
only implementation, because it never emits `.failed`.

**Blocker 2 — the neural voice's engine was never stopped.** It built
its own host on the first reply, started that engine, and
`stopRendering()` had no production caller anywhere. An output unit
running forever means `setActive(false)` fails with `IsBusy`,
`PhoneSession` swallows it with `try?`, and the `.playAndRecord` session
is held for the life of the app — **the person's music never comes back
after Stop.** Fixed app-side: the demo owns the host and stops it, in an
order that cannot be swapped — the pipeline dies, THEN the engine stops,
THEN the session is released. Step two *waits* for step one rather than
racing it, because detaching a node under a reply that is still playing
reaches blocker 1's abort from the other side.

**Blocker 3 — the first reply loaded 1.1 GB on the coordinator's loop.**
`modelInstalled()` only stats files; the pipeline was built lazily by the
first `openUtterance`, which the coordinator awaits INLINE. So the first
turn after launch froze the whole conversation for tens of seconds —
onsets, transcripts and barges piling up unprocessed — and its felt-pause
number silently contained the model load. This is the identical fault
already fixed one call lower in `feed`, and the review found it sitting
one call higher. Fixed by warming the model in `checkVoice()`, which
`start()` already refuses to proceed without.

### Accepted, with the note written rather than implied

**The neural failure path ships UNPINNED.** `NeuralVoiceRun` holds a
concrete `TTSKit`, so no test can make a decode throw, and blocker 1's
fix could not be red-before-green. That is a departure from this repo's
rule and it is recorded as one. A `TTSDecoding` seam would fix it and is
4f work; until then the guarantee rests on reading, not on a test.

**THE LAZY-INIT CLASS HAS NO CLASS-LEVEL CURE, and it has now bitten
three times.** *(Added 2026-08-21, surfaced by the 4e teach-back.)*
Blocker 3 records that the same fault was "already fixed one call lower
in `feed`, and the review found it sitting one call higher" — an instance
fix, not a class fix. 4h proved the point: `MLXReplyGenerator.prewarm()`
loaded 2.2 GB and called itself done, and the bake-off then measured the
FIRST generation at 1911 ms against the second at 82 ms, because Metal
pipeline warm-up was still landing inside the person's first question
(INSTRUMENTS §25). Three instances — `feed`, `openUtterance`, `prewarm` —
in three components across three milestones, each fixed locally.

Nothing in the library makes a seam DECLARE that it has expensive setup,
and nothing lets the coordinator refuse to start until every seam says it
is ready. The demo's `start()` refuses — but that is one caller
remembering, which is the shape D-052 rejected for `stopRendering`.
Whether the seams should grow a readiness verb is a change to their shape
and therefore Ryad's fork, logged here rather than decided quietly.

**`PlaybackHost` has no stop verb.** Blocker 2 was fixed in the demo, so
any OTHER caller who lets `NeuralVoice` build its own host inherits the
same unstoppable engine. Whether the seam should grow a stop — or whether
`NeuralVoice` should stop a host it created itself — is a change to a
seam's shape and therefore a fork for Ryad, logged here rather than
decided quietly.

## D-052 — Whoever makes the engine stops it (Milestone 4e, the review's second accepted note)

**Date:** 2026-08-16 · **Decided by:** Ryad · **Ruling: B**

The 4e review found that `NeuralVoice` started an audio engine on its
first reply and nothing ever stopped it. Blocker 2 fixed the demo by
giving it a host of its own; this closes the same trap for every other
caller.

**The rule: ownership.** A host handed in by a caller belongs to that
caller and is never stopped from inside. A host that built its own engine
stops that engine. `NeuralVoice.shutdown()` stops only what the voice
made for itself.

**And the rule lives in the TYPE, not in a caller's memory.**
`AudioEnginePlaybackHost` now has two initialisers — one that makes an
engine and one that borrows — and `stopRendering()` consults which. That
matters because a caller who forgets this gets no error: they get an
audio session held for the life of the app, `setActive(false)` failing
with `IsBusy`, and a person whose music never comes back.

Both halves are tested, and the second half is the one that would have
broken quietly: the bake-off hands in its own engine BECAUSE it also taps
the mixer to capture what was said, so an engine stopped underneath that
tap would end the measurement rather than the reply.

*Rejected:* **A — put `stopRendering` in the protocol.** Every host would
have to implement it, and the microphone's host borrows an engine it does
not own — so its version would have to do nothing, or something wrong.
One verb meaning two things is the shallow-wrapper smell this repo
refactors away.

*Rejected:* **C — the owned engine runs only while something renders**,
stopping itself when its last node leaves. Fully automatic and genuinely
tempting, but it starts and stops the engine once per reply. Route churn
on a live graph is what cost this milestone an entire afternoon
(INSTRUMENTS §16–§19), and buying tidiness with more of it is the wrong
trade.

**Still open after this, and the one thing left before merge:** the
neural failure path ships unpinned, because `NeuralVoiceRun` holds a
concrete `TTSKit` and no test can make a decode throw (D-051). A
`TTSDecoding` seam fixes it and would also answer D-023's fourth question
— *could we remove this dependency in a day, because it lives behind one
of our protocols?* — which is currently **no** for TTSKit and yes for
every other dependency in the repo.

*(Closed by D-053, which also corrects the last sentence: the seam
answers that fourth question for the DECODE path only.)*

## D-053 — The `TTSDecoding` seam: our own types, and the run only (Milestone 4e, AC-109)

**Date:** 2026-08-17 · **Decided by:** Ryad · **Rulings: F-6 = B, F-7 = A**

This closes the debt D-051 accepted in writing and D-052 named as the one
thing left before merge. It does not edit either of them — they record
what was true when they were written.

### F-6 — what language the seam speaks. Ruling: B, our own value types.

`TTSDecoding` is two members: a sample rate, and
`decode(text:temperature:onStep:)` handing back `[Float]` per step and
taking a `Bool` back to say whether to continue. TTSKit's `generate`,
`GenerationOptions`, `SpeechProgress` and `SpeechCallback` appear in ONE
file, the adapter — and the `concurrentWorkerCount = 1` correctness pin
moves there with the comment that explains it, because that pin is about
the vendor's batching branch and belongs beside the vendor.

*Rejected:* **A — the protocol names the vendor's types.** Less code, and
that is the whole of its case. A protocol whose signatures are
`GenerationOptions` and `SpeechProgress` is a shallow wrapper around
another library's shape — the §4.0 smell this repo refactors away — and it
leaves a test double needing `import TTSKit` to fake a decode. Under B the
scripted decoder imports nothing.

**The protocol is INTERNAL.** Its second implementation is a test double,
not a shipping product, and this repo's rule (D-017) is that public
surface is earned by a second REAL implementation. Tests reach it with
`@testable import`. If a consumer ever wants to put a different decoder
behind our rendering machinery, that is the day it becomes public, and the
day it needs a written contract rather than an internal one.

### F-7 — how far the seam reaches. Ruling: A, the run only.

`NeuralVoiceRun` takes the protocol. `NeuralVoice` keeps
`TTSModelVariant`, `TTSKitConfig`, `Qwen3MultiCodeDecoderMode` and
`Qwen3SpeechDecoderMode` in its public API.

*Rejected:* **B — hide the model lifecycle too**, so no signature names
TTSKit. It breaks public API the demo and the bake-off depend on, and it
does it to hide the exact levers AC-106 measured: `.fused` versus
`.stepped` is a published number — 1.066 → 0.752 — and a caller who
cannot name the decoder cannot reproduce the measurement. Hiding a
dependency is worth less than reproducing a result.

**And the correction this ruling forces.** D-052's closing paragraph says
the seam would answer D-023's fourth question. Under A it answers **half**
of it: TTSKit is removable-in-a-day behind a protocol for the DECODE, and
still not for the model lifecycle. The half-answer is what goes in the
record, because the fuller claim would be the more flattering one and it
would be false.

## D-054 — Audio graphs are MEASURED, never reasoned about (standing rule, all milestones)

**Date:** 2026-08-17 · **Decided by:** Ryad · **A process pivot, logged
because process pivots get their own entry**

The bill this pays: in one 4e afternoon, five separate faults, **each
introduced while fixing the previous one** — a detach after
`engine.stop()`; a guard on "attached" when the assertion asks "in a
chain"; no output chain at all; an output chain built after the tap; and
an output chain at all. Every one was a guess about what a live
`AVAudioEngine` would do. Every one was tested by Ryad rebuilding onto his
phone. What ended it was not insight: it was `swift run bakeoff
voice-onmic` — the same path, on this Mac, with one variable. All five
were findable that way, in minutes.

**The rule, in five parts.**

1. Before ANY change to `MicrophoneSource`, `PlaybackHost`, an
   `AVAudioEngine` graph or an `AVAudioSession`: write or extend a harness
   that runs that path HERE, with one variable, and run it. **The harness
   comes before the fix** — not after the failure report.
2. Never ask Ryad to test a hypothesis the machine can test itself. That
   includes the iOS Simulator: boot it, build and install the demo, copy
   the model into the app container, tap the UI, screenshot it. His phone
   is for what only real hardware can answer — routing, echo cancellation,
   thermals — never for choosing between two orderings.
3. "I cannot test this here" is an INPUT to the ruling, said before the
   proposal, together with who pays if the guess is wrong. Not a footnote
   after it.
4. When a field report arrives, the first move is a measurement that could
   REFUTE the favourite explanation — not a fix. Four of the five faults
   above were the fix arriving before the measurement.
5. An instrument that shows a number must have a WRITER, and must be able
   to say whether it is switched on. Three instruments shipped dead in 4e
   — the margin counters, the graph-rate line, the reconfiguration watch —
   and each cost a field run before anyone noticed it reported nothing.

**Its first application, in the same hour it was ruled.** AC-109's tests
need a spy `PlaybackHost` that starts no engine, which makes every verb the
run calls on its player node a graph question. `bakeoff graph-probe`
answered it — eight cases, one process each, because an abort ends a
process. `stop()` and `reset()` off a running engine are safe;
**`play()` and `scheduleBuffer` abort**. That measurement is what makes
"the scripted decoder emits empty sample arrays" a load-bearing rule
instead of a style choice.

**And the probe refuted something I believed.** Its CONTROL case — detach
after `engine.stop()`, fault one of that afternoon — **did not abort** on a
plain macOS engine. The harness can plainly see aborts, since two other
cases produced them, so this is not a dead instrument: it means that abort
was never a property of a plain engine. It needed the capture engine's
voice-processing unit, or a session teardown. The guards in
`MicrophonePlaybackHost` and `AudioEnginePlaybackHost` STAY — they cost
nothing and the iPhone's evidence stands — but the comment claiming the
general case is narrower than it reads, and INSTRUMENTS §20 now carries
the number instead of the belief.

## D-055 — One funnel for the lead's liveness escape (Milestone 4e, found by the re-review)

**Date:** 2026-08-17 · **Decided by:** Ryad · **Ruling: B** · Recorded
under D-041's rule that every review finding is fixed or accepted in
writing, never carried silently.

**The finding.** `PlaybackLead` banks audio before the first sound. Two
places can learn that *the reply is complete, so the lead's target will
never be reached*:

- `NeuralVoiceRun.speak()`'s liveness step, which HAS a `.release` arm and
  says why in its own comment: *"If nothing released it here, the player
  would never start, no buffer would ever report played, `finished` would
  never fire, and the turn would hang."*
- `finishTokens()`, which has **no such arm** — its last line is
  `(phrasesInFlight == 0 && scheduled == played) ? .finishNow : .wait`.

So if the last phrase's decode has already completed and the token stream
closes afterwards, nothing releases the lead. **Measured, not argued**
(`PlaybackLeadStrandTests`, and INSTRUMENTS §21):

| lead target | `finishTokens` | started | finished |
|---|---|---|---|
| `.zero` (shipped) | after the decode | true | true |
| 1500 ms | **after** the decode | **false** | **false** |
| 1500 ms | before the decode ends | true | true |

**It is pre-existing, and that phrase needs sharpening.** The `TTSDecoding`
seam did not cause it — and the seam is the only reason it is reproducible,
because making a decode finish ON COMMAND before the token stream closes
needs an injectable decoder. But "pre-existing" must not be read as
"already shipped": `PlaybackLead` and `releaseLead` were both introduced by
**`c7d772a`, in this milestone**, and `main` has neither. So **merging PR
#13 is what would put this hole into `main`.** It is pre-existing relative
to the seam commits and new relative to the product, which is the reading
that matters for the merge decision.

**Why it is not biting, and why that expires.** `defaultLead` is
`deficit(forReplyOf: 6s, realTimeFactor: 0.752)`, and `deficit` returns
`.zero` for any RTF at or below 1.0, so every caller in this repo runs a
zero lead where the first buffer starts the player. **The hole opens the
moment RTF exceeds 1.0**, which is a slower machine — and **the iPhone's
RTF has never been measured, because AC-104 did not happen.** A phone that
decodes slower than it plays, answering with a reply short enough to fit
inside its own lead, hangs the turn. That is 4f's territory.

### The fork — Ryad's to rule

- **A: give `finishTokens()` a `.release` arm**, mirroring `speak()`.
  Smallest diff, and it fixes the measured case. But it leaves the liveness
  escape written twice, in two arms that must be kept in agreement by
  whoever reads them next — which is how it came to be missing in one of
  them.
- **B: one funnel.** Both paths compute the same "is this reply complete,
  and if so must the lead be released?" question through a single function,
  the way `TranscriptionSession` and `TurnCoordinator` both put every state
  write through one transition funnel. More diff, and it puts the invariant
  somewhere it cannot be half-applied.
- **C: make the lead refuse an unreachable target** — `PlaybackLead` itself
  releases when it learns no more audio is coming, so no caller can forget.
  Purest, and it moves policy into the pure type where this repo likes it,
  but `PlaybackLead` currently learns that only from `noMoreAudio()`, whose
  single caller is the arm that already works.

### The ruling: B, and it found a THIRD site

The bug is not that one arm is missing a line; it is that one question had
more than one answering site, which is precisely the shape this repo
funnels everywhere else. A is a patch on the symptom. C is attractive and
may still fall out of a later change, but on its own it alters a pure
type's contract to fix a caller's asymmetry.

**Writing the funnel found a third site the fork had not named.**
`bufferPlayed()` was asking its own inline version of the same question
too — so the count was not two sites but three, and the fork's own framing
("lives in one place and is needed in two") was understated. That is the
argument for B making itself: a question with three askers had already
drifted once, and nothing structural was stopping the fourth.

`NeuralVoiceRun.owed(by:)` is now the single answer — pure, computed under
the caller's lock, returning `.nothing`, `.finish` or `.releaseLead` — and
`settle(_:)` acts on it outside the lock, because `report` finishes a
stream and `releaseLead` touches the player, and nothing may reach either
under the mutex. All three sites route through it. `bufferPlayed()` can
only ever receive `.finish` or `.nothing` in practice, since arriving there
means a buffer was HEARD, so the player was started, so
`PlaybackLead.noMoreAudio()` has already spent its one `true`. It is routed
anyway: a site does not get to decide which answers are possible.

**Red before green, and the wall clock shows it.** The strand test's middle
case asserted the BUG while this was open — the honest way to keep CI green
without deleting the evidence. Its expectations were flipped for the fix
and it failed first with `updates → []` (the reply produced nothing at
all), then passed. Its duration went from **3.054 s** — waiting out the
bounded window for a `.finished` that never came — to **0.525 s**.

## D-056 — The language model is 4f; the echo routing fix becomes 4g (milestone order)

**Date:** 2026-08-18 · **Decided by:** Ryad

**And it settles a contradiction the SPEC has been carrying.** §48 called
the language model "4d". The 2026-08-14 ruling renumbered it **4f** (see
the note under 4d's banner). But two later passages went on saying the
opposite — §54's out-of-scope line reads *"the routing fix becomes
milestone 4f, after TTSKit (4e)"*, and §67's reads *"the language model
(4g)"*. Both readings sat in one file, written at different times, never
reconciled. That is the same documents-disagree-with-themselves class the
4e review caught in ARCHITECTURE.md's line counts.

**The ruling: the language model is 4f. The echo ROUTING fix is 4g.** The
contradicting sentences stay where they were written; a numbering note
under 4f's banner names them and points here.

**Why the reply, not the routing.** Three reasons, and the third is the one
that decided it:

1. The reply generator is the spine's last placeholder. Every other organ
   is real; a conversation that answers with your own words is a
   demonstration of plumbing, not of a product.
2. The seam is already cut for it. `SpeechPhraser` exists BECAUSE D-037's
   F-1 was ruled twice — a language model emits subword fragments, so
   per-token utterances would be wrong rather than merely choppy. That
   ruling was made in 4b for a producer that did not exist yet.
3. **The routing fix cannot honestly start yet.** Its whole purpose is the
   echo canceller seeing the reply, and whether that works is AC-104 —
   which never happened, and which the SPEC itself says would *reshape*
   the work. Starting 4g now would mean building before the measurement
   that decides its shape, which is exactly what D-054 rule 4 forbids.

*Rejected:* **the routing fix first** — it has the warmer harness
(`voice-onmic`, `graph-probe`) and closes 4e's loudest unmet criterion, but
it is gated on a phone measurement nobody has taken.

*Rejected:* **a phone-truth pass first** (AC-104, AC-102's stop-latency and
thermal numbers, the `voice-listen` decision) — genuinely useful, and it
de-risks 4g. It loses because it is debt-paying rather than building, and
4f's own AC-110 forces a phone trip anyway.

**One thing this ruling does NOT settle, and it is load-bearing:** Apple's
Foundation Models is `unavailable(appleIntelligenceNotEnabled)` on the
development Mac — measured 2026-08-18, not remembered. If it is also
unavailable on the iPhone, 4f has no engine and F-6's deferral of MLX
reverses. AC-110 exists to answer that before any adapter is written.

## D-057 — 4f's five open forks, ruled (Milestone 4f)

**Date:** 2026-08-18 · **Decided by:** Ryad · **Rulings: F-2 = A, F-3 = A,
F-4 = A, F-5 = A, F-6 = A** — all five on the spec's recommendations,
ruled in one message. F-1 is deliberately NOT here: the spec gates it on
AC-111's measurement, and ruling it on an argument today would be exactly
the guess §71 warns about.

**F-2 = A — one `LanguageModelSession` per turn, stateless.** The
`TranscriptLedger` already carries the whole thought, so the context the
model needs is assembled by us and visible. *Rejected:* **B, one
long-lived session with multi-turn memory** — the budget is a hard 4096
tokens (read from the machine, AC-116), a barge can collide with
`concurrentRequests`, and a cancelled turn may still spend budget. Memory
across turns is its own later milestone, named rather than smuggled in.

**F-3 = A — the model is told it is SPEAKING.** A short instruction
shaping replies for speech: brief, no markdown, no lists, no headings —
this reply is heard, never read. The instruction TEXT lives in the app,
not the library: mechanism, not policy (D-027's rule, applied again).
*Rejected:* **B, no instructions** — the default shapes replies for a
screen.

**F-4 = A — a refusal is spoken, and the turn completes normally.**
`guardrailViolation` and `refusal` are ordinary outcomes of a supervised
model, not crashes. *Rejected:* **B, refusal as turn failure** — silence,
and the person cannot tell a refusal from a bug.

**F-5 = A — the adapter lives in core, beside `AppleSpeechEngine`.**
Foundation Models is a SYSTEM framework in an OS the platform floor
already requires (D-017), so the zero-runtime-dependency vow (D-016) is
untouched and the precedent is exact. *Rejected:* **B, a new opt-in
product** — that shape exists to quarantine PACKAGE dependencies
(WhisperKit, TTSKit); there is nothing here to opt out of.

**F-6 = A — MLX is deferred, behind a time-boxed spike gate.** The spike
already ran and its finding stands: MLX builds Swift 6 clean and then
**cannot run from a SwiftPM binary** (`Failed to load the default
metallib`; the vendor's own README says SwiftPM cannot build Metal
shaders). This repo's CI and bake-off ARE SwiftPM. A green build that
cannot generate one token is a lying instrument, and D-023's fourth
question fails in a new way: the code is removable in a day, the build
system is not behind the protocol at all. The gate's demands are in the
spec (§74); the result is logged as a D-entry either way. *Rejected:*
**B, adopt now and change the CI story** — trading the machine that
guards everything for a second engine, in the milestone that does not yet
have a first. **The honest cost of A, carried knowingly: 4f ships the
reply seam with ONE real citizen, below this repo's own
two-implementations standard, until the bake-off milestone.**

**Still gating everything, unchanged from D-056:** Apple Intelligence is
OFF on the development Mac, so the floor engine is `unavailable` here
until the setting is flipped — and the iPhone has not been asked at all.
AC-110 runs before any adapter code.

## D-058 — F-1 ruled on the phone's number: the diff, with a tripwire (Milestone 4f)

**Date:** 2026-08-18 · **Decided by:** Ryad · **Ruling: A + tripwire**

The spec refused to rule this fork on an argument (D-057 left it out on
purpose), and the measurement arrived: on Ryad's iPhone, four prompts, 23
snapshot pairs — every snapshot cumulative, every one strictly extending
its predecessor, zero revisions, zero grapheme splits (INSTRUMENTS §22).

**The ruling.** The adapter diffs consecutive snapshots and emits the new
suffix — and **every snapshot is CHECKED**: if one ever fails
`hasPrefix(previous)`, the run reports a named failure and a health event,
and nothing is handed to a mouth. The property the diff depends on is
asserted where it is depended on, every time, at the cost of one string
compare per snapshot — about seven per reply.

**Why the tripwire is not decoration.** Two facts from this same
milestone: one run of "never revised" is evidence, not a law — the
probe's own trace says so — and the Simulator had JUST shown this
platform vouching for a model it could not produce (AC-110's status
note). A platform that can lie about availability earns a check on its
stream shape. The failure the tripwire prevents is the worst one this
pipeline can produce: **spoken garbage with no alarm** — words in the
room that the model then contradicted, detectable by nobody but the
person listening.

*Rejected:* **A pure — trust the property.** Smallest code, and exactly
what was measured. But its failure mode is audible and silent at once,
and the check that removes it costs seven string compares.

*Rejected:* **C — hold back the unconfirmed tail.** Immune to revision,
but it prices insurance above the measured risk: latency on EVERY reply
against an event never observed in 23 pairs. If the tripwire ever FIRES,
C is the fallback already designed, and this entry is where its price was
written down in advance.

*Rejected:* **B — do not stream.** Dead on the numbers: a warm first
snapshot lands in ~280 ms, and a whole-reply wait would throw that away.

## Corrections to D-058, from the 4f review — and one fork it opens

**Date:** 2026-08-19 · The ruling stands; one sentence in it promised more
than the code delivers, and the review proved it with a grep.

**D-058 says the tripwire's violation becomes "a named failure and a
health event."** The named failure exists and is pinned by test; the
silence guarantee exists and is pinned; **no health event exists.**
`HealthEvent` has no case for a reply revision, and nothing in the
Conversation layer holds a diagnostics handle to publish one through. The
failure does reach the ledger as `turnFailed` on the conversation stream —
an alarm, but not the HEALTH alarm the entry names, and in this repo
"named failure + health event" is precise vocabulary from the D-028
precedent, where both surfaces literally exist.

**Why it is not being quietly built:** the reply path has NO diagnostics
seam today, and growing one is a change to a seam's shape — Ryad's to
rule, not a review fix (the D-051 precedent, exactly). **The fork, open:**
A — thread `PipelineDiagnostics` into `TurnCoordinator` so reply failures
can publish health events (the mind's tripwire among them). B — accept the
conversation stream's `turnFailed` as the alarm and amend D-058's wording.
Until ruled, D-058's promise is read MINUS the health event, and this
entry is the honest record of the difference. *(Ruled the same day:
**A**, D-059 below — the promise stands, the code rose to it.)*

## D-059 — The health road: dead turns reach the diagnostics stream (Milestone 4f)

**Date:** 2026-08-19 · **Decided by:** Ryad · **Ruling: A** (of the fork the
D-058 correction opened)

`TurnCoordinator` now takes an optional `PipelineDiagnostics`, like the
clock: nil injected is byte-for-byte the old coordinator — monitoring is
opt-in, never ambient (the D-026/D-028 precedents). `failTurn`, the ONE
funnel every turn death already passes through, publishes
`HealthEvent.turnFailed(turn:failure:)` — typed, not stringly. Same fact,
two audiences: the conversation stream serves whoever follows one
conversation; the health stream serves whoever watches the pipeline's
wellbeing across all of them. **D-058's tripwire alarm now exists**: a
snapshot revision fails the turn through this funnel and rides this road.

Red before green: the test asserting the health event ran and FAILED
before the funnel published, then passed on the one-line wiring. Every
other coordinator test runs with nil injected, which is the
byte-for-byte proof, free.

*Rejected:* **B — amend D-058's wording and accept the conversation
stream's `turnFailed` as the alarm.** It was my recommendation, on the
argument that no health-event consumer exists yet. Ryad overruled it:
the ruling's promise stands and the code rises to it, rather than the
words sinking to the code. The demos already listen to the health stream
(the Mac's 🩺 line now prints dead turns), so the consumer argument was
weaker than claimed.

## D-060 — 4g's four forks: the canceller sees every mouth, always, opt-in (Milestone 4g)

**Date:** 2026-08-19 · **Decided by:** Ryad · **Rulings: F-1 = A, F-2 = A,
F-3 = B, F-4 = A** — all four on the recommendations.

**F-1 = A — replies render on the capture engine's voice-processing
unit.** The only mechanism D-043's measurement endorses. *Rejected:*
**B, raise the gate while speaking** — the echo arrives at peak 1.0,
indistinguishable by level from a human barge, so B stops self-barging by
killing speaker barge-in, the product's soul. *Rejected:* **C,
half-duplex** — kills barge-in entirely. Both stay priced in the spec as
fallbacks if AC-119's phone measurement refutes A on this hardware.

**F-2 = A — Apple's mouth routes its PCM through our host** via
`AVSpeechSynthesizer.write(toBufferCallback:)`: one rendering path for
every mouth, and the canceller sees them all. Gated on AC-119/120.
*Rejected:* **B, receiver-only documented** — not a fix, a smaller
warning label.

**F-3 = B — hosted rendering runs for the WHOLE conversation**, one
configuration. *Rejected:* **A, per-route swapping** — route churn on a
live graph is what cost 4e an afternoon; the D-052 rejection said
exactly this, and it holds one seam over.

**F-4 = A — `hostsPlayback` stays default-off; the app opts in.** 4g
proves the arrangement on ONE device; a library default claims every
device (D-027: mechanism in the library, policy in the app). *Rejected:*
**B, default-on once proven** — a bolder claim than one phone's evidence
supports.

## D-061 — the MLX gate: closed by measurement, and F-6 was half right (Milestone 4h)

**Date:** 2026-08-21 · **Decided by:** Ryad · **Verdict: the gate
PASSES for `swift test` and for CI, FAILS for the iOS Simulator, and is
UNTAKEN on a device.** MLX is admissible as 4h's second mind.

This entry exists because D-057's **F-6 = A** demanded it: MLX was
deferred behind a time-boxed spike gate, run OUTSIDE the repo, with no
`Package.swift` line until it passed and the **"result logged as a
D-entry either way."** The gate ran (INSTRUMENTS §24, STAGES 1–3 and the
runner's answer). This is that entry.

**What F-6 assumed, and what the machine said.** F-6's objection was
that MLX "would compile everywhere and RUN nowhere in the current
toolchain — a green build that cannot generate one token," which is this
repo's lying-instrument problem. It was an honest reading of a real
failure (`swift run` dying with *"Failed to load the default metallib"*).
It was also incomplete:

| question | answer | where |
|---|---|---|
| can `swift test` run MLX? | **yes** — with a 3.6 MB `default.metallib` in the working directory | §24 STAGE 1 |
| does it generate? | **yes** — 67 ms to first token, Qwen3-0.6B-4bit | §24 STAGE 2 |
| does hosted CI pay 688 MB per run? | **no** — `macos-26` ships the toolchain; links a metallib in 15 s | §24 runner |
| can the iOS Simulator run MLX? | **no, structurally** | §24 STAGE 3 |
| can a device? | **untaken** — needs a signed build | — |

**F-6 earned its Simulator half, and that is recorded rather than
buried.** MLX asks Metal for a heap with `ResourceStorageModeShared`
because it assumes unified memory; `MTLSimDevice` requires `Private` and
refuses. `Device.cpu` does not escape it — the allocator is chosen at
BUILD time, so every allocation on any device goes through the refused
heap. For the Simulator, "compiles everywhere, runs nowhere" is exactly
true, and no flag changes it.

*Rejected:* **treating the gate as failed** on the strength of the
Simulator result — it would have thrown away a measured 67 ms and a
green CI answer because one platform cannot host the runtime. *Rejected:*
**treating it as a clean pass** — that would have hidden a real hole:
the Simulator is where this project's cheapest testing lives, and losing
it is a cost, not a footnote.

**The consequences carried into 4h, so they are not rediscovered
later.** A missing metallib does not fail a test, it **aborts the
process** — a crashing runner cannot report, which is why AC-129 exists.
`MLXFoundationModels` — F-6's watch item, which would have collapsed the
two minds into one adapter with two backends — is **ABSENT** from
mlx-swift-lm 3.31.4, read from the checkout rather than remembered, so
it is not a choice today. And measured while ruling F-4: there is no
`mmap` anywhere in MLX's C++ core, so 334 MB of weights stay resident.

## D-062 — 4h's five forks: the second mind, gated at the token, paid for in the open (Milestone 4h)

**Date:** 2026-08-21 · **Decided by:** Ryad · **Rulings: F-1 = A,
F-2 = B, F-3 = A, F-4 = A, F-5 = A** — all five on the recommendations,
ruled in one message. Two of those recommendations had been REWRITTEN by
measurement first (SPEC §86, §89); the rulings are on the measured
versions, not on the first draft, which stands in commit `ae78681`.

**F-1 = A — MLX directly**, `MLXLLM` + `MLXLMCommon` plus a real
tokenizer, in an opt-in product. *Rejected:* **B, wait for
`MLXFoundationModels`** — checked, not assumed: absent from 3.31.4, so B
is a wish rather than a choice. *Rejected:* **C, llama.cpp** — its one
serious argument is that it compiles Metal shaders from embedded source
at RUNTIME, which would make F-3's whole problem vanish; that claim is
**UNMEASURED** and was deliberately not ruled on as if it were evidence.
Its priced costs: C++ interop inside a Swift 6 strict-concurrency
library, and a second build system, against a stack that is Apple-native
everywhere else. If the runtime-Metal claim ever matters, it gets gated
exactly as MLX was — spiked outside the repo, logged either way.
*Rejected:* **D, defer again** — the mind would keep its single citizen,
which 4f already admitted is below this repo's own standard.

**F-2 = B — the prompt switch plus the token-ID gate; the general text
filter is NOT built yet.** §86's layers 1 and 2. Reasoning never becomes
a string, so there is nothing to retract. *Rejected:* **A, all three
layers** — layer 3 is a general answer to a problem no model in this
project has, and D-053's rule applies: surface is earned by a second
REAL case, not an imagined one. Layer 3 also costs the thing this
project guards hardest — holding text back to inspect it delays the
mouth, and two milestones were spent measuring a 542–567 ms felt pause.
*Rejected:* **C, a string filter in core** (the first draft's answer) —
measured to be redoing work the vocabulary already does exactly: `<think>`
and `</think>` are single tokens, 151667 and 151668. *Rejected:* **D,
trust `enable_thinking` alone** — the template merely PRE-FILLS a closed
block, so it is a convention, not a decoding constraint; one model
update away from a phone reading its reasoning aloud, when the guard
costs one integer comparison.

**F-3 = A — the metallib is built in CI by the preinstalled toolchain,
and locally by a documented script; live tests skip when it is absent.**
*Rejected:* **B, vendor the binary into git** — §24 argued against a
blob in a repo whose method is reproducibility. *Rejected:* **C, no live
MLX tests** — the adapter's real path would never be machine-checked.
**D, a hosted release asset, is recorded as the named fallback** if
contributor friction proves real; its costs are a network fetch inside
the build and exact version skew with mlx-swift, which would need a
checksum and a pin or it becomes a quiet wrong-answer machine. Two more
were rejected on measurement rather than taste: compiling shaders at
launch is not available for MLX (kernels excluded from the SwiftPM
build, not exposed as source), and SwiftPM's checksummed binary
mechanism takes xcframeworks and artifact bundles, not a bare shader
library.

**F-4 = A — the MLX product follows Whisper exactly:** its own
`modelInstalled()` and `ensureModel()`, same semantics. This ruling
CORRECTS the spec's first draft, which said the library must never reach
the network. That was wrong on this repo's own terms, and a review
caught it: `MultiModalKitWhisper` already downloads ~142 MB from Hugging
Face, and its doc states the real doctrine — *"no download is ever
triggered by asking"*, and "installed" means OFFLINE-CAPABLE, checking
the tokenizer files too because an audit found a silent network
fallback. So the rule is not abstinence; it is **explicit, idempotent,
and never provoked by a question.** *Rejected:* **B, path-only** — it
would make this engine the odd one out for no gain. *Rejected:* **C, a
shared models package** — tidier, but a new shape earns its place when
two citizens genuinely share something, and these two share no byte.
**Carried as a named unknown:** no `mmap` in MLX's core, so 334 MB is
resident beside the audio graph, the recogniser and the mouth — a device
question, not a Mac one.

**F-5 = A — pay the dependency bill, inside the opt-in product only.**
Measured: `mlx-swift-lm` 3.31.4, `mlx-swift` 0.31.6, transitively
`swift-numerics` 1.1.1, `swift-argument-parser` 1.8.2, `swift-syntax`
603.0.2 — plus a tokenizer, because mlx-swift-lm deliberately excludes
swift-transformers and ships `#huggingFaceTokenizerLoader()`, a macro
wrapping YOUR `Tokenizers.Tokenizer`. **Three direct packages, not
one.** D-023's four questions still pass, the fourth because the code
lives behind `ReplyGenerating` in a product nobody must import — and
D-016's tier 1 is untouched: the core keeps zero runtime dependencies,
enforced mechanically by CI's core-alone build. *Rejected:* **B, a
hand-written tokenizer** — the spike already produced ids that were
valid but wrong, and Qwen3 is `Qwen2Tokenizer` (BPE), so the "200 lines
of SentencePiece" estimate is not the bill either. *Rejected:* **C,
refuse and defer.** Two proposed escape hatches were examined and do not
work: vendoring the macro's expansion does not remove swift-transformers
(the macro WRAPS a tokenizer, it does not generate one), and swift-syntax
is a build-time dependency of macro expansion that is never in the
runtime graph at all — its true cost is CI build TIME, which is a reason
to measure that time, not to redesign around a ghost.

## D-063 — 4h's FIELD rulings, and the adversarial review that followed (Milestone 4h)

**Date:** 2026-08-21 · **Decided by:** Ryad · **Rulings: FIELD-1 = C then
B, FIELD-2 = B (500 ms)** · **Review: 52 claims, 29 refuted, 23
confirmed, 1 refuted afterwards by measurement.**

**A numbering apology first.** D-062 ruled 4h's spec forks F-1…F-5. The
forks below arose LATER, from field sessions, and were discussed as "F-1"
and "F-2" again in conversation. That collision is why the review found
"DECISIONS.md still says F-1 = A while the shipped code does something
else" — the log was right and the conversation was sloppy. They are named
**FIELD-1** and **FIELD-2** here so no future reader has to guess.

**FIELD-1 = C, then B — which local model.** Ruled in two steps because
the first ruling existed to produce a measurement the Mac could not.

*C first:* put the choice in the demo, so the PHONE answers whether 2.1 GB
of resident weights survives beside an audio graph, a recogniser and a
mouth. *Rejected at that moment:* ruling A or B on Mac numbers, which
would have been a guess about a device with jetsam from a device without.

*Then B, on the phone's own evidence:* 2288 MB peak across 38 turns, no
kill, 291–315 ms to the first word, and none of the 0.6B model's
parroting on interrupted speech. *Rejected:* **A, keep 0.6B** — it
answered a barged fragment by repeating it verbatim, which the field log
shows three times in a row. The picker stays: one device is one device,
and D-060 F-4's reasoning about library defaults claiming every device
has not stopped being true.

**FIELD-2 = B — the reply gate, 500 ms, in the app.** AC-81 built this in
4c and the demo never set it, so the assistant committed roughly 300 ms
after Ryad stopped making noise. Measured cost of that: six of 38 turns
opened on a FRAGMENT and were killed by him finishing his own sentence,
and twelve carried a previous turn's words. *Rejected:* **A, leave it at
zero** — fastest, and 16% of turns misfire. *Rejected:* **C, 300 ms** —
half the benefit for half the cost, chosen by nobody's evidence. The
library default stays `.zero` and a test pins it: D-027's line, because
the number costs felt pause 1:1.

**Reply length, same session.** Three instructions measured over the six
prompts from Ryad's own log: the shipped one averaged 19.7 words, "ONE
short sentence, no extra facts" 7.0, and "only what was asked, at most
fifteen words" 9.8. The middle one shipped. The third is worth recording
as *rejected on measurement*: it read like the tighter instruction and
came out longer AND worse, producing self-contradiction and fragments
that sound wrong spoken.

### The D-041 review, and what it found

Six dimensions over the diff, every claim then handed to a skeptic told
to REFUTE it. 29 of 52 died there, which is the process working.

**Fixed (code):** a BLOCKER of my own making — `memoryConflict` guarded
the Listen button while both models load at LAUNCH, and the persistence
added hours earlier made the forbidden pair survive a restart, i.e. a
crash loop with the picker out of reach; `ensureModel()` had no in-flight
latch, so a prewarm plus a tap could each load 2239 MB against a 3351 MB
ceiling (now WhisperEngine's busy-flag-and-waiter-queue shape); a leaked
uncancellable prewarm Task pinning retired weights; a download verified
against the wrong model; a Listen gate that covered only the Apple mind;
a conversation log unreachable in exactly the failures it was built for;
MLX's process-wide peak stamped on turns other minds answered; and
process-global cache policy written by the library.

**Fixed (docs):** three shipped rulings recorded nowhere but INSTRUMENTS
(this entry); §26 still calling the reply gate zero; §25 attributing a
cheap build to "macro expansion we do not currently use" when the adapter
now uses it; SPEC §90 listing model downloading and network use as out of
scope after both shipped; ARCHITECTURE.md showing the mind seam with one
citizen; and MicrophoneSource's comment still calling `hostsPlayback`
historical — the exact staleness that let 4h's 0 Hz crash happen.

**REFUTED afterwards, by measurement.** The review confirmed that "the
zero-dependency vow's only mechanical guard cannot fail". It can: adding
`import MLXLLM` to a core file makes `swift build --target MultiModalKit`
fail. The message is confusing (`missing required module
'_NumericsShims'`) but the build does not succeed. Recorded because a
review finding accepted without testing is the same sin the review exists
to catch.

**Accepted, open, not fixed here.** Two test gaps, named rather than
quietly carried: no test constructs `MLXTokenSource`, so the gate is
proven in isolation but never proven WIRED into the real source; and

*(Correction, same day, recorded rather than edited away: the first half
was PARTLY closed after this entry was written. `MLXMindLiveTests` now
constructs the real `MLXTokenSource` and drives its door on every
machine, mutation-proven. What stays open is narrower and still real — no
test drives a defiant `<think>` from the REAL model through the REAL
detokenizer, because that needs weights AND a model that ignores
`enable_thinking`.)*

`MicrophonePlaybackHost` has no positive test, only the not-rendering
refusal. Both need a real engine or a fake for it, which is its own
piece of work.

## D-064 — 0.6B is removed; the local mind is 4B, and the picker goes with it (Milestone 4i)

**Date:** 2026-08-21 · **Decided by:** Ryad · **Ruling: remove it** —
*"we dont need it, its quality is bad. we will use for sure the 4b"*

**This reverses half of D-063's FIELD-1.** That fork was ruled C (ship a
picker so the phone could answer what the Mac could not), then B (4B as
the default, picker STAYS, "because one device is one device"). The
picker's job is done: it produced the number — 2288 MB peak, 291–315 ms
first word, 38 turns, no kill — and the number decided the model. Keeping
a two-option control whose second option nobody should choose is a
control that cannot be used.

**Why 0.6B goes rather than staying as a fallback.** It was not merely
worse; it was wrong in a way that a fallback must not be. It answered a
barged fragment by repeating it VERBATIM — "13. No, no, no. I ask you the
square of... 113." came back word for word — and reproduced on the Mac
from the phone's own transcript. A fallback is a thing you drop TO when
the good path fails. Dropping to a mind that parrots the user is offering
a worse product as a feature.

*Rejected:* **keep it as the degradation chain's first step.** Tempting,
because 4i's F-1 recommendation named exactly that. But the chain must
degrade to something a person can still USE; a step that produces
parroting is a step that trades a memory problem for a quality one and
calls it graceful.

**The consequence, named rather than discovered in 4i.** 4i's F-1 option
A was "(1) drop the local mind to the small model, (2) drop the neural
voice to Apple's, (3) refuse". Step 1 no longer exists. The chain now
starts at the mouth, and whether that is enough is exactly what the
milestone must measure — which sharpens 4i rather than weakening it: if
the mind cannot be made smaller, either the pair fits or the voice goes.

**What is NOT deleted:** every 0.6B measurement in INSTRUMENTS. They were
true, they paid for this ruling, and removing them would hide the
evidence that produced it.

## D-065 — 4i re-scoped: the chain is not built, because the premise died (Milestone 4i)

**Date:** 2026-08-21 · **Decided by:** Ryad · **Ruling: A — re-scope,
drop the degradation chain**

**A milestone's own first instrument refuted the milestone.** 4i was
drafted around three debts that looked like one question, and its opening
sentence was "4h measured a pair that does not fit". AC-132 — the
headroom instrument, built first because Ryad's F-1 answer promoted it —
measured the pair fitting with **934 MB to spare**, alongside a THIRD
in-process model and a working turn (INSTRUMENTS §29).

**The error was mine and it was repeated in three places** — SPEC §92,
D-064's consequence paragraph, and a red warning in the app. All three
added a Mac's `phys_footprint` to a phone's dirty-memory headroom. CoreML
MAPS its weights, so they are clean pages that a dirty limit does not
charge; MLX has no `mmap`, so its 2225 MB is charged in full. The neural
voice costs **111 MB** on iOS against the 1112 MB I measured on a Mac —
wrong by a factor of ten, and wrong in the direction that forbade a
configuration the user wanted.

**What is dropped:** the pressure level, the hysteresis rule, the
degradation order, and the fork asking where the chain should live
(AC-133–138, F-1–F-3). *Rejected:* **B, build the chain anyway for
smaller phones.** It would be built for a device nobody in this project
owns, which is the purchase D-047 rejected in one sentence — "it protects
against a risk nobody measured" — and it would earn the same label:
insurance, not a measured cure. *Rejected:* **C, close 4i.** The thermal
debt is real, owed since Phase 3, and closing the milestone would orphan
it again.

**What remains: three measurements and no new architecture.** The compile
peak that actually kills (AC-139), AC-102's thermal number at last
(AC-140), and twenty minutes in the configuration Ryad really uses
(AC-141).

**The reopening condition, named in advance** (the D-040 F-3 pattern): if
AC-140 or AC-141 shows this configuration failing under sustained load,
the chain comes back — with evidence, which is the only basis it should
ever have had.

**One fork withdrawn rather than ruled.** F-4 asked how to resolve
`os_proc_available_memory`'s ambiguous 0, and I recommended cross-checking
`limit_bytes_remaining`. Measurement before building showed that field
also reads 0 on macOS, for the opposite reason, so the cross-check
disambiguates nothing. Withdrawn by its author before Ryad spent a ruling
on it.

## D-066 — the phone gets a bench, not a bigger settings screen (Milestone 4j)

**Date:** 2026-08-23 · **Decided by:** Ryad · **Ruling: all four
recommendations accepted**

**Why this milestone exists at all.** The Mac can now be tuned from the
command line — decoder, vocoder mode, temperature, cushion (§31.1) — and the
first thing that tuning produced was a disagreement between the clock and
Ryad's ears (§32). `temperature 0` has the fastest first audio of all six
configurations and he calls it bad; `throughputOptimized` starts 180 ms later
and he ranks it level with the winner. **No instrument in this repo measures
what he judged in five seconds**, so the human has to stay in the loop — and
the phone, which is the device that actually matters, has no way to put him
there. It has an engine picker, a mind picker and a voice picker, and not one
of the four levers.

**The constraint that shapes the whole milestone:** `.fused` cannot load on
iOS 18+. `MLModelConfiguration.functionName` must be nil unless the model is
an ML Program, and the Qwen3 multi-code decoder is not. So the phone can
compare four configurations where the Mac compares six, and the best one on
the Mac is not available on the phone at all.

**F-1 — how many screens? Ruled A: three tabs (Chat · Bench · Settings).**
A live meter redrawing at 60 Hz and a stopwatch have no business on the same
screen; the bench must not be timing itself while it animates. *Rejected:*
**two tabs (Chat + Settings)** — it saves a tab by putting the measuring
tools among the pickers, which is how the 884-line ContentView got that way.
*Rejected:* **one screen with a settings sheet** — a sheet cannot be watched
while the thing it configures is running, and watching is the point.

**F-2 — does the phone offer `.fused`, knowing it cannot load? Ruled B:
offer it, and let it refuse honestly with the CoreML reason.** *Rejected:*
**hide it** — a picker that hides the option teaches nobody why, and the
next person to read the library's default (`.fused`) will wonder where it
went. *Rejected:* **offer it labelled "fails here"** — a label is a claim; a
refusal carrying the actual error is evidence. This follows rule 5 of D-054:
an instrument must be able to say whether it is switched on, and a
constraint you can trigger on demand is a constraint you can prove.

**F-3 — sweep on the phone, or ear-only? Ruled C: both, with the sweep gated
on the mind being unloaded.** Ear-only would reproduce the Mac's blind spot
in the other direction — no numbers at all. A sweep with the 4B mind
resident is the memory kill 4i exists to study, and an instrument that
crashes the app is not an instrument. *Rejected:* **port the sweep
unconditionally** — it would be killed and the kill would be read as a
result. *Rejected:* **ear-only** — Ryad's ranking is only interesting
*because* there were numbers to disagree with.

**F-4 — where do the phone's numbers go? Ruled B: copy as a markdown
table.** The Mac's numbers reach INSTRUMENTS by being printed and pasted;
the phone's should arrive in the same shape, beside them, comparable.
*Rejected:* **on-screen only** — a number that cannot leave the device
cannot be reviewed, and every claim in INSTRUMENTS is reviewable.
*Rejected:* **share-sheet export** — a file to open, name and find, when
what is wanted is a paste into a document already open.

**Not yet ruled:** whether 4j starts before or after 4i's remaining
criteria (AC-139 compile peak, AC-140 thermal, AC-141 twenty minutes) are
measured. The spec is written as 4j and does not absorb them.

## D-067 — the bench driver gets its own module, and 4j starts now (Milestone 4j)

**Date:** 2026-08-23 · **Decided by:** Ryad · **Ruling: F-1 = A, F-2 = start
now**

**F-1 — where the sweep driver lives. Ruled A: a new `MultiModalKitBench`
module.** The five hazards in SPEC §104 mean the sweep needs real semantics —
wait for readiness rather than for time, reset counters per row, scope the
settings so a death leaves no residue — and semantics want tests. A module is
what makes them testable on a Mac. Tier 2 of D-016: the core keeps its zero
runtime dependencies and learns nothing about benchmarking.

*Rejected:* **B, put it in `MultiModalKitTTS`.** One fewer module, at the
price of a voice library holding a benchmarking concern. It would fail the
deep-module test in §4.0 — a type whose insides leak into a neighbour's
purpose. *Rejected:* **C, put it in the app.** Nothing new to name, and
nothing testable either: AC-147 (readiness, never time) and AC-149
(per-iteration counters) would have no home, and they are the two criteria
written directly against hazards that have already bitten.

**F-2 — sequencing. Ruled: start 4j now, with 4i's three criteria still
open.** AC-139 (compile peak), AC-140 (thermal) and AC-141 (twenty minutes)
all need Ryad's phone, and all three stay open and unabsorbed. AC-148 makes
every bench row carry the thermal state it was measured under, so the bench
is plausibly the instrument AC-140 has been waiting for — but that is a hope,
not a plan, and 4j does not claim to pay 4i's debt.

**Consequence:** branch `milestone/4j-tuning-bench`, cut from the 4i branch
so that D-066, SPEC §100–108 and the three bug fixes travel with it. 4i's
branch stays open for the three field measurements.

## D-068 — the cushion is learned, and a human still outranks it (Milestone 4j)

**Date:** 2026-08-23 · **Decided by:** Ryad · **Ruling: A and D together**

**The finding that forced the question.** Fixing `voice-spike`'s cushion bug
changed the published comparison: `.stepped` costs **693 ms** to first audio,
not the 201–224 ms in §31, because those runs had a zero cushion and were
measuring a starved player. The ranking survives; the gap goes from 1.2× to
3.6× (INSTRUMENTS §33). And it lands hardest on the phone, which cannot load
`.fused` at all and therefore pays the cushion on every configuration it can
run.

Then the deeper problem: the cushion the phone is given is derived from a
**Mac's** constant. `measuredRealTimeFactor(for:)` returns 1.066 for
`.stepped`; the iPhone measured **1.21** (§22). On a six-second reply that is
396 ms where ~1260 ms is called for — under-cushioned by about 860 ms, on the
device that matters. §22 recorded exactly this in August and deferred it to
"the voice-quality milestone's work". This is that milestone.

**Ruled A — adapt from the margin the voice already reports.** Every reply
ends with a `DecodeMargin` carrying the steady factor it achieved. The next
reply's cushion is sized from it. No calibration step, no device table, and
the number was already being computed. *Rejected:* **B, calibrate once at
startup** — correct from the first reply, at the price of a load-time delay
on a device where the load is what kills the app (INSTRUMENTS §29).
*Rejected:* **C, a per-device constant table** — inspectable, and wrong on
every device nobody has measured, which is all of them but two.

**Ruled D as well — the human's lever still wins.** The precedence is one
line:

    a human's number  →  this machine's measurement  →  the constant

A lever on screen that a measurement can silently overrule is not a lever.
Ruling D alongside A is what keeps AC-143's control honest.

**Cost, named.** The first reply of a session is still cushioned by the
constant, because nothing has been measured yet. On a slow device that reply
runs dry. Accepted knowingly — the alternative was B, and B was rejected for
a reason that has already killed the app three times.

## D-069 — 4k signed; the shield defaults ON in this app (Milestone 4k)

**Date:** 2026-08-24 · **Decided by:** Ryad · **Ruling: spec §109–116
signed; F-1 = A**

**F-1 = A — the speaker shield defaults ON in the demo app, with the
warning kept for anyone who turns it off.** The convicting evidence was a
reinstall: Ryad deleted the app to re-download the voice, UserDefaults was
wiped back to the default, the default was `false`, and his next
conversation self-barged — precisely as the app's own orange label
predicted ("it will interrupt itself"). A default that breaks the first
conversation after every reinstall is not a safe default.

D-060 F-4 is NOT reversed: it kept the *library* default off because a
library claims every device, and it said in the same breath that the app
chooses. This is the app choosing, on this device's own evidence — §23's
matrix (tone cancelled to 0.004–0.08 shielded, 1.0 unshielded), §29's
working field log (`speaker shield=true`), and §37's conviction.

*Rejected:* **B, keep opt-in and warn** — the warning was already on
screen during the failing session, and warning a person about a default
they did not choose is a smaller apology, not a fix. *Rejected:* **C,
remove the toggle** — it is the A/B instrument AC-121's field work still
uses, and §23's suspects are still unconvicted in the shielded arrangement.

**Scope note on AC-157, stated rather than slipped:** the warning stays
scoped to the SPEAKER route. Receiver + no shield is not a guaranteed
failure — the 4d gate (0.021) was earned on exactly that arrangement and
it held a whole era of field sessions. The warning covers the measured
danger, not every non-default state.

## D-070 — a retired voice is terminal, and it takes its reply with it (Milestone 4k)

**Date:** 2026-08-24 · **Decided by:** Ryad · **Ruling: F-2 = C — both
halves**

**The review found the promise unbacked.** `settleLevers` carries the
comment *"Retire AFTER the replacement exists … and before loading the new
one, so two pipelines are never both resident."* Nothing guaranteed it.
`NeuralVoiceRun.beginDraining` stores `Task { [self] … }`, so a speaking run
keeps ITSELF and its `TTSKit` alive; `NeuralVoice` keeps no reference to the
run, so `retire()` cannot reach it; and `shutdown()` touches only `ownHost`,
which is `nil` on the conversation path because the app calls `render(on:)`.
So `retire()` freed nothing, and the very next `openUtterance()` on the
retired voice would build a SECOND pipeline — 2.2 GB where 1.1 was intended,
the jetsam kill of INSTRUMENTS §28/§29 that `retire()` exists to prevent.

**Ruled C — the library guarantees it AND the app never creates the
window.**

- **The library half:** `NeuralVoice` becomes terminal. A latch is raised in
  the same actor step as the retire, before any await; the live run is held
  weakly and cancelled; and `loadedPipeline()` refuses both before and after
  its await (the reentrancy law — a caller already parked in the queue
  passed the first check before the retire landed).
- **The app half:** when a lever changes while listening, the pipeline is
  stopped and AWAITED before the swap. There is then no live run to cancel,
  no coordinator holding a dead voice, and no window at all.

*Rejected:* **A alone, the library cancels** — it frees the pipeline but
leaves the old coordinator running against a voice that now throws; the turn
in flight dies visibly and nothing else stops. *Rejected:* **B alone, the
app stops first** — it closes this app's window while leaving the library's
promise unenforceable by anyone else, and D-027 puts the mechanism in the
library precisely so the next consumer inherits it.

**The cost, named:** changing a lever mid-conversation now visibly stops the
conversation for the length of the new voice's load. That is honest — it is
what was always happening, minus the pretence that the old voice was still
usable during it.

**Required regardless of the fork, and not part of it:** `settleLevers` is
serialized (two lever changes could overlap two full loads), and the sweep's
honesty defects are fixed separately. Both came from the same review.

## D-071 — throughput is the phone's voice, and a barge must persist (Milestone 4k)

**Date:** 2026-08-25 · **Decided by:** Ryad · **Rulings: throughput as the
phone's default vocoder; barge window N = 600 ms**

### The vocoder, and a Mac ranking that did not transfer

§31 ranked `throughputOptimized` third and fourth of six on the Mac. §36
measured it winning BOTH columns on Ryad's iPhone — ~2.4 s adapted first
audio against ~3.1 s, ~9.4 s total against ~10.7 s — because a faster decode
needs a smaller cushion, and the phone is the machine the cushion exists
for. §42 then had Ryad listen: *"1 and 2 sound goods"*. **A tie on sound is
what hands the ranking to the numbers**, and the numbers were already in.

`VoiceLevers.phoneDefault` is now `stepped + throughputOptimized`. The Mac's
default is untouched — `audio-demo` still starts `.fused` + latency, because
a Mac has throughput to spare and never needed the trade.

Temperature 0 is convicted twice and defaults nowhere: §32 called it the
worst sound on the Mac, and §42 got *"voice hung and become weired… the
worst one"* from the phone.

### The barge window, and the axis everyone had been measuring

The assistant interrupts itself. With the shield ON it still happens, and
§42 ended with the sentence that outranked the whole ear test: *"i was not
able to hear all the answer."*

**The discriminator is DURATION, not level** (§43). Across six field
sessions:

```
    echo?    339 – 520 ms      peak 0.022 – 0.281
    speech   939 – 3100 ms     peak 0.084 – 0.398
```

Duration separates with a 419 ms gap; level overlaps. **D-060 F-1 is
confirmed, not overturned** — it rejected "raise the gate while speaking"
precisely because the two cannot be told apart by level. Every level-based
cure, including the per-route calibrated gate this project proposed in §41,
was aimed at the wrong axis and would have traded deafness for silence.

**Ruled: 600 ms.** 80 ms clear of the longest leak ever measured, 339 ms
clear of the shortest real utterance. *Rejected:* **700 and 900 ms** — more
margin against a gap that is already 419 ms wide, bought with a slower
interruption. *Rejected:* **doing nothing until the shield is improved** —
the shield is already on and already working; this is its residue.

**The cost, named:** a deliberate interruption takes 600 ms longer to stop
the voice. Barge-in is the product's soul (D-060), so that is a real price —
paid because a barge that fires on the assistant's own voice is worse than
one that waits.

**Not D-036 returning.** That window gated TRANSCRIPTION and clipped speech
("Riyadh" → "Riyat"). This clips nothing: audio reaches the transcriber
unchanged, and only the kill decision waits.

**Zero by default in the library** (D-027, as D-060 F-4 did for the shield):
a device whose canceller removes system-wide output — macOS (§39) — wants
none of this. `BargeWindow.measured` is the number, and the app reaches for
it. Defaulting it to 600 ms broke seventeen existing tests, and they were
right to break.

## D-072 — a lever that cannot work must say so in our words (Milestone 4l)

**Date:** 2026-08-25 · **Decided by:** Ryad · **Rulings: F-1 = A
(`--voice-model=`), F-2 = B (disabled with the reason), F-3 = A (parse into
`VoiceLevers`), F-4 = B (no compute-units lever)**

### The finding that made all four cheap to rule

The 1.7B voice failed on Ryad's phone with a CoreML plan-build error, and
this project proposed two explanations for it. Both were wrong, and both
were produced the same way — by reading a file path and reasoning from it
instead of measuring. The repository says `code_decoder` ships
`W8A16-stateful` for BOTH sizes; the working 0.6B on this Mac sits in a
`W8A16-stateful` folder; the ANE compiles a stateful code decoder on that
phone every day.

The real answer was never a puzzle. It is a comment in the dependency:

> The 1.7B model requires more peak memory during CoreML compilation than
> iOS/iPadOS devices can reliably provide, so it is restricted to macOS.

`TTSModelVariant.isAvailableOnCurrentPlatform` returns false for 1.7B on
iOS, and **this project has never read it**. That is the whole defect. Every
fork below is about what to do with a `no` we were already being told.

### F-1 — the flag's name

`--model=` is taken in both executables and means *a directory of MLX
weights for the MIND*. One string cannot name two organs.

**Ruled: A — `--voice-model=0.6b|1.7b`.** It joins the vocabulary already
in use (`--mouth=`, `--mind=`) and reuses the exact tokens the iOS app
persists, so the terminal and the phone say the same words.

*Rejected:* **B, `--tts-model=`** — "TTS" is the vendor's word; this
project's word for that organ is "mouth", everywhere including COMMANDS.md.
*Rejected:* **C, rename `--model=` to `--mind-model=`** — the tidiest end
state and the only one that removes the ambiguity at its root, but it breaks
a documented flag across four subcommands and Ryad's own muscle memory for
a cosmetic gain.

### F-2 — what the phone shows

**Ruled: B — the 1.7B row stays visible, disabled, carrying our sentence,**
not CoreML's. The screen teaches what the device cannot do and why, and it
costs nothing to say.

*Rejected:* **A, hide it on iOS** — the picker would never lie, but it would
never teach either; a reader could not learn that a better voice exists.
*Rejected:* **C, leave it tappable and let it refuse** — the literal D-066
precedent, and the tension is named rather than buried. D-066 chose that
shape for `.fused` when the refusal was EVIDENCE this project needed and did
not have. Here the answer is already in hand, so a tap buys no information
and spends a 1417 MB compile attempt on a phone that reaches "hot" in under
three minutes (§40). **The precedent's shape survives; its reason does
not**, and the reason is what decided it.

### F-3 — where the parsing lives

`chosenMouth` hand-parses four flags and calls `NeuralVoice(...)` directly,
never building a `VoiceLevers`. The tested type and the shipped CLI path
share no code — which is precisely why the model lever added in `75e1381`
reached the phone's Bench and never reached the terminal.

**Ruled: A — parsing moves into the library, producing a `VoiceLevers`.**
No test target can import an executable, so parsing that lives in
`AudioDemo.swift` is structurally untestable; moved, it is covered by the
suite that already exists, and the next lever reaches every caller at once.

*Rejected:* **B, a fifth hand-rolled ternary** — half an hour of work that
preserves a duplication which has already cost this project one silently
missing lever, and which still turns `--decoder=banana` into `.fused`
without complaint.

### F-4 — the compute-units lever, refused

TTSKit exposes per-component compute units and applies them at load; this
project passes none, so the three decoders silently run CPU+ANE. If the ANE
plan build is the memory peak the vendor names, `.cpuOnly` might dodge it
and let 1.7B load on iOS. It is the only route that could put a better voice
on the product device, and it is refused anyway.

**Ruled: B — do not build it**, on a number that was already measured. §47
recorded 0.6B running at **1.06× real time** on that phone *with the ANE
doing the work* — barely keeping up. 1.7B is 3.2× the decoder, moved off the
ANE and onto the CPU. Real time is gone by a margin no cushion can bank, and
a voice that cannot keep up is not a voice.

*A second, smaller reason:* `ComputeOptions` is `Sendable` but not
`Equatable`, and `VoiceLevers`' synthesised `Equatable` is load-bearing in
the two places that decide whether the voice gets rebuilt and whether a
bench row is trusted. The lever could not be the vendor's type; it would
need a mirrored enum of our own, for an outcome we can already predict.

**The cost, named:** 1.7B is now a macOS-only capability by OUR decision as
well as the vendor's, and `supportsVoiceDirection` — style instructions —
is true only for 1.7B. So this ruling closes the door on voice direction for
the iPhone until either the device's compile headroom grows or the vendor
ships a smaller build. AC-139's unmeasured compile peak is the one number
that could reopen it, and it stays owed.

## D-073 — the cushion learns the conversation, not a constant (Milestone 4m)

**Date:** 2026-08-25 · **Decided by:** Ryad · **Ruling: the §48 fork = A —
learn the reply length from the margins already arriving** (the WINDOW fork,
SPEC §130 F-1, is ruled in the dated addition below)

§48 convicted the input, not the formula: `deficit(length, RTF)` is right,
and it was being fed a 6-second nominal while Ryad's mind answered at
twenty. The ear heard exactly that — *"the weirdness or let us say slow
still there"* — after the cushion was set back to derived, which is what
cleared the earlier, wrong explanation (§46) and left this one.

**Ruled: A.** `AdaptiveLead` learns the typical reply length from
`DecodeMargin.audioMilliseconds` — the number it already receives and has
been discarding — and sizes the cushion from that and the latest RTF.
The cushion grows only when this mind, on this phone, actually talks long.

*Rejected:* **B, raise the nominal to ~15 s** — one line, and it taxes
every reply: ~900 ms banked instead of 360 at the measured RTF, over half
a second of added silence before every answer including "yes". The felt
pause is the product; B spends it on replies that never come.
*Rejected:* **C, keep replies short** — offered both alone and as free
seasoning on top of A, and not taken. Recorded as offered: it remains an
honest app-level policy someone may still choose, but no system-prompt
change rides into 4m on this ruling.

**The cost, named:** after a stretch of long replies the felt pause
before the next reply grows — the price of not running dry, now paid
proportionally instead of never. AC-168 makes Ryad hear that price and
rule on it with his own ears before the milestone closes.

### The window, ruled with the spec sign-off (same day)

**F-1 = A: the mean of the last four reply lengths.** Four adapts within a
few turns and dilutes one outlier fourfold; the mean rather than the median
because the outlier IS the signal this fix exists for. *Rejected:* **B,
latest length only** — whipsaws; a "yes" right before a long answer
re-creates §48 on the very next reply. *Rejected:* **C, session maximum** —
one long monologue would tax every later "yes" until the decoder changes.

## D-074 — cold is a button, not a 3.3-gigabyte penance (Milestone 4n)

**Date:** 2026-08-25 · **Decided by:** Ryad · **Ruling: the cold-compile
fork = B — an in-app control clears CoreML's compiled-plan cache**

AC-139's warm half is measured: trough 994 MB free, ≈112 MB transient,
≈47 MB settled, under three seconds — safe by a gigabyte beside the
resident 2.2 GB mind. The kills on record and the vendor's 1.7B
restriction both speak about the COLD compile, and the only way to reach
cold today is deleting the app.

**Ruled: B.** A Bench control clears the compiled-plan cache so a cold
compile is one tap away, repeatable forever, on the phone that owns the
number.

*Rejected:* **A, delete and reinstall** — a true cold state at the price
of re-downloading ~3.3 GB (the voice AND the mind live in Documents),
paid again for every future cold measurement.
*Rejected:* **C, accept the warm number** — it leaves AC-139's real
question unanswered and the 1.7B door permanently un-testable, ruled by
a vendor comment this project could never check.

**The cost, named:** the control deletes a cache the OS manages; the
next voice load after any clear pays the full compile (tens of seconds,
§30 measured 64) even when nobody wanted a measurement. The control is
an instrument and must look like one, not like a setting.

### The shape of cold, ruled with the 4n sign-off (same day)

**F-1 = B: the one-tap cold probe.** One control clears the compiled-plan
cache, retires the in-process voice, builds a fresh one, and runs the
probe — the four-step manual dance that produced a null run on its first
attempt becomes a procedure that cannot be done wrong. *Rejected:* **A,
clear-only** — cheaper, but it keeps the dance, and the dance is the
proven failure. Cost accepted: the tap briefly stops any conversation,
and the control refuses while listening.

## D-075 — the cold hunt moves to tmp/, and an empty tmp/ ends it (Milestone 4n follow-up)

**Date:** 2026-08-26 · **Decided by:** Ryad · **Ruling: AC-172's route
= A — the cache survey extends to the app's tmp/; if tmp/ holds no
cache either, the ruling falls through to C without a new fork**

The evidence that forced this ruling: the ❄'s first surviving report
(§52) proved the compiled-plan cache is NOT in the app's Caches on
iOS — the neighbourhood line named what Caches actually holds
(com.apple.dyld entries, speech, the bundle id, huggingface) and no
e5rt, CoreML, or mlcompiler directory among them. On the Mac the same
cache lives at USER level, `~/Library/Caches/com.apple.e5rt.e5bundlecache`
— outside any app container. The working hypothesis, still a
hypothesis: on iOS the compile cache belongs to a system daemon no app
directory reaches.

**Ruled: A.** The app's container has one cache-plausible directory the
survey has never looked at — `tmp/`. One more surveyed directory is
cheap, the report already names neighbourhoods, and D-074's control
gains reach without changing shape. An empty tmp/ is then EVIDENCE,
not a shrug: the fall-through to C is part of this ruling, so absence
does not open a new fork — cold is accepted as system-owned, §30's
64.8 s stands as the recorded cold number, and AC-172 closes with the
honest line that the app cannot reproduce cold on demand.

*Rejected:* **B — delete and re-download the voice (1.1 GB)** — pays a
gigabyte of download per measurement, and may STILL come back warm: if
the system cache is content-keyed, the re-downloaded bytes are the same
bytes, the same key, the same compiled plan.
*Rejected:* **C alone, accepted immediately** — surrenders while one
unsurveyed directory remains. C may well be the destination; ruling it
before tmp/ is surveyed would rest it on absence nobody looked for.

**The cost, named:** the control now deletes inside a directory the OS
also uses for its own staging. The writ stays narrow — only the three
known prefixes are ever touched, everything else in tmp/ is surveyed by
name and left alone — but a prefix list that overmatched would now
overmatch in two places instead of one.

## D-076 — the cold-start pair ships with the cold-route PR, on Ryad's own review (Milestone 4n follow-up)

**Date:** 2026-08-26 · **Decided by:** Ryad · **Ruling: keep together —
the turn-1 cold-start commits (4074d0c, 7420730) merge in the same PR
as the D-075 work**

While the D-075 session waited on its verification jobs, two commits
landed on the branch from outside it: an iOS session-start fallback for
the voice's lead (phone RTF constants 1.30/1.33, from §22's measured
1.21× and §41's 1.33×) and a WhisperEngine.prewarm() that pays the ANE
compile off-turn. Ryad ruled they ship now: **"i already reviewed and
tested. the work is good."** That review-and-test is the D-041 gate for
these commits, closed by the person the rule belongs to.

*Rejected:* **splitting the streams** (the session's recommendation —
a clean D-075-only PR, with the cold-start pair waiting for its own
review and the §50 field evidence). Ryad's review had already happened;
a split would have manufactured ceremony around work he had personally
verified.

**Recorded with the ruling, so the record stays whole:**
- §50's suspect list stays OPEN. The pair mitigates the starvation
  suspect; it does not convict it — turn 2's "Rome." is sub-second and
  starvation cannot explain it. AC-173's margin-per-turn logging is the
  instrument that still decides, and it logs the cushion in force, so
  the next conversation log stays readable evidence either way.
- The new prewarm is a fourth instance of the lazy-init class D-051's
  accepted notes hold open (feed · openUtterance · mind-prewarm · now
  ear-prewarm). The class-level cure remains an open fork.
- The prewarm conformance test self-skips where no model is installed,
  so CI exercises the guard path only — hardware-gated like the rest of
  the engine suite, said here rather than discovered later.

## D-077 — 1.7B is better, and it stays on the Mac (Milestone 4l, AC-163)

**Date:** 2026-08-27 · **Decided by:** Ryad · **Ruling: A — record the
verdict, keep 0.6B everywhere, and log 1.7B as a macOS-only quality
ceiling this project measured but cannot ship**

AC-163 asked the ear to rule, and warned in advance that the honest
outcome might be "better, and unreachable on the device that matters."
It is exactly that.

**What the measurement said** (this Mac, release, `bakeoff voice-levers`
and `voice-wer`, both models on the same sentences):

| | 0.6B | 1.7B |
|---|---|---|
| WER, fused | 0.067 (worst 0.400) | **0.022 (worst 0.200)** |
| steady RTF, fused | 0.757 | 0.992 |
| audio for the same sentence | 6.5–12.8 s | 4.1–8.6 s |

1.7B is **three times more accurate on fused** and says the same words
in far less audio — 0.6B drags and wanders, which is the same trait
behind the laugh 4e recorded. The cost is 1.1–1.3× more decode time per
second of audio across all six configs.

**What the ear said:** both models sound good and fluent on this Mac.
The quality gap the numbers report is not one Ryad's ear rejects either
way — so the ruling does not rest on 0.6B sounding bad.

**Ruled: A.** 0.6B stays the shipped voice on every platform. 1.7B is
recorded as a measured ceiling, reachable only on macOS.

*Rejected:* **B, make 1.7B the Mac's default** — it would split the
product in two: the Mac would ship a voice the phone can never run, so
every future voice measurement would need saying twice, and the demo a
reader runs on a Mac would stop being evidence about the phone.
*Rejected:* **C** — no ear finding contradicted the numbers.

**The cost, named:** `supportsVoiceDirection` is true only for 1.7B, so
style instructions stay unreachable, and this ruling makes that OUR
choice as well as the vendor's — the same door D-072 F-4 closed, now
closed with the quality evidence that was missing then.

**D-072's F-4 prediction, now measured rather than argued.** That
ruling refused the compute-units lever by predicting 1.7B could not
hold real time on the phone. The phone runs 0.6B at 1.05–1.37; 1.7B
costs 1.1–1.3× more, which puts it at roughly 1.4–1.8 there. Real time
gone by a margin no cushion can bank — exactly as written, now with
numbers behind it.

## D-078 — the four organs finally share one contract for their weights (refactor, step 1)

**Date:** 2026-08-27 · **Decided by:** Ryad · **Rulings: the seam gap =
B (one `ModelBacked` protocol, adopted by all four organs) · its shape =
B1 (the protocol returns nothing; the mind keeps its value-returning
method under a second name)**

### How a linter found a design hole

SwiftLint, added the same day, flagged four `force_cast` violations in
`AudioDemo`. The code behind them:

```swift
case "apple": await (engine as! AppleSpeechEngine).modelInstalled()
default:      await (engine as! WhisperEngine).modelInstalled()
```

A force cast chosen by a **string**, against an object constructed
somewhere else. If the two ever disagreed the app would not degrade — it
would crash. But the cast was the symptom. The cause: `modelInstalled()`
and `ensureModel()` were declared on FOUR types — `AppleSpeechEngine`,
`WhisperEngine`, `LocalMindModel`, `NeuralVoice` — and on **no protocol
at all**. A caller holding `any TranscriptionEngine` could not ask either
question, so it reached for the only tool left.

**Ruled: B.** One protocol, `ModelBacked`, adopted by all four. It states
the doctrine `WhisperEngine` already followed and nobody could depend on:
asking is free and never downloads · fetching is explicit and idempotent
· "installed" means offline-capable.

*Rejected:* **A, add the pair to `TranscriptionEngine` only** — kills the
cast, and leaves the mind and the mouth duplicating the same two methods
with no contract. It fixes the instance and not the class, which is the
fault D-051's open note already names three times over.
*Rejected:* **C, work around it in the CLI** — hides a missing seam
behind a local switch, and the next caller rediscovers the hole.

### F-1 — what `ensureModel()` returns (ruled B1)

Three organs return `Void`; `LocalMindModel.ensureModel()` returned its
loaded `ModelContainer` so a caller could run the model.

**Ruled: B1 — the protocol returns nothing.** "Make sure the weights are
on disk" and "give me the loaded thing" are two jobs. The conformance is
one line calling the other method, now named `ensureModelLoaded()`.

*Rejected:* **B2, an `associatedtype Loaded`** — more faithful to the
four shapes, and it makes `any ModelBacked` nearly unusable, which is
precisely the caller this protocol exists to serve. A protocol that
cannot be held existentially would not have removed a single cast.

**The cost, named:** `LocalMindModel` now has two methods one letter
apart in meaning, and a reader must notice which one hands back the
container. The alternative was an existential nobody could hold.

**What this does NOT fix:** the lazy-init class D-051's accepted note
keeps open (`feed`, `openUtterance`, two `prewarm`s). `ModelBacked` is
about weights on disk, not about who loads them when. That fork stays
open and is now the older of the two.

## D-079 — the app stops the mind before iOS kills the app (crash fix)

**Date:** 2026-08-27 · **Decided by:** Ryad · **Ruling: A — the guard
lives in the app, not in the library**

### The crash, from Ryad's phone

```
IOGPUMetalError: Insufficient Permission (to submit GPU work from
background) (00000006:kIOGPUCommandBufferCallbackErrorBackground
ExecutionNotPermitted)
libc++abi: terminating due to uncaught exception of type
std::runtime_error: [METAL] Command buffer execution failed
```

iOS forbids GPU work from the background. The app left the foreground
while the LOCAL mind was generating, Metal refused the command buffer,
and MLX threw a **C++** `std::runtime_error`. A C++ exception crossing
into Swift cannot be caught — the `do/catch` already wrapped around
`MLXReplyRun`'s token loop never sees it — so `libc++abi` terminates the
process. Not a glitch: a kill.

Ruled out before it was tried: `beginBackgroundTask` buys CPU time and
never GPU time. The restriction is on the hardware, not the clock. **The
only cure is to not be generating when we go.**

**Ruled: A.** `TranscribeModel` observes `willResignActiveNotification`
and takes the same two steps an audio interruption already takes — the
live turn dies honestly, the words already spoken are kept.

*Rejected:* **B, guard inside `MLXReplyGenerator`** — the session's own
recommendation, and it is the better engineering: the landmine is in the
library, so every future caller inherits the crash. Ryad ruled otherwise
and the reason is scope — `MultiModalKitMLX` today knows about weights
and tokens and nothing about app lifecycle, and this project's own rule
is that the app owns the platform (D-042 F-1, D-044). **The cost is
named: the library still crashes for anyone else who backgrounds it
mid-generation, and that is now a known, recorded hazard rather than an
unknown one.**
*Rejected:* **C, both** — the library half is what makes C differ from
A, and A's ruling is precisely that the library half does not happen.

### Two implementation notes, both costs rather than cleverness

**`willResignActive`, not `didEnterBackground`.** The later notification
fires when the app is ALREADY in the background — too late if a command
buffer is in flight. The earlier one always precedes it. The price:
pulling down Control Centre or taking a call also stops the reply. A
stopped reply is an annoyance a tap recovers from; a killed process is
not.

**The honest limit.** Cancellation is cooperative. The token loop checks
between tokens, so this wins the race only when MLX is between command
buffers as the notification lands. It makes the crash rare; it cannot
make it impossible, and no app-side fix can. **Unverified on hardware:**
the fix is reasoned from the crash log and compiles, but nobody has yet
backgrounded the phone mid-reply to watch it hold.

### What needs no guard

The ear and the mouth run on the ANE through CoreML, which the background
does not forbid. Only the MLX mind touches Metal.

## D-080 — the cushion stops averaging, because the drought comes in bursts (Milestone 4o)

**Date:** 2026-08-27 · **Decided by:** Ryad · **Ruling: B — size the
cushion from the WORST observed stall, not from the mean rate**

### The rule this retires, and the measurement that retired it

`PlaybackLead`'s formula — **`deficit = replyLength × (RTF − 1)`** —
comes from D-046 and was inherited unchanged by 4m's learned cushion
(D-073). It is not predictive of the silence it exists to prevent.

Fed this Mac's honest measurement for the phone's own configuration
(steady RTF 1.114), against condition D's 800 ms bank (INSTRUMENTS §53):

| file | audio | the rule asks | it predicts | silence MEASURED |
|---|---|---|---|---|
| s2-stepped-draw3 | 6043 ms | 689 ms | **none — "safe"** | **394 ms** |
| s3-stepped-draw1 | 11515 ms | 1313 ms | 513 ms | 1674 ms |

Pooled: **1248 ms predicted uncovered against 5593 ms measured — under
by 4.5×** — and on one file the rule calls a reply covered while its
audio breaks. No constant inside the measured range repairs it: covering
the worst file needs RTF ≈ 1.22, outside the 1.053–1.120 ever observed.

**The defect is the rule's FORM.** The decoder does not run uniformly
1.114× slow. It STALLS, and a stall drains a bank that the average says
is deep enough. A mean cannot size a burst.

**Ruled: B.** Measure per-step decode timing, track the worst lag seen,
and size the bank from that. It fixes the CLASS: a rule that works on any
device, rather than a number that works on one.

*Rejected:* **A, measure the cushion instead of deriving it** — sweep the
lead on the Mac, take the smallest value with zero digital silence.
Gives a correct number today using the laboratory §53 just built, and
becomes a table per device and per configuration rather than a rule; it
also cannot adapt to a long reply mid-conversation. **Kept as 4o's
verification method, which is the half of A that is worth having.**
*Rejected:* **C, stop sizing and rebuffer** — never let the buffer fall
below a floor, and pause at a phrase boundary when it does, the way
video rebuffers. It converts thirteen mid-word gaps into one honest
pause, which may yet be the better PRODUCT. Rejected as the fix because
it hides the fault rather than removing it, and because it introduces a
new audible failure while the old one is still unexplained.

### What survives, and it matters

`keepsUp` — `steadyRealTimeFactor < 1.0` — was **correct for every
condition measured**: A, C and F never starved, D and B did. Steady RTF
remains a sound keeps-up/does-not-keep-up FLAG. Only its use as a sizing
formula is retired.

### The cost, named

Per-step timing does not exist today: `DecodeMargin` carries whole-run
numbers only (audio, wall, prefill, steady RTF). So 4o must build the
instrument before it can build the cure, and the first reply of a session
still has no history to learn from — the same hole 4m left open, now
inherited by its successor.

## D-081 — two review findings on a merged branch, fixed forward (PR #29 follow-up)

**Date:** 2026-08-27 · **Decided by:** Ryad (fix both) · these are
CORRECTIONS, not new design

The adversarial review of PR #29 finished after Ryad had already merged
it. It confirmed two MAJOR defects, both on `main`. Recorded here rather
than quietly patched, because both are faults this project's own rules
were supposed to prevent.

### 1. A behaviour change inside a commit that claimed none

`ab6bd92` — "ModelBacked: one contract for the four organs' weights" —
also deleted **`Answer in ONE short sentence. `** from the LOCAL mind's
instructions. Nothing in that commit's message mentions a prompt, and no
lint rule touched it: the deleted text sat on a 78-character line with no
length limit configured, and the byte-identical sentence on the Apple
mind survived the same commit.

Three consequences, and the third is the expensive one:

1. The two minds were given different prompts while the doc comment
   above still claimed "the same sentence the Apple mind gets".
2. The 4B model was free to answer in paragraphs, which changes reply
   length — and reply length is what 4m's cushion learns from.
3. `bakeoff ask`'s comment says its prompt is "WORD FOR WORD the demo's
   text … a field report cannot be chased with a different prompt than
   the one that produced it." Since `ab6bd92` that was false. **Every
   Mac measurement of the local mind was taken against a prompt the
   phone no longer ran.**

Restored. **The lesson, which is the reason this entry exists:** a
"mechanical" commit is exactly where a behaviour change hides, because
nobody is reading it for behaviour. The review found it by set-diffing
string literals between the old and new files — a check worth repeating
whenever a big file is split.

### 2. D-079's guard was armed everywhere except where it was needed

`observeForegroundLoss()` was registered inside `start()` and removed in
`stop()`, and its handler opened with `guard isListening`. But the MLX
mind runs Metal work during **launch**: `refreshMind()` prewarms it
seconds before anyone can tap Listen. Backgrounding in that window
reached the identical crash D-079 was written to prevent, through the one
path the fix did not watch.

Fixed in three places:

- **Armed at launch**, first in `RootView`'s sequence — before anything
  can touch the GPU — and no longer torn down by `stop()`, because the
  observer must outlive any single conversation.
- **`guard isListening` removed** from the handler. The mind can be on
  the GPU with no conversation at all.
- **The mind is retired**, not merely interrupted: `retire()` cancels the
  warm-up AND releases 2.2 GB to a system that is about to judge this
  app's footprint.

**The cost, named:** a retired mind is cold, so the first reply after
returning pays the load again. `rewarmMind()` on
`didBecomeActiveNotification` is the symmetric half — the warm-up starts
while the person is still looking at the screen. **The honest limit is
unchanged:** cancellation is cooperative, so this wins the race only when
MLX is between command buffers, and it remains **unverified on
hardware**.

## D-082 — Kokoro is measured before it is believed (Milestone 4p)

**Date:** 2026-09-01 · **Decided by:** Ryad · **Rulings: the candidate =
A (spike it behind the existing seam and measure) · F-1 = A (the adapter
lives inside `MultiModalKitTTS`; `TTSDecoding` stays internal) · F-2 =
`mlalma/kokoro-ios`**

### The number that opened the question

The iPhone's neural RTF is **1.21**. Every cushion this project owns —
D-046's rule, D-073's learner, D-080's stall statistic — exists to paper
over a decoder that speaks slower than speech. §143a is open because none
of them scale with reply length. A decoder with RTF below 1.0 does not
make the cushion smaller; it makes it unnecessary.

Kokoro-82M is a StyleTTS 2 + ISTFTNet model of 82 M parameters, roughly
seven times smaller than the 0.6B Qwen3 variant this app ships, and its
Swift port claims ~3.3× faster than real time on an iPhone 13 Pro.

**That claim is a README's.** The standing rule — audio graphs are
MEASURED, harness before belief — is why this is a spike and not a swap.

### Options

**A. Spike it behind `TTSDecoding` and measure. — RULED.** D-053 F-6
built that seam so a second decoder would cost an adapter, not a rewrite.
This is the first time the seam is asked to pay for itself.

*Rejected: B, park it until the walkthrough finishes.* Defensible — the
walkthrough is teaching Ryad the pipeline he must own — but the cushion
work owed after 4o (re-running the sweep, rewriting §54) is work that a
sub-1.0 RTF could make pointless. Measuring first prices that risk.

*Rejected: C, adopt it now.* Fast and indefensible: it swaps the mouth on
a vendor's README. The exact failure this project's instrument discipline
exists to prevent.

### F-1 — the adapter lives inside `MultiModalKitTTS`

`TTSDecoding` is **internal**, so this was never a matter of taste: a
separate target could not conform to it without making the seam public.

*Rejected: a new `MultiModalKitKokoro` target.* It is the cleaner end
state, and it would force `TTSDecoding` public today. D-017's rule is
that public surface is earned by a second **kept** implementation, and a
spike is not kept until it survives its own numbers. **The cost of A,
named:** anyone linking the mouth now pulls both vendors. If 4p ends in
adoption, the split becomes the adoption PR's own ruling.

### F-2 — `mlalma/kokoro-ios`

Its G2P is self-contained (MisakiSwift), so eSpeak NG — GPL, and
therefore poison for a public repo someone might link — stays out. Its
performance claim is the only one of the three made on an iPhone.

*Rejected:* `mattmireles/kokoro-coreml` (Apple Neural Engine, but its
numbers are Mac Studio ones) and `mweinbach/kokoro-swift` (both backends,
more surface than a spike needs). Either may return if this one measures
badly — as a new entry, never as a silent switch.

### The four dependency questions, answered

This is an **optional-module** dependency: it enters `MultiModalKitTTS`
beside TTSKit. The core `MultiModalKit` keeps zero runtime dependencies,
which the tiered policy (2026-08-09) allows no exception to.

1. **Not the point of the project?** Correct. This project is about the
   coordination pipeline — the ring, the pump, the tickets, the cushion.
   Inventing a TTS model is not in it. Same reasoning that admitted
   WhisperKit and TTSKit.
2. **Swift 6 clean?** **UNKNOWN, and it is an acceptance gate.** The
   package states iOS 18 / macOS 15. Nothing here may claim it builds
   warning-free until it has.
3. **Permissive licence, maintained?** MIT, and its G2P Apache-2.0 — both
   verified on 2026-09-01. **Maintained is the weak half:** it is a young
   single-maintainer package, not a vendor SDK like argmax's. Recorded as
   a risk, not waved away.
4. **Could we remove it in a day?** Yes, and the count is the answer: one
   adapter file, one instrument file, one `Package.swift` edit. Nothing
   else in the repo may name the vendor — the same rule `TTSKitDecoder`
   already lives under.

### What this decision does NOT decide

Whether Kokoro speaks in this app. That is AC-189, and it is a HALT after
the numbers exist — adopt, keep Qwen3, or ship both.

## D-083 — the spike moves outside the package, because the graph refused it (Milestone 4p)

**Date:** 2026-09-01 · **Decided by:** Ryad · **Ruling: B — measure Kokoro
in a separate project first; fork nothing**

D-082 ruled F-1 = A on a fact set that did not include this one. The pins
were read only when the dependency was actually added, and they do not fit.

### What was measured, not guessed

```
error: root depends on 'mlx-swift-lm' 3.0.0..<4.0.0 and root depends on 'mlx-swift' 0.30.2.
'mlx-swift-lm' >= 3.0.0 practically depends on 'mlx-swift' 0.31.3..<0.32.0
```

- `kokoro-ios` 1.0.11 → `mlx-swift` **exactly 0.30.2**
- `MisakiSwift` (the G2P alone) → `mlx-swift` **exactly 0.30.2**
- `mlx-swift-lm` ≥ 3.0.0, which the Qwen mind needs → **0.31.3..<0.32.0**

No overlap, and no partial route: even taking the G2P by itself drags the
same pin. **The mind and this mouth cannot share one package graph.**

The escape routes were checked and are worse. `adriancmurray/kokoro-ios`
relaxes the pins but has **no tags at all**. `mweinbach/kokoro-swift`
would resolve (it pins 0.31.3) but has **no licence file**, which ends it
for a public repository whatever it measures. `mattmireles/kokoro-coreml`
is a Python conversion pipeline, not a Swift package.

### Options

**B. Measure outside the package first. — RULED.** `Spikes/KokoroSpike`
is its own Xcode project with its own SPM graph. It links the vendor
untouched, at the vendor's own pin, and answers 4p's only question
without a fork. If the number is good, forking three repositories becomes
a decision made with eyes open.

*Rejected: A, fork the trio and relax the pins now.* Three forks to
maintain, and an unknown — whether their code survives MLX 0.30 → 0.31 —
paid for before a single measurement exists. Chasing a README's number by
forking is the same error as adopting on a README's number, only slower.

*Rejected: C, stop 4p here.* Defensible and cheap, but the question is
worth one day: the cushion work still owed after 4o could be made
pointless by a decoder with RTF below 1.0.

### What this costs, named

The spike does **not** exercise this library's audio graph, its phraser,
its lead, or its barge-in. It measures a decoder and nothing else. So a
good number here is permission to integrate, never proof that integration
will behave — AC-183 (digital silence) and AC-184 (WER) stay unanswered
until the mouth is inside a real pipeline.

D-082's F-1 ruling is **not edited**. It was right on what was known; this
entry is what changed.

## D-084 — the mouth changes: Kokoro fp16 becomes the default (Milestone 4p, AC-189)

**Date:** 2026-09-02 · **Decided by:** Ryad · **Ruling: A — adopt
Kokoro-82M at fp16 as the default mouth; Qwen3-TTS stays as an
alternative behind the existing lever**

### The evidence, and what makes it trustworthy

INSTRUMENTS §55, measured on Ryad's iPhone with both mouths in ONE
process, ONE stopwatch and ONE memory sampler:

| | median RTF | peak at a 2.7 s sentence |
|---|---|---|
| Kokoro-82M fp16 | **0.20** | 667 MB |
| Qwen3-TTS 0.6B | 1.35 | 598 MB |

**About six times faster, for about seventy megabytes.**

Two properties of that measurement matter more than the ratio:

- **The harness did not flatter the challenger.** Qwen measured WORSE here
  (1.35) than in the live app (1.21), and it ran second on a phone Kokoro
  had already warmed. Every plausible correction moves the gap the wrong
  way for Kokoro and it still wins by ~6×.
- **The ear agrees, on the exact configuration being adopted.** Ryad on
  fp16: *"fp16 sound the same, i cant hear a difference."* Half precision
  is not a compromise taken on a number alone.

The decisive fact behind the ratio: **the two decoders fail in opposite
directions.** Kokoro's time is bounded and its memory is not; Qwen's
memory is bounded and its time is not. Every cushion this project owns —
D-046, D-073, D-080 — exists because Qwen's RTF is above 1.0. A decoder at
0.20 does not make that apparatus smaller; it removes its reason to exist.

### Options

**A. Adopt Kokoro fp16 as the default. — RULED.**

*Rejected: B, keep Qwen and shelve Kokoro.* No forks, no new
dependencies, no risk — and the cushion apparatus stays load-bearing
forever with §143a permanently open. It was defensible on surface area
alone; it is not defensible against a 6× measured on the machine that
reported the fault.

*Rejected: C, defer the ruling.* Costs nothing except that a spike goes
cold and has to be rebuilt to answer the same question again.

### The price, named before it is paid

1. **Three forks, or a vendored copy.** `kokoro-ios`, `MisakiSwift` and
   `MLXUtilsLibrary` all pin `mlx-swift` to exactly 0.30.2, which the
   Qwen MIND cannot use (D-083). Both routes are permitted by the
   licences (MIT / Apache-2.0). **Which one is a ruling of its own, in
   the integration milestone** — it is not decided here.
2. **A one-shot decode cannot be stopped in flight** (AC-181, already
   tested). Barge-in stays correct — the ticket is the guarantee — but
   the compute is not saved. The cost is bounded by the phrase length,
   which makes point 3 do double duty.
3. **Memory grows with phrase length**, ~120 MB per second of audio on
   top of ~336 MB fixed. Integration MUST cap phrase length. The phraser
   already cuts at sentences, so this is a bound to state and enforce,
   not a mechanism to invent.
4. **A worse cold start.** ~9–11 s for the first decode in a process
   against Qwen's ~5.9 s — Metal kernel compilation, once. It lands
   exactly on §143a's first-reply hole, and 4p could not measure it
   cleanly (§55 records why: the fp16 warm-up inherited fp32's compiled
   kernels).
5. **English only, in practice.** Kokoro ships 54 voices across 8
   languages, but the Swift port's G2P is `MisakiSwift`, English. This
   project is English-only today; the day it is not, this is where the
   cost appears.

### What this ruling does NOT do

- **It does not delete the cushion.** `PlaybackLead`, `AdaptiveLead` and
  D-080's stall statistic stay exactly as they are until Kokoro's RTF is
  confirmed below 1.0 *inside this library's pipeline*. Removing them on
  a bare-harness number would be the same mistake as adopting on a
  README's.
- **It does not make Kokoro proven.** §55 exercised no phraser, no
  `PlaybackLead`, no barge-in, no microphone. AC-183 (digital silence)
  and AC-184 (WER) are still unanswered and are the integration
  milestone's first job (SPEC §148a).
- **It does not retire Qwen.** It stays behind `VoiceLevers`, which is
  what that lever is for, and it remains the only mouth this project has
  ever run in a real conversation.

## D-085 — the cold start is paid at launch, not in the first reply (Milestone 4q)

**Date:** 2026-09-03 · **Decided by:** Ryad · **Ruling: B — warm the
Kokoro decoder at `ensureModel()` with one short, discarded phrase**

### The number this waited for

§143a has been open since 4o: the first reply of a session has no history
to learn from. For Kokoro the question became measurable once
`KokoroColdStart` existed. On Ryad's phone, two fresh launches:

```
  first reply, first phrase (prefill):  1343 ms · 1403 ms
  every phrase after:                   0.18× · 0.21×
```

So the cold penalty is roughly **a second, once per process**, and it is
two things at once: MLX reading the weights it had only mapped, and
Metal compiling the kernels the first time they run.

**A number that was true and misleading:** `load 84 ms`. MLX is lazy —
its own source says arrays "are not fully realized until they are
evaluated" — so that was the cost of MAPPING 164 MB, not reading it.
The parity fix that moved the load call to launch had not moved the load
cost. The screen now says "map".

### Options

**B. Warm at launch with a tiny decode. — RULED.** One short phrase,
decoded during the demo's "preparing" step and thrown away. Pays weights
and kernels while the person is looking at the screen. It is also the
only option that makes the launch-time number honest.

*Rejected: A, leave it.* A one-second late first reply, once, is far
less than Qwen's first reply ever cost. Defensible, and it leaves §143a's
hole exactly where it was.

*Rejected: C, force-evaluate the weights only.* Moves the read, not the
compile — half the win, none of B's risk. Kept in mind if B's risk
materialises.

### The price, named

1. **GPU work at launch is D-079's window.** The background guard is
   armed first at launch (D-081) and `retireVoiceIfOnGPU()` retires the
   voice on backgrounding — but Kokoro's decode is one-shot (AC-181), so
   a retire that lands during the warm-up cannot stop it, only outlive
   it. The exposure is one short phrase wide. D-079's own limit applies
   unchanged: cooperative cancellation, unverified on hardware.
2. **A memory burst beside a 2.2 GB mind.** The first in-situ log showed
   884 MB of headroom at start and §55 measured ~120 MB per second of
   audio, so the phrase is SHORT — "Ready to talk.", about a second —
   rather than the 2.7-second fixture.
3. **The bet inside the phrase.** MLX kernels are specialised per
   operation and type, not per sequence length, so a short phrase should
   compile what a long one needs. If the first real reply is still slow
   after the warm-up, that bet lost — and `KokoroColdStart.first` is the
   line that says so.

### What this does NOT close

§143a is about the CUSHION not scaling with reply length, for a decoder
slower than speech. Kokoro is not that decoder; for it the hole was the
cold start, and this ruling fills it. §143a stays open for the Qwen
mouth, which D-084 keeps behind the lever.

## D-086 — the demo asks the kernel for more memory (Milestone 4q)

**Date:** 2026-09-03 · **Decided by:** Ryad · **Ruling: add
`com.apple.developer.kernel.increased-memory-limit` to the demo**

### The number that asked for it

With the local 4B mind and the Kokoro mouth both resident, the phone
reported **884 MB of headroom** before the app's limit (INSTRUMENTS §56).
Alive, and tight enough that D-085's warm-up phrase was cut to one second
and the mouth's phrase cap to 60 characters on memory grounds alone.

### What the entitlement does, and does not

It asks the kernel for a higher per-process limit than an app gets by
default, on devices that grant one. It is the standard enabler for
on-device language models and it costs one file.

It **raises the ceiling and shrinks nothing.** The mind is still 2.2 GB,
the mouth still costs ~120 MB per second of audio (§55), and the cache
cap (D-079's family) still matters. How far the ceiling moves is
device-dependent and is not written here as a number: the app already
prints its headroom, and that line on the same phone, before and after,
is the measurement. 884 MB is the "before".

**Measured the same day, same phone — and corrected once:** the first
"after" reported was 5,830 MB, read before the mind had loaded. Like
for like, at the same ~2.3 GB of MLX memory, headroom went from
**884 MB to 3,580 MB**. About 4×, and the limit itself from roughly
3.2 GB to roughly 5.9 GB. The two
rulings sized against the 884 — the 60-character phrase cap and the
one-second warm-up phrase — now stand on a premise that has moved;
INSTRUMENTS §56 records it and this entry does not re-rule them.

*Rejected: leave the default limit and shrink the models.* A smaller mind
is a different product; a shorter phrase cap is already at the point
where prosody pays for it. Asking for the memory that is physically there
is the cheaper first move, and it is reversible in one line.

**The cost, named:** an app that may use more memory is an app the
system evicts others for. That is acceptable for a demo that exists to
measure; it is a product question the day it ships as one.

## D-087 — four rulings on the twelve-turn log (Milestone 4q)

**Date:** 2026-09-03 · **Decided by:** Ryad ("do your recommendation") ·
**Rulings: the phrase cap returns to 120 · the warm-up phrase stays at
one second · `prefill` gains a pure-decode stamp beside it (A) · a
one-step reply reports its margin**

### The log that asked for them

Twelve turns on Ryad's phone: local 4B mind, Whisper, shield on, Kokoro
speaking, thermal fair throughout. His verdict — natural, no echo, never
stopped answering, "a little bit more time between thinking and
speaking". The entitlement's like-for-like headroom: 884 → 3,580 MB.

### 1. The cap returns to 120

60 was never a taste; it was memory — sized against 884 MB with the mind
resident. At 3,580 MB a 120-character phrase's ~1.3 GB peak is not a
constraint, and every cut the 60 forced was a place prosody could break.
*Rejected: keep 60.* Defensible only on a phone without the entitlement,
and the cap is one parameter the day that phone appears.

### 2. The warm-up phrase stays at one second

Lengthening it would spend memory to answer a question the instrument
could not yet ask. The residual in the first phrase may be the mind's
token wait, not the decoder's compile — ruling 3 is what tells them
apart. *Rejected: the 2.7-second fixture.* Right lever, wrong moment;
it returns on evidence if ruling 3 shows the first phrase still slow.

### 3. `prefill` gains a pure-decode stamp — A

`prefill` is birth to the first step, and the run is born on the reply's
FIRST TOKEN, so it has always contained the wait for the rest of the
first phrase's tokens. The twelve-turn log made that visible at reply
scale: turn 12's 19.6 s of audio at "RTF 0.369" is 7.2 s of wall on 6.7 s
of the mind writing. The voice was pacing the mind.

A stamp at the `decode` call, one field beside `prefill`, and the
difference between them is the wait for text — now a number on the
screen. *Rejected: B, redefine `prefill`.* It would make AC-106's name
honest and break comparability with every prefill in §53–§56. *Rejected:
C, leave it.* Half a second of ambiguity in the cold-start verdict,
forever.

### 4. A one-step reply reports its margin

Six of the twelve turns had no `voice:` line, and every one was spoken —
"Rome.", "Berlin.", "Good morning to you too!". The margin was reported
only when audio existed AFTER the first step: always true for a
streaming decoder, never true for a one-shot decoder's single-phrase
reply. `steadyRealTimeFactor` is now optional and `keepsUp` falls back
to the whole-reply rate; the margin itself is always reported. *Rejected:
leave them invisible.* An instrument that cannot see short replies
cannot learn from them, and short replies are most of a conversation.
