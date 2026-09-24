// The local brain's runtime: Qwen3.5 through MLX (mlx-swift-lm pinned by revision
// in project.yml, tokenizer from swift-transformers). PicshopKit never links MLX:
// PicshopApp.init registers this runtime with LocalBrainHub, and everything
// MLX-specific stays in App/LocalBrain.
//
// Phase 0: the packages are linked and the runtime registers, but it reports
// itself unusable and every call throws. Loading, the chat engine, the planner
// and the memory guard arrive in phase 1.
#if canImport(MLXVLM)
import Foundation
import MLXLMCommon
import MLXVLM
import Tokenizers
import PicshopCore
import PicshopIntent
import PicshopUI

final class MLXLocalRuntime: LocalModelRuntime, @unchecked Sendable {
    static let shared = MLXLocalRuntime()

    private init() {}

    /// Phase 1: false only on the simulator (MLX builds there but cannot run).
    var isUsable: Bool { false }

    func load(_ info: LocalModelInfo, from directory: URL) async throws {
        throw Self.notReady
    }

    func unload() async {}

    func isLoaded(_ id: String) async -> Bool { false }

    func makeEngine(_ setup: LocalChatSetup) async throws -> any LocalChatEngine {
        throw Self.notReady
    }

    func makePlanner() -> (any IntentEngine)? { nil }

    func benchmark() async throws -> LocalModelSpeed {
        throw Self.notReady
    }

    private static let notReady = LiveBrainError.modelUnavailable("mlx runtime not ready")
}
#endif
