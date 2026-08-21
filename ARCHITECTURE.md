# The map

When the overview blurs, read this page. It exists because after three
phases the overview lived only in heads, and heads leak — against this
repo's own rule that the repo is the memory.

Division of labor between the documents: the code says **what**,
[DECISIONS.md](DECISIONS.md) says **why** (and what was rejected),
[SPEC.md](SPEC.md) says **what was promised**,
[INSTRUMENTS.md](INSTRUMENTS.md) says **what it cost, measured**. This
page says **where**.

Line counts are as of Phase 4 (milestone 4e). They will drift; the shape
should not. Any PR that adds a box or moves an arrow updates this page.

## The spine — sound to text to speech

Everything the library does is one journey. A spoken sentence enters at
the top, and — when the app is talking back — a spoken reply leaves at
the bottom.

```
 microphone ──► MicrophoneSource (385)     the mic tap. The ONLY code that
                     │ writes frames       runs on the audio thread: view
                     │                     the buffer, copy, return. Owns
                     │                     the ORDER of the session seam,
                     │                     the platform's voice-processing
                     │                     unit (4b), an ungated input
                     │                     level (4e), and it watches for
                     │                     the engine killing its own graph.
                     ▼
                AudioRingBuffer (199)      lock-free SPSC ring; the one
                     │                     bridge off the audio thread;
                     │ drains              every dropped frame counted,
                     ▼                     exactly.
                AudioPump (244)  actor     wakes on an injected clock,
                     │                     drains the ring, asks
                     │                     EnergyVAD (99) "speech?" —
                     │                     hangover out — adds 200 ms
                     │                     pre-roll.
                     ▼  AudioEvents:  speechStarted / audioSegment /
                     │                speechEnded / dropped
                     ▼
                TranscriptionSession (366) One loop, one truth:
                     │                     utterance tickets, barge-in,
                     │                     settling decodes (D-024),
                     │                     the single transition funnel.
                     ▼  via the engine seam
                TranscriptionEngine (99)   the protocol: capabilities +
                  ├─ AppleSpeechEngine     openRun / feed / finishAudio.
                  │    (254)               streaming, emits partials.
                  └─ WhisperEngine (267)   whole-utterance, one-decode-
                     │                     at-a-time waiter queue,
                     │                     offline-proven local load.
                     ▼
                TranscriptEvents:  partial / final / failed / truncated
                     │                 ──► the app's screen
                     ▼
                TurnCoordinator (692)      THE NAMESAKE. The conversation
                     │                     above the text: turn ticket,
                     │                     barge-in across the whole chain,
                     │                     the funnel + legal-pair table,
                     │                     the reply gate — the floor must
                     │                     stay yielded before it answers
                     │                     (4b, app's number) — and the
                     │                     TranscriptLedger (98), which
                     │                     keeps the WHOLE thought so a
                     │                     pause mid-sentence no longer
                     │                     costs the first half (4c).
                     ▼  via the turn seams (TurnCoordination, 91)
                  ├─ ReplyGenerating       final text in, reply tokens out
                  │    └─ AppleReplyGenerator (326)   THE MIND (4f): Apple's
                  │         on-device model, a SYSTEM framework, so core's
                  │         zero-dependency vow holds (D-057 F-5). One
                  │         session per turn; snapshots → SnapshotDiffer
                  │         (70), the pure tripwire (D-058) — a revision
                  │         of spoken text is a named failure, never
                  │         spoken garbage. Refusals are SPOKEN (F-4).
                  └─ SpeechSynthesizing    tokens in, spoken EVIDENCE out
                     │                     TWO real mouths since 4e, which
                     │                     is what turned "we can switch
                     │                     mouths" from a claim into a
                     │                     proof. Both pass one kit.
                     │
                     ├─ AppleSpeechSynthesizer (320)   thin: hand text to
                     │     the framework, report delegate evidence. Picks
                     │     the best INSTALLED voice. Behind the 4g shield
                     │     it opens AppleWrittenSynthesisRun (307) instead:
                     │     write() hands us the PCM and the reply renders
                     │     on the capture host — both mouths, one road,
                     │     the canceller sees them all (AC-121).
                     │
                     └─ NeuralVoice (307) ─► NeuralVoiceRun (574)
                           MultiModalKitTTS, an OPT-IN product. Qwen3 via
                           CoreML. The DECODER decodes; WE render, onto a
                           PlaybackHost. `feed` hands off and returns —
                           it must never block the coordinator's loop.
                              │
                              └─► TTSDecoding (60)   a seam of our own, so
                                    ├─ TTSKitDecoder (73)   the vendor's
                                    │    DECODE lives in ONE file. Its model
                                    │    lifecycle does not, by ruling
                                    │    (D-053 F-7 = A).
                                    └─ a scripted decoder in the tests, which
                                         is how the FAILURE path is pinned at
                                         all (AC-109) — a real model cannot be
                                         asked to fail on command.
                     │
                     │  the phrasing for both lives in SpeechPhraser
                     │  (130), pure and clockless; when to START lives in
                     │  PlaybackLead (118), also pure.
                     ▼
                TurnEvents:  stateChanged / replyToken / completed /
                             barged / failed  ──► the app's screen
```

