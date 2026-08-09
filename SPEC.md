# SPEC — Phase 1: Audio Capture, Ring Buffer, VAD

> Status: **DRAFT — awaiting sign-off.** No code before this is approved.
> Simple-English rule applies to every document in this repo: short sentences,
> everyday words, technical terms explained once.

## 1. What Phase 1 builds

Real sound from the microphone travels through a lock-free ring buffer,
gets judged by a voice activity detector (VAD), and comes out as clean
utterance events behind a swappable provider seam. One demo shows it live in
the terminal; a deterministic test suite proves it without any real audio or
real time.

## 2. The one hard problem (the phase's reason to exist)

The real-time audio thread may **never wait** — no locks, no allocation, no
`await`. Swift concurrency lives in a different world. Phase 1 is about
crossing that boundary **exactly once**, safely, and being able to explain
every line of the crossing.

## 3. Acceptance criteria

### The ring buffer (the crown jewel)
- **AC-1** Fixed capacity, allocated once at startup. It never grows and
  never allocates afterwards.
- **AC-2** One writer, one reader (SPSC). The write path performs only:
  a bounds check, a memory copy, and two atomic counter moves. Nothing else.
- **AC-3** Counters are `Atomic<Int>` (Swift `Synchronization`), with
  acquire/release ordering: release says "the bytes are ready," acquire says
  "I saw that." Head and tail live on **separate cache lines** (padding), so
  the hot core and the cool core never fight over one line.
- **AC-4** Overflow policy: **overwrite oldest** (fresh speech beats stale
  audio). Every dropped frame is **counted** and the count is readable — the
  buffer may drop, but it may never lie.
- **AC-5** The buffer is a pure component: no clocks, no audio, no Swift
  concurrency inside. Testable by itself, exhaustively.

### The capture engine
- **AC-6** v1 uses `AVAudioEngine.installTap` (F1 ruling). The tap callback
  obeys the iron laws: copy into the ring, update counters, return. Nothing
  else — no logging, no allocation, no Swift runtime surprises.
- **AC-7** The capture engine is behind a protocol seam, so tests replace it
  with a scripted fake microphone. No test ever touches real audio hardware.
- **AC-8** Planned upgrade to `AVAudioSinkNode` is documented as a future
  step (not built in Phase 1).

### The pump (the one bridge)
- **AC-9** A single long-running structured task reads the ring on a polling
  rhythm (~10 ms) using an **injected Clock** (F5 ruling). All time flows
  through that clock — tests drive it by hand, deterministically.
- **AC-10** The pump is the only reader of the ring, and the only place where
  ring data enters Swift concurrency. One bridge, no side doors.

### VAD and events
- **AC-11** VAD v1 is energy-based: a loudness threshold plus a **hangover**
  (speech stays "on" through short gaps between words). Pure function of
  samples + config — no clocks, no state outside itself beyond the hangover
  counter.
- **AC-12** Output events: `speechStarted`, `audioSegment(samples)`,
  `speechEnded`. Delivered through a provider seam shaped like a streaming
  STT source, so a conductor can consume it later without changes.
- **AC-13** Latency instrumentation: instants captured at capture-time and at
  `speechStarted`, reported through an injectable reporter (the inline
  pattern; no wall clock in tests).

### Determinism and hygiene
- **AC-14** Every test runs on fake time and fake audio: same result, every
  run, any machine. No real sleeps, no polling loops in tests.
- **AC-15** Swift 6 strict concurrency, zero warnings, zero third-party
  dependencies. The only locks in the package: none. The only atomics: the
  ring's counters.
- **AC-16** Every started task in tests terminates: ledger-style accounting
  where teardown is involved; zero parked sleepers after each test.

## 4. Test matrix (first pass)

| Area | Tests |
|---|---|
| Ring buffer | write/read roundtrip · wraparound correctness · overwrite-oldest with exact dropped-frame counts · stress: fast fake writer vs slow reader · counter padding sanity |
| Fake microphone | scripted chunks arrive at scripted fake-time moments |
| Pump | polls on fake clock · drains ring in order · backpressure behavior observable |
| VAD | silence → nothing · loud frames → speechStarted · gap shorter than hangover → still speaking · gap longer → speechEnded · exact boundary cases |
| Events/seam | full scripted "utterance" produces the exact expected event sequence |
| Latency | scripted timings produce exact expected measurements |

## 5. Out of scope for Phase 1 (deliberately)

Real STT models (Phase 2) · os_signpost/thermal handling (Phase 3) ·
Metal / C++ interop (Phase 4) · any UI beyond the terminal demo ·
audio *output* (playback) · error/failure paths of real hardware beyond
"engine failed to start".

## 6. Definition of done

