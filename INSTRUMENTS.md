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
