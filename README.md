# MultiModalCoordinator

A coordination library for on-device AI streaming, built in public — phase by
phase, every design decision logged, every claim checkable in the tests.
Lost in the code? [ARCHITECTURE.md](ARCHITECTURE.md) is the one-page map.

**What it is now:** a microphone becomes speech events, speech events become
text, text becomes a *conversation* — one that answers out loud and stops the
moment you interrupt it. On the device. On a Mac and on an iPhone, with no
platform variant of anything on the spine.

| Phase | What it added |
|---|---|
| **1** | real microphone → lock-free ring → voice activity → clean speech events, many listeners |
| **2** | utterances become **text**, two engines behind one proven seam, [measured](BAKEOFF.md) |
| **3** | `os_signpost` spans, health events, a thermal ruling that is honest about being insurance |
| **4** | the **conversation**: turn-taking, barge-in, the whole thought, **two real mouths**, and the whole thing running on a phone |

The problem the whole library exists for is one boundary:

> The real-time audio thread may **never wait** — no locks, no allocation, no
> `await`. Swift concurrency lives on the other side of that rule. The library
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

```
swift test   →   259 tests in 33 suites, green, run 20× before any milestone closes
                 (deterministic core; gated engine and speaker suites run real
                  models and real audio where installed, and skip honestly where not)
```

The deterministic core runs on fake time and fake audio: same result on any
machine, under any load. No sleeps, no "wait a bit and hope", no count-based
waits.

**Three suites are exceptions, and they are ungated** — they run on a plain
`swift test`: `AudioSessionSeamTests` starts a REAL microphone,
`PlaybackHostTests` starts a REAL audio engine, and
`PlaybackLeadStrandTests` renders real (silent) samples through one, because
the invariants they guard (the session's ordering, where a reply may render,
and whether a reply can be stranded unplayed) do not exist anywhere else.
They skip honestly when the machine has no engine to render on. The cost is
real and is written down: a machine whose audio configuration changes
underneath the run can **abort the process** rather than fail a test, and
[INSTRUMENTS.md](INSTRUMENTS.md) §19 records the run where that happened 39
times in 40.

## The hardest problem: the crossing

Two counters, not one.

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

## The law that repeats at every layer

Three times now, at three different heights, the same shape:

> **Cancellation is an optimisation. A ticket is the guarantee.**

A recognition may answer after its utterance is over. A reply may arrive after
the speaker has moved on. A decode may finish after the listener interrupted.
Cancelling any of them is a *request* the platform may ignore — so every
utterance and every turn carries a monotonic ticket, raised and checked **in
the same actor step**, and a *defiant* scripted engine that answers into a dead
utterance on purpose proves the guarantee by test.

The other law that repeats: **after every `await`, re-check everything the
await could have invalidated.** Two critical bugs in milestone 4d were exactly
this and nothing else.

## Phase 4 — the conversation

```
AudioPump ─► TranscriptionSession ─► TurnCoordinator ─► a spoken reply
                                          │
                                          ├─ the turn ticket: a barge kills
                                          │  the reply, everywhere, at once
                                          ├─ the reply gate: the floor must
                                          │  stay yielded before it answers
                                          ├─ the TranscriptLedger: the WHOLE
                                          │  thought, so a pause mid-sentence
                                          │  no longer costs the first half
                                          └─ two seams out: a reply generator,
                                             and a MOUTH
```

**Two real mouths, which is the point.** `SpeechSynthesizing` has Apple's
`AVSpeechSynthesizer` behind it and a Qwen3 neural voice (CoreML, via TTSKit)
behind it, both certified by the same conformance kit, both driven by the same
coordinator, ledger and phraser, on both platforms, with no variant of any of
them. That claim used to be a promise with one implementation; milestone 4e
made it a proof — and then measured both voices against each other by speaking,
recording, transcribing and scoring the result.

