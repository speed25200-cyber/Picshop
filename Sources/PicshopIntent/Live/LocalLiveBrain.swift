import Foundation
import PicshopCore

/// The brain that needs no model at all: Live's last resort, always available.
/// Live hands it a rules-only HybridIntentRouter (`preferredEngine: .rules`),
/// so a turn never waits on a language model. No conversation memory.
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
        let (stream, continuation) = AsyncThrowingStream<LiveBrainEvent, Error>.makeStream()
        let task = Task {
            do {
                try await self.answer(turn, tools: tools, output: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func answer(_ turn: LiveUserTurn, tools: any LiveToolHandler, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) async throws {
        output.yield(.started(model: "local"))
        let language = turn.language
        guard turn.kind != .sessionStart else {
            output.yield(.text(LiveLines.line(.greetingLocal, language)))
            output.yield(.completed(.answered))
            return
        }
        let context = await tools.context()
        let plan = await router.plan(turn.text, context: context)
        try Task.checkCancellation()
        let intents = plan.intents.filter { $0.action != .unknown }
        guard !intents.isEmpty else {
            // Nothing to run: the question the planner asks, else what can be said instead.
            output.yield(.text(plan.clarification ?? Replies.suggestions(for: mode, language: language)))
            output.yield(.completed(.answered))
            return
        }
        let id = "local-\(turn.id)"
        let call = LiveToolCall(id: id, tool: .applyEdits(intents))
        output.yield(.toolStarted(id: id, name: .applyEdits, activity: LiveActivityTitles.title(for: call.tool, language: language)))
        let result = await tools.perform(call)
        output.yield(.toolFinished(id: id, name: .applyEdits, result: result))
        let execution = result.execution
        let reported = execution?.steps.first { [.info, .needsUser, .failed, .needsClarification].contains($0.status) }
        let running = execution?.steps.contains { $0.status == .running || $0.status == .queued } ?? false
        let reply: String
        if let reported, let message = reported.message, !message.isEmpty {
            reply = message
        } else if running {
            reply = LiveLines.line(.running, language)
        } else {
            reply = plan.reply ?? Replies.combined(for: intents, language: language)
        }
        output.yield(.text(reply))
        output.yield(.completed(.answered))
    }

    public func interrupt(turn: Int, spokenText: String) async {}

    public func reset() async {}
}
