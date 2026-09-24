import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// A scripted LocalChatEngine: each send() plays the next scripted turn and
// records what the brain sent, so the local brain's turn logic is tested on
// Linux without MLX.

final class FakeChatEngine: LocalChatEngine, @unchecked Sendable {
    let info: LocalModelInfo
    let setup: LocalChatSetup
    private let lock = NSLock()
    private var script: [[LocalChatEvent]]
    private var sentMessages: [[LocalChatMessage]] = []
    private var sentOptions: [LocalGenerationOptions] = []
    private var prepares = 0
    private var closed = false
    private var terminations = 0
    private var tokens: Int
    /// Tokens the context grows by on every send.
    private let growth: Int
    /// Pause before each scripted event (a slow model).
    private let eventDelay: Double

    init(info: LocalModelInfo = .qwen4B, setup: LocalChatSetup, script: [[LocalChatEvent]], contextTokens: Int = 0, growth: Int = 0, eventDelay: Double = 0) {
        self.info = info
        self.setup = setup
        self.script = script
        tokens = contextTokens
        self.growth = growth
        self.eventDelay = eventDelay
    }

    func prepare() async throws {
        lock.withLock { prepares += 1 }
    }

    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LocalChatEvent, Error>.makeStream()
        // Like MLXChatEngine: once closed (the weights were unloaded), nothing is generated.
        if lock.withLock({ closed }) {
            continuation.finish(throwing: LiveBrainError.modelNotReady)
            return stream
        }
        let events: [LocalChatEvent] = lock.withLock {
            sentMessages.append(messages)
            sentOptions.append(options)
            tokens += growth
            return script.isEmpty ? [] : script.removeFirst()
        }
        let delay = eventDelay
        let task = Task {
            for event in events {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                if Task.isCancelled { break }
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] reason in
            task.cancel()
            if case .cancelled = reason { self?.lock.withLock { self?.terminations += 1 } }
        }
        return stream
    }

    func contextTokens() async -> Int { lock.withLock { tokens } }

    func close() async {
        lock.withLock { closed = true }
    }

    var sent: [[LocalChatMessage]] { lock.withLock { sentMessages } }
    var options: [LocalGenerationOptions] { lock.withLock { sentOptions } }
    var prepareCount: Int { lock.withLock { prepares } }
    var isClosed: Bool { lock.withLock { closed } }
    /// Streams the consumer walked away from (generation cancelled).
    var cancelledStreams: Int { lock.withLock { terminations } }
}

/// Every engine a factory made, in order.
final class FakeEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[[LocalChatEvent]]]
    private var made: [FakeChatEngine] = []
    private let growth: Int
    private let eventDelay: Double
    /// Thrown by the factory instead of making an engine (weights not loaded).
    var failure: Error?

    init(scripts: [[[LocalChatEvent]]] = [], growth: Int = 0, eventDelay: Double = 0) {
        self.scripts = scripts
        self.growth = growth
        self.eventDelay = eventDelay
    }

    var engines: [FakeChatEngine] { lock.withLock { made } }

    var factory: LocalChatEngineFactory {
        { [self] setup in
            if let failure = lock.withLock({ failure }) { throw failure }
            return lock.withLock {
                let engine = FakeChatEngine(setup: setup, script: scripts.isEmpty ? [] : scripts.removeFirst(), growth: growth, eventDelay: eventDelay)
                made.append(engine)
                return engine
            }
        }
    }
}

extension LocalModelInfo {
    static let qwen4B = LocalModelCatalog.max.info
    static let qwen2B = LocalModelCatalog.fast.info
}

/// Scripted model output, shortest to write.
enum Say {
    static let stats = LiveGenerationStats(model: "Qwen3.5 4B", promptTokens: 60, cachedTokens: 2_000, generatedTokens: 12, firstTokenMs: 420, tokensPerSecond: 22)

    static func done(_ reason: LocalStopReason = .endOfTurn) -> LocalChatEvent { .finished(stats, reason) }

    static func call(_ name: String, _ arguments: JSONValue, id: String = "call_1") -> LocalChatEvent {
        .toolCall(LocalToolCall(id: id, name: name, arguments: arguments))
    }

    static let warmer: JSONValue = ["steps": [["action": "adjust", "parameter": "temperature", "amount": 15]]]
    static let invalidSteps: JSONValue = ["steps": [["action": "teleport", "amount": 15]]]
    static let ideas: JSONValue = ["ideas": [
        ["title": "Soir doré", "why": "La lumière chaude flatte la scène.", "symbol": "sun.max", "steps": [["action": "adjust", "parameter": "temperature", "amount": 20]]],
        ["title": "Noir et blanc", "why": "Des formes fortes.", "symbol": "circle.lefthalf.filled", "steps": [["action": "applyLook", "look": "mono"]]],
    ]]
}

/// A fallback that answers every turn with one sentence and counts the turns it got.
actor FakeFallbackBrain: LiveBrain {
    nonisolated let kind: LiveBrainKind = .local
    private(set) var turns: [LiveUserTurn] = []

    func isAvailable() async -> Bool { true }
    func warmUp() async {}
    func interrupt(turn: Int, spokenText: String) async {}
    func reset() async {}

    private func record(_ turn: LiveUserTurn) { turns.append(turn) }

    nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(turn)
                continuation.yield(.started(model: "local"))
                continuation.yield(.text("Réponse des commandes."))
                continuation.yield(.completed(.answered))
                continuation.finish()
            }
        }
    }
}

/// Whether P's LocalOutputFilter is past its phase 0 pass-through (the markup tests need it).
func outputFilterIsReal() -> Bool {
    var filter = LocalOutputFilter()
    let pieces = filter.feed("<think>x</think>Salut") + filter.finish()
    return !pieces.contains { if case .speech(let text) = $0 { return text.contains("<") } else { return false } }
}

/// Markup that must never reach the voice.
let forbiddenMarkup = ["<tool_call", "<function=", "<think>", "<|im_", "<parameter"]

func assertSpeakable(_ events: [LiveBrainEvent], file: StaticString = #filePath, line: UInt = #line) {
    for event in events {
        guard case .text(let text) = event else { continue }
        for markup in forbiddenMarkup where text.contains(markup) {
            XCTFail("spoken text contains \(markup): \(text)", file: file, line: line)
        }
    }
}
