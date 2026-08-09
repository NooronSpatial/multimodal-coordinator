# MultiModalCoordinator

A coordination library for on-device AI streaming, built in public — phase by
phase, every design decision logged, every claim checkable in the tests.

**Phase 1 (nearly complete):** real microphone → lock-free ring buffer → voice
activity detection → clean speech events, delivered to many listeners.

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

```
swift test   →   42 tests in 6 suites, green, ~0.1 s
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

The demo opens the microphone and shows the pump deciding, live:

```
🎙  Speak — the pump is listening.  (Ctrl-C to quit)
    48000 Hz · 960-frame chunks (20 ms) · 300 ms hangover · 2 chunks of pre-roll
    two listeners attached: [display] and [recogniser]

▶︎  speech started  at 3.42 s
   ↳ [recogniser] utterance #1 complete — 3840 frames received so far
⏹  speech ended    at 4.28 s  —  0.86 s of audio in 43 chunks
[████████████·····························] listening…
```

Two listeners are attached on purpose: the display, and a stand-in for a speech
recogniser. They receive the same events independently — that is the multicast
promise, visible.

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

Phase 1 milestones 1a–1c complete: ring buffer, capture, clock, VAD, pump,
events, live demo. Next: `os_signpost` instrumentation and the streaming STT
seam (Phase 2). See [SPEC.md](SPEC.md) for what is deliberately out of scope.
