// THE APPLE MIND'S FAILURE TABLE, as one value (AC-114, AC-236; 5b SPEC
// §213 R-2, D-122 F-20 A).
//
//     an error out of the vendor's stream ──▶ AppleEnding(error)
//                                                 │
//               ┌─────────────────────────────────┴───────────────┐
//               ▼                                                 ▼
//     the RUN reports it (`settle`)               the KEEPER asks again only for
//     .cut · .refused · .failed(typed)            .failed(.unexplained) after a tool
//                                                 ran, before any word (§213 R-1)
//
// Until 5b the table lived as `catch` arms inside `AppleReplyRun`, which
// was its only reader. The keeper's retry needs the same answer — "is
// this the failure with no name?" — so the table is a pure value now:
// ONE table, two readers, and they can never disagree about which
// failure is which (the rule `ConversationTurn.remembered` set for the
// memory). The arms moved here whole, comments and all; the mapping is
// unchanged except where R-2 says.

import FoundationModels

/// How one error out of the vendor's stream ENDS a reply.
@available(macOS 26.0, iOS 26.0, *)
enum AppleEnding: Equatable {
    /// The worker was cancelled while parked on the stream — the
    /// deadline's doing (`expire`) or a `cancel()`; the run's latch tells
    /// them apart, and the second owes no terminal.
    case cut
    /// A supervised model DOING ITS JOB (D-057 F-4 = A, D-104): the
    /// person hears the app's sentence and the reply ends `.refused`.
    case refused
    /// A failure, typed — the one terminal a caller counts.
    case failed(ReplyFailure)

    init(_ error: any Error) {
        switch error {
        case is CancellationError:
            self = .cut
        case let revision as SnapshotRevision:
            // The tripwire fired: the model rewrote text that may
            // already be in the room. One honest failure, showing both
            // sides — never the wrong words, spoken (D-058). This
            // library's own failure, so it keeps its name (R-2).
            self = .failed(.engine("the model revised text already emitted — "
                + "was: \"\(revision.emitted)\" now: \"\(revision.snapshot)\""))
        case let error as LanguageModelSession.GenerationError:
            self = Self.ending(for: error)
        case let error as LanguageModelSession.ToolCallError:
            // A tool the model called THREW (4w, AC-225). Since 4z the
            // adapter answers in words instead (F-4 = B), so this is the
            // vendor raising the error on its own — named, so it stays
            // `.engine`, carrying the SAME `ToolCallFailure` sentence
            // every mind writes (`AppleReplyRun.toolFailure`).
            self = .failed(.engine(AppleReplyRun.toolFailure(from: error).description))
        case let declaration as ToolDeclarationError:
            // A declaration no mind can show — the APP's error, with the
            // same words the door uses for a per-call table (F-13 d). Not
            // the vendor's silence: it names the tool and the parameter.
            self = .failed(.engine(declaration.description))
        case is GenerationSchema.SchemaError:
            // The vendor refused to render a declaration the library's
            // own check let through — a named vendor error, so NOT
            // unexplained (R-2 covers only errors nothing names). The
            // words are the pre-5b ones.
            self = .failed(.engine("reply generation failed: \(error)"))
        default:
            // R-2 (D-122 F-20 A): an error that is neither a
            // `GenerationError` nor a `ToolCallError` — the diet app's
            // `tokengeneration Code=10`, which arrived as an NSError the
            // enum cannot claim. Until 5b this was `.engine("reply
            // generation failed: …")`, a string an app could only match
            // as a string. The words are kept whole, for a log.
            self = .failed(.unexplained(String(describing: error)))
        }
    }

    /// AC-114, and since 4v AC-236's table (SPEC §175/3): every case
    /// reaches an honest outcome, none is swallowed, every failure is a
    /// case a caller can count, and the enum being NON-frozen is handled
    /// rather than hoped away.
    ///
    /// Two cases END the turn instead of failing it (D-057 F-4 = A, and
    /// since D-104 with a name): `guardrailViolation` and `refusal` are a
    /// supervised model DOING ITS JOB, and silence would make that look
    /// like a bug.
    ///
    /// No mapping reads `Context.debugDescription` into a test-visible
    /// promise: it is an unlocalised string Apple may change (the spec's
    /// own warning). The CASE decides; the description only rides along
    /// in the failure text for a human to read.
    static func ending(for error: LanguageModelSession.GenerationError) -> AppleEnding {
        switch error {
        case .guardrailViolation, .refusal:
            // RULED (D-104, SPEC §178 F-7 = C): a refusal is how a reply
            // ENDS. Both vendor cases land on the same one row.
            return .refused
        case .exceededContextWindowSize:
            return .failed(.contextWindowExceeded)
        case .assetsUnavailable:
            // The Simulator lesson (INSTRUMENTS §22): availability can
            // vouch for assets the model manager then cannot produce. The
            // table's row is `.unavailable` (SPEC §175/3), and the verdict
            // inside it is `.unknown` with the vendor's own word: the
            // vendor said "assets unavailable" and nothing about WHY. It
            // is not `.modelDownloading` — that sentence promises "try
            // later", and on the very Simulator that taught this lesson
            // the assets never arrive (the 4v review's finding).
            return .failed(.unavailable(.unknown(AppleReplyRun.assetsUnavailableWords)))
        case .unsupportedLanguageOrLocale:
            return .failed(.unsupportedLanguage)
        case .rateLimited, .concurrentRequests:
            // Both are "the engine is serving another request" to a
            // caller that counts. `concurrentRequests` is ALSO a
            // coordination bug on our side — the keeper never asks a
            // session that is still answering (D-117 F-10 A; before 5b,
            // sessions were per-turn) — so a second request on one
            // session should be impossible; the caller's remedy is the
            // same either way: later.
            return .failed(.busy)
        case .unsupportedGuide, .decodingFailure:
            // No guide is ever sent (the mind returns text, §176) and a
            // decoding failure has no caller-side remedy: the honest rest.
            return .failed(.engine("generation failed: \(error.localizedDescription)"))
        @unknown default:
            // R-2 (D-122 F-20 A): a case the SDK does not publish is a
            // failure this library cannot name — until 5b, `.engine`
            // saying so in words.
            return .failed(.unexplained(String(describing: error)))
        }
    }
}
