import Foundation
import PicshopCore

/// Claude over raw HTTPS + SSE: the streaming tool loop of one Live session.
public actor ClaudeLiveBrain: LiveBrain {
    /// .claude
    public nonisolated let kind: LiveBrainKind
    private let mode: EditorMode
    private let apiKey: String
    private let transport: any ClaudeTransport
    private var options: ClaudeRequestOptions
    private let clock: any LiveClock
    private let log: (@Sendable (LiveLogEntry) -> Void)?
    private var lastRequestAt: Double?

    public init(mode: EditorMode, apiKey: String, transport: any ClaudeTransport, options: ClaudeRequestOptions = .init(),
                clock: any LiveClock = SystemLiveClock(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) {
        kind = .claude
        self.mode = mode
        self.apiKey = apiKey
        self.transport = transport
        self.options = options
        self.clock = clock
        self.log = log
    }

    public var secondsSinceLastRequest: Double? {
        guard let lastRequestAt else { return nil }
        return clock.now() - lastRequestAt
    }

    public func isAvailable() async -> Bool {
        !apiKey.isEmpty
    }

    public func warmUp() async {
        // Phase 0 stub.
    }

    public nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        // Phase 0 stub: answers nothing.
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(.answered))
            continuation.finish()
        }
    }

    public func interrupt(turn: Int, spokenText: String) async {
        // Phase 0 stub.
    }

    public func reset() async {
        // Phase 0 stub.
    }
}
