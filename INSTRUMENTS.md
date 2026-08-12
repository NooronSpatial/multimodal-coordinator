# INSTRUMENTS.md — what the pipeline costs, measured

Phase 3's founding sentence was a confession: *"excluded by reasoning,
never benchmarked."* This document is where that sentence comes to die.
Every number below is measured or visibly missing — no cell is filled by
opinion. Slots marked **⟨fill⟩** await the field session.

## Environment

- Mac numbers: Apple Silicon, macOS 26.6.1 (the development machine).
- Device numbers: Ryad's iPhone, iOS 26 — field sessions of 2026-08-11.
  (Run 1: found the span leak. Run 2: found the concurrent decodes. Run 3:
  the clean capture, both fixes in, confounds controlled — the numbers
  below.)
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
- **Confounds are disclosed, not discovered.** Runs 1–2 carried two,
  declared by the speaker before run 3: the device was charging/pre-heated
  (voids thermal attribution), and sentences ran together without real
  pauses (utterance shapes reflect glued speech, and decode overlap was
  constant by accident). The run-3 protocol controls both: unplugged,
  badge-cool start, deliberate pauses.

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
| `pump.drain` cadence | ~100/s — 5,492 drains / ~55 s listening | run 3 |
| `pump.drain` avg duration | **15.68 µs** (min 250 ns · max 777 µs); run 2 measured 11.70 µs — consistent | runs 2–3 |
| Pump's total CPU share while listening | 86.1 ms / 55 s ≈ **0.16 % of one core** (3 runs agree: 0.12–0.16 %) | runs 1–3 |
| App CPU %, listening (whole app, UI included) | **4 %** — both engines | Xcode gauge, plain run |
| App memory, listening | Apple: **29.1 MB** · Whisper: **51.8 MB** → the loaded Whisper base pipeline costs ≈ **23 MB resident** (CoreML maps weights; true footprint is larger than resident) | Xcode gauge |
| Network while transcribing | **Zero KB/s, both engines** — the on-device claim, on a dial | Xcode gauge |
| Network at engine STARTUP | Found by an airplane-mode experiment: WhisperKit pinged huggingface.co (a revision check) on every pipeline load, even with the model on disk — an offline failure and a privacy footnote in one. Fixed: with the local folder handed to the config, startup makes **zero requests** — and the test suite got 4× faster, because that ping was being paid on every load. A source audit of WhisperKit then closed the last gap: the tokenizer is a second, separate asset whose load is local-first but falls back to the hub if its cache files vanish — so `modelInstalled()` now verifies those files by name, and "installed" means offline-capable, proven, not assumed. | field experiment + fix |
| Energy Impact gauge | "High" while listening — driven by the live audio session; not decomposed further (a battery protocol is out of scope, and said so below) | Xcode gauge |

## 3. Per-utterance cost — a real sentence on each engine (AC-51)

Speak ~3-second sentences, read the spans from the timeline. Three
sentences per engine; report the middle one.

| Span | Apple | Whisper base | Source |
|---|---|---|---|
| `session.utterance` (start → retire) | 17 utterances avg 2.47 s (speech length dominates, as it should) | (same pool) | run 3 |
| `session.settle` (the felt pause) | **avg 85.8 ms across all 17 · max 311 ms** — the user waits a tenth of a second | (same pool) | run 3 |
| engine decode (`apple.settle` / `whisper.decode`) | **73 ms** avg (44–122, n=11) | **110 ms** avg (3–311 ms, n=6, zero overlaps) | run 3 |
| Reference point: 46.5 s fixture decode | 0.62 s | 0.75–0.82 s | BAKEOFF.md, both devices |

## 4. Sustained run — thermal observation (AC-51)

Ten minutes of intermittent Whisper conversation on the phone, badge
watched, Instruments running.

