import AVFAudio
import Synchronization
import MultiModalKit
import MultiModalKitBench
import MultiModalKitTesting
import MultiModalKitMLX
import MultiModalKitTTS
import MultiModalKitWhisper
import Observation

// `TranscribeModel` — the choices and the shapes they travel in: which
// mouth, which mind, which ear, what state a model is in, and one
// utterance as the screen sees it.
extension TranscribeModel {
    /// WHICH MOUTH SPEAKS (AC-105). The milestone's whole thesis was
    /// that a second implementation of `SpeechSynthesizing` needs no
    /// change anywhere else; this picker is where a listener gets to
    /// check that claim with their ears instead of reading it.
    enum MouthChoice: String, CaseIterable, Identifiable {
        case apple = "Apple"
        case neural = "Neural"
        var id: String { rawValue }
    }

    /// WHICH MIND ANSWERS (AC-117). The echo stays: it is the seam's
    /// scripted citizen, deterministic, offline, and the control group
    /// every real generator is compared against. The picker is the same
    /// claim the mouth picker makes one seam over — swapping the organ
    /// changes NOTHING else on the spine.
    enum MindChoice: String, CaseIterable, Identifiable {
        case echo = "Echo"
        case apple = "Apple"
        /// The SECOND MIND (4h): weights on this device, no Apple
        /// Intelligence, no network once downloaded.
        case local = "Local"
        var id: String { rawValue }
    }

    /// THE LOCAL MIND'S MODEL — one, named, not chosen.
    ///
    /// 4h shipped a picker (F-1 = C) so the PHONE could answer what the
    /// Mac could not, and it did: 4B runs at 2288 MB peak with 291–315 ms
    /// to the first word. Ryad then ruled 4B outright and removed 0.6B —
    /// its replies were bad enough that keeping it as a "fallback" would
    /// have meant offering a worse product as a feature (D-064).
    ///
    /// The 0.6B measurements stay in INSTRUMENTS. They were true, they
    /// paid for the ruling, and deleting them would hide the evidence.
    enum LocalMind {
        static let repoID = "mlx-community/Qwen3-4B-4bit"
        static let sizeOnDisk = "about 2.2 GB"
        /// Measured on a Mac, and the caption says so — these are not a
        /// phone's numbers (INSTRUMENTS §25).
        static let macBehaviour = "249–374 ms first word · reads through disfluency"
    }

    enum EngineChoice: String, CaseIterable, Identifiable {
        case apple = "Apple"
        case whisper = "Whisper"
        var id: String { rawValue }
    }

    enum EngineState: Equatable {
        case checking
        case modelMissing
        case downloading
        /// ON DISK, being made ready — NOT fetched.
        ///
        /// From a field report: "every time i start the app i see
        /// downloading the voice!" He was right to ask. The files were
        /// already there; `ensureModel()` was compiling six CoreML
        /// components, which takes tens of seconds every launch, and the
        /// screen called that "Downloading". The work was real; the word
        /// was false — and a screen whose job is removing ambiguity had
        /// been the thing creating it.
        case preparing
        case ready
        case failed(String)
    }

    struct Utterance: Identifiable, Equatable {
        let id: Int
        var text: String
        var isFinal: Bool
        var failure: String?
        /// FORENSICS (the Mac's 🔎 line, brought to the phone). Without
        /// these the first field run could only be described, not
        /// measured — and the echo question is entirely a question about
        /// levels: what does the microphone hear when the phone speaks?
        var peakRMS: Float = 0
        var milliseconds: Int = 0
        /// True when this utterance began while the assistant was SPEAKING
        /// — the signature of the echo loop. A run full of these is the
        /// machine hearing itself.
        var whileSpeaking = false
    }
}
