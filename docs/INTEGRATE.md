# Integrating MultiModalKit — the page a developer (or an agent) reads first

*Written for the person or the AI agent wiring this library into an
app. Every code block below is lifted from a contract page in
`ARCHITECTURE.md` that was fact-checked against the source, or from the
demo that runs it; the public surface in the appendix is the OUTPUT of
`Scripts/api.sh`, never typed. If the appendix disagrees with the script,
the appendix is stale and the script is right.*

## What this is, in five lines

An on-device voice assistant in three organs — **ear** (speech to
text), **mind** (a language model), **mouth** (text to speech) — and a
**coordinator** that runs the turn loop between them with barge-in. Swift
6, strict concurrency, zero runtime dependencies in the core module;
the neural organs live in optional modules behind protocols. Floor:
iOS 18 / macOS 15 for the library; the Apple organs need OS 26. Nothing
leaves the device after the weights are on disk (`docs/HOSTS.md` names
the two hosts a download may contact).

```
 MultiModalKit           the core: seams, the coordinator, the Apple ear, the Apple mind,
                         the Apple mouth, the text contract, the tool contract, admission's types
 MultiModalKitMLX        the local mind on MLX (Qwen3 weights): install, admission, pressure, tools
 MultiModalKitTTS        the neural mouths (Kokoro)
 MultiModalKitWhisper    the Whisper ear
 MultiModalKitTesting    manual clock, scripted ear/mind/mouth/tool — for YOUR tests, not only ours
```

## Which tag has what

| tag | commit | what it added |
|---|---|---|
| `0.1.0` | `e7993b4` | the mind's TEXT contract: `reply(to:)`, `GenerationOptions`, typed `StopReason` and `ReplyFailure`, `MindReadiness.verdict` |
| `0.2.0` | `ee6788c` | the install (`expectedInstall()`, `download(reporting:)`, `InstallState`, `WeightsFetching`, six privacy manifests, `docs/HOSTS.md`) and the tool spike (`ReplyTool`, `ToolTable` at construction) |
| `0.3.0` | `228b7e6` | admission and heat (`admit(needing:)`, `.tooHot`, memory pressure, `deadline`) and the tool CONTRACT (typed parameters, one door, tools per call, the confirmation flag, the band). **The tag note lists every public break versus 0.2.0** — `git show 0.3.0`. |

Pin an exact tag. A `from:` range would let a `throws` land on an init
you did not write `try` for.

## 1. The mind, text in, text out (4v — `ARCHITECTURE.md` "The mind's text contract")

```swift
import MultiModalKit
import MultiModalKitMLX

// 1 — the mind: weights on disk, and a generator over them.
let model = LocalMindModel(weights: weightsFolder)
let mind  = try MLXReplyGenerator(model: model)   // defaults: nil, 1024; `try` since 0.3.0

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

The Apple mind is the same four steps with two names changed: `try
AppleReplyGenerator()` for the mind, `AppleMind.readiness()` for step 2.
`reply(to:)` is the whole-reply convenience; `openReply(to:)` gives the
stream of `.token` updates and one terminal (`.finished(StopReason)` or
`.failed(ReplyFailure)`).

## 2. Getting the weights (4x — "Getting the weights")

```swift
import MultiModalKitMLX

// 1 — a model that KNOWS where its weights come from. The other
//     initializer, LocalMindModel(weights:), never downloads anything.
let model = LocalMindModel(repoID: "mlx-community/Qwen3-4B-4bit")
print(model.weights)   // THE folder, never changes

// 2 — the price, BEFORE a byte of the model moves. This reaches the
//     network (~3 s of listings). Ask it once, and keep the answer.
let size = try await model.expectedInstall()
print(size.downloadBytes, size.onDiskBytes)

// 3 — the download. Cancel the surrounding task to stop it.
try await model.download(reporting: { progress in
    print(progress.fraction)                     // 0…1, always a number
    print(progress.bytesExpected ?? -1)          // nil on a FIRST install
})

// 4 — what is on disk now. No await: it is nonisolated, and cheap.
switch model.installState() {
case .installed, .installedUnverified: print("ready")
case .incomplete(let files): print("repair", files)
case .absent: print("offer the download")
}

// …and the same download driven by a fetcher of your own — the seam an
// app fakes in its tests (shipping API, not test-only).
try await model.download(reporting: { _ in }, using: MyFakeFetcher())
```

A download runs in the foreground and dies when the app is suspended
(the next milestone, 0.3.1, is about that). A cancelled or failed
download never reports "installed".

## 3. Running it safely — admission, heat, the deadline (4y — "Running it safely")

```swift
import MultiModalKit
import MultiModalKitMLX

let model = LocalMindModel(weights: weightsFolder)

// 1 — ONE admission call, with YOUR number: the PEAK a load plus one
//     reply reaches on your phone, measured (never the file size).
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
let mind = try MLXReplyGenerator(model: model)

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
    print("too hot to generate at \(state)")           // no run was opened
} catch let failure as ReplyFailure {
    print(failure.description)
}
```

What happens on its own: a memory `.warning` cuts the running
generation (the stream ends with no terminal; the weights stay); a
`.critical` also retires the weights, and the next `openReply` reloads
them — with NO memory question, so call `admit(needing:)` again if you
want the gate. The default heat policy refuses at `.critical` only.

## 4. Tools — a verb the app owns, with typed parameters (4z — "The tool contract")

```swift
let logReading = ReplyTool(
    name: "log_reading",
    description: "Record a body reading the person gives, in kilograms.",
    parameters: [ToolParameter(name: "kg", description: "the reading in kilograms",
                               kind: .number, isRequired: true,
                               range: 20...400, showsRange: false)],
    requiresConfirmation: false) { arguments in
        let kg = try arguments.number("kg")        // a number, never text
        await store.record(kg)                     // runs to its end even under a barge
        return "Recorded \(kg) kg."                 // back to the model, verbatim, capped at 4,000
    }

// The table rides on the CALL. nil = the generator's own table;
// .empty = no tools this turn (the plain path, byte-identical).
let reply = try await mind.reply(to: ReplyContext(
    transcript: "log eighty-three and a half",
    options: GenerationOptions(tools: ToolTable([logReading]))))
```

What the door does to every call, in this order, on every mind: strip
undeclared names (counted) → missing / null / wrong kind refused, `"84"`
for a number read as 84 (counted), `"nan"`/`"inf"` refused → the band
checked if declared → `requiresConfirmation` and no yes on the call:
the body does NOT run, the model is told to ask → the BODY runs in its
own awaited task, a barge cannot reach inside → the result is cut at
4,000 characters, marked, counted → the model reads a sentence either
way. The counts come back on `ToolCallOutcome`.

A verb that needs a yes: declare `requiresConfirmation: true`; when the
person has said yes, put the tool's NAME on the next call —
`GenerationOptions(tools: table, confirmedTools: ["log_reading"])`. The
model cannot confirm itself.

## 5. The voice loop — the front door (`AIRuntime`)

The coordinator runs ear → mind → mouth with barge-in. You assemble it
ONCE from your organs; the exact assembly the demo runs is
`Sources/AudioDemo/Runtime/AudioDemo+Pipeline.swift`:

```swift
let runtime = try AIRuntime(.init(
    consumer: ringConsumer,                       // the audio ring's consumer end
    vad: EnergyVAD(config: .init(threshold: 0.02, hangoverFrames: 4_800, onsetFrames: 1_600)),
    ear: ear,                                     // AppleSpeechEngine() or WhisperEngine()
    mind: mind,                                   // any ReplyGenerating, or nil to only transcribe
    mouth: mouth,                                 // any SpeechSynthesizing, or nil
    pump: .init(sampleRate: 16_000, pollInterval: .milliseconds(10), chunkFrames: 320, preRollChunks: 10),
    transcription: .init(format: .init(sampleRate: 16_000, channels: 1)),
    turns: .init(replyGate: .milliseconds(600)),  // how long the floor stays the person's
    clock: ContinuousClock(),
    diagnostics: PipelineDiagnostics(),           // optional; health events
    releaseSource: { microphone.stop() }))

await runtime.run { session in
    for await turn in session.turns! { print(turn) }   // .replyToken, .turnCompleted, .turnFailed…
}
```

The runtime allocates nothing at construction; `run` starts the loop and
tears everything down in order when its task is cancelled.

## The rules — ten lines

1. **Both generator inits throw** (`throws(ToolDeclarationError)`): a
   default table no mind can show is refused where it is handed over.
   Write `try`.
2. **`GenerationOptions.tools`: `nil` is the mind's own table, `.empty`
   is no tools this turn.** They are not the same.
3. **A number is a number.** `ToolValue` has one number case; an integer
   PARAMETER refuses 84.5 at the door; `"84"` is read as 84 and counted.
4. **`isRequired` and `requiresConfirmation` have no default.** Write
   them on every tool; `showsRange` must be written when a band is
   declared.
5. **The yes binds to a tool's NAME, not its arguments** (D-110 F-10
   B-ii, recorded). Re-check the number in your verb after a yes.
6. **`admit(needing:)` takes YOUR measured number**, and admission is not
   remembered across a `.critical`.
7. **Every failure is typed and thrown; nothing terminates the process.**
   The Simulator is `.deviceCannotRun(.simulator)`, an old OS is
   `.osBelowFloor`, both readable before any download.
8. **Inject time in tests.** Every generator takes a `clock:`;
   `MultiModalKitTesting.ManualClock` makes a deadline a fact of the
   script. Wait on events, never on time.
9. **The library ships no words for a screen and no policy.** Tool
   names, descriptions, instructions, confirmation and undo are the
   app's.
10. **Measured claims live in `INSTRUMENTS.md`**; the numbers here (4B:
    +419 ms per idle tool, 0.74 ms per parameter character, one round
    ≈ 2.65 s) are this Mac's shape — the phone decides.

## For an AI agent integrating this library

The three rules that were broken this month were process rules, not
signatures: **requirements come as documents, code comes from this
repo's own session**; **design forks are the owner's to rule** — present
options, never decide; **the repo is the memory** — `SPEC.md` holds the
criteria, `DECISIONS.md` the rulings and what they rejected,
`INSTRUMENTS.md` the measurements. Read `llms.txt` at the root for the
map, and the contract page for the organ you touch before writing a
line.

## Where to read more

| you want | read |
|---|---|
| the argument, the concurrency model, how to build and test | `README.md` |
| the map of every seam, one contract page per milestone | `ARCHITECTURE.md` |
| every acceptance criterion and its test | `SPEC.md` |
| why — every ruling and the options it rejected | `DECISIONS.md` |
| every number, with its methodology and caveats | `INSTRUMENTS.md` |
| the instruments and demos, and how to run them | `COMMANDS.md` |
| which hosts a download may contact | `docs/HOSTS.md` |

## Appendix — the public surface, generated

The output of `Scripts/api.sh` at the commit named on its first line;
one line per `public` declaration, multi-line signatures folded (a
default closure `= { … }` folds at its brace). The words are the
source's; the doc comments beside them say why.

```
commit   228b7e6

