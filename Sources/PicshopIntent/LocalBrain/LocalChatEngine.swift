import Foundation
import PicshopCore

// The seam between Live's local-model brain and whatever runs the weights.
// LocalModelLiveBrain is pure Swift and tested on Linux against a scripted
// engine; the MLX engine lives in the app target (App/LocalBrain), so this
// package never links MLX.

/// Which weights answer, and how much of their context the brain uses.
public struct LocalModelInfo: Sendable, Equatable {
    /// "live-qwen35-4b"
    public var id: String
    /// "Qwen3.5 4B"
    public var displayName: String
    /// The pinned Hugging Face revision the weights came from.
    public var revision: String
    /// The budget the brain works within, not the model's own limit: 8_192.
    public var contextTokens: Int
    public var supportsVision: Bool
    public var promptSize: LocalPromptSize

    public init(id: String, displayName: String, revision: String, contextTokens: Int, supportsVision: Bool, promptSize: LocalPromptSize) {
        self.id = id
        self.displayName = displayName
        self.revision = revision
        self.contextTokens = contextTokens
        self.supportsVision = supportsVision
        self.promptSize = promptSize
    }
}

/// A tool call as the model wrote it, before coercion and validation.
public struct LocalToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One message of the local conversation, in the engine's chat format.
public enum LocalChatMessage: Sendable, Equatable {
    case user(String, imageJPEG: Data?)
    case assistant(String, toolCalls: [LocalToolCall])
    case toolResult(callID: String, name: String, content: String)
}

/// What an engine starts from: the system prompt, the tool specs and the
/// history prefilled before the first turn.
public struct LocalChatSetup: Sendable, Equatable {
    public var system: String
    /// LocalLivePrompt.toolSpecs: `{"type":"function","function":{…}}` objects.
    public var tools: [JSONValue]
    /// Few-shot examples and/or the recap, prefilled by prepare().
    public var history: [LocalChatMessage]
    /// Pixel budget for an attached picture: 196_608 (512×384).
    public var imageMaxPixels: Int

    public init(system: String, tools: [JSONValue], history: [LocalChatMessage], imageMaxPixels: Int) {
        self.system = system
        self.tools = tools
        self.history = history
        self.imageMaxPixels = imageMaxPixels
    }
}

/// Sampling for one assistant turn. Thinking is always off.
public struct LocalGenerationOptions: Sendable, Equatable {
    public var maxTokens = 120
    public var temperature = 0.55
    public var topP = 0.8
    public var topK = 20
    /// Kept low: a higher penalty punishes the repeated keys of tool-call JSON.
    public var presencePenalty = 0.3

    public init() {}
}

extension LocalGenerationOptions {
    /// What a generation is for, which sets its sampling (contract §11). Thinking stays off.
    public enum Style: String, Sendable, CaseIterable {
        /// An action verb, a table or `last:` line, not a question: tool JSON wants little randomness.
        case edit
        /// Questions and opinions.
        case conversation
        /// The one round after a failed, blocked or unverified step: greedy.
        case repair
    }

    /// edit 0.25 / 0.8 / 20 / 0; conversation 0.6 / 0.8 / 20 / 0.3; repair 0 (greedy).
    public init(style: Style, maxTokens: Int) {
        self.init()
        self.maxTokens = maxTokens
        switch style {
        case .edit:
            temperature = 0.25
            topP = 0.8
            topK = 20
            presencePenalty = 0
        case .conversation:
            temperature = 0.6
            topP = 0.8
            topK = 20
            presencePenalty = 0.3
        case .repair:
            temperature = 0
            topP = 1
            topK = 1
            presencePenalty = 0
        }
    }
}

public enum LocalStopReason: String, Sendable { case endOfTurn, maxTokens, cancelled }

/// What an engine streams for one assistant turn.
public enum LocalChatEvent: Sendable, Equatable {
    /// Raw model text: may still hold markup, which LocalOutputFilter removes.
    case text(String)
    /// A tool call the engine parsed itself.
    case toolCall(LocalToolCall)
    /// A call the engine saw but could not parse.
    case rejectedToolCall(raw: String)
    /// Always last, unless the stream throws.
    case finished(LiveGenerationStats, LocalStopReason)
}

/// One conversation with a loaded model: one KV cache, reused turn after turn.
public protocol LocalChatEngine: Sendable {
    var info: LocalModelInfo { get }
    /// Prefills the system prompt and history. Idempotent.
    func prepare() async throws
    /// Appends messages and generates one assistant turn. Cancelling the consumer cancels generation.
    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error>
    /// Tokens held in the conversation's cache.
    func contextTokens() async -> Int
    func close() async
}

/// Makes a fresh engine: at the start of a conversation and after each compaction.
public typealias LocalChatEngineFactory = @Sendable (LocalChatSetup) async throws -> any LocalChatEngine
