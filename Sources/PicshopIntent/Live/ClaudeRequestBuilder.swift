import Foundation

/// One HTTP request, ready for a `ClaudeTransport`.
public struct ClaudeHTTPRequest: Sendable, Hashable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: Double
    /// Lets the transport drive LiveRoute.isUploading / sharesMedia.
    public var carriesImage: Bool

    public init(url: String, method: String, headers: [String: String], body: Data?, timeout: Double, carriesImage: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.carriesImage = carriesImage
    }
}

public struct ClaudeRequestOptions: Sendable, Hashable {
    /// Fixed: no instance property, no setter.
    public static let model = "claude-opus-5"
    public var maxTokens = 2048
    public var effort = "low"
    public var useServerFallbacks = true

    public init() {}
}

/// Builds the Messages API requests Live sends.
public struct ClaudeRequestBuilder: Sendable {
    public static let messagesURL = "https://api.anthropic.com/v1/messages"
    public static let modelURL = "https://api.anthropic.com/v1/models/claude-opus-5"
    public static let apiVersion = "2023-06-01"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let options: ClaudeRequestOptions

    public init(options: ClaudeRequestOptions) {
        self.options = options
    }

    /// One streamed turn. Keys serialize sorted: cache_control, fallbacks, max_tokens, messages,
    /// model, output_config, stream, system, thinking, tools. Never temperature, top_p, top_k,
    /// tool_choice, a prefilled assistant turn, thinking.display or speed.
    public func streamingRequest(apiKey: String, system: String, tools: [ClaudeToolDefinition], messages: [ClaudeMessage]) -> ClaudeHTTPRequest {
        var body = sharedBody(system: system, tools: tools)
        body["cache_control"] = CacheControl.oneHour.json
        body["max_tokens"] = .number(Double(options.maxTokens))
        body["messages"] = .array(messages.map(\.json))
        body["stream"] = true
        if options.useServerFallbacks { body["fallbacks"] = "default" }
        var headers = baseHeaders(apiKey: apiKey)
        headers["accept"] = "text/event-stream"
        if options.useServerFallbacks { headers["anthropic-beta"] = Self.fallbackBeta }
        let lastUser = messages.last { $0.role == .user }
        return ClaudeHTTPRequest(url: Self.messagesURL, method: "POST", headers: headers, body: Data(JSONValue.object(body).serialized().utf8),
                                 timeout: 30, carriesImage: lastUser?.content.contains { $0.isImage } ?? false)
    }

    /// Writes the tools + system cache entry and opens the connection: same model, system,
    /// tools, thinking and effort as a turn, max_tokens 0, no stream, no top-level
    /// cache_control, no fallbacks field and no beta header.
    public func warmUpRequest(apiKey: String, system: String, tools: [ClaudeToolDefinition]) -> ClaudeHTTPRequest {
        var body = sharedBody(system: system, tools: tools)
        body["max_tokens"] = 0
        body["messages"] = [["role": "user", "content": "warmup"]]
        var headers = baseHeaders(apiKey: apiKey)
        headers["accept"] = "application/json"
        return ClaudeHTTPRequest(url: Self.messagesURL, method: "POST", headers: headers, body: Data(JSONValue.object(body).serialized().utf8), timeout: 30)
    }

    private func sharedBody(system: String, tools: [ClaudeToolDefinition]) -> [String: JSONValue] {
        [
            "model": .string(ClaudeRequestOptions.model),
            "output_config": ["effort": .string(options.effort)],
            "system": [ClaudeContentBlock.text(system, cache: .oneHour).json],
            "thinking": ["type": "adaptive"],
            "tools": .array(tools.sorted { $0.name < $1.name }.map(\.json)),
        ]
    }

    private func baseHeaders(apiKey: String) -> [String: String] {
        ["content-type": "application/json", "x-api-key": apiKey, "anthropic-version": Self.apiVersion]
    }

    /// GET modelURL; also the cheap pre-connect.
    public static func keyCheckRequest(apiKey: String) -> ClaudeHTTPRequest {
        ClaudeHTTPRequest(url: modelURL, method: "GET", headers: ["x-api-key": apiKey, "anthropic-version": apiVersion], body: nil, timeout: 10)
    }

    /// 200 valid, 401 invalid, 402 noCredit, 403/404 noAccess, 429 rateLimited, >=500 server, nil+offline offline.
    public static func keyStatus(httpStatus: Int?, offline: Bool) -> ClaudeKeyStatus {
        guard let status = httpStatus else { return offline ? .offline : .unchecked }
        switch status {
        case 200..<300: return .valid
        case 401: return .invalid
        case 402: return .noCredit
        case 403, 404: return .noAccess
        case 429: return .rateLimited
        default: return .server(status)
        }
    }
}

/// Estimated cost of a response: $5 per million input tokens, $25 per million
/// output tokens, cache reads at 0.1x and 1-hour cache writes at 2x the input price.
/// An estimate only.
public enum LiveCostEstimator {
    public static func dollars(_ usage: ClaudeUsage) -> Double {
        let input = Double(usage.inputTokens) * 5 + Double(usage.cacheReadInputTokens) * 0.5 + Double(usage.cacheCreationInputTokens) * 10
        return (input + Double(usage.outputTokens) * 25) / 1_000_000
    }
}
