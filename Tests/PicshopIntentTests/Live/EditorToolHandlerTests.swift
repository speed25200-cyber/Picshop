import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// A photo editor as Live sees it, backed by the real PhotoCommandExecutor and the fake vision services.
@MainActor final class FakePhotoHost: LiveEditingHost {
    var document = PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000)))
    let executor: PhotoCommandExecutor
    var labels: [String] = []
    var revision = 0
    var liveSpeechSuppressed = false
    var busy = false
    /// Seconds a step of this action takes.
    var delays: [IntentAction: Double] = [:]
    var pending: ClarificationRequest?
    var compared: [Double] = []
    var runs: [IntentAction] = []

    init(candidates: [ObjectCandidate] = []) {
        executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: candidates), language: .french)
    }

    var liveMode: EditorMode { .photo }
    var liveVersion: Int { revision }
    var liveIsBusy: Bool { busy }
    var liveProcessingProgress: Double? { nil }
    var livePendingChoice: LiveChoiceRequest? {
        pending.map { request in
            LiveChoiceRequest(question: request.question, candidates: request.candidates.enumerated().map { .init(id: $0.offset + 1, label: $0.element.spokenDescription) },
                              allowsAll: true)
        }
    }

    func liveIntentContext() -> IntentContext {
        IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, pendingClarification: pending, canUndo: !labels.isEmpty)
    }

    func liveContextSummary() -> LiveEditorState {
        var state = LiveEditorState(mode: .photo, version: revision)
        state.appliedEdits = Array(labels.suffix(12))
        state.adjustments = document.activeAdjustments
        state.canUndo = !labels.isEmpty
        return state
    }

    func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        runs.append(intent.action)
        if let delay = delays[intent.action] {
            busy = true
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            busy = false
        }
        let (updated, result) = await executor.execute(intent, on: document, context: liveIntentContext())
        if result.changedDocument {
            document = updated
            labels.append(result.label)
            revision += 1
        }
        if case .needsClarification(let request) = result.outcome { pending = request }
        return LiveRunResult(outcome: result.outcome, effects: result.effects)
    }

    func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        guard !redo else { return [] }
        let taken = toOriginal ? labels : Array(labels.suffix(count))
        labels.removeLast(taken.count)
        if !taken.isEmpty { revision += 1 }
        return taken
    }

    func liveCompareBeforeAfter(seconds: Double) { compared.append(seconds) }
    func liveSnapshotImage(maxPixel: Int) async -> LiveImage? { nil }
    func liveHandleCommand(_ text: String) async -> LiveCommandReply { LiveCommandReply(text: text, isProblem: false, isError: false, language: "fr") }
    func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult { LiveRunResult(outcome: .ignored) }
    func liveCancelProcessing() -> Bool { false }
}

@MainActor
private final class Received {
    var ideas: [LiveIdea] = []
    var jobs: [LiveExecution] = []
}

