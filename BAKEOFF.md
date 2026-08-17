# The bake-offs

**Two of them now.** This document is the TRANSCRIPTION bake-off — two
speech engines, one contract, the same recorded voice. Milestone 4e added
a second one, of VOICES, and its numbers live in
[INSTRUMENTS.md](INSTRUMENTS.md) §13–§14 rather than here: two mouths
speaking the same sentences, captured at the mixer, transcribed back by
this repo's own engines, and scored. A pipeline that can listen can grade
its own mouth.

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

| Engine | WER | sub | ins | del | decode settle | device | model on disk |
|---|---|---|---|---|---|---|---|
| Apple SpeechAnalyzer (en_US) | **12.0%** | 9 | 0 | 2 | 0.62 s | iPhone | system-managed |
| Whisper base (WhisperKit) | **12.0%** | 7 | 2 | 2 | 0.75 s | iPhone | 142 MB |
| Whisper base (WhisperKit) | **12.0%** | 7 | 2 | 2 | 0.82 s | Mac (Apple Silicon) | 142 MB |

The iPhone rows come from the demo app's bake-off button feeding the SAME
bundled fixture through both engines. The Apple engine cannot run on the
development Mac (its asset daemon refuses the model — see README), so its
row comes from the phone only.

## Findings — read them all, they do not flatter anyone

**1. A dead heat.** The anecdote that motivated this milestone — "the Apple
model struggles with this accent" (milestone 2a field impression) — is NOT
confirmed on read-aloud speech at equal conditions: both engines score
12.0% on the same audio. The honest caveat cuts both ways: this fixture is
one speaker reading one prepared paragraph; the 2a impression came from
spontaneous conversational speech, which is a different and harder fixture —
a candidate for a follow-up recording, not a conclusion by assumption.

**2. They fail differently.** Apple substitutes (9) and never invents a
word; Whisper invents a little (2 insertions) but substitutes less (7).
For a downstream consumer, substitution-heavy and hallucination-light are
different risk profiles — which one matters depends on the product.

**3. Latency and shape favor Apple for conversation.** 0.62 s settle vs
0.75 s — and Apple streams live partials while Whisper stays silent until
the decode. For a conversational screen, that difference is the UX.

**4. Whisper's real trump card is availability.** It is the only engine
that can exist on the development Mac at all (Hugging Face delivered in
34 s where Apple's asset daemon has failed for days), it has no per-app
asset allocation ceremony, and its models are swappable files.

**5. The instrument out-earned the comparison.** On its way to one table,
the bake-off caught two scoring faults (digits, control tokens — disclosed
above) and one PRODUCTION bug: the Apple adapter stopped at the first
segment final, so 46.5 s of speech came back as 14 words (85.9% "WER" — 1
substitution, 78 deletions; the arithmetic identified the bug: 92−78 = the
first sentence exactly). A real utterance with a long mid-sentence pause
would have lost its tail the same way. Fixed; lesson 4 in the adapter.

**6. Reproducibility held.** Whisper scored an identical 12.0% with
identical error counts on two different machines — the instrument measures
the same thing twice, which is what makes everything above worth reading.

## What Whisper base heard (verbatim, iPhone and Mac identical)

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

The same tool grew the voice measurements in 4e. Each answers one
question, and each writes to [INSTRUMENTS.md](INSTRUMENTS.md):

```bash
swift run bakeoff voice-install   # fetch the neural voice's model (1.1 GB, once)
swift run bakeoff voice-spike     # time to first audio, and the real-time factor
swift run bakeoff voice-levers    # every decoder setting, measured serially
swift run bakeoff voice-listen    # a BLIND A/B between decoders, judged by ear
swift run bakeoff voice-wer       # speak → record → transcribe → score
swift run bakeoff voice-onmic     # a reply rendered on a LIVE capture engine
```

**`voice-wer` grades with Whisper alone**, and that is a known gap
against D-045 F-5, which asked for both engines. A single grader's bias
is unmeasured; the number is reported with that caveat rather than
without it.
