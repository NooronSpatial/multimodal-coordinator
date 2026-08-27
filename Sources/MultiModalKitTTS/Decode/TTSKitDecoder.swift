import TTSKit

/// THE REAL DECODER — and the only place TTSKit's decode API is named
/// (AC-109, D-053 F-6).
///
/// Everything the vendor brought with it stops here: `generate`,
/// `GenerationOptions`, `SpeechProgress`, `SpeechCallback`,
/// `SpeechResult`. Above this line the mouth talks to `TTSDecoding`, which
/// is ours, so the scripted decoder that makes a decode throw needs no
/// vendor import at all.
///
/// **What this seam does and does not buy.** It answers D-023's fourth
/// question — *could we remove this dependency in a day, because it lives
/// behind one of our protocols?* — **for the decode path**: yes, replacing
/// it means writing one more conformance of `TTSDecoding`. It does NOT
/// answer it for the model lifecycle, where `NeuralVoice` still names
/// `TTSModelVariant`, `TTSKitConfig` and the two decoder-mode enums in its
/// public API, deliberately (D-053 F-7 = A): `.fused` versus `.stepped` is
/// a PUBLISHED number — 1.066 → 0.752 — and a caller who cannot name the
/// decoder cannot reproduce the measurement.
///
/// A struct holding a class: `TTSKit` is `open class … @unchecked
/// Sendable`, so this needs no unsafety of its own to be `Sendable`.
struct TTSKitDecoder: TTSDecoding {
    let kit: TTSKit

    /// Straight from the loaded speech decoder — 24 kHz for Qwen3, but
    /// asked rather than assumed.
    var sampleRate: Int { kit.sampleRate }

    func decode(_ text: String,
                temperature: Float?,
                onStep: @escaping @Sendable ([Float]) -> Bool) async throws {
        var options = GenerationOptions()
        // NOT A TUNING KNOB - A CORRECTNESS PIN, and TTSKit proves it
        // by doing the same thing in its own `play()`.
        //
        // The default is 0, "all chunks run concurrently in one
        // batch". On that path the streaming callback is handed
        // `audio: []` on every single step, and the real samples
        // arrive only after the WHOLE batch finishes decoding
        // (TTSKit.swift:910-919 and :958-972). A renderer like ours
        // would receive nothing to play until the entire reply was
        // decoded - no streaming, no lead, first-audio back to full
        // decode time - and it would happen silently, only for
        // replies long enough to split into two chunks. Every
        // sentence measured so far is one chunk, which is exactly
        // why this never showed.
        //
        // `1` takes the sequential branch, which passes the real
        // callback through untouched (TTSKit.swift:858-880). The
        // library's own real-time path sets the same value for the
        // same reason (TTSKit.swift:1046).
        //
        // THIS PIN IS STILL UNTESTED, and the seam does not change that.
        // Its guarantee rests on reading the vendor's source, because the
        // fault it prevents lives in the vendor's branching — a scripted
        // decoder cannot reproduce a batching mode it does not have. The
        // seam's new tests cover the FAILURE path; they say nothing about
        // this line, and a reader who assumes otherwise would be wrong.
        options.concurrentWorkerCount = 1
        if let temperature { options.temperature = temperature }
        // `voice` and `language` stay nil: the model resolves its own
        // defaults, and choosing them is not this mouth's business.
        _ = try await kit.generate(
            text: text, voice: nil, language: nil, options: options
        ) { progress in
            // TTSKit reads `nil` and `true` alike as "keep going"; our
            // seam has no third state, so the mapping is total.
            onStep(progress.audio)
        }
    }
}
