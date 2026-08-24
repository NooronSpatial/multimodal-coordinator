# COMMANDS — everything runnable, and how to tune it

Read out of the argument parsing itself (`Sources/AudioDemo/AudioDemo.swift`,
`Sources/Bakeoff/main.swift`), then adversarially re-checked against the same
source and proved by running the binary. Where this file and the code
disagree, the code is right and this file is a bug.

Three rules before anything else.

**1. Build release when you are judging speed.**

```bash
swift run -c release audio-demo whisper --talk --mind=local --mouth=neural
```

A debug build was one of the three causes of the slow neural voice
([INSTRUMENTS §31](INSTRUMENTS.md)). A timing read off `swift run` without
`-c release` is not evidence of anything.

**2. There are THREE flag shapes, and mixing them fails silently.**

| shape | flags | example |
|---|---|---|
| `--name=value` | `--mind` `--mouth` `--decoder` `--speech` `--temperature` `--lead` | `--mouth=neural` |
| `--name value` (separate word) | `--onset` `--gate` `--vad` `--hangover` | `--onset 120` |
| bare, no value | `--talk` `--no-aec` `--levels` | `--talk` |

`--onset=120` is not an error, and neither is `--decoder stepped`. The token is
discarded, the default is used, and no warning is printed. **Proved by
running the binary**: the same command with `--decoder=stepped` and with
`--decoder stepped` produced

    voice: decoder=stepped, …          ← the "=" form
    voice: decoder=fused, …            ← the space form, silently defaulted

with the orphaned word `stepped` appearing nowhere in either stream.

The three shapes are not a design. The two-word flags are older (D-036's
field A/B); the newer ones took `=`. They are documented rather than
unified, because renaming them would break commands already recorded in
INSTRUMENTS as the provenance of published numbers.

**3. `swift run bakeoff <typo>` does not tell you it is a typo.** There is no
subcommand validation: an unknown word falls through to the WER bake-off and
is used as the *wav path*. Proved by running it — `bakeoff nonsense` exits 1
with `cannot read wav: nonsense`, which is a loud failure but not the one you
would expect.

---

## `audio-demo` — the live conversation

```
        EAR                MIND                 MOUTH
   ┌───────────┐     ┌────────────┐      ┌────────────┐
   │  whisper  │  →  │   local    │  →   │   neural   │
   │  apple    │     │   apple    │      │   apple    │
   └───────────┘     │   echo     │      └────────────┘
   (positional)      └────────────┘
```

    swift run -c release audio-demo [apple|whisper] [--talk] [flags]

### The organs

| flag | values | default | parsed at |
|---|---|---|---|
| *(positional)* | `apple` · `whisper` | `apple` | `AudioDemo.swift:83` |
| `--talk` | bare | off | `AudioDemo.swift:32` |
| `--mind=` | `echo` · `apple` · `local` | `echo` | `chosenMind` |
| `--mouth=` | `apple` · `neural` | `apple` | `chosenMouth` |
| `--model=` | a weights directory | the Hugging Face cache | `defaultLocalWeights` |

The positional argument is "the first token that is neither a flag nor a
number" — the number test is what stops `--onset 120` from making `120` the
engine. A consequence worth knowing: `swift run audio-demo 120` does **not**
print the usage line, it silently starts the Apple engine.

### The neural voice's levers

**These four are read only when `--mouth=neural` AND `--talk` are both
present.** `chosenMouth` returns the Apple voice before it ever looks at
them, and is itself only called inside the turn loop. Without both, all four
are silently ignored.

| flag | values | default | note |
|---|---|---|---|
| `--decoder=` | `fused` · `stepped` | `fused` | `.fused` cannot load on iOS 18+; the Mac has no such bug |
| `--speech=` | `latency` · `throughput` | `latency` | |
| `--temperature=` | e.g. `0.7` | the model's own | |
| `--lead=` | `400ms` or `400` | **derived from the decoder** | the unit is optional here |

When it does build a neural voice, it says so on stderr first:

    voice: decoder=stepped, speech=throughputOptimized, temperature=0.7, lead=0.25 seconds

That banner is the point — the slow voice was a silent disagreement between
the decoder in use and a cushion sized for a different one. Note the limit
honestly: **with the default mouth there is no banner at all**, so the
default run is exactly the run that cannot say what it was.