All ACs have passing deterministic tests · the terminal demo shows live
mic → VAD events on real hardware · README explains the thread map and the
iron laws in half a page · DECISIONS.md covers every fork · repo is public
with CI green.

---

# SPEC DELTA — Milestone 1c: the pump, the events, the latency

> Status: **DELIVERED 2026-08-08.** Approved 2026-08-05 (rulings A3/B3/C1/D1
> + Q1/Q2 → D-008…D-012; event semantics → D-013; the stop race → D-014).
> All of Phase 1 is now built: ring ✅, capture ✅, ManualClock ✅,
> EnergyVAD ✅, pump ✅, events ✅, live demo ✅ — 42 tests green, 20
> consecutive full runs with zero failures. AC-16 ("every started task
> terminates") is proven by the `sleeperCount == 0` assertions after `stop()`.
>
> Found and fixed while building this milestone: a rare read that could return
> a mix of old and in-flight frames (D-015). D-007's "only ONE value crosses
> the boundary" is corrected there, not edited away.
>
> **Open for a later phase (found in a live run, not yet ruled):** the 300 ms
> hangover is delivered as part of each utterance, so a short phrase is mostly
> trailing silence. Options for the fork: trim the tail before publishing, or
> keep it and let the consumer decide. Not ruled — recorded.

## 7. What 1c builds

The **pump**: one long-lived structured task that is the only reader of the
ring. Every ~10 ms of injected clock time it drains whatever the microphone
left there, cuts it into fixed-size chunks, asks the VAD about each chunk,
and publishes events to any number of listeners. Nothing else in the package
touches the ring, and nothing in the package reads a real clock.

## 8. Rulings applied (Ryad, 2026-08-05)

| Fork | Ruling | Entry |
|---|---|---|
| How events leave the pump | **A3** — multicast (`Broadcast`), many listeners | D-008 |
| What a segment contains | **B3** — chunk-by-chunk **plus pre-roll** | D-009 |
| How drops become visible | **C1** — a `dropped` event, in timeline order | D-010 |
| How time is known | **D1** — sample arithmetic, no clock inside | D-011 |

## 9. Acceptance criteria for 1c

### The pump
- **AC-9 (concrete)** The pump owns exactly one structured task. It sleeps on
  the **injected clock** for a configured poll interval (default 10 ms),
  wakes, drains, publishes, sleeps again. No real time anywhere.
- **AC-10 (concrete)** The pump is the **only** ring reader in the package.
  It is created with a consumer handle and never shares it.
- **AC-17** Chunking: drained frames are assembled into **fixed-size chunks**
  (default 20 ms of audio). A partial chunk is carried to the next poll, never
  padded and never judged. The VAD only ever sees full chunks.
- **AC-18** Shutdown: `stop()` ends the task, finishes every listener's
  stream, and leaves **zero** parked sleepers on the ManualClock — proven by a
  counting test (AC-16).

### The events
- **AC-12 (concrete)** One event type, delivered in strict timeline order:
  `speechStarted(at:)` · `audioSegment(chunk)` · `speechEnded(at:)` ·
  `dropped(frames:at:)`.
- **AC-19** Pre-roll (D-009): when speech starts, the pump first publishes the
  **last N chunks it already held** (default 2 = 40 ms), then continues
  chunk-by-chunk. The first syllable is never lost.
- **AC-20** Multicast (D-008): several listeners each receive the **same
  sequence**, independently. A slow listener can never block the pump and can
  never change what another listener sees.

### The time
- **AC-13 (concrete)** Every event carries an `AudioTime` derived only from
  **frames consumed ÷ sample rate** (D-011) — the audio's own time, not the
  scheduler's. Capture-to-`speechStarted` latency is therefore an exact number
  in tests, not a measurement.

## 10. Test matrix for 1c

| Area | Tests |
|---|---|
| Pump rhythm | wakes exactly once per poll interval on the ManualClock · drains everything available · carries a partial chunk to the next tick |
| Event sequence | scripted utterance → exact expected event array, in order |
| Pre-roll | speech starting mid-stream delivers the 2 chunks before it, in order, ahead of the first live chunk |
| Drops | slow drain against a fast fake microphone emits `dropped` with the **exact** frame count, at the right point in the sequence |
| Multicast | two listeners get identical sequences · a listener that stops reading does not stall the other · late-subscriber semantics (see Q2) |
| Shutdown | `stop()` finishes all streams, the task tree exits, `sleeperCount == 0` |
| Latency | scripted timings produce exact capture-to-`speechStarted` values, no wall clock |

## 11. Two questions the rulings left open — RULED (D-012)

**Q1 — the buffer policy per listener.** A3 means every listener has its own
buffer. A slow listener makes that buffer grow — which is exactly the
unbounded-buffer weakness found in the hiring-task `Broadcast`.
→ **Recommendation: bounded, drop-oldest, and honest.** A small fixed
capacity per listener (e.g. 64 events); on overflow, drop the oldest and raise
that listener's own `droppedEvents` counter. The pump never blocks, memory is
capped, and the loss is counted instead of hidden.

**Q2 — replay or no replay.** The hiring-task `Broadcast` replays the last
value, which is right for *state* ("you are speaking"). These are *events* —
moments in time. Replaying `speechStarted` to a listener that arrives ten
seconds late would be a lie.
→ **Recommendation: no replay for events.** A new listener gets what happens
from now on. If a UI later needs "am I speaking right now", that is a separate
state stream, and that one may replay.

---

# SPEC — Phase 2: speech becomes text, on the device

> Status: **APPROVED 2026-08-09.** Rulings: F1 = **B + D** (Apple's engine in
> the core, a Whisper-class engine as an optional product), F2–F7 as
> recommended, plus the tiered dependency policy — logged as D-016…D-020.
> Phase 1 is delivered: sound reaches Swift concurrency as clean utterance
> events. Phase 2 turns those utterances into words, still without a server.
>
> **First task: a spike.** `SpeechAnalyzer` is new; nothing is specified in
> code before the API has been run on this machine.

## 1. What Phase 2 builds

The demo already has a listener called `[recogniser]` that only counts. Phase 2
makes it real: a transcription session subscribes to the pump's events, opens
one recognition per utterance, feeds it the audio it already received —
pre-roll included — and publishes text as it arrives.

```
AudioPump ──events──►  TranscriptionSession ──transcript events──► listeners
                            │
                            ├─ opens ONE recognition per utterance
                            ├─ feeds chunks in order, exactly once
                            └─ a dead utterance can never publish
```

## 2. The one hard problem (this phase's reason to exist)

**A recognition is slow, and speech does not wait.** Text for utterance 3 can
arrive after utterance 4 has already begun. Cancelling the old recognition is
only a request — the engine may still deliver one last result. So the same law
as the barge-in work applies here: **cancellation is the optimisation, an
utterance ticket is the guarantee.** A result carrying a dead ticket is
dropped, provably, before anyone can see it.

The second hard part is honesty about failure: real engines fail — no
permission, no model downloaded, no network-free model available, audio format
refused, the system busy. Phase 1's mocks never failed. Phase 2's fake fails on
purpose.

## 3. Acceptance criteria

### The seam
- **AC-21** A `TranscriptionProvider` protocol is the only thing the session
  talks to. Tests use `ScriptedTranscriber`; the app uses the Apple engine.
  Swapping them changes no line of session code.
- **AC-22** The library **never** asks the user for permission and never opens
  a microphone. Authorisation belongs to the app; unavailability arrives as an
  event, not a crash.

### The session
- **AC-23** Exactly **one recognition per utterance**, opened on
  `speechStarted`, closed on `speechEnded`.
- **AC-24** Every chunk the pump published for that utterance is fed **once, in
  order, including the pre-roll** — the first syllable reaches the engine too.
- **AC-25** **The utterance ticket.** Each utterance gets a number that only
  goes up. Every result is checked against it in the same actor step that could
  raise it. A result from a finished or abandoned utterance is dropped and
  never published — proven by a test where a defiant transcriber answers late.
- **AC-26** Bounded by construction: audio is held only while its recognition
  is open, and an utterance longer than a configured maximum (default 30 s) is
  cut with an explicit `truncated` event. Nothing grows without a limit.

### The events
- **AC-27** Transcript events, in timeline order per utterance:
  `partial(text, utterance:at:)` · `final(text, utterance:at:)` ·
  `failed(reason, utterance:at:)` · `truncated(utterance:at:)`.
- **AC-28** Partials are monotonic inside one utterance (each replaces the
  previous), and a `final` ends that utterance. After `final`, that utterance
  publishes nothing, ever.
- **AC-29** Failure is an event, not an end: after `failed`, the session
  accepts the next utterance normally. One bad recognition never kills the run.
- **AC-30** Delivery reuses the Phase 1 `Broadcast`: many listeners, bounded
  buffers, drop-oldest, counted, no replay.

### Time and shutdown
- **AC-31** Latency is measured in **audio time** (D-011): capture →
  first partial, and capture → final, exact in tests.
- **AC-32** `stop()` finishes every transcript stream, ends any open
  recognition, leaves zero parked sleepers and no task behind (AC-16 rules
  still apply).

### Hygiene
- **AC-33** Swift 6 strict concurrency, zero warnings, CI green on every push.
  Dependencies follow the tiered policy (D-016): **the core library
  `MultiModalKit` keeps zero runtime dependencies**; optional engine modules,
  demo targets and tests may have them.
- **AC-35** Every engine declares an `EngineCapabilities` value —
  `emitsPartials`, `wantsWholeUtterance`, `requiredSampleRate`,
  `maximumUtterance` — so a streaming engine and a batch engine can live behind
  one protocol without the session guessing (D-017).
- **AC-36** An **engine conformance kit**: one shared test suite that every
  engine implementation must pass (one final per run, nothing after cancel,
  failures are events, ordering, capability honesty). Switching engines is
  proven by tests, not promised in a README.
- **AC-34** Test coverage is claimed **only** for our own code. Apple's engine
  is exercised by the demo on real hardware, and the README says so plainly —
  no test in this repo will pretend to verify Apple's model.

## 4. Test matrix (first pass)

| Area | Tests |
|---|---|
| Session boundaries | one recognition per utterance · pre-roll fed first · chunks fed once, in order |
| The ticket | defiant transcriber answers after `speechEnded` → nothing published · answers during the NEXT utterance → still nothing · the next utterance's own results are unaffected |
| Partials | partials replace each other · `final` closes the utterance · nothing after `final` |
| Failure | scripted failure → `failed` event → the next utterance still transcribes |
| Truncation | an utterance longer than the cap → `truncated`, audio released |
| Multicast | two listeners get identical transcript sequences |
| Latency | capture → first partial and capture → final are exact on the ManualClock |
| Shutdown | `stop()` mid-recognition: streams finish, no sleepers, no leaked tasks |

## 5. Out of scope for Phase 2 (deliberately)

Speaker identification · punctuation/formatting beyond what the engine gives ·
language switching at runtime · `os_signpost` and thermal work (Phase 3) ·
Metal / C++ interop (Phase 4) · any UI beyond the terminal demo · sending audio
anywhere off the device, ever.

## 6. Definition of done

All ACs have deterministic tests on fake time and a scripted engine · the
terminal demo transcribes live speech on real hardware · README gains the
transcription picture and an honest note about what is and is not tested ·
DECISIONS.md covers every fork below · CI green · merge commit into main.

## 7. The design forks — for Ryad to rule

**F1 — which engine?**
- **A** `SFSpeechRecognizer` with `requiresOnDeviceRecognition` — works on the
  current platform floor (macOS 15 / iOS 18), mature, and now the legacy API.
- **B** `SpeechAnalyzer` + `SpeechTranscriber` — Apple's current API, built for
  streaming and long audio, on-device by design. Costs a platform bump to
  **macOS 26 / iOS 26** (your machine already runs 26).
- **C** Bring your own CoreML model (e.g. a converted Whisper). Most control,
  most work, and a model file in the repo.
- **RULED: B + D** (D-017). Apple's engine ships in the core library; a
  Whisper-class engine arrives as a separate optional product under the tiered
  dependency policy (D-016). Both implement `TranscriptionEngine`, both pass
  the conformance kit, and the pair makes a measured bake-off possible.
  Platform floor moves to macOS 26 / iOS 26, accepted deliberately.

**F2 — who decides where an utterance starts and ends?**
- **A** Our `EnergyVAD` (Phase 1) stays the boundary owner.
- **B** Apple's `SpeechDetector` module does it.
- **C** Let the transcriber's own endpointing decide.
- **Recommendation: A.** The boundaries stay ours, deterministic and testable
  on fake time — and the VAD is part of what this repo is showing. B becomes an
  interesting comparison in a later phase, not a dependency now.

**F3 — how audio reaches the engine?**
- **A** An adapter converts our chunks into the engine's buffer type. The ring
  stays the single crossing.
- **B** Let the engine tap the microphone itself.
- **Recommendation: A.** B would open a second capture path and quietly destroy
  the "exactly one crossing" claim that the whole library is built on.

**F4 — late results from a dead utterance?**
- **A** An utterance ticket, checked in the same actor step that raises it.
- **B** Trust cancellation.
- **Recommendation: A.** Cancellation is a request; the ticket is the
  invariant. Same law as the barge-in work, and a defiant fake will prove it.

**F5 — how many partials to publish?**
- **A** Every partial the engine gives.
- **B** Throttle to at most one every N milliseconds.
- **C** Finals only.
- **Recommendation: A** for v1 — a UI wants them, and the bounded listener
  buffers already protect a slow consumer. Throttling can be added later with
  real numbers instead of a guess.

**F6 — Phase 1's open question, now decidable: the hangover tail.**
- **A** Keep it: the 300 ms of trailing quiet is fed to the engine.
- **B** Trim it before feeding.
- **Recommendation: A.** Recognisers use trailing silence to settle their
  final result. Revisit with measurements once the real engine is running.

**F7 — the maximum utterance?**
- **A** A hard cap (default 30 s) with a `truncated` event.
- **B** No cap.
- **Recommendation: A.** Nothing in this library is allowed to grow without a
  limit — the same rule as the ring (D-004) and the listener buffers (D-012).