## The seams — each one has two real implementations

That rule is the design story. An interface with one implementation is a
guess; two is a proof, and every one of these has been swapped in anger.

The MIND is the seam that took longest to get its second real citizen —
4f shipped it with one and said so — and 4h supplied it. Note what the
second one did NOT need: `MLXReplyGenerator` uses no `SnapshotDiffer`,
because cumulative snapshots are Apple's API shape and not the seam's.
MLX emits tokens, which is what `ReplyUpdate` already carried.

| Seam | Implementations |
|---|---|
| `AudioSource` | `MicrophoneSource` · `FakeMicrophone` |
| `TranscriptionEngine` | `AppleSpeechEngine` · `WhisperEngine` · `ScriptedTranscriber` |
| `ReplyGenerating` | `AppleReplyGenerator` · **`MLXReplyGenerator` (4h)** · the demos' generators · `ScriptedReplyGenerator` |
| `ReplySnapshotStreaming` (4f, internal) | `FoundationModelSnapshots` · a scripted source in the tests |
| `ReplyTokenStreaming` (4h, internal) | `MLXTokenSource` · a scripted source in the tests |
| `SpeechSynthesizing` | `AppleSpeechSynthesizer` · `NeuralVoice` · `ScriptedSynthesizer` |
| `AudioSessionConfiguring` (4d) | the app's `PhoneSession` · `nil` on macOS |
| `PlaybackHost` (4e) | `AudioEnginePlaybackHost` · `MicrophonePlaybackHost` |
| `TTSDecoding` (4e, internal) | `TTSKitDecoder` · a scripted decoder in the tests |
| `ThermalStateProviding` | `ProcessInfo` · a test provider |
| `Clock` | `ContinuousClock` · `ManualClock` |

## The rails — cross-cutting, everything rides on them

```
 Broadcast (140)           one event stream → many listeners; bounded
                           buffers, drop-oldest, every drop counted.
 StopSignal (71)           clean shutdown, no leaked tasks.
 PipelineDiagnostics (104)  health events: thermal, ring drops, listener
                           losses, settling-decode count — and dead
                           TURNS (D-059), the mind's tripwire among them.
 PipelineSignposter (58)   the os_signpost spans Instruments shows.
 Thermal (54)              ThermalStateProviding seam + the real
                           ProcessInfo provider.
 ThermalPolicy (40)        D-028: one question at one moment — may this
                           settling decode keep its ticket? The shipped
                           default is dormant below .serious. NOTE: it
                           governs transcription only; nothing in the TTS
                           path reads thermal state (4e, open).
 AudioSessionConfiguring   4d: the library calls the platform's steps in
   (42)                    ORDER; the app supplies their contents.
 PlaybackHost (309)        4e: WHERE a reply renders. Two verbs, and the
                           host keeps the ordering rules — attach,
                           connect, THEN start.
 GateCalibration (69)      4e: where to put the VAD gate, computed from a
                           measured room and voice instead of guessed.
```

Diagnostics is optional everywhere (`nil` by default): the library never
requires observation, it offers it.

## The outer ring — not the library

```
 MultiModalKitTesting      determinism tools: ManualClock,
                           ScriptedTranscriber, ScriptedReplyGenerator,
                           ScriptedSynthesizer, FakeMicrophone,
                           WER scorer, BakeoffHarness.
 AudioDemo (339)           terminal demo:
                           swift run audio-demo [apple|whisper] [--talk]
 TranscribeDemo            the iPhone app (Demo/TranscribeDemo): two
                           transcribers, two mouths, an Apple-voice
                           picker, gate calibration, a live level meter,
                           the echo probe, and the barge counters.
  Bakeoff (825)            the measurement tools:
                             swift run bakeoff                 WER, transcribers
                             swift run bakeoff voice-install   fetch the voice
                             swift run bakeoff voice-spike     first-audio, RTF
                             swift run bakeoff voice-levers    decoder matrix
                             swift run bakeoff voice-wer       speak→hear→score
                             swift run bakeoff voice-onmic     a reply rendered
                                                               on a LIVE capture
                                                               engine — the path
                                                               a phone runs
                             swift run bakeoff graph-probe     what a live graph
                                                               tolerates, one
                                                               case per process
                                                               (D-054)
```

The demos are deliberately thin: they wire the spine and draw it. What
they own — permissions, the audio session's VALUES, model download UI —
is what apps must own (AC-22); everything else is the library, unchanged.

**`voice-onmic` is the newest and the most important of those tools.**
Milestone 4e spent an afternoon debugging a live audio graph through a
person holding a phone. That tool runs the same path here, with one
variable, and every fault of that afternoon was findable in one command
(INSTRUMENTS §17, D-049).

## Where is …? — the geography table

