import Foundation
import PicshopCore

/// Runs a brain's tool calls, a tapped idea or a grammar plan on the open editor.
@MainActor public final class EditorToolHandler: LiveToolHandler {
    private weak var host: (any LiveEditingHost)?
    private let mode: EditorMode
    private let runningAfter: Double
    private let onIdeas: @MainActor ([LiveIdea]) -> Void
    private let onJobFinished: @MainActor (LiveExecution) -> Void

    public var language: NormalizedUtterance.Language = .french

    public init(host: any LiveEditingHost, runningAfter: Double = 2.5,
                onIdeas: @escaping @MainActor ([LiveIdea]) -> Void,
                onJobFinished: @escaping @MainActor (LiveExecution) -> Void) {
        self.host = host
        mode = host.liveMode
        self.runningAfter = runningAfter
        self.onIdeas = onIdeas
        self.onJobFinished = onJobFinished
    }

    public func context() -> IntentContext {
        host?.liveIntentContext() ?? IntentContext(mode: mode)
    }

    public func perform(_ call: LiveToolCall) async -> LiveToolResult {
        // Phase 0 stub.
        LiveToolResult(isError: false, payload: ["ok": false], changedDocument: false)
    }

    /// Chip tap: no model call.
    public func runIdea(_ idea: LiveIdea) async -> LiveExecution {
        // Phase 0 stub.
        emptyExecution()
    }

    /// Local fast lane.
    public func runPlan(_ plan: EditPlan) async -> LiveExecution {
        // Phase 0 stub.
        emptyExecution()
    }

    private func emptyExecution() -> LiveExecution {
        LiveExecution(steps: [], version: host?.liveVersion ?? 0, canUndo: false)
    }
}
