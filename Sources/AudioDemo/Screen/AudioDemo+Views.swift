import Foundation
import MultiModalKit

// Extends `AudioDemo` with the terminal's views: one printer per event
// stream (turns, health, audio, transcripts) and the small measurements
// they print.

extension AudioDemo {
    static func showTurns(_ events: AsyncStream<TurnEvent>, on screen: Screen) async {
        var reply = ""
        for await event in events {
            switch event {
            case .stateChanged(let state, _):
                await screen.set(turnState: state)
                if state == .listening || state == .idle { reply = "" }
                await screen.set(reply: reply)
            case .replyToken(let token, _):
                reply += token          // tokens carry their own spacing now
                await screen.set(reply: reply)
            case .turnCompleted(let turn):
                await screen.log("🤖 [\(turn)] \(reply)")
                reply = ""
                await screen.set(reply: "")
            case .turnBarged(let turn):
                await screen.log("✋ [\(turn)] interrupted — listening to you instead")
            case .turnFailed(let failure, let turn):
                await screen.log("⚠️  [\(turn)] turn failed: \(failure)")
            }
        }
    }

    // MARK: - the two listeners' views of the world

    /// The pipeline's own health, one line per fact — the forensics feed.
    static func showHealth(_ events: AsyncStream<HealthEvent>, on screen: Screen) async {
        for await event in events {
            switch event {
            case .thermal(let state):
                await screen.log("🩺 thermal: \(state)")
            case .ringDropped(let frames, let at):
                await screen.log("🩺 ring dropped \(frames) frames at \(format(at.seconds)) s")
            case .listenerFellBehind(let id, let total):
                await screen.log("🩺 listener \(id) fell behind — \(total) events dropped so far")
            case .settlingDecodes(let count):
                await screen.log("🩺 settling decodes: \(count)")
            case .settlingDecodeRefused(let utterance, let thermal):
                await screen.log("🩺 [\(utterance)] settling decode refused (thermal: \(thermal))")
            case .turnFailed(let turn, let failure):
                // D-059: the health-side record of a dead turn — the road
                // the mind's tripwire alarm rides.
                await screen.log("🩺 turn \(turn) FAILED: \(failure)")
            }
        }
    }

    static func showAudio(
        _ events: AsyncStream<AudioEvent>, on screen: Screen, ringDrops consumer: AudioRingConsumer
    ) async {
        // Per-utterance forensics: what did the gate actually let through?
        var utterance = -1
        var startSeconds = 0.0
        var chunks = 0
        var peak: Float = 0
        for await event in events {
            switch event {
            case .speechStarted(let number, let at):
                utterance = number
                startSeconds = at.seconds
                chunks = 0
                peak = 0
                await screen.set(speaking: true)
            case .audioSegment(let chunk):
                chunks += 1
                peak = max(peak, rms(of: chunk))
                await screen.set(level: level(of: chunk), drops: consumer.totalDropped)
            case .speechEnded(let at):
                let ms = (at.seconds - startSeconds) * 1000
                await screen.log("🔎 [\(utterance)] \(String(format: "%.0f", ms)) ms" +
                    " · peak rms \(String(format: "%.3f", peak)) · \(chunks) chunks")
                await screen.set(speaking: false)
            case .dropped(let frames, let at):
                await screen.log("⚠️  dropped \(frames) frames at \(format(at.seconds)) s")
            }
        }
    }

    static func showTranscripts(_ events: AsyncStream<TranscriptEvent>, on screen: Screen) async {
        for await event in events {
            switch event {
            case .partial(let text, _, _):
                await screen.set(partial: text)
            case .final(let text, let utterance, let at):
                await screen.log("💬 [\(utterance)] \(text)   (\(format(at.seconds)) s)")
                await screen.set(partial: "")
            case .failed(let failure, let utterance, _):
                await screen.log("⚠️  [\(utterance)] recognition failed: \(failure)")
                await screen.set(partial: "")
            case .truncated(let utterance, _):
                await screen.log("✂️  [\(utterance)] utterance hit the 30 s ceiling")
            }
        }
    }

    static func rms(of chunk: AudioChunk) -> Float {
        var sumOfSquares: Float = 0
        for sample in chunk.samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()
    }

    static func level(of chunk: AudioChunk) -> Int {
        min(Int(rms(of: chunk) * 300), 24)
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
