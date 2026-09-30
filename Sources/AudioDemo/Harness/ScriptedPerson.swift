import AVFAudio
import Foundation
import MultiModalKit
import Synchronization

// THE SCRIPTED PERSON (5d, SPEC §225/4; F-28 A). Ryad's own recorded voice
// (`Fixtures/ryad-en.wav`), cut into sentences where he paused, said into
// the ring at the pace of real time — the next sentence once the answer has
// ended, or, on cue, over the answer. The same run can be repeated exactly,
// before and after every fix.
//
// It is a person without ears or a room: its voice reaches the ring
// digitally, so it can never produce an echo. The loudspeaker's path stays
// with the live microphone and with the phone.

/// The recording, cut where the speaker paused.
enum Sentences {
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// Reads `url` (mono PCM) and cuts it with the library's own VAD, so a
    /// "sentence" is roughly what the pipeline would hear as one utterance:
    /// a pause of 350 ms or more ends one. 200 ms of air is kept before
    /// each sentence, and the quiet tail the VAD waited through after it.
    static func cut(_ url: URL, threshold: Float = 0.02) throws -> (rate: Double, sentences: [[Float]]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Unreadable(description: "\(url.lastPathComponent): expected one channel of PCM")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw Unreadable(description: "\(url.lastPathComponent): no samples")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = format.sampleRate
        let chunk = Int(rate * 0.02)
        var vad = EnergyVAD(config: .init(threshold: threshold, hangoverFrames: Int(rate * 0.35)))
        var sentences: [[Float]] = []
        var start: Int?
        var index = 0
        while index + chunk <= samples.count {
            switch vad.process(Array(samples[index..<index + chunk])) {
            case .speechStarted: start = max(0, index - chunk * 10)
            case .speechEnded:
                if let from = start { sentences.append(Array(samples[from..<index + chunk])) }
                start = nil
            case nil: break
            }
            index += chunk
        }
        if let from = start { sentences.append(Array(samples[from...])) }
        return (rate, sentences)
    }
}

/// The person's mouth: the sentence being said, handed to the ring 20 ms at
/// a time by `feed`, and silence between sentences — as a microphone would.
actor Mouthpiece {
    private var sentence: [Float] = []
    private var cursor = 0
    private var said: CheckedContinuation<Void, Never>?

    /// Says `samples`; returns once the last of them is in the ring (or the
    /// run is cancelled).
    func say(_ samples: [Float]) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume() }
                sentence = samples
                cursor = 0
                said = continuation
            }
        } onCancel: {
            // Demo-tier liberty (D-016): the hop back onto the actor.
            Task { await self.hush() }
        }
    }

    private func hush() {
        sentence = []
        cursor = 0
        said?.resume()
        said = nil
    }

    /// The next `count` samples: the sentence if one is being said, silence
    /// otherwise.
    func next(_ count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard cursor < sentence.count else { return out }
        let end = min(cursor + count, sentence.count)
        out.replaceSubrange(0..<(end - cursor), with: sentence[cursor..<end])
        cursor = end
        if cursor == sentence.count { hush() }
        return out
    }
}

/// The person's voice reaching the "microphone": 20 ms every 20 ms, paced by
/// the real clock (the demo's liberty, D-016), until cancelled.
func feed(_ mouth: Mouthpiece, into producer: AudioRingProducer, rate: Double) async {
    let chunk = Int(rate * 0.02)
    let clock = ContinuousClock()
    var deadline = clock.now
    while !Task.isCancelled {
        let samples = await mouth.next(chunk)
        samples.withUnsafeBufferPointer { producer.write($0) }
        deadline = deadline.advanced(by: .milliseconds(20))
        do { try await clock.sleep(until: deadline) } catch { return }
    }
}

/// Every turn event, kept in order, and waited for by predicate with a
/// deadline — one waiter per wait, so a wait that times out takes nothing
/// down with it (the lesson of 5d's first red run, applied to the harness).
final class TurnWatch: Sendable {
    private struct Waiter {
        let from: Int
        let match: @Sendable (TurnEvent) -> Bool
        let continuation: CheckedContinuation<(TurnEvent, Int)?, Never>
    }
    private struct State {
        var seen: [TurnEvent] = []
        var waiters: [UInt64: Waiter] = [:]
        var cancelled: Set<UInt64> = []
        var nextID: UInt64 = 0
    }
    private let state = Mutex(State())

    var count: Int { state.withLock { $0.seen.count } }

    /// Keeps `event`, prints it, and answers every waiter it matches.
    func record(_ event: TurnEvent) {
        let answered = state.withLock { state -> [(CheckedContinuation<(TurnEvent, Int)?, Never>, Int)] in
            state.seen.append(event)
            let index = state.seen.count - 1
            let keys = state.waiters.filter { $0.value.from <= index && $0.value.match(event) }.map(\.key)
            return keys.compactMap { key in state.waiters.removeValue(forKey: key).map { ($0.continuation, index) } }
        }
        for (waiter, index) in answered { waiter.resume(returning: (event, index)) }
        if case .replyToken = event { return }          // a reply's words would flood the trace
        print("   · \(Self.describe(event))")
    }

