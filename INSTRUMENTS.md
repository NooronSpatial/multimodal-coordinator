# INSTRUMENTS.md — what the pipeline costs, measured

Phase 3's founding sentence was a confession: *"excluded by reasoning,
never benchmarked."* This document is where that sentence comes to die.
Every number below is measured or visibly missing — no cell is filled by
opinion. Slots marked **⟨fill⟩** await the field session.

## Environment

- Mac numbers: Apple Silicon, macOS 26.6.1 (the development machine).
- Device numbers: **⟨fill: iPhone model, iOS version, date of session⟩**
- Pipeline configuration: 48 kHz mono · 10 ms poll · 20 ms chunks ·
  200 ms pre-roll · 300 ms hangover · 30 s ceiling.

## Method

- The signpost tracks (subsystem `dev.nooron.MultiModalKit`, category
  `pipeline`): `pump.drain` (one poll's work) · `session.utterance`
  (speechStarted → retire) · `session.settle` (no-more-audio → final: the
  pause a user feels) · `whisper.decode` · `apple.settle`.
- Captured with Instruments' **os_signpost** template, app launched via
  Product → Profile, subsystem filtered.
- First inference per engine excluded (CoreML graph compilation — install
  cost, not recognition cost), same rule as BAKEOFF.md.
- The audio thread carries **zero** instrumentation (D-026); capture-side
  pressure is read as ring occupancy at drain.

## 1. The observer's own cost (AC-47)

| What | Cost | Source |
|---|---|---|
| One begin/end signpost pair, no instrument attached | **784 ns** (mean of 200 000 pairs, after warm-up) | measured, Mac, `-O` |
| Pump's share at 100 drains/s | **≈ 78 µs/s ≈ 0.008 % of one core** | arithmetic from above |
| Full suite wall-time, seam absent vs injected | **⟨fill: s vs s — run `swift test` twice on the Mac⟩** | informational |

The 784 ns is the FAST path — warmed category, buffer not full. The slow
paths are exactly why the audio thread stays dark (D-026): this table
proves signposts cheap where they live, not free where they're banned.

## 2. Idle cost — the pipeline listening to silence

| Metric | Value | Source |
|---|---|---|
| `pump.drain` cadence | **⟨fill: expect ~100/s⟩** | Instruments timeline |
| `pump.drain` typical duration, silence | **⟨fill: expect µs-scale⟩** | Instruments |
| App CPU %, listening, nobody speaking | **⟨fill⟩** | Instruments / Xcode gauge |
| App memory, listening, models loaded | **⟨fill: per engine⟩** | Xcode gauge |

## 3. Per-utterance cost — a real sentence on each engine (AC-51)

Speak ~3-second sentences, read the spans from the timeline. Three
sentences per engine; report the middle one.

| Span | Apple | Whisper base | Source |
|---|---|---|---|
| `session.utterance` (start → retire) | **⟨fill⟩** | **⟨fill⟩** | Instruments |
| `session.settle` (the felt pause) | **⟨fill⟩** | **⟨fill⟩** | Instruments |
| engine decode (`apple.settle` / `whisper.decode`) | **⟨fill⟩** | **⟨fill⟩** | Instruments |
| Reference point: 46.5 s fixture decode | 0.62 s | 0.75–0.82 s | BAKEOFF.md, both devices |

## 4. Sustained run — thermal observation (AC-51)

Ten minutes of intermittent Whisper conversation on the phone, badge
watched, Instruments running.

| Observation | Value |
|---|---|
| Thermal state reached (badge) | **⟨fill: cool / warm / hot⟩** |
| Time to first transition, if any | **⟨fill⟩** |
| `whisper.decode` drift (first vs last minutes) | **⟨fill: does heat slow decodes?⟩** |
| `dropped` counter after the run | **⟨fill: expect 0⟩** |

## 5. The eager-Whisper number (AC-52) — closing the founding concession

Milestone 2b rejected "streaming Whisper" by reasoning: it re-decodes the
whole growing buffer every pass. The arithmetic, now with measured inputs:

- Measured: one decode of a complete utterance ≈ **⟨fill from table 3⟩**;
  decode time scales with input length (46.5 s → ~0.8 s on this hardware).
- Eager mode at ~1 decode/s over a 10 s utterance decodes 1 s, then 2 s,
  … then 10 s of audio: **≈ 55 s-of-audio decoded for 10 s spoken — about
  5–6× the compute of the single settle decode**, plus the confirmation
  delay before text stabilises.
- Field check (optional, honesty ceiling): **⟨fill if run: eager decodes
  counted per utterance in a WhisperKit AudioStreamTranscriber spike⟩**

The rejection stands or falls with this table — reasoning now has numbers
under it, which was the whole point.

## Not measured (and said so)

Battery drain in mAh (needs a longer protocol than this session) · other
languages · far-field microphones · Apple engine on the Mac (asset daemon,
see README) · memory high-water marks under pressure.

## Reproduce

Product → Profile → os_signpost template → filter `dev.nooron.MultiModalKit`
→ speak → read the tracks. The badge and `decoding ×N` come free in the
demo's status bar.
