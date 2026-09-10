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
It is written for the caller that has to ask a person for 2.2 GB of
their data allowance, and be honest about what that costs and what
leaves the device.

**The short codes are the same ones**, with one change: `F-n = A` here
names a fork of milestone **4x** and the option Ryad chose on it
(D-106), not 4v's.

### The life of an install

```
 ASKING COSTS NOTHING                    expectedInstall()  ── a NETWORK call
 ┌──────────────────────────────────────────────────────────────────────┐
 │  9 files · 2 173 MB · ~3.4 s  (INSTRUMENTS §66, 2026-09-10)          │
 │  no bytes fetched · no directory made · installState() unchanged     │
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
        │  3 WRITE manifest.json THERE            │  │
        │  4 SWAP it into <weights>               │  │  ← the only
        │  5 mark it excluded from backup         │  │    destructive step
        └───┬─────────────────────────────────┬───┘  │
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
```

Two things in that picture are the whole safety argument, and they are
worth reading twice. **The manifest is written at the staging path**,
so a tree in `<weights>` either carries a manifest or was never
completed here. And **the swap is the last step**, so every failure
before it leaves the disk exactly as this download found it. Both are
`completeInstall(movingFrom:)` in
`MultiModalKitMLX/LocalMindInstall.swift`.

There is one path that skips the staging box, and it is the one a
conformer is told not to take: a fetcher that writes STRAIGHT INTO the
weights directory and hands that same path back has nothing to stage —
there is no second copy — so the manifest is written in place. The
question is asked of the resolved PATH and not of the URL, because
`…/Fake-Model` and `…/Fake-Model/` are two spellings of one directory
and a `!=` there once sent a live tree down the staging road.

### The shortest install that works

```swift
import MultiModalKitMLX

// 1 — a model that KNOWS where its weights come from. The other
//     initializer, LocalMindModel(weights:), never downloads anything.
let model = LocalMindModel(repoID: "mlx-community/Qwen3-4B-4bit")

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
```

Everything below is commentary on that block.

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
client makes its own listing before each one. For a nine-file model that
is **ten listings and nine HEADs**, all small. The doc on `hubSizes`
carries that count because an earlier version of it said "nine and nine"
and a review counted the calls in the client instead of trusting the
sentence.

**Measured once, on the real repository** (INSTRUMENTS §66,
`mlx-community/Qwen3-4B-4bit`, Ryad's Mac on a home connection,
**2026-09-10**):

| what | measured |
|---|---|
| files | 9 |
| to download | 2 278 969 756 bytes — **2 173.4 MB** |
| on disk afterwards | the same 2 278 969 756 bytes |
| the whole question | **3 388 ms** |
| bytes fetched by asking | **0** — the target directory held 0 files, `installState()` still `.absent` |

`downloadBytes` and `onDiskBytes` are equal here, and that is a fact
about this install path rather than a rounding: the snapshot is MOVED
into place exactly as it arrived, so nothing is unpacked or
re-quantised. Only `manifest.json` is added. They stay two fields because
the day a model repacks on arrival, a caller that assumed one number
would be wrong in the direction that fills a phone.

**The trap: the weights file alone under-promises by 15 MB.**
`model.safetensors` is 2 158.2 MB of the 2 173.4. The tokenizer and the
vocabularies are the other ~15 MB. A caller that showed the weights file
and then counted the whole download would overrun its own progress bar.
Show `downloadBytes`.

**The number will drift** the day the model is re-quantised — which is
why it is written down with its date, and why this library reads it from
the repository every time and caches nothing. `bakeoff install-size` is
how to take it again.

Two typed failures come out of the ask, and both name what went wrong:
`ReplyFailure.unavailable(.weightsAbsent)` when this model has no
repository to ask (the same error `download` throws for the same reason,
so a caller has one case and not two), and
`InstallFailure.sizeUnknown(file:)` when a file's size cannot be learned
— because a total that quietly leaves the 2 GB file out is worse than no
total at all.

### The four install states

`installState()` is public, nonisolated and cheap — a directory listing
and one small JSON. Never a load, never a network call, so a door can
ask it every turn.

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
keeps its state. A caller that wants a verified install must remove the
folder and download afresh, which costs the full 2.2 GB, so it is a
choice to offer a person rather than one to make for them.

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
because a client has been seen reporting outside it, and a NaN reads as
0 — that one is not a precaution, it is a scar: `min(max(x, 0), 1)` does
not clamp NaN, and the conversion below it killed a test process.

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
courtesy.** When a fetch RETURNS, it has named its directory and this
library removes it — bounded to a strict descendant of the base it handed
out, and never an ancestor of the weights, because the unbounded version
of that line once deleted a person's whole Documents folder in a review
probe. When a fetch THROWS, it has named nothing at all, and this library
does not go looking for a directory to delete. So the throw path is the
conformer's own, `WeightsFetching` states it as a requirement, and
`HubWeightsFetcher` keeps it.

**What that last sentence is worth, exactly.** The shipped cleanup and
the shipped location are both proven —
`theShippedFetchersCleanupIsBounded` removes the client's own tree and
leaves a sibling model beside it untouched. What no test executes is the
one line joining them, `HubWeightsFetcher.fetch`'s own `catch`: reaching
it needs a real network failure, and no test in this house touches the
network. The test that names this says so itself.