    /// The first event at or after `from` that `match` accepts — or nil once
    /// `timeout` has passed.
    func first(from: Int, within timeout: Duration,
               where match: @escaping @Sendable (TurnEvent) -> Bool) async -> (event: TurnEvent, index: Int)? {
        let id = state.withLock { state -> UInt64 in
            defer { state.nextID += 1 }
            return state.nextID
        }
        return await withTaskGroup(of: (TurnEvent, Int)?.self) { group in
            group.addTask { await self.wait(id: id, from: from, match: match) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first.map { (event: $0.0, index: $0.1) }
        }
    }

    private func wait(id: UInt64, from: Int,
                      match: @escaping @Sendable (TurnEvent) -> Bool) async -> (TurnEvent, Int)? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(TurnEvent, Int)?, Never>) in
                let now = state.withLock { state -> (TurnEvent, Int)?? in
                    if let index = state.seen.indices.first(where: { $0 >= from && match(state.seen[$0]) }) {
                        return .some((state.seen[index], index))
                    }
                    if state.cancelled.remove(id) != nil { return .some(nil) }
                    state.waiters[id] = Waiter(from: from, match: match, continuation: continuation)
                    return .none
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<(TurnEvent, Int)?, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
                state.cancelled.insert(id)
                return nil
            }
            waiter?.resume(returning: nil)
        }
    }

    static func describe(_ event: TurnEvent) -> String {
        switch event {
        case .stateChanged(let state, let turn): "turn \(turn) \(state)"
        case .replyToken: "token"
        case .turnCompleted(let turn): "turn \(turn) completed"
        case .turnBarged(let turn): "turn \(turn) BARGED"
        case .turnFailed(let failure, let turn): "turn \(turn) FAILED: \(failure)"
        }
    }
}

/// What the person will say, and when it talks over the answer.
struct Script: Sendable {
    let sentences: [[Float]]
    let rate: Double
    let turns: Int
    let interruptAt: Set<Int>

    /// The sentence for turn `said`. An interruption takes the next sentence
    /// of 2 s or more: a shorter voice over the reply is dropped BY DESIGN
    /// (D-071, the echo rule), which the first run of this harness found by
    /// waiting for ever.
    func words(for said: Int, nextLong: inout Int) -> [Float] {
        let long = sentences.filter { Double($0.count) / rate >= 2.0 }
        guard interruptAt.contains(said), !long.isEmpty else { return sentences[(said - 1) % sentences.count] }
        defer { nextLong += 1 }
        return long[nextLong % long.count]
    }

    func milliseconds(_ words: [Float]) -> Int { Int(Double(words.count) / rate * 1000) }
}

/// The person's side of the conversation. Say a sentence; then wait for its
/// answer to end — or, when the NEXT sentence is an interruption, start it
/// 1.5 s after this answer's first sound, over it. Every wait has a deadline.
func converse(_ script: Script, mouth: Mouthpiece, watch: TurnWatch) async {
    var nextLong = 0
    for said in 1...script.turns {
        let words = script.words(for: said, nextLong: &nextLong)
        print("🗣  sentence \(said)/\(script.turns) (\(script.milliseconds(words)) ms of audio)"
              + (script.interruptAt.contains(said) ? " — OVER the answer" : ""))
        let before = watch.count
        await mouth.say(words)
        guard !Task.isCancelled else { return }
        guard let opened = await watch.opening(from: before) else {
            print("⚠  sentence \(said) opened no turn (dropped as too short, or unheard)")
            continue
        }
        let interruptsNext = script.interruptAt.contains(said + 1)
        await follow(opened, until: interruptsNext ? .firstSound : .end, watch: watch)
        if !interruptsNext { try? await Task.sleep(for: .milliseconds(700)) }   // a person's own beat
    }
}

enum Until { case firstSound, end }

/// Waits on the turn the sentence opened: for its end, or — when the next
/// sentence will talk over it — for its first sound plus 1.5 s. A person's
/// sentence split in two can barge its own answer; the newest turn is then
/// followed instead.
func follow(_ opened: (turn: Int, index: Int), until: Until, watch: TurnWatch) async {
    var mine = opened.turn
    var from = opened.index + 1
    while !Task.isCancelled {
        let current = mine
        guard let end = await watch.first(from: from, within: .seconds(30), where: { event in
            switch event {
            case .stateChanged(.speaking, let turn): until == .firstSound && turn == current
            case .turnCompleted(let turn), .turnBarged(let turn), .turnFailed(_, let turn),
                 .stateChanged(.idle, let turn): turn == current
            default: false
            }
        }) else {
            print("⚠  turn \(mine): no end within 30 s")
            return
        }
        switch end.event {
        case .stateChanged(.speaking, _):
            try? await Task.sleep(for: .milliseconds(1_500))
            return
        case .turnBarged:
            guard let next = await watch.opening(from: end.index + 1) else { return }
            mine = next.turn
            from = next.index + 1
        default:
            return
        }
    }
}

extension TurnWatch {
    /// The first turn to start listening at or after `from`, within 5 s.
    func opening(from: Int) async -> (turn: Int, index: Int)? {
        guard let found = await first(from: from, within: .seconds(5), where: {
            if case .stateChanged(.listening, _) = $0 { true } else { false }
        }), case .stateChanged(_, let turn) = found.event else { return nil }
        return (turn, found.index)
    }
}
