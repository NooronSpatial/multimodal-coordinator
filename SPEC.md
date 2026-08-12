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
