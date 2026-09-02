# Two mouths, one stopwatch (Milestone 4p)

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

## Both mouths, on purpose

The first Kokoro numbers came back at RTF 0.19–0.21 against Qwen3's 1.21.
Six times is a large gap — and the two numbers were not measured the same
way. Kokoro ran bare here; Qwen3's 1.21 came from the live app with the
mind feeding it. Part of that gap could have been the harness.

So this app now holds **both**. Same two sentences, same stopwatch, same
memory sampler, same process, back to back. `argmax-oss-swift` depends on
argument-parser, vapor and swift-openapi — never mlx-swift — so the pin
collision that exiled this spike does not reach TTSKit.

The timing lives in `SpikeModel`, never in the engines: a stopwatch each
vendor starts for itself is a comparison with a thumb on the scale.

**Two opposite embedding rules, both learned the hard way.** KokoroSwift
declares `type: .dynamic`, so it must be carried in the app bundle —
without `embed: true` the build is green and the device refuses to launch.
TTSKit declares no type, so SPM builds it static and links it in; asking
to embed *that* fails the build outright. Neither line is decoration.

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
4. Turn on **also measure Qwen3-TTS** for the comparison. It costs a
   ~1 GB download, once: this app has its own container, so the demo
   app's copy cannot be borrowed.
5. **Copy the table out** with the share button.

**A confound, stated rather than corrected:** Kokoro always runs first and
Qwen second, and this phone heats. Every row stays on screen, so drift is
visible. If the two land close enough for order to matter, that is the
moment to counterbalance — the way the Mac sweep had to.

## Reading the number

`RTF = decode wall time ÷ audio produced`, this project's convention —
**lower is better**, 1.00 is exactly real time. The vendor's README quotes
the reciprocal ("3.3× faster than real time", which would be RTF ≈ 0.30).

Kokoro is one-shot: it returns a whole sentence at once. So "time to first
audio" and "decode time" are the same number, and there is no starvation
to measure inside a sentence — the gap, if any, moves to the seam
*between* phrases.

## Reading the memory number

Peak is **this process's own footprint** (`phys_footprint` — what Xcode's
gauge shows and what iOS judges an app on), sampled every 20 ms while the
decode runs. It is the shared metric because MLX keeps a peak counter and
CoreML does not; a vendor's own number cannot compare two vendors.

Sampling is a compromise this project usually refuses. The cost is stated
rather than hidden: **a spike shorter than the interval is invisible**, so
a reported peak is a floor, never a ceiling.

## What this spike does NOT answer

- Intelligibility as a number (AC-184's WER) — this plays the audio so it
  can be judged by ear, which is evidence, not measurement.
- Behaviour inside the real pipeline: no phraser, no lead, no barge-in,
  no mic. A good number here is permission to integrate, never proof that
  integration behaves.
- Whether the voice is good enough. That is Ryad's ear and AC-189's fork.
