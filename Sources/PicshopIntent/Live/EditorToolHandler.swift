import Foundation
import PicshopCore

/// Runs a brain's tool calls, a tapped idea or a grammar plan on the open editor.
///
/// Steps run in order through the host. A step still running after
/// `runningAfter` seconds is reported as running (the rest as queued) so the
/// conversation can go on; the background run finishes them and calls
/// `onJobFinished`.
@MainActor public final class EditorToolHandler: LiveToolHandler {
    private weak var host: (any LiveEditingHost)?
    private let mode: EditorMode
    private let runningAfter: Double
    private let onIdeas: @MainActor ([LiveIdea]) -> Void
    private let onJobFinished: @MainActor (LiveExecution) -> Void
    /// A heavy step already running is waited for, polled this often, at most `busyTimeout`.
    var busyPoll: Double = 0.1
    var busyTimeout: Double = 20

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
        guard let host else { return LiveToolResult(isError: true, payload: ["error": "editor_closed"], changedDocument: false) }
        switch call.tool {
        case .applyEdits(let intents):
            return ToolResultEncoder.applyEdits(await run(intents))
        case .undo(let count, let redo, let toOriginal):
            let labels = host.liveUndo(count: count, redo: redo, toOriginal: toOriginal)
            return ToolResultEncoder.undo(labels: labels, redo: redo, version: host.liveVersion, language: language)
        case .compare(let seconds):
            host.liveCompareBeforeAfter(seconds: seconds)
            return ToolResultEncoder.compare()
        case .proposeIdeas(let ideas):
            // Invalid ideas arrive without steps; the session fills their slots with its own.
            let valid = ideas.filter { !$0.steps.isEmpty }
            onIdeas(valid)
            return ToolResultEncoder.ideas(shown: valid.count, replaced: ideas.count - valid.count)
        }
    }

    /// Chip tap: no model call. The steps are checked again against the editor as it is now.
    public func runIdea(_ idea: LiveIdea) async -> LiveExecution {
        switch ToolInputValidator(mode: mode).steps(raw: idea.steps, context: context()) {
        case .success(let intents):
            return await run(intents)
        case .failure(let error):
            let message: String
            if case .problems(let problems) = error { message = problems.joined(separator: "; ") } else { message = "invalid idea" }
            let action = idea.steps.first.flatMap { IntentAction(rawValue: $0.action) } ?? .unknown
            return LiveExecution(steps: [LiveStepResult(index: 0, action: action, status: .failed, message: message)], version: host?.liveVersion ?? 0,
                                 canUndo: context().canUndo)
        }
    }

    /// Local fast lane: the grammar's intents, as they are.
    public func runPlan(_ plan: EditPlan) async -> LiveExecution {
        await run(plan.intents.filter { $0.action != .unknown })
    }

    // MARK: Running

    private func run(_ intents: [EditIntent]) async -> LiveExecution {
        guard let host else { return LiveExecution(steps: [], version: 0, canUndo: false) }
        var results: [LiveStepResult] = []
        var index = 0
        while index < intents.count {
            let intent = intents[index]
            guard await waitUntilIdle() else {
                results.append(LiveStepResult(index: index, action: intent.action, status: .failed, message: busyMessage))
                results += skipped(intents, after: index)
                break
            }
            let step = Task { @MainActor in await host.liveRun(intent) }
            guard let run = await Self.value(of: step, within: runningAfter) else {
                // Still running: report it and let the rest finish in the background.
                results.append(LiveStepResult(index: index, action: intent.action, status: .running))
                results += intents.indices.dropFirst(index + 1).map { LiveStepResult(index: $0, action: intents[$0].action, status: .queued) }
                let done = Array(results.prefix(index))
                finishInBackground(step, index: index, intents: intents, done: done)
                break
            }
            let result = LiveStepResult(index: index, intent: intent, run: run)
            results.append(result)
            if result.stopsTheRun {
                results += skipped(intents, after: index)
                break
            }
            index += 1
        }
        return LiveExecution(steps: results, version: host.liveVersion, canUndo: host.liveIntentContext().canUndo)
    }

    private func finishInBackground(_ running: Task<LiveRunResult, Never>, index: Int, intents: [EditIntent], done: [LiveStepResult]) {
        Task { @MainActor [weak self] in
            var results = done
            let first = LiveStepResult(index: index, intent: intents[index], run: await running.value)
            results.append(first)
            var next = index + 1
            if first.stopsTheRun {
                results += self?.skipped(intents, after: index) ?? []
                next = intents.count
            }
            while next < intents.count, let self, let host = self.host {
                guard await self.waitUntilIdle() else {
                    results.append(LiveStepResult(index: next, action: intents[next].action, status: .failed, message: self.busyMessage))
                    results += self.skipped(intents, after: next)
                    break
                }
                let result = LiveStepResult(index: next, intent: intents[next], run: await host.liveRun(intents[next]))
                results.append(result)
                if result.stopsTheRun {
                    results += self.skipped(intents, after: next)
                    break
                }
                next += 1
            }
            guard let self, let host = self.host else { return }
            self.onJobFinished(LiveExecution(steps: results, version: host.liveVersion, canUndo: host.liveIntentContext().canUndo))
        }
    }

    private func skipped(_ intents: [EditIntent], after index: Int) -> [LiveStepResult] {
        intents.indices.dropFirst(index + 1).map { LiveStepResult(index: $0, action: intents[$0].action, status: .skipped) }
    }

    /// True once the host is free; false after `busyTimeout`.
    private func waitUntilIdle() async -> Bool {
        var waited = 0.0
        while host?.liveIsBusy == true {
            guard waited < busyTimeout else { return false }
            try? await Task.sleep(nanoseconds: UInt64(busyPoll * 1_000_000_000))
            waited += busyPoll
        }
        return true
    }

    private var busyMessage: String {
        language == .french ? "Une autre opération est encore en cours." : "Something else is still running."
    }

    /// The task's value if it arrives within the time, else nil (the task keeps running).
    private static func value(of task: Task<LiveRunResult, Never>, within seconds: Double) async -> LiveRunResult? {
        let gate = FirstResult()
        return await withCheckedContinuation { continuation in
            gate.continuation = continuation
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.resume(nil)
            }
            Task { @MainActor in
                let value = await task.value
                timer.cancel()
                gate.resume(value)
            }
        }
    }
}

/// Resumes a continuation once, with whichever result comes first.
@MainActor private final class FirstResult {
    var continuation: CheckedContinuation<LiveRunResult?, Never>?

    func resume(_ value: LiveRunResult?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