**Leave `--lead` off** unless you are deliberately testing the cushion. Absent,
it is derived from the decoder you picked, which is what stops the two from
disagreeing. Typing a number re-opens that hole by hand.

### The listening levers

| flag | shape | default | what it moves |
|---|---|---|---|
| `--vad` | `--vad 0.02` | `0.02` | the energy threshold that counts as speech |
| `--onset` | `--onset 120` | `0` (D-036) | how long speech must persist before it counts |
| `--hangover` | `--hangover 700` | `700` (D-028/D-036) | how long silence must last before the turn ends |
| `--gate` | `--gate 250` | `0` | AC-81's reply gate — how long to wait before answering |
| `--no-aec` | bare | AEC **on** (D-038) | turns echo cancellation off |

These four values are printed in the startup banner (`AudioDemo.swift:182`),
so a run does report the settings in force — it just never says that a
mistyped flag was dropped.

### One mode that is not a conversation

    swift run audio-demo --levels

Replaces the whole program: it prints a level probe every 500 ms straight
from the ring and returns. No pump, no transcription, no turn loop.

### What each organ needs on disk

| organ | needs |
|---|---|
| `--mind=local` | `mlx-community/Qwen3-4B-4bit` **in the Hugging Face cache**, and a Metal shader library (`Scripts/metallib.sh`) |
| `--mouth=neural` | the Qwen3 TTS model, ~1.1 GB — `swift run bakeoff voice-install` |
| `--mind=apple` / `--mouth=apple` | an OS willing to hand them over |

A missing model does not stop the demo: `chosenMind` writes a refusal to
stderr and falls back to the echo mind, because a silent downgrade would be
worse. **But see the known bug below — that refusal currently names a command
that does not work.**

---

## `bakeoff` — the measuring tools

Each answers one question and writes its numbers into
[INSTRUMENTS.md](INSTRUMENTS.md).

| command | question | flags |
|---|---|---|
| `bakeoff [wav] [reference]` | which transcriber has the lower WER | positional; defaults `Fixtures/ryad-en.wav`, `Fixtures/bakeoff-reference.txt` |
| `bakeoff voice-install` | is the voice model on disk — fetch it if not | — |
| `bakeoff voice-spike` | time to first audio, per sentence, neural vs Apple | `--stepped`, `--lead=400` |
| `bakeoff voice-levers` | all six decoder settings, measured serially | — |
| `bakeoff voice-wer` | speak → record → transcribe → score | — |
| `bakeoff voice-onmic` | a reply rendered on a LIVE capture engine | `--no-output-chain` |
| `bakeoff voice-selfecho` | does the assistant's voice cross its own gate | `--no-shield`, `--no-vp` (the eyes control), `--gate=0.021` |
| `bakeoff graph-probe` | what a live audio graph actually tolerates | `--case=N` |
| `bakeoff ask "…"` | one question to the local mind | `--model=`, `--system=` |
| `bakeoff mind-off` | both brains on the same three questions | `--model=` |
| `bakeoff memory-fit` | do the two models fit together | `--model=` — **required, see below** |
| `bakeoff fetch` | download weights with honest progress | `--repo=`, `--into=` |

Every bakeoff flag uses the `--name=value` shape. There are no two-word flags
here — that inconsistency is `audio-demo`'s alone.

Four details that will otherwise mislead you:

- **`memory-fit` without `--model=` never loads a mind.** The mind is loaded
  only inside `if let given = --model=…`, so the flagless form prints the
  baseline and the voice and cannot answer the question its own name asks.
- **`voice-spike` prints no real-time factor.** It reports first audio and
  total per sentence, plus a neural-vs-Apple ratio. The RTF line lives in
  `NeuralVoiceRun` and is suppressed unless `MMK_TRACE_TTS=1`.
- **`voice-spike --lead=400ms` is silently ignored** — that parser wants a bare
  number. `audio-demo` accepts both. Same flag name, two parsers.
- **`graph-probe` re-executes itself once per case.** AVFoundation raises an
  ObjC exception rather than throwing, so a single-process probe would report
  only its first fault. Case 5 is a deliberate control: a probe where nothing
  ever fails cannot be told from a probe that cannot see failures.

