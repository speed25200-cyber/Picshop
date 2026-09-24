import Foundation
import PicshopCore

/// Splits a local model's streamed text into what may be spoken and the tool
/// calls it wrote as text, so no markup ever reaches the voice.
///
/// Phase 0: the frozen signature with a pass-through body. Phase 1 holds back
/// any trailing prefix of <tool_call>, <think> and <|im_…; drops <think>…</think>;
/// stops at <|im_end|>, <|endoftext|> and <|im_start|>; and parses both the
/// XML-function dialect (<function=NAME><parameter=KEY>…</parameter>) and the
/// JSON dialect ({"name","arguments"}).
public struct LocalOutputFilter: Sendable {
    public enum Piece: Sendable, Equatable {
        case speech(String)
        case toolCall(name: String, arguments: JSONValue)
        /// Markup that looked like a tool call but could not be read.
        case malformed(String)
    }

    public init() {}

    public mutating func feed(_ delta: String) -> [Piece] {
        delta.isEmpty ? [] : [.speech(delta)]
    }

    /// Flushes whatever was held back at the end of the generation.
    public mutating func finish() -> [Piece] {
        []
    }
}
