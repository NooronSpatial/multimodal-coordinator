import Foundation

// MARK: - the token-ID gate (SPEC 4h §86 layer 2, D-062 F-2 = B)

/// Which token ids mark a model's private reasoning.
///
/// READ from the model, never hard-coded. AC-125's rule, and the reason
/// for it: this project's whole method is that an instrument which shows
/// a number must be able to say whether it is switched on. A hard-coded
/// 151667 is switched on for exactly one vocabulary and silently off for
/// every other one — and "silently off" here means a phone reading its
/// own deliberation aloud.
struct ThinkTokens: Sendable, Equatable {
    let open: Int
    let close: Int

    /// The two ids, read from a HuggingFace `tokenizer_config.json`.
    ///
    /// Three outcomes, and the third is the point:
    /// - both markers present  → the gate can be built.
    /// - NEITHER present       → `nil`. Not an error: a model that does
    ///   not reason out loud has nothing to gate, and saying so is
    ///   honest rather than defensive.
    /// - exactly ONE present   → `throws`. A vocabulary that can open a
    ///   thought and never close it (or the reverse) is one this gate
    ///   does not understand, and guessing would be the silent failure
    ///   the whole rule exists to prevent.
    static func read(fromTokenizerConfigAt url: URL) throws -> ThinkTokens? {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else {
            throw ThinkTokensFailure.unreadable(url.lastPathComponent)
        }
        // `added_tokens_decoder` maps the id (as a STRING key) to a
        // descriptor whose `content` is the literal marker text.
        let declared = object["added_tokens_decoder"] as? [String: Any] ?? [:]
        var open: Int?
        var close: Int?
        for (key, value) in declared {
            guard let id = Int(key),
                  let content = (value as? [String: Any])?["content"] as? String
            else { continue }
            if content == "<think>" { open = id }
            if content == "</think>" { close = id }
        }
        switch (open, close) {
        case (nil, nil):
            return nil
        case let (openID?, closeID?):
            return ThinkTokens(open: openID, close: closeID)
        default:
            throw ThinkTokensFailure.halfAVocabulary(open: open, close: close)
        }
    }
}

enum ThinkTokensFailure: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case halfAVocabulary(open: Int?, close: Int?)

    var description: String {
        switch self {
        case .unreadable(let name):
            "\(name) is not a tokenizer configuration this gate can read."
        case .halfAVocabulary(let open, let close):
            """
            this vocabulary declares only half of a thought \
            (<think>=\(open.map(String.init) ?? "absent"), \
            </think>=\(close.map(String.init) ?? "absent")) — refusing to \
            guess, because guessing here is a model reading its reasoning aloud.
            """
        }
    }
}

/// Swallows a model's reasoning at the TOKEN, before any string exists.
///
/// §86's layer 2. Layer 1 — the chat template's `enable_thinking`, which
/// pre-fills a closed block — is only a CONVENTION: nothing structurally
/// stops the model opening a second thought. This is the net under it,
/// and it costs one integer comparison per token.
///
/// Why here and not on the text: `<think>` and `</think>` are single
/// tokens in this vocabulary, so they can never arrive split across two
/// deltas. Filtering the text instead would mean holding characters back
/// to see what they become, and holding delays the mouth — a cost this
/// project has spent two milestones measuring (the 542–567 ms felt
/// pause). Measured, not assumed: SPEC §86.
struct ThinkGate: Sendable {
    private let tokens: ThinkTokens
    private var swallowing: Bool

    /// - Parameter startingInsideThought: for a chat template that has
    ///   already opened a thought in the prompt.
    init(_ tokens: ThinkTokens, startingInsideThought: Bool = false) {
        self.tokens = tokens
        self.swallowing = startingInsideThought
    }

    /// True when this token may reach the mouth.
    ///
    /// The markers themselves NEVER pass — they are punctuation for the
    /// model, not words for a person.
    mutating func admits(_ id: Int) -> Bool {
        if id == tokens.open {
            swallowing = true
            return false
        }
        if id == tokens.close {
            swallowing = false
            return false
        }
        return !swallowing
    }

    /// Whether the gate is currently holding a thought back. Exposed so a
    /// test can prove the gate is switched ON, rather than trusting that
    /// nothing came out for some other reason.
    var isSwallowing: Bool { swallowing }
}
