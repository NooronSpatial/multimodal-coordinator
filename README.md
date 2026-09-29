# The AI Runtime

*The SPM package is `multimodal-coordinator` and the core module is
`MultiModalKit` — the names it was born with, kept because two apps pin
them. **The AI Runtime** is what it is: `AIRuntime` is the type an app
builds, and the name this page uses for the thing as a whole (D-115).
The package and the modules are renamed once, at a major version, when
the runtime can do everything the name claims.*

An on-device AI runtime, built in public — phase by phase, every design
decision logged, every claim checkable in the tests. Lost in the code?
[ARCHITECTURE.md](ARCHITECTURE.md) is the one-page map.

**What it is now:** a microphone becomes speech events, speech events become
text, text becomes a *conversation* — one that answers out loud and stops the
moment you interrupt it. On the device. On a Mac and on an iPhone, with no
platform variant of anything on the spine.

The brain is swappable and both options are real: Apple's Foundation Models,
or a model whose weights sit in your own filesystem, running through MLX.
Measured on an iPhone: **291–315 ms to the first spoken word**, 38 turns, no
network at any point after the weights are on disk.

**And that brain — the *mind*, the piece that writes the reply text — can be
driven as text, not only as a voice.** A caller that wants one whole reply
calls `reply(to:)`: text in, text out. It sets its own instructions, token
budget, temperature and seed on that one call, instead of only at `init`.
What comes back is typed rather than a string — a reply carrying the text and
why it stopped (`.complete`, `.tokenBudget`, `.unreported`, `.refused`), and a
failure that is a case a caller can count, not a sentence it has to parse.
Ask the same question twice at temperature 0, and the same bytes come back on
the same machine; that is measured in [INSTRUMENTS.md](INSTRUMENTS.md) §65,
on a Mac. The whole contract — the shortest call that works, the typed "can
this device run it?" verdict, which failures are worth retrying, and what it
deliberately does not do — is one section of
[ARCHITECTURE.md](ARCHITECTURE.md).

| Phase | What it added |
|---|---|
| **1** | real microphone → lock-free ring → voice activity → clean speech events, many listeners |
| **2** | utterances become **text**, two engines behind one proven seam, [measured](BAKEOFF.md) |
| **3** | `os_signpost` spans, health events, a thermal ruling that is honest about being insurance |
| **4** | the **conversation**: turn-taking, barge-in, the whole thought, **two real mouths**, and the whole thing running on a phone |
| **4h** | the **second mind**: a model whose weights live on your device, behind the same seam Apple's sits behind — and the seam's proof that it was drawn in the right place |

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
swift test   →   green, and run 20× before any milestone closes
                 (deterministic core; gated engine and speaker suites run real
                  models and real audio where installed, and skip honestly where not)
```

The count is not typed on this page. `Scripts/shape.sh` runs the suite
and prints it, and the last section of [ARCHITECTURE.md](ARCHITECTURE.md),
*The shape in numbers*, carries that output with the commit it ran at.
This line said 356 while the suite nearly tripled — a number a person
keeps in prose drifts (AC-210).

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
swift test                          # deterministic (count: ARCHITECTURE.md)
swift run audio-demo                # terminal: the pump deciding, live
swift run audio-demo whisper --talk # …and talking back
swift run bakeoff                   # the transcription bake-off (WER)
```

The measurement tools each answer one question, and each writes its numbers
into [INSTRUMENTS.md](INSTRUMENTS.md). **Run them `-c release`** — a timing
read off a debug build is not evidence of anything, and a debug build was one
of the three causes of the slow neural voice (§31):

```bash
swift run -c release bakeoff voice-install   # the voice's model, ~1.1 GB, once
swift run -c release bakeoff voice-spike     # time to first audio, per sentence
swift run -c release bakeoff voice-levers    # every decoder setting, serially
swift run -c release bakeoff voice-wer       # speak → record → transcribe → score
swift run -c release bakeoff voice-onmic     # a reply on a LIVE capture engine
swift run -c release bakeoff graph-probe     # what a live audio graph tolerates
```

The full surface — every subcommand, all thirteen `audio-demo` flags, the
three flag shapes that fail silently when mixed, the environment switches,
and the bugs found while writing it down — is
**[COMMANDS.md](COMMANDS.md)**. Neither executable has a `--help`, so that
file is the only complete answer.

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
  every push, and the core keeps **zero runtime dependencies** — Whisper, the
  neural voice and MLX are opt-in products, each behind a protocol the core
  owns. That vow is checked mechanically, not promised: CI builds the core
  target ALONE before anything else, and an `import MLXLLM` in a core file
  makes that build fail.

## Status

