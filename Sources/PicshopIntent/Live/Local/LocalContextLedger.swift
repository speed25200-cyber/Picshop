import Foundation
import PicshopCore

/// A running estimate of how full the local model's context is, from the text
/// Qwen3.5's template actually renders (`QwenChatTemplate`): the cached prefix
/// (system prompt, tool specs, examples, a recap) and what the conversation
/// appended since. It never replaces the engine's exact count
/// (`LocalChatEngine.contextTokens()`); it lets pure code and tests budget the
/// prompt, decide a compaction before asking the engine, and log how a
/// conversation grows.
///
/// Additive to the contract (phase 1), used by LocalLivePrompt's budget tests and
/// the fake engines.
public struct LocalContextLedger: Sendable, Equatable {
    /// Qwen's tokenizer on French and English prose mixed with JSON: about 3.2
    /// characters per token (conservative: French accents and JSON punctuation cost more).
    public static let charactersPerToken = 3.2
    /// One picture at `processing.maxPixels` 196,608 (512×384): 32×32 pixels per token.
    public static let tokensPerImage = 192

    /// Characters of the prefix prefilled once: system, tools, history.
    public private(set) var prefixCharacters: Int
    /// Characters appended by the conversation since.
    public private(set) var conversationCharacters = 0
    /// Pictures in the context, the history's included.
    public private(set) var images: Int
    /// User turns appended since the prefix.
    public private(set) var turns = 0

    public init(setup: LocalChatSetup) {
        prefixCharacters = QwenChatTemplate.render(setup, addGenerationPrompt: false).count
        images = setup.history.filter(Self.hasImage).count
    }

    /// The prefix's tokens, estimated.
    public var prefixTokens: Int { Self.tokens(characters: prefixCharacters) }

    /// Everything in the context, estimated: text plus pictures.
    public var estimatedTokens: Int {
        Self.tokens(characters: prefixCharacters + conversationCharacters) + images * Self.tokensPerImage
    }

    /// Messages sent to the engine (a user turn, tool results), with the assistant prefix they open.
    public mutating func append(_ messages: [LocalChatMessage]) {
        guard !messages.isEmpty else { return }
        conversationCharacters += Self.rendered(messages).count + QwenChatTemplate.generationPrompt.count
        images += messages.filter(Self.hasImage).count
        turns += messages.contains { if case .user = $0 { return true } else { return false } } ? 1 : 0
    }

    /// What the model generated: its words and its calls, closed by `<|im_end|>`.
    public mutating func appendReply(_ text: String, calls: [LocalToolCall] = []) {
        var reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, call) in calls.enumerated() {
            reply += (index == 0 ? (reply.isEmpty ? "" : "\n\n") : "\n") + QwenChatTemplate.functionCall(call)
        }
        conversationCharacters += reply.count + QwenChatTemplate.imEnd.count + 1
    }

    /// Past `compactAt` estimated tokens, or a picture that would make one too many.
    public func needsCompaction(compactAt: Int, maxImages: Int, addingImage: Bool = false) -> Bool {
        estimatedTokens > compactAt || (addingImage && images >= maxImages)
    }

    public static func tokens(characters: Int) -> Int {
        Int((Double(max(0, characters)) / charactersPerToken).rounded(.up))
    }

    /// Messages as the template writes them in the middle of a conversation.
    private static func rendered(_ messages: [LocalChatMessage]) -> String {
        QwenChatTemplate.render(system: "", tools: [], messages: messages, addGenerationPrompt: false)
    }

    private static func hasImage(_ message: LocalChatMessage) -> Bool {
        if case .user(_, let image) = message { return image != nil }
        return false
    }
}
