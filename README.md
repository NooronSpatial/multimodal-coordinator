# MultiModalCoordinator

A coordination library for on-device AI streaming, built in public — phase by
phase, every design decision logged, every claim checkable in the tests.

**Phase 1 (complete):** real microphone → lock-free ring buffer → voice
activity detection → clean speech events, delivered to many listeners.
**Phase 2 (milestone 2a complete):** those utterances become **text, on the
device** — one recognition per utterance, engines swappable behind one seam,
verified live on an iPhone.

The problem this phase exists for is one boundary:

> The real-time audio thread may **never wait** — no locks, no allocation, no
> `await`. Swift concurrency lives on the other side of that rule. Phase 1
> crosses the boundary **exactly once**, safely, in code that can be explained
> line by line.

```
   AUDIO THREAD (real-time, never waits)          SWIFT CONCURRENCY (may wait)
 ┌───────────────────────────────────┐        ┌─────────────────────────────────┐
 │  AVAudioEngine tap callback       │        │  AudioPump  (one actor,         │
 │   • no locks                      │        │              one task)          │
 │   • no allocation                 │        │                                 │
 │   • no await                      │        │   wait: next poll OR stop       │
 │                                   │        │            │                    │
 │        producer.write(samples) ───┼──┐     │            ▼                    │
 └───────────────────────────────────┘  │     │   drain the ring once           │
                                        │     │            ▼                    │
                    ╔═══════════════════▼══╗  │   carry + cut fixed chunks      │
                    ║   AudioRingBuffer     ║ ─┼──►         ▼                    │
                    ║   lock-free SPSC      ║  │   EnergyVAD judges each chunk   │
                    ║   overwrite-oldest    ║  │            ▼                    │
                    ╚═══════════════════════╝  │   Broadcast.publish(event)      │
                         ▲                     └────────┬───────────┬────────────┘
                         │ TWO atomics cross            ▼           ▼
                         │ (reserved, then head)    listener 1   listener 2
                                                   (own stream, own drop count)
```

## What it does today

| Piece | What it is | Proven by |
|---|---|---|
| `AudioRingBuffer` | lock-free single-producer/single-consumer ring; overwrite-oldest; every dropped frame counted exactly | 9 tests, incl. a 100k-frame stress run and an in-flight-overwrite regression |
| `MicrophoneSource` | `AVAudioEngine.installTap` capture, behind a protocol seam | swapped for `FakeMicrophone` in every test |
| `ManualClock` | hand-driven `Clock`; tests own time completely | 7 tests |
| `EnergyVAD` | RMS threshold + hangover, pure and clockless | 8 tests, exact boundary cases |
| `AudioPump` | the one bridge: polls on an injected clock, chunks, judges, publishes | 8 tests, exact event sequences |
| `Broadcast` | many listeners, bounded buffers, drop-oldest, losses counted, no replay | 7 tests |

| `TranscriptionSession` | one recognition per utterance; the utterance ticket; the 30 s ceiling | 8 tests, exact event sequences |
| `ScriptedTranscriber` | an engine that misbehaves on demand — silent, defiant, failing | the ticket's sparring partner |
| `AppleSpeechEngine` | SpeechAnalyzer/SpeechTranscriber behind the seam | conformance-gated; verified live on iPhone |

```
swift test   →   54 tests in 9 suites, green, ~0.12 s
```

Everything runs on fake time and fake audio: same result on any machine, under
any load. No sleeps, no "wait a bit and hope", no count-based waits.

## The three hard parts

### 1. The crossing: two counters, not one

