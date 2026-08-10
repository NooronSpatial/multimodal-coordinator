# The engine bake-off

Two speech engines, one contract, the same recorded voice — measured, not
argued. The experiment exists because of a field finding (milestone 2a): the
on-device Apple model struggled with a non-native accent. Whisper-class
models are said to be robust there. This document is where "said to be"
becomes a number.

## Method (fixed before any measurement — see Fixtures/bakeoff-script.md)

- **The audio:** a fixed 92-word paragraph, written into the repo BEFORE
  recording, read once by Ryad (non-native speaker — the accent is the
  point), one take, no retakes. 46.5 s, 16 kHz mono WAV, committed.
- **The scorer:** word error rate by word-level edit distance after
  normalization (lowercase, punctuation stripped, digits spelled out).
  The scorer has its own tests — the ruler is checked before measuring.
- **Warm-up excluded:** each engine runs the file once unmeasured first;
  CoreML graph compilation belongs to install cost, not recognition.
- **Decode settle** = wall-clock from "no more audio" to the final text —
  the pause a user would feel after finishing a sentence.
- **Engine-level, not pipeline-level:** audio is fed straight through
  `TranscriptionRun`, 20 ms chunks, file rate. VAD and session costs are
  measured elsewhere (LATENCY-style docs); this table isolates the engines.

**Scoring corrections, disclosed:** the first run scored 15.2%. Two scoring
faults were fixed — digits were not being spelled out although the written
rules said so ("20" vs "twenty"), and Whisper's non-speech control token
`[BLANK_AUDIO]` was being counted as two inserted words. Control tokens are
now stripped in the adapter; digits are spelled out in the scorer. The
corrected number is below; nothing about the engines changed.

## Environment

Apple M2 Pro · macOS 26.6.1 · WhisperKit (argmax-oss-swift 1.1.0)
· model `openai_whisper-base` (142 MB on disk) · Swift 6, release of
2026-08-10.

## Results

| Engine | WER | sub | ins | del | decode settle | model on disk |
|---|---|---|---|---|---|---|
| Whisper base (WhisperKit) | **12.0%** | 7 | 2 | 2 | 0.82 s | 142 MB |
| Apple SpeechAnalyzer (en_US) | *pending* | — | — | — | — | system-managed |

**Why the Apple column is pending:** this Mac's asset daemon refuses the
speech model download (machine-side, proven by elimination — see README).
The column arrives from an iPhone via the demo's engine picker, or from this
Mac after the next macOS update. It is left visibly empty rather than
quietly omitted.

## What Whisper base heard (verbatim)

> My name is Riyad and I am testing two speech engines on this device. The
> audio travels through a ring buffer into pump that cuts it into small
> chunks of 20 milliseconds. When I stop speaking for a moment, the voice
> detector closes the utterance and the engine writes the final text. Good
> transcriptions should survive in accent, a fast synthesis, and the
> technical world like latency, hooker and sea, or microphone. This
> paragraph has exactly the same words every time, so the error rate is
> real measurement and not an opinion.

The earned errors tell their own story: the name ("Riyad"), small function
words ("into pump", "in accent", "real measurement"), and the star of the
experiment — **"hooker and sea" for "concurrency"** — exactly the kind of
technical-vocabulary failure the accent test exists to catch.

## Not measured (and said so)

Battery and thermal (Phase 3's instruments) · other languages · far-field
microphones · larger Whisper variants (a `small`/`tiny` row may join as
a measurement, not a decision) · streaming latency of the Apple engine
(needs its model; measured at the session level when it lands).

## Reproduce

```bash
swift run bakeoff                       # committed fixtures
swift run bakeoff my.wav my-ref.txt     # your own voice, your own reference
```