| Observation | Value |
|---|---|
| Thermal state reached (badge) | Run 3 started badge-cool per protocol; the badge did not stay cool for the whole run — and per the house rule, **no attribution is claimed**: the device context (5G, recent charging) is noisy, and separating the pipeline's contribution needs a controlled protocol this session doesn't have. Recorded as observed, not explained. |
| `whisper.decode` drift within run 3 | none visible (3–311 ms band throughout) |
| `dropped` counter after all runs | **0** — the ring never lost a frame in any field session |

The unproven-need caveat, stated where it belongs: the `ThermalPolicy`
shipped in Phase 3b (D-028) is **insurance, not a measured cure** — this
table never proved the pipeline heats a phone. The policy's price matches
that honesty: its default is dormant below `.serious`, so if the pipeline
never truly runs a device hot, it never changes anything. What it declines
when heat does arrive — the settling decodes — is the one lever this
document's numbers identify (110 ms ANE bursts, ×2–3 under contention).

### The unpredicted finding of run 3

**Serialized Whisper settles almost like Apple.** 110 ms vs 73 ms average
for short conversational sentences — the "batch engine = seconds of felt
pause" assumption is dead at this utterance length. D-024's overlap
machinery remains correct and necessary for LONG utterances (the 46.5 s
fixture decodes in ~0.75 s), but a calm short-sentence conversation on
Whisper is, to the user's ear, indistinguishable from the streaming engine
minus partials. Also observed: no multi-second first-decode warm-up in this
run — CoreML's compiled-graph cache appears to persist per install, making
warm-up an install-time cost, not a launch-time one. (Claim held loosely:
one run, one device.)

## 5. The eager-Whisper number (AC-52) — closing the founding concession

Milestone 2b rejected "streaming Whisper" by reasoning: it re-decodes the
whole growing buffer every pass. The arithmetic, now with measured inputs:

- Measured (run 3): a short utterance decodes in ~**110 ms**; the 46.5 s
  fixture in ~0.75 s → decode cost ≈ **16–44 ms per second of audio** on
  this hardware, uncontended.
- Eager mode at ~1 decode/s over a 10 s utterance decodes 1 s, then 2 s,
  … then 10 s of audio: **≈ 55 s-of-audio decoded for 10 s spoken — about
  5–6× the compute of the single settle decode**, plus the confirmation
  delay before text stabilises.
- Field check: deliberately not run — the estimate now rests on measured
  inputs (uncontended decode cost per second of audio), and the marginal
  honesty of counting eager decodes live does not justify building the
  spike. The cell says "computed from measurements", and that is the truth.

The rejection stands or falls with this table — reasoning now has numbers
under it, which was the whole point.

## What the instrument caught (before any table was even full)

The first two field sessions found two real bugs the entire deterministic
suite could not see:

1. **The span leak (run 1).** Settle totals exceeded utterance totals —
   geometrically impossible by design — because the streaming-retirement
   branch dropped its spans and Instruments closed the orphans at
   recording-stop. One summary table convicted one branch.
2. **The concurrent decodes (run 2) — and their repair, proven (run 3).** Three `whisper.decode` intervals
   overlapping and finishing together: the engine claimed "one decode at a
   time, by actor isolation" — but an actor does not hold isolation across
   an await. The reentrancy law, violated by the code that preaches it.
   Three transcribes fought over one Neural Engine; each was ~3–5× slower
   than it should have been. (The device also showed *warm* — but the
   speaker disclosed it was charging and pre-heated for external reasons,
   so the heat is NOT claimed as our doing. Disclosed confounds beat
   flattering attributions.) Fixed with a real waiter queue; run 3 must
   show zero overlaps.

An observability phase that finds two correctness bugs before filling its
own tables has already paid for itself.

## Not measured (and said so)

Battery drain in mAh (needs a longer protocol than this session) · other
languages · far-field microphones · Apple engine on the Mac (asset daemon,
see README) · memory high-water marks under pressure.

## Reproduce

Product → Profile → os_signpost template → filter `dev.nooron.MultiModalKit`
→ speak → read the tracks. The badge and `decoding ×N` come free in the
demo's status bar.
