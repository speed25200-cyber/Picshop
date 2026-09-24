import Foundation
import PicshopCore

// The contract between a Live session and whatever answers it: Claude, the
// on-device model or the local grammar. One user turn goes in, a stream of
// events comes out, and edits go through a `LiveToolHandler`.

public enum LiveBrainKind: String, Sendable, Codable { case claude, onDevice, local }

/// Everything a brain needs to answer one turn.
public struct LiveUserTurn: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case speech, typed, sessionStart }
    public var id: Int
    public var kind: Kind
    public var text: String
    public var language: NormalizedUtterance.Language
    public var image: LiveImage?
    public var editorState: LiveEditorState
    /// "Contrast +15 (manual)"; "tapped idea 'Portrait doux' -> applied"; "offline: said X, applied Y"; "finished 'Remove dog'".
    public var sinceLastReply: [String]
    public var interruptedAfter: String?

    public init(id: Int, kind: Kind, text: String, language: NormalizedUtterance.Language, image: LiveImage?, editorState: LiveEditorState,
                sinceLastReply: [String] = [], interruptedAfter: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.language = language
        self.image = image
        self.editorState = editorState
        self.sinceLastReply = sinceLastReply
        self.interruptedAfter = interruptedAfter
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
    /// Speakable delta.
    case text(String)
    case toolStarted(id: String, name: LiveToolName, activity: String?)
    case toolFinished(id: String, name: LiveToolName, result: LiveToolResult)
    case ideas([LiveIdea])
    case fallbackModel(from: String?, to: String?)
    case usage(ClaudeUsage)
    case completed(LiveTurnEnd)
}

public enum LiveBrainError: Error, Sendable, Equatable {
    case missingKey, invalidKey, noCredit, forbidden, modelUnavailable
    case rateLimited(retryAfter: Double?), overloaded, server(status: Int)
    case badRequest(requestID: String?, message: String), requestTooLarge
    case network(String), timeout(stage: String), streamTruncated, unavailable(String)
}

public protocol LiveBrain: Sendable {
    var kind: LiveBrainKind { get }
    func isAvailable() async -> Bool
    func warmUp() async
    /// One user turn including every tool round trip. Cancelling the consuming Task cancels the request;
    /// the caller then calls interrupt(turn:spokenText:) before the next turn.
    func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error>
    func interrupt(turn: Int, spokenText: String) async
    func reset() async
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
    /// Lengths, ids, statuses, ms; never transcripts or keys.
    public var fields: [String: String]

    public init(time: Double, event: String, fields: [String: String] = [:]) {
        self.time = time
        self.event = event
        self.fields = fields
    }
}
