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

**MEASURED ON THE DEVICE, 2026-08-15 — and the hypothesis below was
right.** Echo probe, speaker route, gate 0.010:

```
quiet room       peak 0.0092   rms 0.0008
while speaking   peak 0.7036   rms 0.0100      ← 76x the quiet room
```

The Mac's canceller took speaker audio at the tap from 0.136 to 0.008.
The phone shows **0.70** — the reply arrives essentially UNCANCELLED.
This also kills tuning as an option, permanently: human speech peaks
around 0.1-0.3, so on this route **the echo is louder than the speaker's
own voice**, and no threshold can separate them. Raising the gate would
silence the person before it silenced the phone.

DISTINGUISHED, and the answer is the worse one: the probe reports
**voice processing ACTIVE** while the reply still arrives at peak
**1.0000** — and the same run shows the canceller working on room noise
(0.0092 → 0.0030). It runs; it cannot see the reply. Ruled in D-043:
the finding ships with 4d, the routing fix becomes milestone 4f, after
TTSKit (4e).

The hypothesis that predicted this: **the canceller may not
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

# SPEC — Milestone 4e: the second mouth (TTSKit)

## 61. What 4e builds, and why it is next

Every seam in this library has two real implementations — except one.
`TranscriptionEngine` has Apple's and Whisper's, proven interchangeable
by a measured bake-off. `SpeechSynthesizing` has one mouth, and
"we can switch mouths" is therefore a CLAIM where the input side has a
PROOF.

4e builds the second: a `SpeechSynthesizing` backed by **TTSKit**
(Qwen3 neural TTS, CoreML) from the `argmax-oss-swift` package this
project already resolves for WhisperKit. Same seam, no coordinator
change, and a voice bake-off with BAKEOFF.md's discipline.

**Two things make it worth doing now rather than after the language
model.** First, the architecture claim is the portfolio's differentiator
and it is one milestone from being provable. Second — and this was not
planned — TTSKit may hand back the fix that 4d deferred.

## 62. The unplanned opportunity, stated as a HYPOTHESIS

D-043 measured why the iPhone cannot cancel its own reply: voice
processing removes only what ITS OWN audio unit renders, and
`AVSpeechSynthesizer` plays somewhere else. The fix named there is to
render the reply through the pipeline's engine — deferred as milestone
4f because it meant rewiring Apple's mouth.

TTSKit's `SpeechModel` exposes BOTH paths:

```
   play(text:…)      → TTSKit renders through its own AudioOutput   (same problem)
   generate(text:…)  → hands US the PCM, chunk by chunk, in a callback
                          ▲
              if WE render it, the canceller can see it
```

So the neural mouth may arrive already cancellable, and 4f may shrink to
"do the same for Apple's mouth". **Recorded as a hypothesis to TEST, not
a claim** — the D-038 lesson is exactly what happens when a measurement
on one path is treated as a law elsewhere. It is fork F-1 below, and
AC-104 is the measurement that settles it.

## 63. The one hard problem: a mouth that thinks before it speaks

`AVSpeechSynthesizer` starts almost instantly. A neural TTS decodes
autoregressively — roughly one frame (~80 ms of audio) per step — so
**time-to-first-audio becomes part of the felt pause**, and it is
variable rather than fixed. The pipeline's whole latency story (743 ms
of pipeline, 1481–1555 ms felt pause with an 800 ms gate) gets a new
term, and the D-028 thermal policy — honestly labelled "insurance, not a
measured cure" since Phase 3 — finally meets a workload that can heat a
phone.

## 64. Acceptance criteria (4e)