/// The scenarios run on the main actor, as the session does.
@MainActor private enum HandlerScenarios {
    private static let dogs = [
        ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
        ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.75, y: 0.4, width: 0.2, height: 0.3), confidence: 0.88),
    ]

    static func makeHandler(_ host: FakePhotoHost, runningAfter: Double = 2.5) -> (EditorToolHandler, Received) {
        let received = Received()
        let handler = EditorToolHandler(host: host, runningAfter: runningAfter, onIdeas: { received.ideas = $0 }, onJobFinished: { received.jobs.append($0) })
        return (handler, received)
    }

    static func validIntents(_ steps: [RawIntentStep]) throws -> [EditIntent] {
        try ToolInputValidator(mode: .photo).steps(raw: steps, context: .photo).get()
    }

    static func testApplyEditsEndToEnd() async throws {
        let host = FakePhotoHost()
        let (handler, _) = makeHandler(host)
        let call = LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "adjust", parameter: "brightness", amount: 20), RawIntentStep(action: "autoEnhance", amount: 70)])))
        let result = await handler.perform(call)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.changedDocument)
        XCTAssertEqual(result.execution?.steps.map(\.status), [.applied, .applied])
        XCTAssertEqual(result.execution?.steps.map(\.label), ["Brightness +20", "Auto Enhance"])
        XCTAssertEqual(result.execution?.version, 2)
        XCTAssertEqual(result.execution?.canUndo, true)
        XCTAssertEqual(result.payload["version"], 2)
        XCTAssertEqual(host.document.activeAdjustments[.brightness], 0.2, accuracy: 1e-9)
        XCTAssertEqual(handler.context().canUndo, true)
    }

    static func testClarificationStopsAndSkips() async throws {
        let host = FakePhotoHost(candidates: Self.dogs)
        let (handler, _) = makeHandler(host)
        let result = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "removeObject", target: "dog"),
                                                                                               RawIntentStep(action: "autoEnhance")]))))
        let steps = result.execution?.steps ?? []
        XCTAssertEqual(steps.map(\.status), [.needsClarification, .skipped])
        XCTAssertEqual(steps[0].candidates, ["dog (left)", "dog (right)"])
        XCTAssertNotNil(steps[0].message)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(host.runs, [.removeObject], "nothing after the question runs")
        XCTAssertEqual(host.livePendingChoice?.candidates.count, 2)
    }

    static func testFailureStopsAndNeedsUserIsReported() async throws {
        let host = FakePhotoHost()
        let (handler, _) = makeHandler(host)
        let failed = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "selectiveAdjust", target: "sky", parameter: "saturation", amount: 20),
                                                                                               RawIntentStep(action: "autoEnhance")]))))
        XCTAssertEqual(failed.execution?.steps.map(\.status), [.failed, .skipped])
        XCTAssertTrue(failed.isError, "every step that ran failed")
        let region = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits([EditIntent(action: .generativeFill, text: "a hat")])))
        XCTAssertEqual(region.execution?.steps.first?.status, .needsUser)
        XCTAssertEqual(region.execution?.steps.first?.needsUser, "select_region")
        XCTAssertEqual(region.payload["results"]?.array?.first?["needs"], "select_region")
    }

    static func testSlowStepRunsOnInTheBackground() async throws {
        let host = FakePhotoHost()
        host.delays[.autoEnhance] = 0.3
        let (handler, received) = makeHandler(host, runningAfter: 0.05)
        let result = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "adjust", parameter: "contrast", amount: 10),
                                                                                               RawIntentStep(action: "autoEnhance"),
                                                                                               RawIntentStep(action: "adjust", parameter: "vibrance", amount: 20)]))))
        XCTAssertEqual(result.execution?.steps.map(\.status), [.applied, .running, .queued])
        XCTAssertEqual(result.payload["results"]?.array?[1]["job"], "autoEnhance")
        XCTAssertTrue(received.jobs.isEmpty)
        for _ in 0..<100 where received.jobs.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(received.jobs.first?.steps.map(\.status), [.applied, .applied, .applied])
        XCTAssertEqual(host.labels.count, 3)
        XCTAssertEqual(host.runs, [.adjust, .autoEnhance, .adjust], "in order")
    }

    static func testBusyHostIsWaitedFor() async throws {
        let host = FakePhotoHost()
        host.busy = true
        let (handler, _) = makeHandler(host)
        handler.busyPoll = 0.01
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            host.busy = false
        }
        let result = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "autoEnhance")]))))
        XCTAssertEqual(result.execution?.steps.map(\.status), [.applied])
        host.busy = true
        handler.busyTimeout = 0.05
        let busy = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "autoEnhance"), RawIntentStep(action: "flip")]))))
        XCTAssertEqual(busy.execution?.steps.map(\.status), [.failed, .skipped])
        XCTAssertEqual(busy.execution?.steps.first?.message, "Une autre opération est encore en cours.")
    }

    static func testUndoCompareAndIdeas() async throws {
        let host = FakePhotoHost()
        let (handler, received) = makeHandler(host)
        let nothing = await handler.perform(LiveToolCall(id: "u", tool: .undo(count: 1, redo: false, toOriginal: false)))
        XCTAssertEqual(nothing.payload["ok"], false)
        XCTAssertFalse(nothing.isError)
        _ = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits(try validIntents([RawIntentStep(action: "autoEnhance"), RawIntentStep(action: "flip")]))))
        let undone = await handler.perform(LiveToolCall(id: "u", tool: .undo(count: 1, redo: false, toOriginal: false)))
        XCTAssertEqual(undone.payload["undone"], ["Flip Horizontal"])
        XCTAssertEqual(undone.payload["version"], 3)
        _ = await handler.perform(LiveToolCall(id: "c", tool: .compare(seconds: 2)))
        XCTAssertEqual(host.compared, [2])
        let good = LiveIdea(title: "Noir et blanc", why: "Graphique.", symbol: nil, steps: [RawIntentStep(action: "applyLook", look: "mono")], source: .claude)
        let broken = LiveIdea(title: "Cassé", why: "", symbol: nil, steps: [], source: .claude)
        let ideas = await handler.perform(LiveToolCall(id: "i", tool: .proposeIdeas([good, broken])))
        XCTAssertEqual(ideas.payload.serialized(), #"{"ok":true,"replaced":1,"shown":1}"#)
        XCTAssertEqual(received.ideas, [good])
    }

    static func testIdeasAndPlans() async throws {
        let host = FakePhotoHost()
        let (handler, _) = makeHandler(host)
        let idea = IdeaEngine.generic(mode: .photo, language: .french).first { $0.steps.first?.action == "autoEnhance" }!
        let ran = await handler.runIdea(idea)
        XCTAssertTrue(ran.allApplied)
        let invalid = LiveIdea(title: "Couper", why: "", symbol: nil, steps: [RawIntentStep(action: "split", seconds: 2)], source: .claude)
        let refused = await handler.runIdea(invalid)
        XCTAssertEqual(refused.steps.map(\.status), [.failed])
        let plan = RuleBasedIntentEngine().parse("plus lumineux", context: .photo)
        let local = await handler.runPlan(plan)
        XCTAssertTrue(local.allApplied)
        XCTAssertEqual(local.outcomeText(language: .french), "C'est fait.")
    }

    static func testHostGone() async throws {
        var host: FakePhotoHost? = FakePhotoHost()
        let handler = EditorToolHandler(host: host!, onIdeas: { _ in }, onJobFinished: { _ in })
        host = nil
        let result = await handler.perform(LiveToolCall(id: "t", tool: .compare(seconds: 2)))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(handler.context().mode, .photo)
    }

    static func testHostExecuteStopsAfterAFailure() async throws {
        let host = FakePhotoHost()
        let execution = await host.execute(steps: [EditIntent(action: .adjust, parameter: .brightness, amount: .relative(0.1)),
                                                   EditIntent(action: .selectiveAdjust, target: ObjectTarget(label: "sky"), parameter: .saturation),
                                                   EditIntent(action: .autoEnhance)])
        XCTAssertEqual(execution.steps.map(\.status), [.applied, .failed, .skipped])
        XCTAssertEqual(execution.version, 1)
    }
}