**The honest verdict on those voices** ([INSTRUMENTS.md](INSTRUMENTS.md)
§13–§14, §18): Apple's is fast and sounds like a robot. The neural one is
intelligible (round-trip WER **0.074** against Apple's 0.000, over 18 draws),
about **twice as slow**, inconsistent in length between draws of the same
sentence, and it occasionally inserts a laugh. Neither is good. **The point was
never that either voice is good — it was that switching between them cost the
library nothing**, and that is now demonstrated rather than claimed.

## Run it

```bash
swift build
swift test                          # 259 tests, deterministic
swift run audio-demo                # terminal: the pump deciding, live
swift run audio-demo whisper --talk # …and talking back
swift run bakeoff                   # the transcription bake-off (WER)
```

The measurement tools each answer one question, and each writes its numbers
into [INSTRUMENTS.md](INSTRUMENTS.md):

```bash
swift run bakeoff voice-install   # fetch the neural voice's model (1.1 GB, once)
swift run bakeoff voice-spike     # time to first audio, and the real-time factor
swift run bakeoff voice-levers    # every decoder setting, measured serially
swift run bakeoff voice-wer       # speak → record → transcribe → score
swift run bakeoff voice-onmic     # a reply rendered on a LIVE capture engine
swift run bakeoff graph-probe     # what a live audio graph actually tolerates
```

`voice-listen` used to be in that list and **is not any more** — it was
deleted in `0331534`, a commit about something else, while all three
documents kept advertising it. INSTRUMENTS §13's blind A/B numbers came
from it, so they are recorded but no longer reproducible from this tool.
Named here rather than quietly dropped.

`Demo/TranscribeDemo` is the iPhone app: two transcribers, two MINDS (the
echo control and the on-device language model, with honest availability
words and a mind probe in the toolbar), two mouths, an
Apple-voice picker, a live microphone level with the gate marked on it, a
one-tap gate calibration, the echo probe, and barge counters that fail apart so
three different bugs can be told apart at a glance.

## Rules this repo keeps

- **Spec before code.** [SPEC.md](SPEC.md) is signed off before anything is
  built; the acceptance criteria are numbered and each has tests.
- **Every fork is logged.** [DECISIONS.md](DECISIONS.md) records the choice,
  the options rejected, and why — including the ones later found wrong.
  D-007 → D-015 is the honest example; **D-048 → D-049 is the expensive one**,
  where a ruling made on a bad recommendation was reversed a day later after
  it cost five rebuilds on real hardware.
- **Measurements before opinions.** [INSTRUMENTS.md](INSTRUMENTS.md) carries
  the numbers *and* the ones that were thrown away — a debug build that
  flattered nothing, a harness that measured itself, a stability run taken
  while the machine was busy, a WER table that the very next run contradicted.
  A number that cannot be reproduced is recorded as an anecdote.
- **The history is the record.** No squash, no rebase, no force-push. Red tests
  are committed before the code that makes them green, and mistakes are fixed
  **forward** with a commit that says what happened.
- **Machines guard the rest.** Swift 6 strict concurrency, zero warnings, CI on
  every push, and the core keeps **zero runtime dependencies** — Whisper and
  the neural voice are opt-in products, each behind a protocol the core owns.

## Status

Phases 1–3 complete. Phase 4 complete through milestone 4e: the conversation
runs on a Mac and on an iPhone, with two transcription engines and two speech
synthesizers behind their seams.

**Open, and named rather than buried:**

- The neural voice is unpleasant. Kept deliberately (D-050) as the seam's
  second implementation; making it pleasant is deferred, with the levers
  already measured and rejected written down so the next attempt does not
  repeat them.
- A reply rendered on the **capture** engine — so the platform's echo canceller
  can see it — is SOLVED on iOS (4g): the shield matrix measured the graph
  arrangement, the canceller took an audible tone from the disease's 1.0 down
  to 0.004–0.08, and a field conversation on the loudspeaker no longer barges
  itself. Two honest residues: Apple's mouth (via `write()`) still self-barges
  INTERMITTENTLY — suspects and instruments recorded, investigation open — and
  the fallback-loudly path (AC-123) is not built.
- AC-102 still owes an iPhone stop-latency number and a thermal number. The
  phone gets hot; how hot has not been written down.
- The neural decode's **batching pin** (`concurrentWorkerCount = 1`) is still
  untested, and the `TTSDecoding` seam does not change that: the fault it
  prevents lives in the vendor's own branching, which a scripted decoder
  cannot reproduce. Its guarantee rests on reading TTSKit's source.
- `graph-probe`'s control case — detach after `engine.stop()` — **does not
  reproduce on a plain Mac engine** (INSTRUMENTS §20). The abort that cost 4e
  an afternoon needed voice processing or a session teardown, so that one
  case still needs a phone.
- ~~A liveness hole (D-055)~~ **— found, measured, and CLOSED before the
  merge.** A reply could be stranded, fully decoded and silent, if the
  playback lead was larger than the whole reply and the token stream closed
  after the last decode. Three separate places were answering one question
  and one of them asked a smaller version of it; they now go through a
  single funnel (D-055 = B, INSTRUMENTS §21). Found by the adversarial
  review of the TTS seam, which is the argument for D-041 in one line.

See [SPEC.md](SPEC.md) and [DECISIONS.md](DECISIONS.md) — D-045…D-060 carry
phase 4's rulings.
