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
