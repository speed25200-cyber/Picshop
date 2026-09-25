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
        // A question the table or the scene map answers: said by code, nothing edited.
        if let answer = LiveQuestionAnswers.answer(turn.text, table: context.table, scene: context.scene, language: language) {
            output.yield(.text(answer))
            output.yield(.completed(.answered))
            return
        }
        let plan = await router.plan(turn.text, context: context)
        try Task.checkCancellation()
        let intents = plan.intents.filter { $0.action != .unknown }
        // A question the rules could not answer above changes nothing ("pourquoi tu ne peux pas écrire derrière ?",
        // "est-ce que le titre est lisible ?"): said so, never an edit made of its words.
        if RuleBasedIntentEngine.asksAQuestion(NormalizedUtterance(turn.text), original: turn.text),
           intents.contains(where: { !$0.action.isMeta && $0.action != .describe }) || (intents.isEmpty && plan.clarification == nil) {
            output.yield(.text(LiveLines.line(.cannotAnswerLocal, language)))
            output.yield(.completed(.answered))
            return
        }
        // "Quelle case ?", "Avec quoi ?": the planner's question comes before any step it could only guess.
        guard !intents.isEmpty, plan.clarification == nil else {
            // Nothing to run: the question the planner asks, else what can be said instead.
            output.yield(.text(plan.clarification ?? Replies.suggestions(for: mode, language: language, hasTable: context.table != nil)))
            output.yield(.completed(.answered))
            return
        }
        let id = "local-\(turn.id)"
        let call = LiveToolCall(id: id, tool: .applyEdits(intents))
        output.yield(.toolStarted(id: id, name: .applyEdits, activity: LiveActivityTitles.title(for: call.tool, language: language)))
        let result = await tools.perform(call)
        output.yield(.toolFinished(id: id, name: .applyEdits, result: result))
        output.yield(.text(Self.reply(to: plan, intents: intents, execution: result.execution, language: language)))
        output.yield(.completed(.answered))
    }

    /// What the grammar lane says after its run, as the session's fast lane does: the honest line when a
    /// check of the result failed, the count line of a table step, the reason-aware line of a step that
    /// did not apply, else the grammar's own reply; never the executor's raw text (D11).
    static func reply(to plan: EditPlan, intents: [EditIntent], execution: LiveExecution?, language: NormalizedUtterance.Language) -> String {
        var reply: String
        if let execution, let failed = execution.verifications.first(where: { $0.status == .failed }) {
            reply = LiveLines.verification(failed, language)
        } else if let execution, execution.tableReport != nil || !execution.allApplied {
            reply = execution.outcomeText(language: language)
        } else {
            reply = plan.reply ?? Replies.combined(for: intents, language: language)
        }
        if reply.isEmpty { reply = Replies.combined(for: intents, language: language) }
        return LiveSpeechSanitizer.clean(reply, language: language)
    }

    public func interrupt(turn: Int, spokenText: String) async {}

    public func reset() async {}
}
