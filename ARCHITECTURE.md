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
 microphone ──► MicrophoneSource     the mic tap. The ONLY code that
                     │ writes frames       runs on the audio thread: view
                     │                     the buffer, copy, return. Owns
                     │                     the ORDER of the session seam,
                     │                     the platform's voice-processing
                     │                     unit (4b), an ungated input
                     │                     level (4e), and it watches for
                     │                     the engine killing its own graph.
                     ▼
                AudioRingBuffer      lock-free SPSC ring; the one
                     │                     bridge off the audio thread;
                     │ drains              every dropped frame counted,
                     ▼                     exactly.
                AudioPump  actor     wakes on an injected clock,
                     │                     drains the ring, asks
                     │                     EnergyVAD "speech?" —
                     │                     hangover out — adds 200 ms
                     │                     pre-roll.
                     ▼  AudioEvents:  speechStarted / audioSegment /
                     │                speechEnded / dropped
                     ▼
                TranscriptionSession One loop, one truth:
                     │                     utterance tickets, barge-in,
                     │                     settling decodes (D-024),
                     │                     the single transition funnel.
                     ▼  via the engine seam
                TranscriptionEngine   the protocol: capabilities +
                  ├─ AppleSpeechEngine     openRun / feed / finishAudio.
                  │                  streaming, emits partials.
                  └─ WhisperEngine   whole-utterance, one-decode-
                     │                     at-a-time waiter queue,
                     │                     offline-proven local load.
                     ▼
                TranscriptEvents:  partial / final / failed / truncated
                     │                 ──► the app's screen
                     ▼
                TurnCoordinator      THE NAMESAKE. The conversation
                     │                     above the text: turn ticket,
                     │                     barge-in across the whole chain,
                     │                     the funnel + legal-pair table,
                     │                     the reply gate — the floor must
                     │                     stay yielded before it answers
                     │                     (4b, app's number) — and the
                     │                     TranscriptLedger, which
                     │                     keeps the WHOLE thought so a
                     │                     pause mid-sentence no longer
                     │                     costs the first half (4c).
                     ▼  via the turn seams (TurnCoordination, 91)
                  ├─ ReplyGenerating       final text in, reply tokens out
                  │    └─ AppleReplyGenerator   THE MIND (4f): Apple's
                  │         on-device model, a SYSTEM framework, so core's
                  │         zero-dependency vow holds (D-057 F-5). One
                  │         session per turn; snapshots → SnapshotDiffer
                  │        , the pure tripwire (D-058) — a revision
                  │         of spoken text is a named failure, never
                  │         spoken garbage. Refusals are SPOKEN (F-4).
                  └─ SpeechSynthesizing    tokens in, spoken EVIDENCE out
                     │                     TWO real mouths since 4e, which
                     │                     is what turned "we can switch
                     │                     mouths" from a claim into a
                     │                     proof. Both pass one kit.
                     │
                     ├─ AppleSpeechSynthesizer   thin: hand text to
                     │     the framework, report delegate evidence. Picks
                     │     the best INSTALLED voice. Behind the 4g shield
                     │     it opens AppleWrittenSynthesisRun instead:
                     │     write() hands us the PCM and the reply renders
                     │     on the capture host — both mouths, one road,
                     │     the canceller sees them all (AC-121).
                     │
                     └─ NeuralVoice ─► NeuralVoiceRun
                           MultiModalKitTTS, an OPT-IN product. Qwen3 via
                           CoreML. The DECODER decodes; WE render, onto a
                           PlaybackHost. `feed` hands off and returns —
                           it must never block the coordinator's loop.
                              │
                              └─► TTSDecoding   a seam of our own, so
                                    ├─ TTSKitDecoder   the vendor's
                                    │    DECODE lives in ONE file. Its model
                                    │    lifecycle does not, by ruling
                                    │    (D-053 F-7 = A).
                                    └─ a scripted decoder in the tests, which
                                         is how the FAILURE path is pinned at
                                         all (AC-109) — a real model cannot be
                                         asked to fail on command.
                     │
                     │  the phrasing for both lives in SpeechPhraser
                     │ , pure and clockless; when to START lives in
                     │  PlaybackLead, also pure.
                     ▼
                TurnEvents:  stateChanged / replyToken / completed /
                             barged / failed  ──► the app's screen
```

## The front door — the order, owned once (4t)

Two applications used to assemble the spine by hand, and what they
duplicated was not decisions — every differing value was policy pushed out
of the library on purpose (D-027, AC-22). They duplicated SEQUENCE, and
sequence is where the accidents lived. `AIRuntime` owns it:

```
 the app ──► AIRuntime(Configuration)      the app's OWN config types and
                 │                          organs, passed through untouched;
                 │ .run(observing:)         the door adds no policy (AC-204).
                 ▼
     1. build the actors          pump · TranscriptionSession · TurnCoordinator
     2. open EVERY listener       the spine's own AND the app's — before any
                                  loop starts, or the first utterance is lost,
                                  intermittently (AC-202)
     3. one task group            every loop a child; "the group is the wall":
                                  the first child to end stops the actors, every
                                  stream finishes, the scope drains (D-014)
     4. teardown, in order        actors → stopRendering → releaseSource, on the
                                  way out; the bodies of steps 2 and 3 are the
                                  app's closures, the MOMENT is the door's (AC-203)
                 │
                 ▼ Session:  audio · transcripts · turns? · health? · conversation?
             the app observes, and steers the one thing it may — the conversation
```

The name is the destination's, taken early by ruling (D-093 F-5). Today
it composes a voice conversation and nothing else: it cannot see, cannot
call a tool, has no permission layer and no model router. Read it as a
direction, not a claim.

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
| `ReplyGenerating` (takes a `ReplyContext` since 4r) | `AppleReplyGenerator` · **`MLXReplyGenerator` (4h)** · the demos' generators · `ScriptedReplyGenerator` |
| `ReplySnapshotStreaming` (4f, internal) | `FoundationModelSnapshots` · a scripted source in the tests |
| `ReplyTokenStreaming` (4h, internal) | `MLXTokenSource` · a scripted source in the tests |
| `SpeechSynthesizing` | `AppleSpeechSynthesizer` · `NeuralVoice` · `ScriptedSynthesizer` |
| `SpokenVoice` (4q) | `NeuralVoice` (Qwen3-TTS) · `KokoroVoice` |
| `AudioSessionConfiguring` (4d) | the app's `PhoneSession` · `nil` on macOS |
| `PlaybackHost` (4e) | `AudioEnginePlaybackHost` · `MicrophonePlaybackHost` |
| `TTSDecoding` (4e, internal) | `TTSKitDecoder` · a scripted decoder in the tests |
| `ThermalStateProviding` | `ProcessInfo` · a test provider |
| `Clock` | `ContinuousClock` · `ManualClock` |

## The mind's text contract (4v)

This section is the page a caller reads before using the mind on its own.

**Three words it uses, before it uses them:**

| the word | what it means here |
|---|---|
| the **mind** | whatever writes the reply text — the `ReplyGenerating` protocol. Two real ones ship: the Apple mind and the MLX mind. |
| the **mouth** | whatever says the reply out loud — the `SpeechSynthesizing` protocol. The voice path has a mouth; a text caller has none. |
| a **seam** | one protocol with more than one real thing behind it, so a piece can be swapped and the rest of the spine does not notice. |

**And the short codes**, all of which point at files in this repo.
`D-nnn` is a ruling in [DECISIONS.md](DECISIONS.md). `AC-nnn` is a
numbered acceptance criterion and `§nnn` a section, both in
[SPEC.md](SPEC.md). `§nn` in [INSTRUMENTS.md](INSTRUMENTS.md) is a
measurement. `F-n = A` names one of this milestone's design forks and
the option Ryad chose on it. `4v` is this milestone; `4w` and `4x` are
the next two.

### The shortest call that works

```swift
import MultiModalKit
import MultiModalKitMLX

// 1 — the mind: weights on disk, and a generator over them.
let model = LocalMindModel(weights: weightsFolder)
let mind  = MLXReplyGenerator(model: model)   // defaults: nil, 1024

// 2 — can it run on THIS device? nil means yes.
if let why = model.readiness() {
    print(why.description)                    // a sentence for a screen
} else {
    // 3 — the question, the past, and the levers for this one call.
    let context = ReplyContext(
        transcript: "plan me a 30 minute session",
        history: [],                          // oldest first; may be empty
        options: GenerationOptions(
            instructions: "Answer as one JSON object.",
            maxTokens: 1024,
            temperature: 0))                  // 0 = greedy = repeatable

    // 4 — one whole reply, or a typed failure thrown.
    do {
        let reply = try await mind.reply(to: context)
        print(reply.text)
        if reply.stop == .tokenBudget { print("the cap cut it short") }
        if reply.stop == .refused     { print("the model declined") }
    } catch let failure as ReplyFailure {
        print(failure.description)
    }
}
```

The Apple mind is the same four steps with two names changed:
`AppleReplyGenerator()` for the mind, and `AppleMind.readiness()` for
step 2. Everything below is commentary on that block.

### Why it exists, and what moved under the voice path

The caller it was written for is a training app: text in, text out, one
complete reply, no voice. Its own logic recommends a session. The mind
proposes that session as JSON. The app's own validator accepts or
rejects it (D-101). Things in this library blocked that; SPEC §175 lists
nine — eight changes, and this page as the ninth.

**The coordinator's call site is unchanged.** It still calls
`openReply(to:)`, and it passes a default `GenerationOptions()`. Every
existing call site compiled without an edit. That is the whole of what
AC-231 promised.

**One default under it did move.** `nil` on an option means "the
generator's own", and the generator's own budget changed (F-6 = A):

| the token budget | before 4v | now |
|---|---|---|
| MLX mind | `maxTokens: Int = 512` at `init` | `= 1024` |
| Apple mind | no cap sent at all | always `maximumResponseTokens: 1024` |

So the voice path now runs under a 1024-token ceiling it did not have
before. The number is measured, not preferred — see "What is measured".

```
 the caller                                  the library
 ──────────                                  ───────────
 ReplyContext                          ┌──────────────────────────┐
   transcript    the question ────────►│  ReplyGenerating         │
   history       what came before      │    openReply(to:) ── the │
   options       GenerationOptions     │      stream, one reply   │
     instructions  nil = the mind's    │    reply(to:) ─── one    │
     maxTokens     nil = 1024          │      whole value, written│
     temperature   nil = the vendor's  │      once over the stream│
     seed          nil = the vendor's  │      (F-4 = A)           │
                                       └────────────┬─────────────┘
                                                    │
        ┌───────────────────────────────────────────┴──────────────┐
        ▼  openReply — the stream                 reply — one value ▼
   ReplyRun.updates                                Reply { text, stop }
     .token(String)          … many, in birth order        ▲
     then exactly one terminal, then the stream ends:      │ drained here
       .finished(StopReason) ───────────────────────────── ┘
       .failed(ReplyFailure) ─────────────────────────────► throws it
       — cancelled: no terminal at all ───────────────────► CancellationError

 THREE WAYS A REPLY ENDS
   it finished     .finished(.complete | .tokenBudget | .unreported | .refused)
   it failed       .failed(ReplyFailure)   — five cases, all Equatable
   it was cancelled  the stream just ends; a conformant run emits no terminal
```

`reply(to:)` is a protocol extension over `openReply`. It is written
once, so every mind and every fake behaves the same way, and the text
caller and the voice coordinator drain the same stream (F-4 = A,
D-103). It throws the `ReplyFailure` that a `.failed` carried. A refusal
is not a failure and does not throw (D-104).

**Cancelling is a request, not a kill.** Cancel the calling task and
`reply(to:)` calls `run.cancel()`, waits for that call to return, and
then throws `CancellationError`.

What `cancel()` actually does is three things: raise the run's `retired`
flag, ask the run's own worker task to stop, and finish the stream. It
does not wait for that worker to end. So a defiant run may still be
computing after the call has returned. It is *unheard*, not over. A
finished `AsyncStream` drops every later yield, and the flag is raised
in the same locked step that decides "was I first", so nothing the
worker produces afterwards can reach a caller. That is the house rule in
§4.1 of the working contract: cancellation is the optimization, the
ticket is the guarantee.

### Can this mind run here at all?

This is the second question a caller asks, and in the block above it is
asked before the first. **One call answers it, per mind:**

| the mind | the call | it returns |
|---|---|---|
| MLX | `LocalMindModel.readiness()` | `MindUnavailable?` — `nil` means it can run |
| Apple | `AppleMind.readiness()`, or `AppleReplyGenerator.availability` | the same type |

Neither answer is cached, and neither should be: a download can finish
between two turns.

The two minds reach the answer by different roads. The Apple mind asks
the vendor's own availability enum and maps it. The MLX mind fills in a
value and runs a pure function over it:

```
 DeviceReport.current(gpu:install:)            MindNeeds
   platform     iOS | macOS       ─┐             floor        an OSVersion
   os           OSVersion          │             memoryBytes  0 = no claim
   isSimulator  Bool               ├──► MindReadiness.verdict(for:needs:)
   gpu          available | absent │                   │
   memoryHeadroomBytes  Int?       │                   ▼
   install      InstallState      ─┘          MindUnavailable?   nil = it can run
```

Inside `readiness()` those inputs come from three places:

1. `install` — `installState()`, public, on the model. Its four values
   are in "The install, size-checked" below.
2. `gpu` — `MLXRuntime.isAvailable ? .available : .absent`, public. The
   core cannot ask Metal itself; that lives behind the optional module.
3. `needs` — `needs(for:)`, which is **internal**. This mind asks for the
   library's own floor and claims no memory.

A caller does not have to assemble any of that. `DeviceReport.current`
and `MindReadiness.verdict` are public for a different reason: a test
writes a whole device by hand in three lines and reads the verdict off
it. That is why the verdict is a pure function over a value and not a
protocol to fake (F-5 = A).

**The order is the contract.** The checks run in this sequence, and the
first one that fails is the answer, so a device with two problems is told
the one a download will not fix:

| # | the check | the verdict |
|---|---|---|
| 1 | `os < needs.floor` | `.osBelowFloor(required:)` |
| 2 | `isSimulator` | `.deviceCannotRun(.simulator)` |
| 3 | `gpu == .absent` | `.deviceCannotRun(.noGPU)` |
| 4 | `install == .absent` | `.weightsAbsent` |
| 5 | `install == .incomplete(f)` | `.installIncomplete(files: f)` |
| 6 | headroom known **and** need claimed **and** headroom < need | `.notEnoughMemory(needed:available:)` |

Row 1's string is built as the report's platform plus the asking mind's
floor, so it is never one fixed sentence. It reads `"iOS 18"` or
`"macOS 15"` for the MLX mind, which asks for the library floor (D-091).
The Apple mind does not run this function at all, but it builds the same
case from its own floor the same way: `"iOS 26"` or `"macOS 26"`.

Memory comes last, and it refuses only when all three of its facts are
true together. An unknown headroom is never a refusal. `nil` is what a
Mac gives, because a Mac has no per-process limit to report, and `nil`
means "I do not know" rather than "none left". D-092 is the record of
what a number nobody had measured cost this project. Its lesson cuts
both ways: the library must not refuse on a number it does not have
either. Headroom exactly equal to the need is enough.
`.installedUnverified` passes steps 4 and 5, because the phones already
in the field are installed.

### The types, exactly as they are

`Conversation/ReplyContract.swift` holds all of them.

**`GenerationOptions`** — four fields, and `nil` means something
different on each one:

| field | `nil` means |
|---|---|
| `instructions: String?` | keep the generator's own; `nil` on both sides is no system message at all |
| `maxTokens: Int?` | the generator's own default, which is 1024 on both minds since F-6 = A |
| `temperature: Float?` | the vendor's own default — this library never invents a temperature |
| `seed: UInt64?` | leave the vendor's randomness alone |

`GenerationOptions()` is what the coordinator passes, and it is why no
existing call site had to change (AC-231). It is not identical to pre-4v
behaviour — the budget table above is the difference.

`0` for temperature asks for the greedy path, and **both real minds have
one**. The Apple mind maps `0` to the vendor's `.greedy` sampling mode.
The MLX vendor's `sampler()` returns its arg-max sampler for exactly
`temperature == 0`. So a caller gets a repeatable answer without a
second lever (AC-234), and a seed is only needed above zero.

**`StopReason`** — four cases, why a reply ended well:

- `.complete` — the model ended its own turn.
- `.tokenBudget` — the cap cut it. A caller that asked for a whole
  document should know it did not get one.
- `.unreported` — the engine cannot say. The honest value for a mind
  whose API reports no reason, never a guess.
- `.refused` — the model declined, and said so out loud (D-104, F-7 = C).

**Not every mind can produce every case.** A caller should know which
before it writes the switch:

| mind | can end with | never ends with | why |
|---|---|---|---|
| Apple | `.unreported` · `.refused` | `.complete` · `.tokenBudget` | its stream ends without saying why — the vendor's interface has no finish reason to read (AC-235). Even the new 1024 cap cannot announce itself, so a cut reply arrives as `.unreported` |
| MLX | `.complete` · `.tokenBudget` · `.unreported` | `.refused` | the vendor reports `.stop` and `.length`; its model gives no refusal signal at all, so there is nothing to read |

`.refused` is the case that took a ruling. D-057 F-4 = A says a refusal
is spoken out loud and completes the turn, because silence makes a
refusal look like a bug. The spec had listed `.refused` as a failure,
which is a turn that ends with nothing said. Both could not be true.
Ryad ruled C: a refusal is how a reply ends. The person still hears the
refusal sentence, and a text caller reads `stop == .refused` and can
count refusals.

That sentence is `spokenRefusal` on the Apple mind, and it has a
default: `"I can't answer that."`. An app replaces it at `init`; the
default exists so the mechanism works with no configuration. D-027 keeps
this library out of prompt text and out of policy wording for the model.
It does not claim the library has no English of its own — see "What this
contract does NOT do".

**`ReplyFailure`** — five cases, why a reply failed. `.refused` is not
one of them (D-104). The third column is the part a caller needs most,
and a bare list did not have it:

| the failure | retry? | what has to change first |
|---|---|---|
| `.contextWindowExceeded` | not as sent | shorten the question, or drop history, then ask again |
| `.unsupportedLanguage` | not in this language | ask in a language the model has |
| `.busy` | yes, later | nothing. The engine is serving another request, and this library never retries for you (§176) |
| `.unavailable(_)` | it depends | the verdict inside says which — the next table |
| `.engine(_)` | no promise | unknown by construction. This case is what the library could not type, so show the words and do not build a policy on them |

**`MindUnavailable`** — eight case names, and this is all of them, so a
`switch` can be exhaustive. Five come from the pure verdict above.
`.featureDisabled`, `.modelDownloading` and `.unknown` are the Apple
mind's, mapped from the vendor's enum; `.deviceCannotRun` has a third
limit, `.notEligible`, that only the Apple mind produces.

| the verdict | retry? | what has to change first |
|---|---|---|
| `.weightsAbsent` | after a download | `download(reporting:)` on the MLX model. Only a model built with a `repoID` can fetch; one built from a `weights:` folder throws this from the download too |
| `.installIncomplete(files:)` | after a download | the same call — it runs whenever the tree is not complete |
| `.modelDownloading` | later | nothing. The system is still fetching the model |
| `.featureDisabled(name)` | after the person acts | the named switch, in Settings |
| `.notEnoughMemory(needed:available:)` | maybe | free memory, or ask a smaller model. Both numbers are bytes. No mind claims memory today, so nothing produces this yet — ruled, D-105, and explained at the end |
| `.osBelowFloor(required:)` | never | nothing this app can do on this device |
| `.deviceCannotRun(.simulator / .noGPU / .notEligible)` | never | the same |
| `.unknown(String)` | no promise | the vendor stated no cause, so this library states none |

**`Reply`** — `{ text: String, stop: StopReason }`. What `reply(to:)`
returns.

**All four are `Equatable`, and that is the point of typing them at
all.** `ReplyFailure`, `StopReason`, `MindUnavailable` and `Reply` all
conform, so a caller can count: two `.busy` in a run is a fact, where
two strings were only prose. `ReplyFailure` and `MindUnavailable` also
carry `description`, so the same value a switch reads is the sentence a
screen shows — and `.engine(_)`'s description is the words with no
prefix at all, which is how every pre-4v test kept its meaning (AC-242).

### The failure table

The Apple mind, `Conversation/AppleReplyGenerator.swift`. Its vendor
error has nine named cases and is not frozen, so there is a tenth row:

| the vendor said | the caller sees |
|---|---|
| `guardrailViolation` | `.finished(.refused)` — the refusal sentence is spoken first |
| `refusal` | `.finished(.refused)` — the same one row |
| `exceededContextWindowSize` | `.failed(.contextWindowExceeded)` |
| `assetsUnavailable` | `.failed(.unavailable(.unknown("its assets are unavailable — availability said yes and the model said no")))` |
| `unsupportedLanguageOrLocale` | `.failed(.unsupportedLanguage)` |
| `rateLimited` | `.failed(.busy)` |
| `concurrentRequests` | `.failed(.busy)` |
| `unsupportedGuide` | `.failed(.engine(_))` — no guide is ever sent (§176) |
| `decodingFailure` | `.failed(.engine(_))` — no caller-side remedy |
| a case added after this was written | `.failed(.engine(_))`, naming it — the `@unknown default`, AC-114's lesson |

Two rows of that table are not failures at all. `guardrailViolation` and
`refusal` are a supervised model doing its job: the run speaks the app's
short sentence and ends `.finished(.refused)`, and `reply(to:)` returns
rather than throwing. An empty `spokenRefusal` yields no token, because
an empty string is not speech, and a stream that claimed it was would be
the exact silence D-057 exists to prevent.

`assetsUnavailable` is deliberately not mapped to `.modelDownloading`.
That sentence promises "try later", and this library has no evidence the
wait ends. On the Simulator that taught the lesson, availability said
`.available` and then every generation threw — zero snapshots produced,
not a slow start (INSTRUMENTS §22).

Before any row of that table can happen, `openReply` throws
`.unavailable(verdict)` when the readiness question says no. It is asked
fresh at the door, every turn, never cached, because a download can
complete between two turns. Availability is a necessary gate and not a
sufficient one: the same Simulator answered "available" and then failed
every generation, which is why the table above exists at all (AC-110,
INSTRUMENTS §22).

The MLX mind, `MultiModalKitMLX/`. It reports less, and the table says
so rather than pretending:

| what happens | the caller sees |
|---|---|
| the device or the install rules it out | `openReply` throws `.unavailable(verdict)` — asked fresh at the door, every turn, never cached |
| the prepared prompt is `>=` the model's context window | `.failed(.contextWindowExceeded)`, refused before generation |
| the vendor's `.info` says `.stop` | `.finished(.complete)` |
| the vendor's `.info` says `.length` | `.finished(.tokenBudget)` |
| the vendor's `.info` says `.cancelled` | nothing is mapped and nothing is yielded — a cancelled run ends with no terminal (the cancel contract above), and yielding one would be a terminal after a cancel |
| no `.info` event arrives | `.finished(.unreported)` |
| anything the vendor throws | `.failed(.engine("local generation failed: …"))` |

**This mind never reports `.refused`, and that is honest rather than a
gap.** Its model gives no refusal signal at all, so inventing the value
would be a guess. `.unreported` is the word for an engine that does not
say. It also never reports `.unsupportedLanguage` or `.busy`: it has no
vendor case for either.

The window check is the library's own, not the vendor's. The prepared
prompt is counted before generation, and refused at `>=` rather than
`>` — a prompt that fills every position leaves no position for a reply.
An unknown window, from a `config.json` that does not say, never
refuses: the same D-092 rule the memory check follows.

*What is proven, and what is only believed.* The tests prove this
library's own arithmetic — `MLXPromptFitTests` calls
`PromptFit.refusal(promptTokens:window:)` directly (AC-236). The reason
recorded in the source for doing the check at all is that the vendor
does not refuse an over-long prompt itself. No instrument in this repo
has watched it happen, so that reason is a working assumption, not a
measurement.

### The install, size-checked

Before 4v, "installed" meant a file with the right name exists. D-101's
L1 recorded exactly that: existence, not size. A download that stops
part-way leaves a tree that passes such a check and then fails on the
first token.

So a complete download now writes `manifest.json` beside the weights,
and `installState()` verifies against it:

| state | what it means |
|---|---|
| `.installed` | a manifest, no file missing or short, and the tree can answer offline — `config.json`, `tokenizer.json`, `tokenizer_config.json`, and at least one `.safetensors` |
| `.incomplete(files:)` | a manifest, and those named files are missing or shorter than it says |
| `.absent` | no usable tree, manifest or not |
| `.installedUnverified` | the files are there and offline-capable, but there is no manifest — a pre-4v install, the phones already in the field |

**What the manifest actually lists.** Every regular, non-hidden file at
the top level of the weights folder, with its byte size. It skips
itself, and it skips anything whose name starts with a dot — the
download cache's own bookkeeping. It follows symbolic links and skips a
dangling one. It is not recursive. Links are followed because a model
cache is a tree of them, and the first live run refused a perfectly good
install by measuring the link instead of the file.

**Only a complete download writes the manifest.** The cancel is checked
in `completeInstall`, before anything is moved or written. A manifest
built from a partial tree would list the short files at their short
sizes and call the install complete — the exact lie the manifest exists
to end. The reason the check sits there is recorded in the source: the
download client is believed to return early on cancellation with a
partial tree and no error. That belief is not measured here; what the
tests prove is that our own code checks cancellation first, over a fake
fetch handed in as an argument (`MLXInstallTests`).

A tree already on a phone before 4v is left without a manifest and stays
`.installedUnverified` until it is fetched again, because this library
does not invent byte counts for files it did not download.

`InstallProgress` is honest about what it can and cannot tell you:

- `fraction` — 0…1, from the client. Clamped here; a NaN reads as 0.
- `bytesExpected` — an earlier manifest's total, or `nil` on a first
  install. Never invented.
- `bytesReceived` — **derived, not counted**: `fraction × bytesExpected`.

That last line is the one not to oversell, and the source says why: the
download client's unit is believed to be one file, not one byte. With
one 2 GB weight file beside four small JSONs, "80% of files" would be a
few megabytes and not 80% of the bytes. That client behaviour is not
measured in this repo either. What is certain from the code alone is
that `bytesReceived` is arithmetic over a fraction this library did not
compute, so it is an honest progress bar and a poor byte counter, and a
caller must not read it as a measurement.

### What can throw, and what cannot

Until 4v several of these were `precondition`s. A precondition is the
right tool for an invariant a caller cannot reach, and the wrong one for
a number a caller reads out of its own settings. A crash is a fact a
person finds in a log afterwards; an error is a fact a caller can switch
over and show (AC-241). Two error types, and the checks they carry —
§175/8 counts five doors where D-101 had seen two:

| the refusal | the door | the type |
|---|---|---|
| a mind with no mouth | `AIRuntime.init` | `AIRuntimeConfigurationError.mindWithoutMouth` |
| a mouth with no mind | `AIRuntime.init` | `.mouthWithoutMind` |
| a non-zero reply gate on the clockless coordinator | `TurnCoordinator.init` (clockless) | `TurnCoordinatorConfigurationError.replyGateNeedsAClock` |
| `maxContextPieces < 1` | both `TurnCoordinator` doors, and `AIRuntime.init` as `.turns(_)` | `.contextBoundMustBePositive` |
| `maxMemoryTurns < 0` · `maxMemoryCharacters < 1` | the same three | `.memoryTurnsMustBeNonNegative` · `.memoryCharactersMustBePositive` |

D-101 named the first two rules: the runtime's mind-and-mouth pairing,
and the clockless gate. The 4v review found the three `Config` numbers
with a probe. They passed `AIRuntime.init` and then trapped inside
`run()`, after the microphone was already capturing. That late trap is
the hazard AC-241 exists to remove. `Config.validate()` is public on
purpose, so an app can check its settings before it opens a source.
Neither error type is nested inside the generic type that throws it, so
a `catch` does not have to name a clock it does not have.

**The `precondition`s that stay, and the invariant each one guards:**

| where | the invariant |
|---|---|
| `Audio/AudioRingBuffer.swift` — `RingStorage.init` | a ring's capacity must be positive. It is rounded up to a power of two and used as a mask, and zero has no mask. It travels through no `Config`, and every value handed to `AudioRing.create(minimumCapacity:)` in this repo resolves to a literal — the one call site that passes a variable is a test fixture whose parameter has a literal default and literal overrides. |
| `MultiModalKitTesting/ManualClock.swift` — `advance(to:)` | test time may not move backwards. A clock that went back would wake a sleeper twice and make a deterministic test lie. Test support, never in a shipping path. |

Three more `precondition`s are still in the code and are no longer
reachable **through the coordinator's or the runtime's doors**: the
ledger's bound and the memory's two now sit behind `Config.validate()`,
which refuses the same numbers as typed errors first.

**Three honest residues, named rather than buried.** All three types are
public and have public initializers that still trap, so a caller that
builds one directly reaches the trap:

| the door | the trap |
|---|---|
| `TranscriptLedger.init(maxPieces:)` | `maxPieces > 0` |
| `ConversationMemory.init(maxTurns:maxCharacters:)` | `maxTurns >= 0` and `maxCharacters > 0` |
| `SpeechPhraser.Config.init` | `maxPhraseCharacters >= 1`, and `KokoroVoice.init(phraseCharacters:)` passes a caller's number straight through |

Each invariant is real. A ledger that can hold nothing loses the
sentence being spoken right now. A phrase limit below one leaves no room
for a character, so the cut cannot advance and `feed` would spin
building empty phrases. But by §175/8's own rule these are
caller-supplied numbers, and they should come back as errors. They were
not on AC-241's list and are not fixed here.

### What this contract does NOT do

§176's non-goals, plainly, so nobody plans around a promise that was
never made:

- **No JSON schema, no guided decoding, no validation.** The mind
  returns text. The caller's own validator disposes (D-101). The
  measured run in INSTRUMENTS §65 came back as one clean JSON object
  because the model was told the shape and obeyed. That is a property of
  that prompt and that model, not a guarantee this library makes.
- **No prompt authoring.** The instructions sent to the model are the
  caller's, on the call or at `init`. This library writes none (D-027,
  D-057 F-3). It does ship English of its own elsewhere, and says so
  plainly: the refusal sentence has a replaceable default, and
  `ReplyFailure` and `MindUnavailable` carry `description` sentences
  meant for a screen.
- **No retry, no queueing, no admission policy.** A `.busy` is reported,
  not absorbed.
- **No second seam.** `ReplyGenerating` stays the one protocol. The
  whole reply is written over it, not beside it, so a text caller and
  the voice path can never drift apart.
- **No voice change and no new dependency.** The coordinator, the
  phraser, barge-in and memory are untouched, and the core stays at zero
  runtime dependencies.

Two things are named in the spec and were deliberately not built here.
The foreground-release hook a caller might look for already exists: it
is `LocalMindModel.retire()`, which cancels the warm-up and drops the
weights, and 4v documents it rather than adding a second one. Everything
else on the caller's lifecycle, admission and privacy lists — a privacy
manifest included — is a later milestone (4x). Tools are 4w.

### What is measured

INSTRUMENTS §65 is the whole table; three numbers from it:

- **Greedy repeats byte for byte.** Temperature 0, the same question
  twice on one Mac: 210 characters, identical, `complete`. A seed at
  temperature 0.6 repeats too. The free row is the control — 218
  characters, then 258 — and if it had repeated, the table would be
  measuring caching rather than determinism.
- **One whole reply in the caller's own shape**, a ~800-character JSON
  proposal at the 1024 budget: **484 / 464 ms to the first token and
  3 710 / 3 694 ms in total**, greedy, on that Mac.
- **800 characters is longer than the 600 the spec guessed**, which is
  why the default budget rose to 1024 (F-6 = A).

Two caveats belong with those numbers. **Determinism is per model and
per machine.** The same seed on another chip is not promised, and
nothing here claims it. And these are Mac numbers: the phone is not
measured in §65, and a reply of this length will cost more there.

### One question, asked and answered

**SPEC §178 F-8 — does the reply door claim memory? Ruled: no (D-105).** `MindUnavailable`
carries `.notEnoughMemory(needed:available:)` and the verdict computes
it, but nothing says who supplies the number. A first cut had the MLX
reply door claim `weights × 1.5`. The review showed that this could lock
a phone out for good, because the estimate only drops once the weights
are resident, and a refused reply door never gets there. The claim was
removed. **So today no mind claims memory.** The MLX mind's `needs(for:)`
returns `memoryBytes: 0`, and its reply door and its load door ask that
one same question; the Apple mind maps the platform's own availability
enum and never reaches the memory branch at all. No caller is refused
for memory today, and a phone that cannot fit the model finds out when
the load fails, as it did before 4v.

Ryad ruled it that way on 2026-09-09 (D-105): the enum case and the pure
verdict stay, tested over hand-written reports, and they wait for a
milestone that MEASURES what a mind needs rather than inferring it from
a file size. A number that can lock a device out belongs with a
measurement, not with a guess.

## Getting the weights (4x)

The section above is how the mind ANSWERS. This one is how it ARRIVES.
It is written for the caller that has to ask a person for 2.28 GB of
their data allowance, and be honest about what that costs and what
leaves the device.

**The short codes, for a reader who landed here from a link.** `AC-nnn`
is a numbered acceptance criterion in `SPEC.md`; `§nnn` is a spec
section; `D-nnn` is a ruling in `DECISIONS.md`; `L7` is one of Aura's
lessons — the one that says a cache a person can re-download must be
kept out of their iCloud backup. `F-n = A` names a design fork and the option Ryad chose on it —
here always a fork of milestone **4x**, ruled in **D-106**, not 4v's.
The three that carry this section: **F-2 = A** (a stopped download
deletes its partial tree), **F-3 = A** (the suspend limit is stated, not
engineered), **F-4 = A** (a privacy manifest per linkable module).

### The life of an install

```
 ASKING DOWNLOADS NOTHING — but it IS a network call, and a slow one
 ┌──────────────────────────────────────────────────────────────────────┐
 │  expectedInstall()                                                   │
 │  9 files · 2 278 969 756 bytes · ~3.4 s (INSTRUMENTS §66, 2026-09-10)│
 │  no WEIGHT bytes fetched · no directory made · installState() same   │
 │  it still makes 10 listings and 9 HEADs — never on onAppear          │
 └──────────────────────────────────────────────────────────────────────┘

 .absent                       download(reporting:)
 or .incomplete(files:) ─────────────────┐
                                         ▼
                         ┌──────────────────────────────────────┐
                         │ DOWNLOADING                          │
                         │ the fetcher writes its OWN tree,     │
                         │ under the PARENT of <weights>        │
                         │ progress is a FRACTION, not bytes    │
                         └───┬───────────────────────┬──────────┘
                it returns   │                       │  it throws
                  a path     │                       │
                             ▼                       │
        ┌─────────────────────────────────────────┐  │
        │ completeInstall(movingFrom:)            │  │
        │  1 CANCELLED? stop here, move nothing   │  │
        │  2 MOVE the tree to <weights>.incoming  │  │  ← STAGED
        │    (a stale .incoming from a dead       │  │
        │     process is removed first)           │  │
        │  3 WRITE manifest.json THERE            │  │
        │  4 SWAP it into <weights>               │  │  ← 4 and 5 touch
        │  5 mark it excluded from backup         │  │    the LIVE tree.
        └───┬─────────────────────────────────┬───┘  │    1…3 never do
            │ 1…5 all done                    │ 1 saw a cancel,
            │                                 │ or 2…4 threw   │
            ▼                                 ▼                ▼
        ┌────────────────┐   ┌──────────────────────────────────────────┐
        │ .installed     │   │ cancelled     → CancellationError        │
        └────────────────┘   │ the fetch threw → .fetchFailed(String)   │
                             │ step 2…4 threw  → .couldNotComplete(_)   │
                             │        both InstallFailure cases         │
                             └──────────────────┬───────────────────────┘
                                                ▼
                          the new tree is DELETED · a tree that was
                          already there is UNTOUCHED · the state is
                          .absent, or the .incomplete it already was —
                          never .installed, never .installedUnverified

                          TWO EXCEPTIONS, both a fetcher's own doing:
                          · it hands back <base> itself → <base> and every
                            model beside it survive; mayDelete needs a
                            STRICT descendant, so the "new tree" is never
                            deleted — aFetcherThatReturnsTheBaseKeepsIt
                          · it writes STRAIGHT INTO <weights> → nothing to
                            stage, manifest written in place, and over a
                            tree that was ALREADY there a failed write can
                            leave it .installedUnverified. WeightsFetching
                            tells a conformer not to do this.
```

Two things in that picture are the whole safety argument, and they are
worth reading twice. **The manifest is written at the staging path**,
so a tree in `<weights>` either carries a manifest or was never
completed here. And **the swap is the last step**, so every failure
before it leaves the LIVE WEIGHTS TREE exactly as this download found
it. Both are `completeInstall(movingFrom:)` in
`MultiModalKitMLX/LocalMindInstall.swift`.

**Say "the live tree", not "the disk", because the disk does change.**
Before the move, that same function creates the parent directory if it
is missing, and removes any stale `<weights>.incoming` a dead process
left behind. What no failure touches is `<weights>` itself. Steps 4 and
5 are the only ones that do — and the in-place exception at the bottom
of the diagram is the one path that writes a manifest straight into the
live tree, which is why `WeightsFetching` tells a conformer not to take
it.

One path skips the staging box. A fetcher may write STRAIGHT INTO the
weights directory and hand that same path back. Then there is no second
copy to stage, so the manifest is written in place. `WeightsFetching`
tells a conformer not to do this, for the reason the diagram gives.

**How that path is recognised matters.** The code compares the resolved
PATH, not the `URL`. A `URL` is text: `…/Fake-Model` and `…/Fake-Model/`
are two spellings of one directory. An earlier version compared with
`!=`, so the second spelling looked like a different place — and the
code then moved the live tree away to stage a copy of it. If the
manifest write failed after that, the caller's bytes were gone.
`samePlace(_:_:)` in `LocalMindInstall.swift` is the fix, and
`aDifferentSpellingOfTheWeightsTreeIsStillTheWeightsTree` is the row.

### The shortest install that works

```swift
import MultiModalKitMLX

// 1 — a model that KNOWS where its weights come from. The other
//     initializer, LocalMindModel(weights:), never downloads anything.
//     `in:` defaults to URL.documentsDirectory, so the weights land at
//     Documents/Qwen3-4B-4bit — the LAST path component of the repo id.
let model = LocalMindModel(repoID: "mlx-community/Qwen3-4B-4bit")
print(model.weights)   // public, nonisolated, never changes: THE folder

// 2 — the price, BEFORE a byte of the model moves. This reaches the
//     network. Ask it once, and keep the answer.
let size = try await model.expectedInstall()
print(size.downloadBytes, size.onDiskBytes)      // bytes, and bytes
for file in size.files { print(file.name, file.bytes) }

// 3 — the download. Cancel the surrounding task to stop it.
try await model.download(reporting: { progress in
    print(progress.fraction)                     // 0…1, always a number
    print(progress.bytesExpected ?? -1)          // nil on a FIRST install
})

// 4 — what is on disk now. No await: it is nonisolated, and cheap.
switch model.installState() {
case .installed, .installedUnverified: print("ready")
case .incomplete(let files): print("repair", files)   // the names to show
case .absent: print("offer the download")
}

// …and the same download, driven by a fetcher of your own — this is the
// seam, and it is shipping API, not test-only. Step 3 above calls it
// with HubWeightsFetcher() as the default.
try await model.download(reporting: { _ in }, using: MyFakeFetcher())
```

Everything below is commentary on that block.

**Where the folder is, in one line**, because "delete the weights" and
"show storage used" are both questions about a path. `model.weights` is
a public, *nonisolated* `let URL` that never changes. **Nonisolated**
means it is not behind the actor's door: any thread may read it, with no
`await`. So a settings screen can show it without waiting for anything.
For a model built with `LocalMindModel(repoID:in:)` it is `directory`
plus the last component of the repo id, and `directory` defaults to
`URL.documentsDirectory`.

**An install can have bytes in THREE places, not one**, and a settings
screen has to know all three. For the model in the block above:

| path | who writes it | when it is there |
|---|---|---|
| `Documents/Qwen3-4B-4bit` | this library, on the last steps | the LIVE tree — what `installState()` reads, and what a Delete Model button removes |
| `Documents/Qwen3-4B-4bit.incoming` | this library, while it stages | only DURING `completeInstall` |
| `Documents/models/mlx-community/Qwen3-4B-4bit` | the shipped fetcher's client | only DURING the download |

The middle row is the staging sibling the diagram names.
`completeInstall(movingFrom:)` moves the whole new tree — 2.28 GB —
to `<weights>.incoming`, writes `manifest.json` there, and only then
swaps it in. The tests treat a leftover sibling as a real hazard: it
would be a second copy of the model in a person's Documents, invisible
to `installState()`. `MLXInstallLateFailureTests.stagingLeftovers`
asserts it is gone on the success path and on all three failure paths.

The third row is the fetcher's own tree. `HubWeightsFetcher` hands its
client `model.weights.deletingLastPathComponent()` as a base, and the
client materialises the repo at `base/models/<owner>/<name>`.

**Every in-process path clears rows two and three. A process that is
KILLED clears neither.** So a storage row must measure all three paths,
and a Delete Model button must remove all three — not just
`model.weights`. The suspend section below has the lines to run and what
they save.

### The size — and it is a network call

`expectedInstall()` returns an `InstallSize`: `downloadBytes`,
`onDiskBytes`, and `files`, every file with its name and its byte count,
sorted by name. The totals are DERIVED from `files` by the only
initializer there is, so the breakdown and the total cannot disagree.

**It reaches the network, and its name does not say so.** The doc
comment does, loudly, and a spec fork is open about the name itself
(SPEC §184 F-6, raised by the build, **not ruled**). Until it is ruled,
the rule for a caller is simple: this is not a call to put on a screen's
`onAppear`. Ask it once, when a person is about to be shown a number,
and keep the answer.

**What one ask really costs.** The repository listing gives names, not
sizes, so the size comes from one metadata request per file — and the
client makes its own listing before each one. A metadata request is an
HTTP `HEAD`: it asks for a file's headers, its size among them, and
brings back none of the file itself. For a nine-file model that is **ten
listings and nine HEADs**, all small. The doc on `hubSizes` carries that
count because an earlier version of it said "nine and nine" and a review
counted the calls in the client instead of trusting the sentence.

**Measured once, on the real repository** (INSTRUMENTS §66,
`mlx-community/Qwen3-4B-4bit`, Ryad's Mac on a home connection,
**2026-09-10**):

| what | measured |
|---|---|
| files | 9 |
| to download | **2 278 969 756 bytes** |
| on disk afterwards | the same 2 278 969 756 bytes |
| the whole question | **3 388 ms** |
| bytes fetched by asking | **0** — the target directory held 0 files, `installState()` still `.absent` |

**Say the units out loud, because two conventions disagree here and a
person will compare your screen to Settings.** 2 278 969 756 bytes is
**2.28 GB decimal** (÷ 10⁹) or **2.12 GiB binary** (÷ 2³⁰). Apple's own
byte formatting is decimal, so that is the number a phone's storage
screen shows and the number your download screen must match. A screen
printing "2 173 MB" — the same bytes in MiB — sits beside a Settings
entry saying 2.28 GB and looks like a lie.

**This is not hypothetical: it happened here, in this milestone.** The
`install-size` instrument divided by 2²⁰ and printed the column header
"MB", so INSTRUMENTS §66 recorded 2 173 MB while every prose page said
2.3 GB — one model, one measurement, and documents that disagreed with
each other. The review that fact-checked this page is what caught it.
The instrument now prints both columns with both labels, and §66 states
which one to show a person. **2.28 GB decimal is the figure.**

The lesson for a caller is not to pick a favourite page. Format
`downloadBytes` with `ByteCountFormatStyle` and let it choose. Never
copy a rounded figure out of a document into a screen, and never
hand-divide.

`downloadBytes` and `onDiskBytes` are equal here, and that is a fact
about this install path rather than a rounding: the snapshot is MOVED
into place exactly as it arrived. Nothing is unpacked, and nothing is
re-quantised — *quantising* is squeezing a model's numbers into fewer
bits, which this repo's model has had done to it already, in the
repository, before any download. Only `manifest.json` is added. They stay
two fields because the day a model repacks on arrival, a caller that
assumed one number would be wrong in the direction that fills a phone.

**The trap: the weights file alone under-promises by ~16 MB.**
`model.safetensors` is 2 263 022 529 of the 2 278 969 756 bytes. The
tokenizer and the vocabularies are the other ~16 MB. A caller that showed
the weights file and then counted the whole download would overrun its
own progress bar. Show `downloadBytes`.

**The number will drift** the day the repository publishes the model
squeezed to a different number of bits, or repacks a tokenizer. That is
why it is written down with its date, and why this library reads it from
the repository every time and caches nothing. `bakeoff install-size` is
how to take it again.

**What comes out when it fails, and it is three things, not two.** Two
are typed by this library and name what went wrong:
`ReplyFailure.unavailable(.weightsAbsent)` when this model has no
repository to ask (the same error `download` throws for the same reason,
so a caller has one case and not two), and
`InstallFailure.sizeUnknown(file:)` when a file's size cannot be learned
— because a total that quietly leaves the 2 GB file out is worse than no
total at all. **The third is everything the hub client throws, untyped
and unwrapped.** `hubSizes` in `LocalMindInstallSize.swift` awaits
`getFilenames` and `getFileMetadata` with no `catch`, so a `URLError`, a
`Hub.HubClientError` or an environment error reaches the caller as
itself. On a bad connection that is the COMMON case, not the rare one.
So a price screen needs a `default` arm, and it should say "we could not
reach the repository — try again", not "unknown error". (The source's own
`- Throws:` list has the same gap; noted here rather than fixed, because
this page does not edit Swift.)

**And it is slow enough to design around.** 3 388 ms on a Mac, on a home
connection. On a phone on mobile data it will be worse, and this library
sets no timeout of its own — whatever the hub client's session does is
what happens. So do not block a whole screen on it with a bare spinner:
draw the screen first, ask once, keep the answer, and have a "could not
get the price" state ready beside the number.

**And there is no seam for the price — say it plainly, because the
download half has one.** `download` takes a fetcher of your own.
`expectedInstall()` takes nothing. The shape the tests use,
`expectedInstall(asking:)`, is internal, and so is the `Sizing`
typealias it takes. So an offline UI test of the number, the spinner and
the "could not get the price" state has no injection point in this
library. A caller that wants one must put `expectedInstall()` behind a
protocol of its own. That is a gap in this milestone, written here
rather than left to be found.

### The four install states

`installState()` is public, nonisolated and cheap — a directory listing
and one small JSON. Never a load, never a network call, so a door can
ask it every turn. **The folder it lists is `model.weights`** — public,
nonisolated, fixed at init. That is the URL a Delete Model button
removes, and the URL a storage row measures.

| state | what it means | ready? |
|---|---|---|
| `.installed` | a manifest, no file missing or short, and the tree can answer offline | **yes** |
| `.installedUnverified` | the required files are there, and there is no manifest | **yes** |
| `.incomplete(files:)` | a manifest, and those named files are missing or shorter than it says | no |
| `.absent` | no usable tree, manifest or not | no |

"Ready" is not a word the code uses; `modelInstalled()` is, and it is
`true` for exactly the two rows marked yes. The readiness verdict agrees:
`.absent` becomes `.weightsAbsent` and `.incomplete` becomes
`.installIncomplete(files:)`, while both installed rows pass (the table
in "Can this mind run here at all?" above).

**Why `.installedUnverified` exists.** Only a download writes a
manifest, because only a download has seen the bytes arrive. So a tree
that arrived before this work — a phone already in the field, or a
folder a person dropped in by hand over USB, which `LocalMindModel`
explicitly invites — has no manifest to be checked against. It is
treated as installed, because it ran yesterday and a missing manifest is
not evidence of a missing file. What this library will not do is invent
byte counts for files it did not fetch.

**What a caller should do about it: nothing, and know why.** Calling
`download(reporting:)` on such a tree does NOT upgrade it. The download
returns at its own `guard !modelInstalled()` before asking any fetcher
for anything, and writes no manifest — `downloadOnACompleteTreeIsANoOp`
in `MLXInstallTests.swift` pins exactly that. The tree keeps working and
keeps its state. A caller that wants a verified install must remove
`model.weights` — `FileManager.removeItem(at: model.weights)`, the same
URL `installState()` reads — and download afresh, which costs the full
2.3 GB. So it is a choice to offer a person rather than one to make for
them.

### Progress, honestly

`InstallProgress` has three fields, and only one of them is always a
number:

| field | what it is |
|---|---|
| `fraction` | 0…1, from the fetcher. Clamped here; a NaN reads as 0 |
| `bytesExpected` | an EARLIER manifest's total, or `nil` on a first install. Never invented |
| `bytesReceived` | `fraction × bytesExpected` — DERIVED, never counted — or `nil` when the total is |

**Nothing counts bytes for a first download**, so `bytesExpected` is
`nil` and stays `nil` — `aFirstInstallInventsNoTotal` proves it, and the
AC-249 row asserts every progress it saw carried `nil` there. On a
re-install — a repair of an `.incomplete` tree — the OLD manifest
supplies the total, and `theHubPathCarriesTheManifestsExpectedTotal`
proves the number comes from there and nowhere else.

**What a caller should draw when `bytesExpected` is `nil`:** the bar at
`fraction`, and beside it the total `expectedInstall()` already gave,
labelled as what the download WILL cost — not as bytes received. What it
must not draw is `bytesReceived` as a measurement. The reason is in the
source rather than in an instrument: the shipped client's progress unit
is believed to be one FILE, not one byte, and nothing in this repo has
watched it to be sure. If that belief holds, then with one 2 GB weight
file beside four small JSONs, "80% of files" is a few megabytes and not
80% of the bytes. So it is an honest progress bar and a poor byte
counter, and the field carries that warning in its own doc comment.

`fraction` is safe to hand straight to a view. It is clamped to 0…1
because a client has been seen reporting outside it. A NaN reads as 0,
and that line is there because of a real crash, not a worry:
`min(max(x, 0), 1)` does not clamp NaN, and the conversion below it
killed a test process.

**How the closure ARRIVES, which a bar cannot be drawn without.** Four
facts, all read from `LocalMindInstall.swift` at this commit:

- **It can be called from any thread.** The parameter is
  `@escaping @Sendable`, and `download` passes it on to the fetcher,
  which calls it from wherever its transfer reports. There is no hop to
  the main actor anywhere in that path — `download` is on the actor, but
  the closure is not. **So hop to the main actor yourself before you
  touch a view.** The worked example below writes
  `seen.withLock { … }` for exactly this reason.
- **Roughly one call per FILE, not per byte** — the same belief the
  paragraph above rests on. For this model that is about nine calls for
  a 2.3 GB download.
- **Nothing promises the number only rises.** `InstallProgress.at`
  clamps to 0…1 and turns NaN into 0. It does not remember the last
  value. A bar that must never go backwards has to keep its own maximum.
- **A final `1.0` is NOT guaranteed.** After the fetch returns,
  `download` never calls the closure again — the one call site is inside
  the fetch. So fill the bar when `download` RETURNS, not when a 1.0
  arrives.

### What a cancelled or failed download leaves (F-2 = A)

Ryad ruled **F-2 = A** (D-106): a stopped download DELETES its partial
tree. Simple, provable, and `installState()` cannot lie. The cost is that
a person who cancels at 90% pays again; keep-and-resume was rejected
because "resume" is a promise that has to be tested on a bad network, and
this Mac cannot do that honestly.

| what stopped it | what the caller gets | what is on disk |
|---|---|---|
| the caller cancelled | `CancellationError`, unwrapped | the partial tree is gone |
| the fetch threw | `InstallFailure.fetchFailed(String)` | the same |
| putting it in place threw | `InstallFailure.couldNotComplete(String)` | the same |

Cancellation is not an `InstallFailure` case, deliberately: it is
something the CALLER asked for, not a failure of the install.

**Who does the deleting is split, and the split is a rule rather than a
courtesy.**

When a fetch RETURNS, it has named its directory, and this library
removes that directory. The removal is bounded: the path must be a
strict descendant of the base the library handed out, and must never be
an ancestor of the weights tree. That bound is not decoration. An
unbounded version of the same line, in a review probe, deleted a
person's whole Documents folder — `aFetcherThatReturnsTheBaseKeepsIt` is
the row that now holds it shut.

When a fetch THROWS, it has named nothing at all. This library does not
go looking for a directory to delete. So cleaning up after a throw is
the conformer's job. `WeightsFetching` states it as a requirement, and
`HubWeightsFetcher` keeps it.

**What that last sentence is worth, exactly.** The shipped cleanup and
the shipped location are both proven —
`theShippedFetchersCleanupIsBounded` removes the client's own tree and
leaves a sibling model beside it untouched. What no test executes is the
one line joining them, `HubWeightsFetcher.fetch`'s own `catch`: reaching
it needs a real network failure, and no test in this house touches the
network. The test that names this says so itself.

**The promise that matters most: an install that was already there is
never destroyed by a download that fails — and it has two limits, which
belong here and not in a footnote.** The new bytes are completed at the
staging sibling, manifest and all, and only a tree that survived every
step is swapped in. That is a mechanism, and the table below is what the
mechanism has actually been measured doing.

The two limits, both spelled out further down this section: a fetcher
that writes STRAIGHT INTO the weights directory has already replaced
whatever was there, before this library is asked anything; and no test
crosses "a caller's tree" with a CANCEL, so that one corner is argued
from the source rather than measured.

The rows are all in
`Tests/MultiModalKitTests/Mind/MLXInstallSeamTests.swift`, and each row
says what it covers — because two of them were being credited with more
than they run:

| the promise | the test | over what |
|---|---|---|
| a cancel leaves `.absent`, partial tree deleted | `aCancelDeletesThePartialTree` | an EMPTY base |
| a thrown fetch leaves `.absent`, error typed | `aThrownFetchLeavesNothing` | an EMPTY base |
| a failure AFTER the move leaves nothing pretending | `aFailureAfterTheMoveLeavesNothingPretending` | an EMPTY base |
| a caller's `.incomplete` tree survives a fetch that throws | `aFailedRedownloadKeepsWhatWasAlreadyThere` | a caller's tree |
| **a failure after the move over a caller's tree keeps that tree** | `aLateFailureOverACallersTreeKeepsIt` | a caller's tree |
| a move that fails never touches the tree it would replace | `aMoveThatFailsNeverTouchesTheCallersTree` | a caller's tree |
| a complete install survives a later re-download, untouched | `aCompleteInstallSurvivesAReDownload` | a finished install |
| a losing racer whose FETCH throws deletes nothing | `aLateFailureNeverDeletesAFinishedInstall` | a finished install |
| **a losing racer whose fetch SUCCEEDS and whose swap fails deletes nothing** | `aLateRacingFailureNeverDeletesAFinishedInstall` | a finished install |

**The last two rows look alike. They are not.** Each proves one half of
the promise, and neither half stands in for the other.
`aLateFailureNeverDeletesAFinishedInstall` parks its
slow download in a fetch that THROWS, so that download never reaches
`completeInstall` at all; what it exercises is
`discardPartialInstall`'s re-read of the disk.
`aLateRacingFailureNeverDeletesAFinishedInstall` parks the slow download
and then lets it RETURN a real snapshot whose manifest write fails — so
the failure lands INSIDE `completeInstall`, which is where the old code
destroyed things. It asserts `.installed` afterwards, and that the bytes
on disk are the winner's 4 096 and not the loser's 1 024. That is the
row that proves the swap. The test file writes the same distinction down
above both rows.

**The fifth row is the one to name if only one can be named**, because
it crosses the two conditions the earlier rows each covered only half
of: a tree that was ALREADY there, and a failure that lands AFTER the
fetch succeeded. A review probe ran that crossing and printed
`.installedUnverified` — the word AC-247 forbids — and then every later
download returned early at `guard !modelInstalled()`, so no manifest
could ever be written by anyone. The cause was an order, not a missing
guard: the old code deleted the live tree first and wrote the manifest
last. The staging swap is what closed it.

**Two things the table does NOT prove, said here rather than left to be
assumed.**

- **A cancel over a tree that was already there.** Both cancel rows
  start from an empty base and assert `.absent`. No row crosses "a
  caller's `.incomplete` tree" with a cancel. The code reads as safe —
  `completeInstall` runs `try Task.checkCancellation()` as its first
  line, before anything is moved, and `discardPartialInstall` returns at
  its `wasAlreadyThere` guard before the `removeItem(at: weights)` — but
  that is reasoning from the source, not a measured row. Treat it as
  argued, and if it matters to a screen, add the row.
- **A real full disk.** `aLateFailureOverACallersTreeKeepsIt` and
  `aLateRacingFailureNeverDeletesAFinishedInstall` both make the
  manifest write fail *in the shape* a full disk makes it fail — the
  manifest's slot is a directory, so the write throws at the same point.
  That is the failure SHAPE, proven. No test fills a volume.

**One boundary, stated rather than buried.** A fetcher that writes
straight into the weights directory and hands that same path back has
already replaced whatever was there. That happens before this library is
asked anything. `WeightsFetching` tells a conformer not to do it. Past
that line, this library protects nothing.

### The suspend truth (F-3 = A)

**What IS verified, and what is reasoning from it — the two are not the
same size here.**

| the claim | how it stands |
|---|---|
| there is no background session | **verified in the source.** `HubWeightsFetcher.fetch` builds `HubApi(downloadBase: base)`, and the vendored `HubApi.init` leaves `useBackgroundSession` at its default of `false`. A test in `MLXInstallSuspendTests.swift` fails if either that flag or `URLSessionConfiguration.background` ever appears in `Sources/MultiModalKitMLX` |
| an ordinary session's transfer stops when iOS suspends the process | reasoning from the platform, not from a run here |
| what the awaiting call sees afterwards | **not measured.** INSTRUMENTS §66's own closing block says the same: the download's duration, its behaviour on a bad connection, and what a suspend does to it were not measured |

So the honest headline is: **on iOS, a download is expected to die when
the app leaves the foreground, and this library has nothing to stop it.**
On macOS an app that is not frontmost is not suspended, so the same
sentence does not apply there — and the live tests in this repo run on
this Mac, which is part of why nobody here has watched a real suspend.

`try await model.download(reporting:)` can only end three ways —
returning, throwing `CancellationError`, or throwing an `InstallFailure`.
A transfer killed by the system would arrive as `.fetchFailed(String)`,
because that is what wraps anything the fetcher throws. It is equally
possible the call simply stays suspended with the process and reports no
progress again. Nobody here has watched it.

**So what should a download screen do? Not a short stall timer.** If the
progress unit really is one file, a first install of this model reports
about NINE times — and one of those gaps, `model.safetensors`, is
2 263 022 529 of the 2 278 969 756 bytes. That is more than 99% of the
wait spent in a single silence, which on a phone is many minutes. **No
safe threshold has been measured, so this page will not invent one.**
Keep the restart button on the screen at all times instead of arming it
from a timer. If you do add a timer, measure it in tens of minutes, and
have it say "still working" rather than "stalled".

**What a caller must do about it, corrected.** Disabling the idle timer
only stops the screen going to sleep on its own. It does NOT stop a
person locking the phone or switching app, which is the case the
headline above names. So a keep-awake is worth having, and it is not
enough on its own. The download screen needs a restart button that is
always there, not only a progress bar.

**"Starting again begins at zero" — with a boundary.** That is true when
the fetch RETURNED or THREW. The cleanup runs on those two paths:
`HubWeightsFetcher.fetch` removes the client's tree from its own
`catch`, and `download` removes what it can name after the fetch
returns.

A process the system suspends and then TERMINATES runs neither. What it
leaves is this. The client's tree stays where it was being written.
`HubWeightsFetcher`'s doc names that place: `base/models/<owner>/<name>`.
Here `base` is `model.weights.deletingLastPathComponent()`. The client's
own per-file bookkeeping lives inside that same tree. And if the kill
landed inside `completeInstall`, a `<weights>.incoming` sibling stays
too.

**Three things follow, and the third is the one nobody expects.**

1. **The bytes are not gone, and `installState()` cannot see them.** Up
   to the whole 2.3 GB can be sitting at
   `Documents/models/<owner>/<name>` while `installState()` answers
   `.absent`.
2. **They are not excluded from backup.** The exclusion flag is set by
   `excludeWeightsFromBackup()`, on `model.weights`, on the last line of
   a SUCCESSFUL install. A tree that a kill left behind was never
   flagged, and it is not `model.weights`, so nothing flags it. That is
   the L7 bill — 2.3 GB of cache inside a person's iCloud backup — being
   paid by exactly the failure the backup section below does not cover.
   Read the two sections together: the flag protects a finished install,
   not a dead one.
3. **A Delete Model button on `model.weights` removes none of it.**

So a caller that wants D-106's ruling honoured after a kill has to
delete the leftovers itself, at launch, before offering the download
again. Neither path is public API, so both are built by hand:

```swift
let files = FileManager.default
let parent = model.weights.deletingLastPathComponent()   // Documents

// 1 — the fetcher client's tree. NOT `parent`, which is the person's
//     whole Documents folder, and NOT `parent/models`, where other
//     models live beside this one.
try? files.removeItem(at: parent.appending(path: "models/mlx-community/Qwen3-4B-4bit"))

// 2 — a staging sibling a kill left mid-install.
try? files.removeItem(
    at: parent.appending(path: model.weights.lastPathComponent + ".incoming"))
```

**Read that first path twice.** An unbounded version of the same line,
in a review probe, deleted a person's whole Documents folder — the same
mistake `aFetcherThatReturnsTheBaseKeepsIt` now holds shut inside the
library.

**What happens if you leave the leftovers instead: less certain than
this page said before.** The client keeps per-file bookkeeping in that
tree, and `WeightsFetching`'s own note says its next run "reuses a file
whose commit hash still matches" — so finished files are not fetched
again. Whether the file it was in the MIDDLE of resumes by byte range or
restarts is not something this repo has read out of the client or
watched. Either way it is some form of option B, the one D-106 rejected,
arriving by accident rather than by design. And either way one file is
2 263 022 529 of the 2 278 969 756 bytes, so the saving is small next to
the risk of a cache nobody counts.

**Can a caller keep this off mobile data? Not through this library.**
No file in `Sources/` sets `allowsCellularAccess`,
`allowsExpensiveNetworkAccess` or `allowsConstrainedNetworkAccess`, and
`Sources/MultiModalKitMLX` builds no `URLSession` at all — the hub
client makes its own, at its defaults. So a download started on mobile
data runs on mobile data, and 2.3 GB can go that way, including by
accident if a screen offers the button with no check. The only lever
this library gives is the seam: a caller that must be Wi-Fi-only
conforms its own `WeightsFetching` with a session it configures, and
passes it to `download(reporting:using:)`. Guarding the tap with `NWPathMonitor` on
the caller's side is the cheaper half of the same answer.

**This is a stated limit, not an engineered solution**, and Ryad ruled it
that way (D-106, F-3 = A). A background `URLSession` is what a 2.3 GB
cellular download really needs, and it is a different downloader, a
delegate and a re-entry path — a milestone of its own, not a bullet in
this one.

A statement can drift away from the code, so two rows in
`MLXInstallSuspendTests.swift` read this module's own source: one fails
if the doc comment loses the sentence, the other fails if
`URLSessionConfiguration.background` or the client's
`useBackgroundSession` flag ever appears anywhere in
`Sources/MultiModalKitMLX`. That is AC-251's second half.

One thing about that scan is worth knowing. AC-251 asked it to look for
`URLSessionConfiguration.background`. That string could never appear
here, because this module builds no `URLSession` at all — so on its own
the scan would pass forever and prove nothing. The string that CAN
appear is the hub client's own `useBackgroundSession` flag, which is why
the test looks for both.

### The backup flag (L7, AC-250)

The weights are a re-downloadable cache. **2.3 GB of cache inside a
person's iCloud backup is a bill they never agreed to**, and they pay it
in storage they must buy or in a backup that stops finishing.

So the weights directory is marked excluded from backup on the **last
line of every install** — not once, at creation. That distinction is the
whole criterion: `completeInstall` swaps a fresh tree into place, and a
new directory carries no flag, so a mark set when the weights first
appeared would silently be gone after the repair that replaced them.
`theBackupFlagSurvivesAReDownload` clears the flag by hand, truncates a
file so the download's own guard lets a second one through, downloads
again, and asserts the flag is back.

The failure is swallowed on purpose: a filesystem that will not take the
flag is not a reason to throw away a complete, working install.

**What the flag does NOT cover, said here so the two sections meet.** It
is set on `model.weights`, and only when an install finishes. It is never
set on the fetcher's own tree at `Documents/models/<owner>/<name>`, and
never on a `<weights>.incoming` sibling. A download that a killed process
left behind is therefore up to 2.3 GB inside a person's Documents with no
exclusion flag on it — the exact bill this section says the design
avoids, arriving through the one path it does not reach. The suspend
section above has the two lines that clear it.

### Faking the install (AC-249)

`WeightsFetching` is public. One method, deliberately — every extra
requirement is a thing a caller's fake has to get right before it can be
used at all:

```swift
public protocol WeightsFetching: Sendable {
    func fetch(repoID: String,
               into base: URL,
               reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}
```

**Where you plug it in**, which is the one line that makes this section
usable. `LocalMindModel` has THREE public `download` methods. Two of them
matter here, and both are shipping API — the second is not test-only:

```swift
// the default: uses HubWeightsFetcher(), reaches the network
public func download(reporting: @escaping @Sendable (InstallProgress) -> Void) async throws

// the seam: your fetcher, no network, everything else identical
public func download(reporting: @escaping @Sendable (InstallProgress) -> Void,
                     using fetcher: some WeightsFetching) async throws
```

The first is a one-line wrapper over the second
(`try await download(reporting: progress, using: HubWeightsFetcher())`),
so there is no second code path to test. The fetcher is passed per call,
not stored on the model — there is no `LocalMindModel(repoID:fetcher:)`.
A caller wires it the way the tests do — this is the wiring line from
`aCallersFakeDrivesACompleteInstall`, with its own fetcher double:

```swift
try await model.download(
    reporting: { progress in seen.withLock { $0.append(progress) } },
    using: FakeWeightsFetcher { _, _, report in
        // writes four small files into a directory of its own,
        // report(0.25) … report(1.0), and returns that directory
        return snapshot
    })
```

`FakeWeightsFetcher` is that test file's own double, not shipped API — a
caller writes the equivalent for its screen. The line that matters is
`using:`.

**The third method, so autocomplete does not surprise you.**
`download(progress: @escaping @Sendable (Double) -> Void = { _ in })` is
the pre-4v shape. It survives as a thin wrapper over the `reporting:`
one, so the demo and the `fetch` instrument keep compiling. It hands you
`$0.fraction` and throws `bytesExpected` and `bytesReceived` away. It is
public, a caller will find it, and new code should take the `reporting:`
shape instead.

Nothing else about the install changes: the guards, the staging, the
manifest and the backup flag are this library's, whoever brought the
bytes.

**Its doc carries requirements, not suggestions.** Three of them, quoted:

- "**A CONFORMER THAT THROWS CLEANS UP AFTER ITSELF** (F-2 = A). The
  throw carries no path, so nothing outside can find what was written;
  whatever bytes have landed must be removed before the error leaves this
  method, or the next attempt does not begin at zero."
- On the returned directory: "Make it a directory of the conformer's
  OWN, not the weights directory itself" — everything the install
  promises about a failure rests on the new bytes being completed
  somewhere else first.
- On `base`: "`base` itself is not its own to hand back" — the returned
  directory is moved into place, and a directory cannot be moved inside
  itself. A conformer that returns `base` fails the install and loses
  nothing, which is proven rather than promised
  (`aFetcherThatReturnsTheBaseKeepsIt`).

The progress argument is forgiving on purpose: values outside 0…1 are
clamped by the caller, so a conformer that reports a rough number cannot
break a progress bar.

**The row to copy** is `aCallersFakeDrivesACompleteInstall` in
`MLXInstallSeamTests.swift`: a fake writes four small files into a
temporary directory, reports quarters, and a real `download` produces
reported progress, a written manifest and `.installed` — with none of
this library's Hub code in the path.

### What leaves the device

The full answer is its own page: **[docs/HOSTS.md](docs/HOSTS.md)**. Its
headline, in its own words, is that this library contacts exactly one
host family — `huggingface.co` — and only while it is downloading model
weights; once the weights are on disk, listening, thinking and speaking
issue no requests at all. That sentence was untrue when the page was
first written, and this milestone's own recorder is what caught it, so
the page keeps the story rather than tidying it away.

Three things a caller should read there before quoting the headline:

- **The credential caveat is not closed.** This library sets no request
  header at all, and reads no device or person identifier — that half is
  scanned by a test. But three of the four weight fetches, the mind's
  among them, go through hub clients this repo did not write — each one
  ships inside a dependency, which is what `docs/HOSTS.md` means by
  "vendored". Those clients resolve a token from the ENVIRONMENT when
  none is given, and would then send
  `Authorization: Bearer …`. An app sandbox on a phone has nothing for
  them to find; a developer's Mac that has signed in with the hub's
  command-line tool does. This library cannot currently switch it off.
  Reported on that page, not decided.
- **The silence proof's real reach.** A *silence proof* is a test that
  puts a recorder in front of the process's networking, runs a whole
  cycle, and then asserts the recorder saw no request. The recorder is
  installed with `URLProtocol.registerClass` — `URLProtocol` is the
  Foundation hook that lets code sit in front of URL requests. That hook
  reaches `URLSession.shared` and nothing else: not a session a package
  builds for itself, even on a default configuration. Of the weight path
  that means the `httpGet` metadata calls ARE watched, while the `HEAD`
  metadata calls and the 2.3 GB snapshot itself are **not**. A green run
  means "no request left through `URLSession.shared`", never "no byte
  left this device".
- **The privacy manifests.** F-4 = A: six `PrivacyInfo.xcprivacy` files
  ship, one per linkable module, each declared in `Package.swift` as
  `.copy("PrivacyInfo.xcprivacy")` — a manifest that is not declared as a
  resource never reaches a consumer's app.

### What this does NOT do

SPEC §182's non-goals, plainly, plus the two things this milestone owes:

- **No download UI.** The library reports; the app draws.
- **No background download and no resume.** F-3 = A and F-2 = A, both
  above. Keep-and-resume is named as a later milestone for someone who
  can measure it on a real, bad, moving network.
- **No admission, thermal or memory-pressure work — in 4x.** When this
  section was written the library refused no device for memory (D-105),
  before a download or after one, and F-1 = A named that as the next
  milestone's question. That milestone is the next section, "Running it
  safely (4y)": `admit(needing:)` now compares a number the APP measured
  to the phone's headroom, and refuses with
  `.notEnoughMemory(needed:available:)`. The headroom it reads is a
  `HeadroomReading` injected at the model's init — by default the same
  kernel reader (`MemoryHeadroomReader.read`) that fills
  `DeviceReport.memoryHeadroomBytes` for `readiness()`; admission never
  opens a `DeviceReport`. Headroom there is memory, not disk. Nothing
  here infers that number from `expectedInstall()`; D-105 still forbids
  it.
- **No free-DISK check at all, and that is a different question.**
  Nothing in this library asks the volume how much room is left, and no
  test fills one, so the disk-full path is argued from the code and never
  measured. A caller must ask for itself before it offers the button —
  `URL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`
  is the key Apple wants for a large optional download. Ask for more than
  `onDiskBytes`: a REPAIR of an `.incomplete` tree downloads a fresh copy
  while the old tree is still on disk, so at the peak the volume holds
  both.
- **No new dependency and no second fetcher.** The hub client stays,
  behind the new protocol.
- **No change to the text contract (4v), and no tools (4w).**
- **AC-254 is not complete, and must not be ticked.** No test reads a
  request header. What ships is a source-level scan plus the honest
  finding above, and the header-level assertion the criterion asks for is
  owed.
- **The size call's name is an open fork** (§184 F-6). `expectedInstall()`
  reaches the network and does not say so in its name; the doc does. The
  builder did not rename a public symbol on its own.

## Running it safely (4y)

The section above is how the mind ARRIVES. This one is how it runs on
a phone that may be **hot** or **short of memory** — without the phone
killing the app. It is written for the caller that runs a 2.3 GB model
inside a spinner, on a device that may have just come off a charger or
a run (SPEC §186).

**The short codes, for a reader who landed here from a link.** `AC-nnn`
is a numbered acceptance criterion in `SPEC.md`; `§nnn` is a spec
section; `D-nnn` is a ruling in `DECISIONS.md`; `§nn` in
`INSTRUMENTS.md` is a measurement. `F-n = A` names a design fork and
the option Ryad chose on it — here always a fork of milestone **4y**,
ruled in **D-107**: **F-1 = A** (the app sets the memory number),
**F-2 = A** (heat refuses at `.critical` only), **F-3 = A** (a memory
warning cancels the generation), **F-4 = A** (a deadline is an ending).
Two more forks, **F-5** and **F-6**, were raised by the build and ruled
by delegation in **D-108**: **F-5 = B** (the door reads headroom, not
pressure) and **F-6 = A** (the one untyped throw is to become a typed
verdict, `.unavailable(.retiredDuringLoad)` — owed under AC-268, not
built) — they are named where they bite, below. `Rn` is a row
of the caller's own requirements list: `R1`, `R2`, `R3` and `R7` are
quoted in SPEC §186 (one admission call; heat before a generation;
pressure abandons the generation; a wall-clock deadline); `R4` is named
in AC-262 (a retire is not the end — the next reply reloads); `R5` is
named in §188 (what happens when the app goes to the background — a
non-goal here).

**Four memory words, before the picture.** *Jetsam* is iOS's memory
killer: it does not warn, it terminates the process that is over its
limit. The *dirty-memory limit* is that limit — the ceiling iOS sets on
the memory one process has written to; *headroom* is the bytes left
before it. A Mac has no such limit, so a Mac reports no headroom. The
*prefill* is the model's first pass over the whole prompt, before the
first token comes out — where a reply's short-lived memory is born
(INSTRUMENTS §68: ~95 MB above the floor on the Mac's 0.6B). The *KV
cache* is what the prefill builds: the model's working memory
for that prompt, one entry per prompt token, grown by one per generated
token, read again for every later token. It lives inside the vendor's
generation task and dies with it.

### The life of a generation under threat

```
 the app                              the library (the MLX mind; the Apple mind has
 ───────                              the DOOR and the DEADLINE only — see "Heat")
                                      ──────────────────────────────────────────────
 model.admit(needing: N)  ─────────►  ADMISSION   LocalMind+Admission.swift
   N = the app's OWN number            1 readiness()  no? ──► throws .unavailable(verdict)
   (F-1 = A; 0 = "no claim")           2 the gate: ONE admission at a time, held
                                         until the load has ENDED (that is "no window")
                                       3 already resident? ──► admitted, no question
                                       4 headroom KNOWN and < N ──► throws .unavailable(
                                           .notEnoughMemory(needed: N, available: h))
                                         headroom UNKNOWN ──► never refuses (D-092)
                                       5 the LOAD, gate still held; released on every exit

 mind.openReply(to: ctx)  ─────────►  THE DOOR    MLXReplyGenerator.openReply
   ctx.options.deadline = 8 s          1 HEAT   thermometer read once; policy says no?
                                                ──► throws .tooHot(state)  (default: .critical)
                                       2 READY  readiness() no? ──► throws .unavailable(verdict)
                                       3 a run is born: REGISTERED for pressure at once,
                                         and a sleeper armed on the clock if a deadline was set
                                                        │  the run's own task
                                                        ▼
            ┌── the load door: ensureModelLoaded() — the weights, if not resident ──┐
            │ ✓ CHECK 1  Task.checkCancellation()  BEFORE the vendor's serial lock  │
            │            is asked for                     LocalMind.swift:496       │
            ├── the lock is taken; the prompt is built and counted (AC-236) ────────┤
            │ ✓ CHECK 2  Task.checkCancellation()  BEFORE the prefill               │
            │            the vendor's lock ignores cancellation, so a run cut while │
            │            parked on it arrives here ALIVE  LocalMind.swift:578       │
            ├── PREFILL: the KV cache is born, inside the vendor's own task ────────┤
            │            ~95 MB over the floor on the Mac's 0.6B (INSTRUMENTS §68)  │
            ├── TOKENS: .token … .token — each admitted under the run's lock ───────┤
            └── the vendor's task ENDS ── awaited, not dropped ── the cache is gone ─┘

 THREE WAYS IT IS CUT          what the stream gives back        what memory does
 ────────────────────          ──────────────────────────        ────────────────
 the DEADLINE fires            tokens so far, then               the vendor's task is cancelled
  (options.deadline, slept     .finished(.deadline)              AND awaited; the KV cache goes
   on the injected clock)      — an ENDING, never a failure      with it; the pool is cleared.
                                (F-4 = A)                        Measured: after == before (§68)
 a memory WARNING              tokens so far, then the stream    the same. The WEIGHTS stay.
  (.warning from the kernel,   just ENDS — NO terminal, like a
   through the pressure seam)  barge (F-3 = A)
 a memory CRITICAL             the same silence                  the same, then retire(): the
  (.critical)                                                    weights go too. The next
                                                                 openReply RELOADS them (R4)
```

The two cancellation checks are the memory argument, so they are drawn
where they sit. A run that is already dead — a `.warning` during the
load, an early barge, an early deadline — used to pay the WHOLE prompt
prefill before anything looked. The vendor's `TokenIterator` prefills
synchronously in its `init`, the vendor's serial lock does not honour
cancellation (a cancelled task waits its turn and enters), and the first
check on the old path was the drain's, one token later. Check 1 keeps a
dead run from taking the lock at all, so the NEXT reply does not queue
behind a corpse. Check 2 is the last look before the prefill, for the run
that was cut while parked on the lock. What is proven and what is only
read is in "What is measured".

### The shortest code that works

```swift
import MultiModalKit
import MultiModalKitMLX

// The model reads the kernel's own headroom and pressure by default; a
// test hands in scripted ones (`headroom:` and `pressure:` at init).
let model = LocalMindModel(weights: weightsFolder)

// 1 — ONE admission call, with YOUR number (F-1 = A). Bytes the app
//     measured for itself: the PEAK a load plus one reply reaches, not
//     the file size (D-105). 3.3 GB here rounds UP the phone's largest
//     measured peak for a 2.3 GB model (3.26 GB, INSTRUMENTS §60) —
//     see "What the number should be, and one way to get it".
//     0 means "no claim": the load is admitted unasked.
do {
    try await model.admit(needing: 3_300_000_000)
} catch ReplyFailure.unavailable(.notEnoughMemory(needed: let needed, available: let available)) {
    print("short by \(needed - available) bytes")      // refused BEFORE a byte was read
} catch let failure as ReplyFailure {
    print(failure.description)                         // the readiness verdict, typed
}

// 2 — the mind. Thermometer, policy and clock are the shipped defaults;
//     an app that wants to refuse earlier injects its own policy here.
let mind = MLXReplyGenerator(model: model)
// let mind = MLXReplyGenerator(model: model, thermalPolicy: RefuseAtSerious())

// 3 — a reply with a wall-clock budget BESIDE the token budget.
do {
    let reply = try await mind.reply(to: ReplyContext(
        transcript: "plan me a 30 minute session",
        options: GenerationOptions(maxTokens: 1024, deadline: .seconds(8))))
    switch reply.stop {
    case .deadline:    print("the clock cut it — show what it has:", reply.text)
    case .tokenBudget: print("the cap cut it:", reply.text)
    default:           print(reply.text)
    }
} catch ReplyFailure.tooHot(let state) {
    print("too hot to generate at \(state)")           // no run was opened; ask again cooler
} catch let failure as ReplyFailure {
    print(failure.description)
}
```

The Apple mind is steps 2 and 3 with `AppleReplyGenerator()` in place of
the MLX mind: it takes the same `thermal:`, `thermalPolicy:` and `clock:`
at `init`, throws the same `.tooHot`, and ends the same
`.finished(.deadline)`. It has no `admit(needing:)` and reads no memory
pressure, because the vendor's framework manages its own memory behind
`LanguageModelSession` — this library holds no allocation to admit and no
cache to free there. Everything else on this page is commentary on that
block.

### Admission

**One call, one gate.** `LocalMindModel.admit(needing:)` is Aura's R1
(SPEC §187/1, AC-258, AC-259). Before 4y a caller asked `readiness()`
and then loaded, and between the check and the allocation there was a
window — a second caller, or the phone itself, could fall into it, and
jetsam (the killer defined above) would end the app inside it. The gate
closes the window:

```
 admit(needing: N)
   │
   ├─ readiness()  ──► a verdict? throw .unavailable(verdict). Asked FIRST, before
   │                   the gate, so a Simulator or an absent install is told THAT and
   │                   the memory question is only put to a device that could load.
   │
   └─ MindAdmission.admit          an actor: a busy flag, a FIFO of waiters,
        │                          a WHILE loop re-checked after every wake
        ├─ while admitting { park }         ◄── a second caller waits HERE
        ├─ admitting = true;  defer { release; wake EVERY waiter }
        ├─ resident?  yes ──► load() (idempotent), no memory question
        ├─ h = headroom()         KNOWN and h < N ──► throw .notEnoughMemory(N, h)
        │                        UNKNOWN            ──► go on (D-092)
        │                        .exhausted         ──► a KNOWN zero: refuses
        └─ load()                gate still held until this returns or throws
```

**"No window" is a lock across the whole load, not a single actor
step.** This matters, and the source says it plainly
(`LocalMind+Admission.swift`, the type comment): the first cut claimed the
check and the allocation were one step with no `await` between them; the
review read `load()` and found its first suspension is the hop INTO the
model, long before a byte is allocated. What actually holds the door is
the `admitting` flag, raised before the check and held until the load
has ENDED, released on every exit. So a second caller's check runs
against the number the first caller's allocation left behind — never a
stale one.

**How it is proven.** `MLXAdmissionTests.theSecondCallerSeesTheFirstsAllocation`.
The picture of the row:

```
 headroom 3 GB · two callers · each needs 2 GB

 first  ─ admit ─ headroom read: 3 GB ─ load BEGINS ─ (parked) ──────── load ENDS ─►
                                                                        headroom := 1 GB
 second ───────── admit ─ waits at the gate ................................. ─ headroom read: 1 GB
                          ▲ the row WAITS for this fact                          ──► refused:
                            (MindAdmission.parked ≥ 1)                              needed 2 GB,
                            before it lets the first load end                       available 1 GB
```

In words, one step at a time. The first caller's load begins and parks.
The second caller arrives and waits at the gate. The row waits for the
FACT that the second is parked (`MindAdmission.parked`, a count a test
can wait on). Only then does it let the first's load end, which sets the
headroom to 1 GB — the way the kernel would see the allocation land.
Then it asserts three things: the second is refused with
`.notEnoughMemory(needed: 2 GB, available: 1 GB)`; exactly one load ran;
and the facts came in this order:
`headroom read: 3 GB · first load began · first load ended · headroom read: 1 GB`.

Remove the wait on the `admitting` flag (the mutant) and the row goes
red. It did not always. The first draft did not wait for the park, so
the mutant slipped through green one run in ten: whenever the scheduler
ran the second caller only after the first load had landed, the stale
window was never entered (the row's comment; SPEC §190a and the source
comment say the same fact from the other side — the red held nine runs
in ten). Now the row gates on the park: a gate that does not park never
sends that fact, and the row dies on its cap instead of on the
scheduler's mood. No run count is claimed for the fixed row beyond
that. The house rule about events, again.

**The number is the app's to measure (F-1 = A).** `admit(needing:)`
takes bytes the APP measured for itself and compares them to the phone's
headroom — bytes REMAINING before the dirty-memory limit, which already
counts everything resident (D-092's correction: never subtract from it).
The library will not infer the number from a file size, and the reason
is D-105's own history: the first cut of the 4v reply door claimed
`weights × 1.5`, had to exempt an already-resident model, and the review
showed it could lock a phone out for good — the estimate only drops once
the weights are resident, and a refused door never gets there. A number
that can lock a device out belongs with a measurement, not a guess. The
rejected options are in D-107: infer it (D-105 forbids), or no check at
all (admits a load that jetsam kills seconds later — the race R1 names).

**What the number should be, and one way to get it.** The comparison
is made while the weights are NOT resident (a resident model is admitted
unasked), so `N` is everything the load and one reply will add on top of
an empty mind: the weights, plus the prefill and the KV cache of a
prompt the app's own size. Not the file size — the file is only the
weights. One way to measure it, the way §68's rows do: on a reference
device, with the mind unloaded, call `MLXRuntime.resetPeakMemory()`,
then load and run one reply of the app's usual prompt, then read
`MLXRuntime.peakMemoryBytes` — the peak in bytes since the reset, MLX's
own counter (what MLX held, not the whole process; the weights are in
it because they were loaded after the reset). Round it up and ship it
as `N`. The picture on the phone: the 4B sits at ~2.3 GB resident, and
MLX's peak in a field session reached 3.06 GB and 3.26 GB (INSTRUMENTS
§58, §60); on the Mac's 0.6B the reply adds ~95 MB above a 320 MB floor
(§68). That
is why the example passes 3.3 GB for a 2.3 GB model: it rounds UP the
larger of the two measured peaks — the weights plus the working memory
a reply needs. A number below the measured peak is a guess dressed as
a measurement. The library does not check the number against anything
but the headroom, so a number too small admits a load that jetsam will
kill — the app's measurement is the whole safety of this call.

**Admission asks no heat question.** `admit(needing:)` reads readiness
and headroom, nothing else (`LocalMindModel.admit`, five steps in the
picture above, none of them a thermometer). A hot phone is admitted and
loads 2.3 GB; heat is asked at `openReply`, once per door (the "Heat"
section). A caller that wants to refuse a hot load asks its own
thermometer before it calls `admit`.

**What `0` means.** No claim — D-105's own shape. The load is admitted
with no memory question asked, even on an `.exhausted` headroom
(`zeroBytesIsNoClaim`).

**What an unknown headroom means.** Never a refusal (AC-259, D-092). A
Mac reports none, because a Mac has no per-process limit; a kernel that
answers with a short struct reports none either. A number you do not
have is not a number you may refuse on. The row runs all three
`unavailable` reasons through the gate and watches each one load
(`anUnknownHeadroomAdmits`). `.exhausted` is different: it is a KNOWN
zero, and refuses with `available: 0` (`exhaustedIsZeroAndRefuses`).
Headroom exactly equal to the need admits — the refusal is strictly
below (`equalHeadroomAdmits`).

**Weights already resident are admitted without the question.** The
headroom has already paid for them, and refusing a mind that is loaded
and answering is exactly the lock-out D-105 removed
(`residentWeightsAreAdmitted`). `resident` is read INSIDE the gate, after
the wait, because the holder is another actor and its answer ages.

**The gate is released on every exit.** A load that throws lets the next
admission through (`aFailedLoadReleasesTheGate`), and every waiter is
woken — not one — because a woken waiter here may return early, and a
one-at-a-time hand-off would strand the rest (the lesson `Retirable`
records, D-051).

**Admission is optional — and it is not remembered.** `openReply` loads
the weights itself if they are not resident, through the same load door
— with no memory question. `admit(needing:)` is the call that ASKS one.
A caller that never calls it is where it was before 4y, and finds out at
the load, as D-105 says. **This matters after a `.critical`.** A
critical warning retires the weights (the "Pressure" section), and the
next `openReply` reloads them with no memory question — on a phone that
just ran out of memory. So the caller must call `admit(needing:)` AGAIN
before its next reply, or it is back in the pre-4y race for that one
load. The gate does not know the weights were once admitted; it asks
`resident` and the headroom fresh every time (`MindAdmission.admit`,
the `resident()` read inside the gate).

**On the Mac and on the phone.** This Mac reports no headroom, so the
real door admits any number and the load lands
(`MLXAdmissionLiveTests.admissionOnThisMacAdmitsAndLoads`, 64 GB asked,
admitted). The one line that carries the app's number to the gate was
proven on the same Mac with a scripted headroom of 1 byte: the real door
refuses `needing: 2` with `.notEnoughMemory(needed: 2, available: 1)` and
never begins the load, then admits the same call once the headroom stops
giving a number (`theMindsOwnDoorRefusesOnAKnownShortfall`). The phone's
own row — a real short headroom on a real 4B load — is not in this repo.

**The one untyped throw that remains (§190a F-6, ruled A — D-108).**
The two refusals above are typed: `ReplyFailure.unavailable(_)` carrying
the readiness verdict or `.notEnoughMemory`. One more error can leave
this door today, and it is NOT on the reply seam: a `.critical` that
lands DURING this call's own load retires the weights (AC-262), and the
holder then throws `Retirable.Failure.retiredDuringLoad` — the same word
the load door has spoken for that case since 4j. The retire is right.
F-6, raised by the build, was ruled **A** in D-108: the door is to
speak it as a typed verdict, `ReplyFailure.unavailable(.retiredDuringLoad)`,
a new `MindUnavailable` case beside `.notEnoughMemory` — because it is
a memory event, and `.engine(_)` is the bucket for the VENDOR's errors,
not the library's own. The reply door does not change: there a
`.critical` during the load ends the run SILENTLY — `pressure(_:)`
abandons the live runs before it retires the weights, so the run is
already retired when the holder throws and nothing it would say is
heard (AC-262's own row asserts no terminal for a `.critical`
mid-generation; the during-a-load case follows from the order, since a
run joins the registry in its init, before its load — no row drives
one through the reply door's load). A stream may end in silence;
`admit()` must throw a word. (D-108 first
ruled B — map to `.engine(_)` — on the claim that the reply door
"already speaks" that word for this event; the facts lens read the code
and the claim was false; the ruling was corrected before commit and the
correction is recorded in D-108.) The case, the catch and one row that
scripts a `.critical` through `admit`'s own load are **owed under
AC-268**; none is built yet. Until then no test drives a `.critical`
through `admit`'s own load; the path is argued from `Retirable`'s own
row (`RetirableTests`) and the pressure step's `retire()`.

### Heat

**The policy is asked BEFORE the readiness verdict.** Both real doors
read the thermometer once and ask the injected policy with that reading,
then ask readiness (`MLXReplyGenerator.openReply`,
`AppleReplyGenerator.openReply`). A phone too hot to generate is told so
whatever is installed; a refusal is `ReplyFailure.tooHot(state)`, thrown
at the door, so no run exists and nothing was said. The state rides on
the case so a counting caller sees WHERE an app's stricter policy
refused. The order is a test on each mind: on a `.critical` thermometer
a door that would ALSO refuse for readiness hears `.tooHot`, not
`.unavailable` — the MLX row scripts absent weights
(`MLXThermalDoorTests.heatSpeaksBeforeReadiness`, `.weightsAbsent`), the
Apple row scripts a vendor still downloading
(`AppleHeatTests.heatBeforeTheVerdict`, `.modelDownloading`), and both
check that the cooler door then speaks the verdict; the thermometer is read at every
door, never cached, so a phone that cools between two turns is admitted
on the second (`theThermometerIsReadEveryTime`); and three doors on a
`.critical` thermometer are three equal `.tooHot(.critical)` values
(`theRefusalIsCountable`, `readOnceAndCountable` — the Apple row also
counts the reads: one per door).

**The default refuses at `.critical` only (F-2 = A).**

```
 DefaultGenerationThermalPolicy        thermal < .critical
   .nominal   generate
   .fair      generate
   .serious   generate     ◄── the measured phone LIVES here
   .critical  refuse       ──► .tooHot(.critical)
```

Why `.serious` generates. On the phone, thermal went `nominal` at 73 s
to `serious` by 128 s. It never recovered in a 1132-second session:
seventeen of nineteen minutes at `serious`. The numbers are in
INSTRUMENTS §40, the AC-140 row — open §40. (SPEC §186 and D-107 write
"§26" for the same fact; §26 is a different section, the 0 Hz crash.
The cite there is wrong; the fact is not.) The field sessions since
that recorded heat read `serious` too — from turn 5 in §60, throughout
in §61, §63 and §67. A default that refused at `.serious` would refuse
the product. D-107 lists
the rejected options: refuse at `.serious` (safer for the battery,
unusable on the measured phone) and never refuse (what the library did
before 4y). The table is pinned state by state on the policy alone, on
the MLX door and on the Apple door
(`AdmissionSeamTests.defaultPolicyRefusesOnlyAtCritical`,
`MLXThermalDoorTests.theDefaultPolicyStateByState`,
`AppleHeatTests.defaultRefusesAtCriticalOnly`), and the public
constructors are checked to default to the real thermometer and this
policy (`thePublicDefaultsAreTheSystemsAndTheShipped`, `publicDefaults`).

**A stricter policy is one struct.** The seam is
`GenerationThermalPolicy` in `Diagnostics/ThermalPolicy.swift`: one
method, `allowGeneration(thermal:) -> Bool`. An app that wants the
rejected default B injects it at the mind's construction, the way tools
are injected — never through the coordinator (AC-265):

```swift
struct RefuseAtSerious: GenerationThermalPolicy {
    func allowGeneration(thermal: ThermalState) -> Bool { thermal < .serious }
}
let mind = MLXReplyGenerator(model: model, thermalPolicy: RefuseAtSerious())
```

The injected policy is the one asked, and its refusal names ITS state —
`.tooHot(.serious)` (`anInjectedPolicyIsObeyed`, `injectedPolicyIsAsked`,
`injectedPolicyOverrulesTheDefault`).

**This is D-028's one question, asked at a second moment.** D-028 ruled
`ThermalPolicy` as a seam consulted at exactly one moment — whether an
optional settling decode may start — governing TRANSCRIPTION only, with
a default that refuses from `.serious` up. 4y does not touch that
protocol or that default. It adds a SEPARATE protocol with a SEPARATE
default, because the two moments price different work: a settling decode
is optional comfort, a reply is the turn. The two tables are pinned side
by side so the day someone "unifies" them the test says which ruling they
broke (`AdmissionSeamTests.transcriptionPolicyIsUntouched`). D-028's
boundary holds on this side too: the policy is never consulted for a
reply already running.

**What the coordinator sees: nothing.** It passes a default
`GenerationOptions()` and names no thermometer, no policy and no
deadline. Proven on the record of every driven call and by a scan of the
coordinator's own source (`AdmissionCoordinatorTests`, the two AC-265
rows). A refused door on the voice path is an honest failed turn — the
failure event carries `tooHot`'s own words, the next turn runs clean,
and the memory is not poisoned (`heatRefusalFailsOnlyTheTurn`).

**The mouth has no thermal policy.** Nothing in the TTS path reads
thermal state. That is 4e's open item, named in SPEC §188 as a non-goal
of this milestone, and it is still open.

### Pressure

**Which object listens: the MODEL, not the mind.** `LocalMindModel` —
the actor that holds the weights and the registry of live runs —
subscribes to memory pressure ONCE, in its `init`, for its whole life
(`watchPressure`, `LocalMind.swift`). `MLXReplyGenerator`, the mind,
subscribes to nothing; it only opens runs on the model. So the object a
caller must keep alive for pressure to be acted on is the model — the
mind holds it, and a model with no owner cancels its subscription in
`deinit`. Not from load to retire, because a retire is not the end of
the model (R4: the next `openReply` reloads), and a subscription tied
to residency would miss a `.critical` that lands between. The seam
is `MemoryPressureSourcing` in `MindPressure.swift`; the real source
wraps `MemoryPressureMonitor`, the kernel's dispatch source; a test's
source pushes levels by hand. Three levels: `.normal`, `.warning`,
`.critical`.

```
 the kernel's queue                      the model's actor — LocalMind+Admission.swift, one step;
 ──────────────────                      the only await is the retire at .critical
                                         ────────────────────────────────────────────────────────
 onChange(level) {                       pressure(level)
   Task { await self?.pressure(level) }    .normal   ──► nothing: the pressure LIFTED
 }                                         .warning  ──► liveRuns.abandonAll()   every live run's
   ▲ the HANDLER: one hop,                               ticket raised, stream finished, NO terminal
     nothing else                                       freePrefill()           MLX.Memory.clearCache()
                                           .critical ──► the same, then retire(): the weights go
```

**What `.warning` does (F-3 = A).** Every run alive on these weights is
ended the way a barge ends one: through the run's own `retired` latch,
raised in the same locked step that finishes the stream
(`MLXReplyRun.abandon()` — the body `cancel()` also runs). Every token
is admitted under that same lock (`guard !guarded.retired`), so once the
latch is up no later token can reach a listener. Be exact about WHEN
the latch goes up: not in the kernel's callback, but one hop later, on
the model actor's step — "What that shape costs" below says what can
happen in between. The stream carries the tokens already spoken and
then simply ENDS — no terminal. The generation's task is then cancelled
as the optimisation, the source's end path awaits the vendor's task,
and the prefill is freed. The weights STAY resident, and the next turn
runs clean. Proven with a scripted source: the two tokens already
spoken, then the end, no terminal, the generation cancelled, the
registry empty, zero retirements
(`MLXPressureTests.aWarningEndsTheRunWithNoTerminal`; its source stops
on cancellation, so this row does not test a defiant token). The
after-the-latch defiance is proven on the same `abandon()` through the
cancel seam: a source that yields a token AFTER the cut, and a listener
that never hears it
(`MLXReplyConformanceTests.nothingAfterTheCancelSurvives`, promise 3,
`gatedDefiance`). A run opened after the warning runs untouched
(`theNextTurnRunsClean`); every live run ends, not only the latest
(`aWarningEndsEveryLiveRun`); `.normal` ends nothing
(`normalDoesNothing`). D-107 records the rejected option: let it
finish, then release — a warning is a warning, and the finish may be
the kill.

**What the two callers of this page SEE — read from the code.** This
section's own persona is a whole-reply caller with a spinner, and for
them a warning is not the quiet ending above:

```
 how the reply is read        what a .warning mid-reply looks like        proven by
 ─────────────────────        ───────────────────────────────────        ─────────
 openReply, the stream        tokens so far, then the stream ENDS,       MLXPressureTests
                              no terminal                                 (scripted source)
 reply(to:), whole reply      THROWS ReplyFailure.engine(                 ReplyContractTests
                                "the reply ended without a terminal");     .noTerminalIsAnEngineFailure
                              the partial text is GONE                    (a scripted silent mind — no row
                                                                           drives a real warning through it)
 the voice path               the tokens already said are spoken; then    NO row. Read from
  (the coordinator)           NOTHING arrives — no .finished, no .failed:  TurnCoordinator+Stages.swift
                              the turn is neither completed nor failed     (`handleReply`) and
                              by the library                               +Transcripts.swift
```

`reply(to:)` drains a stream and treats "ended with no terminal and no
cancel of my own" as a broken seam: it throws
`ReplyFailure.engine("the reply ended without a terminal")` — a thrown
`ReplyFailure`, not a `.failed` update (`ReplyContract.swift`,
`drainWholeReply`). Under a warning that is what the spinner caller
gets: an engine failure, and the words already generated thrown away
with it. A caller that wants to tell a warning from a broken engine, or
keep the partial text, reads the stream.

On the voice path, argued from the code and proven by no row: the
coordinator forwards the run's updates one by one and acts on `.token`,
`.finished` and `.failed` (`handleReply`); a stream that just ends
delivers none of those, and the forwarding task returns silently. The
tokens already spoken were fed to the mouth, which speaks each phrase
as it completes; the mouth is never told the tokens are finished, so a
half-built last phrase is never flushed (`AppleSpeechSynthesizer`,
`feed` and `finishTokens`); the turn stays where it was until the next
barge or `stop()`. Nothing publishes `turnFailed` or `turnCompleted`
for it. What the person hears is the completed phrases up to the cut,
then silence — and the library has no test that says so. This is listed
under "What this does NOT do".

**What `.critical` adds.** The same cut, then `retire()`: the weights are
released, and the next `openReply` reloads them through the same door as
the first — R4's non-terminal shape (AC-262). Scripted: no terminal, one
retirement, not resident, and the door opens again
(`aCriticalRetiresTheWeights`); a `.critical` with nothing running still
retires, because the weights, not the run, are the target
(`aCriticalWithNoRunStillRetires`). Live, on the Mac: the reload answers
(`MLXAdmissionLiveTests.aCriticalRetiresAndTheNextReplyReloads`, and the
last two rows of §68's table). **That reload asks no memory question.**
It goes through the plain load door, on a phone that just ran out of
memory. A caller that wants the gate again calls `admit(needing:)`
before the next `openReply` — "Admission is optional — and it is not
remembered", above.

**The handler does no work (AC-263).** The kernel calls it on a dispatch
queue, synchronously, while it is already short of memory. The handler's
whole job is to get OFF that queue: one `Task` hop to the actor, and the
actor does everything above on its own step. A counting allocator is out
of reach, so this is enforced the way 4x's suspend test works — by
reading the code. `MLXPressureHandlerScanTests` opens `LocalMind.swift`,
cuts the text between `// pressure-handler: begin` and
`// pressure-handler: end`, and asserts it contains the hop
`Task { await self?.pressure(level) }` exactly once, that what is left
around it — whitespace collapsed — IS the subscribe wrapper and nothing
else, that none of `await`, `MLX.`, `clearCache`, `retire`, `abandon`,
`freePrefill`, `Memory`, `withLock`, `DispatchQueue`, `sleep` appears
outside the hop, and that `[weak self]` is there so the source cannot
keep a model alive. A second row proves the model is the only subscriber
in the module, so the scan covers every subscription there is.

**What that shape costs, stated.** The runs' tickets are raised one
scheduler hop later, on the actor's step — not in the handler itself.
Between the kernel's callback and that step the vendor may produce a
token and a listener may hear it. So the two sentences on this page
fit together like this: BEFORE the actor's step, a token may pass;
AFTER it, none can. "After the warning" in the paragraph above means
after that step, not after the kernel spoke. The source says so
(`LocalMind.swift`, `watchPressure`) and names the alternative — raising
every latch synchronously in the handler — as a fork, not a fix, because
it would finish streams and run their termination handlers on the
kernel's queue.

**The registry.** `LiveRunRegistry` holds every `MLXReplyRun` alive on
one model's weights, WEAKLY: a run registers itself synchronously at
birth, before its worker exists, and removes itself on every terminal
path. Weak, so a run its owner dropped mid-round is not kept alive by
the table that exists to kill it. `abandonAll()` snapshots the table
under its lock and ends each run OUTSIDE it (lock rule 2 — a stream's
termination handler is somebody else's code). A run that finished on its
own is gone from the table and a later warning finds nothing
(`aFinishedRunIsNotInTheRegistry`). And the subscription lives exactly
as long as the model: one subscribe at birth, one cancel at `deinit`
(`theSubscriptionLivesAsLongAsTheModel` counts both — subscriptions 1,
cancellations 1). The same row pushes a `.critical` after the model is
gone and asserts only that the push does not crash; that nothing acts
on it is argued from the `[weak self]` in the handler, which the scan
row checks for, not from an assertion about where the level went.

**The door does not read pressure (§190a F-5, ruled B — D-108).** SPEC
§187/1 said `admit()` reads "headroom and pressure". What shipped reads
headroom only: no acceptance criterion names a pressure verdict at the
door, and `MindUnavailable` has no case for one. So a phone already at
`.warning` is admitted, loads 2.3 GB, and is then cut by the same
warning a moment later (the fork's framing; the source delivers
transitions, so the cut is the NEXT one — D-108) — correct under F-3,
but a load that was never going to survive. F-5, raised by the build,
was ruled **B** in D-108 —
what ships stays: the gate's number is the app's own against the
kernel's per-process headroom, the number that decides jetsam, while
pressure is system-wide and momentary and already acts where it bites
(a `.warning` cuts the generation, a `.critical` retires the weights —
even one that lands during a load, so a load begun under pressure ends
under the same net as any other). The rejected option and its cost are
in §190a and D-108; the source cites the ruling
(`LocalMind+Admission.swift`, "PRESSURE IS NOT READ HERE").

### The deadline

**An ending, never a failure (F-4 = A).** `GenerationOptions.deadline:
Duration?` sits beside `maxTokens`. `nil` is no deadline — the voice
path's setting, which the coordinator never changes (AC-265). A reply
that runs past it ENDS `.finished(.deadline)` with what was said so far.
D-107 gives the reason and the rejected option: `.failed(.deadline)`
would throw away words the person may already have heard, and D-104
already ruled that how a reply ENDS is not a failure — a refusal became
a stop reason for the same reason. `.deadline` is `.tokenBudget`'s
sibling: one budget is counted in tokens, this one in time, and both are
endings a caller reads and shows.

```
 MLX  (MLXReplyGenerator.swift)                 Apple  (AppleReplyGenerator.swift)
 ─────────────────────────────                 ───────────────────────────────────
 a task group: the rounds vs the clock         the worker, and a sleeper task armed
   child 1  rounds(): tokens, terminal           AFTER the worker is stored
   child 2  clock.sleep(for: deadline)         sleeper wakes ──► expire(): raise the
            wakes ──► deadlineFired():           flag under the lock, cancel the
            raise the flag under the lock        worker. Nothing yielded here.
   group.next(); group.cancelAll()             worker's stream hands back nil ──►
   ── the loser is cancelled by structure        concludeStream(): take the latch,
 ONE WRITER: the rounds task speaks              read the flag in the SAME step,
   .finished(.deadline) itself, after            speak .finished(.deadline) — or
   its own loop has ended                        .unreported when the flag is down
                                               ONE WRITER: the worker, always
```

**One writer for the stream, so no token follows the terminal.** Both
minds learned this the same way. The first cut let the clock's task
yield the terminal itself, concurrently with the token loop — and a
token whose latch check had already passed landed AFTER
`.finished(.deadline)`: 2 of 400 in the review's hammer on the MLX mind,
once in twenty rounds on the Apple mind with the cancel removed.
Cancellation is a request, not a kill (§4.1), so the cancel cannot close
that window; only one emitter can. Now the sleeper raises a flag under
the lock and the task that
yields the tokens yields the terminal, in its own program order, after
its loop. Past the flag no token is admitted either — "what was said so
far" is literal, the text BEFORE the clock fired. The hammer is a test:
four hundred 1 ms deadlines against a firehose of twenty thousand
tokens, and the terminal is exactly one and last on every run
(`MLXDeadlineTests.aTokenIsNeverSpokenAfterTheDeadlineTerminal`); a
token the source defiantly yields after the deadline is never heard
(`aTokenAfterTheDeadlineIsNotHeard`); and on the Apple mind the deadline
and the last snapshot fired at once, twenty rounds, report exactly one
terminal — whichever won (`AppleDeadlineTests.deadlineAndFinishAtOnceReportOneTerminal`).

**The sleeper is cancelled when the run ends first.** A reply that ends
before its deadline leaves NO sleeper on the clock: on the MLX mind the
task group cancels the loser by structure; on the Apple mind the terminal
path takes the latch and hands the sleeper OUT in the same lock step,
then cancels it outside the lock (rule 2: nothing is resumed while the
lock is held — `concludeStream`), and a sleeper stored into an
already-ended run is cancelled on the spot. A
cancelled sleep ends nothing — the clock was stopped, not reached
(`aReplyThatEndsFirstLeavesNoSleeper`, `aCancelBeforeTheDeadlineLeavesNothing`,
and the Apple rows "a source that finishes first … releases the
sleeper" and "cancel() ends with no terminal and releases the sleeper").
With no deadline nothing sleeps on the clock at all — the run adds
nothing to what ran before 4y (`noDeadlineArmsNothing`, AC-265's half).
Every SCRIPTED row measures the deadline on a `ManualClock`: 199 ms is
not the deadline, 200 ms is, and nothing waits on wall time
(`aSlowReplyEndsOnTheDeadlineWithItsPartialText`). Two rows are the
exception, on purpose: the live rows
(`MLXAdmissionLiveTests.aRealReplyEndsOnTheDeadlineAndFreesItsPrefill`,
`AppleDeadlineLiveTests`) build the mind on its default
`ContinuousClock` and give it a real 200 ms, because they measure a real
model — they are gated, and they skip in CI.

**On the public seam** `reply(to:)` returns `Reply(text: "two tokens",
stop: .deadline)` (`replyReturnsTheStopReason`), and on the voice path a
reply the clock cut is spoken as far as it got and the turn COMPLETES —
the same events, in the same order, as a reply the token cap cut
(`AdmissionCoordinatorTests.deadlineEndingCompletesTheTurn`; the ending is
scripted there, since the coordinator passes no deadline).

**What each mind can free.** The MLX mind owns its cache: the deadline's
cancellation is the same one a barge uses, the source awaits the
vendor's task, and clears the pool — the memory row is in "What is
measured", and a real 0.6B reply cut at 200 ms ends `.finished(.deadline)`
with text already said — 13 tokens in §68's run
(`aRealReplyEndsOnTheDeadlineAndFreesItsPrefill` asserts the ending and
that the text is not empty, not the count). The Apple mind cannot: the
vendor's session manages its own memory behind `LanguageModelSession`,
and this library holds no allocation to admit and no cache to free. What
it can do is cancel the stream task, which reaches the session through
the stream's termination — and that is the whole of the release. Its
live deadline row exists and is honest about its own skip: on the Mac it
was written on the model reported `modelNotReady`, so it ran no reply
(`AppleDeadlineLiveTests`). Nothing here claims what the Apple mind's
cancel frees.

### What is measured

INSTRUMENTS §68 is the whole table. Ryad's Mac, 2026-09-12, the 0.6B
model; every row is `MLXRuntime.activeMemoryBytes` read three times.
The floor is the resident weights, 320 MB:

| what cut the generation | before | peak during | after | cache after |
|---|---|---|---|---|
| a deadline at 200 ms, 13 tokens out | 320 MB | 415 MB | **320 MB** | 0 MB |
| a memory warning after 3 tokens | 320 MB | 411 MB | **320 MB** | 0 MB |
| a run cancelled BEFORE its first token — before the fix | 320 MB | **413 MB** | 320 MB | |
| the same run — after the fix | 320 MB | **0 MB** | 320 MB | |
| a critical warning, then idle | 320 MB | | **0 MB** | |
| …then the next reply reloads | 0 MB | | 320 MB, and it answers | |

The rows are `MLXAdmissionLiveTests`, gated on `MMK_MLX_MODEL` and on a
metallib; CI prints a loud SKIPPED. Two things about how they are read.
The claim is about `before`, not `peak`: `after < peak` cannot fail when
the release is removed, because the temporaries free regardless — the
review's mutation left the KV cache resident and such a row still
passed. So the assertion is `after <= before + 1 MB`, and green runs
measure `after == before` to 0.1 MB. And the "after" is read only once
`waitForIdle()` says no generation is in flight — the vendor's task, and
the KV cache it owns, must be GONE before the number is honest.

**The phone rows are owed.** The 4B's numbers for the same three cuts,
and the thermal curve with the mind generating every turn, are AC-266's
second half and Ryad's gate; neither is in this repo. Every number above
scales up on the phone — the SHAPE is the finding.

**The dead-run finding, in one paragraph.** A run cut before its first
token — a warning during the load, an early barge, an early deadline —
still paid the whole prompt prefill: 413 MB peak for a run that should
have done nothing (the source comment records 866 MB over the floor for
the same defect on a long prompt; the §68 row measured 413 MB), and it
held the container's serial lock the whole way, so the next reply queued
behind a dead one. Two cancellation checks now
stand between the load door and the vendor's loop, drawn in the picture
above. Peak after the fix: 0 MB. The live row is deterministic by
construction — it holds the vendor's own lock before the reply is opened,
cancels the run, and only then lets the generation reach the vendor
(`aRunCancelledAtBirthNeverPrefills`). **The pair is proven; each half
alone is not.** The row goes red only when BOTH checks are removed;
either one alone keeps it green. With the second removed, the first
catches the run before the lock. With the first removed, the run parks
on the lock the row is holding, enters when the row lets go, and the
second catches it there. The second check — the last look
before the prefill, for a run cut while PARKED on the lock — is justified
by reading the vendor's `AsyncMutex`, not by a row: there is no hook for
"parked on the lock" to build one from. The source says exactly that
(`LocalMind.swift`, `stream`), and §68 repeats it.

**What frees the prefill, exactly** — because "freed" is a claim.
The KV cache is owned by the vendor's `TokenIterator`, a local of the
vendor's generation task. Cancelling without awaiting frees nothing.
`VendorLoop.drain` cancels that task when the loop was cut and AWAITS
it either way, so "the cache is gone" is true when it returns; then
`MLX.Memory.clearCache()` empties the vendor's buffer pool, which the
allocator otherwise keeps up to `cacheLimitBytes`. The cut-both-ways
rule is its own test with a scripted producer (`MLXVendorLoopTests`),
because a consumer that leaves the loop with `break` never terminates
the stream, and on that path the vendor ran to `maxTokens`.

### What this does NOT do

SPEC §188's non-goals, plainly, plus what this milestone owes:

- **No memory claim inferred from a file size.** D-105 stands. Admission
  compares the app's own number to the phone's own headroom, and a mind
  that is asked nothing (`needing: 0`, or a plain `openReply`) is refused
  nothing.
- **No thermal policy for the mouth.** Nothing in the TTS path reads
  thermal state — 4e's open item, still open.
- **No background execution, and no scene-phase hook beyond
  `retire()`.** R5 is documented already; the library does nothing when
  the app goes to the background.
- **No change to the text contract's shape beyond one optional field.**
  §188 names the field, `deadline`; the ACs name the two cases that
  carry it and the heat refusal — `.deadline` on `StopReason`, `.tooHot`
  on `ReplyFailure`. `StopReason` has five cases now and `ReplyFailure`
  six; `.refused` is still not a failure (`AdmissionSeamTests`, the two
  enum rows).
- **No Aura-side code.**
- **The door does not read pressure** — by ruling, not by omission:
  §190a F-5 = B, D-108, above.
- **One throw off the seam, still** — §190a F-6 = A, D-108: the typed
  verdict `.unavailable(.retiredDuringLoad)`, its catch and its row are
  owed under AC-268 and are not built yet, above.
- **Admission is not remembered across a `.critical`.** The reload
  after a critical asks no memory question; the caller calls
  `admit(needing:)` again, or takes the pre-4y race for that one load.
- **A whole-reply caller cannot tell a memory warning from a broken
  engine, and loses the partial text.** `reply(to:)` throws
  `ReplyFailure.engine("the reply ended without a terminal")` for both.
  Open; the stream reader is the way around it today.
- **The voice path under a memory warning is argued from the code, not
  tested.** The phrases already spoken, then silence, and no turn event
  — no row says so ("What the two callers of this page SEE").
- **The phone is not measured here.** §68's phone rows and the thermal
  curve with the mind generating are owed (AC-266's second half).

## The tool contract (4z)

The section above is how the mind runs SAFELY. This one is how the mind
DOES something: it calls a verb the app hands it, with the numbers the
person said, and the app's code runs. It is written for the caller that
declares nine verbs with one number each and wants to know exactly what
reaches its code (SPEC §192–197, D-110; the diet app's requirement,
`4z-tool-contract.md`, and Aura's §168a before it).

**The short codes.** `AC-nnn` is a criterion in `SPEC.md`; `F-n` is a
fork of milestone 4z ruled in **D-110** — F-1 A (typed arguments),
F-2 A (tools per call), F-3 A (a `String` result, capped), F-4 B (a
thrown tool answered in words), F-5 A (a body runs to its end under a
barge), F-6 A (the demo's timer), F-7 C (extras stripped and counted),
F-8 C (lenient kinds, counted at the door), F-9 A (the deadline waits
for a body), F-10 B-ii (a confirmation flag the run enforces), F-11 B (a
band shown and checked as two switches), F-12 B (no app codename here),
F-13 a–k (the small rulings). A *verb* is a tool the app owns; the
*door* is the one function every call passes through; a *round* is one
trip model → tool → model.

### The life of one call

```
 the app declares                    the model                      the LIBRARY
 ────────────────                    ─────────                      ───────────
 ReplyTool(                                                         SHOWN to the model, per mind:
   name: "log_reading",                                              MLX   <tools> JSON: properties,
   description: "…",                                                       required, a band if shown
   parameters: [kg: number,                                          Apple GenerationSchema built at
      required, band 20…400,                                               run time from the same list
      showsRange: false],
   requiresConfirmation: false,      writes a call ──────────────►  THE DOOR  ToolTable.invoke
   body: { args in … })                {"kg": "83.5",                1 strip   undeclared names dropped, COUNTED   F-7 C
                                        "mood": "fine"}              2 check   missing / null / wrong kind → REFUSED,
 GenerationOptions(                                                            told in words; "83.5" → 83.5 COUNTED   F-8 C
   tools: table,          ◄── per call, or nil = the mind's own      3 band    20…400? out → REFUSED, counted      F-11 B
   confirmedTools: ["…"])                                            4 flag    needs a yes and none on this call →
                                                                               body NOT run, model told to ask   F-10 B-ii
                                                                     5 shield  the BODY runs in its own awaited task:
                                                                               a barge cannot reach inside it       F-5 A
                                                                     6 cap     4,000 chars, cut marked, COUNTED    F-3/F-13 f
                                                                     7 words   the sentence the model reads, either way
                                     reads the words ◄──────────────  (MLX: the template's closing tag escaped here)
                                     and speaks
```

The one sentence to keep: **the library owns the door; the app owns the
verbs.** No verb, no kilogram, no notion of a meal lives in the library —
`kg` and `log_reading` appear in this repo only as test examples and in
one comment that tells the story of the bug F-5 answers.

### The shortest code that works

```swift
let logReading = ReplyTool(
    name: "log_reading",
    description: "Record a body reading the person gives, in kilograms.",
    parameters: [ToolParameter(name: "kg", description: "the reading in kilograms",
                               kind: .number, isRequired: true,
                               range: 20...400, showsRange: false)],
    requiresConfirmation: false) { arguments in
        let kg = try arguments.number("kg")        // a number, never text (F-1 A, F-8 C)
        await store.record(kg)                     // runs to its end even under a barge (F-5 A)
        return "Recorded \(kg) kg."                 // back to the model, verbatim, capped (F-3 A)
    }

// The table rides on the CALL (F-2 A). nil = the generator's own table;
// .empty = no tools this turn (the plain path, byte-identical to 4v).
let reply = try await mind.reply(to: ReplyContext(
    transcript: "log eighty-three and a half",
    options: GenerationOptions(tools: ToolTable([logReading]))))
```

Two more lines when a verb needs a yes: declare it
`requiresConfirmation: true`, and when the person has said yes, put the
tool's NAME on the next call — `GenerationOptions(tools: table,
confirmedTools: ["log_reading"])`. The model cannot confirm itself: a
`confirmed: true` it writes into the arguments changes nothing. **The
known hole, ruled and recorded (D-110 F-10 B-ii):** the yes binds to the
name, so the model's next call of that tool runs with whatever number
it writes; re-check the number in the verb after a yes, or wait for the
delta that binds name plus arguments (B-iv on the page).

### What each mind shows the model, and how the answer comes back

| | MLX mind | Apple mind |
|---|---|---|
| the schema | the `<tools>` JSON block: one property per parameter with its type and sentence, `required`, `minimum`/`maximum` when `showsRange` (AC-271) | a `GenerationSchema` built at run time from the same list — `DynamicGenerationSchema`, a range guide when shown (AC-270) |
| no parameters | 4w's bytes, unchanged (the fixture) | the spike's `@Generable` empty schema, unchanged |
| the answer | the vendor's `.toolCall` JSON parsed by KIND into `ToolValue` — one number case (F-13 b); a list or object is refused for a scalar (F-13 i) | the vendor's `GeneratedContent`, read by kind into the same `ToolValue` |
| the table per call | `options.tools ?? own` (AC-275) | the same rule; a session is born per reply with exactly that list |
| a thrown body | the door's sentence goes back to the model; `.finished` | the adapter returns the door's sentence — never throws (F-4 B, AC-276) |
| the closing tag | `</tool_response>` inside a result is escaped at the MLX seam, before `.tool(answer)` (F-13 f) | not a template mind; untouched |
| a bad table (two parameters, one name) | `init` throws `ToolDeclarationError`; `openReply` throws `.engine(words)` before any run (AC-289) | the same two doors; the vendor's `duplicateProperty` stays as the second line |

Neither mind judges an argument. The door does, once, the same way.

### The proofs, one line each

- **A barge does not un-write** (F-5 A, AC-277): a cooperative tool that
  looks at the cancellation flag before it commits used to skip its
  write on a barge — the bug that bit first. Now the body runs in an
  awaited task of its own; the test was commit one of the milestone,
  red (`writes == 1 → 0`), then green.
- **The deadline waits for a body** (F-9 A, AC-278): the rounds task
  awaits the door, then speaks `.finished(.deadline)` in its own program
  order — one write, one terminal, last. The opposite design is
  convicted by a kept mutation log.
- **The plain path is unchanged** (AC-272): the prepared prompt for a
  question with no tools was captured with the 0.6B before the first MLX
  change and after — byte-identical (23 tokens, 138 bytes), both files
  kept.
- **A number arrives as a number** (AC-269): the 0.6B, asked by name,
  called `log_reading` and the body's typed accessor read `83.5`. The
  Apple mind's row is written and skips on this Mac (model not ready);
  the phone is its gate.

### What it costs, measured (INSTRUMENTS §69)

On the 4B — the phone's model — an idle tool with no parameters costs
**+419 ms** on the first token of every turn (4w's number, reproduced
byte for byte); the parameters add **0.74 ms per spec character** on top
(three verbs: +955 ms in all). One tool round is **≈2.65 s** on the 4B,
≈460 ms on the 0.6B — the second prefill costs as much as the first.
Arguments: the 4B got 18 of 20 scripted sentences right and invented
nothing in 16 trap rows; the 0.6B got 11 and invented in every trap row,
optional `kg` or not — and with the band SHOWN it invented `kg: 20`, the
band's own edge, which no door can catch. That is why `showsRange` is a
separate switch, and why the demo keeps it off.

### What this does NOT do

- **No verb, no policy, no undo.** The library confirms nothing on its
  own and refuses nothing on its own; the flag and the band are bits the
  app declares.
- **No provenance.** The door checks presence, kind and band; whether
  the person actually SAID the number is the app's to confirm — the 0.6B
  writes a plausible 83 that no band catches.
- **No nested parameters** (§194): a list or an object for a scalar is
  refused; a tool that wants one waits for a later milestone.
- **The yes is bound to a name, not to the arguments** (F-10 B-ii) —
  the recorded hole, and B-iv the delta that closes it.
- **The Apple mind's live rows skip on this Mac** (model not ready);
  the phone is their gate, as it is for the demo's per-turn line.
- **One tool per round on the demo; four rounds on the MLX mind** — the
  cap stands (F-13 h), priced in §69.

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
 ThermalPolicy (85)        D-028: one question at one moment — may this
                           settling decode keep its ticket? The shipped
                           default is dormant below .serious. It governs
                           transcription only. 4y added a SECOND moment
                           beside it, GenerationThermalPolicy — may a
                           reply be generated? — whose default refuses at
                           .critical only. NOTE: nothing in the TTS path
                           reads thermal state (4e, open).
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
| The front door — assembly and teardown ORDER, owned once | `Runtime/AIRuntime.swift` |
| The conversation before this thought — bounded, role-tagged (4r) | `Conversation/ConversationMemory.swift` |
| What the mind is handed: this thought plus the past | `Conversation/TurnCoordination.swift` — `ReplyContext` |
| The neural mouths behind one seam (4q) | `MultiModalKitTTS/Voice/SpokenVoice.swift`, `KokoroVoice.swift` |
| The mind's TEXT contract — options, stop reasons, failures (4v) | `Conversation/ReplyContract.swift` |
| Can this mind run here? — the pure verdict over a device report | `Conversation/MindReadiness.swift` |
| The install, size-checked; the manifest and byte progress | `MultiModalKitMLX/LocalMindInstall.swift` |
| What an install will COST, asked before a byte moves (4x) | `MultiModalKitMLX/LocalMindInstallSize.swift` |
| The install seam a caller can fake, and the typed install failure (4x) | `MultiModalKitMLX/WeightsFetching.swift` |
| Which hosts this library can contact, and what a request carries (4x) | `docs/HOSTS.md` |
| ONE admission call — the gate, the app's number, and the pressure step (4y) | `MultiModalKitMLX/LocalMind+Admission.swift` |
| The tool contract's types and THE DOOR — strip, check, band, flag, shield, cap (4z) | `Conversation/ReplyTool.swift` |
| What the MLX mind SHOWS the model, and how its call is parsed by kind (4z) | `MultiModalKitMLX/MLXTools.swift` |
| The Apple mind's tool adapter — the schema built at run time, the answer read by kind (4z) | `Conversation/AppleReplyGenerator+Tools.swift` |
| The headroom hand, the pressure seam, and the runs a warning must reach (4y) | `MultiModalKitMLX/MindPressure.swift` |
| The two cancellation checks before the prefill; what frees the KV cache (4y) | `MultiModalKitMLX/LocalMind.swift` — `generate`, `stream`; `VendorLoop.swift` |
| Heat at the door — the second moment, and its `.critical`-only default (4y) | `Diagnostics/ThermalPolicy.swift` — `GenerationThermalPolicy` |
| The deadline — one writer for the stream, the sleeper cancelled with the race (4y) | `MultiModalKitMLX/MLXReplyGenerator.swift`, `Conversation/AppleReplyGenerator.swift` |
| What the doors refuse, as an error rather than a trap (AC-241) | `Runtime/AIRuntime.swift`, `Conversation/TurnCoordinator+Config.swift` |
| The pipeline wired for real — through the door | `Demo/TranscribeDemo/Sources/Model/TranscribeModel+Pipeline.swift`, `Sources/AudioDemo/AudioDemo.swift` |

## The shape in numbers — generated, never typed

This paragraph was wrong **four times**, twice inside its own correction —
a number a human maintains in prose drifts, which is what D-054 rule 5 is
about. So the numbers are now the OUTPUT of `Scripts/shape.sh`, pasted
with the commit they were taken at, and the script is the authority: run
it, and if it disagrees with this page, the page is stale and the script
is right.

```
$ Scripts/shape.sh
commit          7a4f10e
library core    8278 lines   Sources/MultiModalKit
all sources     22039 lines   every product, demo and instrument under Sources/
demo app        6092 lines   Demo/
tests           23532 lines   Tests/
TurnCoordinator 1028 lines across 5 files
runner          Test run with 855 tests in 119 suites
```

More test than library, which is the point. The test folder mirrors this
map roughly one suite per box; every suite is deterministic (injected
clocks, no sleeps, event-gated) and the whole thing runs 20× before any
milestone closes. The suites that touch real speakers or real models are
gated (`MMK_LIVE_SYNTH=1`, model-installed checks) and skip honestly — and
since D-091 the two OS-26 suites are gated at runtime, so on a host older
than 26 they report PASS having proven nothing. CI needs a 26 host.

If a box on this map ever stops being explainable in one sitting, that
is a design smell, not a documentation problem — see the deep-module
rule in DECISIONS.md.
