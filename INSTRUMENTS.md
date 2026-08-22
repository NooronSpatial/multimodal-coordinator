# INSTRUMENTS.md — what the pipeline costs, measured

Phase 3's founding sentence was a confession: *"excluded by reasoning,
never benchmarked."* This document is where that sentence comes to die.
Every number below is measured or visibly missing — no cell is filled by
opinion. Slots marked **⟨fill⟩** await the field session.

## Environment

- Mac numbers: Apple Silicon, macOS 26.6.1 (the development machine — a
  Mac mini, which has no built-in microphone: its input arrives from an
  iPhone over Continuity. Matters for §6; see the capture chain there).
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

## 6. The echo loop (Phase 4b, AC-82) — the assistant hearing itself

With a real mouth (`AVSpeechSynthesizer`) the pipeline gained a new way to
fail: its own voice reaches its own microphone, the VAD opens an utterance,
and since D-031 an utterance IS the barge trigger — so the assistant kills
its own reply mid-sentence.

**Captured before any fix** (Mac, `--talk`, Whisper, output volume 75, the
demo's own forensic lines):

```
💬 [1] weather today.                     ← ambient speech in the room, transcribed
   🤖 You said: weather today.            ← the assistant answers ALOUD
✋ [0] interrupted — listening to you instead    ← it barged ITSELF
⏱  [0] barge → dead in 1 ms
🔎 [2] 360 ms · peak rms 0.024 · 28 chunks       ← the utterance that killed it
```

**The echo path, isolated.** Method: no turn loop, so nothing on this
machine speaks except a scripted `say` through the speakers — a controlled
"user" that is reproducible and needs no human. Whisper transcribed it:
`💬 [0] Testing 123` at peak rms 0.037. The path is real, and it lands
just above the demo's 0.02 gate.

**The capture chain these echo numbers came through — state it, because
it is not the obvious one.** The development machine is a Mac mini, which
has NO built-in microphone: its default input is *"Ryad's iPhone
Microphone"* over Continuity, while the sound comes out of the Mac mini's
own speakers. So the echo path measured here is *Mac speakers → across
the room → iPhone → Continuity → the tap*, and the canceller is the Mac's
voice-processing unit applying the Mac's output as reference to a signal
captured elsewhere. It worked (numbers below), and the mechanism is
sound — an echo canceller needs the reference, not a particular
microphone — but a built-in-mic laptop has a shorter acoustic delay and a
different tail, so these ratios are this rig's, not a law. Re-measure on
any machine before trusting them.

(How this surfaced, and it is worth knowing: mid-session the tap went to
DIGITAL ZERO — frames still arriving, every sample 0.0000 — because the
iPhone dropped out. A missing microphone does not look like an error
here; it looks like a very quiet room. `--levels` is what told them
apart.)

**The F-2 spike (voice-processing input unit), measured with `--levels`.**
The pump publishes only sound the VAD already accepted, so "no utterances"
cannot distinguish *cancelled echo* from *deaf microphone*. `--levels`
reads the ring directly and prints what the microphone really delivers:

| | room silent | speakers playing `say` |
|---|---|---|
| voice processing **off** | rms 0.0045 · peak 0.024 | rms 0.0189 · **peak 0.136** |
| voice processing **on** | rms 0.0016 · peak 0.006 | rms 0.0016 · **peak 0.008** |

Three readings, three conclusions:
1. **The echo is cancelled** — peak 0.136 → 0.008 (~17×), rms 0.019 →
   0.0016 (~12×). No utterance opened at all in the `--aec` run.
2. **The microphone is NOT deaf** — it still delivers a live floor
   (0.0016 rms, 0.006 peak) while cancelling. The dangerous false
   positive is ruled out by measurement, not by hope.
3. **A bonus for 1d's marginal gate**: the ambient peak fell from 0.024 —
   which was *touching* the 0.02 gate and is exactly why this Mac's VAD
   flapped — to 0.006, comfortably below it.

**Two predictions this spike refuted** (both were written in the source
before it ran, and the correction stays visible there): that the unit
would only cancel audio rendered through *our* engine, and that its AGC
would lift room noise toward the gate. Neither happened on this machine.

**The after run — a human in the room** (`--talk --aec --gate 800`,
2026-08-14). What the machine-only tests could not answer, answered:

```
    voice processing: ACTIVE
🔎 [0] 1620 ms · peak rms 0.106 · 91 chunks      ← a real voice, heard clearly
💬 [0] How is the weather today?   (3.28 s)
⏱  [0] felt pause: 1549 ms
🤖 [0] You said: How is the weather today?       ← COMPLETED. No ✋.
🔎 [1] 1480 ms · peak rms 0.235
💬 [1] How is the weather today?   (18.48 s)
🔎 [2] 1320 ms · peak rms 0.235
💬 [2] Should I put the jacket?    (20.68 s)     ← he kept talking
⏱  [1] felt pause: 1495 ms
🤖 [1] You said: Should I put the jacket?        ← answered the FINISHED thought
```

Three readings:
1. **The echo loop is cured.** Two replies spoken aloud with the
   microphone live, and not one self-barge. Before the canceller, every
   reply died inside a second (`✋ … barge → dead in 1 ms`).
2. **The cure does not deafen it.** The human voice still lands at peak
   0.106–0.235 — an order of magnitude above what the canceller leaves
   of the machine's own speech (0.008). Speech and echo end up on
   opposite sides of the gate, which is the whole trick.
3. **The reply gate earned its keep.** Utterance [1] never got its own
   answer: the speaker carried on into [2] inside the 800 ms, so the
   assistant waited and answered the completed thought. Honest limit:
   in the field this outcome is indistinguishable from the D-024 stale-
   final door doing the same job — only the deterministic tests separate
   the two mechanisms.

Felt pause = 1549 and 1495 ms against an 800 ms gate, so ~700 ms is
pipeline (decode + first token + mouth) and the rest is the number the
app chose. The gate is the tunable part of the wait, and it is the app's
to tune (D-027).

**The last two answers came from ears, not instruments** (same session):
the reply stays comfortably loud with voice processing on, and a live
voice still barges it *during* its own speech — the acid test, since the
voice the canceller must ignore and the voice it must hear arrive at the
same moment. Both confirmed by the person in the room. That closed the
spike's gate and the canceller was adopted for the Mac demo (D-038).

**The 90-second conversation** (same configuration, later the same day):
five replies completed, one barge the speaker MEANT (he talked over the
reply; it died in 0 ms), zero self-barges. Felt pause across the whole
run: 1555 · 1489 · 1492 · 1486 · 1481 · 1503 ms — against an 800 ms
gate, so the pipeline's own share is ~690 ms and it is remarkably
steady. That is the cure holding under real use, not a single lucky
exchange.

The same run also produced the honest bad news, recorded in SPEC §46a:
four utterances (420–580 ms, peaks 0.039–0.084) decoded EMPTY — and the
speaker had been talking. Quiet speech, fragmented by the gate: subtract
the 300 ms hangover tail and a 420 ms utterance holds ~120 ms of voice,
so at 2–4× the gate his voice dipped under it between syllables and the
utterance closed mid-word. The engine got syllables and returned
nothing. (First written up here as ambient noise, on the first
description of the room; corrected when he said he had spoken. The
numbers never moved — their meaning did.)

Note what the canceller did to the number that gate was chosen for:
ambient peaks went from 0.024 to 0.006, so 0.02 is now far more
conservative than when it was picked to beat a flapping 0.01 (D-035/36).
That suggested lowering the gate — and the field said no.

**The knob hunt, in order, with what each run actually proved:**

| run | gate | hangover | quiet sentence | empties |
|---|---|---|---|---|
| baseline | 0.02 | 300 ms | shattered (4 pieces, 0.039–0.084) | 4 |
| lower gate | 0.008 | 300 ms | not re-tested | 4 @ 0.009–0.011 (ambient) |
| bracket | 0.012 | 300 ms | **still shattered** (4 pieces) | 3 @ 0.014–0.023 |
| **hangover** | **0.02** | **700 ms** | **WHOLE — 2300 ms, one utterance** | **0** |
| bracket down | 0.02 | 500 ms | cut short (1080 ms, tail lost) | 0 |

The 500 ms run bracketed the minimum from below, and the cleanest
evidence in it is a phrase spoken in BOTH runs — a natural controlled
comparison:

```
700 ms:  "Hello my friend, how is the weather today?"   → one utterance (3060 ms)
500 ms:  "Hello my friend!" + "How is the weather today?" → two (1340 + 1760 ms)
```

500 ms is better than 300 ms — it splits sentences instead of
shattering them, and produced no empty decodes — but a split is still a
premature final, and every premature final is another chance for the
assistant to answer half a thought. The true minimum lies between 500
and 700; it was not chased further, because a speaker's pauses vary by
the day and the margin is worth more than the 100 ms.

**Confirmation run on the ruled defaults** (700 ms, gate 0.02, canceller
on, reply gate 0): the sentence that shattered into four empty fragments
at 300 ms arrived as one 2340 ms utterance at peak 0.080 — and Whisper
returned the REAL words, "Do you think should I put my jacket?", not the
"Debra"/"check" garble it produced from syllables. Whole input, whole
output.

That run also separates policy cost from pipeline cost, because the
reply gate was zero: **felt pause 743 ms**. It closes D-039's
arithmetic — 743 + 800 = 1543 ms, against the 1481–1572 ms measured
with an 800 ms gate. The pipeline costs what it costs; the gate is the
number a product chooses, and it is the larger of the two.

The threshold hypothesis was mine, it was tested twice, and it failed
twice — the pieces at 0.040 and 0.042 sat at the same level as a
fragment that decoded fine, which is what finally pointed at the dip
budget instead. The gate says whether a chunk is loud; the hangover says
how long a silence is forgiven, and quiet speech is mostly forgiven
silence. Cost of the fix, stated where the number lives: every final
waits 400 ms longer, on every turn.

**Not measured, and said so:** whether voice processing changes
transcription accuracy. The after run's three clean utterances are an
anecdote; BAKEOFF.md is the instrument if that question ever needs a
real answer.

## Not measured (and said so)

Battery drain in mAh (needs a longer protocol than this session) · other
languages · far-field microphones · Apple engine on the Mac (asset daemon,
see README) · memory high-water marks under pressure · echo cancellation
on iOS (measured on the Mac only) · whether the voice-processing unit
alters what a human hears from the speakers.

## Reproduce

Product → Profile → os_signpost template → filter `dev.nooron.MultiModalKit`
→ speak → read the tracks. The badge and `decoding ×N` come free in the
demo's status bar.

## 7. Milestone 4c in the field — the whole thought, seen

The run that milestone 4c exists for (2026-08-14, `--talk --gate 800`,
700 ms hangover, canceller on). The `🧠` line is the GENERATOR's own
view: what actually crossed the seam.

```
💬 [2] Do you hear me? Well...                      ← sentence one
💬 [3] Can you understand what I'm telling you?     ← sentence two, after a pause
🧠 whole thought → "Do you hear me? Well... Can you understand what I'm telling you?"

✋ [1] interrupted — listening to you instead       ← the speaker barged
💬 [4] She'll die take a jacket.                    ← "should I take a jacket"
🧠 whole thought → "Do you hear me? Well... Can you understand what I'm telling you?
                    She'll die take a jacket."
```

Before 4c, utterance [2] was refused at the input door and discarded, and
the reply answered [3] alone — the bug §46a finding (2) recorded. Both
lines above are the fix, and the second is also **D-040 F-3 working
live**: the barged thought carried forward and the third sentence joined
it, because a reply that was interrupted never answered anything.

**Not proven by this run, and not claimed:** clear-on-completion. No
reply completed here — both were barged — so the ledger never emptied.
That path has tests, not field evidence.

**Still open, and visible again:** three utterances decoded empty at peak
0.021–0.024 (720 ms each) — ambient just over the 0.02 gate, consistent
with the 0.023 ceiling measured in §6. They contributed NOTHING to the
thought, which is the ledger's whitespace rule doing its job, but each
still cost a decode and each was a live barge trigger. §46a finding (1)
stays open.

**And the honest limit of this milestone:** the speaker was still
interrupted mid-thought. 4c does not fix §46a finding (3) — no fixed
timer separates "still thinking" from "done talking" — it makes the
interruption *cheaper*, because when the assistant finally answers, it
answers everything that was said instead of the last fragment.

## 8. The phone's echo — measured, and the cheap fix ruled out (AC-96)

The Mac's canceller numbers never transferred, exactly as the milestone
insisted they might not. Measured on Ryad's iPhone with the app's own
echo probe — which reads the ring DIRECTLY, past the VAD, so "nothing
happened" can never be confused with "the microphone is deaf":

| session mode | route | quiet room peak | while SPEAKING peak | voice processing |
|---|---|---|---|---|
| `.default` | speaker | 0.0030 | **1.0000** (full scale) | ACTIVE |
| `.voiceChat` | speaker | **0.0008** | **0.9391** | ACTIVE |

And the same probe on the RECEIVER, twice:

| session mode | route | quiet room peak | while SPEAKING peak | verdict at gate 0.010 |
|---|---|---|---|---|
| `.voiceChat` | receiver | 0.0099 | 0.0094 | under — by **6 %** |
| `.voiceChat` | receiver | 0.0002 | 0.0044 | under — the reply adds ~0.004 over the floor |

At the gate this device then EARNED for itself (AC-97), the margin stops
being uncomfortable:

| session mode | route | gate | quiet room peak | while SPEAKING peak | margin |
|---|---|---|---|---|---|
| `.voiceChat` | receiver | 0.020 | 0.0008 | 0.0063 | 3.2× |
| `.voiceChat` | receiver | 0.020 | 0.0000 | 0.0053 | 3.8× |

Those two runs also served as an accidental CONTROL: one was taken with
Apple selected and one with Whisper, and the probe touches no engine at
all — it starts the microphone, speaks, and reads the ring. Same result
either way, which is what says the 0.0063/0.0053 difference is room
variation rather than anything about an engine. It also weakens the one
loose end still unexplained from the first device run ("lowering the
volume helped Apple but not Whisper"): the echo path is now measured as
engine-independent at two separate points.

**And the third number, arrived at by accident.** One probe was run
while the speaker TALKED through it — which voids the verdict line (it
assumes silence) but measures the thing no other run had: a human voice
on this route, at **peak 0.2540**. The picture that completes:

```
   echo leak      0.0044 – 0.0094      ← must stay UNDER the gate
   gate           0.020                ← 2–4x above the leak
   human voice    0.2540               ← 13x above the gate
```

Ten-fold separation at both ends. That is AC-97 answered by measurement
rather than by choosing a number that felt safe — and the probe now
prints "valid only if nobody spoke during the measurement", because this
run read as a failure when it was in fact the best result of the day.

**Why the receiver works, stated precisely, because the easy phrasing is
wrong.** It is not that the canceller works there. The canceller is
exactly as blind on the receiver as on the speaker — it cannot see
`AVSpeechSynthesizer` either way. The receiver is quiet and aimed at an
ear, so ~200× less of the reply reaches the microphone (0.9391 →
0.0044). That is ACOUSTIC ISOLATION doing the work, and it is worth
saying because the two explanations predict different futures: a louder
voice, a smaller room or a lower gate breaks isolation, and one run
already came within 6 % of the gate.

Read the rows twice, because they say two different things.

**The canceller works.** It is not refused, and it is not idle: it takes
the room's own noise floor down — threefold under `.default`, and
another fourfold under `.voiceChat` (0.0092 unprocessed → 0.0008).

**And it never sees the reply.** The assistant's own voice arrives at
the microphone at essentially full scale under both modes. Voice
processing cancels what ITS OWN audio unit renders;
`AVSpeechSynthesizer` plays on a separate path. The macOS spike (§6)
proved cancellation of audio from a whole separate PROCESS, so the
reference is system-wide there — one platform measured, and iOS is not
the same platform.

**What these numbers retire.** Tuning. Human speech peaks around
0.1–0.3 here; the echo peaks at ~1.0, so on this route **the echo is
louder than the person**. No gate separates them: raising it would
silence the speaker before the phone. An entire line of work, closed by
one measurement.

**The cheap fix, tried and ruled out.** `.voiceChat` is the session mode
built for full-duplex speech, and it was the one-line hope. It is kept —
the noise floor it buys is real and measured — but it is NOT the answer:
same route, same probe, still 0.9391. Ruled in D-043: the finding ships
with milestone 4d and the routing fix becomes 4f, after TTSKit.

## 9. Milestone 4d on the phone — the conversation, and one false alarm

**AC-92 PASSED on hardware** (2026-08-15, receiver route, gate 0.020,
`.voiceChat`, Ryad's iPhone): the phone holds a conversation — it
listens, replies aloud through `AVSpeechSynthesizer`, and **a live voice
barges it**. The same `TurnCoordinator`, `TranscriptLedger`,
`SpeechPhraser` and mouth the Mac runs, with no iOS variant of any of
them. That was the milestone's thesis (AC-92) and it held: the whole
diff was platform reality.

**The false alarm, kept because it earned a change.** An earlier attempt
reported "it kept talking when I talked", which read as a barge-in
failure — the project's thesis breaking on a new platform. Two causes
fit equally well (the microphone never opening, or the mouth ignoring
its cancel), and the screen could not tell them apart. The real cause
was neither: the Listen button had not been tapped, so no pipeline was
running at all.

What it exposed is still real: an acceptance criterion that could only
be judged BY EAR. So the screen now counts both halves separately —
`onsets while speaking` (what the pump heard) and `barges` (what the
coordinator did about it). They fail apart, which is the point:

```
both climbing    → the barge works, the mouth is deaf to cancel
only onsets      → the coordinator never acted
neither          → the microphone never heard the voice
```

Three different bugs, one glance — and AC-92 becomes a number instead of
an impression.

## 10. The second mouth's gates (AC-102) — and two corrections to get there

**The question the ruling needs answered** (D-045): can the Qwen3 neural
voice speak inside a conversation, where the felt pause is already
~743 ms? Three gates: time to first audio, stop latency, thermal.

**Setup.** M-series Mac, **release build**, `swift run -c release bakeoff
voice-spike`. Qwen3-TTS 0.6B, 24 kHz, decoded by TTSKit and rendered by
this project's own `AVAudioPlayerNode` (D-045 F-1 = B). Warm-up utterance
excluded — the first load compiles CoreML graphs. Both mouths driven
through the SAME `SpeechSynthesizing` seam, so the numbers are comparable
by construction rather than by argument.

### Gate 1 — time to first audio

| sentence | mouth | first audio | total |
|---|---|---|---|
| How is the weather today? | neural | **218 ms** | 6347 ms |
| How is the weather today? | Apple | **66 ms** | 1777 ms |
| The audio travels through a ring b… | neural | **226 ms** | 9216 ms |
| The audio travels through a ring b… | Apple | **8 ms** | 4598 ms |
| Should I take a jacket? | neural | **238 ms** | 2987 ms |
| Should I take a jacket? | Apple | **8 ms** | 1558 ms |

**first-audio mean — neural 227 ms · Apple 28 ms · ratio 8.3×.**

227 ms is a real cost against Apple's 28 ms, but it is not a
disqualification: it adds ~200 ms to a pause already near 750 ms.

### Gate 1b — the margin, which is the actual problem

A streaming voice must decode audio at least as fast as the ear drinks
it. The real-time factor is decode wall time ÷ audio produced.

```
MARGIN · 5760 ms audio decoded in 6258 ms wall · RTF 1.09
MARGIN · 8240 ms audio decoded in 9129 ms wall · RTF 1.11
MARGIN · 2400 ms audio decoded in 2889 ms wall · RTF 1.20
```

**RTF 1.09–1.23 — above 1.0 on a Mac.** The voice decodes SLOWER than it
plays, so the player runs dry. The arithmetic says so without needing an
ear: for the long sentence, gapless playback would end at first-audio +
audio = 226 + 8240 = **8466 ms**. It ended at **9216 ms**, which is
decode wall time (9129) plus one buffer. Playback is gated by decode —
every ~80 ms buffer arrives ~10–18 ms late, from the first one, because
this integration starts playing with ZERO lead.

This is precisely the cost D-045 F-1 accepted when it chose to render the
audio itself: *"pre-buffering and resampling become ours to get wrong."*
It is ours, and this is it. iPhone is not measured yet and will be worse.

### An anomaly, recorded rather than explained

"How is the weather today?" produced **5760 ms of audio** — Apple speaks
the same five words in 1777 ms. Two other sentences look normal. Whether
this is trailing silence or the model rambling, this spike cannot say;
AC-103's round-trip WER is the instrument that will. Recorded here so it
is not discovered later as a surprise.

### Not measured, and not claimed

**Stop latency** (barge → the room actually quiet) and **thermal**. The
seam reports its own bookkeeping instantly; proving SILENCE needs the
microphone probe on the device. Both remain open against AC-102.

### Two corrections, kept because the record is the point

**1. A debug build.** The first run reported neural first-audio of
**6066 ms** — a 217× ratio that would have condemned the voice on the
spot. It was a debug build, which TTSKit's own docs name as a slow case.
Caught before it was written down; the number above is release.

**2. The harness was the slow part.** The first release run still said
**4910 ms**, and it was wrong for a worse reason. `measure()` fed the
whole sentence, closed it, and only THEN read the update stream:

```swift
await run.feed(text)                     // neural: does not return until decode ends
await run.finishTokens()
for await update in run.updates { … }    // .started stamped when READ, not when SENT
```

Apple's `feed` hands off and returns at once, so only the neural side
paid. The tell was sitting in the table — **neural first-audio within
~100 ms of neural total, on every row** — which is the signature of a
number taken at the end. A per-step trace settled it: audio steps arrive
every ~80 ms from the start, not after 5 seconds. The reader now parks on
the stream first and the feeding moves to a child task, gated on a fact
rather than a sleep. **The corrected number is 21× smaller than the one
this file nearly recorded.**

## 11. The lead — the gaps closed, and what they cost (AC-107, D-046 = A)

`PlaybackLead` banks audio before the player starts, sized by the rule
`deficit = replyLength × (RTF − 1)`. Default: a six-second reply at the
worst measured factor (1.25) → **1500 ms**.

**Did the gaps close?** The arithmetic answers without an ear. Gapless
playback ends at first-audio + audio; a starving player ends at decode
wall time instead.

| sentence | audio | first + audio | measured total | miss |
|---|---|---|---|---|
| How is the weather today? | 5760 ms | 7572 ms | 7594 ms | **22 ms** |
| The audio travels through a ring b… | 6480 ms | 8384 ms | 8412 ms | **28 ms** |
| Should I take a jacket? | 2240 ms | 4168 ms | 4190 ms | **22 ms** |

Every miss is under a third of ONE 80 ms buffer. Before the lead, the
long sentence missed by **750 ms**. The player no longer runs dry.

**What it cost.**

| | first audio | vs Apple |
|---|---|---|
| no lead (AC-102) | 227 ms | 8.3× |
| 1500 ms lead | **1882 ms** | **61.8×** |

1882 rather than 1500 because banking 1500 ms of audio takes 1500 × RTF
of wall time, plus the first step's ~220 ms. The felt pause of a turn
would go from ~743 ms to well over two seconds. **Gapless, and too slow
— which is the whole argument for D-046's other half.** If B gets RTF
below 1.0 the lead goes to zero and both numbers are won at once.

**A limit, stated rather than discovered later:** a FIXED lead has a
ceiling. While RTF stays above 1.0 a long enough reply drains any
cushion; 1500 ms covers ~6 s of speech at RTF 1.25 and no more.

**Two things this run also showed, recorded without explanation:**

1. **The voice is non-deterministic in LENGTH.** The long sentence
   produced 8240 ms of audio in the AC-102 run and 6480 ms here — same
   text, same model, same machine. Sampling, presumably. It means every
   number in this section is one draw, not a constant.
2. **The weather anomaly is repeatable.** "How is the weather today?"
   produced 5760 ms of audio in BOTH runs, where Apple speaks it in
   1829 ms — 3.1×. Repeatable is worse than random: it is a property of
   the voice on this input, and AC-103's round-trip WER is the
   instrument that will say whether those extra seconds are silence,
   drawl, or invention.

## 12. Attacking the decode (AC-106, D-046 = B) — one lever won, one vendor claim died

Nine candidate levers survived adversarial verification against the
pinned `argmax-oss-swift` checkout; five families were closed on paper
(no smaller model exists — the only other variant is the 1.7B; no faster
asset string; the prompt cache is already optimally placed; `prewarm`
compiles and discards; logging has no per-step cost). The rest were
measured serially — one machine, one run at a time, because two models
decoding at once would corrupt both timings.

### First, a correction to our own instrument

`reportMargin` clocked from the run's BIRTH, so every factor carried a
fixed ~210 ms of prefill. Divide one fixed cost by three different audio
lengths and you get three different factors for one decoder: **AC-102's
"RTF 1.09–1.23" was largely the shortest sentence failing to amortise
prefill, not a decoder that changes speed.** Prefill and STEADY rate are
now reported separately. The steady baseline is **1.066**, not 1.25 —
which means §11's lead was sized against a number that was partly an
artefact of how we measured.

### The matrix — median STEADY of 3 runs, release, M-series Mac

| config | steady RTF | prefill | verdict |
|---|---|---|---|
| baseline (`.stepped` + `.latencyOptimized`) | 1.066 | 207 ms | — |
| **`.fused`** | **0.752** | **171 ms** | **the win** |
| `.throughputOptimized` | 1.148 | 535 ms | worse on both |
| `.fused` + `.throughputOptimized` | 0.766 | 386 ms | worse than fused alone |
| temperature 0 (on `.stepped`) | 1.036 | 217 ms | inside noise |
| temperature 0 (on `.fused`) | 0.815 | 165 ms | worse than fused alone |

**`.fused` takes the decoder below 1.0.** It replaces ~35 CoreML
predictions per 80 ms frame with about 5, doing the whole 15-code frame
in one prediction with in-graph sampling. Dispatch overhead, not matrix
maths, was where our time was going.

**A vendor claim, refuted on our hardware.** Argmax's own table (M4,
default compute units) reports `.throughputOptimized` as the faster
vocoder path — 1.32× against 1.18×. On this machine it is **slower**
(1.148 vs 1.066) and its prefill is 2.6× worse. Their number is not
wrong; it is theirs. This is why the spike discipline exists.

### End to end, with `.fused` and the lead at ZERO

| sentence | audio | decode wall | first + audio | measured total | miss |
|---|---|---|---|---|---|
| How is the weather today? | 3600 | 2929 | 3822 | 3870 | 48 ms |
| The audio travels through a ring b… | 9360 | **7190** | 9529 | 9567 | 38 ms |
| Should I take a jacket? | 3040 | 2591 | 3336 | 3391 | 55 ms |

**first-audio mean — neural 229 ms · Apple 32 ms · ratio 7.1×.**

Every miss is under ONE 80 ms buffer, and decode wall now finishes
*before* the audio does — 2.2 s early on the long sentence. With the
decoder ahead of the ear there is no deficit to bank, so §11's 1500 ms
cushion is not needed on this Mac: **gapless AND 229 ms, together.**

### Two bugs the investigation found, neither of them a speed knob

**1. Our streaming was one long phrase away from silently stopping.**
`GenerationOptions.concurrentWorkerCount` defaults to 0, "all chunks
concurrently in one batch". On that path TTSKit hands the streaming
callback `audio: []` on every step and delivers real samples only after
the whole batch finishes. Any reply long enough to split into two chunks
would have stopped streaming — no lead, first-audio back to full decode
time — and only for long replies, which is why every sentence measured
so far missed it. TTSKit's own `play()` sets this to 1 for exactly this
reason. Now so do we.

**2. A phrase with nothing to say cost up to 19.6 seconds.**
The conformance kit's liveness promise feeds whitespace. The phraser
cuts it into whitespace-only phrases, and an autoregressive voice given
no letters to end on decodes toward its 245-step cap — ~19.6 s of audio
for a phrase containing nothing. Several in a row pushed the suite past
its four-minute limit; other times the model stopped early and the test
passed in 9 s. **A test whose duration depends on when a model feels
like stopping is flaky by construction**, and it was a product fault
first: the turn loop waits inline, so one stray whitespace phrase buys
twenty seconds of dead air. `SpeechPhraser.hasSpeakableContent` (letters
or digits, any script) now answers first. That liveness test went from a
240-second timeout to **0.001 s**, and the suite from 251 s to 7.5 s.

### Not measured, still not claimed

**iPhone** (slower silicon, and `.fused` needs iOS 18), **thermal**,
**stop latency**, and **whether `.fused` SOUNDS right**. Its audio
lengths are plausible and more consistent than `.stepped`'s, which is
weak evidence and labelled as such — AC-103's round-trip WER is the
instrument, and no adoption should precede it.

### Stability, and one measurement thrown away

**20 × full suite: 20 passed, 0 failed** (200 tests, 23 suites), on a
quiet machine.

An earlier attempt reported 13 of 20 failing and was **discarded as
invalid, because I caused it**: that loop ran while I was editing
sources and running a release build against the same `.build`, and the
check counted a build error as a test failure. It is recorded here
rather than deleted, because a stability number measured under
interference is worse than no number — it would have sent the next hour
hunting a race that did not exist. The rule it earns: a stability loop
owns the machine, exactly like a timing run.

Note also that the whitespace fix above removed a REAL flake source —
one whose failure rate depended on when a language model chose to stop.
That is a different flake from the unexplained one recorded against 4d,
and claiming otherwise would be tidy rather than true.

## 13. The listening test (AC-103, the opinion half) — a wash, and why that is useful

Blind A/B, `.stepped` vs `.fused`, seeded order (20260816), Apple played
first each round as an unblinded reference. One listener (Ryad), three
rounds, on his own machine and speakers.

| round | clip A was | clip B was | preferred |
|---|---|---|---|
| 1 — "How is the weather today?" | stepped | fused | **fused** |
| 2 — "I can hear you. Say that again…" | stepped | fused | **no difference heard** |
| 3 — the long technical sentence | fused | stepped | **stepped** |

**fused 1 · stepped 1 · no difference 1.**

**This is an OPINION from one listener over three rounds, and it is
recorded as one.** It is not evidence that either decoder sounds better.

**What it does establish, and it is the thing that mattered:** `.fused`
is not audibly broken. It moves sampling inside the CoreML graph, so its
draws differ from `.stepped`'s, and the real risk was a garbled or
swallowed word rather than a different voice. A broken decoder loses
3–0 to a working one. This one drew.

**The limit of the design, stated because it is not obvious.** §11
recorded this voice producing 8240 ms of audio for a sentence in one run
and 6480 ms in the next — **the model is non-deterministic in length**,
and the seed did not fix it (only greedy sampling did, and greedy was
measurably slower). So each clip in this test is ONE DRAW. A listener
comparing one draw against one draw is comparing draws at least as much
as decoders. To hear a real preference you would need several draws per
decoder per sentence, randomised — which is a bigger test than the
question currently justifies.

**The instrument that can settle it is the other half of AC-103**:
round-trip WER (speak → record → transcribe → compare against the source
text), which is a number, survives non-determinism by averaging, and
measures the thing that actually matters in a conversation —
intelligibility, not taste.

## 14. Round-trip WER (AC-103, the objective half) — and why one run would have lied

speak → capture at the mixer → transcribe with Whisper → WER against the
text we asked for. Intelligibility as a NUMBER, graded by an engine this
repo already owns: a pipeline that can listen can grade its own mouth.

The capture is taken at the engine's mixer — the last point before the
speaker — so it includes our own rendering, resampling and buffering.
Capturing the model's raw 24 kHz PCM instead would have flattered us by
measuring the decoder rather than the pipeline.

Three sentences, **3 draws per neural mouth per sentence** because this
voice is non-deterministic in length (§11, §13), and one draw for Apple
because it is not.

### The result, from TWO runs

| | stepped | fused |
|---|---|---|
| run A (9 draws each) | 0.122 | **0.000** |
| run B (9 draws each) | **0.044** | 0.148 |
| **combined, 18 draws each** | **0.083** | **0.074** |

Apple: **0.000** across all draws.

**The two decoders are indistinguishable.** Between-RUN variance is
larger than the difference between them, which is the only honest
reading of a 0.122/0.000 result followed by a 0.044/0.148 one.

**This is the finding, and it is about method rather than about TTS.**
Run A alone says fused is flawless and stepped is flawed. Run B alone
says the reverse. Either, written up on its own, would have been a clean
convincing table supporting a conclusion that the next run destroys. The
replication cost five minutes. It was the difference between a number
and an opinion wearing a number's clothes.

It also agrees with §13's listening test, which was a wash. Two
independent instruments, one subjective and one objective, both say
there is no quality difference to find here.

### A discarded run, and the bug it was measuring

An earlier run reported **fused 0.384 against stepped 0.058** — a
6× difference that looked decisive. It was mine. Three of nine fused
draws transcribed to the empty string, and all three followed a stepped
draw, because both voices shared ONE `AVAudioEngine` and each reply's
teardown detaches its player node from that graph. The measurement was
of my race, not of a decoder.

Two things came out of it, and they are the reason it is recorded rather
than deleted:

- **The tool now prints what it captured** — duration and peak amplitude
  — beside every WER. An empty transcript can mean an unintelligible
  voice or an empty capture, and those lead to opposite conclusions.
  With peaks now all in 0.19–0.59, "the capture was fine" is evidence
  rather than an assumption.
- **A real leak in the library**: `NeuralVoiceRun` attached a player node
  per reply and never detached one. A long conversation grew its audio
  graph without bound, and an engine handed in by a caller collected
  dead nodes for the life of the app.

### One more library correction this work forced

Buffers were scheduled with the legacy completion, which reports when the
player has **consumed** data — up to a buffer before any of it reaches
the room — and that count is what decides `.finished`, whose meaning
under D-029 is "the room is quiet". Now `.dataPlayedBack`.

The switch immediately hung this tool at 0% CPU, which was the callback
being *correct*: the tool had started the engine before any player node
existed, an engine with no source never pulls, so the node attached
afterwards never rendered and its buffers were never played. The old
callback would have reported them done and produced a table of silence.
**The hang was the honest failure of a more honest callback.**

### What the numbers do NOT settle

- **The voice emits non-speech.** Whisper heard `*crying*`,
  `(laughing)`, `"Ha,"` and `"Uh uh, uh,"` in draws from BOTH decoders.
  That is a property of the model, not of a decoder, and for a
  conversational assistant it is a real hazard. Unmeasured beyond
  "it happens", and owed a decision.
- **Speaking rate.** The neural voice takes 6.6–15.9 s for a sentence
  Apple speaks in 4.29 s — roughly 2× slower, on both decoders.
- **One grader.** Whisper only; the Apple transcription engine was not
  used as a second opinion.
- **Apple's capture is not our shipping path.** `AVSpeechSynthesizer`
  does not render through our engine, so its audio comes from the
  framework's offline `write` — the same voice, not the same code path.

## 15. The shipped configuration (D-047) — what the default actually does now

`.fused`, lead **0 ms** (derived from the measured 0.752, not chosen).

| sentence | first audio | audio | first + audio | measured total | miss |
|---|---|---|---|---|---|
| How is the weather today? | 162 ms | 2880 | 3042 | 3131 | 89 ms |
| The audio travels through a ring b… | 168 ms | 6240 | 6408 | 6494 | 86 ms |
| Should I take a jacket? | 294 ms | 3680 | 3974 | 4062 | 88 ms |

**first-audio mean — neural 208 ms · Apple 30 ms · ratio 7.0×.**
Steady RTF 0.765–0.797.

The whole journey of one number:

| | first audio | gapless | steady RTF |
|---|---|---|---|
| AC-102, as found | 227 ms | **no** | 1.066 |
| + the lead (D-046 A) | 1882 ms | yes | 1.066 |
| + fused (D-046 B, D-047) | **208 ms** | yes | **0.765** |

**On the misses being 86–89 rather than 38–55.** That is not a
regression, it is `.dataPlayedBack`: the completion now waits for audio
to actually play, so the device's own output latency is inside the
number. What matters is that the three misses are within 3 ms of each
other — a starving player produces misses that are large and variable,
like the 750 ms one in §10.

**Still unmeasured, and the lead's zero is measured only here:** the
iPhone (AC-104), thermal, and stop latency. `NeuralVoice`'s sizing rule
reads one named constant, so a slower measurement puts the cushion back
by changing that constant rather than by re-deriving the argument.

## 16. The phone's gate, earned the hard way (AC-97, AC-104)

**0.020 was too low on this iPhone, and it silenced the app completely.**

Field, 2026-08-16, iPhone, speaker on, Apple STT + neural voice. The
screen showed utterances opening at **peak 0.022, 0.030, 0.040** against
a gate of **0.020** — room noise, barely over the line. Every one of
those was an onset, and an onset while the app is thinking is a barge.
So every reply was cancelled before it made a sound, and the state sat
at "thinking" forever. Ryad's words: "i hear nothing and the state is
thinking!"

**Raising the gate to 0.060 made it speak.** One slider, and the
symptom went.

Two things worth separating, because they arrived together:

- **The gate is the cause.** 0.020 was earned in Phase 2 on a Mac, when
  this app only LISTENED. AC-97 already said the phone earns its own,
  and this is the phone earning it: 3× the Mac's value, on hardware
  where the noise floor sits at 0.02–0.04.
- **The barge fix made it VISIBLE.** Until `feed` handed off, a barge
  queued behind a whole phrase decode, so a false onset often arrived
  too late to kill the reply. Making barge-in correct is what turned an
  intermittent annoyance into total silence. A fix that exposes a
  second fault is still a fix; it is not the cause.

### Two real crashes and one refusal, found in the same session

**`detach` aborts the process.** `AVAudioEngine.detach` asserts when the
node is no longer in the graph, and it is an ObjC assertion, so nothing
can catch it. Two causes, both ours: nodes were detached AFTER
`engine.stop()` (they are in no chain by then), and our own bookkeeping
was trusted over the engine's — `AVAudioEngine` drops nodes by itself on
any reconfiguration, including the speaker being switched, and never
says so. Fixed, with a regression test that lets the engine take a node
back behind our back.

**`auou/vpio/appl, render err: -1`, repeating.** The capture engine
started with a microphone tap and NO output chain. The first reply then
called `engine.connect(player, to: engine.mainMixerNode)` — and touching
`mainMixerNode` for the first time creates it and wires it to the output
node. So the entire output half of a LIVE voice-processing unit was
being built while it was rendering, which VPIO refuses, every cycle.
The chain is now established inside `start`, before the engine runs, so
a reply only adds an input bus to a mixer that already exists.

**Honest status: that last fix is UNVERIFIED on hardware.** The gate
change is what made the phone speak, on the build without it. Whether
the render errors stop is the next thing to look at, and it is not
claimed here.

## 17. Why the neural voice would not talk — measured on a Mac, not on Ryad

Five field runs, five faults, and each time I answered with a hypothesis
and sent Ryad back to his phone. That was the wrong shape. **This Mac
has a microphone and voice processing**, so it can run the exact path
the phone runs — a live capture engine with a reply rendered onto it —
and it took one command to reproduce.

`swift run bakeoff voice-onmic`, one variable:

| output chain on the capture engine | capture starts? | input format |
|---|---|---|
| **yes** (the neural path, AC-108) | **NO** | 0 Hz, 0 channels |
| no (the pre-AC-108 path) | yes | 48000 Hz |

Then the full truth table, four combinations:

| voice processing | output chain | result |
|---|---|---|
| on | **on** | **FAILS — `-10875` at `PerformCommand(*outputNode, kAUInitialize)`** |
| on | off | starts, 48000 Hz / 3 ch |
| off | on | starts, 48000 Hz / 1 ch |
| off | off | starts, 48000 Hz / 1 ch |

**Voice processing and an output chain on the same engine cannot both
exist here.** That is precisely the AC-108 configuration. Capture never
starts, so the state can only ever read `idle` — which is exactly what
the phone showed.

### Two mechanisms, separated

**1. Touching `mainMixerNode` invalidates `inputFormat`.**

```
after voice processing   input 48000 Hz/3ch   inputNode.output 48000 Hz/3ch
after mainMixerNode      input     0 Hz/0ch   inputNode.output 48000 Hz/3ch
after prepare            input     0 Hz/0ch   inputNode.output 48000 Hz/3ch
```

`inputFormat` collapses; `outputFormat` does not. A tap observes what a
node PRODUCES, so `outputFormat` was the correct property all along —
this code had been reading the other one, and the difference only shows
when something else touches the graph.

**2. Handing an invalid format to `installTap` is not an error, it is an
ABORT** — `IsFormatSampleRateAndChannelCountValid`. A microphone that is
merely unavailable became a crash report. It is now
`AudioSourceFailure.inputUnavailable(sampleRate:channels:)`, which a
screen can show in words.

### What this does NOT prove

**That iOS behaves the same way.** `-10875` on a Mac is consistent with
voice processing requiring one device for input and output, and a Mac
routinely has two. A phone has one. So the Mac reproduces the SYMPTOM
and names two real bugs, but it cannot convict iOS of the same cause —
and the iPhone's five faults are equally consistent with the ordering
bugs found and fixed along the way.

Recorded plainly because the temptation is to call this settled. It is
not. What is settled: two real bugs, a path that is un-runnable on this
Mac, and a harness that can test it here instead of on a person.

### A late measurement that complicates §17, recorded because it does

After D-049 was ruled, the same harness was run once more with the
mixer created LAZILY — at the first reply, the way AC-108 originally
did it — instead of at capture start:

```
capture running: true · voice processing: true · input rate 48000 Hz
utterance 1: started YES · finished YES · 4986 ms · reconfigs 0
```

**It worked.** The neural voice rendered onto a live capture engine with
voice processing active, on this Mac, and both the start and the finish
arrived.

So the truth table above is narrower than it first reads. What it
proves is that creating the output chain **before `engine.start()`**
cannot coexist with voice processing here. It does NOT prove that
rendering onto the capture engine is impossible — the original lazy
arrangement is fine on this machine, and it was the phone, not the Mac,
that answered it with `vpio render err: -1`.

Which means the Mac still cannot settle the deciding case, and that is
exactly the reasoning D-049 rests on: not "this cannot work", but "I
cannot test whether it works, and the person holding the phone should
not be the harness". 4f inherits a real question and a real tool for
asking it.

## 18. The neural voice on iPhone — it speaks, and it still sounds wrong

**D-049 validated in the field, 2026-08-16.** With the reply rendered on
the voice's OWN engine and the gate calibrated on the device, Ryad's
iPhone speaks with the Qwen3 neural mouth. The same `TurnCoordinator`,
`TranscriptLedger`, `SpeechPhraser` and `SpeechSynthesizing` seam that
drive Apple's mouth, driving a completely different one, on a phone,
with no iOS variant of any of them. That was 4e's thesis and it holds.

**And the voice still sounds wrong.** Ryad: *"after i changes the gate
it worked but the voice still weired."*

That is not a new fault and it is not fixable in this repo. It is the
model, measured three separate times on a Mac where playback was proven
gapless (§15: misses of 89/86/88 ms, within 3 ms of each other):

| property | measurement | where |
|---|---|---|
| speaks ~2× slower than Apple | 6.6–15.9 s vs 4.29 s | §14 |
| same words, different length | 8240 ms vs 6480 ms | §11 |
| inserts non-speech | `*crying*`, `(laughing)`, `"Ha,"`, `"Uh uh, uh,"` | §14 |

Half speed, uneven, with occasional laughing — on both decoders, on both
platforms, with the audio pipeline proven clean. **The phone did not
create this and no buffering will remove it.**

### What the whole day actually established

- The seam works, on two mouths, on two platforms. **Proven.**
- The neural voice is intelligible: round-trip WER 0.074 against
  Apple's 0.000, over 18 draws (§14). **Measured.**
- It is not pleasant, and that is a property of the model. **Measured
  three ways, and heard by the one person whose opinion this was.**
- Rendering a reply on the capture engine is unsolved, and now has a
  harness instead of a volunteer (§17, D-049).

## 19. The stability loop caught a process abort I had introduced

**19/40, then 39 of 40 failing** — and none of them a race.

The 4e hygiene gate ran 20× and lost one round. A second 20× passed
clean. A third run of 40 lost 39. That pattern — clean, then near-total
failure — is not what a race looks like, and chasing it as one would
have wasted the evening. The signal was in the crash reason, which my
first loop never captured because its grep matched test NAMES containing
the word "failed":

```
required condition is false: format.sampleRate == inputHWFormat.sampleRate
  AudioSessionSeamTests.theSessionIsActivatedFirstAndAlwaysReleased
  → MicrophoneSource.start → installTapOnBus → signal 6
```

**`installTap` asserts on the INPUT HARDWARE format**, and an ObjC
assertion aborts the process rather than failing a test.

**The bug was a correction of mine, aimed at a configuration that no
longer existed.** Earlier that day the tap format was changed from
`inputFormat` to `outputFormat` on the reasoning that a tap observes
what a node PRODUCES. That sounds right and is wrong. The observation
behind it was real — `inputFormat` collapses to 0 Hz once
`mainMixerNode` is touched — but that only happened in the
`hostsPlayback` arrangement, which D-049 then removed. The fix outlived
the problem and broke the path that remained.

**Why it hid:** the assertion only fires when the node's output format
and the input hardware format DISAGREE. They agreed on this Mac all day.
They stopped agreeing when an iOS Simulator was booted running the demo
app, which changed the machine's audio configuration — so a bug that had
been silently present became 39 failures in 40.

Restored to `inputFormat`, guard kept: **20/20 clean.**

**Two lessons, both cheap and both mine:**

1. **A stability loop must capture the FAILURE, not the fact of it.**
   The first loop printed `grep -E "✘|failed"`, which matched a test
   called *"A failed turn keeps its words"* and told me nothing. Three
   runs were spent before the reason was ever read.
2. **A test that opens real hardware is environment-sensitive by
   construction.** `theSessionIsActivatedFirstAndAlwaysReleased` starts
   a real `MicrophoneSource`; anything else on the machine holding audio
   can change what it sees. That is a plausible candidate for the
   unexplained 4d flake too — plausible, not proven, and recorded as
   the former.

## 20. The graph probe (D-054) — measuring instead of arguing, and one belief refuted

`swift run bakeoff graph-probe`

**Why it exists.** Milestone 4e produced five faults in one afternoon,
each introduced while fixing the previous one, every one a guess about
what a live `AVAudioEngine` would do, every one paid for by Ryad
rebuilding onto his phone. D-054 makes the harness come BEFORE the fix.
This is the harness for the graph.

**One case per process, on purpose.** AVFoundation does not throw when a
node is misused — it raises an ObjC exception and the process dies. A
single-process probe would report its first fault and silently hide every
case after it, which is the failure mode that makes an instrument worse
than none. The parent re-executes itself once per case and reads the exit
status; a child that never prints `SURVIVED` aborted.

**Its first job** was to decide whether AC-109's failure-path tests could
run headlessly: they use a spy `PlaybackHost` that starts no engine, so
every verb `NeuralVoiceRun` calls on its player node became a question.

Release build, this Mac (M-series, macOS 26), 2026-08-17:

| case | path | expected | measured |
|---|---|---|---|
| 1 | never attached → `stop()` | survives | survives |
| 2 | never attached → `reset()` | survives | survives |
| 3 | never attached → `stop()`, `reset()` — the cancel + teardown path | survives | survives |
| 4 | attached to an engine NEVER started → `stop()`, `reset()`, `detach` | survives | survives |
| 5 | **CONTROL** — attach, connect, start, `engine.stop()`, `detach` | 4e fault #1 says ABORT | **survives** |
| 6 | never attached → `play()` | ABORT | **ABORT** · `required condition is false: _engine != nil` |
| 7 | never attached → `scheduleBuffer` | ABORT | **ABORT** · `required condition is false: _outputFormat.channelCount == buffer.format.channelCount` |
| 8 | attached to an engine never started → `scheduleBuffer`, `play()` | survives | survives |

**What that bought.** Cases 1–4 are exactly what the run's cancel and
failure paths do, so those paths test on any machine with no model and no
speaker. Cases 6 and 7 are why `ScriptedDecoder` has **no way** to emit a
non-empty sample: `render` would reach an aborting verb. The rule is
enforced by the type rather than by a comment asking a reader to remember
it.

**And what it refuted — mine.** Case 5 is fault one of that afternoon, a
detach after `engine.stop()`. On a plain engine on this Mac it **does not
abort.** The probe is not blind — cases 6 and 7 aborted in the same run,
which is why it prints `DETECTION PROVEN` from evidence rather than from
hope — so the honest reading is that *this abort was never a property of a
plain engine.* It needed the capture engine's voice-processing unit, or a
session teardown, and the iPhone is where it was found.

**Consequences, stated rather than acted on.** The guards in
`MicrophonePlaybackHost.detachIfStillOurs` and
`AudioEnginePlaybackHost.stopRendering` **stay**: they cost nothing, and
the phone's evidence stands. What changes is the CLAIM. The comment above
those guards reads as though detaching a stopped node aborts in general;
it does not, on this configuration. The general statement is unproven and
the specific one — under VPIO, on a phone — is what was measured in §17.

**What this probe does NOT measure, and does not claim:** voice
processing, an iOS audio session, a real capture engine, or the Simulator.
Case 5 under VPIO is the case that matters for 4f and it needs hardware.
That is named here as a gap, before anyone reads the table as a clean bill
of health.

## 21. The stranded reply (D-055) — a liveness hole the seam made visible

**Why it exists.** The adversarial review of the `TTSDecoding` seam claimed
that `finishTokens()` can strand a reply. Two verifiers split one-for-one,
so it was neither confirmed nor refuted by vote — and a liveness claim is
not something to settle by vote. D-054 rule 1 says measure it.

**How.** A decoder that emits real (silent) samples on command and reports
when it has finished decoding, rendering on a real `AudioEnginePlaybackHost`,
with the only variable being the lead target and WHEN the token stream
closes. This is the measurement the seam made possible: before it, no test
could make a decode finish at a chosen moment.

`PlaybackLeadStrandTests`, this Mac, 2026-08-17 — 400 ms of audio per case:

| lead target | `finishTokens()` called | `.started` | `.finished` |
|---|---|---|---|
| `.zero` — the shipped default | after the decode completed | true | true |
| 1500 ms | **after** the decode completed | **false** | **false** |
| 1500 ms | before the decode ended | true | true |

**Read it as:** row two is a hung turn. The reply is fully decoded and
sitting complete and silent in the player node, the lead was never
released, so the player is never started, no buffer ever reports played,
and `.finished` never fires. Row three is the same lead with the opposite
ordering, and it is fine — which localises the fault precisely: not the
lead, not the decoder, but WHICH of the two places that learn "the reply is
complete" bothers to release it.

**What it does NOT say.** Nothing here is reachable from any caller in this
repo today, because `defaultLead` is `.zero` at the measured RTF of 0.752.
The row that matters is a machine with RTF above 1.0, and **this Mac is not
that machine**. The iPhone might be, and nobody knows, because AC-104 never
happened. So this table is a proof that the hole exists, not a report that
it has bitten.

**Still open as D-055.** The fix is a fork — one arm, one funnel, or a
purer `PlaybackLead` — and it moves when a reply starts speaking, which is
D-046's ground and Ryad's ruling. Recorded rather than patched.

**And the first version of this measurement FLAKED, 3 times in 20.** It
waited on the decoder's own "I have finished decoding" flag, which is set
from INSIDE `decode` — before `speak()`'s liveness step has run. In the
three runs where `finishTokens()` won that window, `tokensFinished` was
already true when the accounting happened, `speak()`'s `.release` arm fired
exactly as designed, and the reply played perfectly. A test that passes
because the bug did not happen this time is worse than no test.

The fix was to gate on the FACT rather than on a proxy: `phrasesInFlight`
returning to zero is the observable that the liveness step has run, and
`NeuralVoiceRun.counters` exists to expose it (internal, like the type).
One flake is not done — and finding this race also sharpened the finding:
the hole is not "a non-zero lead strands replies", it is "a non-zero lead
strands a reply whose token stream closes in one specific window". That is
a narrower and truer claim than the review's original wording.

**AFTER THE FIX (D-055 = B, one funnel).** Same instrument, same machine,
same three cases — the middle row is what moved:

| lead target | `finishTokens()` called | `.started` | `.finished` | wall |
|---|---|---|---|---|
| `.zero` — the shipped default | after the decode completed | true | true | 0.59 s |
| 1500 ms | **after** the decode completed | **true** | **true** | **0.53 s** |
| 1500 ms | before the decode ended | true | true | 0.53 s |

The wall-clock column is the honest part. Before the fix the middle case
took **3.054 s** — the whole bounded window, spent waiting for a
`.finished` that was never coming — and afterwards it takes 0.53 s, the
same as the two cases that always worked. A hang does not look like a
failed assertion; it looks like time.

## 22. The mind probe (4f, AC-110/AC-111) — availability and stream shape, per device

**The instrument.** The demo app grew a toolbar brain: reachable in EVERY
engine state (the echo probe's lesson — the devices where a model refuses
to install are exactly where the enum matters most), it reads
`SystemLanguageModel.default.availability` as the enum says it, then
streams four prompts and grades the snapshots: cumulative? strictly
extending? any revision of already-emitted text? any grapheme split? The
whole trace leaves the phone as markdown via ShareLink, because a phone
has no stderr (§18's lesson) and a verdict without its evidence is an
adjective. The Mac runs the same measurement as a compiled probe.

**What is measured so far (2026-08-18, milestone in flight):**

| device | availability says | and then |
|---|---|---|
| dev Mac (M2 Pro, macOS 26.6.1) | `unavailable(appleIntelligenceNotEnabled)` → after the toggle: `unavailable(modelNotReady)` | download running; a watcher re-checks every 60 s and fires the full measurement when it flips |
| iOS Simulator (iPhone 17 Pro, same Mac) | **`.available`** | **every generation THREW**: `GenerationError` → `SensitiveContentAnalysisML Code=15` → `ModelManagerError Code=1026`. Zero snapshots produced |
| Ryad's iPhone | **`.available`** | **generated on every prompt** — the first device that can actually think |

**The simulator row is the finding.** An availability check that vouches
for a model the model manager then cannot produce means the enum is a
NECESSARY gate, not a sufficient one. The adapter (AC-112) must treat a
failed generation as its own unavailability signal. Recorded as a status
note on AC-110.

**And the probe lied once itself, on its first run.** With zero snapshots
the per-prompt verdict still showed "strictly extending ✓" in green —
vacuously true over no evidence, the exact class D-054 rule 5 exists for.
It now refuses to speak under two snapshots ("shape: no data"), and the
run-level verdict distinguishes "every pair extended" from "nothing
streamed, so the question is UNANSWERED — and if you are reading this, the
availability line above it lied."

**Not yet in this table, by design:** the stream-shape verdicts
themselves. They arrive when a device that can actually generate runs the
probe — the Mac when its download completes, the iPhone on the next build.
F-1 stays unruled until then.

### The iPhone's run (2026-08-18) — AC-110 answered, AC-111's first real numbers

Shared off the phone as markdown by the probe's own ShareLink. Four
prompts, every snapshot pair graded:

| prompt | snapshots | first | total | cumulative | strictly extending | grapheme split |
|---|---|---|---|---|---|---|
| capital of France (2 sentences) | 3 | **1839 ms** | 2044 ms | yes | **yes** | no |
| count one to ten | 6 | 274 ms | 810 ms | yes | **yes** | no |
| three sentences, the sea | 7 | 301 ms | 1076 ms | yes | **yes** | no |
| four sentences, blue sky | 7 | 282 ms | 1151 ms | yes | **yes** | no |

**VERDICT of this run: every snapshot strictly extended its predecessor.**
No revision of already-emitted text, no suspected grapheme split, across
23 snapshot pairs. One run is evidence, not proof — the probe's own trace
says so — but it is the evidence F-1 asked for, and it points at the
plain diff.

**Four more things this run said, beyond what it was asked:**

1. **Snapshots are CHUNKS, not tokens.** A 50-word reply arrived in 7
   snapshots — several words per step, not subword fragments. The phraser
   handles any granularity (it cuts at clause marks, not at token edges),
   but the mental model "the model streams tokens" is wrong for this API
   on this device: it streams sentences-in-progress, a handful of times
   per reply.
2. **The first prompt of the session paid 1839 ms to first snapshot; the
   warm ones paid ~280 ms.** That ~1.5 s gap is AC-115's whole case:
   session warm-up exists, it is big enough to feel, and it must not land
   inside the first turn's felt pause. `prewarm()` placement is real work,
   not hygiene.
3. **The count-to-ten reply came back as a MARKDOWN LIST** — "Sure, here
   are the numbers…" then "1. One" line by line. Nothing revised, so the
   shape verdict stands — but a mouth would SPEAK that formatting. This is
   F-3 = A's evidence arriving unasked: the told-it-is-speaking
   instruction is not a nicety, it is what stands between the pipeline
   and a voice reading list numbering aloud.
4. **`contextSize` on the phone: 4096** — same as the Mac. AC-116's
   budget is confirmed cross-device.

**Still missing from the table:** the Mac's own run (watcher armed,
`modelNotReady` at check 33, ~33 minutes into the system download) — it
becomes the second device the day the download completes. And every
number here is ONE run on the main actor of an idle app; the latency
column is indicative, the shape column is the load-bearing one.

### The first field run of the mind (2026-08-19, Ryad's iPhone, field report)

The whole loop ran on the phone: microphone → transcription → **the
on-device language model** → a spoken reply — with the Mind picker on
Apple, and then **with the network off**. Answers kept coming.

**Offline answers are the strongest sentence this project can say.** They
prove, by demonstration rather than by privacy-policy prose, that nothing
in the conversation leaves the device: no speech, no transcript, no
thought, no voice. The library's founding bias — on-device first, the
server a compromise to be minimized (§4.3 of the working method) — is now
a fact a person can verify by flipping airplane mode.

**The felt pause, measured in the field:** "tell me the capital of
Italy" → **567 ms** on screen. For scale: the model's COLD first
snapshot alone costs 1839 ms (measured, this same phone), so that cost
is demonstrably not inside this number — and the whole loop (gate +
model + phraser + mouth first-audio) landing under 600 ms is faster
than the Mac's echo-era pipeline share from 4b (749 ms, INSTRUMENTS
history). What the single number does not yet say: whether it was the
FIRST turn after a fresh launch (the specific case AC-115's prewarm
placement must win) and which mouth spoke it.

**The field barge — WORKS.** Interrupting a thinking reply mid-sentence
stops it immediately, and the pipeline listens until the speaker
finishes. That is the first field barge against a mind that genuinely
GENERATES: 4e's barge bug was a mouth that blocked the coordinator's
loop, invisible to every scripted test — the mind's equivalent risk
(generation blocking `openReply`) was designed out (AC-115's hand-off)
and the field just confirmed it with a human interruption.

**The first turn after a fresh launch: 542 ms** — all-Apple engines
(transcriber, mind, mouth), and the field's own words: "it feels fast."
That is AC-115 PROVEN where it matters: the model's cold start costs
1839 ms on this same phone, and the first felt pause a person meets is
542 ms — statistically the same as the warm turn's 567 ms. The warm-up
is being paid where it was designed to be paid: in `refreshMind()`, at
launch and picker-flip, never inside anyone's first question.

**AC-117's field evidence, precisely** (the 4f review caught the first
version of this paragraph saying "COMPLETE" and "machinery, not
evidence", both overstated): offline answers · felt pause 567 ms warm
and 542 ms first-turn · a barge kills a thinking reply immediately and
the pipeline listens until the speaker finishes — all with the APPLE
mouth. Still owed as EVIDENCE, not machinery *(amended 08-19: the neural-mouth
run HAPPENED — the next section carries it — leaving the rest)*: AC-113's measured numbers (how long until `isResponding` clears after a
normal end and after a cancel; whether a cancelled turn spends context
budget), a real over-budget prompt for AC-116, and the live
conformance-kit run (gated on a Mac whose model download is still
stuck). Then the machinery: the review's findings closed, and the merge.

### The second field run: the mind through the NEURAL mouth (2026-08-19, Ryad's iPhone)

The pair AC-117 demanded and the first run did not cover. Mind = Apple,
Voice = Neural, receiver route, real questions, real barges. Screenshot
numbers, read off the device:

| fact | number |
|---|---|
| felt pause (mind + neural mouth) | **524 ms** |
| felt pause (mind + Apple mouth, prior runs) | 542 / 567 ms |
| neural decode, steady | **1.21× real time — TOO SLOW, the screen's own words** |
| neural prefill | 751 ms |
| barges | 2 onsets while speaking, 2 barges — every interruption landed |
| thermal badge during the run | **hot** |
| the ear's verdict | "voice still sounds slow" |

**Three debts paid by one screenshot:**

1. **AC-117 is met on both mouths.** The felt pause barely moves between
   mouths (524 vs 542) because it measures to FIRST audio, and the
   phraser hands the first clause over quickly either way.
2. **The iPhone's neural RTF — owed since 4e's AC-102/AC-104 — is 1.21.**
   The Mac measured 0.752 and the phone was never measured; now it is,
   in the field, with the mind feeding it. Above 1.0 means this phone
   cannot decode as fast as it plays, so the voice runs dry mid-reply —
   the ear's "still sounds slow" is the number, heard.
3. **D-055 was prophetic, and the funnel fix mattered.** The stranding
   hole opened only on a machine with RTF above 1.0, and this phone IS
   that machine. Had the lead been derived from the phone's own number,
   the pre-fix `finishTokens()` could have stranded replies here.

**The consequence, recorded rather than built:** `NeuralVoice.defaultLead`
derives from the MAC's 0.752, so the phone runs a ZERO lead and starves.
The sizing rule already exists and is injectable — at RTF 1.21 it asks
for roughly 1.3 s of lead on a 6 s reply
(`PlaybackLead.deficit(forReplyOf:realTimeFactor:)`). Wiring a
phone-measured lead through the demo is the voice-quality milestone's
work (deferred by D-050), and its number is now waiting for it. Thermal
"hot" during neural+mind is likewise recorded as observed, not yet as a
measured stop-latency/thermal table — that half of AC-102's debt stands.

## 23. The shield probe (4g, AC-119) — AC-104 finally asked, one variable at a time

**The instrument.** A third toolbar probe beside its siblings, reachable
in every app state for the same reason they are. It starts capture WITH
the output chain (`hostsPlayback: true` — the exact configuration D-049
switched off), renders a pure 440 Hz tone through the capture engine's
own unit, and reads what the microphone hears. A TONE, not a voice: no
phraser, no mouth, no model — one variable. Refusal to start is reported
as a RESULT, not retried.

**First run — the Simulator, machine-driven (2026-08-19):**

```
capture with output chain: STARTED · 48000 Hz
voice processing active: true · route: receiver
```

**The graph question is answered, and the Mac's verdict does not
transfer.** Voice processing and an output chain on one engine — the
arrangement this Mac refuses with `-10875` (§17) — STARTS on iOS. §17's
own caveat ("a two-device Mac cannot convict a one-device phone") was
the truth. 4e's five faults are now fully accounted for as the ordering
bugs that were found and fixed, not as a platform impossibility.

**What the Simulator's LEVEL numbers are worth: nothing, and said so.**
Its microphone is the host Mac's, its speaker path is virtual, and the
quiet-room peak of 0.8579 is this room, not a canceller verdict. The
one number that decides AC-119 — the tone's residual under the phone's
canceller — needs Ryad's iPhone, twice: once on the receiver route,
once with Speaker on. Near the quiet room's numbers = the canceller
sees the hosted tone and F-1 = A proceeds; near full scale = D-043's
disease unmoved by routing, and the spec's fallbacks take over.

### The phone's first shield runs — and the probe's own blind spot (2026-08-20)

Both routes, receiver and speaker, on Ryad's iPhone:

```
capture with output chain: STARTED · 48000 Hz     ← D-049's "cannot
voice processing active: true                        coexist" is DEAD on iOS
quiet room:  peak 0.0000 · rms 0.0000              ← a real room is NEVER
during tone: peak 0.0000 · rms 0.0000                digital zero
```

**Two findings in one screenshot.** The graph result stands — the hosted
arrangement starts on the device that matters, both routes, voice
processing active. And the all-zero levels are a NEW fault: the phone's
own echo probe measured this room at peak 0.0030 in 4d, so zeros mean
the capture side went silent under the output chain — or the ring never
received a frame. **The probe could not tell those apart**, which is
D-054 rule 5 violated by the very instrument built to honor it: it could
not say whether it was switched on.

**The probe grew eyes before the phone was asked again:** frame counts
on every measurement (frames-of-silence vs no-frames-at-all), the 4e
ungated tap level as a cross-instrument (dead tap vs dead ring path),
tone-consumed and player-playing witnesses on the render side, and the
host graph rate read back. Verified machine-driven on the Simulator:
100800/201600 frames counted, tap level 0.0131, tone consumed. The
witness only Ryad has: whether the tone was AUDIBLE in the room.

### The shield becomes a MATRIX (third iteration): four arrangements, one tap

The dead-capture finding turned one question into four, so the probe now
builds four raw engines in sequence — each its own arrangement, each
with an output chain beeping at its OWN pitch, so one pair of ears can
say which arrangements actually sounded:

| # | arrangement | beep |
|---|---|---|
| 1 | shipping: vp on input, no output chain (the control that must work) | none |
| 2 | today's fault: vp on input + output chain | LOW 440 Hz |
| 3 | no vp + output chain (is vp the killer?) | MID 660 Hz |
| 4 | THE CANDIDATE: vp on input AND OUTPUT + chain | HIGH 880 Hz |

The candidate encodes the hypothesis: iOS voice processing is a DUPLEX
unit, and `MicrophoneSource` enables it on the input node only — it
predates any output chain. Measured, not assumed.

Simulator shakedown (mechanics only; its mic is the host's and its
arrangement behavior differs from the device): arrangements 1–3 ran with
frames counted; its arrangement 4 died (`running NO`) — plausibly the
Simulator cannot do output-node voice processing at all. The device's
own table is the evidence that counts, and it is one tap away.

### Matrix v1's phone table, and matrix v2

The phone's v1 run (fresh app, one tap, NO beeps heard):

| arrangement | frames | running at end | mixer |
|---|---|---|---|
| 1 shipping (vp, no chain) | 120000, peak 0.0178 | yes | — |
| 2 vp + chain | **0** | **NO** | 44100 Hz |
| 3 no vp + chain | 124800, peak 0.0090 | yes | 48000 Hz |
| 4 vp in+out + chain | **0** | **NO** | 44100 Hz |

**The engine lies twice:** `start()` returns, and the engine is dead by
the read — self-stopped inside the window, the 4e
"engine killing its own graph" class. The tell is the mixer stuck at
44100 Hz against the session's 48000. The duplex-vp hypothesis
(arrangement 4) is REFUTED — it dies the same death. And arrangement 3's
tone was inaudible despite a live engine, plus two identical v1 taps
heard different beeps: arrangements contaminate each other through the
shared session.

**Matrix v2** (one tap, four isolated arrangements — session cycled
between them): the control · vp+chain plain (reproduce, now with
config-change counts and alive-at-0.5s/end) · vp+chain with
RESTART-on-configuration-change (the 4e watch, finally acting) ·
chain-built-BEFORE-vp (order swap). Simulator shakedown: mechanics
green, and one preview worth carrying — the order swap binds the mixer
at the session's 48000 where vp-first leaves it at 44100.

### AC-119: PASSED — the canceller sees what the capture engine renders

Matrix v2 on the phone, speaker route, two taps:

| arrangement | mic read (peak) | audible? | alive | notes |
|---|---|---|---|---|
| 1 shipping, no tone | 0.0031 | — | y/y | the quiet room |
| 2 vp+chain plain | 0.0396 | **LOW heard** | y/y | cfg 1, survived |
| 3 vp+chain restart | 0.0112 | **MID heard** | y/y | cfg 1, **restarts 1** — the cure fires and holds |
| 4 chain-then-vp | 0.0650 | run 1 silent, **run 2 HIGH heard** | y/y | cfg 0 |

**The number that closes the gate:** a beep loud enough to hear across
the room reached the microphone at peak 0.01–0.07 — against D-043's
disease, where the uncancelled reply hit **1.0000**. That is a 25–90×
reduction: **iOS voice processing removes audio rendered on its own
engine.** F-1 = A is validated on the device that matters.

**What the earlier deaths were:** v1 ran four arrangements on ONE
session activation and the vp+chain engines died; v2 cycles the session
per engine and everything lives. The very first (single) probe also
died with an isolated session — its player was attached at the MIC's
48 kHz into a 44.1 kHz mixer mid-run, the suspected killer; v2 attaches
at the mixer's own rate. Both suspects are covered by one hardening:
restart-on-configuration-change, measured working in arrangement 3.

**Observed, not explained:** beep audibility varied between two
identical taps (run 1: LOW+MID; run 2: all three). The product path runs
one arrangement per session start, so this sequencing variance does not
gate AC-120 — recorded so nobody mistakes it for settled.

### AC-120: FIELD-PROVEN — the shielded conversation on the loudspeaker

The real thing, not a tone: Mind = Apple, Voice = Neural, Speaker ON,
Shield ON, phone on the table. The field's words: **"it works, no self
barge, I can still interrupt it."**

- Before the shield, the speaker route self-barged in ~1 ms (4b's field
  find) and the reply reached the mic at peak 1.0000 (D-043).
- With the shield: no self-barge across the conversation — the reply's
  residual stayed under the 0.021 gate, or the onset counters would
  have said so — and a human barge still killed the reply immediately.
- The same session's matrix run read tone residuals 0.0036–0.0549,
  every arrangement alive, sessions at 48000.

The mechanism is exactly what the record demanded since D-043: the
canceller removes what its own unit renders, so the reply now renders
there. What remains in 4g: the Apple mouth's PCM through the same host
(AC-121, `write()`), the loud fallback when a hosted graph refuses
(AC-123), the label rewritten with these numbers (AC-124), review, merge.

### AC-121 in the field: works — with an intermittent self-barge

The shielded APPLE mouth on the loudspeaker: "working most of the time,
but sometimes it barges itself." Recorded before any fix, with the
suspects and what would convict each (D-054 rule 4):

1. **Residual over the gate.** The canceller attenuates, it does not
   erase — the matrix read tone residuals 0.0036–0.0766, and the demo's
   gate is 0.021: the upper end of measured residual is ABOVE it. Speech
   is burstier than a tone. Convicted by: `echo?` rows with peaks just
   above the gate (0.02–0.08).
2. **Canceller convergence at reply onset.** Adaptive filters take a
   moment; leaks would cluster at the START of replies.
3. **The lazy attach.** The written run attaches its player at the first
   buffer, mid-run on a live voice-processing engine; a transient there
   would also cluster at reply starts, first reply especially.
4. **The 22.05 kHz path.** Apple's written voices deliver ~22 kHz PCM
   into a 48 kHz chain; resampling delay can mis-align the canceller's
   reference — which would make Apple's mouth leak more than the neural
   one (24 kHz) does. Convicted by: neural clean, Apple leaky, same
   session.

The instruments to convict are ALREADY ON SCREEN: the per-utterance
`peak · ms · echo?` rows, and the gate slider — 0.021 was earned on the
receiver route in 4d's era, and AC-97's own law says every device AND
route earns its number from a run, not by inheritance.

## 24. The MLX spike gate (D-057 F-6) — the CI objection, re-measured and HALF REFUTED

F-6 deferred MLX on a measurement: it builds Swift 6 clean and then
`swift run` dies with *"Failed to load the default metallib"*, so a
second mind would compile everywhere and generate nothing — a green
build that cannot produce one token. The gate demanded four answers
before any `Package.swift` line. Three are now in.

**1. The Metal toolchain (688 MB, `Metal Toolchain 17F109`) is installed**
— and it is NECESSARY BUT NOT SUFFICIENT. With `metal --version`
working and a clean rebuild, `swift run` still failed identically. The
toolchain was never the whole story: SwiftPM does not build MLX's
shaders at all (mlx-swift excludes the kernels from its own build; the
vendor's README says the same).

*(An aside worth keeping: the download produced NOTHING for 24 minutes
in the background — 0% CPU, zero bytes — and then completed in 90
seconds when run in the foreground. Two Apple asset downloads had
looked identically wedged; only one of them actually was.)*

**2. Xcode builds it, and MLX then computes:**

```
xcodebuild → MetalLink … default.metallib   ← the freshly installed
                                               toolchain, invoked
run the binary → matmul [[19,22],[43,50]]   ← STAGE 1 PASSED
```

**3. THE CI QUESTION — and the answer is not what F-6 assumed.**
`swift test` CAN run MLX. The vendor's loader searches five places, and
the fifth is `default.metallib` **relative to the working directory**:

| arrangement | `swift test` |
|---|---|
| as-is | **FAILS** — hard MLX abort mid-test, not an assertion |
| `default.metallib` (3.6 MB) placed in the working directory | **PASSES** |
| removed again (the control) | **FAILS** again |
| the repo's exact pair, `swift build` + `swift test -Xswiftc -warnings-as-errors` | **both green** |

So MLX does not require abandoning `swift test`. It requires ONE
prebuilt 3.6 MB artefact to be present — produced by an Xcode build, or
vendored, or built in CI by the toolchain.

**What remains unmeasured, and it is the whole remaining risk:** whether
the GitHub `macos-26` runner has the Metal toolchain, or would have to
download 688 MB per run — or whether the metallib should be committed as
a binary artefact, which is its own decision. That is testable by
pushing one CI job, and it is the only gate item left besides the phone.

**4. The models were already here.** Ryad downloaded MLX weights on
2026-06-12: Qwen3-0.6B-4bit (334 MB), Qwen3-4B-4bit (2.1 GB),
Qwen3-8B-4bit (4.3 GB), whisper-large-v3-turbo (1.5 GB). The second
mind's model needs no download.

### The runner's answer (2026-08-20) — the gate's last unknown, closed

Pushed a probe job to `macos-26`, the repo's own CI runner, asking one
question and building nothing else:

```
xcode: Xcode 26.6 · swift 6.3.3 · 96 Gi free
metal: PREINSTALLED — "Apple metal version 32023.883"
proof: compiled a .metal and linked probe.metallib (3,481 bytes) ON THE RUNNER
```

**The runner ships the Metal toolchain.** No 688 MB download per run, no
vendored binary artefact required, and no committed blob in a repo whose
method is reproducibility. A CI step can BUILD the metallib from source
on the runner and place it where `swift test` finds it — the same
working-directory trick measured in §24.

`metal` was tested by RUNNING it, not by finding it: this Mac had the
binary present and still refused, so presence is not the question.

**All four gate items now have answers:**

| item | answer |
|---|---|
| Metal toolchain on the dev Mac | installed (688 MB); necessary, not sufficient |
| MLX computes | yes, via an Xcode build |
| `swift test` runs MLX | **yes**, with a 3.6 MB `default.metallib` in the working directory |
| the CI runner | **has the toolchain preinstalled** and can link a metallib |
| the models | already on disk since 2026-06-12 |

**What F-6's deferral rested on no longer holds.** The ruling said MLX
"would compile everywhere and RUN nowhere in the current toolchain" and
that the build system "is not behind the protocol at all". The first
half is refuted by measurement; the second half stands but shrinks to
one CI step. What remains genuinely unmeasured is the PHONE: a token,
its time-to-first-token, and peak memory — the numbers that decide
whether a second mind feels alive rather than merely compiles.

### STAGE 2: a real token, on this Mac, from Ryad's own weights (2026-08-20)

Qwen3-0.6B-4bit, loaded from the cache it has sat in since 2026-06-12,
built through Xcode, run on this M-series Mac:

| measurement | value |
|---|---|
| model load | **311 ms** |
| **time to first token** | **67 ms** |
| steady rate | 66.9 chunks/s (40 chunks in 650 ms) |
| peak GPU memory | **368 MB** (cache limit set to 20 MB, the examples' value) |

What it said, verbatim: *":<think> Okay, so I need to figure out the
capital of France. Let me start by recalling what I know…"*

**Read those numbers against the mind already shipped.** Apple's
Foundation Models measured, on the iPhone, **1839 ms** to a cold first
snapshot and ~280 ms warm (§22). This 0.6B model answered in **67 ms**
on a Mac — a different device and a smaller model, so not a fair race
yet, but the first evidence that a second mind could be FASTER rather
than merely different. The phone's numbers are the ones that matter and
are not taken.

**Three caveats, stated rather than buried:**

1. **The tokenizer is approximate.** `mlx-swift-lm` ships the `Tokenizer`
   protocol and no implementation; the spike wrote a longest-match
   encoder over `tokenizer.json` rather than pull a package for a
   throwaway. Token ids are VALID but not necessarily the ones a real
   BPE tokenizer would choose, so the leading `:` and the doubled
   `<think>` are artefacts of the spike, not of the model. Any judgement
   of reply QUALITY from this run would be dishonest.
2. **The model thinks out loud.** Qwen3 emits `<think>` reasoning before
   its answer — a real design question for a SPOKEN assistant, since a
   mouth would read the deliberation aloud. Noted for the milestone, not
   solved here.
3. **A silent segfault cost an hour.** The first run exited 139 with NO
   output: the crash discarded buffered stdout, so the trail vanished
   with it. `setbuf(stdout, nil)` and the same binary ran clean — the
   crash was never real, only invisible. A measurement tool must flush.

**Dependency count, corrected by reading rather than by memory:** the
earlier research said 3 packages minimum and 5 realistic, because
`Tokenizer` was assumed to come from swift-transformers. It does not —
`MLXLMCommon` defines its own, and depends only on mlx-swift. The
resolved graph here is **mlx-swift-lm + mlx-swift**, with swift-numerics,
swift-argument-parser and swift-syntax pulled transitively. A production
adapter still needs a real tokenizer, which is where a HuggingFace
package would come back — but that is one dependency, not three.

### STAGE 3: the phone token — BLOCKED, and the blockage is structural (2026-08-20)

The Mac's number is taken. The phone's is not, and this section records
WHY rather than promising it later. The short version: **MLX cannot run
on the iOS Simulator at all.** Not because of my code, not because of a
missing metallib, and not because of a flag I failed to set. The
Simulator's Metal driver and MLX's memory design contradict each other.

```
  MLX's design                    MTLSimDevice's rule
  ------------                    -------------------
  one memory, shared by           the simulator's GPU is the MAC's GPU,
  CPU and GPU (real Apple         reached through a translation layer —
  silicon: unified memory)        it does NOT share memory with the app

  heap_desc->setResourceOptions(         "MTLStorageModePrivate is
    ResourceStorageModeShared)  ---X--->  required for heaps"
       allocator.cpp:15, :63              MTLSimDriver, assertion at :1226
```

**How it was found, in the order it actually happened.** Two runs died
with `libc++ Hardening assertion __s != nullptr failed` and NO output at
all — the same failure the Mac spike had taught me to distrust, so the
first fix was to the instrument, not the code: `log()` now writes to
stderr as well as to the view, because the first two crashes killed the
view that held the evidence. An instrument whose trail dies with the
crash it is measuring is not an instrument.

With a step-0 matmul isolated ahead of any model or tokenizer work, the
crash report named its own cause four frames below my line:

```
  Probe.run() + 1400 (App.swift:56)        <- the matmul, my code
    MLXArray.init                          <- allocating one array
      mlx::core::allocator::malloc
        metal::MetalAllocator::MetalAllocator()
          mlx::core::metal::Device::Device() + 500  (device.cpp:328)
            std::basic_string(char const*) detected nullptr   <- ABORT
```

device.cpp:328 is `arch_ = std::string(device_->architecture()->name()
->utf8String())`. The Simulator's Metal device returns a **null**
architecture name and MLX hands it straight to `std::string`.

**That first wall has a door, and taking it was worth doing.** The line
above 328 is `arch_ = env::metal_gpu_arch()`, read from
`MLX_METAL_GPU_ARCH` (utils.h:173) and only falling through to the null
read when empty. Launching with `SIMCTL_CHILD_MLX_METAL_GPU_ARCH=
applegpu_g15` cured that crash outright — step 0 printed for the first
time — and the run reached the **real** wall one layer deeper:

```
  device: iPhone · iOS 26.5
  step 0: matmul…
  -[MTLSimDevice newHeapWithDescriptor:]:1226: failed assertion
     `MTLStorageModePrivate is required for heaps'
```

**Why no further flag helps.** MLX's heap storage mode is a constant
(`allocator.cpp:15`), not a setting. And `Device.cpu` does not route
around it: the generic `allocator()` is chosen at BUILD time — there is
one in `backend/metal/`, one in `backend/no_gpu/`, one in
`backend/cuda/` — and mlx-swift compiles the Metal one for iOS. So on
the Simulator EVERY array allocation, on any device, goes through a
heap the driver refuses to make. Running MLX there would need MLX
rebuilt against `no_gpu`, which measures nothing anyone cares about.

**What this costs the gate, stated plainly.** The phone number is the
one that matters — thermals, memory pressure and a real Neural
Engine-class GPU are exactly what a Mac cannot stand in for — and it now
requires a build signed for Ryad's device. That is the one step in this
whole gate I cannot take for him: it needs his signing team. Everything
that could be measured without his hands has been.

**And an honest correction to §24's own headline.** F-6's objection was
"compiles everywhere, runs nowhere." §24 recorded that as half refuted,
and it stays half refuted — but the halves are now sharper than the
word "half" suggests:

| where                | compiles | runs  | evidence                          |
|----------------------|----------|-------|-----------------------------------|
| `swift test` on Mac  | yes      | yes   | STAGE 1/2 — 67 ms to first token  |
| hosted CI (macos-26) | yes      | yes   | toolchain preinstalled, links     |
| iOS Simulator        | yes      | **no**| this section — structural         |
| iOS device           | yes      | ?     | untaken, needs signing            |

For the Simulator, F-6 was exactly right, and said so before I measured
it. Recording that costs nothing and keeps the ruling honest.
## 25. The second mind's own numbers (4h) — the bill, and what mutation caught

*(Numbering note, now closed: §24 is the MLX spike gate. While 4h was
being built it lived on `spike/mlx-gate` and this section reserved the
number rather than skipping it. PR #16 merged the gate to `main` on
2026-08-21 and `main` was merged back into this branch, so §24 is
directly above — read it first, because everything below depends on the
question it answered.)*

### The dependency bill, in seconds rather than in adjectives

D-062's F-5 = A priced MLX at three direct packages and said the honest
cost is CI build TIME, "which is a reason to measure that time, not to
redesign around a ghost." Measured on this Mac:

| what | before | after |
|---|---|---|
| `swift build --target MultiModalKit` (the vow's proof) | 1.72 s | **1.56 s** |
| full `swift build -Xswiftc -warnings-as-errors`, cold | — | **39.65 s** (412 steps) |
| full suite | 259 tests / 33 suites | **279 / 36** |
| stability, the new suites | — | **60 runs, 0 failures** |

Sixty runs rather than the house twenty, because promise 3 is the exact
test whose Apple-seam twin was measured flaking ~1 in 800 — and a
twenty-run pass would have said nothing about a fault of that size. Sixty
says little more, honestly; what makes this version deterministic is the
GATE, not the repetitions: the defiant token cannot race the cancel
because the test opens the gate only after `cancel()` has returned.

The core-alone number is the one that matters, and it did not move: the
zero-dependency vow is enforced mechanically by CI building that target
BEFORE anything else, and MLX is not reachable from it. The 39.65 s is
the whole graph from cold, warnings-as-errors clean — cheaper than the
"slow build" the fork discussion feared, because at that moment nothing
used the macro.

*(Corrected by the 4h review: `LocalMind.swift` now calls
`#huggingFaceTokenizerLoader()`, so the macro — and swift-syntax — IS
built. The 39.65 s figure predates the tokenizer landing and must not be
quoted as the cost of the finished milestone. The number that has been
re-measured since is the core-alone build, which is what the vow turns
on, and it did not move.)*

### The mutation log — five that bit, one that did not

Tests here were written ALONGSIDE the implementation rather than watched
failing first. That is a departure from red-then-green, so red was proven
afterwards by mutation instead of claimed:

| mutation | result |
|---|---|
| the gate admits everything | 5 of 6 gate tests RED |
| the CLOSE marker is admitted | the 6th RED |
| the real-vocabulary test expects the wrong ids | RED — so its silent skip is not hiding a dead assertion |
| `cancel()` emits a terminal | promises 2, 3, 4 RED |
| `cancel()` stops finishing the stream | promises 2, 3, 4 and the race test RED (in 5.000 s, the `until` bound) |
| **the retire latch removed from `report`** | **NOTHING RED — masked** |

The masked one is recorded rather than dressed up. `report` cannot be
called twice by construction, and in the cancel-then-finish race
`out.finish()` has already run, and a finished `AsyncStream` drops every
later yield. So the FINISH is load-bearing and the latch is the belt. It
stays — `AppleReplyRun` needed exactly this latch forced onto it by 4e's
review after a failed decode kept running and aborted the process, and
the structure that masks it here is not guaranteed to survive the next
change. This is the 4b precedent: record redundancy, do not pretend every
line is load-bearing alone.

### Two defects in my own tests, found by measuring instead of trusting

1. **A control that survived the mutation it existed to catch.** The
   removed-gate control first asserted only that gated output DIFFERED
   from ungated. With the gate neutered it still passed, because the
   close marker alone made the two differ. Both halves are now exact, and
   the ungated half runs a FOREIGN vocabulary through the same code path
   rather than skipping the gate — so it proves the gate acts on THESE
   ids, not on tokens in general.
2. **A red that hung instead of failing.** The cancel-then-finish test
   first awaited its collector task's result. With `out.finish()` mutated
   away the stream never ended, and the run took **ten minutes and
   produced no verdict** before it was killed. Rewritten on the house
   `until` bound, the same mutation now reddens it in 5.000 s. A red that
   hangs is a red nobody reads.

### The real model, in `swift test` (AC-128/129) — and a guard that lied twice

The second mind answering, on this Mac, inside the ordinary test runner:

```
AC-128 · first token in 1.926 s · said: The capital of Italy is Rome.
AC-128 WARM · model load 1.717 s · first token 0.272 s · said: The capital of France is Paris.
```

| what | measured |
|---|---|
| cold first token (load included) | **1.93 s** |
| model load alone | **1.72 s** |
| **warm first token** | **0.27 s** |

The split is the whole story: essentially ALL of the cold number is
loading 334 MB, so `prewarm()` exists for the same reason the Apple
mind's does. For scale, this project's measured felt pause with all-Apple
engines was 542–567 ms; a warm local first token at 272 ms is inside
that, and a cold one at 1.9 s is not remotely.

(The spike's 67 ms in §24 is not this number and should not be compared
to it: that measured raw generation on a bare prompt, while this includes
the chat template, a system instruction and prefill.)

### AC-129: the guard that must never say yes wrongly

Without a `default.metallib`, MLX aborts the PROCESS. So the guard is
asked with Foundation before MLX is touched at all. It was wrong twice,
and only the control caught it — reasoning would not have:

| attempt | what it accepted | result |
|---|---|---|
| 1 | a nested Cmlx bundle found via `url(forResource:)` | said yes, **process died** |
| 2 | any bundle's `Resources/default.metallib` | matched **`Vision.framework`'s own metallib** — said yes, **process died** |
| 3 | nested `mlx-swift_Cmlx.bundle`, frameworks only when the bundle IDENTIFIER matches, else cwd | **correct** |

Attempt 2 is the instructive one. Apple ships `default.metallib` inside
`Vision.framework`, and a check that merely looks for a file by that name
will find someone else's. MLX itself only accepts a framework whose
identifier is its own — mirroring that rule is what fixed it.

The control, run both ways:

```
metallib removed  → guard nil, 5 tests SKIP, green in 0.140 s, no abort
metallib restored → real reply, 6 tests green
```

The colocated `mlx.metallib` arrangements are deliberately NOT checked.
They belong to non-SwiftPM builds this package does not produce, and
every extra place to look is another chance to say yes wrongly. The cost
is a false NEGATIVE — skipping where MLX could have run — which is the
direction this check is allowed to be wrong in.

### AC-130, the mind-off — and the discovery that LOADING IS NOT WARMING

`swift run bakeoff mind-off --model=<weights>` puts both citizens of the
seam on the same three questions. The first run said something the spec
had not anticipated:

```
(model load: 2318 ms)
first token  1911 ms ·  7 pieces · 32.2/s   "The capital of Italy is Rome."
first token    82 ms · 10 pieces · 30.6/s   "A microphone is used to ..."
first token   267 ms · 17 pieces · 35.7/s   "The sky is blue because ..."
```

The weights were ALREADY resident when question 1 was asked — the load
had finished. So the 1911 ms was not loading. It was the first
**generation**: Metal pipelines and graph warm-up, paid by whoever asks
first. `prewarm()` was loading and calling it done, which would have put
that 1.8 s in front of a person's first question on the phone.

Burning one throwaway token off-turn fixes it, and the second effect was
bigger than the first:

```
(model load 1457 ms + pipeline warm-up 84 ms — both paid ONCE, off-turn)
first token 51 ms ·  7 pieces · 65.0/s   "The capital of Italy is Rome."
first token 50 ms ·  8 pieces · 67.8/s   "A microphone is used to capture sound."
first token 50 ms · 29 pieces · 75.0/s   "The sky appears blue because ..."
```

| | before the warm-up | after |
|---|---|---|
| first token | 1911 / 82 / 267 ms | **51 / 50 / 50 ms** |
| throughput | 30–36 tok/s | **65–75 tok/s** |
| cost | — | 84 ms, once, off-turn |

Throughput roughly DOUBLED as well, which is the same cause seen from the
other side: the first run was compiling kernels while it generated. For
scale, this project's measured felt pause with all-Apple engines was
542–567 ms end to end; a warm local first token is 50 ms.

**The Apple rows are empty, and that is a result rather than a gap.** All
three refused at the door with *"the on-device model is still
downloading"* — the Mac's Foundation Models asset has been stuck for
days (its daemon idle at 0.0% CPU). The tool prints refusals as rows on
purpose: a table that silently omitted the mind that could not answer
would be the lying instrument this project keeps hunting.

**Not measured, and not implied:** the phone. Every number here is this
Mac's, and D-061 says the device figure needs a signed build.

### The field report "sometimes it just replies my question" — chased to the model

Ryad, on the phone, with the local mind. Three explanations were possible
and the log was built to tell them apart, because none of them is visible
in a screenshot.

**Suspect 1, the wrong brain — REFUTED by the log.** `PhoneEchoReply`'s
entire behaviour is to answer with the question ("You said: …"), and the
picker defaults to `.echo`, so "it replies my question" is a literal
description of it. The conversation log records the generator the
COORDINATOR held rather than the picker's value, and it read
`mind: **Local (MLX)**` on all ten turns. Not the brain.

**Suspect 2, speech phrasing — REFUTED before the log arrived.** Twenty
prompts on the Mac in the phone's style (no capitals, no question mark)
and in written style: every one answered, none echoed.

**Suspect 3, the model — CONFIRMED, and reproduced exactly.** The log's
`heard:` lines were replayed verbatim through `bakeoff ask` on the Mac,
and turn 10 came back character-for-character identical to the phone:

```
heard:  13. No, no, no.  I ask you the square of... 113.
phone:  No, no, no. I ask you the square of... 113.
Mac:    No, no, no. I ask you the square of... 113.
```

So it is not the phone, not the demo, and not the seam. A 0.6B model
parrots input that is not a clear question.

**Why the input was not a clear question — the ledger, working as
designed.** The log shows the whole thought carrying forward:

| turn | heard |
|---|---|
| 9 | `13. No, no, no.  I ask you the square of...` **(BARGED IN)** |
| 10 | `13. No, no, no.  I ask you the square of... 113.` |

A barged turn was never answered, so 4c's ledger keeps its text as still
UNANSWERED and delivers it again with the next utterance (AC-88). That is
correct behaviour, and its by-product is that an interrupted exchange
hands the model a fragment rather than a question.

**Two candidate cures, both measured on the same inputs.**

*A stricter instruction* ("never repeat the user's words; if unclear say
only: sorry, I did not catch that") fixes the worst case and nothing
else:

| heard | 0.6B, demo prompt | 0.6B, strict prompt |
|---|---|---|
| `13. No, no, no. …113.` | verbatim echo | "Sorry, I did not catch that." |
| `Hello, my friend, how are you?` | "Hello! How are you?" | "Hello, how are you?" — still parrots |
| `What you can do for me?` | parrots | parrots |

*A bigger model* — Qwen3-4B-4bit, already on this Mac, with the demo's
ORIGINAL prompt — fixes all of it, and does something the small one
cannot:

```
13. No, no, no.  I ask you the square of... 113.
   → "The square of 113 is 12,769."
```

It read through the disfluency to the real question.

| | Qwen3-0.6B-4bit | Qwen3-4B-4bit |
|---|---|---|
| on disk | 334 MB | 2.1 GB |
| first token | 51–78 ms | **249–374 ms** |
| throughput | 64–70 tok/s | 46–53 tok/s |
| parrots fragments | yes | no |

Even at 374 ms the bigger model is inside the 542–567 ms felt pause this
project measured with all-Apple engines. **What is NOT measured is the
phone**: MLX does not mmap its weights (§25), so 2.1 GB would be resident
beside the audio graph, the recogniser and the mouth. That is a device
question, and it is the fork's real cost.

`--system=` was added to `bakeoff ask` so a candidate prompt can be
measured against the same inputs before anyone ships it.

### F-1 = C: the model picker, and the Mac's memory baseline

Ryad ruled F-1 = C — put the choice in the demo so the PHONE answers the
question the Mac cannot. The picker alone would not have done that: the
fork turns on resident memory, so the log had to learn to report it.

`MLXRuntime.activeMemoryBytes` / `peakMemoryBytes` now surface MLX's own
accounting, and every logged turn carries the peak. Reading them is
guarded by `isAvailable`, because touching MLX's allocator on a machine
with no metallib aborts the process — the same trap AC-129 exists for.

**This Mac's baseline, for comparison against a phone:**

| | on disk | active | peak | first word |
|---|---|---|---|---|
| Qwen3-0.6B-4bit | 334 MB | 349 MB | **420 MB** | 76 ms |
| Qwen3-4B-4bit | 2.1 GB | 2198 MB | **2340 MB** | 376 ms |

Active tracks the weights almost exactly, which is what "no mmap" means
in practice: the file is not mapped, it is held.

**What this does NOT tell us.** A Mac has no jetsam. The phone must carry
2.3 GB *beside* the audio graph, the recogniser and the mouth, and
whether iOS tolerates that is not a thing this room can measure. That is
precisely why the ruling was C: the demo now records `MLX peak N MB` on
every turn, so one shared log answers it.

### The phone's answer to F-1 (2026-08-21) — 4B fits, and it behaves

F-1 = C existed to get one number that no Mac could produce: whether
2.1 GB of resident weights survives on a phone beside a live audio graph,
a recogniser and a mouth. Ryad ran the picker on his iPhone with the 4B
model and shared the log. It survives.

```
local model: 4B (mlx-community/Qwen3-4B-4bit) · installed: true
MLX memory now: active 2159 MB · peak 2288 MB
ear=Apple · mouth=Apple · speaker shield=true
```

Eight turns, no kill, and memory settled rather than climbed: peak went
2277 → 2283 → 2288 MB over the first three turns and then stopped.

**The phone matches the Mac, which was not guaranteed:**

| | this Mac | iPhone |
|---|---|---|
| first word | 249–376 ms | **291–315 ms** |
| MLX peak | 2340 MB | **2288 MB** |
| parrots fragments | no | no |

**Every 0.6B failure case is gone**, including the accumulating-ledger
inputs that produced them. The same shape that made the small model echo
verbatim now gets answered:

| heard | 0.6B | 4B on the phone |
|---|---|---|
| `Hello, my friend, how are you?` | "Hello! How are you?" | "I'm doing well, thank you! How about you?" |
| `…how are you? Can you hear me?` | echoed | "Hello! I can hear you. I'm doing well…" |
| `How much countries do those exist in Europe?` | — | "There are 47 countries in Europe…" |

**What this does NOT settle.** Total reply time ran to 4.2 s on the two
longest answers, because the model writes three sentences where the
instruction allows "one to three". Spoken, that is four seconds of
talking before the person can reply. First-word latency is the number
this project has been optimising, and it is fine; reply LENGTH is a
different lever and has not been tuned.

Thermals are also untested: eight turns is not a long conversation, and
sustained GPU work on a phone throttles. Nothing here should be read as a
claim about a twenty-minute session.

### F-1 = B, and the reply-length fix — measured, not phrased

Ryad ruled **F-1 = B**: 4B is the default, on the phone's own evidence
(2288 MB peak, no kill, 291–315 ms first word, none of 0.6B's parroting).
The picker stays, because one device is one device.

**The reply-length problem, stated correctly.** The 4.2 s in his log was
GENERATION time, not the real cost. Turn 6's reply was 29 words — roughly
twelve seconds of speech. First-word latency was never the fault; length
was, and nobody had tuned it.

Three instructions, same six prompts from his log, same model:

| instruction | mean words | verdict |
|---|---|---|
| A: current — "one to three short, plain sentences" | **19.7** | the baseline that produced the complaint |
| B: "ONE short sentence. Do not add extra facts…" | **7.0** | shipped |
| C: "answer ONLY what was asked, at most fifteen words" | 9.8 | rejected — longer AND worse |

C looked plausible and measured badly, which is the point of measuring.
It produced self-contradiction — *"Approximately 450 miles. The distance
between Hamburg and Paris is abo…"* — and bare fragments that read
strangely aloud: *"Madrid. It is the capital city of Spain."*

**B's replies, at 7.0 words mean:**

```
Hello, my friend, how are you?   → "I'm doing well, thank you! How about you?"
what is the capital of Spain?    → "The capital of Spain is Madrid."
Okay, thank you.                 → "You're welcome!"
```

**And the check that mattered before shipping it:** does "ONE short
sentence" make it useless when a question genuinely needs explaining? It
does not — the model adapts rather than truncating:

```
Why is the sky blue?                   → 25 words, one sentence, correct
Explain how a microphone works.        → 33 words
Difference between RAM and storage?    → 27 words
```

Short where short is right, fuller where the question earns it. Applied
to BOTH minds, because the constraint is the MEDIUM — this reply is
heard, never read — and not the model.

## 26. The 0 Hz crash (4h field report) — reproduced in a harness, then fixed

Ryad's phone died mid-session, hard:

```
AURemoteIO.cpp:1135  failed: -66635 (enable 3, outf< 1 ch, 0 Hz, Float32> inf< 1 ch, 0 Hz, Float32>)
AVAudioEngineGraph.mm:2161:_Connect: (IsFormatSampleRateAndChannelCountValid(format))
*** Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio'
```

**0 Hz.** The engine had no valid hardware format — what an engine reports
when the session is not active or the route has gone — and something
connected a node with it anyway.

**The harness came before the fix (D-054).** A standalone one-case
process attached a deliberately built 0 Hz format
(`AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1)` — which,
usefully, is NOT nil) to `AudioEnginePlaybackHost`:

```
built 0 Hz format: 0.0 Hz, 1 ch
  5  AVFAudio  -[AVAudioEngine connect:to:format:] + 124
  6  AudioEnginePlaybackHost.attachForPlayback(_:format:)
libc++abi: terminating due to uncaught exception of type NSException
```

The same death, on this Mac, in ten lines. After the guard, the same
harness prints:

```
RESULT: threw honestly — unusableFormat(rate: 0.0, channels: 1)
```

**Why it was unguarded, and this is the uncomfortable part.**
`MicrophoneSource` has carried this exact guard for milestones, with a
comment saying `inputFormat` "collapses to 0 Hz once `mainMixerNode` is
touched — but that only happened in the `hostsPlayback` arrangement,
which D-049 removed."

**4g put `hostsPlayback` back** (D-060 F-3 = B, the speaker shield), and
Ryad's log says `speaker shield=true`. The comment describing the hazard
as historical was true when written and became false one milestone later,
and nobody — me included — re-read it when the arrangement returned. The
microphone kept its guard. The playback host never had one.

**The fix.** `PlaybackHostFailure.unusableFormat(rate:channels:)`, and
both hosts now check the caller's format AND the mixer's own output
format before connecting. The order matters: reading `mainMixerNode` is
what forces the mixer→output connection, and a dead route shows up there
rather than in the caller's argument.

**A suspicion, recorded as a suspicion.** The crash arrived in the same
session that made 4B the default, and prewarming now loads 2.1 GB at
launch. That is heavy work next to session activation and could widen a
race that always existed. NOT measured — the stack shows only that a UI
event reached our code — and it does not change the fix, which is correct
regardless of what made the format invalid.

**Still open:** the guard turns a crash into an honest failure, not into
a working reply. If the session genuinely is not ready when a reply
starts, the turn now fails cleanly instead of killing the app — better,
but not yet right. Making the attach wait for a usable route is its own
change and its own measurement.

### The 38-turn field session (4h) — what it settled, and the switch nobody turned on

Ryad's longest real conversation with the second mind. Three questions
this project had left open are now answered by it.

**1. Endurance — answered.** No crash across 38 turns, and memory did not
run away:

```
turn 1  MLX peak 2292 MB
turn 38 MLX peak 2320 MB      +28 MB over the whole session
```

**2. Sustained latency — answered.** First word stayed at **285–323 ms**
across all 38 turns, with two outliers (775 ms, 633 ms). No thermal
decay visible at this length. A twenty-minute session is still untested.

**3. Reply length — the fix holds.** "Rome." · "Yes." · "Italy is bigger
than Switzerland." Short enough to listen to, and still full sentences
where the question earned one (the visa answers ran to 25–30 words).

**And the real finding, which is not about the model at all.**

Six of the thirty-eight turns (16%) produced `_(no words)_` and
`BARGED IN` — a turn was OPENED on a fragment and then killed by the
speaker continuing:

```
turn 31  heard: "Okay, and uh,"                    → _(no words)_, barged at 76 ms
turn 32  heard: "Okay, and uh, And if I just want to visit United States as a tourist,"
turn 33  heard: "...Do I need visa as a German?"   → answered
turn 34  heard: "...Do I need visa as a German? Yeah."      → answered AGAIN
turn 35  heard: "...Yeah. Yeah, I'm waiting."               → answered AGAIN
```

Twelve of thirty-eight turns (32%) carried a previous turn's words.

**Two mechanisms, one of them switched off:**

| | value | effect |
|---|---|---|
| VAD hangover | `Int(rate * 0.3)` = **300 ms** | 300 ms of quiet ends the utterance |
| `config.replyGate` | **`.zero`** — the demo never sets it | the reply fires the INSTANT a final arrives |

*(Superseded the same day: Ryad ruled 500 ms and the demo now sets it —
see "F-1 = B, and the reply-length fix" below and D-063. The table above
records the state that PRODUCED the 38-turn session, which is what makes
its numbers readable; it is not the current configuration.)*

So the total wait between Ryad stopping and the assistant committing is
about 300 ms. A person thinking mid-sentence ("Okay, and uh,") pauses
longer than that, every time.

**The cure already exists and was built for exactly this.** AC-81's
reply gate holds the reply after a final, and `handleGateExpired` builds
the prompt when the gate EXPIRES rather than when it was armed:

> "Built HERE, not when the gate was armed: anything the speaker added
> during the gate belongs to the same thought."

A continued sentence is absorbed into the SAME turn instead of starting a
new one — and if a new utterance begins during the gate, the stamp check
fails and no turn fires at all. It has been sitting at zero.

**The ledger repetition is downstream of this, not a separate bug.**
D-040 F-2 says a thought is forgotten only when its reply was fully
SPOKEN; every other ending keeps the words because they went unanswered.
Barging a spoken answer therefore carries it forward — which is why 34
and 35 re-answered 33. Correct by that ruling, and the repetition mostly
disappears if turns stop firing on fragments in the first place.

**Model errors, recorded without excuse:** "The 2nd big city in Italy" →
"Roma." (it is Milan, and turn 9 said Milan for the 3rd), and "Is
Switzerland big as Portugal?" → "No, Switzerland is larger in area than
Portugal" (Portugal is roughly twice Switzerland). A 4-billion-parameter
model on a phone gets facts wrong; the seam cannot fix that and should
not pretend to.

## 27. Two field reports: a voice that was never downloading, and a pair that does not fit

**"Every time I start the app I see downloading the voice!"** He was
right to ask, and the screen was lying. `checkVoice()` calls
`modelInstalled()`, finds the 1.1 GB present, and then sets
`voiceState = .downloading` before `ensureModel()` — which its own doc
comment describes as *"Idempotent: with the assets on disk this is a
load, not a fetch."* The work is real (CoreML compiles six components,
tens of seconds, once per launch) but the WORD was false. A screen whose
stated job is removing ambiguity was manufacturing it. There is now a
`.preparing` state that says what is actually happening.

**"Terminated due to memory issue" — the local 4B mind with the NEURAL
voice.** Jetsam. Measured with `bakeoff memory-fit`, which loads each and
reports `phys_footprint` (the figure iOS judges, not resident size):

| loaded | footprint |
|---|---|
| baseline | 3 MB |
| + local mind (Qwen3-4B-4bit) | **2239 MB** |
| + neural voice | **3351 MB** |

The voice costs about **1112 MB** on top of the mind, and 3.35 GB is over
what iOS will host beside an audio graph and a recogniser.

*A measurement that flattered the answer, caught and corrected.* The
first version of `memory-fit` let the mind go out of scope, so the
footprint went DOWN after adding the voice — 2239 → 1610 MB — which
would have "proved" they fit. The model is now held to the last line.

**The demo refuses the combination instead of dying.** `memoryConflict`
names it before the tap, in numbers, and disables Listen. That is a demo
POLICY (D-027): the library ships no such rule, because the budget
belongs to the app that spends it. It is a guard, not a cure — the two
still cannot run together, and what SHOULD happen is a fork.

**Also fixed, from the same message: every picker persists.** The ear and
the Apple voice already did; the mind, the mouth, the shield and the two
toggles reset at every launch, so the app re-chose for him from a screen
that looked like it remembered. A control that forgets is a control that
lies about its own state — the same fault as the voice label, one screen
over.

## 28. The pair, measured on the phone (4i, AC-132) — it misses by seven megabytes

The first real number for the question 4h could only guess at. Ryad's
iPhone, the demo's pressure probe, and one jetsam kill.

```
fresh launch, nothing loaded     3319 MB free      → the app's dirty limit is ~3.5 GB
probe start (mind ALREADY there) 1105 MB free
+ mind "loaded"                  1105 MB free      ← unchanged: ensureModel returned the cache
  MLX active                     2159 MB
loading the neural voice…        KILLED
```

**The mind costs ~2214 MB** (3319 − 1105) and leaves **1105 MB**. The
neural voice measured **1112 MB on a Mac** (§27).

**1105 available against 1112 needed.** Every earlier statement in this
repo — including mine, repeatedly — said the pair "does not fit", on the
strength of a Mac's `phys_footprint` arithmetic (2239 + 1112 = 3351). The
phone's own answer is that it misses by about **0.6%**.

**Two faults in the instrument, recorded because they shaped the run:**

1. **The word "baseline" was false.** Launch had already prewarmed the
   mind, so the probe's first reading was taken with 2.2 GB resident and
   still called itself a baseline. The line now reports whether the mind
   was already there.
2. **The order was wrong.** It loaded the risky thing LAST, so the run
   died before learning the cheap fact — what the neural voice costs *on
   this phone*. That number is still unknown, and it is the one that
   decides everything: 1112 MB is a Mac's figure, and CoreML frequently
   MAPS its weights, which count differently against a dirty limit than
   MLX's do (MLX has no `mmap` at all — §25).

**What the design got right:** the probe was killed and its evidence
survived. Every line was flushed to `Documents/pressure-probe.txt` before
the next step ran, and the app reads it back at launch — so the
truncation point itself was readable afterwards. That is the MLX phone
spike's lesson (§24 STAGE 3) being spent rather than re-learned.

**Still unmeasured, and the next thing to take:** the neural voice's cost
on iOS, alone, from a clean launch. If it is well under 1105 MB, the pair
fits at steady state and what killed the app was the CoreML *compile*
spike — a different problem with different cures. If it is near 1112 MB,
the pair genuinely does not fit and something has to give.
