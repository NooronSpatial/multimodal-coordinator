# Kokoro spike (Milestone 4p)

**One question:** on this phone, does Kokoro-82M decode faster than
speech? The library's whole cushion apparatus — D-046's rule, D-073's
learner, D-080's stall statistic — exists because the Qwen3 mouth measured
**RTF 1.21** on Ryad's iPhone. A decoder below 1.0 would make that
apparatus unnecessary rather than smaller.

## Why this is a separate Xcode project

`kokoro-ios` pins `mlx-swift` to **exactly 0.30.2**. `mlx-swift-lm`, which
the Qwen mind needs, requires **0.31.3..<0.32.0**. SPM refuses:

```
error: root depends on 'mlx-swift-lm' 3.0.0..<4.0.0 and root depends on 'mlx-swift' 0.30.2.
'mlx-swift-lm' >= 3.0.0 practically depends on 'mlx-swift' 0.31.3..<0.32.0
```

Even `MisakiSwift`, the grapheme-to-phoneme library, carries the same
exact pin — so there is no partial route in either. The alternatives were
checked and are worse: `adriancmurray/kokoro-ios` has relaxed pins but
**no tags at all**, `mweinbach/kokoro-swift` would resolve but has **no
licence**, and `mattmireles/kokoro-coreml` is a Python conversion
pipeline, not a Swift package.

So the spike never meets the mind. It links the vendor untouched, at the
vendor's own pin, and answers the question without a single fork. If the
number is good, forking three repositories becomes a decision made with
eyes open; if it is bad, we lost a day.

## Building it

```
cd Spikes/KokoroSpike && xcodegen
open KokoroSpike.xcodeproj
```

**Device only.** MLX does not run on the iOS Simulator.

Pick your team once in Xcode (signing is Automatic, nothing is hardcoded).

## Using it

1. **Download the model** — 327 MB, once, into Application Support. It is
   not committed: a public repository should not carry a third of a
   gigabyte to answer one afternoon's question.
2. **Measure both sentences.** They are the cushion sweep's own fixtures,
   character for character, so the numbers can be laid beside INSTRUMENTS
   §53/§54.
3. Each sentence runs **once as a warm-up (reported, never counted)** and
   then **three counted times**. The vendor's claim is explicitly "after
   warm up", so the cold run is shown rather than hidden.
4. **Copy the table out** with the share button.

## Reading the number

`RTF = decode wall time ÷ audio produced`, this project's convention —
**lower is better**, 1.00 is exactly real time. The vendor's README quotes
the reciprocal ("3.3× faster than real time", which would be RTF ≈ 0.30).

Kokoro is one-shot: it returns a whole sentence at once. So "time to first
audio" and "decode time" are the same number, and there is no starvation
to measure inside a sentence — the gap, if any, moves to the seam
*between* phrases.

## What this spike does NOT answer

- Intelligibility as a number (AC-184's WER) — this plays the audio so it
  can be judged by ear, which is evidence, not measurement.
- Memory footprint under the app's real load (AC-185).
- Whether the voice is good enough. That is Ryad's ear and AC-189's fork.