The producer writes and moves a counter; the consumer reads behind it. The
first version published one atomic — `head`, stored **after** the copy ("first
the goods, then the flag"). The reader validated its copy by re-reading it.

That check had a hole. `head` moves only when a copy is **finished**, so a copy
still **in flight** was invisible — and a reader sitting a full ring behind
would copy the very slots the producer was overwriting and call the result
clean. It surfaced as one order violation in about 35 stress runs. Chased
instead of retried; a probe reproduced it 34 times in 20 rounds.

The fix (D-015): the producer publishes its **intention** too.

```
reserved.store(h + n)   ← "I am about to own these slots"   (before the copy)
        …memcpy…
head.store(h + n)       ← "the bytes are ready"             (after the copy)
```

The reader clamps and validates against `reserved`, never `head`. The probe is
now a permanent regression test — and it still fails if you remove the fix.

```
  tape:  … 8700 ─────────────────── 12800 ────── 13000 …
           │                          │            │
          tail                       head       reserved
       (consumer)              "ready to read"  "being written NOW"

  slot = frame number & mask   →   frame N and frame N-capacity share a slot
  safe to read  ⟺  less than `capacity` behind `reserved`
```

**The promise, in one line: the buffer may drop, but it may never lie.**

### 2. The pump: one task, one clock, no side doors

`AudioPump` is the only reader of the ring and the only holder of a clock.
Every poll it drains once, adds to whatever it carried, cuts complete chunks
(never padding a partial one — padded silence is a lie the VAD would believe),
judges each chunk, and publishes.

Time comes from **sample arithmetic** — `framesConsumed ÷ sampleRate` — not
from a clock (D-011). It is the audio's own time, so "how long from capture to
`speechStarted`" is an exact number in a test, not a measurement that moves
with machine load.

Stopping is a race, not a flag (D-014):

```swift
group.addTask { try await clock.sleep(until: next) }   // the poll
group.addTask { await stopSignal.wait() }              // the stop
let first = await group.next()                         // whoever arrives first
group.cancelAll()                                      // the loser is cancelled, never abandoned
```

Both racers are children of `run()`'s own scope, so nothing can outlive it:
**cancellation is the optimisation, structure is the guarantee.** A test proves
`stop()` alone ends the loop, with no cancellation and no clock advance.

### 3. The events: what a listener is promised

```
   quiet   quiet   LOUD    LOUD    LOUD   quiet   quiet
     │       │       │       │       │      │       │
     └─ held ┘       │       │       │      └─ hangover ┘
       (pre-roll)    │
                     ▼
  speechStarted(1920)                       ← announced first
  audioSegment(0) audioSegment(960)         ← the run-up, handed over
  audioSegment(1920) … audioSegment(5760)   ← the phrase, chunk by chunk
  speechEnded(6720)                         ← when the decision could be made
```

- **Pre-roll** (D-009): the two chunks before the first loud one are kept and
  delivered, so the first syllable is never cut.
- **`speechEnded` is stamped when the hangover is spent** (D-013), not when the
  sound stopped — at that earlier moment, the pause could still have been a
  breath between two words.
- **Dropped frames are an event** (D-010), stamped where the gap begins. A gap
  also clears the carried partial chunk: those frames are no longer next to
  what follows, and splicing them would be a smooth-sounding lie.
- **Listeners are independent** (D-008/D-012): each has a bounded buffer,
  drop-oldest, and its own loss counter. A slow listener costs itself events —
  never the pump a millisecond, never another listener a single frame. Events
  never replay: a listener that joins late hears what happens next.

## Run it

```bash
swift build
swift test          # 42 tests, ~0.1 s, deterministic
swift run audio-demo
```

The demo opens the microphone and shows the pump deciding, live. Real output
from a 32-second run:

```
🎙  Speak — the pump is listening.  (Ctrl-C to quit)
    48000 Hz · 960-frame chunks (20 ms) · 300 ms hangover · 2 chunks of pre-roll
    two listeners attached: [display] and [recogniser]

▶︎  speech started  at 1.36 s
   ↳ [recogniser] utterance #1 complete — 28800 frames received so far
⏹  speech ended    at 1.92 s  —  0.60 s of audio in 30 chunks
▶︎  speech started  at 2.78 s
   ↳ [recogniser] utterance #3 complete — 169920 frames received so far
⏹  speech ended    at 4.98 s  —  2.24 s of audio in 112 chunks
[········································] listening…
```

**Read the numbers — they prove two claims.**

*Pre-roll works.* Utterance #1 runs 1.36 → 1.92 s: 0.56 s between the events,
but 0.60 s of audio delivered. Utterance #3: 2.20 s between the events, 2.24 s
of audio. Every phrase in the run is **exactly 0.04 s longer** — the two
pre-roll chunks, handed over from before the start was announced. The first
syllable is never cut, on real hardware, not only in a test.

*The listeners are independent.* The `[recogniser]` line lands before the
display's own end line, every time: two tasks consuming the same event, each at
its own pace, neither waiting for the other.

Across those 32 seconds the ring dropped **zero** frames.

**A known trade-off, visible in the same output:** the 300 ms hangover is part
of the delivered audio, so every utterance carries 300 ms of trailing silence —
most of a short one. That is correct today (the tail is real sound and a
recogniser may want it), and it is a candidate for a future ruling: trim the
tail, or keep it and let the consumer decide.

## Phase 2 — speech becomes text (milestone 2a)

```
AudioPump ──events──►  TranscriptionSession ──transcripts──► listeners
                            │                    partial / final /
                            │                    failed / truncated
                            ├─ ONE recognition per utterance
                            ├─ fed pre-roll first, every chunk once, in order
                            └─ the utterance TICKET: a dead utterance's
                               words can never reach a listener
```

**The law, again:** recognition is slow and speech does not wait — an engine
may answer after its utterance is long over. Cancelling it is only a request.
So every utterance carries a ticket, checked in the same actor step that can
retire it; a *defiant* scripted engine that answers into a dead utterance on
purpose proves the guarantee by test. Same law as a voice assistant's
barge-in: **cancellation is the optimisation, the ticket is the guarantee.**

**One loop, one truth:** audio events, engine updates and the stop request
merge into a single stream handled by a single actor loop. No racing readers,
no stored tasks, every state change in loop order.

**Engines are swappable, provably.** `TranscriptionEngine` is the only thing
the session knows. A **conformance kit** — one shared test suite — is what
every engine must pass: one final then silence, partials never after the
final, cancel ends without a final. Apple's engine ships in the core (zero
dependencies kept); a Whisper-class engine is the planned second product
(D-016/D-017), motivated by a real field finding: the on-device `en_US`
model struggles with non-native accents — Whisper is famously robust there.
Two engines, one contract, then a measured bake-off.

