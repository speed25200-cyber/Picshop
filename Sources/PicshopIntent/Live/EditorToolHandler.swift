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
    /// Act-then-verify: the check of a run's result may take this long (one render, one text pass);
    /// past it the steps stay unverified rather than hold the turn.
    var verifyTimeout: Double = 2.0

    public var language: NormalizedUtterance.Language = .french

    /// The last actions run through this handler, oldest first: apply_edits calls (.model), grammar
    /// plans (.grammar) and tapped chips (.idea). A ring of `recentActionsCapacity`.
    public private(set) var recentActions: [LiveActionRecord] = []
    public static let recentActionsCapacity = 8

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
            let execution = await run(intents)
            record(.model, intents: intents, execution: execution)
            return ToolResultEncoder.applyEdits(execution)
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
            let execution = await run(intents)
            record(.idea, intents: intents, execution: execution)
            return execution
        case .failure(let error):
            let message: String
            if case .problems(let problems) = error { message = problems.joined(separator: "; ") } else { message = "invalid idea" }
            let action = idea.steps.first.flatMap { IntentAction(rawValue: $0.action) } ?? .unknown
            // The chip no longer fits the picture: a coded failure, so no validator text is ever spoken.
            return finished([LiveStepResult(index: 0, action: action, status: .failed, message: message, reason: .unsupported)])
        }
    }

    /// Local fast lane: the grammar's intents, as they are.
    public func runPlan(_ plan: EditPlan) async -> LiveExecution {
        let intents = plan.intents.filter { $0.action != .unknown }
        let execution = await run(intents)
        record(.grammar, intents: intents, execution: execution)
        return execution
    }

    /// Keeps a run in `recentActions`, with its arguments in the model's vocabulary.
    private func record(_ source: LiveActionRecord.Source, intents: [EditIntent], execution: LiveExecution) {
        guard !intents.isEmpty, !execution.steps.isEmpty else { return }
        recentActions.append(LiveActionRecord(source: source, steps: intents.map(RawIntentStep.init(intent:)), results: execution.steps,
                                              version: execution.version))
        if recentActions.count > Self.recentActionsCapacity { recentActions.removeFirst(recentActions.count - Self.recentActionsCapacity) }
    }

    // MARK: Running

    private func run(_ intents: [EditIntent]) async -> LiveExecution {
        guard let host else { return LiveExecution(steps: [], version: 0, canUndo: false) }
        var results: [LiveStepResult] = []
        /// Act-then-verify: the checks the applied steps asked for, by step.
        var checks: [(step: Int, request: VerificationRequest)] = []
        /// D12 on every lane: a step identical to one that did not apply in this run is not run again.
        var missed: [LocalModelLiveBrain.StepSignature: LiveStepResult] = [:]
        var index = 0
        while index < intents.count {
            let intent = intents[index]
            if let earlier = missed[LocalModelLiveBrain.StepSignature(intent)] {
                results.append(LiveStepResult(index: index, action: intent.action, status: .blocked, message: earlier.message, reason: earlier.reason, hint: earlier.hint))
                index += 1
                continue
            }
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
            var result = LiveStepResult(index: index, intent: intent, run: run)
            result.createdRef = createdRef(of: result, run: run)
            if result.status == .applied, let request = run.verificationRequest { checks.append((results.count, request)) }
            if [.failed, .info, .needsUser].contains(result.status) { missed[LocalModelLiveBrain.StepSignature(intent)] = result }
            results.append(result)
            if result.stopsTheRun {
                results += skipped(intents, after: index)
                break
            }
            index += 1
        }
        results = await verified(results, checks: checks)
        return finished(results)
    }

    /// The scene id ("l2") of the text layer an applied text step selected (the layer it wrote), read from
    /// the editor's scene map right after the step, so the model can name it in a repair or a follow-up.
    private func createdRef(of result: LiveStepResult, run: LiveRunResult) -> String? {
        guard result.status == .applied, [.addText, .editText, .moveText].contains(result.action), let host else { return nil }
        let selected = run.effects.compactMap { effect -> UUID? in
            if case .selectLayer(let id) = effect { return id }
            return nil
        }.last
        guard let selected else { return nil }
        return host.liveIntentContext().scene?.texts.first { $0.layerID == selected }?.id
    }

    /// The execution as reported: hints on the steps that carry a reason, and whether the picture is a table.
    private func finished(_ steps: [LiveStepResult]) -> LiveExecution {
        let context = context()
        let hasTable = context.table != nil
        var execution = LiveExecution(steps: steps.map { step in
            var step = step
            if step.hint == nil {
                if step.status != .applied, step.status != .skipped, let reason = step.reason {
                    step.hint = ToolHints.hint(for: reason, action: step.action, hasTable: hasTable)
                } else if step.status == .applied, step.verification?.status == .failed {
                    step.hint = ToolHints.hint(for: .verifyFailed, action: step.action, hasTable: hasTable)
                }
            }
            return step
        }, version: host?.liveVersion ?? 0, canUndo: context.canUndo)
        execution.pictureIsTable = context.table?.coversPicture == true
        return execution
    }

    /// One look at the rendered result for every check the run asked for (`LiveEditingHost.liveVerify`),
    /// within `verifyTimeout`; past it the steps stay unverified. Each report lands on its step.
    private func verified(_ results: [LiveStepResult], checks: [(step: Int, request: VerificationRequest)]) async -> [LiveStepResult] {
        guard let host, !checks.isEmpty else { return results }
        let requests = checks.map(\.request)
        let looking = Task { @MainActor in await host.liveVerify(requests) }
        guard let reports = await Self.value(of: looking, within: verifyTimeout), !reports.isEmpty else { return results }
        var updated = results
        for (offset, check) in checks.enumerated() {
            let report = reports.first { $0.intentID == check.request.intentID && $0.action == check.request.action }
                ?? (reports.count == checks.count ? reports[offset] : nil)
            guard let report, updated.indices.contains(check.step) else { continue }
            updated[check.step].verification = report
        }
        return updated
    }

    private func finishInBackground(_ running: Task<LiveRunResult, Never>, index: Int, intents: [EditIntent], done: [LiveStepResult]) {
        Task { @MainActor [weak self] in
            var results = done
            var checks: [(step: Int, request: VerificationRequest)] = []
            let firstRun = await running.value
            var first = LiveStepResult(index: index, intent: intents[index], run: firstRun)
            first.createdRef = self?.createdRef(of: first, run: firstRun)
            if first.status == .applied, let request = firstRun.verificationRequest { checks.append((results.count, request)) }
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
                let run = await host.liveRun(intents[next])
                var result = LiveStepResult(index: next, intent: intents[next], run: run)
                result.createdRef = self.createdRef(of: result, run: run)
                if result.status == .applied, let request = run.verificationRequest { checks.append((results.count, request)) }
                results.append(result)
                if result.stopsTheRun {
                    results += self.skipped(intents, after: next)
                    break
                }
                next += 1
            }
            guard let self, self.host != nil else { return }
            results = await self.verified(results, checks: checks)
            self.onJobFinished(self.finished(results))
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
    private static func value<Value: Sendable>(of task: Task<Value, Never>, within seconds: Double) async -> Value? {
        let gate = FirstResult<Value>()
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
@MainActor private final class FirstResult<Value: Sendable> {
    var continuation: CheckedContinuation<Value?, Never>?

    func resume(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