### The default-model mismatch

`bakeoff ask` and `bakeoff fetch` default to `mlx-community/Qwen3-0.6B-4bit`,
while `audio-demo --mind=local` looks for `Qwen3-4B-4bit`. The 0.6B was ruled
out as a mind for quality (D-064) and the iOS app no longer offers it, but the
two bakeoff defaults were not moved with it. Pass `--model=` / `--repo=` to
compare like with like. Named rather than quietly changed, because the numbers
already in INSTRUMENTS were taken against those defaults.

---

## Environment switches

| variable | what it does |
|---|---|
| `MMK_TRACE_TTS=1` | prints **every decode step**, and the RTF/margin line, to stderr |
| `MMK_LIVE_SYNTH=1` | lets the audible tests really make sound |
| `MMK_MLX_MODEL=<dir>` | unlocks the think-gate test **and** the six AC-128/129 live-model tests |

The first is the instrument to reach for when a setting feels wrong but the
totals look fine:

```bash
MMK_TRACE_TTS=1 swift run -c release bakeoff voice-spike 2>trace.txt
```

---

## Build and test

```bash
swift build
```

```bash
swift test
```

299 tests, 40 suites, deterministic — injected clocks, event-gated waits, no
sleeps. Audible tests additionally need `MMK_LIVE_SYNTH=1`. A test phase is
not done until the suite has run 20× clean; one flake is a race, not noise.

---

## Bugs found while writing this file — and fixed

Writing a tool down honestly is itself an instrument. Verifying every claim
here against the source turned up three defects no test covered. All three
are fixed; they are kept here because the *numbers* they affected are still
in INSTRUMENTS.

**1. `voice-spike --stepped` measured with no cushion.** It passed
`NeuralVoice.defaultLead` — the constant derived from `.fused`'s RTF 0.752,
which is **zero** — and an explicit lead defeats the decoder-aware
derivation. Stepped should get ~396 ms. The exact bug that caused the slow
voice, hardcoded into the instrument built to study it, under a comment
reading "THE LEAD MUST FOLLOW THE DECODER, and once it did not."

> **Every `--stepped` number this tool produced before 2026-08-23 was taken
> with no cushion.** They measure a starved player, not the decoder.

The fix is not only the one line. `defaultLead` is now **deprecated**, because
a test could never have caught this: the bug lived in an executable's
`main.swift`, which the package suite cannot reach. CI builds every target
with `-warnings-as-errors`, so the deprecation turns the mistake into a build
failure — verified by reintroducing it:

    error: 'defaultLead' is deprecated: This is .fused's cushion, not a
    universal default. Pass lead: nil to derive it from the decoder…

Five tests now also pin the derivation itself (`LeadFollowsDecoderTests`).

**2. The `--mind=local` refusal named a command that could not work.** It
said to run `bakeoff fetch`, which writes to `$TMPDIR/mmk-fetch`, while
`--mind=local` read only the Hugging Face cache. `audio-demo` now takes
`--model=<dir>`, so the advice has somewhere true to point — and a path that
is not a model is refused by name rather than failing later inside MLX.

**3. The turn-loop header lied about the mouth.** It printed "it SPEAKS the
echo aloud (AVSpeechSynthesizer)" in every run, including
`--mind=local --mouth=neural`, where all three words were wrong. It now reads
the flags:

    turn loop: ON — local mind, spoken by Qwen3 neural voice

## A build trap worth knowing

`swift build --target AudioDemo` compiles the module but **does not relink the
executable**. The binary under `.build/…/debug/` stays stale, and a test run
against it silently measures the old code. This cost a full verification
cycle here. Use:

```bash
swift build --product audio-demo
```

## Known gap: there is no `--help`

Neither executable has one. Worse, `swift run audio-demo --help` does not
print help — it **starts the microphone**, because the engine choice is "the
first token that is not a flag and not a number", and with none present it
falls back to `apple`. The single usage line that exists
(`AudioDemo.swift:94`) still reads `[apple|whisper] [--talk]` and knows
nothing of the other **twelve** flags above.

So this file is currently the only complete answer, which means it is the only
thing that can go out of date. Recorded as a gap rather than left for the next
person to find by starting a microphone they did not want.
