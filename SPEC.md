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

> Status: **MILESTONE 2a DELIVERED 2026-08-09.** Seam + capabilities (AC-21,
> AC-35), session with the utterance ticket (AC-23…AC-32), scripted engine,
> conformance kit (AC-36), Apple engine adapter, iOS demo (verified live on
> an iPhone: model downloaded, utterances transcribed) and the terminal demo.
> 54 tests in 9 suites. Session semantics ruled in D-021. Field findings
> applied: per-app asset reservation, input gain, VAD threshold, pre-roll,
> partial cadence. **Remaining for Phase 2: milestone 2b** — the
> Whisper-class engine module (D-016 tier 2) and the measured bake-off; its
> motivation is now field data (accent robustness).
>
> Original approval: rulings F1 = **B + D** (Apple's engine in the core, a
> Whisper-class engine as an optional product), F2–F7 as recommended, plus
> the tiered dependency policy — logged as D-016…D-020.
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

---

# SPEC DELTA — Milestone 2b: the second engine, and the measured bake-off

> Status: **DELIVERED 2026-08-10.** Spike ✅ (WhisperKit proven end-to-end;
> Hugging Face delivered where Apple's daemon could not) · D-024 overlap
> red→green ✅ · MultiModalKitWhisper + conformance on the real pipeline ✅ ·
> WER scorer + shared harness + bakeoff CLI ✅ · engine picker + on-device
> bake-off in the iOS demo ✅ · BAKEOFF.md with measured rows from two
> devices ✅. Headline: a dead heat at 12.0% WER with different failure
> styles — the motivating anecdote was NOT confirmed, and the document says
> so. The instrument caught two scoring faults and one production bug (the
> Apple adapter's first-final hangup) on its way to one table.
> Original approval 2026-08-09 — all five forks ruled as recommended
> (D-023, D-024, D-025).
> The motivation is field data: the on-device en_US model struggles with
> non-native accents (found live, 2a). Whisper-class models are famously
> robust there. Two engines behind one contract make that a measurement
> instead of an opinion.

## 12. What 2b builds

A **second engine** — Whisper-class, CoreML, fully on-device — as a separate
product `MultiModalKitWhisper` (D-016 tier 2: dependencies allowed, isolated,
removable in a day because it lives behind `TranscriptionEngine`). Plus the
**bake-off**: the same recorded speech through both engines, with accuracy,
latency and size measured and written down honestly.

## 13. The one hard problem (this milestone's reason to exist)

**Whisper does not stream.** It wants the whole utterance, then decodes —
seconds, not milliseconds. Two consequences:

1. `EngineCapabilities` stops being decoration: `emitsPartials: false`,
   `wantsWholeUtterance: true`, `requiredSampleRate: 16_000` are now REAL,
   and the session must behave correctly for both engine shapes.
2. **D-021's retirement rule breaks batch engines.** Today, a new
   `speechStarted` retires the settling run — correct when finals arrive in
   milliseconds, fatal when they take seconds: results would routinely die.
   This is the milestone's real design fork (F2 below), and its ruling gets
   a new decision entry — D-021 is amended, never silently edited.

## 14. Acceptance criteria

- **AC-37** `MultiModalKitWhisper` is a separate library product. The core
  keeps zero runtime dependencies; CI proves the core builds without the
  Whisper product.
- **AC-38** `WhisperEngine` implements `TranscriptionEngine`, declares its
  capabilities HONESTLY, and mirrors the Apple engine's model surface
  (`modelInstalled()` / `ensureModel()`); model absence is an event.
- **AC-39** The engine passes the conformance kit (gated on an installed
  model, like Apple's; CI skips honestly).
- **AC-40** The session honors `wantsWholeUtterance` per the F2 ruling, with
  deterministic tests on a new scripted BATCH plan (`ScriptedTranscriber`
  learns to answer slowly, on command).
- **AC-41** Bounded by construction: accumulated audio is capped by the
  existing utterance ceiling; the memory bound is stated in the docs.
- **AC-42** `BAKEOFF.md`: methodology, exact numbers, honest caveats — same
  audio, same machine, both engines; what was NOT measured is listed.
- **AC-43** The iOS demo gains an engine picker, so the bake-off can run on
  the one machine that has both models today: the iPhone.
- **AC-44** CI stays green with no models installed anywhere.

## 15. Test matrix (first pass)

| Area | Tests |
|---|---|
| Batch semantics | scripted batch engine: final arrives AFTER the next utterance began → per the F2 ruling, exactly |
| Capabilities | a wantsWholeUtterance engine is fed identically but its late results survive per ruling |
| Ceiling | accumulation hits the 30 s cap → truncated, audio released |
| Conformance | WhisperEngine passes the kit (gated); ScriptedTranscriber batch plan passes it ungated |
| Bake-off harness | the runner computes WER correctly against a known reference (tested with scripted text, no models) |

## 16. The design forks — for Ryad to rule

**F1 — which dependency carries the model?**
- **A — WhisperKit (Argmax OSS SDK v1.0.0).** CoreML + Neural Engine, MIT,
  maintained, Swift 6 concurrency adopted. The four D-016 questions pass on
  paper; the spike verifies the Swift-6-cleanliness claim before any code.
- **B — whisper.cpp via C++ interop.** More control, no CoreML/ANE benefits
  without extra work, and it drags the Metal/C++ phase forward prematurely.
- **C — our own CoreML port.** The Phase-4 showcase, not a milestone.
- **Recommendation: A**, with the spike-first condition, and the exit is
  already built: it lives behind `TranscriptionEngine`, removable in a day.

**F2 — what happens to a slow engine's settling run when new speech starts?**
- **A — keep strict retirement** (today's D-021.1). Simple, but a batch
  engine's results die routinely — the second engine would be born broken.
- **B — capabilities-driven overlap:** for `wantsWholeUtterance` engines, a
  settling run SURVIVES the next `speechStarted`; its final is published
  late, tagged with its own utterance number (listeners already upsert by
  number). One run still feeds at a time; several may settle. Each settling
  run keeps its ticket until its final, failure, the ceiling, or `stop()`.
- **C — serialize:** don't open utterance N+1 until N settled. Kills
  conversational latency and queues unbounded audio — violates AC-41's
  spirit.
- **Recommendation: B.** It is what `EngineCapabilities` exists for, and the
  streaming path keeps today's exact behavior — strict retirement stays for
  engines that emit partials.

**F3 — which model, and how does it arrive?**
- **A — `base` (~150 MB), downloaded on first use** through the dependency's
  own model hub, surfaced through `ensureModel()` like the Apple engine.
- **B — `tiny` (~75 MB):** faster, noticeably weaker — it would bias the
  bake-off against Whisper.
- **C — bundled weights in the repo:** repo bloat, licence noise.
- **Recommendation: A** — and the bake-off may add `tiny` later as a second
  row, which is a measurement, not a decision.

**F4 — the bake-off methodology (what makes it honest)?**
- A fixed paragraph, written down in the repo, read aloud by Ryad — the
  reference transcript is known BEFORE recording, and the reader's accent is
  the point. Recorded once, committed as small WAV fixtures.
- Metrics per engine: word error rate against the reference · capture→final
  wall-clock latency (same machine, same audio, stated) · model size on
  disk · peak memory. NOT measured (and said so): battery, thermal, other
  languages, far-field microphones.
- Runners: a macOS CLI (`bakeoff <wav>`) for any machine with models, and
  the iOS demo's engine picker for the phone.
- **Recommendation: as described.**

**F5 — fake progress for a batch engine?**
- **A — none:** `emitsPartials: false` is the truth; the UI shows "thinking…"
  until the final arrives.
- **B — synthesized partials** (decode a sliding window early): pretty, but
  it manufactures the exact chunky-cadence problem we just escaped, and it
  costs decode time twice.
- **Recommendation: A.** The capability flag exists so UIs can tell the
  truth.

## 17. Out of scope for 2b (deliberately)

Speaker diarization and TTS (the SDK ships them — not our milestone) ·
language switching · streaming Whisper research · battery/thermal
measurement (Phase 3's instruments) · replacing the dependency with our own
CoreML port (Phase 4).

## 18. Definition of done

All ACs tested (deterministic where our code decides, gated where models are
required) · the F2 ruling amended into the decision log · BAKEOFF.md holds
real numbers from real hardware · the iOS demo switches engines · CI green ·
merge commit into main · teach-back: Ryad explains the overlap semantics and
the bake-off numbers cold.

---

# SPEC — Phase 3: instruments and self-awareness

> Status: **APPROVED 2026-08-11** — all five forks ruled A as recommended
> (F1/F2/F5 → D-026, F3/F4 → D-027). Build order: thermal seam + health
> stream red→green, then signposts, then field numbers → INSTRUMENTS.md.
> Phase 2 ended with an honest concession: "excluded by reasoning, never
> benchmarked." Phase 3 exists so that sentence can never be necessary
> again — the pipeline learns to measure itself, and to notice the device
> it lives on.

## 19. What Phase 3 builds

Three things, in order:

1. **Signposts** — `os_signpost` intervals across every pipeline stage
   (drain, VAD verdict, session feed, decode-per-engine, capture→final per
   utterance), so Instruments can draw the pipeline's true timeline on real
   hardware.
2. **The health stream** — a `HealthEvent` broadcast: thermal state changes,
   ring drops, listener losses, settling-decode count. The pipeline tells
   its consumer how it feels, through the same multicast machinery
   everything else already uses.
3. **INSTRUMENTS.md** — the evidence doc: pipeline idle cost, per-utterance
   cost, Whisper decode cost, measured on the iPhone with the new
   signposts; methodology stated, not-measured list included.

## 20. The one hard problem (this phase's reason to exist)

**Measurement must not disturb the measured.** The audio thread's iron laws
(no locks, no allocation, no logging) do not bend for observability — a
signpost in the tap callback could cost exactly the deadline it measures.
So the capture side stays dark: its only story crosses the boundary through
the atomics that already exist (drop counts, frame counts), and the
signposts begin where waiting is legal — at the pump. Observing the
real-time edge without touchinging it is the phase's craft.

## 21. Acceptance criteria

### Signposts
- **AC-45** Signpost intervals exist for: one pump drain · one VAD verdict
  batch · session chunk-feed · engine decode (labelled per engine) ·
  capture→final per utterance (audio-time stamped). Visible as a clean
  track in Instruments on a real device.
- **AC-46** ZERO instrumentation on the audio thread. The capture side is
  reconstructed from existing atomics only. Enforced by review and stated
  in the thread-map doc — honestly noted as not machine-checkable.
- **AC-47** Overhead is measured, not assumed: the deterministic suite runs
  with and without signposts and the delta is recorded in INSTRUMENTS.md.

### Health
- **AC-48** `HealthEvent` stream via `Broadcast` (bounded, drop-oldest,
  counted, no replay — D-012 rules apply unchanged): thermal state
  transitions · ring drops (mirrored from D-010 events) · listener losses ·
  settling-decode count changes.
- **AC-49** Thermal state arrives through a **seam** (`ThermalStateProviding`)
  — the real provider wraps `ProcessInfo`; tests drive a scripted fake
  deterministically. No test ever depends on a real device's temperature.
- **AC-50** v1 policy is **observe and publish only**: the pipeline reports,
  the consumer decides. No self-throttling — adaptive behavior is a future
  fork that needs Phase 3's own numbers first.

### Evidence
- **AC-51** INSTRUMENTS.md: methodology · idle pipeline cost · cost per
  utterance (both engines) · signpost overhead · thermal observations from
  a sustained run · what was NOT measured. Numbers from real hardware,
  device named.
- **AC-52** The eager-Whisper question from Phase 2 gets its number: decodes
  per utterance and compute cost measured for the sliding-window approach,
  recorded as a fork-input (not built as a feature).

### Hygiene
- **AC-53** Swift 6 strict, zero warnings, CI green; core keeps zero
  runtime dependencies (`os` is a system framework); all health/diagnostic
  code deterministic under test via the seams.

## 22. Test matrix (first pass)

| Area | Tests |
|---|---|
| Thermal seam | scripted transitions (nominal→serious→critical) → exact HealthEvent sequence |
| Health stream | bounded/drop-oldest/no-replay semantics hold (reuse the Broadcast suite pattern) · ring-drop mirroring exact |
| Settling count | batch overlap raises and lowers the count at exact moments (scripted batch engine) |
| Signpost overhead | suite wall-time with/without, recorded (informational, not asserted) |
| Determinism | full suite unchanged: no real thermal, no real clocks, no signposts required for any assertion |

## 23. Out of scope for Phase 3 (deliberately)

Adaptive throttling (needs this phase's numbers first — future fork) ·
AVAudioSession interruption/route handling (calls, Siri — the "real product
audio citizenship" phase, deserves its own spec) · the D-001/D-005 upgrade
rulings (`AVAudioSinkNode`, signal-driven pump — now MEASURABLE with these
instruments, ruled after numbers exist) · Metal/C++ (Phase 4) · any UI.

## 24. Definition of done

All ACs tested or honestly marked review-enforced · Instruments screenshot
-worthy timeline on a real iPhone · INSTRUMENTS.md with real numbers ·
DECISIONS.md covers every fork · CI green · merge commit · teach-back:
Ryad explains the observer-effect problem and the health seam cold.

## 25. The design forks — for Ryad to rule

**F1 — where signposts live**
- **A** Pump, session, and engines only — the audio thread stays dark, its
  story told by the atomics it already writes.
- **B** Everywhere, including the tap callback ("os_signpost is cheap").
- **Recommendation: A.** "Cheap" is not "free," and not provably lock-free
  on every path — the iron laws don't take probabilistic exceptions. The
  capture story is already fully reconstructable from the ring's counters.

**F2 — signposts in release builds**
- **A** Keep them: they are near-zero when no instrument listens, and they
  make FIELD problems diagnosable — an excellent product is debuggable in
  production, not only in the lab.
- **B** Compile them out for a theoretically pure release binary.
- **Recommendation: A.**

**F3 — how health reaches the consumer**
- **A** `Broadcast<HealthEvent>` — the house pattern, bounded and honest,
  many listeners (UI + logger + tests).
- **B** A delegate/closure callback. **C** os_log only.
- **Recommendation: A** — one delivery idiom everywhere; a consumer that
  learned `listen()` once knows the whole library.

**F4 — thermal policy**
- **A** Observe and publish only; consumers decide (and the demo shows a
  thermal badge, proving the loop).
- **B** Adaptive now: pipeline self-throttles (wider poll, smaller model).
- **Recommendation: A.** Self-throttling without measurements is guessing
  with extra steps; F4-B returns as its own fork the moment INSTRUMENTS.md
  exists, with numbers instead of vibes.

**F5 — the diagnostics seam's shape**
- **A** A small `PipelineDiagnostics` type owned by the consumer and passed
  in (like the clock: injected, explicit).
- **B** A global/static signpost logger reached from anywhere.
- **Recommendation: A** — injection is the house law; globals are how
  observability quietly becomes coupling.

## 26. Phase 3b — the thermal policy (fork B, D-028)

The deferral in D-027 comes due. One new seam:

```swift
public protocol ThermalPolicy: Sendable {
    /// Consulted at exactly one moment: when a whole-utterance run is
    /// about to move to the settling table. true = let the decode keep
    /// its ticket; false = retire the run instead. Never consulted for
    /// live work.
    func allowSettlingDecode(thermal: ThermalState, activeSettlingDecodes: Int) -> Bool
}
```

Injected into `TranscriptionSession` like the clock and diagnostics.
`nil` = today's behavior, byte for byte. A shipped default — allow below
`.serious`, refuse at `.serious`/`.critical` — encodes the field numbers:
the settling decode is the only measured lever (110 ms ANE bursts, ×2–3
under contention; everything else is 0.1 %-core noise or system-owned).

Honesty about what a refusal saves: the decode may already be RUNNING
(it starts at `finishAudio`); refusal cancels it — cooperative, an
optimisation, the ticket stays the guarantee. The big saving is the
CONTENDED case: queued decodes that would otherwise pile onto the ANE
(the ×2–3 the field runs measured) never reach it.

**The one hard problem:** a refusal must lose text *loudly and exactly
once*. The refused utterance surfaces as
`.failed(.declinedUnderThermalPressure)` — per-utterance, visible — plus
one `HealthEvent` per refusal, and its spans end at the refusal (one
grave, every path). Thermal staleness is tolerated by doctrine: the
policy is an *optimization*, never correctness — a transition one
millisecond after the read changes nothing that matters (the
cancellation doctrine, applied to heat).

**The boundary D-027 keeps:** the policy can only decline *optional*
work. It cannot gate the live utterance, cannot stop listening, cannot
cancel the active run. Those remain the app's rights. The policy is
consulted even without diagnostics injected (thermal reads `.nominal`
then) — so a custom policy can cap settling concurrency alone; the
shipped default is dormant in that case by construction.

## 27. Acceptance criteria (Phase 3b)

- **AC-54** `ThermalPolicy` seam: one method, `Sendable`, optional
  injection; with `nil`, every existing test passes unchanged.
- **AC-55** Exactly one consultation point — the settling-move step of
  the session funnel. The active utterance's decode is never gated, at
  any thermal state.
- **AC-56** Refusal semantics: run retired with its spans ended · the
  utterance surfaces `.failed(.declinedUnderThermalPressure)` · one
  `HealthEvent` per refusal · counts exact.
- **AC-57** Shipped default: allow at `.nominal`/`.fair`, refuse at
  `.serious`/`.critical`. Provably dormant on a cool device (a
  nominal-only script produces zero refusals).
- **AC-58** Determinism: all policy behavior driven by
  `ScriptedThermalProvider` + scripted engines. No real temperature, no
  real clocks, no sleeps.
- **AC-59** Hygiene: Swift 6 strict, zero warnings, zero new
  dependencies, CI green, 20× stability loop.
- **AC-60** The map's own rule fires: `ARCHITECTURE.md` gains the new
  box. The honesty caveat (thermal attribution never proven; the policy
  is insurance) is stated where the thermal claims live.

## 28. Test matrix (Phase 3b)

| Area | Tests |
|---|---|
| Seam | `nil` policy = suites pass untouched · scripted policy receives exact `(thermal, activeCount)` inputs |
| Default | scripted transitions: refusals at `.serious`/`.critical` only, dormant below |
| Refusal path | barge-in at `.serious` with a whole-utterance engine → named failure + health event + next utterance clean (spans ended: enforced in code review, not machine-checkable — the house signpost doctrine: no test can observe an os_signpost) |
| Live-turn immunity | active decode completes even at `.critical` |
| Determinism | scripted provider everywhere; stability ×20 |

## 29. Out of scope for Phase 3b (deliberately)

Pump-cadence throttling (0.1 % core — nothing to save) · gating the
Apple engine (system-managed) · auto-stop of listening (the app's
right, D-027) · adaptive eager-window work (own fork, needs AC-52's
numbers).

## 30. Definition of done (Phase 3b)

All ACs green · 20× stable · PR merged with the map updated ·
teach-back survived.

## 31. Phase 4, milestone 4a — the turn loop (scripted stages)

Today the spine ends at text. 4a builds the conversation above it: two new
seams — `ReplyGenerating` (final text in, reply tokens out) and
`SpeechSynthesizing` (token stream in, spoken-evidence events out) — plus
the `TurnCoordinator`: one loop, one truth, consuming the audio and
transcript streams the pipeline already broadcasts. Inputs are plain
`AsyncStream`s; the coordinator never holds the session or the pump, so
tests script it without either. 4a ships SCRIPTED stages only (with defiant
plans — the proof duty); real engines are 4b/4c behind the same seams.

**The one hard problem:** the ticket doctrine, promoted one level. An
utterance ticket protected one decode; a **turn ticket** must protect a
chain — generation feeding synthesis, both possibly mid-flight when the
user barges. Raised in the same actor step as the retiring transition; a
dead turn's tokens and speech provably unable to surface, defiant stages
included. Cancellation stays the optimization, never the guarantee.

**The input-side ticket:** a settling final from an EARLIER utterance
(D-024) may arrive while a new turn is already listening. The coordinator
mirrors the session's utterance numbering from the same event stream and
only lets the CURRENT utterance's final open a turn's thinking phase —
stale settled finals remain what they are: comfort text for apps, never a
reply trigger.

## 32. Acceptance criteria (Phase 4a)

- **AC-61** `TurnState` (idle / listening / thinking / speaking) with a
  single transition funnel validating every change against an explicit
  legal-transition table; no state write outside the funnel.
- **AC-62** Turn ticket: monotonic turn number, raised in the same actor
  step as the retiring transition. After a barge-in, ZERO events from the
  dead turn surface — proven with defiant generator AND defiant
  synthesizer, and for the input side with a stale settled final.
- **AC-63** Barge-in in every phase: during `thinking` before the first
  token, mid-generation, and during `speaking` — each yields the exact
  event sequence, tested.
- **AC-64** A final transcript that is empty/whitespace produces no reply:
  back to idle, the generator is never opened.
- **AC-65** Failure is an event: a generator or synthesizer failure ends
  the TURN, never the coordinator; the next turn runs clean.
- **AC-66** `stop()`: streams finish, no leaked tasks — the D-014
  race-then-cancel doctrine, applied to the turn loop.
- **AC-67** Events via `Broadcast` (bounded, drop-oldest, counted, no
  replay — D-012 unchanged); the current state is QUERYABLE on the actor,
  so late listeners ask for "now" instead of replaying history.
- **AC-68** Determinism: scripted stages, no sleeps, event-gated, 20×.
- **AC-69** Hygiene: Swift 6 strict, zero warnings, zero new dependencies,
  CI green, ARCHITECTURE.md updated (its own rule).
- **AC-70** The slice: the terminal demo runs the scripted turn loop live —
  speak, watch it think, see reply tokens print as speech, barge it
  mid-reply with your voice.
- **AC-72** *(added mid-milestone, ruled by Ryad — D-034)* Utterance
  identity is assigned by the pump and carried in `speechStarted`; no
  component derives it by counting. The desync-corruption scenario the
  review confirmed (one lost onset → every reply off by one, forever) is
  a regression test that proves one lost onset costs one utterance, and
  the next event heals the view.
- **AC-71** *(added mid-milestone, ruled by Ryad — D-032)* Latency seam:
  clock + injectable `LatencyReporter`, instants at the semantic
  boundaries, exact values proven on a manual clock (turn latency
  = advanced time exactly; cancel latency = exactly zero in mock time).
  The default coordinator stays clockless.

## 33. Test matrix (Phase 4a)

| Area | Tests |
|---|---|
| Happy turn | exact event sequence idle→listening→thinking→speaking→idle, tokens included |
| Barge-in | in thinking-before-tokens · mid-generation · mid-speaking · rapid double barge — exact sequences, defiant stages emit late and are dropped |
| Input ticket | stale settled final while listening → no thinking opened |
| Empty final | AC-64 exact; generator untouched |
| Failures | generator fails · synthesizer fails → turnFailed + idle, next turn clean |
| Funnel audit | full multi-turn state sequence: every adjacent pair in the legal table |
| Zero-token reply | finished with no tokens → completed, speaking never entered |
| stop() | mid-speaking: broadcast finishes, nothing after |

## 34. Out of scope for 4a (deliberately)

Real TTS (`AVSpeechSynthesizer` — 4b) · real on-device reply generation
(4c, seam-ready) · echo cancellation — the assistant hearing itself is
4b's hard problem, named now, solved when real audio exists · multi-turn
memory/context · turn-level signposts (revisit with 4b's field session).

## 35. Definition of done (Phase 4a)

All ACs green · 20× stable · demo slice runs live on the Mac · PR merged
with the map updated · teach-back survived.

# SPEC — Milestone 1d (interlude): the onset debounce

## 36. What 1d builds, and why now

Field evidence (08-13, commit 5be72ac): the Mac demo's 0.01 gate sat
exactly on this machine's post-sentence ambient level, and the VAD flapped
open every 0.84 s like a metronome — a dozen empty Whisper decodes per
short run, clustered right after each real sentence. The demo was patched
that day by raising the gate to 0.02; the principled fix was agreed as its
own milestone. This is it.

Today `speechStarted` fires on the FIRST loud chunk — 20 ms of sound.
Any transient (a keyboard tap, a click, one metronome tick, ambient noise
grazing the gate) opens a full utterance: pre-roll, a 300 ms hangover
tail, an engine decode. Since 4a the cost is higher: a pump
`speechStarted` is the barge-in trigger (D-031), so one 20 ms click can
kill a live spoken reply mid-sentence.

The fix is the mirror of the hangover. The hangover makes speech hard to
END: quiet must persist before `speechEnded`. The onset window makes
speech hard to START: loud must persist N frames before `speechStarted`.
Counted in FRAMES, not seconds — the VAD stays pure and clockless
(D-011), and the caller does the one conversion.

**The honest cost, named:** a debounce delays every TRUE onset by its own
length, so 4a's felt barge-in latency grows by the window. That is why
the window must stay small (2–4 chunks, 40–80 ms at the demo's 20 ms
chunks) and why the default is a fork for Ryad to rule (F-5).

## 37. Acceptance criteria (1d)

- **AC-73** `EnergyVAD.Config` gains an onset window in frames. A loud
  burst shorter than the window produces NO transition at all — no
  `speechStarted`, no `speechEnded`, no utterance born, nothing for the
  turn loop to barge on.
- **AC-74** Window = 0 is byte-for-byte today's behavior; the existing
  suite passes untouched (proof by unchanged tests — the D-028 nil
  precedent).
- **AC-75** The candidate dies on quiet (per F-2 ruling): loud·quiet·loud
  never accumulates across the gap. Loud persisting to exactly the window
  fires on the chunk that completes it, stamped per the F-3 ruling.
- **AC-76** No beheaded words: with pre-roll wired to cover the window
  (per F-4 ruling), the candidate chunks — the true start of the word —
  are delivered inside the utterance. Proven at the pump level: the first
  loud chunk's samples arrive after `speechStarted`.
- **AC-77** The hangover is untouched: while speaking, a loud chunk still
  resets the quiet budget exactly as before — the window only guards the
  quiet→speaking door. After a true end, a short transient does not
  reopen the utterance (AC-73 applies again).
- **AC-78** Hygiene + the slice: VAD purity kept (no clock, no
  allocation, no await in `process()`); Swift 6 strict, zero warnings,
  zero new dependencies; 20× stable; the Mac demo carries the window and
  a field run shows transients ignored and real words still opening —
  numbers printed and recorded in the PR.
  *(Amended by ruling, 2026-08-13 — D-036, fork F-6 = B: the field A/B
  convicted the window of clipping word onsets twice for zero quiet-room
  benefit, so the Mac demo ships with the window OFF and an `--onset`
  flag for experiments. The field evidence recorded in the PR is the
  A/B itself — both signatures, the disclosed confound, and the clean
  re-run — plus the forensic 🔎/🩺 lines that produced it. The window's
  mechanism proofs remain the deterministic suite, AC-73..77.)*

## 38. Test matrix (1d)

| Area | Tests |
|---|---|
| Flap killer | 1-chunk and (window−1)-chunk bursts → zero transitions ever |
| Exact window | a window-length run fires on the completing chunk, exact stamp per F-3 |
| Candidate reset | loud·quiet·loud alternation never fires (F-2) |
| Zero window | existing suite green, untouched (AC-74) |
| Pump integration | run-up chunks delivered inside the utterance; identity still born at the pump (AC-72 regression stays green) |
| Turn-loop interplay | scripted: a sub-window transient while `speaking` barges nothing |
| Purity | clockless, allocation-free — the existing iron-law style |

## 39. The design forks (1d) — for Ryad to rule

- **F-1 WHERE the debounce lives.** A: inside `EnergyVAD` — only the VAD
  knows loud/quiet per chunk; the window is the hangover's mirror and
  lives beside it. B: a decorator over any `VoiceActivityDetecting` —
  but the seam speaks only in transitions, so during nil-chunks the
  wrapper cannot tell loud-continuing from quiet without recomputing RMS
  (a second judge). C: in the pump — the pump is a bridge, not a judge
  (D-018/D-022 boundary), and would need the seam to leak loudness.
  **Recommendation: A.**
- **F-2 WHAT the window counts.** A: strictly consecutive loud frames —
  one quiet chunk kills the candidate. Simple, provable, kills clicks.
  B: a tolerance budget (loud must dominate the window) — kinder to
  breathy onsets, more knobs, harder to prove; belongs in the same
  drawer as per-sample precision (D-008, a smarter VAD later).
  **Recommendation: A.**
- **F-3 THE STAMP.** With a window, decision time and true onset diverge
  (today they coincide). A: stamp the chunk that completes the window —
  a decision stamp, consistent with D-013's `speechEnded`; the seam is
  unchanged, and the true onset is still recoverable from the pre-roll
  chunks' own timestamps. B: backdate to the first candidate chunk — the
  seam grows an associated value (`speechStarted(framesBack:)`) for one
  implementation's knob. **Recommendation: A.**
- **F-4 THE PRE-ROLL LAW.** During candidacy the pump believes "quiet",
  so candidate chunks land in pre-roll — capacity 2 today. A window of
  3 chunks would push the word's first chunk off the shelf. A: the
  wiring law — the caller sets `preRollChunks` ≥ onset chunks + the
  quiet run-up wanted; documented at both configs, wired in the demo,
  proven by the AC-76 pump test. The pump cannot see through
  `any VoiceActivityDetecting`, so config coupling is the caller's duty.
  B: widen the seam so the pump can ask the VAD its window and auto-size
  — the seam grows, and every future VAD must answer a question only one
  of them has. **Recommendation: A.**
- **F-5 THE DEFAULT.** A: default 0 — off. The library changes nothing
  byte-for-byte (the D-028 precedent); each product earns its own number;
  the demo sets the field-tuned example (3 chunks = 2,880 frames = 60 ms
  at 48 kHz). B: default on at ~2 chunks — safer out of the box, but
  silently changes every existing caller and adds 40 ms of barge latency
  nobody asked for. **Recommendation: A.**

## 40. Out of scope for 1d (deliberately)

Adaptive/auto-calibrating thresholds · spectral or model-based VAD ·
per-sample onset precision (D-008 drawer) · any change to the hangover
side · demo per-machine tuning UI. Small milestone, one door guarded.

## 41. Definition of done (1d)

All ACs green · 20× stable · field run on the Mac recorded · PR merged
with the map updated (if the map changes) · the forks ruled and logged
as D-entries · teach-back folded into the next session's spaced quiz.

# SPEC — Phase 4b: the real mouth

## 42. What 4b builds

The first real engine behind `SpeechSynthesizing`: an
`AVSpeechSynthesizer` adapter. The coordinator needs NO structural
change — that is the seam's exam. With a real mouth come the two
problems the 1d field session handed us:

**The one hard problem — the echo loop.** The Mac speaks its reply
through the speakers; the microphone hears it; the VAD opens; the
pump's `speechStarted` is the barge trigger (D-031) — the assistant
kills its own reply mid-sentence. Named in §34, due now.

**The second field debt — the reply gate.** "The utterance ended"
(300 ms of quiet) is a much weaker fact than "the user yielded the
floor." The 1d field runs showed every echo barged while the speaker
was still mid-paragraph. The coordinator gets the MECHANISM; the
number stays with the app (D-027).

Ordering ruled in session (2026-08-13): TTS before the LLM. The echo
loop is real-time audio — this project's spine; reply generation (4c)
is integration behind an already-proven seam, and it lands better
into an audible loop.

## 43. Acceptance criteria (4b)

- **AC-79** The phraser, pure: a clockless component that takes raw
  token text IN (any granularity — whole words today, subword
  fragments from a future generator) and yields speakable phrases OUT
  at punctuation and max-length boundaries. Exact deterministic tests
  including: subword joins, punctuation inside a token, burst-then-
  stall arrival, flush on finish. The token→utterance intelligence
  lives HERE, never in the adapter.
- **AC-80** The adapter, thin: `AVSpeechSynthesizer` behind
  `SynthesisRun`. Evidence-based updates (D-029): `.started` = the
  delegate's didStart (sound is audible), `.finished` = the LAST
  utterance's didFinish after `finishTokens` (F-4 = A), `cancel()` =
  `stopSpeaking(.immediate)`. Joins the recorded un-TDD-able list
  beside `AppleSpeechEngine`: kept thin, conformance-verified live.
- **AC-81** The reply gate, mechanism-not-policy: coordinator config —
  a gate `Duration` between a final transcript and opening the
  generator; a new onset during the gate kills the pending reply
  silently (no thinking entered, no turn events for it). Default zero
  = byte-for-byte today, proven by the untouched 4a suite (the D-028
  precedent). Exact ManualClock tests: gate expiry opens thinking at
  the exact instant; an onset one tick before expiry wins the race.
- **AC-82** The echo defense (F-2 = A, spike-gated): voice-processing
  echo cancellation on the microphone path. Honest before/after field
  record: FIRST the failing run — the assistant barges itself,
  recorded with the 1d forensic lines — THEN the fix: the assistant
  completes replies with the microphone live, and a real human barge
  still lands. If the spike fails on this hardware, fork F-2 reopens
  with the evidence (fallback candidate: the software gate).
- **AC-83** Latency, audible and measured: the D-032 seam reports
  token→first-audible-sound; felt pause and barge-dead are now HEARD
  on the Mac and printed as numbers.
- **AC-84** Hygiene + the slice: Swift 6 strict, zero warnings, zero
  NEW dependencies (AVFoundation/AVFAudio is the platform), 20×
  stable, map updated; `--talk` speaks through the Mac's speakers and
  is barged by a live voice.

## 44. Test matrix (4b)

| Area | Tests |
|---|---|
| Phraser | word tokens → phrases at punctuation · subword fragments joined · ". The" split correctly · max-length flush · finish flushes remainder · empty/whitespace tokens |
| Reply gate | zero gate = 4a suite untouched · expiry opens thinking at exact mock instant · onset during gate: reply dies silently, no ghost events · onset one tick before expiry wins · gate + stale final interplay (identity door unchanged) |
| Coordinator unchanged | full 4a suite green with a phrase-buffering scripted synth (defiant plans included) |
| Adapter (live kit) | conformance on hardware: started-on-audible · finished-after-last-didFinish · cancel silences within the barge budget |
| Echo (field) | the before run (self-barge recorded) · the after run (replies complete, human barge lands) |

## 45. The design forks (4b) — ruled 2026-08-13, logged as D-037

- **F-1 = A** Phrase buffer inside the mouth; per-token at the seam
  preserved. (Initially ruled C — per-token utterances — then re-opened
  the same day on the producer analysis: a future generator emits
  SUBWORD fragments and glued punctuation, which per-token would
  pronounce as broken pieces; buffering must exist somewhere, and the
  deep-module answer puts it below the seam so coordinator and
  generator never know. The seam law is untouched: the coordinator
  forwards every token as it arrives, buffering nothing.)
- **F-2 = A** OS-level echo cancellation (voice processing) on the
  microphone path — SPIKE FIRST, D-023 style: it can change the tap's
  format and sample rate; adoption is ruled on the spike's evidence.
  Rejected: half-duplex (kills barge-in — the thesis); software gate
  (kept as the named fallback if the spike fails).
- **F-3 = A** Reply gate lives in the coordinator as mechanism, the
  number in the app, default 0. Rejected: app-side filtering — the
  race between onset and gate expiry belongs inside the actor with
  the ticket; an app cannot win it from outside.
- **F-4 = A** `.finished` = the last utterance's didFinish — evidence,
  not intent (D-029). Rejected: finishing at `finishTokens` — state
  would flip to idle while sound still plays, and the reply-done
  latency number would be a lie.

## 46. Out of scope for 4b (deliberately)

TTSKit/neural voices — the named follow-up: spike three numbers
(first-audio latency, stop latency, thermal under D-028's policy),
then a voice bake-off with BAKEOFF.md discipline · SpeakerKit /
multi-speaker rejection (recorded during the 1d confound) · voice and
language selection policy · iOS talk demo · 4c reply generation.

## 46a. OPEN, RECORDED, NOT RULED (found in 4b's field runs)

Two problems the 90-second field conversation of 2026-08-14 exposed.
Both are named here with their evidence and deliberately left unruled —
neither belongs to 4b, and neither should be hotfixed by tuning a number.

**(1) QUIET SPEECH IS HEARD BY THE GATE AND LOST BY THE PIPELINE.**
Four utterances in the field run (420–580 ms, peaks 0.039–0.084) opened,
decoded EMPTY, and produced no reply — the speaker said something and
the assistant did nothing.

*(Diagnosis corrected on the record: first reported as a silent stretch,
so this entry first blamed ambient noise and argued that no threshold
could separate noise from speech. The speaker then corrected it — he WAS
talking. The evidence never changed; its meaning did. Same lesson as
D-036's confound: the room's description is data, and data gets
corrected.)*

The arithmetic says what happened. Each utterance carries a 300 ms
hangover tail, so a 420 ms utterance holds only ~120 ms of actual voice —
a syllable. At peak 0.039–0.084 the voice is barely 2–4× the 0.02 gate
(his normal speech runs 7–13×), so between syllables it dips UNDER the
gate, the hangover expires mid-word, and the utterance is cut. The
engine then receives fragments too short to decode and returns nothing.
Fragmentation, not deafness — and the failure is silent, which is worse.

The canceller changed the arithmetic that chose that gate. Before it,
ambient peaked at 0.024 and 0.01 flapped like a metronome (D-035/D-036);
with it, ambient peaks at 0.006. So the prediction was: a lower gate
should hold quiet speech in ONE utterance. `--vad <level>` was added to
test it.

**THE PREDICTION WAS TESTED AND IT FAILED — the threshold was the wrong
knob.** Field A/B at gate 0.012 (2026-08-14), one quiet sentence:

```
🔎 [1]  940 ms · peak 0.040  → "Do you think?"   decoded
🔎 [2]  380 ms · peak 0.017  → (empty)
🔎 [3]  820 ms · peak 0.042  → (empty)   ← the SAME level as [1]
🔎 [4]  380 ms · peak 0.017  → (empty)
```

One sentence, four pieces, and two of those pieces sat at the exact
level that had decoded a moment earlier. Lowering the gate 0.02 → 0.012
did not stop the shattering, so the fragment boundary is not the
threshold.

It is the HANGOVER. The gate decides whether a chunk is loud; the
hangover decides how long a dip is forgiven before the utterance is
declared over — and it is 300 ms. Quiet speech dips longer and deeper
(unvoiced consonants, trailing vowels, thinking gaps fall under any sane
gate), so a soft sentence crosses that 300 ms budget mid-thought and is
cut. 300 ms is a number tuned for brisk turn-taking, not for a speaker
who is quiet or composing.

This links finding (1) to finding (3) through ONE knob: a longer
hangover both keeps a quiet sentence whole AND stops the pipeline
manufacturing premature finals for the reply gate to act on — fewer
fragments, fewer wrong interruptions.

**A/B RUN, AND THE HANGOVER HYPOTHESIS IS CONFIRMED** (2026-08-14, the
same quiet sentence spoken twice, one variable changed):

```
300 ms hangover, gate 0.012        700 ms hangover, gate 0.02
🔎 940 ms · 0.040 "Do you think?"   🔎 2300 ms · 0.059
🔎 380 ms · 0.017 (empty)              "Do you think, should I put
🔎 820 ms · 0.042 (empty)               my check on?"
🔎 380 ms · 0.017 (empty)
   one sentence, four pieces          one sentence, one utterance
```

At peak 0.059 the voice sits comfortably ABOVE the 0.02 gate, which
settles it: the threshold never cut that sentence — the 300 ms dip
budget did. Zero empty decodes in the whole run, and the reply
completed without a barge.

Not yet bracketed: the minimum that works (500 ms untested; 700 proven,
300 disproven). Not yet tested: whether the longer hangover also reduces
the finding-(3) interruptions — that run was two utterances long. The
cost is real and must be stated wherever the number is adopted: the
hangover sits in front of EVERY final, so every reply waits 400 ms
longer than it did at 300 ms.

The barge side of the same coin stays open too: every one of those
fragments was a live barge trigger (D-031), so a reply that happened to
be sounding would have been killed by a syllable. If a lower gate does
not settle it, the named options are a smarter judge (the D-008 drawer),
a two-speed barge (duck at onset, kill only once the utterance proves
itself), or a transcript-gated barge (cheap, but delays the interruption
by a whole decode). SpeakerKit-style diarization is the neighbouring
question and stays in the same drawer.

**(2) A pause inside one thought loses its first half.** The speaker
said "Do you hear me well? Can you understand what I'm telling you?",
paused, then "should they put a jacket?" — and the assistant answered
only the LAST sentence. That is the input door and the reply gate
working exactly as ruled (D-024, AC-81), and for an echo it is
harmless. It will NOT be harmless in 4c: a reply generator that sees
only the newest final answers half a question. The fork to open there:
should a turn accumulate every final it collected while listening and
hand the generator the whole thought? Recorded now, with this run as
the evidence, so 4c starts from a known problem instead of discovering
it late.

**(3) NO FIXED TIMER SEPARATES "STILL THINKING" FROM "DONE TALKING."**
Field report, 2026-08-14, in the speaker's own words: *"when I talk for
long, the system just interrupts me and says what I'm saying at the
end"* — and the run contains the exchange, including his live complaint
about it being echoed back at him. The arithmetic explains it without
any component misbehaving. Measured from the same run: the hangover
costs 300 ms, the batch decode ~700 ms, the gate 800 ms, so the
assistant answers only when a pause exceeds ~1.8 s of real silence:

- pause < ~1.0 s — the next onset beats the final to the coordinator,
  the final is stale at the input door (D-024), nothing is said;
- ~1.0–1.8 s — the gate is armed and the onset kills the pending reply
  (AC-81), nothing is said;
- pause > ~1.8 s — the gate expires and it SPEAKS. If the speaker was
  merely composing his next sentence, that is an interruption.

His thinking-pauses and his finished-pauses are both around two
seconds, so no single number can tell them apart. BOTH WALLS ARE NOW
MEASURED: at gate 800 ms the assistant interrupts him mid-thought; at
gate 2000 ms it never answered at all in a 22-second exchange (felt
pauses, when it did answer in an earlier run: 2679–2768 ms — the cost
lands on every legitimate reply). A timer has no setting that is both
patient and prompt. This is the endpointing
problem, and it is a POLICY question the pipeline cannot answer with a
timer alone. Options, none ruled, all for their own milestone:
(a) accumulate the turn's finals so an early reply at least answers
everything said — this makes finding (2)'s fix the mitigation for
finding (3), which is why they belong in one milestone;
(b) semantic endpointing — let a judge decide whether the sentence is
COMPLETE, which is natural once 4c has a language model in the loop;
(c) prosodic endpointing (falling pitch, final lengthening) — the
D-008 smarter-judge drawer;
(d) leave it as the app's number and document the trade — honest, and
the current state.

Also observed, on the `--vad 0.008` experiment that finding (1)
predicted: no metronome flap returned (four empty utterances in 85 s,
not one every 0.84 s), which supports the canceller-gave-headroom
claim — but the gate now admits genuine ambient at peaks 0.009–0.011,
and the quiet-speech case was not re-run, so finding (1) stays OPEN.
The bracket to try next is 0.012–0.015: above the ambient just
measured, far below the 0.039 quiet speech that was being lost.

## 47. Definition of done (4b)

All ACs green · 20× stable · the Mac audibly converses and survives
its own voice, recorded before/after · PR merged with the map updated
· teach-back survived (may share a session with the owed 4a
teach-back).

# SPEC — Milestone 4c: the whole thought (the transcript ledger)

*(Numbering note: what the 4b spec called "4c — real reply generation"
becomes 4d. This milestone was not planned; it was specified BY THE
FIELD — SPEC §46a findings (2) and (3) — and it is a prerequisite for
putting a language model behind the reply seam, because a model that
sees one fragment answers half a question.)*

## 48. What 4c builds, and the evidence that demands it

Today a turn answers its LAST accepted final and nothing else. Every
other thing the speaker said in that turn is refused at the input door
(D-024/D-034 identity) or killed by the reply gate (AC-81), and then
dropped. Measured in the field, 2026-08-14:

```
"Do you hear me well? Can you understand what I'm telling you?"
[pause]
"should I take a jacket?"          →  the assistant answered ONLY the jacket
```

4c gives the turn a **transcript ledger**: the coordinator keeps what
the speaker said and hands the generator the whole thought. The
TRIGGER rules do not change — a refused final still never opens a turn,
never re-arms a gate, never moves a ticket. It contributes CONTENT
only.

**The one hard problem: when may a dead turn's words live, and when
must they die?** The ticket doctrine says a dead generation's events
must be provably unable to cause observable effects, and a ledger is a
deliberate channel from a refused input into a live prompt. The line
this milestone draws, and must defend:

> **User speech is EVIDENCE; a turn's reply tokens are COMPUTATION.**
> The ticket exists to stop cancelled computation from surfacing.
> Words the speaker really said do not stop being true when a ticket
> expires. Evidence may cross a turn boundary; computation may not.

That answers *may they live*. The other half — *when must they die* —
is answered by evidence too, and is fork F-2 below.

## 49. Acceptance criteria (4c)

- **AC-85** The ledger, pure: an ordered store keyed by utterance
  identity (D-034), with dedup by that identity, ordering by it, and a
  bounded size with drop-oldest (the D-012 house idiom). Clockless, no
  allocation surprises, exact deterministic tests — no coordinator, no
  actor, no clock in its suite.
- **AC-86** Membership, exactly: ONLY `TranscriptEvent.final` with
  non-empty trimmed text is recorded — whether the input door accepted
  it or refused it. `.partial` (a hypothesis), `.truncated` (a ceiling
  notice, its final still comes), `.failed` (no words) and every
  synthesis/reply event record NOTHING. A dead turn's reply tokens can
  never enter the ledger; the ledger holds only what the user said.
- **AC-87** The trigger rules are unchanged, and this is PROVEN, not
  asserted: refused finals still open no turn, arm no gate, move no
  ticket; the empty-final path still ends the turn (AC-64) and a
  non-empty ledger does NOT rescue it into a reply — an empty decode is
  the field's signature of a FRAGMENTED speaker (§46a finding 1), never
  of a finished one.
- **AC-88** The whole thought reaches the generator: when a reply
  opens, the generator receives every recorded piece of that thought in
  spoken order, joined per the F-1 ruling. The field scenario above is
  a test: two sentences with a pause, one reply, both sentences in it.
- **AC-89** The ledger empties on EVIDENCE (F-2 ruling), never on
  assumption: the words survive every path where the speaker did not
  actually get an answer, and are gone once they did.
- **AC-90** Reentrancy, stated precisely: the merge loop awaits each
  handler inline, so no audio or transcript event can interleave INSIDE
  a handler — only `stop()` can enter during an await. The ledger's
  post-await guards are specified against that REAL surface, not
  against an imagined one, and `stop()` mid-accumulation is a test.
- **AC-91** Hygiene + the slice: Swift 6 strict, zero warnings, zero
  new dependencies, 20× stable, map updated; the terminal demo makes
  the accumulated thought VISIBLE (one line per opened reply) so a
  field run can confirm the fix with the naked eye.

## 50. Test matrix (4c)

| Area | Tests |
|---|---|
| Ledger, pure (no clock, no actor) | order by identity · dedup by identity · bound + drop-oldest · join is exact · whitespace/empty excluded · out-of-order insert (a settled final arriving after a newer one) |
| The milestone's own bug | two sentences + pause → ONE reply containing BOTH (the field scenario, exactly) |
| Gate interaction | a gate-killed final still contributes to the reply that eventually fires |
| Door interaction | a stale settled final (D-024) contributes CONTENT and still opens nothing |
| Empty final | AC-64 exact: no turn, no rescue-by-ledger, generator untouched |
| Failure paths | generator/synthesis failure and transcription failure keep the words (F-2) |
| Barge | per the F-3 ruling, with the exact event sequence unchanged |
| Completion | after a reply is fully spoken, the words are gone (no double answer) |
| stop() | mid-accumulation: clean end, nothing published, no leak |
| Trigger invariance | the existing 4a/4b suite, with the one test that encodes the OLD behaviour amended visibly and by ruling |

## 51. The design forks (4c) — for Ryad to rule

- **F-1 WHAT THE GENERATOR RECEIVES.** A: keep `openReply(to: String)`
  — the coordinator joins the pieces (separator documented) and no
  conformer changes. B: widen the seam to a small `TurnTranscript`
  value carrying pieces (text + utterance + `AudioTime`) plus a joined
  `text`. B's honest argument is D-027: the join separator is PROMPT
  FORMATTING, which is policy, and A hard-codes it in the library.
  A's argument is the house rule against widening a seam on
  speculation — no AC here reads the extra fields, and pre-1.0 we own
  every conformer, so widening later costs three call sites.
  **Recommendation: A**, with the separator named in the spec and the
  D-027 objection recorded as the reason B may win later.
- **F-2 WHEN THE WORDS DIE.** A: on `turnCompleted` ONLY — the reply
  was fully spoken (the D-029/F-4 evidence rule again), so the thought
  was answered; every other ending (empty final, failure, barge, stop)
  keeps the words for the next attempt. B: on any turn end — simplest,
  but the field's most common turn-ender is the empty decode, so this
  throws the thought away exactly when it is most needed. C: a
  high-water mark raised when a generator is opened — rejected by the
  adversarial pass: opening a generator is not the user hearing an
  answer (failures, zero-token replies and barges all leave the words
  unanswered). **Recommendation: A.**
- **F-3 WHAT A BARGE MEANS FOR THE LEDGER.** A: the interrupted
  thought carries into the new turn — the speaker's field barges were
  CONTINUATIONS ("Why you interrupt me and tell me what I'm saying?").
  B: a barge empties the ledger — an interruption is an explicit "not
  that", and carrying risks answering an abandoned thought.
  **Recommendation: A**, because F-2 already deletes anything actually
  answered, so what carries is by construction unanswered speech — and
  the measured bug is the PAUSE case, which A serves and B does not.
  Honest counter: a speaker who barges to CHANGE subject drags the old
  subject into the new prompt.
- **F-4 THE BOUND.** A: bounded, drop-oldest, with a default count —
  the ledger's consumer is a PROMPT, and prompts have hard limits, so
  an unbounded ledger is a latent failure with a batch engine and a
  speaker who never completes a turn (a real 22-second field run
  produced zero completions). B: no bound until evidence demands one —
  D-039's own closing lesson is "do not invent a knob without
  evidence", and the measured volumes are tiny (16 utterances in 90 s).
  **Recommendation: A**, mechanism only: drop-oldest, no eviction
  event (the adversarial pass correctly called that unearned), and the
  number stated as the app's (D-027).
- **F-5 THE FLAG.** A: no flag — accumulation is always on. B: a
  default-off `Config` switch, mirroring D-028/D-036/D-039.
  **Recommendation: A**, and the distinction matters: those three
  precedents defaulted-off a POLICY (a thermal gate, an onset window, a
  tuning number). This is a CORRECTNESS fix — a switch to "keep
  answering half the question" is not a feature. Also, with the flag
  off the existing suite would exercise none of the new code, so
  "untouched suite" would prove nothing. The one existing test that
  encodes the old behaviour is amended VISIBLY, by this ruling, in the
  honest-history way.

## 52. Out of scope for 4c (deliberately)

Real reply generation (now 4d) · semantic or prosodic endpointing
(§46a finding 3's real answer — this milestone only SOFTENS it by
answering everything when it does answer) · cross-session memory ·
adaptive VAD (the D-008 drawer) · multi-speaker rejection (SpeakerKit).

## 53. Definition of done (4c)

All ACs green · 20× stable · the field scenario reproduced live on the
Mac and recorded (two sentences, one pause, one reply containing both)
· PR merged with the map updated · the forks logged as D-entries ·
teach-back survived.

# SPEC — Milestone 4d: the conversation leaves the Mac

*(Numbering note, second one: milestone letters follow EXECUTION order in
this repo. Ryad's ruling of 2026-08-14 puts the iPhone conversation
first, TTSKit's second mouth after it, and the language model last — so
what §48 called "4d — real reply generation" becomes **4f**, TTSKit is
**4e**, and this milestone takes 4d. The old names are left visible
where they were written; nothing is edited away.)*

## 54. What 4d builds, and why it is not a copy-paste

The Mac converses aloud. The iPhone still only transcribes: its demo
(`Demo/TranscribeDemo`) runs mic → pump → session → transcript list,
with a thermal badge, an engine picker and an on-device bake-off — but
**no turn loop and no mouth**. 4d gives the phone the whole
conversation.

The library needs no new capability for this. Everything the loop
requires — coordinator, ledger, phraser, `AppleSpeechSynthesizer` —
is platform-neutral and already shipped. **That is the milestone's
thesis, and its exam: if the core is honest, the diff is almost
entirely platform reality.**

Platform reality, on iOS, is an audio session that can be TAKEN AWAY.

## 55. The one hard problem: an audio session that fights back

On macOS the pipeline owns the microphone until it stops. On iOS it
owns nothing:

```
   a phone call arrives      → the session is INTERRUPTED, the engine stops
   Siri is invoked           → same
   headphones are unplugged  → the ROUTE changes under a running graph
   the app is backgrounded   → capture may end
   the app wants to SPEAK    → recording alone is no longer enough
```

And two of those interact with everything 4b measured. Playing a reply
while recording needs the `.playAndRecord` category — which on iPhone
defaults its output to the **receiver** (the quiet earpiece), not the
speaker. Choosing the speaker makes the reply audible AND makes the
echo loop far worse, which is the problem D-038's canceller exists to
solve — but the canceller's numbers were measured on a Mac mini whose
"microphone" is an iPhone over Continuity (INSTRUMENTS §6). None of
those ratios transfer. This milestone measures them again, on the
device, or it claims nothing.

## 56. Acceptance criteria (4d)

- **AC-92** The phone converses: speak, hear a spoken reply, and barge
  it with your voice. The same `TurnCoordinator`, `TranscriptLedger`,
  `SpeechPhraser` and `AppleSpeechSynthesizer` the Mac uses — no iOS
  fork of any of them, and no new library capability. If the core needs
  a change to run here, that change is a FINDING and gets recorded.
- **AC-93** Session mechanism, app policy (D-027): whatever configures
  `AVAudioSession` exposes MECHANISM; the category, mode, options and
  the speaker-vs-receiver choice are the APP's, stated in one place and
  visible in the UI. Per the F-1 ruling below.
- **AC-94** INTERRUPTION IS AN EVENT, NOT A CRASH: a phone call or Siri
  interrupts capture, and the pipeline ends the turn honestly rather
  than hanging — the turn's ticket dies, no ghost reply speaks
  afterwards, and the UI says what happened. On resume the next
  utterance starts a clean turn. Proven deterministically with a
  scripted interruption source, and once on hardware.
- **AC-95** ROUTE CHANGE IS AN EVENT: plugging or unplugging headphones
  while a reply is being spoken does not strand the turn. Same
  guarantees as AC-94, same proof shape.
- **AC-96** The echo numbers are re-measured ON THE PHONE and recorded
  in INSTRUMENTS.md, for BOTH output routes (the F-4 toggle: receiver
  and speaker, one row each): the residual level with voice processing on, the
  speaker's own level at the tap, and the human-speech level for
  comparison. No Mac number is reused, and the sentence "the ratios
  transfer" is never written without a device measurement behind it.
- **AC-97** The numbers this device earns are ITS OWN (the D-036/D-039
  precedent): VAD gate, hangover and reply gate are re-derived on the
  phone from a field run, not inherited from the Mac's 0.02 / 700 ms /
  800 ms. Whatever they turn out to be, the reasoning is recorded.
- **AC-98** Hygiene + the slice: Swift 6 strict, zero warnings, zero new
  dependencies, the whole suite 20× stable, map updated; a field run on
  the iPhone recorded with the same forensic discipline as the Mac's —
  including at least one interruption survived live.

## 57. Test matrix (4d)

| Area | Tests |
|---|---|
| Interruption | scripted: began → the turn dies, no reply speaks after, exact event sequence · ended → the next utterance opens a clean turn |
| Route change | scripted mid-reply: no stranded turn, ticket honoured |
| Session seam | the app's configuration is called exactly once per start; a failure to configure is an event, not a crash |
| Core unchanged | the entire existing suite green with no iOS-specific branch in the library |
| Hardware (gated) | conformance of the real session path, skipped honestly off-device — the `MMK_LIVE_SYNTH` precedent |

## 58. The design forks (4d) — for Ryad to rule

- **F-1 WHERE THE SESSION LIVES.** A: entirely in the demo app — the
  library never mentions `AVAudioSession`, and the app configures it
  before starting capture (what the iOS demo does today). B: a small
  library seam (`AudioSessionConfiguring`) that the app implements and
  injects, so the library can ORDER the steps (configure → start →
  deactivate) without knowing the policy. C: `MicrophoneSource`
  configures it internally on iOS. **Recommendation: B** — the ordering
  IS mechanism and it is easy to get wrong (deactivating while the
  engine runs, activating twice), while every value in it is policy;
  A leaves the ordering to be re-invented by every app, C hides policy
  inside a type that has no business choosing it.
- **F-2 HOW INTERRUPTIONS REACH THE PIPELINE.** A: an
  `InterruptionReporting` seam the app feeds from
  `AVAudioSession.interruptionNotification`, so the library sees a
  platform-neutral event and the tests can script it. B: the app alone
  reacts, stopping and restarting the pipeline from outside. C: the
  library subscribes to the notification itself (platform code in the
  core — against the house shape). **Recommendation: A** — it is the
  only option that makes AC-94 deterministically testable, and it keeps
  the core free of iOS.
- **F-3 WHAT AN INTERRUPTION DOES TO A LIVE TURN.** A: it ends the turn
  like a failure — the ticket dies, the mouth is silenced, an event is
  published, and the words STAY in the ledger (D-040 F-2: nothing
  answered them). B: it pauses and resumes the same turn. C: it is
  treated as a barge. **Recommendation: A** — B needs state that
  survives a dead audio graph and invents a "paused turn" the funnel
  has no place for; C would be a lie (the user did not speak).
- **F-5 WHO DECIDES TO RESUME (added mid-spec, raised by Ryad).** The
  OS takes the session during a call — there is no "keep recording"
  option to rule on. The real choice is what happens when the
  interruption ENDS. A: the library auto-resumes when the platform
  hints `.shouldResume`. B: the library stays stopped, publishes that
  it was interrupted, and the APP (or the user, via a control) decides
  when listening starts again. C: a config knob with a default.
  **Recommendation: B** — auto-resume has a real failure mode: after a
  long call the speaker may have walked away, and with the ledger the
  assistant still holds what was said BEFORE the call and could answer
  it out of nowhere. Resuming is policy (D-027), and policy belongs to
  the app. C is B plus a knob nobody has asked for yet.
- **F-4 SPEAKER OR RECEIVER.** A: `.defaultToSpeaker` — the reply is
  audible across a room, and the echo is loud, so the canceller is
  doing real work and is measured doing it. B: receiver/earpiece —
  quiet, phone-to-ear, far less echo, but the demo becomes unshowable.
  **Recommendation: A**, with the honest note that it is the harder
  case and the one the numbers must be taken under.

## 58a. OPEN, RECORDED, NOT RULED (found in 4d's first field run)

**The echo loop is NOT cured on the phone.** First device run,
2026-08-14, speaker route: the assistant barged ITSELF while speaking —
the disease D-038's canceller cured on the Mac, back on iOS. Lowering
the output volume reduced it, which is the signature of a residual echo
sitting ABOVE the gate rather than of anything subtler.

The arithmetic that makes it unsurprising: this app's gate is **0.01**,
earned in Phase 2 when the app only LISTENED — no speaker, so nothing to
cross it — while the Mac runs 0.02 against a MEASURED residual of 0.008.
On a phone the loudspeaker sits centimetres from the microphone, and
since D-031 an onset IS a barge.

Also reported and NOT yet explained: lowering the volume helped the
Apple engine but not Whisper. The barge fires on the pump's
`speechStarted`, which never sees the engine at all, so either something
else differs or the observation was about transcription quality rather
than barging. **No theory is recorded here, because the first run had no
instrument** — the phone app shipped without the forensic levels the Mac
demo has had since its first field session. That gap is now closed (live
input level, per-utterance peak/duration, an "echo?" mark on any
utterance that began while the assistant was speaking, and the gate
itself adjustable on screen), so the next run measures instead of
describes.

The hypothesis to test FIRST, before any tuning: **the canceller may not
have the reply as its reference at all.** Voice processing cancels what
the audio unit it belongs to renders; `AVSpeechSynthesizer` does not
play through this pipeline's `AVAudioEngine`. On macOS the spike proved
cancellation of audio from an entirely separate PROCESS, so the
reference is system-wide there — that is a measurement of one platform,
never a law, and iOS may differ. If it does, raising the gate treats a
symptom: the honest fix is routing the mouth's audio through the same
engine (`AVSpeechSynthesizer.write` into a player node), which is a
design fork, not a tweak.

## 59. Out of scope for 4d (deliberately)

TTSKit (now 4e) · the language model (now 4f) · endpointing (§46a
finding 3) · adaptive VAD (finding 1) · background audio and lock-screen
playback · CarPlay/AirPlay routing · a second iOS UI design pass.

## 60. Definition of done (4d)

All ACs green · 20× stable · the iPhone converses aloud, is barged by a
live voice, and survives a real interruption — recorded · the device's
own numbers in INSTRUMENTS.md · PR merged with the map updated · the
forks logged as D-entries · code adversarially reviewed BEFORE the merge
(D-041) · teach-back survived.
