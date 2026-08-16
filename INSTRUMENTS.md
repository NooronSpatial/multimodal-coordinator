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
