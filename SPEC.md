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
