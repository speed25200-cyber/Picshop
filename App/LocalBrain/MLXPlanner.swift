// Push-to-talk's planner over the Live model's loaded weights (contract D14),
// registered with the app's router as `IntentEngineKind.proLocal` once the
// model is loaded. It replaces the old "Pro Brain" (MLXIntentEngine), fixing
// what made it slow:
// - thinking is off (`enable_thinking: false`), so the JSON comes first and short;
// - one session per editor mode is reused: its system prompt and examples are
//   prefilled once, and each command appends only its own few dozen tokens
//   (Qwen3.5's cache cannot be trimmed, so reuse is append-only; the session is
//   renewed after a handful of commands to keep the context small);
// - 300 tokens at most, and nothing loads here: without loaded weights the
//   planner says it is unavailable and the router answers with the grammar.
#if canImport(MLXVLM)
import Foundation
import MLXLMCommon
import PicshopCore
import PicshopIntent

final class MLXPlanner: IntentEngine, @unchecked Sendable {
    let kind: IntentEngineKind = .proLocal
    private let runtime: MLXLocalRuntime
    private let sessions = PlannerSessions()

    init(runtime: MLXLocalRuntime) {
        self.runtime = runtime
    }

    func isAvailable() async -> Bool {
        runtime.loadedContainer() != nil
    }

    func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
        guard let loaded = runtime.loadedContainerAndGeneration() else {
            throw LiveBrainError.modelNotReady
        }
        let (container, generation) = loaded
        let prompt = IntentPrompt.userPrompt(for: utterance, context: context, hint: hint) + "\nJSON:"
        let text = try await sessions.answer(prompt, mode: context.mode, container: container, generation: generation)
        guard let raw = LLMResponseParser.parse(text) else {
            throw PicshopError.renderFailed("the local model returned no plan")
        }
        return IntentNormalizer.plan(from: raw, utterance: utterance, context: context, engine: .proLocal)
    }

    /// Prefills the session for `mode` with one real command, off the main actor: the next
    /// command appends to a warm cache instead of prefilling the instructions and examples.
    /// Nothing happens when the weights are not loaded or the session is already there.
    func warm(mode: EditorMode) {
        guard let loaded = runtime.loadedContainerAndGeneration() else { return }
        let (container, generation) = loaded
        let prompt = IntentPrompt.userPrompt(for: "un peu plus lumineux", context: IntentContext(mode: mode), hint: nil) + "\nJSON:"
        let store = self.sessions
        Task.detached(priority: .utility) {
            await store.warm(prompt, mode: mode, container: container, generation: generation)
        }
    }

    /// Drops the sessions (the weights were unloaded, or the app left the foreground).
    func reset() async {
        await sessions.reset()
    }

    func stopGenerating() {
        Task { await sessions.stopGenerating() }
    }
}

/// The planner's reused sessions, one command at a time.
private actor PlannerSessions {
    private struct Entry {
        var session: ChatSession
        var generation: Int
        var commands: Int
    }

    private var entries: [EditorMode: Entry] = [:]
    private var running: Task<String, Error>?

    /// Commands a session answers before it is renewed.
    private static let commandsPerSession = 8
    private static var parameters: GenerateParameters { GenerateParameters(maxTokens: 300, temperature: 0.1, topP: 0.8, topK: 20) }

    func answer(_ prompt: String, mode: EditorMode, container: ModelContainer, generation: Int) async throws -> String {
        // One command at a time: a command still running (the router gave up on it) finishes first.
        if let running { _ = try? await running.value }
        let session = session(for: mode, container: container, generation: generation)
        let task = Task { () throws -> String in
            var text = ""
            for try await chunk in session.streamResponse(to: prompt) {
                text += chunk
                try Task.checkCancellation()
            }
            return text
        }
        running = task
        do {
            let text = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            running = nil
            return text
        } catch {
            running = nil
            // A failed or cancelled command leaves the transcript unsure: start clean next time.
            entries[mode] = nil
            throw error
        }
    }

    private func session(for mode: EditorMode, container: ModelContainer, generation: Int) -> ChatSession {
        if var entry = entries[mode], entry.generation == generation, entry.commands < Self.commandsPerSession {
            entry.commands += 1
            entries[mode] = entry
            return entry.session
        }
        var history: [Chat.Message] = []
        for (request, json) in IntentPrompt.fewShotExamples {
            history.append(.user("Request: \"\(request)\"\nJSON:"))
            history.append(.assistant(json))
        }
        let session = ChatSession(container, instructions: IntentPrompt.systemInstructions(mode: mode), history: history,
                                  generateParameters: Self.parameters, additionalContext: ["enable_thinking": false])
        entries[mode] = Entry(session: session, generation: generation, commands: 1)
        return session
    }

    /// One command through a fresh session for `mode`, its answer dropped; skipped when a session is there.
    func warm(_ prompt: String, mode: EditorMode, container: ModelContainer, generation: Int) async {
        if let entry = entries[mode], entry.generation == generation { return }
        _ = try? await answer(prompt, mode: mode, container: container, generation: generation)
    }

    func reset() {
        running?.cancel()
        running = nil
        entries = [:]
    }

    func stopGenerating() {
        running?.cancel()
    }
}
#endif
