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
