import Foundation
import MLXLMCommon
import MultiModalKit

// THE TOOL HALF OF THE REAL TOKEN SOURCE (4w, AC-222; D-101 F-1 = B).
//
// Two things the token loop in `LocalMind.swift` needs when — and only
// when — a tool was given: the prompt that shows the model its own call
// and the answer (`messages(…exchanges:)`), and the parser that turns
// what the model says into a `.toolCall` event (`ToolCallSieve`). Both
// are here so the loop itself reads as it did before 4w, with one
// `guard let sieve` where the two paths part.

extension MLXTokenSource {
    /// The chat with the reply's tool exchanges appended (4w). The
    /// template pairs a call with its result BY ORDER: an assistant turn
    /// carrying the call, then a `.tool` message carrying the answer —
    /// so each exchange is rendered as exactly that pair, after the
    /// question and before the generation prompt. A reply that called
    /// nothing has no exchanges and renders the 4r chat unchanged.
    ///
    /// The assistant turn's content is EMPTY: the words the model said
    /// before its call were already spoken by the run, and repeating
    /// them here would make the model read its own half-sentence as a
    /// finished turn. The arguments go back as strings, the shape the
    /// seam flattened them to (`ToolCallRequest.flatten`) — lossless for
    /// this spike's no-argument read, and the contract milestone's to
    /// carry typed when it types them.
    static func messages(spoken: String?, asked: String,
                         past: [ConversationTurn],
                         exchanges: [ToolExchange]) -> [Chat.Message] {
        var messages: [Chat.Message] = []
        if let spoken { messages.append(.system(spoken)) }
        for turn in past {
            messages.append(.user(turn.said))
            messages.append(.assistant(turn.replied + (turn.interrupted ? "…" : "")))
        }
        messages.append(.user(asked))
        for exchange in exchanges {
            let call = ToolCall(function: .init(
                name: exchange.request.name,
                arguments: exchange.request.arguments.mapValues { JSONValue.string($0) }))
            messages.append(.assistant("", toolCalls: [call]))
            messages.append(.tool(exchange.answer))
        }
        return messages
    }
}

/// The vendor's `ToolCallProcessor`, fed OUR gated pieces (4w, AC-222).
///
/// WHY IT IS NOT THE VENDOR'S LOOP: `generateTokens` yields token IDs
/// and nothing else, and this mind must stay on it — the think gate
/// runs on the ID (§86 layer 2), before anything is detokenised. The
/// vendor's `.toolCall` event lives on its TEXT loop, where a
/// `ToolCallProcessor` reads the decoded chunks. So the same processor
/// is built here, in the same format the vendor inferred for these
/// weights, and read the same way its own loop reads it: a chunk in,
/// the text to show (or nothing, while a call is being collected) out,
/// then every complete call drained in order; at end of sequence the
/// residual text, then the calls the closing token completed.
///
/// A class, not a struct, because the processor is one and buffers
/// between calls; it lives inside one `perform` closure and never
/// crosses an isolation boundary.
final class ToolCallSieve {
    private let processor: ToolCallProcessor

    /// - Parameters:
    ///   - format: the vendor's, from the weights' configuration — the
    ///     `<tool_call>` JSON tags for this family, inferred per model
    ///     and never typed here (AC-125's rule).
    ///   - specs: the specs the prompt was rendered with, so a parser
    ///     that reads argument types can.
    init(format: ToolCallFormat, specs: [ToolSpec]?) {
        processor = ToolCallProcessor(format: format, tools: specs)
    }

    /// One decoded piece in; the seam's events out, in order: the text
    /// the piece contributed (if any is ready), then every call the
    /// piece completed. Empty while a call is still being collected —
    /// partial JSON is never spoken.
    func admit(_ piece: String) -> [TokenEvent] {
        var events: [TokenEvent] = []
        if let text = processor.processChunk(piece), !text.isEmpty {
            events.append(.token(text))
        }
        events += drainCalls()
        return events
    }

    /// End of sequence: what was buffered and turned out not to be a
    /// call is text after all, and a call whose end tag arrived on the
    /// last token is a call.
    func finish() -> [TokenEvent] {
        var events: [TokenEvent] = []
        if let residual = processor.processEOS(returnBufferedText: true), !residual.isEmpty {
            events.append(.token(residual))
        }
        events += drainCalls()
        return events
    }

    /// The vendor's `drainToolCalls()` is internal to it; this is the
    /// same two lines over its public `toolCalls`.
    private func drainCalls() -> [TokenEvent] {
        let calls = processor.toolCalls
        processor.toolCalls.removeAll()
        return calls.map { .toolCall(ToolCallRequest(vendor: $0)) }
    }
}
