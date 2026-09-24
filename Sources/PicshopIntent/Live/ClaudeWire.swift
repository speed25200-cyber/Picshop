import Foundation

// The parts of the Claude Messages wire format that other modules see.

/// Token counts reported by one response.
public struct ClaudeUsage: Sendable, Hashable {
    public var inputTokens = 0, outputTokens = 0, cacheCreationInputTokens = 0, cacheReadInputTokens = 0
    /// A usage.iterations entry of type fallback_message was present.
    public var servedByFallback = false

    public init() {}
}

/// A non-2xx answer from the API, read from its `{error: {type, message}}` body.
public struct ClaudeAPIError: Error, Sendable, Hashable {
    public var status: Int?
    public var type: String
    public var message: String
    public var requestID: String?
    public var retryAfter: Double?

    public init(status: Int?, type: String, message: String, requestID: String?, retryAfter: Double?) {
        self.status = status
        self.type = type
        self.message = message
        self.requestID = requestID
        self.retryAfter = retryAfter
    }
}

/// The HTTP layer, implemented with URLSession on Apple platforms and by fakes in tests.
public protocol ClaudeTransport: Sendable {
    /// Streams a 2xx body in network-sized chunks. Non-2xx: reads the body and throws ClaudeAPIError.
    /// URL errors: LiveBrainError.network / .timeout. Cancelling the consuming Task cancels the HTTP task.
    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error>
    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data)
}

extension ClaudeUsage {
    /// Reads a Messages API `usage` object. A `usage.iterations` entry of type
    /// fallback_message means a fallback model served the turn.
    public init(json: JSONValue) {
        self.init()
        inputTokens = json["input_tokens"]?.int ?? 0
        outputTokens = json["output_tokens"]?.int ?? 0
        cacheCreationInputTokens = json["cache_creation_input_tokens"]?.int ?? 0
        cacheReadInputTokens = json["cache_read_input_tokens"]?.int ?? 0
        servedByFallback = json["iterations"]?.array?.contains { $0["type"]?.string == "fallback_message" } ?? false
    }

    /// Later usage (message_delta) wins field by field over earlier usage (message_start).
    public func merged(with later: JSONValue) -> ClaudeUsage {
        var result = self
        if let value = later["input_tokens"]?.int { result.inputTokens = value }
        if let value = later["output_tokens"]?.int { result.outputTokens = value }
        if let value = later["cache_creation_input_tokens"]?.int { result.cacheCreationInputTokens = value }
        if let value = later["cache_read_input_tokens"]?.int { result.cacheReadInputTokens = value }
        if let iterations = later["iterations"]?.array, iterations.contains(where: { $0["type"]?.string == "fallback_message" }) {
            result.servedByFallback = true
        }
        return result
    }
}