**On `main`, every milestone through 5b is merged** — phases 1–3, phase 4
from 4a to 4z, then 5a and 5b. The conversation runs on a Mac and on an
iPhone, with two transcription engines, two minds and three mouths behind
their seams. Five tags an app can pin:

| Tag | Milestones | What it added |
|---|---|---|
| **0.1.0** | up to 4v | the spine, the front door (`AIRuntime`, 4t) and the mind's text contract (4v) |
| **0.2.0** | 4x, 4w | the model's size before a byte moves; an install that cannot destroy a working model; a first tool |
| **0.3.0** | 4y, 4z | admission, heat at the door, memory pressure that cancels, a deadline; the tool contract |
| **0.3.1** | 5a | model downloads: a percentage on every engine, a transfer that survives the background, a delete |
| **0.4.0** | 5b | the Apple mind keeps one session per conversation; a reply that fails for no named reason after a tool ran is asked again, once |

**0.4.0 was tagged before its phone session, on purpose** (D-125). That
session is next. If it overturns the retry's design, the fix ships as
0.4.1 — a pushed tag is never moved.

**What changed after 4h, measured on the phone.** All the local models fit
at once: the Whisper ear, the 4B mind and the Qwen3 voice worked together
with 934 MB to spare ([INSTRUMENTS.md](INSTRUMENTS.md) §29). Nineteen
minutes and 58 turns showed **no decay** — first word, median 323 ms over
the first ten turns and 317 ms over the last ten — and free memory fell by
7 MB (§40). The mind now sees the earlier turns of the conversation (4r).
And the default mouth changed: **Kokoro-82M** replaced the Qwen3 voice,
about **six times faster** on the same phone (§55, D-084).

**Open, and named rather than buried:**

- **The newest promises still owe their phone rows.** One session is
  planned for them (SPEC §214): the retry probe (AC-323); turn two's first
  token and twenty turns that call their tools (AC-315); the demo running
  on a device (AC-316); and 5a's three — a download that keeps going while
  the phone is locked for five minutes, a killed app that resumes with a
  range request, and the system waking the app when the last file lands
  (AC-300). 4z's live tool rows for the Apple mind are owed too (SPEC §198).
- **One CI run never finished** (5b, piece R): twelve silent minutes,
  cancelled by hand. Its re-run passed, and so did the whole suite on a
  one-thread pool. Not explained yet; the log is kept (SPEC §214).
- **Kokoro's clean result is a Mac number.** No silent gaps and WER 0.000
  over ten draws (§57) — but on a Mac, where it decodes faster than on the
  phone. Until the phone repeats it, the cushion built for the Qwen3 voice
  stays (D-084). That voice stays too, behind the lever: it sounds good to
  the ear now (§42), but on the phone it decodes slower than it speaks
  (§55).
- **Self-barge is cured on one mouth, not on all.** Since 4g every reply
  plays through the capture engine, where the echo canceller can see it
  (D-060). What still leaked is told apart by how long it lasts, not how
  loud it is (§43), so a 600 ms barge window stopped it on the Qwen3 voice
  — and a real interruption still landed *"immediately"* (D-071, §45).
  Kokoro's first field session heard no echo (D-087). Apple's mouth still
  cuts itself sometimes: its 22 kHz resampling path is the convicted
  suspect, and its leak has never been timed (§45). The loud fallback for a
  device where that graph cannot start (AC-123) is still not built.
- **Heat is measured now, and it arrives fast.** The phone reached
  `serious` about two minutes into a session and did not come back down in
  nineteen minutes (§40). Still owed: the cool-down curve after stopping —
  the one attempt was spoiled by the phone's hotspot — and the phone's stop
  latency, from a barge to silence (AC-102).
- **English first.** Arabic was started — the ear measured, a first
  conversation held on the phone (§62–§63) — and then parked (D-100). The
  default mouth pronounces English only (D-084).
- The Qwen3 voice's **batching pin** (`concurrentWorkerCount = 1`) is still
  untested; its guarantee rests on reading TTSKit's source.
- `graph-probe`'s control case — detach after `engine.stop()` — **does not
  reproduce on a plain Mac engine** (§20). It needed voice processing or a
  session teardown, so that one case still needs a phone.

**Taken back since the last update:** *"The local 4B mind (2239 MB) and the
neural voice (1112 MB) cannot run together."* The 1112 MB was a Mac's
count. CoreML memory-maps its weights, so on the phone the voice costs
111 MB (§29). What survives is the order: the voice loads before the mind,
while the phone has the most memory free.

See [SPEC.md](SPEC.md) and [DECISIONS.md](DECISIONS.md): D-029…D-113 carry
the rulings from 4a to 4z, D-114 carries 5a's, and D-116…D-125 carry 5b's.
