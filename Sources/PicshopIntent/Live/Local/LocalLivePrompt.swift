import Foundation
import PicshopCore

/// How much prompt a local model gets: `full` for the 4B, `compact` for the 2B.
public enum LocalPromptSize: String, Sendable { case full, compact }

/// One few-shot exchange, replayed as real chat history before the conversation.
public struct LocalPromptExample: Sendable, Equatable {
    public var user: String
    /// The sentence said before the call.
    public var assistant: String
    public var toolName: LiveToolName?
    public var arguments: JSONValue?
    /// ToolResultEncoder.compactText of a canned result.
    public var toolResult: String?

    public init(user: String, assistant: String, toolName: LiveToolName? = nil, arguments: JSONValue? = nil, toolResult: String? = nil) {
        self.user = user
        self.assistant = assistant
        self.toolName = toolName
        self.arguments = arguments
        self.toolResult = toolResult
    }
}

/// What survives a compaction, written by code rather than by the model.
public struct LocalRecapInput: Sendable, Equatable {
    public var appliedEdits: [String]
    public var lastExchanges: [String]
    public var openQuestion: String?
    public var lastLook: String?

    public init(appliedEdits: [String], lastExchanges: [String], openQuestion: String?, lastLook: String?) {
        self.appliedEdits = appliedEdits
        self.lastExchanges = lastExchanges
        self.openQuestion = openQuestion
        self.lastLook = lastLook
    }
}

/// The words the local model (Qwen3.5 through MLX) reads: its system prompt,
/// tool specs, few-shot examples, and each user message. Deterministic, so the
/// system prefix stays in the KV cache for the whole conversation.
///
/// Phase 0: the frozen signatures with minimal bodies. The persona, the compact
/// tool specs, the examples and the delta editor state arrive in phase 1.
public enum LocalLivePrompt {
    /// Budgets, in characters.
    public struct Budgets: Sendable {
        public static let systemFull = 7_500, systemCompact = 4_800, userMessage = 900, editorDelta = 500, recap = 1_000
    }

    public static func system(mode: EditorMode, size: LocalPromptSize) -> String {
        let medium = mode == .video ? "video" : "photo"
        let text = """
        You are Picshop Live, a warm, expert creative director inside a \(medium) editor on iPhone, talking out loud with the user. \
        Reply in the user's language; in French use tu. One or two short spoken sentences: no lists, markdown or emojis. \
        Change the \(medium) only with the tools: say one short sentence, then call apply_edits. Never identify real people.
        """
        return String(text.prefix(size == .full ? Budgets.systemFull : Budgets.systemCompact))
    }

    /// `[{"type":"function","function":{"name","description","parameters"}}]`, one per Live tool.
    public static func toolSpecs(mode: EditorMode) -> [JSONValue] {
        LiveToolSchema.tools(for: mode).map { tool -> JSONValue in
            ["type": "function", "function": ["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.inputSchema]]
        }
    }

    public static func examples(mode: EditorMode, size: LocalPromptSize) -> [LocalPromptExample] {
        []
    }

    /// The editor state, the reply language, the media text as data, then the user's words.
    public static func userMessage(_ turn: LiveUserTurn, previous: LiveEditorState?, imageAttached: Bool) -> String {
        var parts = [LivePrompt.editorState(turn.editorState, sinceLastReply: turn.sinceLastReply, interruptedAfter: turn.interruptedAfter,
                                            imageVersion: imageAttached ? turn.editorState.version : nil, ideasOnScreen: turn.ideasOnScreen)]
        parts.append("langue: \(turn.language.rawValue)")
        if let media = LivePrompt.mediaText(turn.editorState.mediaText) { parts.append(media) }
        parts.append(turn.text)
        return parts.joined(separator: "\n")
    }

    /// The first message of a session: the state, then the ask for one sentence and ideas.
    public static func sessionStartMessage(_ turn: LiveUserTurn, imageAttached: Bool) -> String {
        let state = LivePrompt.editorState(turn.editorState, imageVersion: imageAttached ? turn.editorState.version : nil, ideasOnScreen: turn.ideasOnScreen)
        return state + "\nlangue: \(turn.language.rawValue)\nThe Live session just started: say one short sentence about what you see, then call propose_ideas."
    }

    /// Whether this turn deserves a fresh picture (the caller also checks that the version changed).
    public static func needsFreshLook(_ turn: LiveUserTurn, versionsSinceLastLook: Int) -> Bool {
        turn.kind == .sessionStart || versionsSinceLastLook >= 3
    }

    /// The conversation so far, in a few lines, for the history after a compaction.
    public static func recap(_ input: LocalRecapInput) -> String {
        var lines = ["Recap of the conversation so far"]
        if !input.appliedEdits.isEmpty { lines.append("applied: " + input.appliedEdits.joined(separator: "; ")) }
        if !input.lastExchanges.isEmpty { lines.append("last exchanges: " + input.lastExchanges.joined(separator: " | ")) }
        if let question = input.openQuestion { lines.append("open question: " + question) }
        if let look = input.lastLook { lines.append("last look: " + look) }
        return String(lines.joined(separator: "\n").prefix(Budgets.recap))
    }
}
