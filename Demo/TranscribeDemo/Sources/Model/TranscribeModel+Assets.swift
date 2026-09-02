import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the model assets (the app's job, never the
// library's): checking, downloading and installing ear and mouth.
extension TranscribeModel {
    // MARK: - the model asset (the app's job, never the library's)

    func checkModel() async {
        let installed = switch choice {
        case .apple: await appleEngine.modelInstalled()
        case .whisper: await whisperEngine.modelInstalled()
        }
        engineState = installed ? .ready : .modelMissing
        if installed && choice == .whisper {
            whisperEngine.prewarm()
        }
    }

    /// Honest disk check for the VOICE. Asking never downloads.
    func checkVoice() async {
        guard mouth == .neural else { voiceState = .ready; return }
        // The mouth's half of the same guard. Preparing the voice is a
        // 1.1 GB load, and it must not happen when the mind has already
        // claimed 2.2 GB (INSTRUMENTS §27).
        guard memoryConflict == nil else {
            voiceState = .failed(memoryConflict ?? "")
            return
        }
        guard await neuralVoice.modelInstalled() else {
            voiceState = .modelMissing
            return
        }
        // ON DISK IS NOT LOADED, and the difference is a frozen
        // conversation. `modelInstalled` only stats files; the pipeline
        // is built lazily by the first `openUtterance`, which the
        // coordinator awaits INLINE on its one serial loop. So the first
        // reply after launch would compile six CoreML components — tens
        // of seconds — while speech onsets, transcripts and barges piled
        // up unprocessed behind it, and the first turn's felt-pause
        // number would silently contain the model load.
        //
        // The 4e review found this one call above the identical fault
        // already fixed in `feed`. Warming here closes it completely
        // rather than shrinking it, because `start()` refuses to run
        // until this says ready.
        //
        // PREPARING, not downloading: `modelInstalled()` just said the
        // files are here, so this call is a load. Saying otherwise is how
        // a person comes to believe their phone re-downloads 1.1 GB at
        // every launch.
        voiceState = .preparing
        do {
            // AC-139: SAMPLE THE LAUNCH LOAD. This is the load that killed
            // the app twice — six CoreML models compiling concurrently —
            // and it happens before anyone can tap a probe button. By the
            // time the gauge is reachable, everything is already resident
            // and there is nothing left to watch.
            // NOT SAMPLED AT LAUNCH ANY MORE. AC-139 put the sampler
            // here because the peak happens here — and then Ryad's app
            // began losing headroom on every open until it died. A
            // measurement instrument that stops an app from starting has
            // stopped being an instrument: it is now the fault. Sampling
            // survives on the explicit probe button, where a person
            // chooses to pay for it and can stop by not tapping it.
            try await neuralVoice.ensureModel()
            voiceState = .ready
        } catch {
            voiceState = .failed(String(describing: error))
        }
    }

    /// The voice's 1.1 GB, fetched once. Deliberately a separate button
    /// from the transcriber's download: they are different models, they
    /// fail for different reasons, and a single "Download" that could
    /// mean either would be a worse screen.
    func installVoice() async {
        voiceState = .downloading
        do {
            try await neuralVoice.ensureModel()
            // Trust the DISK, not the call returning. Phase 2's lesson,
            // and the one that caught a wrong model path in this very
            // milestone: a load can succeed against files the check
            // cannot find.
            // AND SAY WHAT THE DISK ACTUALLY SHOWS (4q). "the disk check
            // disagrees" was true and useless on Kokoro's first field
            // run; a check that cannot name the file and the size it saw
            // is shrugging, not reporting.
            if await neuralVoice.modelInstalled() {
                voiceState = .ready
            } else {
                let detail = (neuralVoice as? KokoroVoice)?.installationProblem()
                voiceState = .failed(detail ?? "loaded, but the disk check disagrees")
            }
        } catch {
            voiceState = .failed(String(describing: error))
        }
    }

    func downloadModel() async {
        engineState = .downloading
        do {
            switch choice {
            case .apple: try await appleEngine.ensureModel()
            case .whisper:
                try await whisperEngine.ensureModel()
                whisperEngine.prewarm()
            }
            engineState = .ready
        } catch let failure as TranscriptionFailure {
            engineState = .failed(Self.describe(failure))
        } catch {
            engineState = .failed(String(describing: error))
        }
    }
}