## MultiModalKit
  Audio/AudioEvent.swift: public struct AudioTime: Sendable, Hashable, Comparable, CustomStringConvertible
  Audio/AudioEvent.swift: public let frames: Int
  Audio/AudioEvent.swift: public let sampleRate: Double
  Audio/AudioEvent.swift: public init(frames: Int, sampleRate: Double)
  Audio/AudioEvent.swift: public func advanced(by duration: Duration) -> AudioTime
  Audio/AudioEvent.swift: public var seconds: Double
  Audio/AudioEvent.swift: public static func < (lhs: AudioTime, rhs: AudioTime) -> Bool
  Audio/AudioEvent.swift: public var description: String
  Audio/AudioEvent.swift: public struct AudioChunk: Sendable, Equatable
  Audio/AudioEvent.swift: public let samples: [Float]
  Audio/AudioEvent.swift: public let start: AudioTime
  Audio/AudioEvent.swift: public init(samples: [Float], start: AudioTime)
  Audio/AudioEvent.swift: public var frameCount: Int
  Audio/AudioEvent.swift: public enum AudioEvent: Sendable, Equatable
  Audio/AudioPump.swift: public actor AudioPump<C: Clock> where C.Duration == Duration
  Audio/AudioPump.swift: public struct Config: Sendable
  Audio/AudioPump.swift: public var sampleRate: Double
  Audio/AudioPump.swift: public var pollInterval: Duration
  Audio/AudioPump.swift: public var chunkFrames: Int
  Audio/AudioPump.swift: public var preRollChunks: Int
  Audio/AudioPump.swift: public var listenerBufferCapacity: Int
  Audio/AudioPump.swift: public init( sampleRate: Double = 48_000, pollInterval: Duration = .milliseconds(10), chunkFrames: Int = 960, preRollChunks: Int = 2, listenerBufferCapacity: Int = Broadcast<AudioEvent>.defaultBufferCapacity )
  Audio/AudioPump.swift: public init( consumer: AudioRingConsumer, vad: any VoiceActivityDetecting, clock: C, config: Config = Config(), diagnostics: PipelineDiagnostics? = nil )
  Audio/AudioPump.swift: public func listen() -> Broadcast<AudioEvent>.Listener
  Audio/AudioPump.swift: public func run() async
  Audio/AudioPump.swift: public func stop()
  Audio/AudioPump.swift: public func droppedEvents(for listenerID: Int) -> Int
  Audio/AudioRingBuffer.swift: public enum AudioRing
  Audio/AudioRingBuffer.swift: public static func create(minimumCapacity: Int) -> (producer: AudioRingProducer, consumer: AudioRingConsumer)
  Audio/AudioRingBuffer.swift: public final class AudioRingProducer: Sendable
  Audio/AudioRingBuffer.swift: public var capacity: Int
  Audio/AudioRingBuffer.swift: public func write(_ samples: UnsafeBufferPointer<Float>)
  Audio/AudioRingBuffer.swift: public final class AudioRingConsumer: Sendable
  Audio/AudioRingBuffer.swift: public struct ReadResult: Sendable, Equatable
  Audio/AudioRingBuffer.swift: public let framesRead: Int
  Audio/AudioRingBuffer.swift: public let framesDropped: Int
  Audio/AudioRingBuffer.swift: public init(framesRead: Int, framesDropped: Int)
  Audio/AudioRingBuffer.swift: public var capacity: Int
  Audio/AudioRingBuffer.swift: public var totalDropped: Int
  Audio/AudioRingBuffer.swift: public func read(into destination: UnsafeMutableBufferPointer<Float>) -> ReadResult
  Audio/AudioSessionConfiguring.swift: public protocol AudioSessionConfiguring: Sendable
  Audio/AudioSource.swift: public protocol AudioSource: AnyObject
  Audio/AudioSource.swift: public enum AudioSourceFailure: Error, Sendable, Equatable
  Audio/EnergyVAD.swift: public struct EnergyVAD: VoiceActivityDetecting
  Audio/EnergyVAD.swift: public struct Config: Sendable
  Audio/EnergyVAD.swift: public var threshold: Float
  Audio/EnergyVAD.swift: public var hangoverFrames: Int
  Audio/EnergyVAD.swift: public var onsetFrames: Int
  Audio/EnergyVAD.swift: public init( threshold: Float = 0.02, hangoverFrames: Int = 14_400, onsetFrames: Int = 0 )
  Audio/EnergyVAD.swift: public typealias Transition = SpeechTransition
  Audio/EnergyVAD.swift: public init(config: Config = Config())
  Audio/EnergyVAD.swift: public mutating func process(_ chunk: UnsafeBufferPointer<Float>) -> SpeechTransition?
  Audio/EnergyVAD.swift: public mutating func process(_ chunk: [Float]) -> Transition?
  Audio/GateCalibration.swift: public enum GateCalibration
  Audio/GateCalibration.swift: public enum Outcome: Sendable, Equatable
  Audio/GateCalibration.swift: public static let minimumRatio: Float = 3
  Audio/GateCalibration.swift: public static func suggestedGate(quiet: Float, speech: Float) -> Outcome
  Audio/MicrophoneSource.swift: public final class MicrophoneSource: AudioSource
  Audio/MicrophoneSource.swift: public private(set) var isRunning = false
  Audio/MicrophoneSource.swift: public private(set) var sampleRate: Double = 0
  Audio/MicrophoneSource.swift: public private(set) var voiceProcessingActive = false
  Audio/MicrophoneSource.swift: public var configurationChanges: Int
  Audio/MicrophoneSource.swift: public var engineRestarts: Int
  Audio/MicrophoneSource.swift: public var isWatchingConfiguration: Bool
  Audio/MicrophoneSource.swift: public var engineIsRunning: Bool
  Audio/MicrophoneSource.swift: public var inputLevel: Float
  Audio/MicrophoneSource.swift: public let playbackHost: MicrophonePlaybackHost
  Audio/MicrophoneSource.swift: public init(voiceProcessing: Bool = false, session: (any AudioSessionConfiguring)? = nil, hostsPlayback: Bool = false)
  Audio/MicrophoneSource.swift: public func start(into producer: AudioRingProducer) throws
  Audio/MicrophoneSource.swift: public func stop()
  Audio/PlaybackHost.swift: public protocol PlaybackHost: AnyObject, Sendable
  Audio/PlaybackHost.swift: public enum PlaybackHostFailure: Error, Sendable, Equatable
  Audio/PlaybackHost.swift: public final class MicrophonePlaybackHost: PlaybackHost, @unchecked Sendable
  Audio/PlaybackHost.swift: public var hostedCount: Int
  Audio/PlaybackHost.swift: public var isRendering: Bool
  Audio/PlaybackHost.swift: public var outputSampleRate: Double
  Audio/PlaybackHost.swift: public func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws
  Audio/PlaybackHost.swift: public func detachFromPlayback(_ node: AVAudioNode)
  Audio/PlaybackHost.swift: public final class AudioEnginePlaybackHost: PlaybackHost, @unchecked Sendable
  Audio/PlaybackHost.swift: public init()
  Audio/PlaybackHost.swift: public init(engine: AVAudioEngine)
  Audio/PlaybackHost.swift: public var isRendering: Bool
  Audio/PlaybackHost.swift: public var hostedCount: Int
  Audio/PlaybackHost.swift: public var outputSampleRate: Double
  Audio/PlaybackHost.swift: public func attachForPlayback(_ node: AVAudioNode, format: AVAudioFormat) throws
  Audio/PlaybackHost.swift: public func detachFromPlayback(_ node: AVAudioNode)
  Audio/PlaybackHost.swift: public func stopRendering()
  Audio/VoiceActivityDetecting.swift: public enum SpeechTransition: Sendable, Equatable
  Audio/VoiceActivityDetecting.swift: public protocol VoiceActivityDetecting: Sendable
  Concurrency/Broadcast.swift: public final class Broadcast<Element: Sendable>: Sendable
  Concurrency/Broadcast.swift: public struct Listener: Sendable
  Concurrency/Broadcast.swift: public let id: Int
  Concurrency/Broadcast.swift: public let events: AsyncStream<Element>
  Concurrency/Broadcast.swift: public init(id: Int, events: AsyncStream<Element>)
  Concurrency/Broadcast.swift: public static var defaultBufferCapacity: Int
  Concurrency/Broadcast.swift: public init( bufferCapacity: Int = Broadcast.defaultBufferCapacity, onListenerDrop: (@Sendable (_ listenerID: Int, _ totalDropped: Int) -> Void)? = nil )
  Concurrency/Broadcast.swift: public func listen() -> Listener
  Concurrency/Broadcast.swift: public func publish(_ element: Element)
  Concurrency/Broadcast.swift: public func finish()
  Concurrency/Broadcast.swift: public func droppedEvents(for id: Int) -> Int
  Concurrency/Broadcast.swift: public var listenerCount: Int
  Concurrency/LaunchOnce.swift: public actor LaunchOnce
  Concurrency/LaunchOnce.swift: public init()
  Concurrency/LaunchOnce.swift: public var hasRun: Bool
  Concurrency/LaunchOnce.swift: public func run(_ steps: [@Sendable () async -> Void]) async
  Concurrency/Retirable.swift: public actor Retirable<Resource: Sendable>
  Concurrency/Retirable.swift: public enum Failure: Error, Equatable
  Concurrency/Retirable.swift: public init(discard: @escaping @Sendable (Resource) -> Void =
  Concurrency/Retirable.swift: public var isResident: Bool
  Concurrency/Retirable.swift: public func value( building build: @Sendable () async throws -> Resource ) async throws -> Resource
  Concurrency/Retirable.swift: public func retire() -> Resource?
  Concurrency/StopSignal.swift: public final class StopSignal: Sendable
  Concurrency/StopSignal.swift: public init()
  Concurrency/StopSignal.swift: public var isOn: Bool
  Concurrency/StopSignal.swift: public func signal()
  Concurrency/StopSignal.swift: public func wait() async
  Conversation/AppleReplyGenerator.swift: public enum AppleMind
  Conversation/AppleReplyGenerator.swift: public static func readiness() -> MindUnavailable?
  Conversation/AppleReplyGenerator.swift: public struct AppleReplyGenerator: ReplyGenerating
  Conversation/AppleReplyGenerator.swift: public static let defaultTokenBudget = 1024
  Conversation/AppleReplyGenerator.swift: public let instructions: String?
  Conversation/AppleReplyGenerator.swift: public let spokenRefusal: String
  Conversation/AppleReplyGenerator.swift: public let tools: ToolTable
  Conversation/AppleReplyGenerator.swift: public let thermal: any ThermalStateProviding
  Conversation/AppleReplyGenerator.swift: public let thermalPolicy: any GenerationThermalPolicy
  Conversation/AppleReplyGenerator.swift: public let clock: any Clock<Duration>
  Conversation/AppleReplyGenerator.swift: public init(instructions: String? = nil, spokenRefusal: String = "I can't answer that.", tools: ToolTable = .empty, thermal: any ThermalStateProviding = SystemThermalProvider(), thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(), clock: any Clock<Duration> = ContinuousClock()) throws(ToolDeclarationError)
  Conversation/AppleReplyGenerator.swift: public static var availability: MindUnavailable?
  Conversation/AppleReplyGenerator.swift: public func prewarm()
  Conversation/AppleReplyGenerator.swift: public func openReply(to context: ReplyContext) async throws -> any ReplyRun
  Conversation/AppleSpeechSynthesizer.swift: public final class AppleSpeechSynthesizer: SpeechSynthesizing
  Conversation/AppleSpeechSynthesizer.swift: public init(voiceIdentifier: String? = nil, renderingOn host: (any PlaybackHost)? = nil)
  Conversation/AppleSpeechSynthesizer.swift: public struct InstalledVoice: Sendable, Identifiable, Equatable
  Conversation/AppleSpeechSynthesizer.swift: public let id: String
  Conversation/AppleSpeechSynthesizer.swift: public let name: String
  Conversation/AppleSpeechSynthesizer.swift: public let quality: String
  Conversation/AppleSpeechSynthesizer.swift: public let language: String
  Conversation/AppleSpeechSynthesizer.swift: public var label: String
  Conversation/AppleSpeechSynthesizer.swift: public static func installedVoices(matching language: String? = nil) -> [InstalledVoice]
  Conversation/AppleSpeechSynthesizer.swift: public static func bestInstalledVoice( forLanguage language: String = Locale.preferredLanguages.first ?? "en-US" ) -> AVSpeechSynthesisVoice?
  Conversation/AppleSpeechSynthesizer.swift: public static func describe(_ voice: AVSpeechSynthesisVoice) -> String
  Conversation/AppleSpeechSynthesizer.swift: public func openUtterance() async throws -> any SynthesisRun
  Conversation/ConversationMemory.swift: public struct ConversationMemory: Sendable, Equatable
  Conversation/ConversationMemory.swift: public let maxTurns: Int
  Conversation/ConversationMemory.swift: public let maxCharacters: Int
  Conversation/ConversationMemory.swift: public init(maxTurns: Int = 8, maxCharacters: Int = 600)
  Conversation/ConversationMemory.swift: public mutating func record(_ turn: ConversationTurn) -> Bool
  Conversation/ConversationMemory.swift: public var turns: [ConversationTurn]
  Conversation/ConversationMemory.swift: public var isEmpty: Bool
  Conversation/ConversationMemory.swift: public var count: Int
  Conversation/ConversationMemory.swift: public var characters: Int
  Conversation/ConversationMemory.swift: public mutating func clear()
  Conversation/ConversationMemory.swift: public struct ConversationTurn: Sendable, Equatable
  Conversation/ConversationMemory.swift: public let said: String
  Conversation/ConversationMemory.swift: public let replied: String
  Conversation/ConversationMemory.swift: public let interrupted: Bool
  Conversation/ConversationMemory.swift: public init(said: String, replied: String, interrupted: Bool = false)
  Conversation/ConversationMemory.swift: public var characters: Int
  Conversation/LatencyReporter.swift: public protocol LatencyReporter: Sendable
  Conversation/MindReadiness.swift: public struct OSVersion: Sendable, Hashable, Comparable, CustomStringConvertible
  Conversation/MindReadiness.swift: public var major: Int
  Conversation/MindReadiness.swift: public var minor: Int
  Conversation/MindReadiness.swift: public var patch: Int
  Conversation/MindReadiness.swift: public init(major: Int, minor: Int = 0, patch: Int = 0)
  Conversation/MindReadiness.swift: public init(_ version: OperatingSystemVersion)
  Conversation/MindReadiness.swift: public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool
  Conversation/MindReadiness.swift: public var description: String
  Conversation/MindReadiness.swift: public enum Platform: Sendable, Equatable
  Conversation/MindReadiness.swift: public var libraryFloor: OSVersion
  Conversation/MindReadiness.swift: public var appleMindFloor: OSVersion
  Conversation/MindReadiness.swift: public enum GPU: Sendable, Equatable
  Conversation/MindReadiness.swift: public enum InstallState: Sendable, Equatable
  Conversation/MindReadiness.swift: public struct DeviceReport: Sendable, Equatable
  Conversation/MindReadiness.swift: public var platform: Platform
  Conversation/MindReadiness.swift: public var os: OSVersion
  Conversation/MindReadiness.swift: public var isSimulator: Bool
  Conversation/MindReadiness.swift: public var gpu: GPU
  Conversation/MindReadiness.swift: public var memoryHeadroomBytes: Int?
  Conversation/MindReadiness.swift: public var install: InstallState
  Conversation/MindReadiness.swift: public init(platform: Platform, os: OSVersion, isSimulator: Bool, gpu: GPU, memoryHeadroomBytes: Int?, install: InstallState)
  Conversation/MindReadiness.swift: public static func current(gpu: GPU, install: InstallState) -> DeviceReport
  Conversation/MindReadiness.swift: public struct MindNeeds: Sendable, Equatable
  Conversation/MindReadiness.swift: public var floor: OSVersion
  Conversation/MindReadiness.swift: public var memoryBytes: Int
  Conversation/MindReadiness.swift: public init(floor: OSVersion, memoryBytes: Int)
  Conversation/MindReadiness.swift: public enum MindReadiness
  Conversation/MindReadiness.swift: public static func verdict(for report: DeviceReport, needs: MindNeeds) -> MindUnavailable?
  Conversation/PlaybackLead.swift: public struct PlaybackLead: Sendable
  Conversation/PlaybackLead.swift: public let target: Duration
  Conversation/PlaybackLead.swift: public private(set) var queuedAudio: Duration = .zero
  Conversation/PlaybackLead.swift: public private(set) var hasStarted = false
  Conversation/PlaybackLead.swift: public init(target: Duration)
  Conversation/PlaybackLead.swift: public mutating func queue(_ audio: Duration) -> Bool
  Conversation/PlaybackLead.swift: public mutating func noMoreAudio() -> Bool
  Conversation/PlaybackLead.swift: public mutating func abandon()
  Conversation/PlaybackLead.swift: public static func deficit(forReplyOf reply: Duration, realTimeFactor: Double) -> Duration
  Conversation/ReplyContract.swift: public struct GenerationOptions: Sendable, Equatable
  Conversation/ReplyContract.swift: public var instructions: String?
  Conversation/ReplyContract.swift: public var maxTokens: Int?
  Conversation/ReplyContract.swift: public var temperature: Float?
  Conversation/ReplyContract.swift: public var seed: UInt64?
  Conversation/ReplyContract.swift: public var deadline: Duration?
  Conversation/ReplyContract.swift: public var tools: ToolTable?
  Conversation/ReplyContract.swift: public var confirmedTools: Set<String>
  Conversation/ReplyContract.swift: public init(instructions: String? = nil, maxTokens: Int? = nil, temperature: Float? = nil, seed: UInt64? = nil, deadline: Duration? = nil, tools: ToolTable? = nil, confirmedTools: Set<String> = [])
  Conversation/ReplyContract.swift: public enum StopReason: Sendable, Equatable
  Conversation/ReplyContract.swift: public enum ReplyFailure: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/ReplyContract.swift: public var description: String
  Conversation/ReplyContract.swift: public enum MindUnavailable: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/ReplyContract.swift: public enum DeviceLimit: Sendable, Equatable
  Conversation/ReplyContract.swift: public var description: String
  Conversation/ReplyContract.swift: public struct Reply: Sendable, Equatable
  Conversation/ReplyContract.swift: public let text: String
  Conversation/ReplyContract.swift: public let stop: StopReason
  Conversation/ReplyContract.swift: public init(text: String, stop: StopReason)
  Conversation/ReplyContract.swift: public func reply(to context: ReplyContext) async throws -> Reply
  Conversation/ReplyTool.swift: public enum ToolValue: Sendable, Equatable
  Conversation/ReplyTool.swift: public init(stringLiteral value: String)
  Conversation/ReplyTool.swift: public init(integerLiteral value: Int)
  Conversation/ReplyTool.swift: public init(floatLiteral value: Double)
  Conversation/ReplyTool.swift: public init(booleanLiteral value: Bool)
  Conversation/ReplyTool.swift: public var description: String
  Conversation/ReplyTool.swift: public struct ToolParameter: Sendable, Equatable
  Conversation/ReplyTool.swift: public enum Kind: String, Sendable, Equatable, CaseIterable
  Conversation/ReplyTool.swift: public let name: String
  Conversation/ReplyTool.swift: public let description: String
  Conversation/ReplyTool.swift: public let kind: Kind
  Conversation/ReplyTool.swift: public let isRequired: Bool
  Conversation/ReplyTool.swift: public let range: ClosedRange<Double>?
  Conversation/ReplyTool.swift: public let showsRange: Bool
  Conversation/ReplyTool.swift: public init(name: String, description: String, kind: Kind, isRequired: Bool)
  Conversation/ReplyTool.swift: public init(name: String, description: String, kind: Kind, isRequired: Bool, range: ClosedRange<Double>, showsRange: Bool)
  Conversation/ReplyTool.swift: public struct ToolArgumentFailure: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/ReplyTool.swift: public enum Reason: Sendable, Equatable
  Conversation/ReplyTool.swift: public let argument: String
  Conversation/ReplyTool.swift: public let reason: Reason
  Conversation/ReplyTool.swift: public init(argument: String, reason: Reason)
  Conversation/ReplyTool.swift: public var description: String
  Conversation/ReplyTool.swift: public struct ToolArguments: Sendable, Equatable
  Conversation/ReplyTool.swift: public let values: [String: ToolValue]
  Conversation/ReplyTool.swift: public init(_ values: [String: ToolValue] = [:])
  Conversation/ReplyTool.swift: public static let empty = ToolArguments()
  Conversation/ReplyTool.swift: public func has(_ name: String) -> Bool
  Conversation/ReplyTool.swift: public func string(_ name: String) throws -> String
  Conversation/ReplyTool.swift: public func number(_ name: String) throws -> Double
  Conversation/ReplyTool.swift: public func integer(_ name: String) throws -> Int
  Conversation/ReplyTool.swift: public func boolean(_ name: String) throws -> Bool
  Conversation/ReplyTool.swift: public init(dictionaryLiteral elements: (String, ToolValue)...)
  Conversation/ReplyTool.swift: public struct ReplyTool: Sendable
  Conversation/ReplyTool.swift: public let name: String
  Conversation/ReplyTool.swift: public let description: String
  Conversation/ReplyTool.swift: public let parameters: [ToolParameter]
  Conversation/ReplyTool.swift: public let requiresConfirmation: Bool
  Conversation/ReplyTool.swift: public init(name: String, description: String, parameters: [ToolParameter], requiresConfirmation: Bool, body: @escaping @Sendable (ToolArguments) async throws -> String)
  Conversation/ReplyTool.swift: public struct ToolCallFailure: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/ReplyTool.swift: public enum Reason: Sendable, Equatable
  Conversation/ReplyTool.swift: public let tool: String
  Conversation/ReplyTool.swift: public let reason: Reason
  Conversation/ReplyTool.swift: public init(tool: String, reason: Reason)
  Conversation/ReplyTool.swift: public var description: String
  Conversation/ReplyTool.swift: public struct ToolCallOutcome: Sendable, Equatable
  Conversation/ReplyTool.swift: public let result: Result<String, ToolCallFailure>
  Conversation/ReplyTool.swift: public let stripped: [String]
  Conversation/ReplyTool.swift: public let coerced: [String]
  Conversation/ReplyTool.swift: public let cut: Bool
  Conversation/ReplyTool.swift: public init(result: Result<String, ToolCallFailure>, stripped: [String] = [], coerced: [String] = [], cut: Bool = false)
  Conversation/ReplyTool.swift: public var wordsForModel: String
  Conversation/ReplyTool.swift: public enum ToolDeclarationError: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/ReplyTool.swift: public var description: String
  Conversation/ReplyTool.swift: public struct ToolTable: Sendable, Equatable
  Conversation/ReplyTool.swift: public let tools: [ReplyTool]
  Conversation/ReplyTool.swift: public init(_ tools: [ReplyTool] = [])
  Conversation/ReplyTool.swift: public static let empty = ToolTable()
  Conversation/ReplyTool.swift: public var isEmpty: Bool
  Conversation/ReplyTool.swift: public static let answerCap = 4_000
  Conversation/ReplyTool.swift: public static let cutMarker =
  Conversation/ReplyTool.swift: public subscript(name: String) -> ReplyTool?
  Conversation/ReplyTool.swift: public static func == (lhs: ToolTable, rhs: ToolTable) -> Bool
  Conversation/ReplyTool.swift: public func checkDeclarations() throws(ToolDeclarationError)
  Conversation/ReplyTool.swift: public func invoke(_ name: String, arguments: ToolArguments, confirmed: Set<String> = []) async -> ToolCallOutcome
  Conversation/SnapshotDiffer.swift: public struct SnapshotDiffer: Sendable
  Conversation/SnapshotDiffer.swift: public private(set) var emitted = ""
  Conversation/SnapshotDiffer.swift: public init()
  Conversation/SnapshotDiffer.swift: public mutating func advance(to snapshot: String) throws -> String
  Conversation/SnapshotDiffer.swift: public struct SnapshotRevision: Error, Equatable, Sendable
  Conversation/SnapshotDiffer.swift: public let emitted: String
  Conversation/SnapshotDiffer.swift: public let snapshot: String
  Conversation/SnapshotDiffer.swift: public init(emitted: String, snapshot: String)
  Conversation/SpeechPhraser.swift: public struct SpeechPhraser: Sendable
  Conversation/SpeechPhraser.swift: public static func hasSpeakableContent(_ text: String) -> Bool
  Conversation/SpeechPhraser.swift: public struct Config: Sendable
  Conversation/SpeechPhraser.swift: public var maxPhraseCharacters: Int
  Conversation/SpeechPhraser.swift: public init(maxPhraseCharacters: Int = 120)
  Conversation/SpeechPhraser.swift: public init(config: Config = Config())
  Conversation/SpeechPhraser.swift: public mutating func feed(_ token: String) -> [String]
  Conversation/SpeechPhraser.swift: public mutating func flush() -> String?
  Conversation/TranscriptLedger.swift: public struct TranscriptLedger: Sendable, Equatable
  Conversation/TranscriptLedger.swift: public let maxPieces: Int
  Conversation/TranscriptLedger.swift: public init(maxPieces: Int = 16)
  Conversation/TranscriptLedger.swift: public mutating func record(_ text: String, utterance: Int)
  Conversation/TranscriptLedger.swift: public var text: String
  Conversation/TranscriptLedger.swift: public var isEmpty: Bool
  Conversation/TranscriptLedger.swift: public var count: Int
  Conversation/TranscriptLedger.swift: public mutating func clear()
  Conversation/TranscriptLedger.swift: public static func == (lhs: TranscriptLedger, rhs: TranscriptLedger) -> Bool
  Conversation/TurnCoordination.swift: public enum TurnState: Sendable, Equatable
  Conversation/TurnCoordination.swift: public enum TurnFailure: Error, Sendable, Equatable
  Conversation/TurnCoordination.swift: public enum TurnEvent: Sendable, Equatable
  Conversation/TurnCoordination.swift: public enum ReplyUpdate: Sendable, Equatable
  Conversation/TurnCoordination.swift: public protocol ReplyRun: Sendable
  Conversation/TurnCoordination.swift: public struct ReplyContext: Sendable, Equatable
  Conversation/TurnCoordination.swift: public let transcript: String
  Conversation/TurnCoordination.swift: public let history: [ConversationTurn]
  Conversation/TurnCoordination.swift: public let options: GenerationOptions
  Conversation/TurnCoordination.swift: public init(transcript: String, history: [ConversationTurn] = [], options: GenerationOptions = GenerationOptions())
  Conversation/TurnCoordination.swift: public protocol ReplyGenerating: Sendable
  Conversation/TurnCoordination.swift: public func openReply(to transcript: String) async throws -> any ReplyRun
  Conversation/TurnCoordination.swift: public enum SynthesisUpdate: Sendable, Equatable
  Conversation/TurnCoordination.swift: public protocol SynthesisRun: Sendable
  Conversation/TurnCoordination.swift: public protocol SpeechSynthesizing: Sendable
  Conversation/TurnCoordinator+Config.swift: public struct Config: Sendable
  Conversation/TurnCoordinator+Config.swift: public var listenerBufferCapacity: Int
  Conversation/TurnCoordinator+Config.swift: public var replyGate: Duration
  Conversation/TurnCoordinator+Config.swift: public var maxContextPieces: Int
  Conversation/TurnCoordinator+Config.swift: public var bargeWindow: Duration
  Conversation/TurnCoordinator+Config.swift: public var maxMemoryTurns: Int
  Conversation/TurnCoordinator+Config.swift: public var maxMemoryCharacters: Int
  Conversation/TurnCoordinator+Config.swift: public init( listenerBufferCapacity: Int = Broadcast<TurnEvent>.defaultBufferCapacity, replyGate: Duration = .zero, maxContextPieces: Int = 16, bargeWindow: Duration = .zero, maxMemoryTurns: Int = 8, maxMemoryCharacters: Int = 600 )
  Conversation/TurnCoordinator+Config.swift: public func validate() throws(TurnCoordinatorConfigurationError)
  Conversation/TurnCoordinator+Config.swift: public enum TurnCoordinatorConfigurationError: Error, Sendable, Equatable, CustomStringConvertible
  Conversation/TurnCoordinator+Config.swift: public var description: String
  Conversation/TurnCoordinator.swift: public enum BargeWindow
  Conversation/TurnCoordinator.swift: public static let measured = Duration.milliseconds(600)
  Conversation/TurnCoordinator.swift: public actor TurnCoordinator<C: Clock> where C.Duration == Duration
  Conversation/TurnCoordinator.swift: public init( replyGenerator: any ReplyGenerating, synthesizer: any SpeechSynthesizing, config: Config = Config(), clock: C, latencyReporter: any LatencyReporter, diagnostics: PipelineDiagnostics? = nil ) throws(TurnCoordinatorConfigurationError)
  Conversation/TurnCoordinator.swift: public init( replyGenerator: any ReplyGenerating, synthesizer: any SpeechSynthesizing, config: Config = Config(), diagnostics: PipelineDiagnostics? = nil ) throws(TurnCoordinatorConfigurationError) where C == ContinuousClock
  Conversation/TurnCoordinator.swift: public var currentState: TurnState
  Conversation/TurnCoordinator.swift: public var currentUtterance: Int
  Conversation/TurnCoordinator.swift: public var currentContext: String
  Conversation/TurnCoordinator.swift: public var currentMemory: [ConversationTurn]
  Conversation/TurnCoordinator.swift: public func clearMemory()
  Conversation/TurnCoordinator.swift: public func listen() -> Broadcast<TurnEvent>.Listener
  Conversation/TurnCoordinator.swift: public func run( audio: AsyncStream<AudioEvent>, transcripts: AsyncStream<TranscriptEvent> ) async
  Conversation/TurnCoordinator.swift: public func interrupt() async
  Conversation/TurnCoordinator.swift: public func resume()
  Conversation/TurnCoordinator.swift: public func stop() async
  Diagnostics/MemoryHeadroom.swift: public enum MemoryHeadroom: Sendable, Equatable
  Diagnostics/MemoryHeadroom.swift: public enum Reason: Sendable, Equatable
  Diagnostics/MemoryHeadroom.swift: public var megabytes: Int?
  Diagnostics/MemoryHeadroom.swift: public var bytes: Int?
  Diagnostics/MemoryHeadroom.swift: public var isMeasuring: Bool
  Diagnostics/MemoryHeadroom.swift: public enum MemoryHeadroomReader
  Diagnostics/MemoryHeadroom.swift: public static func read() -> MemoryHeadroom
  Diagnostics/MemoryHeadroom.swift: public final class MemoryPressureMonitor: @unchecked Sendable
  Diagnostics/MemoryHeadroom.swift: public enum Level: Sendable, Equatable
  Diagnostics/MemoryHeadroom.swift: public init(queue: DispatchQueue = .global(qos: .utility), onChange: @escaping @Sendable (Level) -> Void)
  Diagnostics/PipelineDiagnostics.swift: public enum HealthEvent: Sendable, Equatable
  Diagnostics/PipelineDiagnostics.swift: public final class PipelineDiagnostics: Sendable
  Diagnostics/PipelineDiagnostics.swift: public let signposts = PipelineSignposter()
  Diagnostics/PipelineDiagnostics.swift: public init( thermal: any ThermalStateProviding = SystemThermalProvider(), healthBufferCapacity: Int = Broadcast<HealthEvent>.defaultBufferCapacity )
  Diagnostics/PipelineDiagnostics.swift: public func health() -> Broadcast<HealthEvent>.Listener
  Diagnostics/PipelineDiagnostics.swift: public func run() async
  Diagnostics/PipelineDiagnostics.swift: public func stop()
  Diagnostics/PipelineDiagnostics.swift: public func noteRingDrop(frames: Int, at: AudioTime)
  Diagnostics/PipelineDiagnostics.swift: public func noteSettlingDecodes(count: Int)
  Diagnostics/PipelineDiagnostics.swift: public func noteSettlingRefusal(utterance: Int, thermal: ThermalState)
  Diagnostics/PipelineDiagnostics.swift: public func noteListenerLoss(listenerID: Int, totalDropped: Int)
  Diagnostics/PipelineDiagnostics.swift: public func noteTurnFailed(turn: Int, failure: TurnFailure)
  Diagnostics/PipelineSignposter.swift: public struct PipelineSignposter: Sendable
  Diagnostics/PipelineSignposter.swift: public struct Span
  Diagnostics/PipelineSignposter.swift: public func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T
  Diagnostics/PipelineSignposter.swift: public func measure<T: Sendable>( _ name: StaticString, _ body: () async throws -> T ) async rethrows -> T
  Diagnostics/PipelineSignposter.swift: public func begin(_ name: StaticString) -> Span
  Diagnostics/PipelineSignposter.swift: public func end(_ span: Span)
  Diagnostics/Thermal.swift: public enum ThermalState: Sendable, Equatable, Comparable
  Diagnostics/Thermal.swift: public protocol ThermalStateProviding: Sendable
  Diagnostics/Thermal.swift: public struct SystemThermalProvider: ThermalStateProviding
  Diagnostics/Thermal.swift: public init()
  Diagnostics/Thermal.swift: public var current: ThermalState
  Diagnostics/Thermal.swift: public func transitions() -> AsyncStream<ThermalState>
  Diagnostics/ThermalPolicy.swift: public protocol ThermalPolicy: Sendable
  Diagnostics/ThermalPolicy.swift: public struct ConservativeThermalPolicy: ThermalPolicy
  Diagnostics/ThermalPolicy.swift: public init()
  Diagnostics/ThermalPolicy.swift: public func allowSettlingDecode(thermal: ThermalState, activeSettlingDecodes: Int) -> Bool
  Diagnostics/ThermalPolicy.swift: public protocol GenerationThermalPolicy: Sendable
  Diagnostics/ThermalPolicy.swift: public struct DefaultGenerationThermalPolicy: GenerationThermalPolicy
  Diagnostics/ThermalPolicy.swift: public init()
  Diagnostics/ThermalPolicy.swift: public func allowGeneration(thermal: ThermalState) -> Bool
  Models/ModelBacked.swift: public protocol ModelBacked: Sendable
  Runtime/AIRuntime.swift: public struct AIRuntime<C: Clock>: Sendable where C.Duration == Duration
  Runtime/AIRuntime.swift: public struct Configuration: Sendable
  Runtime/AIRuntime.swift: public var consumer: AudioRingConsumer
  Runtime/AIRuntime.swift: public var vad: any VoiceActivityDetecting
  Runtime/AIRuntime.swift: public var ear: any TranscriptionEngine
  Runtime/AIRuntime.swift: public var mind: (any ReplyGenerating)?
  Runtime/AIRuntime.swift: public var mouth: (any SpeechSynthesizing)?
  Runtime/AIRuntime.swift: public var pump: AudioPump<C>.Config
  Runtime/AIRuntime.swift: public var transcription: TranscriptionSession.Config
  Runtime/AIRuntime.swift: public var turns: TurnCoordinator<C>.Config
  Runtime/AIRuntime.swift: public var clock: C
  Runtime/AIRuntime.swift: public var diagnostics: PipelineDiagnostics?
  Runtime/AIRuntime.swift: public var thermalPolicy: (any ThermalPolicy)?
  Runtime/AIRuntime.swift: public var latencyReporter: (any LatencyReporter)?
  Runtime/AIRuntime.swift: public var stopRendering: (@Sendable () async -> Void)?
  Runtime/AIRuntime.swift: public var releaseSource: @Sendable () async -> Void
  Runtime/AIRuntime.swift: public init( consumer: AudioRingConsumer, vad: any VoiceActivityDetecting, ear: any TranscriptionEngine, mind: (any ReplyGenerating)? = nil, mouth: (any SpeechSynthesizing)? = nil, pump: AudioPump<C>.Config, transcription: TranscriptionSession.Config, turns: TurnCoordinator<C>.Config, clock: C, diagnostics: PipelineDiagnostics? = nil, thermalPolicy: (any ThermalPolicy)? = nil, latencyReporter: (any LatencyReporter)? = nil, stopRendering: (@Sendable () async -> Void)? = nil, releaseSource: @escaping @Sendable () async -> Void )
  Runtime/AIRuntime.swift: public struct Session: Sendable
  Runtime/AIRuntime.swift: public let audio: Broadcast<AudioEvent>.Listener
  Runtime/AIRuntime.swift: public let transcripts: Broadcast<TranscriptEvent>.Listener
  Runtime/AIRuntime.swift: public let turns: Broadcast<TurnEvent>.Listener?
  Runtime/AIRuntime.swift: public let health: Broadcast<HealthEvent>.Listener?
  Runtime/AIRuntime.swift: public let conversation: TurnCoordinator<C>?
  Runtime/AIRuntime.swift: public typealias ConfigurationError = AIRuntimeConfigurationError
  Runtime/AIRuntime.swift: public let configuration: Configuration
  Runtime/AIRuntime.swift: public init(_ configuration: Configuration) throws(ConfigurationError)
  Runtime/AIRuntime.swift: public func run(observing observe: @escaping @Sendable (Session) async -> Void) async
  Runtime/AIRuntime.swift: public enum AIRuntimeConfigurationError: Error, Sendable, Equatable, CustomStringConvertible
  Runtime/AIRuntime.swift: public var description: String
  Transcription/AppleSpeechEngine.swift: public final class AppleSpeechEngine: TranscriptionEngine, ModelBacked, Sendable
  Transcription/AppleSpeechEngine.swift: public let capabilities = EngineCapabilities(emitsPartials: true)
  Transcription/AppleSpeechEngine.swift: public init(locale: Locale = Locale(identifier: "en_US"), diagnostics: PipelineDiagnostics? = nil)
  Transcription/AppleSpeechEngine.swift: public func modelInstalled() async -> Bool
  Transcription/AppleSpeechEngine.swift: public func ensureModel() async throws
  Transcription/AppleSpeechEngine.swift: public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun
  Transcription/TranscriptionEngine.swift: public struct AudioStreamFormat: Sendable, Equatable
  Transcription/TranscriptionEngine.swift: public var sampleRate: Double
  Transcription/TranscriptionEngine.swift: public var channels: Int
  Transcription/TranscriptionEngine.swift: public init(sampleRate: Double = 48_000, channels: Int = 1)
  Transcription/TranscriptionEngine.swift: public struct EngineCapabilities: Sendable, Equatable
  Transcription/TranscriptionEngine.swift: public var emitsPartials: Bool
  Transcription/TranscriptionEngine.swift: public var wantsWholeUtterance: Bool
  Transcription/TranscriptionEngine.swift: public var requiredSampleRate: Double?
  Transcription/TranscriptionEngine.swift: public var maximumUtterance: Duration?
  Transcription/TranscriptionEngine.swift: public init( emitsPartials: Bool, wantsWholeUtterance: Bool = false, requiredSampleRate: Double? = nil, maximumUtterance: Duration? = nil )
  Transcription/TranscriptionEngine.swift: public enum TranscriptionFailure: Error, Sendable, Equatable
  Transcription/TranscriptionEngine.swift: public enum TranscriptionUpdate: Sendable, Equatable
  Transcription/TranscriptionEngine.swift: public protocol TranscriptionRun: Sendable
  Transcription/TranscriptionEngine.swift: public protocol TranscriptionEngine: Sendable
  Transcription/TranscriptionEngine.swift: public enum TranscriptEvent: Sendable, Equatable
  Transcription/TranscriptionSession+Config.swift: public struct Config: Sendable
  Transcription/TranscriptionSession+Config.swift: public var format: AudioStreamFormat
  Transcription/TranscriptionSession+Config.swift: public var maximumUtterance: Duration
  Transcription/TranscriptionSession+Config.swift: public var listenerBufferCapacity: Int
  Transcription/TranscriptionSession+Config.swift: public init( format: AudioStreamFormat = AudioStreamFormat(), maximumUtterance: Duration = .seconds(30), listenerBufferCapacity: Int = Broadcast<TranscriptEvent>.defaultBufferCapacity )
  Transcription/TranscriptionSession.swift: public actor TranscriptionSession
  Transcription/TranscriptionSession.swift: public init( engine: any TranscriptionEngine, config: Config = Config(), diagnostics: PipelineDiagnostics? = nil, thermalPolicy: (any ThermalPolicy)? = nil )
  Transcription/TranscriptionSession.swift: public func listen() -> Broadcast<TranscriptEvent>.Listener
  Transcription/TranscriptionSession.swift: public func run(events: AsyncStream<AudioEvent>) async
  Transcription/TranscriptionSession.swift: public func stop() async

## MultiModalKitMLX
  LocalMind+Admission.swift: public func admit(needing bytes: Int) async throws
  LocalMind.swift: public actor LocalMindModel: ModelBacked
  LocalMind.swift: public nonisolated let weights: URL
  LocalMind.swift: public nonisolated let repoID: String?
  LocalMind.swift: public nonisolated let cacheLimitBytes: Int
  LocalMind.swift: public init(weights: URL, cacheLimitBytes: Int = 20 * 1024 * 1024, headroom: @escaping HeadroomReading = MemoryHeadroomReader.read, pressure: any MemoryPressureSourcing = SystemMemoryPressureSource())
  LocalMind.swift: public init(repoID: String, in directory: URL = URL.documentsDirectory, cacheLimitBytes: Int = 20 * 1024 * 1024, headroom: @escaping HeadroomReading = MemoryHeadroomReader.read, pressure: any MemoryPressureSourcing = SystemMemoryPressureSource())
  LocalMind.swift: public nonisolated func modelInstalled() -> Bool
  LocalMind.swift: public func ensureModel() async throws
  LocalMind.swift: public func ensureModelLoaded() async throws -> ModelContainer
  LocalMind.swift: public var isResident: Bool
  LocalMind.swift: public func retire() async
  LocalMind.swift: public func prewarm()
  LocalMind.swift: public init(model: LocalMindModel, instructions: String? = nil, maxTokens: Int = 1024, tools: ToolTable = .empty, thermal: any ThermalStateProviding = SystemThermalProvider(), thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(), clock: any Clock<Duration> = ContinuousClock()) throws(ToolDeclarationError)
  LocalMindInstall.swift: public struct InstallProgress: Sendable, Equatable
  LocalMindInstall.swift: public var fraction: Double
  LocalMindInstall.swift: public var bytesReceived: Int64?
  LocalMindInstall.swift: public var bytesExpected: Int64?
  LocalMindInstall.swift: public init(fraction: Double, bytesReceived: Int64?, bytesExpected: Int64?)
  LocalMindInstall.swift: public static func at(fraction: Double, bytesExpected: Int64?) -> InstallProgress
  LocalMindInstall.swift: public nonisolated func installState() -> InstallState
  LocalMindInstall.swift: public nonisolated func estimatedWorkingSetBytes() -> Int
  LocalMindInstall.swift: public nonisolated func readiness() -> MindUnavailable?
  LocalMindInstall.swift: public func download( reporting progress: @escaping @Sendable (InstallProgress) -> Void ) async throws
  LocalMindInstall.swift: public func download( reporting progress: @escaping @Sendable (InstallProgress) -> Void, using fetcher: some WeightsFetching ) async throws
  LocalMindInstall.swift: public func download( progress: @escaping @Sendable (Double) -> Void =
  LocalMindInstallSize.swift: public struct InstallSize: Sendable, Equatable
  LocalMindInstallSize.swift: public struct FileSize: Sendable, Equatable
  LocalMindInstallSize.swift: public let name: String
  LocalMindInstallSize.swift: public let bytes: Int64
  LocalMindInstallSize.swift: public init(name: String, bytes: Int64)
  LocalMindInstallSize.swift: public let downloadBytes: Int64
  LocalMindInstallSize.swift: public let onDiskBytes: Int64
  LocalMindInstallSize.swift: public let files: [FileSize]
  LocalMindInstallSize.swift: public init(files: [FileSize])
  LocalMindInstallSize.swift: public func expectedInstall() async throws -> InstallSize
  MLXReplyGenerator.swift: public struct MLXReplyGenerator: ReplyGenerating
  MLXReplyGenerator.swift: public func openReply(to context: ReplyContext) async throws -> any ReplyRun
  MLXRuntime.swift: public enum MLXRuntime
  MLXRuntime.swift: public static func metallibURL() -> URL?
  MLXRuntime.swift: public static var activeMemoryBytes: Int
  MLXRuntime.swift: public static var peakMemoryBytes: Int
  MLXRuntime.swift: public static var cacheMemoryBytes: Int
  MLXRuntime.swift: public static func resetPeakMemory()
  MLXRuntime.swift: public static var isAvailable: Bool
  MindPressure.swift: public typealias HeadroomReading = @Sendable () -> MemoryHeadroom
  MindPressure.swift: public protocol MemoryPressureSourcing: Sendable
  MindPressure.swift: public final class MemoryPressureSubscription: Sendable
  MindPressure.swift: public init(cancel: @escaping @Sendable () -> Void)
  MindPressure.swift: public func cancel()
  MindPressure.swift: public struct SystemMemoryPressureSource: MemoryPressureSourcing
  MindPressure.swift: public init()
  MindPressure.swift: public func subscribe( onChange: @escaping @Sendable (MemoryPressureMonitor.Level) -> Void ) -> MemoryPressureSubscription
  WeightsFetching.swift: public protocol WeightsFetching: Sendable
  WeightsFetching.swift: public struct HubWeightsFetcher: WeightsFetching
  WeightsFetching.swift: public init()
  WeightsFetching.swift: public func fetch(repoID: String, into base: URL, reporting progress: @escaping @Sendable (Double) -> Void) async throws -> URL
  WeightsFetching.swift: public enum InstallFailure: Error, Sendable, Equatable, CustomStringConvertible
  WeightsFetching.swift: public var description: String

## MultiModalKitTTS
  Decode/AdaptiveLead.swift: public final class AdaptiveLead: Sendable
  Decode/AdaptiveLead.swift: public init()
  Decode/AdaptiveLead.swift: public var target: Duration?
  Decode/AdaptiveLead.swift: public func observe(_ margin: DecodeMargin)
  Decode/AdaptiveLead.swift: public var typicalLength: Duration?
  Decode/AdaptiveLead.swift: public func forget()
  Decode/DecodeMargin.swift: public struct DecodeMargin: Sendable, Equatable
  Decode/DecodeMargin.swift: public let audioMilliseconds: Double
  Decode/DecodeMargin.swift: public let wallMilliseconds: Double
  Decode/DecodeMargin.swift: public let prefillMilliseconds: Double
  Decode/DecodeMargin.swift: public let steadyRealTimeFactor: Double?
  Decode/DecodeMargin.swift: public var realTimeFactor: Double
  Decode/DecodeMargin.swift: public let firstDecodeMilliseconds: Double?
  Decode/DecodeMargin.swift: public var keepsUp: Bool
  Decode/DecodeMargin.swift: public let completed: Bool
  Decode/DecodeMargin.swift: public let cushionMilliseconds: Double?
  Decode/DecodeMargin.swift: public let requiredCushionMilliseconds: Double?
  Decode/DecodeMargin.swift: public let firstStepAudioMilliseconds: Double?
  Decode/DecodeSteps.swift: public struct DecodeStep: Sendable, Equatable
  Decode/DecodeSteps.swift: public let wallMilliseconds: Double
  Decode/DecodeSteps.swift: public let audioMilliseconds: Double
  Decode/DecodeSteps.swift: public init(wallMilliseconds: Double, audioMilliseconds: Double)
  Decode/DecodeSteps.swift: public enum DecodeDeficit
  Decode/DecodeSteps.swift: public static func requiredStart(steps: some Sequence<DecodeStep>) -> Double
  Decode/DecodeSteps.swift: public static func cushion(steps: some Sequence<DecodeStep>) -> Double
  Decode/KokoroWeights.swift: public struct KokoroWeights: Sendable
  Decode/KokoroWeights.swift: public enum Precision: String, Sendable, CaseIterable
  Decode/KokoroWeights.swift: public static let sourceURL = URL( string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/kokoro-v1_0.safetensors")!
  Decode/KokoroWeights.swift: public static let voiceURL = URL( string: "https://huggingface.co/prince-canuma/Kokoro-82M/resolve/main/voices/af_heart.safetensors")!
  Decode/KokoroWeights.swift: public static let sourceBytes = 327_115_152
  Decode/KokoroWeights.swift: public static let voiceBytes = 522_339
  Decode/KokoroWeights.swift: public let directory: URL
  Decode/KokoroWeights.swift: public let precision: Precision
  Decode/KokoroWeights.swift: public init(directory: URL, precision: Precision = .float16)
  Decode/KokoroWeights.swift: public static func inApplicationSupport(precision: Precision = .float16) -> KokoroWeights
  Decode/KokoroWeights.swift: public func isInstalled() -> Bool
  Decode/KokoroWeights.swift: public func damagedReport() -> String?
  Decode/KokoroWeights.swift: public func missingReport() -> String?
  Decode/KokoroWeights.swift: public func ensure(progress: @escaping @Sendable (Double) -> Void =
  Decode/KokoroWeights.swift: public enum KokoroWeightsFailure: Error, CustomStringConvertible, Equatable
  Decode/KokoroWeights.swift: public var description: String
  Voice/KokoroVoice.swift: public struct KokoroColdStart: Sendable, Equatable
  Voice/KokoroVoice.swift: public struct Decode: Sendable, Equatable
  Voice/KokoroVoice.swift: public let wallMilliseconds: Double
  Voice/KokoroVoice.swift: public let audioMilliseconds: Double
  Voice/KokoroVoice.swift: public let firstPhrase: Phrase?
  Voice/KokoroVoice.swift: public var realTimeFactor: Double
  Voice/KokoroVoice.swift: public struct Phrase: Sendable, Equatable
  Voice/KokoroVoice.swift: public let wallMilliseconds: Double
  Voice/KokoroVoice.swift: public let audioMilliseconds: Double
  Voice/KokoroVoice.swift: public let decodeMilliseconds: Double?
  Voice/KokoroVoice.swift: public var realTimeFactor: Double
  Voice/KokoroVoice.swift: public var decodeRealTimeFactor: Double?
  Voice/KokoroVoice.swift: public var waitedForTextMilliseconds: Double?
  Voice/KokoroVoice.swift: public var loadMilliseconds: Double?
  Voice/KokoroVoice.swift: public var warmUpMilliseconds: Double?
  Voice/KokoroVoice.swift: public var first: Decode?
  Voice/KokoroVoice.swift: public var second: Decode?
  Voice/KokoroVoice.swift: public var decodes = 0
  Voice/KokoroVoice.swift: public init()
  Voice/KokoroVoice.swift: public actor KokoroVoice: SpokenVoice
  Voice/KokoroVoice.swift: public static let phraseCharacters = 120
  Voice/KokoroVoice.swift: public init(weights: KokoroWeights, lead: Duration = .zero, phraseCharacters: Int = KokoroVoice.phraseCharacters)
  Voice/KokoroVoice.swift: public func modelInstalled() async -> Bool
  Voice/KokoroVoice.swift: public nonisolated func installationProblem() -> String?
  Voice/KokoroVoice.swift: public func ensureModel() async throws
  Voice/KokoroVoice.swift: public nonisolated var coldStart: KokoroColdStart
  Voice/KokoroVoice.swift: public func ensureModel(progress: @escaping @Sendable (Double) -> Void) async throws
  Voice/KokoroVoice.swift: public func render(on host: any PlaybackHost)
  Voice/KokoroVoice.swift: public func shutdown()
  Voice/KokoroVoice.swift: public func reportMargins(to handler: @escaping @Sendable (DecodeMargin) -> Void)
  Voice/KokoroVoice.swift: public func retire() async
  Voice/KokoroVoice.swift: public func openUtterance() async throws -> any SynthesisRun
  Voice/KokoroVoice.swift: public struct KokoroVoiceRetired: Error, CustomStringConvertible
  Voice/KokoroVoice.swift: public var description: String
  Voice/KokoroVoice.swift: public nonisolated var inForce: String
  Voice/NeuralVoice+Lead.swift: public nonisolated static let measuredRealTimeFactor = 0.752
  Voice/NeuralVoice+Lead.swift: public nonisolated static let defaultLead = PlaybackLead.deficit( forReplyOf: .seconds(6), realTimeFactor: measuredRealTimeFactor)
  Voice/NeuralVoice+Lead.swift: public nonisolated static func measuredRealTimeFactor( for mode: Qwen3MultiCodeDecoderMode ) -> Double
  Voice/NeuralVoice+Lead.swift: public nonisolated static func defaultLead( for mode: Qwen3MultiCodeDecoderMode ) -> Duration
  Voice/NeuralVoice+ModelAssets.swift: public nonisolated func modelInstalled() async -> Bool
  Voice/NeuralVoice.swift: public actor NeuralVoice: SpokenVoice
  Voice/NeuralVoice.swift: public nonisolated let variant: TTSModelVariant
  Voice/NeuralVoice.swift: public private(set) var isRetired = false
  Voice/NeuralVoice.swift: public nonisolated let lead: Duration
  Voice/NeuralVoice.swift: public nonisolated var currentLead: Duration
  Voice/NeuralVoice.swift: public nonisolated let multiCodeDecoderMode: Qwen3MultiCodeDecoderMode
  Voice/NeuralVoice.swift: public nonisolated let speechDecoderMode: Qwen3SpeechDecoderMode
  Voice/NeuralVoice.swift: public nonisolated let temperature: Float?
  Voice/NeuralVoice.swift: public nonisolated let seed: UInt64?
  Voice/NeuralVoice.swift: public init(variant: TTSModelVariant = .qwen3TTS_0_6b, renderingOn host: (any PlaybackHost)? = nil, lead: Duration? = nil, multiCodeDecoderMode: Qwen3MultiCodeDecoderMode = .fused, speechDecoderMode: Qwen3SpeechDecoderMode = .latencyOptimized, temperature: Float? = nil, seed: UInt64? = nil, availableOnThisPlatform: Bool? = nil)
  Voice/NeuralVoice.swift: public func reportMargins(to handler: @escaping @Sendable (DecodeMargin) -> Void)
  Voice/NeuralVoice.swift: public func shutdown()
  Voice/NeuralVoice.swift: public func render(on host: any PlaybackHost)
  Voice/NeuralVoice.swift: public func openUtterance() async throws -> any SynthesisRun
  Voice/NeuralVoice.swift: public func ensureModel() async throws
  Voice/NeuralVoice.swift: public func retire() async
  Voice/NeuralVoiceErrors.swift: public struct NeuralVoiceUnavailableOnPlatform: Error, CustomStringConvertible
  Voice/NeuralVoiceErrors.swift: public let variant: TTSModelVariant
  Voice/NeuralVoiceErrors.swift: public init(variant: TTSModelVariant)
  Voice/NeuralVoiceErrors.swift: public var description: String
  Voice/NeuralVoiceErrors.swift: public struct NeuralVoiceRetired: Error, CustomStringConvertible
  Voice/NeuralVoiceErrors.swift: public init()
  Voice/NeuralVoiceErrors.swift: public var description: String
  Voice/SpokenVoice.swift: public protocol SpokenVoice: SpeechSynthesizing, ModelBacked
  Voice/VoiceLevers.swift: public struct VoiceLevers: Sendable, Equatable
  Voice/VoiceLevers.swift: public enum Voice: String, Sendable, CaseIterable
  Voice/VoiceLevers.swift: public var label: String
  Voice/VoiceLevers.swift: public var voice: Voice
  Voice/VoiceLevers.swift: public var model: TTSModelVariant
  Voice/VoiceLevers.swift: public var decoder: Qwen3MultiCodeDecoderMode
  Voice/VoiceLevers.swift: public var vocoder: Qwen3SpeechDecoderMode
  Voice/VoiceLevers.swift: public var temperature: Float?
  Voice/VoiceLevers.swift: public var lead: Duration?
  Voice/VoiceLevers.swift: public init(voice: Voice = .kokoro, model: TTSModelVariant = .qwen3TTS_0_6b, decoder: Qwen3MultiCodeDecoderMode = .fused, vocoder: Qwen3SpeechDecoderMode = .latencyOptimized, temperature: Float? = nil, lead: Duration? = nil)
  Voice/VoiceLevers.swift: public static let phoneDefault = VoiceLevers(decoder: .stepped, vocoder: .throughputOptimized)
  Voice/VoiceLevers.swift: public func makeSpokenVoice( kokoroWeights: KokoroWeights = .inApplicationSupport() ) -> any SpokenVoice
  Voice/VoiceLevers.swift: public func makeVoice() -> NeuralVoice
  Voice/VoiceLevers.swift: public struct FlagError: Error, Equatable
  Voice/VoiceLevers.swift: public let flag: String
  Voice/VoiceLevers.swift: public let given: String
  Voice/VoiceLevers.swift: public let allowed: String
  Voice/VoiceLevers.swift: public var message: String
  Voice/VoiceLevers.swift: public static func parsed(fromArguments arguments: [String], base: VoiceLevers = VoiceLevers()) throws -> VoiceLevers
  Voice/VoiceLevers.swift: public nonisolated var inForce: String

## MultiModalKitWhisper
  WhisperEngine.swift: public actor WhisperEngine: TranscriptionEngine, ModelBacked
  WhisperEngine.swift: public nonisolated let capabilities = EngineCapabilities( emitsPartials: false, wantsWholeUtterance: true, requiredSampleRate: 16_000 )
  WhisperEngine.swift: public nonisolated let language: String?
  WhisperEngine.swift: public init(model: String = "base", language: String? = nil, diagnostics: PipelineDiagnostics? = nil)
  WhisperEngine.swift: public nonisolated func modelInstalled() async -> Bool
  WhisperEngine.swift: public func ensureModel() async throws
  WhisperEngine.swift: public nonisolated func prewarm()
  WhisperEngine.swift: public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun

## MultiModalKitTesting
  BakeoffHarness.swift: public struct BakeoffMeasurement: Sendable
  BakeoffHarness.swift: public let engineName: String
  BakeoffHarness.swift: public let text: String
  BakeoffHarness.swift: public let score: WordErrorRate.Score
  BakeoffHarness.swift: public let decodeSeconds: Double
  BakeoffHarness.swift: public init(engineName: String, text: String, score: WordErrorRate.Score, decodeSeconds: Double)
  BakeoffHarness.swift: public enum BakeoffHarness
  BakeoffHarness.swift: public static func loadAudio(_ url: URL) throws -> (samples: [Float], sampleRate: Double)
  BakeoffHarness.swift: public static func measure( engine: any TranscriptionEngine, label: String, samples: [Float], sampleRate: Double, reference: String ) async throws -> BakeoffMeasurement
  FakeMicrophone.swift: public final class FakeMicrophone: AudioSource
  FakeMicrophone.swift: public init()
  FakeMicrophone.swift: public func start(into producer: AudioRingProducer) throws
  FakeMicrophone.swift: public func stop()
  FakeMicrophone.swift: public func emit(_ samples: [Float])
  ManualClock.swift: public final class ManualClock: Clock, Sendable
  ManualClock.swift: public struct Instant: InstantProtocol, Sendable, Hashable, CustomStringConvertible
  ManualClock.swift: public var offset: Duration
  ManualClock.swift: public init(offset: Duration = .zero)
  ManualClock.swift: public func advanced(by duration: Duration) -> Instant
  ManualClock.swift: public func duration(to other: Instant) -> Duration
  ManualClock.swift: public static func < (lhs: Instant, rhs: Instant) -> Bool
  ManualClock.swift: public var description: String
  ManualClock.swift: public init()
  ManualClock.swift: public var now: Instant
  ManualClock.swift: public var minimumResolution: Duration
  ManualClock.swift: public var sleeperCount: Int
  ManualClock.swift: public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws
  ManualClock.swift: public func advance(by duration: Duration) async
  ManualClock.swift: public func advance(to target: Instant) async
  ManualClock.swift: public func waitForSleepers(atLeast threshold: Int) async -> Bool
  ScriptedReplyGenerator.swift: public final class ScriptedReplyGenerator: ReplyGenerating, Sendable
  ScriptedReplyGenerator.swift: public enum Plan: Sendable
  ScriptedReplyGenerator.swift: public struct ReplyRecord: Sendable
  ScriptedReplyGenerator.swift: public var context: ReplyContext
  ScriptedReplyGenerator.swift: public var cancelled = false
  ScriptedReplyGenerator.swift: public var toolCalls: [ToolCallRecord] = []
  ScriptedReplyGenerator.swift: public var transcript: String
  ScriptedReplyGenerator.swift: public var history: [ConversationTurn]
  ScriptedReplyGenerator.swift: public let tools: ToolTable
  ScriptedReplyGenerator.swift: public let thermal: any ThermalStateProviding
  ScriptedReplyGenerator.swift: public let thermalPolicy: any GenerationThermalPolicy
  ScriptedReplyGenerator.swift: public let clock: any Clock<Duration>
  ScriptedReplyGenerator.swift: public init(plans: [Plan], tools: ToolTable = .empty, thermal: any ThermalStateProviding = ScriptedThermalProvider(initial: .nominal), thermalPolicy: any GenerationThermalPolicy = DefaultGenerationThermalPolicy(), clock: any Clock<Duration> = ContinuousClock())
  ScriptedReplyGenerator.swift: public static func manual(replies: Int) -> ScriptedReplyGenerator
  ScriptedReplyGenerator.swift: public var repliesOpened: Int
  ScriptedReplyGenerator.swift: public var heatRefusals: [ThermalState]
  ScriptedReplyGenerator.swift: public func record(ofReply index: Int) -> ReplyRecord?
  ScriptedReplyGenerator.swift: public func emit(reply index: Int, token: String)
  ScriptedReplyGenerator.swift: public func finish(reply index: Int, stop: StopReason = .complete)
  ScriptedReplyGenerator.swift: public func fail(reply index: Int, reason: String)
  ScriptedReplyGenerator.swift: public func fail(reply index: Int, with failure: ReplyFailure)
  ScriptedReplyGenerator.swift: public func forceToken(reply index: Int, token: String)
  ScriptedReplyGenerator.swift: public func forceFinished(reply index: Int)
  ScriptedReplyGenerator.swift: public func openReply(to context: ReplyContext) async throws -> any ReplyRun
  ScriptedReplyGenerator.swift: public func releaseOpen()
  ScriptedSynthesizer.swift: public final class ScriptedSynthesizer: SpeechSynthesizing, Sendable
  ScriptedSynthesizer.swift: public enum Plan: Sendable
  ScriptedSynthesizer.swift: public struct UtteranceRecord: Sendable
  ScriptedSynthesizer.swift: public var fedTokens: [String] = []
  ScriptedSynthesizer.swift: public var tokensFinished = false
  ScriptedSynthesizer.swift: public var cancelled = false
  ScriptedSynthesizer.swift: public init(plans: [Plan])
  ScriptedSynthesizer.swift: public static func manual(utterances: Int) -> ScriptedSynthesizer
  ScriptedSynthesizer.swift: public func releaseOpen()
  ScriptedSynthesizer.swift: public var utterancesOpened: Int
  ScriptedSynthesizer.swift: public func record(ofUtterance index: Int) -> UtteranceRecord?
  ScriptedSynthesizer.swift: public func reportStarted(utterance index: Int)
  ScriptedSynthesizer.swift: public func reportFinished(utterance index: Int)
  ScriptedSynthesizer.swift: public func reportFailed(utterance index: Int, reason: String)
  ScriptedSynthesizer.swift: public func forceUpdate(utterance index: Int, _ update: SynthesisUpdate)
  ScriptedSynthesizer.swift: public func openUtterance() async throws -> any SynthesisRun
  ScriptedThermalProvider.swift: public final class ScriptedThermalProvider: ThermalStateProviding, @unchecked Sendable
  ScriptedThermalProvider.swift: public init(initial: ThermalState = .nominal)
  ScriptedThermalProvider.swift: public var current: ThermalState
  ScriptedThermalProvider.swift: public func transitions() -> AsyncStream<ThermalState>
  ScriptedThermalProvider.swift: public func push(_ new: ThermalState)
  ScriptedThermalProvider.swift: public func finish()
  ScriptedTool.swift: public final class ScriptedTool: Sendable
  ScriptedTool.swift: public indirect enum Plan: Sendable
  ScriptedTool.swift: public struct ScriptedError: Error, CustomStringConvertible
  ScriptedTool.swift: public let description: String
  ScriptedTool.swift: public let name: String
  ScriptedTool.swift: public let description: String
  ScriptedTool.swift: public let parameters: [ToolParameter]
  ScriptedTool.swift: public let requiresConfirmation: Bool
  ScriptedTool.swift: public let plan: Plan
  ScriptedTool.swift: public init(name: String, description: String? = nil, parameters: [ToolParameter] = [], requiresConfirmation: Bool = false, plan: Plan, onEnter: @escaping @Sendable (ToolArguments) -> Void =
  ScriptedTool.swift: public var calls: [ToolArguments]
  ScriptedTool.swift: public func release()
  ScriptedTool.swift: public var tool: ReplyTool
  ScriptedTool.swift: public struct ToolScript: Sendable
  ScriptedTool.swift: public enum OnFailure: Sendable
  ScriptedTool.swift: public var name: String
  ScriptedTool.swift: public var arguments: ToolArguments
  ScriptedTool.swift: public var before: [String]
  ScriptedTool.swift: public var after: [String]
  ScriptedTool.swift: public var onFailure: OnFailure
  ScriptedTool.swift: public var ignoresCancel: Bool
  ScriptedTool.swift: public var whenDone: @Sendable () -> Void
  ScriptedTool.swift: public init(name: String, arguments: ToolArguments = .empty, before: [String] = [], after: [String] = [], onFailure: OnFailure = .failsReply, ignoresCancel: Bool = false, whenDone: @escaping @Sendable () -> Void =
  ScriptedTool.swift: public struct ToolCallRecord: Sendable, Equatable
  ScriptedTool.swift: public enum Outcome: Sendable, Equatable
  ScriptedTool.swift: public let name: String
  ScriptedTool.swift: public let arguments: ToolArguments
  ScriptedTool.swift: public var outcome: Outcome?
  ScriptedTool.swift: public var answerDropped = false
  ScriptedTool.swift: public init(name: String, arguments: ToolArguments = .empty, outcome: Outcome? = nil, answerDropped: Bool = false)
  ScriptedTranscriber.swift: public final class ScriptedTranscriber: TranscriptionEngine, Sendable
  ScriptedTranscriber.swift: public enum RunPlan: Sendable
  ScriptedTranscriber.swift: public struct RunRecord: Sendable
  ScriptedTranscriber.swift: public var fedChunks: [AudioChunk] = []
  ScriptedTranscriber.swift: public var audioFinished = false
  ScriptedTranscriber.swift: public var cancelled = false
  ScriptedTranscriber.swift: public var emittedFinal = false
  ScriptedTranscriber.swift: public let capabilities: EngineCapabilities
  ScriptedTranscriber.swift: public init( plans: [RunPlan], capabilities: EngineCapabilities = EngineCapabilities(emitsPartials: true) )
  ScriptedTranscriber.swift: public static func batch(runs: Int, manualRelease: Bool = true) -> ScriptedTranscriber
  ScriptedTranscriber.swift: public func releaseFinal(run index: Int)
  ScriptedTranscriber.swift: public var runsOpened: Int
  ScriptedTranscriber.swift: public func record(ofRun index: Int) -> RunRecord?
  ScriptedTranscriber.swift: public func forceFinal(run index: Int, text: String)
  ScriptedTranscriber.swift: public func openRun(format: AudioStreamFormat) async throws -> any TranscriptionRun
  WordErrorRate.swift: public enum WordErrorRate
  WordErrorRate.swift: public struct Score: Sendable, Equatable
  WordErrorRate.swift: public let referenceWords: Int
  WordErrorRate.swift: public let substitutions: Int
  WordErrorRate.swift: public let insertions: Int
  WordErrorRate.swift: public let deletions: Int
  WordErrorRate.swift: public var wer: Double
  WordErrorRate.swift: public static func normalize(_ text: String) -> [String]
  WordErrorRate.swift: public static func score(reference: String, hypothesis: String) -> Score
```
