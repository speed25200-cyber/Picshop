import Foundation
import PicshopCore

/// The brain that never needs a network or a model: the existing
/// HybridIntentRouter (Pro MLX, then the Apple planner, then the grammar).
public actor LocalLiveBrain: LiveBrain {
    /// .local
    public nonisolated let kind: LiveBrainKind
    private let router: HybridIntentRouter
    private let mode: EditorMode

    public init(router: HybridIntentRouter, mode: EditorMode) {
        kind = .local
        self.router = router
        self.mode = mode
    }

    public func isAvailable() async -> Bool { true }

    public func warmUp() async {}

    public nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        // Phase 0 stub: answers nothing.
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(.answered))
            continuation.finish()
        }
    }

    public func interrupt(turn: Int, spokenText: String) async {}

    public func reset() async {}
}
