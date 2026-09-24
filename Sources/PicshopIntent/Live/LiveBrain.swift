import Foundation
import PicshopCore

// The contract between a Live session and whatever answers it: the local
// model (MLX), Apple's on-device Foundation Models, or the local grammar. All
// of them run on the iPhone. One user turn goes in, a stream of events comes
// out, and edits go through a `LiveToolHandler`.

/// model: the downloaded local model; onDevice: Apple Foundation Models; local: the rules grammar.
public enum LiveBrainKind: String, Sendable, Codable { case model, onDevice, local }

/// What a brain can do beyond answering words, so the session knows what to hand it.
public struct LiveBrainCapabilities: Sendable, Equatable {
    /// Answers `.sessionStart` itself: one sentence and propose_ideas.
    public var opensSession: Bool
    public var seesImages: Bool
    /// The long side the session asks `liveSnapshotImage(maxPixel:)` for (the model: 768).
    public var imageMaxPixel: Int
    public var proposesIdeas: Bool

    public init(opensSession: Bool = false, seesImages: Bool = false, imageMaxPixel: Int = 0, proposesIdeas: Bool = false) {
        self.opensSession = opensSession
        self.seesImages = seesImages
        self.imageMaxPixel = imageMaxPixel
        self.proposesIdeas = proposesIdeas
    }

    /// Words only: no session opening, no picture, no ideas.
    public static let none = LiveBrainCapabilities()
}

/// What one generation cost, for the latency tracker and Diagnostic Live.
public struct LiveGenerationStats: Sendable, Equatable {
    public var model: String
    /// Prefilled this turn, after cache reuse.
    public var promptTokens: Int
    /// Reused from the KV cache.
    public var cachedTokens: Int
    public var generatedTokens: Int
    public var firstTokenMs: Int
    public var tokensPerSecond: Double

    public init(model: String, promptTokens: Int, cachedTokens: Int, generatedTokens: Int, firstTokenMs: Int, tokensPerSecond: Double) {
        self.model = model
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.generatedTokens = generatedTokens
        self.firstTokenMs = firstTokenMs
        self.tokensPerSecond = tokensPerSecond
    }
}

/// Everything a brain needs to answer one turn.
public struct LiveUserTurn: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case speech, typed, sessionStart }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var language: NormalizedUtterance.Language
    public var image: LiveImage?
    public var editorState: LiveEditorState
    /// "Contrast +15 (manual)"; "tapped idea 'Portrait doux' -> applied"; "commands: said X, applied Y"; "finished 'Remove dog'".
    public var sinceLastReply: [String]
    public var interruptedAfter: String?
    /// Titles of the idea chips on screen, in order (additive to contract 6.4).
    public var ideasOnScreen: [String]

    public init(id: Int, kind: Kind, text: String, language: NormalizedUtterance.Language, image: LiveImage?, editorState: LiveEditorState,
                sinceLastReply: [String] = [], interruptedAfter: String? = nil, ideasOnScreen: [String] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.language = language
        self.image = image
        self.editorState = editorState
        self.sinceLastReply = sinceLastReply
        self.interruptedAfter = interruptedAfter
        self.ideasOnScreen = ideasOnScreen
    }
}

// MARK: - Tools

public enum LiveToolName: String, Sendable, CaseIterable {
    case applyEdits = "apply_edits", undo, compareBeforeAfter = "compare_before_after", proposeIdeas = "propose_ideas"
}

public enum LiveTool: Sendable, Equatable {
    case applyEdits([EditIntent])
    case undo(count: Int, redo: Bool, toOriginal: Bool)
    case compare(seconds: Double)
    case proposeIdeas([LiveIdea])
}

public struct LiveToolCall: Sendable, Equatable {
    public var id: String
    public var tool: LiveTool

    public init(id: String, tool: LiveTool) {
        self.id = id
        self.tool = tool
    }
}

public struct LiveToolResult: Sendable, Equatable {
    public var isError: Bool
    public var payload: JSONValue
    public var changedDocument: Bool
    public var execution: LiveExecution?

    public init(isError: Bool, payload: JSONValue, changedDocument: Bool, execution: LiveExecution? = nil) {
        self.isError = isError
        self.payload = payload
        self.changedDocument = changedDocument
        self.execution = execution
    }
}

/// Where a brain's tool calls land: the open editor.
@MainActor public protocol LiveToolHandler: AnyObject, Sendable {
    func context() -> IntentContext
    func perform(_ call: LiveToolCall) async -> LiveToolResult
}

// MARK: - Events and errors

public enum LiveTurnEnd: Sendable, Equatable { case answered, editApplied, maxTokens, refused(category: String?), loopLimit }

public enum LiveBrainEvent: Sendable, Equatable {
    case started(model: String)
    /// Speakable delta, never markup.
    case text(String)
    case toolStarted(id: String, name: LiveToolName, activity: String?)
    case toolFinished(id: String, name: LiveToolName, result: LiveToolResult)
    case ideas([LiveIdea])
    /// Yielded before `.completed` by a brain that generates tokens.
    case stats(LiveGenerationStats)
    case completed(LiveTurnEnd)
}

public enum LiveBrainError: Error, Sendable, Equatable {
    /// Not installed, still downloading or loading.
    case modelNotReady
    /// Load failed, unsupported device, or no runtime in this build.
    case modelUnavailable(String)
    case memoryPressure
    /// "first_token", "tool", "turn".
    case timeout(stage: String)
    case streamTruncated
    case unavailable(String)
}

public protocol LiveBrain: Sendable {
    var kind: LiveBrainKind { get }
    var capabilities: LiveBrainCapabilities { get }
    func isAvailable() async -> Bool
    func warmUp() async
    /// One user turn including every tool round trip. Cancelling the consuming Task cancels the request;
    /// the caller then calls interrupt(turn:spokenText:) before the next turn.
    func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error>
    func interrupt(turn: Int, spokenText: String) async
    func reset() async
}

extension LiveBrain {
    public var capabilities: LiveBrainCapabilities { .none }
}

// MARK: - Time and logging

/// Injected time, so every timing rule is testable.
public protocol LiveClock: Sendable {
    func now() -> Double
    func sleep(seconds: Double) async throws
}

/// Monotonic seconds since boot.
public struct SystemLiveClock: LiveClock {
    public init() {}

    public func now() -> Double { ProcessInfo.processInfo.systemUptime }

    public func sleep(seconds: Double) async throws {
        let clamped = min(max(0, seconds), 86_400)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

public struct LiveLogEntry: Sendable, Equatable {
    public var time: Double
    public var event: String
    /// Lengths, ids, statuses, ms; never transcripts.
    public var fields: [String: String]

    public init(time: Double, event: String, fields: [String: String] = [:]) {
        self.time = time
        self.event = event
        self.fields = fields
    }
}
