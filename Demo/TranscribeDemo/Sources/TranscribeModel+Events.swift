import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — events → screen: the health, audio, turn and
// transcript streams turned into what the demo shows.
extension TranscribeModel {
    // MARK: - events → screen

    func show(health event: HealthEvent) {
        switch event {
        case .thermal(let state): thermal = state
        case .settlingDecodes(let count): settlingCount = count
        case .ringDropped, .listenerFellBehind: break   // drops already on screen
        case .settlingDecodeRefused: break   // the failed row says it in words
        case .turnFailed: break   // the utterance's failure line says it in
                                  // words (D-059's road exists for listeners
                                  // OUTSIDE one conversation; this screen IS
                                  // the conversation)
        }
    }

    func show(audio event: AudioEvent) {
        switch event {
        case .speechStarted(let utterance, let at):
            isSpeaking = true
            liveUtterance = utterance
            utteranceStartSeconds = at.seconds
            utterancePeak = 0
            // The question the field run has to answer: was this the
            // person, or the phone hearing itself?
            let echo = turnState == .speaking
            if echo { onsetsWhileSpeaking += 1 }     // what the PUMP saw
            upsert(utterance) { $0.whileSpeaking = echo }
        case .speechEnded(let at):
            isSpeaking = false
            if let utterance = liveUtterance {
                let peak = utterancePeak
                let ms = Int((at.seconds - utteranceStartSeconds) * 1000)
                upsert(utterance) { $0.peakRMS = peak; $0.milliseconds = ms }
            }
            liveUtterance = nil
        case .dropped(let frames, _):
            droppedFrames += frames
        case .audioSegment(let chunk):
            var sumOfSquares: Float = 0
            for sample in chunk.samples { sumOfSquares += sample * sample }
            let rms = (sumOfSquares / Float(max(chunk.frameCount, 1))).squareRoot()
            utterancePeak = max(utterancePeak, rms)
        }
    }

    func show(turn event: TurnEvent) {
        switch event {
        case .stateChanged(let state, _):
            turnState = state
            if state == .listening || state == .idle { reply = "" }
        case .replyToken(let token, _):
            // VERBATIM (4d review): tokens carry their own spacing —
            // that is the D-037 F-1 rule the phraser depends on — so
            // adding another space made the screen disagree with the
            // mouth on every word after the first.
            reply += token
        case .turnCompleted(let turn):
            lastTurnEvent = "completed \(turn)"
        case .turnBarged(let turn):
            // COUNTED AND SHOWN. The first conversation run failed with
            // "it kept talking when I talked", and the screen could not
            // say whether the coordinator had barged and the mouth
            // ignored it, or whether no barge ever happened — two
            // different bugs, indistinguishable from outside.
            bargeCount += 1
            lastTurnEvent = "BARGED \(turn)"
            reply = ""
        case .turnFailed(let failure, let turn):
            lastTurnEvent = "failed \(turn)"
            reply = ""
            if case .interrupted = failure { wasInterrupted = true }
        }
    }

    func show(feltPause duration: Duration) {
        feltPauseMilliseconds = Int(
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) * 1e-15)
    }

    func show(transcript event: TranscriptEvent) {
        switch event {
        case .partial(let text, let utterance, _):
            upsert(utterance) { $0.text = text }
        case .final(let text, let utterance, _):
            upsert(utterance) { $0.text = text; $0.isFinal = true }
        case .failed(let failure, let utterance, _):
            upsert(utterance) { $0.failure = Self.describe(failure) }
        case .truncated(let utterance, _):
            upsert(utterance) { $0.text += " …" }
        }
    }

    private func upsert(_ id: Int, _ change: (inout Utterance) -> Void) {
        if let index = utterances.firstIndex(where: { $0.id == id }) {
            change(&utterances[index])
        } else {
            var fresh = Utterance(id: id, text: "", isFinal: false, failure: nil)
            change(&fresh)
            utterances.append(fresh)
        }
    }

    static func describe(_ failure: TranscriptionFailure) -> String {
        switch failure {
        case .modelNotInstalled: "The speech model is not installed."
        case .assetDownloadFailed(let reason): "Model download failed: \(reason)"
        case .audioFormatRejected: "The engine refused the audio format."
        case .engineFailed(let reason): "Engine error: \(reason)"
        case .declinedUnderThermalPressure: "Decode skipped — device too hot."
        }
    }
}