| The question | The file |
|---|---|
| The audio-thread code (all of it) | `Audio/MicrophoneSource.swift` — the tap closure |
| The iron laws' one crossing; drop counting | `Audio/AudioRingBuffer.swift` |
| "Is this speech?" — gate, hangover, pre-roll | `Audio/AudioPump.swift` + `Audio/EnergyVAD.swift` |
| Where to PUT the gate, measured | `Audio/GateCalibration.swift` |
| The raw, ungated input level | `Audio/MicrophoneSource.swift` — `inputLevel` |
| The session's ORDER (activate, capture, release) | `Audio/AudioSessionConfiguring.swift` + `MicrophoneSource.start/stop` |
| Barge-in, utterance tickets, settling table | `Transcription/TranscriptionSession.swift` |
| The engine seam and capabilities | `Transcription/TranscriptionEngine.swift` |
| Apple streaming, partials, segment joining | `Transcription/AppleSpeechEngine.swift` |
| Whisper decode, waiter queue, offline load | `MultiModalKitWhisper/WhisperEngine.swift` |
| One-to-many events, listener drop counting | `Concurrency/Broadcast.swift` |
| Thermal + health events | `Diagnostics/PipelineDiagnostics.swift`, `Diagnostics/Thermal.swift` |
| The heat ruling — who may keep settling | `Diagnostics/ThermalPolicy.swift` |
| The turn loop, barge-in, the turn ticket | `Conversation/TurnCoordinator.swift` |
| The reply gate — "did the user yield the floor?" | `Conversation/TurnCoordinator.swift` — `Config.replyGate` |
| The whole thought — what the speaker said, kept | `Conversation/TranscriptLedger.swift` |
| The reply + synthesis seams | `Conversation/TurnCoordination.swift` |
| Tokens → speakable phrases (subwords joined) | `Conversation/SpeechPhraser.swift` |
| "Is there anything worth speaking?" | `Conversation/SpeechPhraser.swift` — `hasSpeakableContent` |
| WHEN it is safe to start speaking (pre-roll) | `Conversation/PlaybackLead.swift` |
| WHERE a reply renders | `Audio/PlaybackHost.swift` |
| Apple's mouth; delegate evidence → seam updates | `Conversation/AppleSpeechSynthesizer.swift` |
| Which Apple voice, and how good it is | `Conversation/AppleSpeechSynthesizer.swift` — `installedVoices` |
| The mind: snapshots → suffix tokens, the tripwire | `Conversation/SnapshotDiffer.swift`, `AppleReplyGenerator.swift` |
| The neural mouth; decode, render, count buffers | `MultiModalKitTTS/NeuralVoice.swift`, `NeuralVoiceRun.swift` |
| What a DECODER owes the mouth (the seam) | `MultiModalKitTTS/TTSDecoding.swift` |
| TTSKit's DECODE api, confined to one file | `MultiModalKitTTS/TTSKitDecoder.swift` |
| TTSKit's model lifecycle, still in the open (D-053 F-7 = A) | `MultiModalKitTTS/NeuralVoice.swift` |
| The echo canceller switch, and what it measured | `Audio/MicrophoneSource.swift`, `INSTRUMENTS.md` §6, §8 |
| The spans in Instruments | `Diagnostics/PipelineSignposter.swift` |
| The manual clock and scripted engines | `Sources/MultiModalKitTesting/` |
| The pipeline wired for real | `Demo/TranscribeDemo/Sources/TranscribeModel.swift`, `Sources/AudioDemo/AudioDemo.swift` |

## The shape in numbers

Everything that is not a test is 10,693 lines; the library core is 4,773,
and the tests are 7,086 — more test than library, which is the point. The
biggest file on the spine is `TurnCoordinator` at 676 lines. (Counted with
`find Sources Tests Demo -name '*.swift' | xargs cat | wc -l`, excluding
the untracked `local_clone/`.)

*Two corrections live in that paragraph, and the second one is worse than
the first.* It used to claim ~7,100 total against a breakdown of
4,000 + 5,600, which cannot both be true. The version that fixed that then
stated 6,127 tests and 667 lines of `TurnCoordinator` — and **both were
wrong too**: 6,127 was counted mid-edit, before the same commit's own test
file landed, and 667 was copied unchanged out of the paragraph being
corrected, where it had never been right. An adversarial reviewer found it
by running the command this paragraph hands the reader. A page that fixes
un-re-run numbers with un-re-run numbers is the exact failure D-054 rule 5
is about, committed inside the correction for it.

The test folder mirrors this map roughly one suite per box — **38 suites,
290 tests**, all deterministic (injected clocks, no sleeps, event-gated),
run 20× before any milestone closes. The suites that touch real speakers
or real models are gated (`MMK_LIVE_SYNTH=1`, model-installed checks) and
skip honestly rather than failing for the wrong reason.

If a box on this map ever stops being explainable in one sitting, that
is a design smell, not a documentation problem — see the deep-module
rule in DECISIONS.md.