final class EditorToolHandlerTests: XCTestCase {
    func testApplyEditsEndToEnd() async throws { try await HandlerScenarios.testApplyEditsEndToEnd() }
    func testClarificationStopsAndSkips() async throws { try await HandlerScenarios.testClarificationStopsAndSkips() }
    func testFailureStopsAndNeedsUserIsReported() async throws { try await HandlerScenarios.testFailureStopsAndNeedsUserIsReported() }
    func testSlowStepRunsOnInTheBackground() async throws { try await HandlerScenarios.testSlowStepRunsOnInTheBackground() }
    func testBusyHostIsWaitedFor() async throws { try await HandlerScenarios.testBusyHostIsWaitedFor() }
    func testUndoCompareAndIdeas() async throws { try await HandlerScenarios.testUndoCompareAndIdeas() }
    func testIdeasAndPlans() async throws { try await HandlerScenarios.testIdeasAndPlans() }
    func testHostGone() async throws { try await HandlerScenarios.testHostGone() }
    func testHostExecuteStopsAfterAFailure() async throws { try await HandlerScenarios.testHostExecuteStopsAfterAFailure() }
}

final class LocalLiveBrainTests: XCTestCase {
    private func run(_ text: String, kind: LiveUserTurn.Kind = .speech, host: FakePhotoHost) async -> [LiveBrainEvent] {
        let brain = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: .photo)
        let handler = await MainActor.run { EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in }) }
        var turn = LiveUserTurn.speech(text)
        turn.kind = kind
        if text.isEmpty { turn.language = .french }
        return await collect(brain.respond(to: turn, tools: handler)).events
    }

    func testCommandRunsThroughTheHandler() async {
        let host = await FakePhotoHost()
        let events = await run("plus lumineux", host: host)
        XCTAssertEqual(events.toolNames, [.applyEdits])
        XCTAssertEqual(events.completion, .answered)
        XCTAssertFalse(events.spoken.isEmpty)
        let labels = await host.labels
        XCTAssertEqual(labels.count, 1)
        let isAvailable = await LocalLiveBrain(router: HybridIntentRouter(), mode: .photo).isAvailable()
        XCTAssertTrue(isAvailable)
    }

    func testNothingToRunSuggests() async {
        let events = await run("raconte-moi une blague sur les pingouins", host: await FakePhotoHost())
        XCTAssertEqual(events.toolNames, [])
        XCTAssertEqual(events.spoken, Replies.suggestions(for: .photo, language: .french))
        XCTAssertEqual(events.completion, .answered)
    }

    func testExecutorQuestionIsSaid() async {
        let host = await FakePhotoHost(candidates: [
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
            ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.75, y: 0.4, width: 0.2, height: 0.3), confidence: 0.88),
        ])
        let events = await run("efface le chien", host: host)
        let pending = await host.pending
        XCTAssertEqual(events.spoken, pending?.question)
    }

    func testSessionStartGreets() async {
        let events = await run("", kind: .sessionStart, host: await FakePhotoHost())
        XCTAssertEqual(events.spoken, LiveLines.line(.greetingLocal, .french))
        XCTAssertEqual(events.toolNames, [])
    }
}