extension ClaudeAPIError {
    /// Reads an error body: `{"type":"error","error":{"type","message"},"request_id"}`.
    public init(status: Int?, body: Data, headers: [String: String]) {
        let json = try? JSONValue.parse(bytes: Array(body))
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.init(status: status,
                  type: json?["error"]?["type"]?.string ?? "http_error",
                  message: json?["error"]?["message"]?.string ?? "",
                  requestID: json?["request_id"]?.string ?? lowered["request-id"],
                  retryAfter: lowered["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
    }
}

// MARK: - Content

/// `{"type":"ephemeral"}`, with an optional TTL.
public struct CacheControl: Sendable, Hashable {
    public enum TTL: String, Sendable { case fiveMinutes = "5m", oneHour = "1h" }
    public var ttl: TTL?

    public init(ttl: TTL? = nil) {
        self.ttl = ttl
    }

    public static let oneHour = CacheControl(ttl: .oneHour)

    public var json: JSONValue {
        var object: [String: JSONValue] = ["type": "ephemeral"]
        if let ttl { object["ttl"] = .string(ttl.rawValue) }
        return .object(object)
    }
}

public enum ClaudeImageSource: Sendable, Hashable {
    case base64(mediaType: String, data: String)
}

/// One block of message content, as the Messages API writes it. Thinking and
/// unknown blocks are kept so they can be echoed back unchanged.
public enum ClaudeContentBlock: Sendable, Hashable {
    case text(String, cache: CacheControl? = nil)
    case image(ClaudeImageSource, cache: CacheControl? = nil)
    /// Echoed unchanged, even when the text is empty.
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case toolUse(id: String, name: String, input: JSONValue)
    /// content: .text / .image only.
    case toolResult(toolUseID: String, content: [ClaudeContentBlock], isError: Bool)
    /// A server-side fallback marker.
    case fallback(raw: JSONValue)
    /// Any other block type, kept verbatim.
    case unknown(raw: JSONValue)

    public var json: JSONValue {
        switch self {
        case .text(let text, let cache):
            var object: [String: JSONValue] = ["type": "text", "text": .string(text)]
            if let cache { object["cache_control"] = cache.json }
            return .object(object)
        case .image(let source, let cache):
            var object: [String: JSONValue]
            switch source {
            case .base64(let mediaType, let data):
                object = ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data)]]
            }
            if let cache { object["cache_control"] = cache.json }
            return .object(object)
        case .thinking(let text, let signature):
            return ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
        case .redactedThinking(let data):
            return ["type": "redacted_thinking", "data": .string(data)]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
        case .toolResult(let id, let content, let isError):
            var object: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .array(content.map(\.json))]
            if isError { object["is_error"] = true }
            return .object(object)
        case .fallback(let raw), .unknown(let raw):
            return raw
        }
    }

    public init(json: JSONValue) throws {
        guard let type = json["type"]?.string else { throw JSONParseError(offset: 0, reason: "content block without a type") }
        switch type {
        case "text":
            self = .text(json["text"]?.string ?? "")
        case "image":
            guard let source = json["source"], source["type"]?.string == "base64", let media = source["media_type"]?.string, let data = source["data"]?.string else {
                self = .unknown(raw: json)
                return
            }
            self = .image(.base64(mediaType: media, data: data))
        case "thinking":
            self = .thinking(text: json["thinking"]?.string ?? "", signature: json["signature"]?.string ?? "")
        case "redacted_thinking":
            self = .redactedThinking(data: json["data"]?.string ?? "")
        case "tool_use":
            self = .toolUse(id: json["id"]?.string ?? "", name: json["name"]?.string ?? "", input: json["input"] ?? [:])
        case "tool_result":
            let content: [ClaudeContentBlock]
            if let text = json["content"]?.string {
                content = [.text(text)]
            } else {
                content = try (json["content"]?.array ?? []).map { try ClaudeContentBlock(json: $0) }
            }
            self = .toolResult(toolUseID: json["tool_use_id"]?.string ?? "", content: content, isError: json["is_error"]?.bool ?? false)
        case "fallback":
            self = .fallback(raw: json)
        default:
            self = .unknown(raw: json)
        }
    }

    public var isToolUse: Bool {
        if case .toolUse = self { return true }
        return false
    }

    public var isToolResult: Bool {
        if case .toolResult = self { return true }
        return false
    }

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    public var toolUseID: String? {
        switch self {
        case .toolUse(let id, _, _): return id
        case .toolResult(let id, _, _): return id
        default: return nil
        }
    }

    /// The plain text of a text block.
    public var textValue: String? {
        if case .text(let text, _) = self { return text }
        return nil
    }

    /// Whether the block carries nothing the API would accept (an empty text block).
    var isEmptyText: Bool {
        if case .text(let text, _) = self { return text.isEmpty }
        return false
    }
}

public enum ClaudeRole: String, Sendable { case user, assistant, system }

/// One message of the conversation. A system message is one text block, encoded as a plain string.
public struct ClaudeMessage: Sendable, Hashable {
    public var role: ClaudeRole
    public var content: [ClaudeContentBlock]

    public init(role: ClaudeRole, content: [ClaudeContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ClaudeMessage {
        ClaudeMessage(role: .system, content: [.text(text)])
    }

    public var json: JSONValue {
        if role == .system {
            return ["role": "system", "content": .string(content.compactMap(\.textValue).joined(separator: "\n"))]
        }
        return ["role": .string(role.rawValue), "content": .array(content.map(\.json))]
    }
}

public struct ClaudeToolDefinition: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var eagerInputStreaming: Bool

    public init(name: String, description: String, inputSchema: JSONValue, eagerInputStreaming: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.eagerInputStreaming = eagerInputStreaming
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "description": .string(description), "input_schema": inputSchema]
        if eagerInputStreaming { object["eager_input_streaming"] = true }
        return .object(object)
    }
}

public enum StopReason: Sendable, Hashable {
    case endTurn, toolUse, maxTokens, refusal, stopSequence, pauseTurn, contextWindowExceeded, other(String)

    public init(raw: String) {
        switch raw {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "refusal": self = .refusal
        case "stop_sequence": self = .stopSequence
        case "pause_turn": self = .pauseTurn
        case "model_context_window_exceeded": self = .contextWindowExceeded
        default: self = .other(raw)
        }
    }

    public var raw: String {
        switch self {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .refusal: return "refusal"
        case .stopSequence: return "stop_sequence"
        case .pauseTurn: return "pause_turn"
        case .contextWindowExceeded: return "model_context_window_exceeded"
        case .other(let raw): return raw
        }
    }
}