- **AC-99** The module: `MultiModalKitTTS`, an OPT-IN product beside
  `MultiModalKitWhisper` (D-016 tier 2, D-023's four questions). The
  core keeps zero runtime dependencies; nothing in `MultiModalKit`
  learns that TTSKit exists.
- **AC-100** Model lifecycle with Phase 2's lessons applied, not
  re-learned: `modelInstalled()` verifies the asset files BY NAME and
  means offline-capable; `ensureModel()` downloads once; a missing model
  is a named failure, never a crash; and startup makes **zero network
  requests** when the model is on disk (the WhisperKit ping that cost
  4× on every test load).
- **AC-101** The adapter behind the seam: `SpeechSynthesizing` /
  `SynthesisRun`, obeying the same evidence rules as Apple's mouth
  (D-029, D-037 F-4) — `.started` when sound is AUDIBLE, `.finished`
  when the room is quiet, `cancel()` silent and terminal-free. It passes
  the existing `SynthesizerConformanceKit` unchanged: that kit was
  written for "a second mouth we do not have yet", and this is the
  milestone that makes it earn its keep.
- **AC-102** *(status: PARTLY MET — time-to-first-audio is measured on a
  Mac in INSTRUMENTS §10, §15; **stop latency and thermal were never
  measured, on either machine**, and the iPhone numbers this criterion
  demands do not exist. The phone was observed to get hot; how hot was
  never written down. Carried into 4f rather than counted as done.)*
  THE SPIKE GATES, measured before any adoption ruling
  (D-023's discipline, as D-037 promised): **time-to-first-audio**,
  **stop latency** (barge → silence), and **thermal** under sustained
  use with D-028's policy watching. Numbers in INSTRUMENTS.md, on both
  Mac and iPhone, or no adoption.
- **AC-103** THE VOICE BAKE-OFF. Both mouths, the same sentences, and
  measurements that are honest about what can and cannot be measured:
  intelligibility as a NUMBER by round-tripping the spoken audio back
  through the transcription engines this repo already owns (speak →
  record → transcribe → WER against the source text), plus latency and
  size. Anything subjective — "which voice sounds better" — is reported
  as opinion and labelled as such, never dressed as data.
- **AC-104** The echo hypothesis (§62) TESTED on the iPhone with the
  4d probe: does a reply rendered through the pipeline's own engine fall
  under the gate? Either answer is recorded; a positive one reshapes 4f.
- **AC-105** Hygiene + the slice: Swift 6 strict, zero warnings, 20×
  stable, map updated, and the demos let a listener switch mouths and
  hear the difference on real hardware.

- **AC-106** (added after AC-102 measured, D-046 = B) **The decode
  margin is attacked before it is hidden.** Every lever TTSKit exposes
  that could lower RTF is enumerated with a citation, verified to be
  real, public, and actually wired to the decode path, then MEASURED
  serially — one machine, one run at a time, because parallel model runs
  would corrupt the timings. The outcome is a number in INSTRUMENTS.md
  whichever way it falls, including "nothing here gets RTF below 1.0",
  which is a result and not a failure.
- **AC-107** (added after AC-102 measured, D-046 = A) **The lead.** The
  renderer does not start the player with zero pre-roll. The policy that
  decides when to start is a PURE type with its own tests — the
  `SpeechPhraser` shape — so the rule is provable without a speaker, a
  model, or a clock. It must satisfy, deterministically: enough audio
  queued starts playback; a reply that ENDS before the lead is reached
  still plays and still terminates (the liveness promise — a short reply
  must never wait for audio that will never come); a cancelled reply
  starts nothing. Then the RTF measurement is re-run and INSTRUMENTS.md
  records whether the gap arithmetic actually closed — total ≈
  first-audio + audio, rather than ≈ decode wall time.

  *Numbered after AC-105 because this list is append-only: the criteria
  are numbered in the order they were ADDED, not in the order they will
  be met, and AC-105's hygiene gate still closes the milestone last.*

- **AC-108** (added by D-048) **A reply can be rendered on the capture
  engine.** `MicrophoneSource` gains a way to host playback, so the
  audio unit that does the echo cancelling is the one that also renders
  the reply. The seam must hide the engine's LIFECYCLE, not merely
  expose the object: attaching to a host that is not running is a named
  failure rather than silence, and stopping the host takes the reply's
  node with it. It ships with TWO implementations, because that is this
  repo's standard for calling something a seam — the microphone, and a
  plain engine for machines with no capture in the picture. What cannot
  be proven without hardware is stated as such and measured in AC-104.

  **STATUS, AMENDED BY D-049 — built, tested, and SWITCHED OFF in the
  only place that mattered.** The seam exists with two implementations
  and its own tests, and the demo no longer uses the capture-side one:
  voice processing and an output chain could not coexist on one engine
  (INSTRUMENTS §17). So the criterion's stated PURPOSE — the echo
  canceller seeing the reply — is **not met**, and it moves to 4f.
  AC-104, which this criterion existed to enable, **did not happen**.
  Both are recorded as unmet rather than quietly re-scoped, and the
  `hostsPlayback` switch stays in the code, defaulting off, because 4f
  will need it and because deleting it would erase the measurement.

- **AC-109** (added by D-052, ruled as D-053) **The decode lives behind a
  seam, and the failure path is PINNED rather than argued.**
  `NeuralVoiceRun` holds a `TTSDecoding` — ours — instead of a concrete
  `TTSKit`, so a scripted decoder can make a decode **throw** and make it
  **block**. That turns five claims into red-before-green facts:

  1. a throwing decode reports `.failed` **once**, terminal, and the
     update stream finishes;
  2. **the run is retired** — a phrase already queued behind the failure
     is never decoded, and the node goes back exactly once;
  3. an unspeakable phrase is never handed to the decoder AT ALL, and the
     reply still reports `.finished` — the in-flight count staying honest,
     observed. This is AC-106's guard, which until now could only be
     tested where the weights were installed, and the bug it prevents is
     19.6 seconds of audio for a phrase containing nothing;
  4. `cancel()` during a decode makes the step callback return `false` —
     the decode's own channel — and reports no terminal;
  5. a decode that throws AFTER a cancel reports nothing. **Half-provable,
     and the test says so:** `cancel()` has already finished the stream, so
     a late `.failed` would be dropped whether the production guard exists
     or not. What is pinned is that the throw happens and no terminal is
     observed; what is not pinned is the second `teardown()` the guard
     avoids, because asserting "this never happens later" needs a timing
     guess and this repo does not allow one.

  And four promises the seam made testable in passing, none of which
  needed a model or a speaker:

  6. `feed` HANDS OFF rather than decoding — the barge fault the field
     found before the suite did. The suite that owns this promise says a
     mock cannot fail it; a mock that never *returns* can;
  7. the run's render format comes from its DECODER, not from a second
     argument beside it and not from the host — the host's graph runs at a
     deliberately different rate in the test, because 24 kHz played as
     16 kHz is the "drunk voice" the field reported;
  8. `NeuralVoice.shutdown()` (D-052) is safe on a voice that never spoke,
     and safe twice — a public verb that shipped with zero callers and no
     test;
  9. a host that REFUSES to render makes the run fail loudly at
     construction rather than returning a run that can never speak.

  Fact 2 is the one that earns the seam. It is blocker 1 of the 4e review
  (D-051): a `.failed` decode used to keep running and call `play()` on a
  node whose engine had already been handed back, and AVFoundation does
  not throw there — **it aborts the process**. That fix shipped
  green-only, because nothing could make a real 1.1 GB model fail on
  demand. This criterion is the debt being paid.

  **The honest limit, measured rather than assumed (D-054).** Only paths
  that emit NO audio test headlessly. `bakeoff graph-probe` measured what
  a player node off a running engine tolerates: `stop()` and `reset()`
  survive, and **`play()` and `scheduleBuffer` abort the process**. So the
  scripted decoder emits empty sample arrays, and everything that actually
  renders stays where it already is — live-audio gated, model-gated. This
  criterion pins the FAILURE path; it does not pretend to pin playback.

  **What it does NOT claim.** D-052 said this seam would answer D-023's
  fourth question — *could we remove this dependency in a day, because it
  lives behind one of our protocols?* Under the D-053 ruling it answers
  **half**: yes for the decode path, still **no** for the model lifecycle,
  where `TTSModelVariant`, `TTSKitConfig` and the two decoder-mode enums
  remain in `NeuralVoice`'s public API on purpose — `.fused` versus
  `.stepped` is a PUBLISHED NUMBER (AC-106), not an internal detail.

## 65. Test matrix (4e)

| Area | Tests |
|---|---|
| Conformance | the existing `SynthesizerConformanceKit`, applied to the neural mouth (model-gated, skipped honestly where absent — the WhisperEngine precedent) |
| Model lifecycle | not-installed is a named failure · `modelInstalled()` false when asset files are missing by name · zero network on a warm start |
| Cancellation | `cancel()` mid-generation stops the decode AND the audio; no terminal; nothing survives a late feed |
| Liveness | an unspeakable reply still terminates (the promise the Apple mouth already keeps) |
| Coordinator | the whole 4a–4d suite green with the neural mouth substituted in the scripted places it can be |
| Bake-off | the round-trip WER harness itself: a known-good pair scores 0 %, a scrambled pair scores high |
| Neural failure path (AC-109) | `NeuralVoiceFailurePathTests`, nine cases, one per numbered fact above, all headless — no model, no speaker, no environment gate |
| Coordinator, the other half of blocker 1 | the synthesis-`.failed` arm cancels THE MOUTH, not only the reply run |
| The graph itself (D-054) | `bakeoff graph-probe` — one case per process, because an abort ends a process: what a player node off a running engine tolerates, and one CONTROL case whose failure is what proves the instrument can see a failure |
| The lead's liveness funnel (D-055) | `PlaybackLeadStrandTests` — a decoder that emits real samples on command, on a real engine, one variable: WHEN the token stream closes. The shipped zero lead, the stranding case, and the ordering that always worked |

## 66. The design forks (4e) — for Ryad to rule

- **F-1 `play()` OR `generate()` + our own rendering.** A: let TTSKit
  play — least code, and it inherits 4d's echo problem unchanged. B:
  take the PCM from `generate`'s callback and render it through the
  pipeline's engine — more code (format conversion, a player node,
  buffer scheduling) but it is the ONLY path that can make the reply
  cancellable, and it turns §62's hypothesis into a measurement.
  **Recommendation: B**, with A kept as the fallback if the rendering
  proves to fight the platform.
- **F-2 WHAT `.started` MEANS for a mouth that thinks.** A: the first
  PCM chunk actually rendered — evidence, consistent with D-029. B:
  generation start — earlier, and a lie: nothing is audible yet.
  **Recommendation: A.**
- **F-3 THE PLAYBACK STRATEGY.** TTSKit offers `.auto`, `.stream`,
  `.buffered`, `.generateFirst`. A: `.auto`, which measures the first
  step and pre-buffers accordingly. B: `.stream`, lowest latency,
  choppy if the device cannot generate faster than real time. C:
  `.generateFirst`, smooth but the felt pause absorbs the whole
  generation. **Recommendation: A**, with the measured number recorded
  either way — this is a latency/robustness trade the spike can settle.
- **F-4 WHERE IT LIVES.** A: a new opt-in product `MultiModalKitTTS`,
  mirroring `MultiModalKitWhisper`. B: inside the existing Whisper
  module, since both come from one package. **Recommendation: A** — the
  seam it implements is different, and an app wanting a neural voice
  should not be made to pull a speech recogniser.
- **F-5 WHAT THE BAKE-OFF MAY CLAIM.** A: intelligibility measured by
  round-trip WER (speak → record → transcribe → compare), plus latency,
  size and thermal — with voice preference reported as labelled
  opinion. B: latency and size only; refuse to score quality at all. C:
  a subjective rating as the headline. **Recommendation: A** — the
  round trip is a real instrument and this repo's whole method is
  turning "it sounds better" into a number with stated caveats. C is
  the thing BAKEOFF.md exists to refuse.

## 67. Out of scope for 4e (deliberately)

The echo ROUTING fix for Apple's mouth (still 4f, informed by AC-104) ·
the language model (4g) · voice/language selection UI beyond what the
bake-off needs · streaming partial replies from a language model ·
SpeakerKit.

## 68. Definition of done (4e)

All ACs green · 20× stable · the spike's three numbers measured on both
devices BEFORE the adoption ruling · the bake-off written with its
caveats · code adversarially reviewed BEFORE the merge (D-041) · PR
merged with the map updated · the forks logged as D-entries ·
teach-back survived.

# SPEC — Milestone 4f: the mind (a reply that is thought, not echoed)

*(Numbering note, third one — and it settles a contradiction this file has
been carrying. §48 called the language model "4d"; the 2026-08-14 ruling
renumbered it **4f**; but two later passages (§54's out-of-scope line and
§67's) went on calling 4f "the echo ROUTING fix" and the language model
"4g". Both readings are in the file. **Ryad's ruling of 2026-08-18 settles
it: the language model is 4f, and the echo routing fix becomes 4g**
(D-056). The contradicting sentences are left where they were written;
nothing is edited away.)*

## 69. What 4f builds, and why it is next

Today the pipeline listens, understands, decides whose turn it is, and
speaks — and what it speaks is **your own words back at you**.
`PacedEchoReply` on the Mac, `PhoneEchoReply` on the phone. Every other
organ on the spine is real; this one is a placeholder.

4f replaces it with a real on-device language model behind the
`ReplyGenerating` seam that has been waiting for it since 4b. Nothing else
on the spine changes. The turn ticket, the reply gate, the ledger, the
phraser, both mouths — all of it already speaks the language a generator
talks in.

**The seam was built for this, and the record proves it.** `SpeechPhraser`
exists because D-037's F-1 was ruled TWICE: Ryad first ruled per-token
utterances, then re-opened it himself and switched, because a language
model emits SUBWORD fragments — `"con"` / `"curr"` / `"ency"` — so
per-token utterances would be *wrong*, not merely choppy. That ruling was
made for a producer that did not exist yet. 4f is that producer arriving.

**The floor is Apple's Foundation Models**, and it costs **no dependency at
all**: the platform floor is already macOS 26 / iOS 26 (D-017), and
`FoundationModels.framework` is a system framework in that SDK — verified
present on this machine, not remembered. That is the same shape as
`AppleSpeechEngine`, which lives in core for the same reason.

## 70. THE GATE, stated before anything is promised

**The model is NOT available on this development Mac.** Measured, on
2026-08-18, with a four-line probe compiled against the real SDK:

```
availability: unavailable(UnavailableReason.appleIntelligenceNotEnabled)
isAvailable: false
```

Apple Intelligence is switched off at the system level. The framework is
present and the probe builds and runs; the model is simply not there.

This is the same class of finding as the one already in the README about
Apple's speech models failing on this Mac, and it must be ruled BEFORE the
adapter is written, not discovered inside it:

- If Apple Intelligence can be enabled here and on the iPhone, 4f proceeds
  as specified.
- **If it cannot be enabled on the iPhone, 4f has no engine**, the floor
  argument collapses, and the MLX contender (F-6) stops being deferred and
  becomes the milestone. That reversal is cheap to make now and expensive
  to make in week two.

Three `UnavailableReason` cases exist and all three are real on a user's
device: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`.
**Unavailability is a first-class state of this seam, not an error path.**

## 71. The one hard problem: a stream that can unsay what it already said

`SpeechPhraser` concatenates **verbatim** — `buffer += token`. That is not
an implementation detail; it is the contract that lets a reply be spoken
without lying about what was generated.

Apple's `streamResponse` does not yield tokens. It yields
`ResponseStream<String>.Snapshot`, and `Snapshot.content` for `String` is
a `String` (because `PartiallyGenerated` defaults to `Self`). The
swiftinterface carries **zero doc comments**, so the shape is not stated
anywhere Apple ships — it must be measured.

If snapshots are cumulative — `"The"`, `"The capital"`, `"The capital of"`
— then feeding them verbatim would speak:

```
   "The"  "The capital"  "The capital of"  "The capital of France"
   → spoken: "The The capital The capital of The capital of France"
```

So an adapter must DIFF consecutive snapshots and emit only the new
suffix. And that diff is safe **only if every snapshot strictly extends
the one before it.** If the model can ever revise text it already emitted,
the adapter may have already handed those words to a mouth — and **audio
cannot be unsaid.** A reply is spoken into a room in real time; there is
no backspace.

That is this milestone's D-015-shaped question, and AC-111 answers it with
a measurement rather than an assumption.

## 72. Acceptance criteria (4f)

- **AC-110 THE AVAILABILITY GATE, on BOTH machines, before any adapter
  code.** The probe runs on this Mac and on the iPhone, and both answers
  are recorded in INSTRUMENTS.md whichever way they fall. All three
  `UnavailableReason` cases are handled and shown honestly in the demo —
  a person whose device cannot run the model is told which of the three
  reasons applies, not given a silent dead button.
- **AC-110 STATUS NOTE, measured en route (2026-08-18, iOS Simulator):**
  **the availability enum can LIE.** A Simulator running this Mac's SDK
  answered `.available` — and then EVERY generation threw:
  `GenerationError` wrapping `SensitiveContentAnalysisML Code=15` wrapping
  `ModelManagerServices.ModelManagerError Code=1026`, which is the model
  manager failing to produce assets the availability check had just
  vouched for. So availability is a NECESSARY gate, not a SUFFICIENT one:
  the adapter must treat a failed generation as its own unavailability
  signal, and the demo must not promise a mind it has not heard speak.
  Found by the probe's FIRST run — which also caught the probe itself
  showing a green "strictly extending ✓" over ZERO snapshots, a verdict
  with no evidence. Both are fixed and the probe now refuses to speak
  under two snapshots.

- **AC-111 THE STREAM SHAPE, MEASURED — the milestone's gating number.**
  *(status: MEASURED on the iPhone, 2026-08-18 — one run, four prompts,
  23 snapshot pairs: cumulative, strictly extending, zero revisions, zero
  grapheme splits. INSTRUMENTS §22. The Mac joins when its download
  completes. F-1 is now READY FOR RULING on this number.)*
  On real hardware, over a set of prompts: is `Snapshot.content`
  cumulative? Does every snapshot strictly extend its predecessor
  (`new.hasPrefix(old)`)? Does a revision EVER occur? Does a snapshot ever
  split a grapheme cluster? The result is recorded either way, including
  "it revises, so the naive diff is unsafe", which is a result and not a
  failure. **F-1 cannot be ruled until this is measured.**
- **AC-112 The adapter behind the seam.** A `ReplyGenerating` /
  `ReplyRun` implementation over `LanguageModelSession` that emits
  `.token` updates the phraser can concatenate verbatim, then exactly ONE
  terminal, then ends its stream — the same contract every other run in
  this library keeps.
- **AC-113 Cancellation obeys the turn ticket, and it is MEASURED.** A
  barge kills the generation. Does cancelling the iterating task actually
  stop the model, or does it keep computing? How long until `isResponding`
  clears, after a normal end and after a cancel? Does a cancelled partial
  turn still consume the context budget? The ticket remains the guarantee
  (D-034's law, for the third time); cancellation is the optimisation, and
  a defiant-mock test proves a dead turn's late token cannot reach a mouth.
- **AC-114 The failure surface is mapped, not swallowed.** All NINE
  `GenerationError` cases — `exceededContextWindowSize`,
  `assetsUnavailable`, `guardrailViolation`, `unsupportedGuide`,
  `unsupportedLanguageOrLocale`, `decodingFailure`, `rateLimited`,
  `concurrentRequests`, `refusal` — reach an honest outcome. Both that
  enum and `UnavailableReason` are **non-frozen**, so every switch carries
  `@unknown default` or the build fails under warnings-as-errors. No test
  asserts on `Context.debugDescription`: it is an unlocalised string Apple
  may change.
- **AC-115 The first reply does not freeze the turn loop.** This is 4e's
  blocker 3 arriving one seam over: `modelInstalled()` only stats files,
  the pipeline was built lazily by the first call, and the coordinator
  awaits its handlers INLINE on one serial loop — so the first turn froze
  the whole conversation. `prewarm(promptPrefix:)` exists; where it is
  called is a correctness question, and the felt-pause number must not
  silently contain a model warm-up.
- **AC-116 The context budget is known, not discovered.** `contextSize` is
  **4096**, read from the machine. A conversation that exceeds it must
  fail honestly and recoverably rather than dying mid-turn, and what the
  person sees is specified.
  *(status note, forced by the 4f review, which found the specification
  promised here written NOWHERE: here it is. On `exceededContextWindowSize`
  the run reports one `.failed` whose text names the context window; the
  coordinator ends the turn as `turnFailed`, which the demo shows as the
  utterance's failure line. RECOVERY is structural: sessions are per-turn
  (D-057 F-2 = A), so the next turn starts with a fresh budget — only a
  single thought too large for 4096 tokens can never be answered, and it
  fails with the same named text every time rather than dying mid-turn.
  Pinned by the forged-error test; not yet produced with a REAL over-long
  prompt on hardware, and that is owed alongside AC-113's numbers.)*
- **AC-117 The slice, on real hardware (§3.7).** The iPhone hears a spoken
  question, thinks on-device, and answers out loud through either mouth,
  with the felt pause measured and written down — and with the whole reply
  cancellable by a barge, proven in the field, not only in tests.
  *(status: MET, both mouths, in the field — Apple mouth 542/567 ms felt
  pause, neural mouth 524 ms, barges landing through both, offline
  answers proven. The same run finally measured the iPhone's neural RTF
  at 1.21 — the number 4e's AC-102/AC-104 owed — and it is above 1.0,
  which validates D-055 and names the voice milestone's first task.
  INSTRUMENTS §22.)*
- **AC-118 Hygiene.** Swift 6 strict, zero warnings in debug AND release
  with `-warnings-as-errors`, 20× stable, ARCHITECTURE.md updated, and the
  code adversarially reviewed BEFORE the merge (D-041).

## 73. Test matrix (4f)

| Area | Tests |
|---|---|
| The seam contract | a reply conformance kit — the `EngineConformanceKit`/`SynthesizerConformanceKit` pattern, one seam over: tokens then exactly one terminal, cancel ends without a terminal, nothing survives the cancel |
| The snapshot diff | a scripted snapshot source (the `TTSDecoding` precedent — an injectable seam so the vendor is not required to misbehave on demand): cumulative snapshots become correct deltas · a REVISING snapshot is handled per the F-1 ruling · an empty reply terminates |
| Availability | each of the three `UnavailableReason` cases produces an honest, named outcome · `@unknown default` is exercised |
| Failure surface | each `GenerationError` case mapped, guardrail refusal treated as a legitimate reply per F-4 · unknown-case bucket |
| Cancellation | a barge mid-generation: the turn ticket kills it, a defiant late token reaches no mouth |
| Liveness | a reply that ends before any token still terminates the turn — the promise the phraser and both mouths already keep |
| Coordinator | the whole 4a–4e suite green with the real generator substituted where it can be |
| Warm-up | the first reply does not block the coordinator's serial loop (AC-115) |

## 74. The design forks (4f) — for Ryad to rule

*(Ruled 2026-08-18, D-057: F-2 = A, F-3 = A, F-4 = A, F-5 = A,
F-6 = A — all five on the recommendations. F-1 was ruled the same day
the iPhone's measurement arrived: **A + tripwire**, D-058 — the diff,
with every snapshot CHECKED, because a platform that can lie about
availability earns a check on its stream shape.)*

- **F-1 HOW A SNAPSHOT BECOMES A TOKEN.** A: diff consecutive snapshots
  and emit the new suffix — smallest, and correct *only if* the stream is
  strictly prefix-extending. B: do not stream at all, use `respond` and
  emit the whole reply as one token — safe against revision, but the felt
  pause absorbs the entire generation and the `SpeechPhraser`'s whole
  reason to exist dies with it. C: diff, but hold back the tail — emit
  only up to the last SAFE boundary (a completed word or clause) and let
  the next snapshot confirm it — costs a little latency, buys immunity to
  a late revision. **Recommendation: ruled by AC-111's measurement, not
  now.** If the stream strictly extends, A. If it ever revises, C. B is
  the fallback if the phone's latency makes streaming pointless. *A fork
  whose ruling is gated on a number is the honest shape here; guessing it
  is exactly how a reply speaks a word it must then contradict.*
- **F-2 WHERE THE SESSION LIVES.** A: one `LanguageModelSession` per
  turn — stateless, and the `TranscriptLedger` already holds the whole
  thought, so the context the model needs is assembled by us and visible.
  B: one long-lived session carrying multi-turn memory — richer, but the
  budget is 4096 tokens, a barge can collide with `concurrentRequests`,
  and a cancelled turn may still consume budget. **Recommendation: A**,
  with multi-turn memory named as its own later milestone rather than
  smuggled in here.
- **F-3 WHAT THE MODEL IS TOLD.** A: a short instruction shaping replies
  for SPEECH — brief, no markdown, no bullet lists, no headings — because
  this reply is spoken aloud, never read. B: no instructions, take the
  default. **Recommendation: A.** A spoken reply has different constraints
  from a written one, and this is the one place that difference can live.
  The instruction text itself belongs in the app, not the library
  (mechanism, not policy — D-027's rule).
- **F-4 WHAT A REFUSAL SOUNDS LIKE.** The model can refuse, and
  `guardrailViolation` / `refusal` are ordinary outcomes, not crashes.
  A: speak an honest short sentence and complete the turn normally. B:
  treat it as a turn failure — silence, and the person cannot tell a
  refusal from a bug. **Recommendation: A.**
- **F-5 WHERE IT LIVES.** A: in core `MultiModalKit`, beside
  `AppleSpeechEngine` — Foundation Models is a SYSTEM framework, not a
  package dependency, so the "core keeps zero runtime dependencies" vow
  (D-016) is untouched, and the precedent is exact. B: a new opt-in
  product. **Recommendation: A**, on the `AppleSpeechEngine` precedent.
- **F-6 THE MLX CONTENDER — deferred, and here is the measured reason.**
  D-017's doctrine says two real implementations turn a seam from a claim
  into a proof, so a second engine is wanted. But MLX was spiked and
  **it cannot run from a SwiftPM command-line binary**: `swift run` dies
  with `Failed to load the default metallib`, and mlx-swift's own README
  says SwiftPM cannot build the Metal shaders. This repo's CI *is*
  `swift build` + `swift test -Xswiftc -warnings-as-errors`, and the
  bake-off is a SwiftPM executable. So MLX would compile everywhere and
  RUN nowhere in the current toolchain — a green build that cannot
  generate one token, which is the lying-instrument problem this repo
  names. D-023's fourth question fails in a new way: the *code* is
  removable in a day behind `ReplyGenerating`, but the *build system* is
  not behind the protocol at all. A: defer MLX to a later bake-off
  milestone behind a time-boxed spike gate — run OUTSIDE the repo, no
  `Package.swift` line until it passes, result logged as a D-entry
  either way. B: adopt it in 4f and change the CI story now.
  **Recommendation: A.** The honest cost of A, stated: 4f ships a seam
  with ONE real citizen, which is weaker than this repo's own standard,
  and a hostile reviewer may say so. *Watch item:* `mlx-swift-lm` now
  ships `MLXFoundationModels`, which drives an MLX model through Apple's
  own `LanguageModelSession` — if that matures, the bake-off gets one
  adapter and two backends, which is the shape this repo argues for. It
  needs the 27.0 SDK and does not build against the current beta.

## 75. Out of scope for 4f (deliberately)

Multi-turn conversational memory (its own milestone, per F-2) · tool
calling and `@Generable` structured output · the echo ROUTING fix, which
is now **4g** (D-056) · MLX adoption beyond the spike gate · reply quality
scoring or a model bake-off · SpeakerKit · anything served from a network.

## 76. Definition of done (4f)

The availability probe run on BOTH devices and recorded BEFORE any adapter
code (AC-110) · the stream shape measured and F-1 ruled on that number,
not on an argument (AC-111) · all ACs green · 20× stable · zero warnings
debug and release · code adversarially reviewed BEFORE the merge (D-041) ·
PR merged with the map updated · the forks logged as D-entries ·
teach-back survived.

# SPEC — Milestone 4g: the speaker route (the echo canceller finally sees the reply)

## 77. What 4g builds, and why it is next

The demo carries a warning label written by a measurement: *"On speaker
the reply is not cancelled (measured peak 1.0) — it will interrupt
itself."* D-043 measured the disease exactly: the iPhone's echo canceller
works — it took the quiet room from peak 0.0092 to 0.0030 — and the reply
on the loudspeaker reaches the microphone at **full scale, untouched**,
because iOS voice processing cancels only what its OWN audio unit
renders. Both mouths render elsewhere: the neural voice on its own
engine, Apple's inside `AVSpeechSynthesizer`'s private route.

4g routes the reply onto the capture engine's voice-processing unit so
the canceller can see it. The seam already exists — AC-108 built
`MicrophonePlaybackHost` and the `hostsPlayback` switch in 4e, and D-049
switched it off after five faults on real hardware. What was never taken
is the measurement that decides everything: **AC-104, "does a reply
rendered through the pipeline's own engine fall under the gate?" — asked
in 4e, never answered.** This milestone begins by answering it.

## 78. What is KNOWN, what is GUESSED, and what only a phone can say

Known, measured: the disease (D-043) · the Mac cannot host voice
processing and an output chain on one engine (`-10875`, INSTRUMENTS §17)
· §17's own caveat that a two-device Mac cannot convict a one-device
phone · the graph-order faults of 4e, each named and fixed.

Unknown, and stated before proposing (D-054 rule 3): **(a)** whether an
iPhone accepts voice processing + an output chain on one engine at all —
the five faults are equally consistent with the ordering bugs that were
found and fixed; **(b)** whether a reply rendered there is actually
CANCELLED (AC-104 proper); **(c)** whether the Simulator's voice
processing behaves like the device's. The Simulator can answer the GRAPH
question (does it start, are formats sane) and I can drive it myself;
only the phone can answer the CANCELLATION question, and if (a) or (b)
comes back negative, F-1's fallbacks are already priced. **Who pays if
the guess is wrong without the measurement: Ryad, in field trips — which
is exactly what D-054 exists to prevent.**

## 79. Acceptance criteria (4g)

- **AC-119 THE GATE, measured before any fix (AC-104 at last).**
  *(status: PASSED, 2026-08-20, on the phone — the graph runs isolated,
  and an audible tone rendered on the capture engine reached the mic at
  peak 0.01–0.07 against the disease's 1.0000. INSTRUMENTS §23. The
  mechanism for AC-120 is arrangement 3's: hosted rendering plus
  restart-on-configuration-change.)* First
  the Simulator, driven by the machine: `hostsPlayback` on, capture
  running, a reply rendered on the capture engine — does the graph START,
  with sane formats? Then the phone, once, with the echo probe:
  **is the hosted reply removed by the canceller?** The numbers land in
  INSTRUMENTS whichever way they fall. A negative answer reshapes the
  milestone into F-1's fallbacks and is a result, not a failure.
- **AC-120 The slice: the neural mouth on the speaker route.**
  *(status: FIELD-PROVEN for its first two clauses, 2026-08-20 — "it
  works, no self barge, i can still interrupt it"; the residual stayed
  under the 0.021 gate for a whole conversation. The third clause — the
  felt pause RE-MEASURED on this route — was flagged by the review as
  unrecorded, truthfully: it rides the parked field investigation.
  INSTRUMENTS §23.)* The
  neural voice already renders through `PlaybackHost`; behind the
  switch it renders on the capture host. On the phone, on SPEAKER: a
  reply does not barge itself, a human barge still lands, and the felt
  pause is re-measured on that route.
- **AC-121 The Apple mouth follows, via its PCM.**
  *(status: BUILT and kit-certified live on the Mac; field: works on the
  shielded loudspeaker with an INTERMITTENT self-barge — suspects and the
  convicting instruments recorded in INSTRUMENTS §23, investigation
  parked with Ryad. The stranded-write leak a review claimed was MEASURED
  real — stopSpeaking delivers no terminator — and fixed with a take-once
  continuation.)*
  `AVSpeechSynthesizer.write(toBufferCallback:)` hands us buffers
  instead of playing them; a run renders them through the same host.
  `.started`/`.finished` become OUR rendering evidence (D-029's rules),
  the conformance kit applies unchanged, and the write-path's timing
  quirks are measured on the Mac before any phone build.
- **AC-122 The graph laws under voice processing are pinned by harness.**
  *(status: MET — the shield matrix lives in the demo toolbar as the
  permanent regression harness; voice-onmic keeps the Mac's §17 truth
  table; graph-probe keeps the node laws.)*
  `voice-onmic` (and a Simulator probe where the Mac's two-device
  reality lies) carries the hosted arrangement as permanent regression
  checks: the §16–§19 faults must stay findable in minutes, never again
  by field trip.
- **AC-123 Honest degradation.**
  *(status: NOT MET, carried openly — the fallback-to-unhosted path is
  not built. What exists instead: a hosted graph that fails to START now
  cleans up its arms and surfaces the error visibly (the review's one
  confirmed finding, the zombie restart box, fixed), and a mid-run stop
  is counted and restarted. Falling back LOUDLY to the unshielded
  arrangement remains future work, recorded here rather than re-scoped.)* On a device where the hosted graph
  cannot start, the pipeline falls back to today's arrangement LOUDLY —
  a health event and a visible caption ("speaker route unprotected") —
  never a silent difference in behavior.
- **AC-124 Hygiene + the label.**
  *(status: PARTLY — the label now states the honest in-between: the
  probe's measured range beside the old 1.0, and that the reply's own
  number is still owed. The full rewrite waits on the parked field
  investigation (gate experiment, echo? peaks). Hygiene gates all green.)* The demo's speaker warning is
  rewritten by MEASUREMENT — the new peak-under-cancellation number next
  to the old 1.0, not a deleted sentence. Swift 6 strict, zero warnings,
  20× stable, map updated, review before merge (D-041), teach-back.

## 80. Test matrix (4g)

| Area | Tests |
|---|---|
| Graph mechanics | Simulator probe: hosted arrangement starts, formats valid, capture alive — machine-driven, before any phone build |
| The canceller | the phone's echo probe on the hosted route (AC-119): peak while speaking, before/after — the one number that decides the milestone |
| Neural on capture host | existing `NeuralVoiceConformanceTests` + `PlaybackHostTests` unchanged — the host swap must change NOTHING behind the seam |
| Apple mouth via write() | conformance kit against the write-path run (Mac-testable: write() exists on macOS) · evidence timing measured, not assumed |
| Degradation | a scripted host that refuses: the pipeline falls back loudly, health event published (D-059's road, reused) |
| Regression | voice-onmic keeps the §17 truth table; the -10875 row stays recorded as this Mac's fact |

## 81. The design forks (4g) — for Ryad to rule

*(Ruled 2026-08-19, D-060: F-1 = A, F-2 = A, F-3 = B, F-4 = A — all on
the recommendations. AC-119 measures before anything ships.)*

- **F-1 THE MECHANISM.** A: render replies on the capture engine's
  voice-processing unit — the only path D-043's measurement endorses,
  and AC-108 already built its seam. B: software suppression — raise the
  VAD gate while the assistant speaks. Honest cost: the echo arrives at
  peak 1.0, indistinguishable by level from a human barge, so B kills
  speaker barge-in — the product's soul — to stop self-barging. C:
  half-duplex — mute the mic while speaking. Kills barge-in entirely.
  **Recommendation: A**, with B recorded as the fallback if AC-119
  refutes A on this hardware — and if it comes to B, the label must say
  what was traded.
- **F-2 THE APPLE MOUTH.** A: route its PCM through our host via
  `write(toBufferCallback:)` — one rendering path for every mouth,
  forever, and the canceller sees them all. B: leave Apple's mouth
  receiver-only, documented. **Recommendation: A, gated on AC-119/120
  succeeding** — B is not a fix, it is a smaller warning label.
- **F-3 WHEN THE HOST IS THE CAPTURE ENGINE.** A: per-route — hosted on
  speaker, today's arrangement on receiver. B: hosted whenever the
  conversation runs, one configuration. **Recommendation: B.** Route
  churn on a live graph is what cost 4e an afternoon (the D-052
  rejection said exactly this), and one arrangement is one set of bugs.
- **F-4 WHAT THE SWITCH DEFAULTS TO in the library.** A: `hostsPlayback`
  stays default-off; the app opts in (mechanism/policy, D-027). B:
  default-on once proven. **Recommendation: A** — 4g proves it on ONE
  device; a library default claims every device, and that claim needs
  more phones than this project owns.

## 82. Out of scope for 4g (deliberately)

Voice quality and the phone-derived lead (D-050's milestone, its number
waiting) · multi-turn memory · MLX · SpeakerKit · AC-113's numbers and
the over-budget prompt (carried, named) · the Mac's stuck model download.

## 83. Definition of done (4g)

AC-119's numbers recorded BEFORE any fix lands (D-054's order) · all ACs
green or honestly re-scoped by AC-119's answer · 20× stable · zero
warnings both configurations · the label rewritten by measurement ·
review before merge (D-041) · forks logged · teach-back survived.

# SPEC — Milestone 4h: the second mind (the seam's second real citizen, and the token that cannot be unspoken)

## 84. What 4h builds, and why it is next

4f built the mind seam and shipped it with ONE real citizen. The spec
said so itself, in F-6's own honest cost: *"4f ships a seam with ONE
real citizen, which is weaker than this repo's own standard, and a
hostile reviewer may say so."* D-017's doctrine is that two real
implementations turn a seam from a claim into a proof. The ear has two
(Apple, Whisper). The mouth has two (Apple, TTSKit). The mind has one.

4h gives the mind its second citizen: a model whose weights sit on the
device and belong to the user, driven by MLX, behind the same
`ReplyGenerating` protocol the Apple mind implements — and made to pass
the same five conformance promises, unchanged.

The seam it must fit is two requirements and nothing else:

```swift
public protocol ReplyGenerating: Sendable {
    func openReply(to transcript: String) async throws -> any ReplyRun
}
public protocol ReplyRun: Sendable {
    var updates: AsyncStream<ReplyUpdate> { get }   // .token / .finished / .failed
    func cancel() async
}
```

Note what is NOT in that list. `ReplySnapshotStreaming` — the cumulative
snapshot sub-seam — is internal, and it exists only because Apple's API
streams the whole reply again and again. MLX emits tokens. **The second
mind fits the public seam more directly than the first one does**, and
it needs no `SnapshotDiffer`. That is a small piece of evidence that the
seam was drawn in the right place, and it should be said out loud.

## 85. What the GATE settled, what it could not, and what only a device can say

D-057's F-6 = A deferred MLX behind a time-boxed spike gate, run OUTSIDE
the repo, with no `Package.swift` line until it passed. The gate ran
(INSTRUMENTS §24, STAGES 1–3). It is now answered, and 4h starts from
its answers rather than from the assumptions F-6 had to make.

**KNOWN — measured, on this hardware:**

| Question | Answer | Where |
|---|---|---|
| Can `swift test` run MLX? | **yes**, with a 3.6 MB `default.metallib` in the working directory | §24 STAGE 1 |
| Does it generate? | **yes** — 67 ms to first token, Qwen3-0.6B-4bit | §24 STAGE 2 |
| Does hosted CI pay 688 MB per run? | **no** — `macos-26` ships the toolchain and links a metallib in a 15 s job | §24 "The runner's answer" |
| Can the iOS Simulator run MLX? | **no, structurally** | §24 STAGE 3 |
| Is `MLXFoundationModels` (F-6's watch item) ripe? | **no** — absent from mlx-swift-lm 3.31.4, read from the checkout | this spec |

**F-6 was half right, and the halves are now named.** Its objection was
"compiles everywhere, runs nowhere." For `swift test` and for CI that is
refuted. For the iOS Simulator it is exactly true, and no flag fixes it:
MLX asks Metal for a heap with `ResourceStorageModeShared` because it
assumes unified memory, and the Simulator's driver requires `Private`.
Choosing `Device.cpu` does not help — MLX picks its allocator at build
time. **F-6 earned that half, and this spec records it as earned.**

**GUESSED — not measured, and treated as unknown:**

- Speed on a phone. The Mac's 67 ms says nothing about a device under
  thermal pressure with 334 MB of weights resident.
- Whether a 0.6B model's replies are worth speaking. STAGE 2's own
  caveat: the spike's tokenizer was approximate, so judging reply
  QUALITY from that run "would be dishonest."
- Memory pressure beside a live audio graph, a recogniser and a mouth.

**What only a device can say.** The phone number needs a build signed
with Ryad's team. That is the one measurement in this milestone that
cannot be taken by the machine, and AC-130 is written so the milestone
still lands if it is never taken — the bake-off records the Mac's
numbers and says plainly that the phone's are missing.

## 86. The one hard problem: the seam has no undo — three layers, not one heroic filter

*(Rewritten 2026-08-21, after measurement. The first draft of this
section — preserved in commit `ae78681` — built the milestone around a
case this model's vocabulary makes impossible. A second agent's review
put the question, the machine answered it, and the answer is below. The
spec is normally append-only; this section was still unsigned, so it is
corrected in place rather than left standing as a known error.)*

**What stands.** `ReplyUpdate` has no retraction, by design, because the
token has already left for the mouth. Whatever the adapter emits is
spoken. That is still the law this milestone is built on.

**What does NOT stand.** The first draft said the filter must reassemble
a tag split across deltas — `<`, `th`, `ink`, `>` — and made that
reassembly the milestone's hard problem. Measured in the model's own
`tokenizer_config.json`:

```
  <think>   = token 151667   ── single special tokens in the vocabulary.
  </think>  = token 151668      the tokenizer emits each as ONE unit,
                                so they are never split across deltas.
```

and `MLXLMCommon`'s `TokenIterator.next() -> Int?` is public, so the
adapter sees those ids **before any text exists**. For this model the
split-tag case cannot occur. It was reasoned, not measured, and D-054
exists precisely to stop that.

**The measured answer is three cheap layers, not one clever one.** They
fail in different directions, which is why they are worth having
together rather than choosing between:

```
  LAYER 1 — do not think at all.          cost: nothing.
    Qwen3's chat template:                fails if: the model ignores
      {%- if enable_thinking is false %}            the convention.
          {{- '<think>\n\n</think>\n\n' }}
    It PRE-FILLS a closed block so the model starts past its reasoning.
    A convention, NOT a decoding constraint. Nothing structurally
    prevents a second <think>.
                    │
                    ▼
  LAYER 2 — the exact net, at token ID.   cost: backend-specific.
    if id == 151667 { swallowing = true } fails if: the marker is not
    if id == 151668 { swallowing = false }         a special token.
    Impossible to bypass by tokenisation. No string ever forms.
                    │
                    ▼
  LAYER 3 — the general net, on text.     cost: LATENCY.
    Only for models whose markers are     fails if: nothing — but see
    ordinary text. THIS is where "never             the cost.
    emit what you might retract" lives.
```

**Layer 3's cost is the one this project cares about most.** Holding
`<` back to see whether it becomes `<think>` delays the mouth. This repo
has spent two milestones measuring a felt pause of 542–567 ms; a filter
that buys safety with milliseconds of hold is not free here, and it must
be paid for only when a model actually needs it.

**So the milestone's difficulty moved, and that is an honest gain rather
than a loss.** The reasoning problem got small and exact. What is left
genuinely hard in 4h is not the filter at all:

1. **The build system, which is not behind the protocol.** F-6 said it
   first and it is still true: without a metallib MLX does not fail a
   test, it **aborts the process mid-run**. A crashing runner cannot
   report, which is why AC-129 exists.
2. **334 MB, resident.** Measured: there is no `mmap` anywhere in MLX's
   C++ core — it does not memory-map safetensors. The weights sit in
   memory beside a live audio graph, a recogniser and a mouth. On a Mac
   that is nothing. On a phone it is a real question, and it is one more
   thing only a device can answer.

## 87. Acceptance criteria (4h)

- **AC-125 The reply is speakable at the TOKEN, not the string.**
  *(status: MET — `ThinkGate` green and proven non-inert by three
  mutations; ids READ from `tokenizer_config.json`. PARTIAL on one point
  the 4h review raised and D-063 accepts as open: the gate is proven in
  isolation and its door proven wired, but no test drives a defiant
  `<think>` from the REAL model through the REAL detokenizer.)* Layers
  1 and 2 of §86, and deliberately nothing more. The adapter asks the
  model not to think — `enable_thinking` false, which pre-fills a closed
  block — and gates on the vocabulary's own ids so reasoning never
  becomes a string at all. Three proofs, and the third is the one that
  matters: thinking suppressed end to end on the real model; a DEFIANT
  `<think>` emitted anyway is still swallowed, because layer 1 is only a
  convention and layer 2 is the net; and the gate's own control — remove
  the gate and reasoning MUST reach the output, or the test was proving
  nothing. The ids are READ from the model's `tokenizer_config.json` at
  load (151667 / 151668 for this model), never hard-coded: a model whose
  vocabulary differs must fail loudly rather than quietly speak its
  reasoning aloud.
- **AC-126 The MLX mind is the seam's second REAL citizen.**
  *(status: MET — all five `ReplyConformanceKit` promises pass with the
  kit UNCHANGED and no argument the Apple mind did not also pass. Four
  mutations bite; the fifth, the retire latch, is masked by `finish()`
  and recorded as measured redundancy rather than dressed up.)* An
  `MLXReplyGenerator: ReplyGenerating` in its own opt-in product. It
  passes all FIVE promises of `ReplyConformanceKit` — tokens then
  exactly one terminal; cancel ends the stream without a terminal;
  nothing after the cancel survives (gated defiance); `openReply` hands
  off without blocking; a failure is one honest terminal — the same five
  the Apple mind passes, with the kit unchanged. If the kit needs a
  change to admit the second citizen, that change is a finding about the
  kit and gets written down.
- **AC-127 The core's zero-dependency vow survives, mechanically.**
  *(status: MET, and the guard itself was tested after the review claimed
  it could not fail: adding `import MLXLLM` to a core file makes
  `swift build --target MultiModalKit` fail. Core-alone build 1.08–2.84 s
  throughout.)* CI
  already builds the core ALONE (`swift build --target MultiModalKit
  -Xswiftc -warnings-as-errors`) before anything else, which is the
  vow's enforcement rather than its restatement. That step stays green,
  and no MLX symbol is reachable from `MultiModalKit`. D-016's tier 1 is
  untouched: the new dependencies live only in the opt-in product.
- **AC-128 A real token, from the real model, inside `swift test`.**
  *(status: MET — "The capital of Italy is Rome." from Ryad's own weights.
  Cold 1.93 s, WARM 0.27 s, and the field session on the phone gave
  291–315 ms across 38 turns. Skips now ANNOUNCE themselves; they used to
  print "passed".)*
  Env-gated the way this repo already gates live tests ("model required;
  skips if absent", `MMK_LIVE_SYNTH`'s pattern): with metallib and
  weights present, the MLX mind generates and the conformance promises
  hold against the REAL model, not a script. The numbers land in
  INSTRUMENTS.
- **AC-129 A missing metallib SKIPS; it does not kill the runner.**
  *(status: MET, and the guard was WRONG TWICE before it was right — both
  times a false positive, once accepting `Vision.framework`'s own
  metallib. Control run both ways: removed → 5 skip, green in 0.140 s;
  restored → real reply.)*
  §24's C1 measured that MLX aborts the process when the artefact is
  absent. Proven by running the suite deliberately WITHOUT it and
  observing a clean skip and a green run — the control that proves the
  guard is switched on, in the shape D-054 requires of any instrument.
- **AC-130 The bake-off: two minds, one question, measured.**
  *(status: MET — `bakeoff mind-off`, and it found something the spec had
  not anticipated: loading is not warming. Apple's rows are empty and say
  why, which is a result rather than a gap.)* The
  existing `bakeoff` tool gains a mind comparison: Apple against MLX on
  identical prompts — time to first token, tokens per second, and
  whether the reply is speakable at all (how much of it was `<think>`).
  Recorded with the caveats §24 already wrote about tokenizer fidelity,
  and with the phone's absence stated rather than implied.
- **AC-131 The demo offers the third mind, and says honestly when it
  cannot run it.**
  *(status: MET and field-proven — the picker, the honest simulator
  refusal at COMPILE time, and the model chooser F-1 = C added. The
  review found the memory guard on the button rather than the load, which
  was a crash loop; fixed.)* `MindChoice` gains a local case. On a platform that
  structurally cannot run MLX (the Simulator, §24 STAGE 3) it reports an
  unavailable sentence through the machinery AC-110 already built — it
  does not vanish from the picker and it does not crash. An instrument
  that shows a number must be able to say whether it is switched on.

## 88. Test matrix (4h)

| Criterion | Test | Needs a model? |
|---|---|---|
| AC-125 | `ThinkGateTests` — a defiant `<think>` is swallowed (scripted ids) | no |
| AC-125 | the removed-gate control — without it, reasoning reaches output | no |
| AC-125 | ids READ from `tokenizer_config.json`, never hard-coded | config only |
| AC-126 | `ReplyConformanceKit`'s five promises, scripted MLX source | no |
| AC-127 | CI's core-alone build step; a test that core imports nothing | no |
| AC-128 | `MLXMindLiveTests` — env-gated, real weights; thinking suppressed end to end | **yes** |
| AC-129 | suite run with the metallib absent → skip, not abort | no (proves absence) |
| AC-130 | `bakeoff mind-off` output recorded in INSTRUMENTS | **yes** |
| AC-131 | demo picker unavailability sentence; Simulator run | no |

The column on the right is the honest one: **seven of nine rows need no
weights at all** — six need nothing but source, and one needs only the
tokenizer's small config file, not the 334 MB. That is deliberate. If a
reviewer's machine has no metallib and no weights, the milestone's logic
is still machine-checked; only its speed claims and the live end-to-end
suppression go unproven.

## 89. The design forks (4h) — ruled

*(RULED 2026-08-21, D-062: F-1 = A, F-2 = B, F-3 = A, F-4 = A,
F-5 = A — all five on the recommendations, and on the MEASURED
versions below rather than the first draft's. The gate itself is
closed by D-061.)*

*(Rewritten 2026-08-21. The first draft's F-2 rested on §86's refuted
premise, and its F-4 contradicted this repo's own Whisper precedent. A
second agent's review raised eleven further options; the ones that
survived measurement are folded in below and credited where they won.
The original list stands in commit `ae78681`.)*

- **F-1 WHICH SECOND MIND.** A: MLX directly — `MLXLLM` +
  `MLXLMCommon`, plus a real tokenizer. B: wait for
  `MLXFoundationModels`, which would drive an MLX model through Apple's
  own `LanguageModelSession` — one adapter, two backends, the shape this
  repo argues for. C: **llama.cpp** instead of MLX. D: defer the second
  mind again.
  **Recommendation: A.** B was checked rather than assumed: the module
  is ABSENT from mlx-swift-lm 3.31.4, read from the checkout. It is not
  a choice today, it is a wish. C deserves more than the dismissal it
  usually gets, and its real argument is NOT the one usually offered:
  claims about thermals and Metal integration are asserted without
  evidence and are ignored here. Its one serious advantage is that
  llama.cpp compiles its Metal shaders from embedded source **at
  runtime**, which would make F-3 — this milestone's genuine build
  problem — disappear entirely. **That advantage is UNMEASURED.** It is
  written here as a claim, not a finding, and it must not be ruled on as
  if it were evidence. If it matters to the ruling, it is gated exactly
  as MLX was gated: spiked outside the repo first, result logged either
  way. The honest costs of C, if it were taken: C++ interop inside a
  Swift 6 strict-concurrency library, and a second build system to
  learn — against a stack that is Apple-native everywhere else.
- **F-2 HOW THE REPLY IS MADE SPEAKABLE.** *(options replaced — the old
  A/B/C were built on §86's refuted premise.)* A: all three of §86's
  layers. B: layers 1+2 only — the prompt switch, plus the token-ID gate
  inside the MLX adapter; no core component at all. C: layer 3 only — a
  string filter in core, which is the first draft's answer and is now
  known to be redoing work the vocabulary already does exactly. D:
  layer 1 only — trust `enable_thinking` and filter nothing.
  **Recommendation: B, with layer 3 deferred until a model needs it.**
  Layers 1 and 2 are small, exact and measurable today. Layer 3 is a
  general solution to a problem no model in this project currently has,
  and this repo has a rule for exactly that: D-053's "public surface is
  earned by a second REAL one." A general text filter is earned by a
  second model whose markers are ordinary text — not by imagining one.
  D is rejected on its failure mode: a convention is one model update
  away from a phone reading its own reasoning aloud, and the cost of
  layer 2 is a single integer comparison.
- **F-3 THE METALLIB — where the 3.6 MB artefact comes from.** A: built
  in CI by the preinstalled toolchain and by a documented local script;
  live tests skip when it is absent. B: vendor the binary into git.
  C: no live MLX tests — only the demo runs it. D: host the artefact
  outside git (a release asset) and fetch it in a build step.
  **Recommendation: A, with D as the named fallback** if contributor
  friction turns out to be real. §24 already argued against B in a repo
  whose method is reproducibility, and C leaves the adapter's real path
  never machine-checked. D's honest costs, stated because they are easy
  to miss: it puts a network fetch inside the build, and the artefact
  must match the mlx-swift version EXACTLY — so it needs a checksum and
  a version pin, or it becomes a machine that returns wrong answers
  quietly. Two further options were raised and are rejected on
  measurement rather than taste: compiling the shaders at launch is not
  available for MLX — the kernels are excluded from the SwiftPM build
  and are not exposed as source to compile (that trick belongs to
  llama.cpp, see F-1 C); and shipping an xcframework does not fit,
  because SwiftPM's checksummed binary mechanism takes xcframeworks and
  artifact bundles, not a bare shader library.
- **F-4 THE WEIGHTS — and a correction to the first draft.** The first
  draft recommended "the library never reaches the network." That was
  wrong **on this repo's own terms**, and the review caught it.
  `MultiModalKitWhisper` already downloads ~142 MB from Hugging Face,
  and its `modelInstalled()` doc states the doctrine precisely: *"no
  download is ever triggered by asking"*, and "installed" means
  OFFLINE-CAPABLE — it checks the tokenizer files too, because an audit
  found WhisperKit silently falling back to the network. So the real
  rule here is not abstinence. It is: **a download is allowed inside an
  opt-in product when it is explicit, idempotent, and never provoked by
  a question.** A: the MLX product follows Whisper exactly — its own
  `modelInstalled()` and `ensureModel()`, same semantics, same honesty
  about what "installed" means. B: caller supplies a path, no download
  anywhere. C: a separate models package serving both engines.
  **Recommendation: A.** The precedent exists, it has already been
  audited once in the field, and one shape is one set of bugs — which is
  D-060 F-3's reasoning applied again. C is the tidier architecture and
  is rejected for the same reason: a new shape earns its place when two
  citizens actually need it, and today they do not share a byte.
  **A new unknown, named rather than discovered later:** measured, there
  is no `mmap` anywhere in MLX's C++ core — safetensors are not
  memory-mapped, so 334 MB stays resident beside the audio graph, the
  recogniser and the mouth. On the Mac this is invisible. On a phone it
  is a real risk, and it joins the short list of things only a device
  can answer.
- **F-5 THE DEPENDENCY BILL, stated before it is paid.** Measured from
  the spike's resolved graph: `mlx-swift-lm` 3.31.4, `mlx-swift` 0.31.6,
  transitively `swift-numerics` 1.1.1, `swift-argument-parser` 1.8.2 and
  `swift-syntax` 603.0.2 — plus a real tokenizer, because mlx-swift-lm
  deliberately does NOT depend on swift-transformers; it ships
  `#huggingFaceTokenizerLoader()`, a macro that wraps YOUR
  `Tokenizers.Tokenizer`. **Three direct packages, not one.**
  A: pay it, inside the opt-in product only, exactly as WhisperKit and
  TTSKit are paid for. B: hand-write a tokenizer. C: refuse the bill and
  rule F-1 = D. **Recommendation: A, unchanged** — D-023's four
  questions still pass, and the fourth passes because the code lives
  behind `ReplyGenerating` in a product nobody is forced to import.
  B is rejected: the spike already proved a lazy tokenizer yields ids
  that are valid but wrong, and Qwen3 is `Qwen2Tokenizer` — BPE, not
  SentencePiece, so "it is only 200 lines of SentencePiece" is not the
  bill either. Two escape hatches were proposed and do not work:
  vendoring the macro's expansion does not drop swift-transformers,
  because the macro WRAPS a `Tokenizers.Tokenizer` rather than
  generating one; and swift-syntax is a build-time dependency of macro
  expansion that is never in the runtime graph at all — so there is
  nothing to remove there, and its true cost is CI build TIME, which is
  a reason to measure that time, not to redesign around a ghost.

## 90. Out of scope for 4h (deliberately)

Multi-turn memory, still its own milestone · tool calling and structured
output · reply QUALITY scoring beyond "is it speakable" · SpeakerKit ·
the parked self-barge investigation · the Mac's stuck Foundation Models
download.

*(Corrected by the 4h review. Three items were removed from this list
because they did NOT stay out of scope, and leaving them here would have
been the spec claiming a boundary the code had already crossed:*

- *"the phone's numbers" — taken. 2288 MB peak, 291–315 ms first word,
  38 turns (INSTRUMENTS §25–27).*
- *"model downloading" and "anything served from a network" — shipped.
  D-062 F-4 = A ruled that the MLX product follows Whisper's shape, and
  Whisper's shape downloads. The on-device constraint is about where
  INFERENCE happens, not about how weights arrive; Whisper had been
  fetching ~142 MB for three milestones under the same rule.)*

## 91. Definition of done (4h)

D-061 written FIRST, closing the gate as F-6 = A required ("result
logged as a D-entry either way") · forks ruled and logged before any
`Package.swift` line is added · AC-125's invariant proven before the
adapter exists, because the hard problem is the pure one · all ACs green
or honestly re-scoped · the core-alone build still green, which is the
vow's only real proof · 20× stable · zero warnings in both
configurations · a review before merge (D-041), with every finding fixed
or accepted in writing · numbers in INSTRUMENTS with the phone's absence
stated · teach-back survived.

# SPEC — Milestone 4i: under pressure (three measurements, no new architecture)

*(REWRITTEN 2026-08-21, before sign-off, because the milestone's own
first acceptance criterion refuted its premise. The original draft —
which opened "4h measured a pair that does not fit" and proposed a
degradation chain — is preserved in commit `2f48d3c`. Ruled A by Ryad:
re-scope, drop the chain. See D-065.)*

## 92. What 4i builds, and why the first draft was wrong

The draft existed because three debts looked like one question: a pair
that would not fit, an unpaid thermal number, and an unbuilt degradation
path. Then AC-132 — the milestone's own instrument — was built first, and
the pair fitted:

```
mind=Local · ear=Whisper · mouth=Neural · speaker shield=true
memory headroom: 934 MB · a working turn in 478 ms
```

Whisper's recogniser IN-PROCESS, the 4B mind, the neural voice and the
speaker shield, all resident, with 934 MB to spare (INSTRUMENTS §29).

**The claim they refuted was mine, repeated in three places**, and it came
from adding a Mac's `phys_footprint` to a phone's dirty-memory headroom.
CoreML MAPS its weights, so they are clean pages and are not charged
against that limit; MLX has no `mmap`, so its 2225 MB is charged in full.
The neural voice costs **111 MB** on iOS, not the 1112 MB I measured on a
Mac.

**So the chain is not built.** A degradation chain now would be built for
a device nobody in this project owns, which is the purchase D-047
rejected in one sentence — *"it protects against a risk nobody
measured"* — and it would carry the same honest label: insurance, not a
measured cure.

**What is left is three measurements and no new architecture.**

## 93. What is KNOWN, and what is still guessed

**KNOWN — measured on Ryad's iPhone (INSTRUMENTS §28–§29):**

| | |
|---|---|
| the app's dirty limit | ~3.5 GB (3347 MB free at a clean launch) |
| the 4B mind | **2225 MB** — dirty, MLX does not mmap |
| the neural voice | **111 MB** — mapped, and therefore nearly free |
| all three + shield | **934 MB still free**, and a turn answers |
| the instrument | `os_proc_available_memory` is iOS-only; `limit_bytes_remaining` reads 0 on macOS for the OPPOSITE reason, so the platform must discriminate |

**KNOWN — the failure that is real:** the load, not the footprint. The
app was killed twice loading the voice — at 1105 MB free and at 2976 MB
free — and survived at 3347. TTSKit compiles six CoreML models
CONCURRENTLY, and that transient peak is the whole hazard.

**GUESSED — untouched:**

- **The peak itself.** Nobody has seen it. The process dies at it.
- **Every thermal claim.** No temperature, no time-to-throttle, no
  recovery time has ever been recorded by this project.
- **Anything beyond 38 turns.** The longest measured conversation.
- **478 ms to first word** with three in-process models, against 291–315
  ms with Apple's voice and ear. One turn. A hint, not a number.

## 94. The one hard problem: the peak kills the instrument that would measure it

A footprint can be read at leisure. A peak cannot, because the process
that would report it is the process being terminated:

```
   headroom  ────╮
                  ╲          ← six CoreML compiles at once
                   ╲
   ─ ─ ─ ─ ─ ─ ─ ─ ─╳─ ─ ─    jetsam. no callback, no unwind,
                              no final log line, no crash report
```

iOS does not warn. There is no "you are about to die" notification to
handle, and nothing runs afterwards.

So the measurement has to be written down BEFORE it is needed — sampled
continuously and flushed to disk on every reading, so that the last line
that survived is the answer. That is not defensive coding; it is the only
shape that can work, and this project has already paid for the lesson
twice: the MLX phone spike lost two crashes to a buffered stdout (§24
STAGE 3), and the pressure probe's own trail survived a kill only because
every line was flushed before the next step ran (§28).

## 95. Acceptance criteria (4i, rewritten)

- **AC-132 The headroom instrument can say whether it is switched on.**
  *(status: MET — `MemoryHeadroom` never reports an ambiguous 0, four
  tests including the macOS control. It is also what refuted this
  milestone's original premise, which is the best thing an instrument can
  do.)*
- *(AC-133 – AC-138 RETIRED unbuilt: the pressure level, the hysteresis,
  the degradation order, and making the forbidden pair degrade. There is
  no forbidden pair and nothing to degrade. Retired rather than
  renumbered, so the draft that proposed them stays readable.)*
- **AC-139 The compile peak, measured.** The sampler writes headroom
  every 250 ms during a load and flushes each line. A run that survives
  gives the trough; a run that is killed gives the last reading before
  death. Either is the number. Recorded with the configuration that
  produced it, because the peak is a property of what else was resident.
- **AC-140 AC-102's thermal debt, paid.** On the phone, across a
  sustained conversation: thermal state over time, time to first
  throttle, recovery time after stopping, and whether real-time deadlines
  break (audio dropouts, transcript lag, mouth stutter). The number may
  be boring. It is owed either way, and it has been owed since Phase 3.
- **AC-141 Twenty minutes.** One long field session in the configuration
  Ryad actually uses — Whisper ear, 4B mind, neural voice, shield on —
  logging headroom, thermal state and first-word latency over time. 4h
  measured 38 turns and no decay; this asks the question 38 turns cannot.

## 96. Test matrix (4i, rewritten)

| Criterion | Test | Needs a device? |
|---|---|---|
| AC-132 | `MemoryHeadroomTests` — 4 tests, incl. the macOS control | no |
| AC-139 | the sampler's own control: a run with sampling off records nothing | no |
| AC-139 | field run, trough or last-line-before-death | **yes** |
| AC-140 | field run, thermal trace | **yes** |
| AC-141 | 20-minute field run | **yes** |

**Three of five need the phone, and that is honest rather than
regrettable.** This milestone is mostly measurement; the part that could
be proven on a Mac was AC-132, and it is done. A milestone that pretended
otherwise would be measuring the wrong machine — which is exactly the
mistake that produced the first draft.

## 97. The design forks (4i) — ruled

*(D-065: the reshape ruled **A** — re-scope, drop the chain. F-1 through
F-3 of the original draft are retired with AC-133–138; F-4 was withdrawn
by its own author before it could be ruled, because measurement showed
`limit_bytes_remaining` also reads 0 on macOS, so cross-checking cannot
disambiguate anything.)*

No open forks. If AC-140 or AC-141 shows the configuration failing under
sustained load, that reopens the chain with evidence — which is the only
basis on which it should ever have been built.

## 98. Out of scope for 4i (rewritten)

The degradation chain · multi-turn memory · tool calling · reply QUALITY ·
SpeakerKit · the parked Apple-mouth self-barge · the Mac's stuck
Foundation Models download · On-Demand Resources · device tiering ·
making the neural voice pleasant · anything for a phone smaller than the
one being measured.

## 99. Definition of done (4i, rewritten)

AC-132 met · the peak recorded with the configuration that produced it ·
a thermal trace that exists, whatever it says · twenty minutes survived
or honestly reported as not survived · numbers in INSTRUMENTS including
the disappointing ones · zero warnings · 20× stable · review before merge
(D-041) · teach-back survived.

---

# Milestone 4j — the phone's tuning bench

## 100. Why this milestone exists

The Mac can be tuned from the command line: decoder, vocoder mode,
temperature, cushion (INSTRUMENTS §31.1). The first thing that tuning
produced was a disagreement:

    THE CLOCK SAYS              THE EAR SAYS
    ──────────────────          ────────────
    fused           177 ms      good
    temp 0 + fused  171 ms      BAD     ← fastest start, worst sound
    stepped         218 ms      ok
    fused+through   350 ms      good    ← slow start, good sound
    throughput      440 ms      good    ← slowest start, still good

`temperature 0` has the fastest first audio of all six configurations and
speaks for 13 seconds where the winner takes 6.5. Anything tuned on first
audio alone picks it. **No instrument in this repo measures what Ryad judged
in five seconds** (INSTRUMENTS §32), so the human stays in the loop — and the
phone, the device that actually matters, has no way to put him there. It has
an engine picker, a mind picker and a voice picker, and not one of the four
levers.

## 101. Scope

1. Split the single 884-line screen into three tabs — **Chat · Bench ·
   Settings** (D-066 F-1).
2. Put the four voice levers on the phone, `.fused` included so that it can
   refuse honestly with the CoreML reason (D-066 F-2).
3. A measured sweep that runs on the device, gated on the mind being
   unloaded, alongside live by-ear switching (D-066 F-3).
4. Results leave the phone as a markdown table, in the shape INSTRUMENTS
   already uses (D-066 F-4).

## 102. Non-goals

- **Not** a redesign. The controls that exist keep their behaviour and their
  words; they move.
- **Not** a Mac bench. `audio-demo` and `bakeoff` already do that.
- **Not** the six-configuration sweep. The phone can compare four (§103).
- **Not** 4i's remaining debts. AC-139, AC-140 and AC-141 stay open and are
  not absorbed here.

## 103. The constraint that shapes it

`.fused` does not load on iOS 18+:

    modelLoadingFailed("MultiCodeDecoder: failed to load
    MultiCodeDecoder.mlmodelc (function 'fused') on macOS 15 / iOS 18
    or newer. MLModelConfiguration's .functionName must be nil unless
    the model type is ML Program.")

`MLModelConfiguration.functionName` may only be non-nil for an ML Program,
and the Qwen3 multi-code decoder is not one. Measured, not assumed: `.fused`
**does** load on macOS 26 (INSTRUMENTS §31), so the error's own wording
overstates it — the failure is iOS-only in practice.

So the phone compares `stepped × {latency, throughput} × {default, 0}
temperature`, four configurations, and the Mac's winner is unavailable to it.
D-066 F-2 keeps `.fused` in the picker anyway: a refusal carrying the real
error is evidence, where a hidden option teaches nothing.

## 104. What the split has to survive

The groundwork found five hazards. They are the actual work of this
milestone; the tabs themselves are an afternoon.

**H-1 — the launch order is load-bearing.** `ContentView.task` runs
`checkModel()` → `checkVoice()` → `refreshMind()` in that order, under a
comment reading "Swapping these two lines is a memory bug that looks like
nothing." The voice must be born while headroom is at its maximum
(INSTRUMENTS §29: killed at 1105 MB and at 2976 MB free, survived at 3347).
A TabView must run this **once**, at the container, never per tab.

**H-2 — the voice is a `let` with one lever nailed shut.**
`private let neuralVoice = NeuralVoice(multiCodeDecoderMode: .stepped)`.
Changing a lever means building a new voice, which means an explicit retire
of the old one — and D-051's lazy-init bug has already bitten four times, most
recently loading the voice twice concurrently (~2.2 GB where 1.1 was
intended).

**H-3 — `restart()` gives no signal that the new configuration is up.** It
fires from seven `didSet`s, calls a `stop()` that defers teardown into a
detached Task, then starts again from a second detached Task. `isListening`
goes false synchronously while the microphone is still being released. Two
sweep iterations can therefore overlap a live teardown.

**H-4 — state survives across iterations.** `diagnostics` is deliberately
never stopped; `bargeCount` and `onsetsWhileSpeaking` are not in `start()`'s
reset list; `turns` grows without bound. A sweep that reads these reads the
sum of everything before it.

**H-5 — the machine changes under the measurement.** `ConservativeThermalPolicy`
sacrifices late settling decodes on a hot phone, and a repeated sweep heats
the device, so later iterations measure a different machine. Nothing today
annotates a run with its thermal state.

Two smaller ones, recorded so they are not rediscovered: every lever writes
to `UserDefaults` in its `didSet`, so a sweep that dies mid-run leaves the
phone configured at whatever the last iteration set; and the echo-probe
button had to live in the toolbar because a button in the bottom strip did
not fire on synthetic taps in the simulator — which constrains where any
bench control may be placed if it is ever to be driven by a test.

## 105. Acceptance criteria

**AC-142 — one model, one load, three tabs.** The app presents Chat, Bench
and Settings over a single shared `TranscribeModel`, and the order-critical
launch sequence (H-1) executes exactly once for the process, whatever order
the tabs are visited in. *Test:* a launch-counter assertion driven by
visiting all three tabs in both directions.

**AC-143 — the levers exist on the phone, and say what they are.** Bench
offers decoder, vocoder mode, temperature and lead. The screen displays the
configuration currently in force, and that display is read from the voice
that was actually built — never from the picker's own state. *Test:* set each
lever, assert the displayed configuration matches the constructed voice; and
one test that fails if the display is wired to the picker instead.

**AC-144 — `.fused` refuses honestly.** Choosing `.fused` on iOS surfaces the
CoreML `modelLoadingFailed` text, the app does not crash, and the previous
working voice is still usable afterwards. *Test:* Mac control asserting
`.fused` LOADS (proving the test can tell the two outcomes apart), plus the
field observation on the phone.

**AC-145 — changing a lever retires the old voice.** After N lever changes,
exactly one voice pipeline is resident. *Test:* a load-counter on the voice
seam; N changes must produce N loads and N−1 retires, and the concurrent
double-load of §28 must fail the test if reintroduced.

**AC-146 — the sweep refuses to run with the mind resident.** With the mind
loaded, the Bench sweep is disabled and says why. With it unloaded, the sweep
runs. *Test:* both branches, asserting the refusal names the reason.

**AC-147 — the sweep waits for readiness, never for time.** Each iteration
begins only when the previous configuration is observably down and the new
one observably up (H-3). No sleep, no fixed delay, no retry count.
*Test:* a driver test against a controllable seam, with a spin cap so a red
fails fast.

**AC-148 — each row carries the conditions it was measured under.** Every
sweep row records the configuration, first audio, total, thermal state at the
start of the row, and free headroom — so a row taken on a hot phone can be
told from one taken cold (H-5). *Test:* assert every field is present and
that the thermal value comes from the sample taken during that row.

**AC-149 — counters are per-iteration, not cumulative.** The values a row
reports are the ones that iteration produced (H-4). *Test:* two iterations
where the first produces a barge and the second none; the second row must
report zero.

**AC-150 — the numbers leave as markdown.** The Bench copies a table in the
shape INSTRUMENTS already uses, pasteable beside the Mac's numbers without
editing. *Test:* golden-string comparison of the rendered table.

**AC-151 — a sweep that dies does not leave the phone reconfigured.** The
levers a sweep sets are scoped to the sweep; after it ends, by completion or
by death, the phone is back on the settings the human chose. *Test:*
simulated mid-sweep failure, assert the persisted settings are unchanged.

## 106. Test matrix

| AC | Mac-testable | Needs the phone |
|---|---|---|
| AC-142 one load, three tabs | ✅ launch counter | — |
| AC-143 levers say what they are | ✅ | — |
| AC-144 `.fused` refuses honestly | ✅ control only (it must LOAD here) | ✅ the refusal itself |
| AC-145 lever change retires | ✅ load counter | — |
| AC-146 sweep gated on the mind | ✅ both branches | — |
| AC-147 readiness, not time | ✅ | — |
| AC-148 conditions per row | ✅ fields present | ✅ real thermal values |
| AC-149 per-iteration counters | ✅ | — |
| AC-150 markdown out | ✅ golden string | — |
| AC-151 death leaves no residue | ✅ | — |

Two of eleven need the phone, and both are the honest half: a constraint that
only exists on iOS, and a thermal reading a Mac cannot produce.

## 107. Open forks

**F-1 — where does the sweep driver live?** The hazards in §104 mean the
sweep needs defined semantics (readiness, per-iteration reset, scoped
settings), and semantics want tests. Options: **(A)** a new
`MultiModalKitBench` module the app depends on — testable, tier 2 of D-016,
core untouched; **(B)** inside `MultiModalKitTTS` — fewer modules, but the
voice library gains a benchmarking concern it has no business holding;
**(C)** in the app — nothing new to name, and nothing testable either, which
puts AC-147 and AC-149 out of reach. *Recommendation: A.*

**F-2 — sequencing.** Does 4j begin now, with 4i's AC-139/140/141 still open,
or after they are measured? Both need the phone; a bench that logs thermal
state per row (AC-148) is arguably the instrument AC-140 has been waiting
for. *No recommendation — this is a priority call, not a design one.*

## 108. Definition of done (4j)

Eleven criteria met · the four levers reachable on the phone · a sweep that
refuses rather than dies · a markdown table pasted into INSTRUMENTS beside
the Mac's · Ryad's by-ear ranking of the phone's four configurations recorded
next to the clock's, agreeing or not · zero warnings · 20× stable · review
before merge (D-041) · teach-back survived.
