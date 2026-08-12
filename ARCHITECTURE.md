# The map

When the overview blurs, read this page. It exists because after three
phases the overview lived only in heads, and heads leak — against this
repo's own rule that the repo is the memory.

Division of labor between the documents: the code says **what**,
[DECISIONS.md](DECISIONS.md) says **why** (and what was rejected),
[SPEC.md](SPEC.md) says **what was promised**. This page says **where**.

Line counts are as of Phase 3 (milestone 3a). They will drift; the shape
should not. Any PR that adds a box or moves an arrow updates this page.

## The spine — sound to text

Everything the library does is one journey. A spoken sentence enters at
the top and leaves as text at the bottom.

```
 microphone ──► MicrophoneSource (45)      the mic tap. The ONLY code that
                     │ writes frames       runs on the audio thread: view
                     │                     the buffer, copy, return.
                     ▼
                AudioRingBuffer (199)      lock-free SPSC ring; the one
                     │                     bridge off the audio thread;
                     │ drains              every dropped frame counted,
                     ▼                     exactly.
                AudioPump (237)  actor     wakes on an injected clock,
                     │                     drains the ring, asks
                     │                     EnergyVAD (78) "speech?", adds
                     │                     200 ms pre-roll.
                     ▼  AudioEvents:  speechStarted / audioSegment /
                     │                speechEnded / dropped
                     ▼
                TranscriptionSession (336) THE HEART. One loop, one truth:
                     │                     utterance tickets, barge-in,
                     │                     settling decodes (D-024),
                     │                     the single transition funnel.
                     ▼  via the engine seam
                TranscriptionEngine (96)   the protocol: capabilities +
                  ├─ AppleSpeechEngine     openRun / feed / finishAudio.
                  │    (254)               streaming, emits partials.
                  └─ WhisperEngine (267)   whole-utterance, one-decode-
                     │                     at-a-time waiter queue,
                     │                     offline-proven local load.
                     ▼
                TranscriptEvents:  partial / final / failed / truncated
                     ──► the app's screen
```

## The rails — cross-cutting, everything rides on them

```
 Broadcast (140)           one event stream → many listeners; bounded
                           buffers, drop-oldest, every drop counted.
 StopSignal (71)           clean shutdown, no leaked tasks.
 PipelineDiagnostics (81)  health events: thermal, ring drops, listener
                           losses, settling-decode count.
 PipelineSignposter (58)   the os_signpost spans Instruments shows.
 Thermal (54)              ThermalStateProviding seam + the real
                           ProcessInfo provider.
 ThermalPolicy (40)        D-028: one question at one moment — may this
                           settling decode keep its ticket? The shipped
                           default is dormant below .serious.
```

Diagnostics is optional everywhere (`nil` by default): the library never
requires observation, it offers it.

## The outer ring — not the library

```
 MultiModalKitTesting      determinism tools: ManualClock,
                           ScriptedTranscriber, FakeMicrophone,
                           WER scorer, BakeoffHarness.
 AudioDemo (205)           terminal demo:  swift run audio-demo [apple|whisper]
 TranscribeDemo (~485)     the iPhone app (Demo/TranscribeDemo).
 Bakeoff (78)              the WER bake-off:  swift run bakeoff
```

The demos are deliberately thin: they wire the spine and draw it. What
they own — permissions, the audio session, model download UI — is what
apps must own (AC-22); everything else is the library, unchanged.

## Where is …? — the geography table

| The question | The file |
|---|---|
| The audio-thread code (all of it) | `Audio/MicrophoneSource.swift` — the tap closure |
| The iron laws' one crossing; drop counting | `Audio/AudioRingBuffer.swift` |
| "Is this speech?" — gate, hangover, pre-roll | `Audio/AudioPump.swift` + `Audio/EnergyVAD.swift` |
| Barge-in, utterance tickets, settling table | `Transcription/TranscriptionSession.swift` |
| The engine seam and capabilities | `Transcription/TranscriptionEngine.swift` |
| Apple streaming, partials, segment joining | `Transcription/AppleSpeechEngine.swift` |
| Whisper decode, waiter queue, offline load | `MultiModalKitWhisper/WhisperEngine.swift` |
| One-to-many events, listener drop counting | `Concurrency/Broadcast.swift` |
| Thermal + health events | `Diagnostics/PipelineDiagnostics.swift`, `Diagnostics/Thermal.swift` |
| The heat ruling — who may keep settling | `Diagnostics/ThermalPolicy.swift`; its one consultation lives in the session's `speechStarted` branch |
| The spans in Instruments | `Diagnostics/PipelineSignposter.swift` |
| The manual clock and scripted engines | `Sources/MultiModalKitTesting/` |
| The pipeline wired for real | `Demo/TranscribeDemo/Sources/TranscribeModel.swift`, `Sources/AudioDemo/AudioDemo.swift` |

## The shape in numbers

The whole system is ~3,400 lines; the library core is ~2,000. The
biggest file on the spine is 336 lines. The test folder mirrors this
map roughly one suite per box — 14 suites, 74 tests, all deterministic
(injected clocks, no sleeps, event-gated).

If a box on this map ever stops being explainable in one sitting, that
is a design smell, not a documentation problem — see the deep-module
rule in DECISIONS.md.
