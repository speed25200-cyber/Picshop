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
    private var tokens: Int

    init(info: LocalModelInfo = .qwen4B, setup: LocalChatSetup, script: [[LocalChatEvent]], contextTokens: Int = 0) {
        self.info = info
        self.setup = setup
        self.script = script
        tokens = contextTokens
    }

    func prepare() async throws {
        lock.withLock { prepares += 1 }
    }

    func send(_ messages: [LocalChatMessage], options: LocalGenerationOptions) -> AsyncThrowingStream<LocalChatEvent, Error> {
        let events: [LocalChatEvent] = lock.withLock {
            sentMessages.append(messages)
            sentOptions.append(options)
            return script.isEmpty ? [] : script.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func contextTokens() async -> Int { lock.withLock { tokens } }

    func close() async {
        lock.withLock { closed = true }
    }

    var sent: [[LocalChatMessage]] { lock.withLock { sentMessages } }
    var options: [LocalGenerationOptions] { lock.withLock { sentOptions } }
    var prepareCount: Int { lock.withLock { prepares } }
    var isClosed: Bool { lock.withLock { closed } }
}

/// Every engine a factory made, in order.
final class FakeEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[[LocalChatEvent]]]
    private var made: [FakeChatEngine] = []

    init(scripts: [[[LocalChatEvent]]] = []) {
        self.scripts = scripts
    }

    var engines: [FakeChatEngine] { lock.withLock { made } }

    var factory: LocalChatEngineFactory {
        { [self] setup in
            lock.withLock {
                let engine = FakeChatEngine(setup: setup, script: scripts.isEmpty ? [] : scripts.removeFirst())
                made.append(engine)
                return engine
            }
        }
    }
}

extension LocalModelInfo {
    static let qwen4B = LocalModelInfo(id: LocalModelTiering.maxModelID, displayName: "Qwen3.5 4B", revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
                                       contextTokens: 8_192, supportsVision: true, promptSize: .full)
    static let qwen2B = LocalModelInfo(id: LocalModelTiering.fastModelID, displayName: "Qwen3.5 2B", revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
                                       contextTokens: 8_192, supportsVision: true, promptSize: .compact)
}