**Failure is an event.** The scripted engine fails with the exact error shape
observed live (`"transcription.en asset unavailable … final state: Network
Error"`); the session publishes `failed` and accepts the next utterance. One
bad recognition never kills the run.

**What running on real hardware taught (none of it was in the docs):**
1. The speech model is a downloadable asset, and its download can die.
2. The engine's preferred audio format is unknowable until assets exist.
3. The engine's results stream never ends by itself — tear it down or leak.
4. Assets are **allocated per app** (`AssetInventory.reserve`) — without a
   reservation the modules come up empty. Found in the first sixty seconds
   on an iPhone; not in any of the documentation we read first.

**Honesty about testing:** our tests verify *our* code on a scripted engine —
deterministic, exact. Apple's model is exercised by the demos on real
hardware, and no test in this repo pretends otherwise.

**The demos:** `swift run audio-demo` (terminal: level bar, speech events,
live partials, finals with audio-time stamps — offers the model download and
degrades honestly to VAD-only if it fails) and **`Demo/TranscribeDemo`** — an
iOS app: utterance cells updating in place (orange partial → green final →
red failure), the VAD verdict and the ring's exact drop counter on screen.
Verified live: model downloaded on-device, utterances transcribed on an
iPhone, zero dropped frames.

## Rules this repo keeps

- **Spec before code.** [SPEC.md](SPEC.md) is signed off before anything is
  built; the acceptance criteria are numbered and each has tests.
- **Every fork is logged.** [DECISIONS.md](DECISIONS.md) records the choice,
  the options rejected, and why — including the ones later found wrong
  (D-007 → D-015 is the honest example).
- **The history is the record.** No squash, no rebase, no force-push. Red tests
  are committed before the code that makes them green.
- **Machines guard the rest.** Swift 6 strict concurrency, zero warnings, zero
  third-party dependencies, CI on every push.

## Status

Phase 1 complete (ring, capture, clock, VAD, pump, events, live demo).
Phase 2 milestone 2a complete (seam, session + ticket, scripted engine,
conformance kit, Apple engine, iOS + terminal demos). Next: milestone 2b —
the Whisper-class engine module and the measured engine bake-off; then
`os_signpost` instrumentation (Phase 3). Known open item: the speech-model
download repeatedly fails on one development Mac's network (the demo says so
and degrades); it succeeded first-try on iPhone. See [SPEC.md](SPEC.md) and
[DECISIONS.md](DECISIONS.md) — D-016…D-021 carry this phase's rulings.