**The promise that matters most: an install that was already there is
never destroyed.** Not by a cancel, not by a full disk, not by a second
download racing the first. That is a mechanism and not a hope — the new
bytes are completed at the staging sibling, manifest and all, and only a
tree that survived every step is swapped in.

The rows that prove it are all in
`Tests/MultiModalKitTests/Mind/MLXInstallSeamTests.swift`:

| the promise | the test |
|---|---|
| a cancel leaves `.absent`, partial tree deleted | `aCancelDeletesThePartialTree` |
| a thrown fetch leaves `.absent`, error typed | `aThrownFetchLeavesNothing` |
| a failure AFTER the move leaves nothing pretending | `aFailureAfterTheMoveLeavesNothingPretending` |
| a caller's `.incomplete` tree survives a failed re-download | `aFailedRedownloadKeepsWhatWasAlreadyThere` |
| **a failure after the move over a caller's tree keeps that tree** | `aLateFailureOverACallersTreeKeepsIt` |
| a move that fails never touches the tree it would replace | `aMoveThatFailsNeverTouchesTheCallersTree` |
| a complete install survives a later re-download, untouched | `aCompleteInstallSurvivesAReDownload` |
| a losing racer never deletes the install the winner finished | `aLateFailureNeverDeletesAFinishedInstall` |

That fifth row is the one to name if only one can be named. It is the
crossing the earlier rows each half-covered: a tree that was ALREADY
there, and a failure that lands AFTER the fetch succeeded. A review probe
ran it and printed `.installedUnverified` — the word AC-247 forbids —
and then every later download returned early at
`guard !modelInstalled()`, so no manifest could ever be written by
anyone. The cause was an order, not a missing guard: the old code deleted
the live tree first and wrote the manifest last. The staging swap is what
closed it.

**One boundary, stated rather than buried.** A fetcher that writes
straight into the weights directory and hands that same path back has
already replaced whatever was there before this library is asked
anything. `WeightsFetching` tells a conformer not to do that; past that
line the protection is spent.

### The suspend truth (F-3 = A)

**A download dies when the app leaves the foreground.** It runs on an
ordinary foreground session — the client's background-session switch is
left off, at its default — so the moment a person locks the phone or
switches app, the system suspends this process and the transfer stops.
There is no background session and no resume.

**What a caller must do about it:** keep the screen alive while the
weights come down — an idle timer disabled, and a person told why — or
start the download again. Starting again is always safe, and with the
fetcher this library ships it begins at zero: the partial tree is
deleted, and the client's own resume bookkeeping lives inside that tree
and goes with it.

**This is a stated limit, not an engineered solution**, and Ryad ruled it
that way (D-106, F-3 = A). A background `URLSession` is what a 2.2 GB
cellular download really needs, and it is a different downloader, a
delegate and a re-entry path — a milestone of its own, not a bullet in
this one.

A statement can drift away from the code, so two rows in
`MLXInstallSuspendTests.swift` read this module's own source: one fails
if the doc comment loses the sentence, the other fails if
`URLSessionConfiguration.background` or the client's
`useBackgroundSession` flag ever appears anywhere in
`Sources/MultiModalKitMLX`. That is AC-251's second half, and it is
worth knowing that the needle AC-251 named could not have fired on its
own — this module builds no `URLSession` at all — so the client's own
switch is the needle that can.

### The backup flag (L7, AC-250)

The weights are a re-downloadable cache. **2.2 GB of cache inside a
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

The library ships `HubWeightsFetcher` and uses it by default. A caller
conforms its own to test its download screen without a real 2.2 GB
fetch. Nothing else about the install changes: the guards, the staging,
the manifest and the backup flag are this library's, whoever brought the
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
  among them, go through vendored hub clients that resolve a token from
  the ENVIRONMENT when none is given, and would then send
  `Authorization: Bearer …`. An app sandbox on a phone has nothing for
  them to find; a developer's Mac that has signed in with the hub's
  command-line tool does. This library cannot currently switch it off.
  Reported on that page, not decided.
- **The silence proof's real reach.** `URLProtocol` sees
  `URLSession.shared` and nothing else — not a session a package builds
  for itself, even on a default configuration. Of the weight path that
  means the `httpGet` metadata calls ARE watched, while the `HEAD`
  metadata calls and the 2.2 GB snapshot itself are **not**. A green run
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
  can test it on a train.
- **No admission, thermal or memory-pressure work.** This library refuses
  no device for memory today (D-105), before a download or after one. A
  caller that wants to refuse a phone that cannot HOLD the model can do
  that arithmetic itself, from `expectedInstall()` and the headroom
  `DeviceReport` carries — and F-1 = A named it as the next milestone's
  question rather than this one's.
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
commit          6aea757
library core    6942 lines   Sources/MultiModalKit
all sources     16809 lines   every product, demo and instrument under Sources/
demo app        5629 lines   Demo/
tests           14717 lines   Tests/
TurnCoordinator 1028 lines across 5 files
runner          Test run with 615 tests in 83 suites
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
