import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

// The model brain's recovery policy (contract §11, D12): a step identical to one that failed this turn
// is blocked, a reasoned failure or a failed check gets exactly one greedy repair round, a turn never
// ends on a failure left unsaid, the executor's raw text is never spoken, sampling follows the turn,
// and model.tool logs the step actions and reason codes.

/// An editor whose apply_edits results are scripted per call, with codes, reports and checks.
@MainActor final class CodedToolHandler: LiveToolHandler {
    var intentContext = IntentContext.photo
    private(set) var calls: [[EditIntent]] = []
    /// The steps of the n-th apply_edits call (the last one repeats).
    var results: [([EditIntent]) -> [LiveStepResult]] = []
    var pictureIsTable = false
    var version = 10

    nonisolated init() {}

    func context() -> IntentContext { intentContext }

    func perform(_ call: LiveToolCall) async -> LiveToolResult {
        switch call.tool {
        case .applyEdits(let intents):
            calls.append(intents)
            let script = results.isEmpty ? { intents in intents.indices.map { LiveStepResult(index: $0, action: intents[$0].action, status: .applied, label: "Done") } }
                : results[min(calls.count - 1, results.count - 1)]
            let steps = script(intents)
            if steps.contains(where: { $0.status == .applied }) { version += 1 }
            var execution = LiveExecution(steps: steps, version: version, canUndo: true)
            execution.pictureIsTable = pictureIsTable
            return ToolResultEncoder.applyEdits(execution)
        case .undo(_, let redo, _):
            return ToolResultEncoder.undo(labels: ["Done"], redo: redo, version: version)
        case .compare:
            return ToolResultEncoder.compare()
        case .proposeIdeas(let ideas):
            return ToolResultEncoder.ideas(shown: ideas.count, replaced: 0)
        }
    }

    static func noSubject(_ intents: [EditIntent]) -> [LiveStepResult] {
        [LiveStepResult(index: 0, action: intents[0].action, status: .failed, message: "Je ne vois ni personne ni sujet à détacher sur cette image.",
                        reason: .noSubject, hint: ToolHints.hint(for: .noSubject, action: intents[0].action, hasTable: true))]
    }

    static func filled(_ intents: [EditIntent]) -> [LiveStepResult] {
        [LiveStepResult(index: 0, action: .fillCells, status: .applied, label: "Fill Cells",
                        report: TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1"))]
    }

    static func unreadable(_ intents: [EditIntent]) -> [LiveStepResult] {
        let check = VerificationCheck(kind: .textPresent, region: PSRect(x: 0.4, y: 0.3, width: 0.1, height: 0.04), text: "1", tag: "r2c1")
        let report = VerificationReport(intentID: intents[0].id, action: .fillCells, items: [.init(check: check, outcome: .failed, observed: "7")], method: .pixels)
        var step = filled(intents)[0]
        step.verification = report
        step.hint = ToolHints.hint(for: .verifyFailed, action: .fillCells, hasTable: true)
        return [step]
    }

    static func readable(_ intents: [EditIntent]) -> [LiveStepResult] {
        let check = VerificationCheck(kind: .textPresent, region: PSRect(x: 0.4, y: 0.3, width: 0.1, height: 0.04), text: "1", tag: "r2c1")
        var step = filled(intents)[0]
        step.verification = VerificationReport(intentID: intents[0].id, action: .fillCells, items: [.init(check: check, outcome: .passed)], method: .pixels)
        return [step]
    }
}

final class LocalTurnRepairTests: XCTestCase {
    private func brain(_ factory: FakeEngineFactory, limits: LocalModelLiveBrain.Limits = .init(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) -> LocalModelLiveBrain {
        LocalModelLiveBrain(mode: .photo, info: .qwen4B, makeEngine: factory.factory, fallback: FakeFallbackBrain(), limits: limits, clock: BrainTestClock(), log: log)
    }

    static let behind: JSONValue = ["steps": [["action": "textBehind", "text": "1"]]]
    static let fill: JSONValue = ["steps": [["action": "fillCells", "cells": "empty", "text": 1]]]
    static let fillAll: JSONValue = ["steps": [["action": "fillCells", "cells": "all", "text": "1"]]]

    // D12: the same step, failed once, is never run again in the turn.
    func testAnIdenticalFailedStepIsBlockedAndNotRun() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Say.warmer), Say.done()],
            [Say.call("apply_edits", Say.warmer, id: "call_2"), Say.done()],
            [.text("Je n'y arrive pas ici."), Say.done()],
        ]])
        let handler = ScriptedToolHandler()
        await MainActor.run { handler.stepStatus = .failed }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("plus chaud"), tools: handler))
        XCTAssertNil(error)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 1, "the repeat never reaches the editor")
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 3)
        let blocked = try XCTUnwrap(engine.sent[2].first?.toolResultContent)
        XCTAssertTrue(blocked.hasPrefix("1 adjust blocked[repeat]: already failed this turn."), blocked)
        XCTAssertEqual(engine.options[2].temperature, 0, "the round after a block is the greedy repair round")
        XCTAssertEqual(events.said, "Je n'y arrive pas ici.")
        assertSpeakable(events)
    }

    // A reasoned failure: one repair round at temperature 0, with the code and the hint; the model follows it.
    func testAReasonedFailureGetsOneGreedyRepairRound() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je le glisse derrière."), Say.call("apply_edits", Self.behind), Say.done()],
            [.text("Pas de sujet ici : je remplis les cases."), Say.call("apply_edits", Self.fill, id: "call_2"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run {
            handler.results = [CodedToolHandler.noSubject, CodedToolHandler.filled]
            handler.pictureIsTable = true
        }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("il faut remplir les autres cases aussi"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.end, .editApplied)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 2)
        let result = try XCTUnwrap(engine.sent[1].first?.toolResultContent)
        XCTAssertTrue(result.hasPrefix("1 textBehind failed[no_subject]: no person or main subject here. Do not retry this step. Hint: To write in the table use fillCells"), result)
        XCTAssertFalse(result.contains("Je ne vois"), "a coded failure never carries the French message")
        XCTAssertEqual(engine.options[0].temperature, 0.25, "an edit-like turn")
        XCTAssertEqual(engine.options[1].temperature, 0, "the repair round is greedy")
        let calls = await handler.calls
        XCTAssertEqual(calls.map { $0.map(\.action) }, [[.textBehind], [.fillCells]])
        XCTAssertFalse(events.said.lowercased().contains("subject"))
    }

    // The report's model that insists: the repeat is blocked, no third run, one honest line, never silent.
    func testAModelThatInsistsIsBlockedAndTheTurnSaysWhy() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Self.behind), Say.done()],
            [Say.call("apply_edits", Self.behind, id: "call_2"), Say.done()],
            [Say.call("apply_edits", Self.behind, id: "call_3"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run {
            handler.results = [CodedToolHandler.noSubject]
            handler.pictureIsTable = true
        }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("il faut remplir les autres cases aussi"), tools: handler))
        XCTAssertNil(error)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 1, "never a second executor run of the same step")
        XCTAssertEqual(factory.engines.first?.sent.count, 2, "one repair round, then the turn ends")
        XCTAssertEqual(events.said, LiveLines.outcome(.noSubject, action: .textBehind, hasTable: true, .french))
        XCTAssertFalse(events.said.contains("«"))
        XCTAssertEqual(events.end, .loopLimit)
    }

    // A failure after the model already spoke: the failure is still said, after its sentence.
    func testAFailureIsNeverLeftUnsaid() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je le glisse derrière."), Say.call("apply_edits", Self.behind), Say.done()],
            [Say.call("apply_edits", Self.behind, id: "call_2"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.noSubject] }
        let (events, _) = await drain(brain(factory).respond(to: BrainTurns.speech("mets 1 derrière la personne"), tools: handler))
        XCTAssertEqual(events.said, "Je le glisse derrière. " + LiveLines.outcome(.noSubject, action: .textBehind, hasTable: false, .french))
    }

    // Act-then-verify: a failed check gets one repair round with the summary; the fixed step passes.
    func testAFailedCheckGetsOneRepairRound() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je remplis."), Say.call("apply_edits", Self.fill), Say.done()],
            [Say.call("apply_edits", Self.fillAll, id: "call_2"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.unreadable, CodedToolHandler.readable] }
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("remplis toutes les cases avec des 1"), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.end, .editApplied)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 2)
        let result = try XCTUnwrap(engine.sent[1].first?.toolResultContent)
        XCTAssertTrue(result.contains("filled 45"), result)
        XCTAssertTrue(result.contains("verify failed 1/1: r2c1 reads '7'"), result)
        XCTAssertTrue(result.contains("Hint:"), result)
        XCTAssertEqual(engine.options[1].temperature, 0)
        XCTAssertEqual(events.said, "Je remplis.", "a fixed result needs no second line")
    }

    // The repair names what the first round made: the context is read again after it, so "l1" validates and runs,
    // and the result the model read named it ("Add Text (l1)").
    func testTheRepairNamesTheLayerTheFirstRoundMade() async throws {
        let add: JSONValue = ["steps": [["action": "addText", "text": "Merci", "ref": "f1"]]]
        let bigger: JSONValue = ["steps": [["action": "editText", "ref": "l1", "size": "large"]]]
        let factory = FakeEngineFactory(scripts: [[
            [.text("J'écris dans le ciel."), Say.call("apply_edits", add), Say.done()],
            [.text("Je l'agrandis."), Say.call("apply_edits", bigger, id: "call_2"), Say.done()],
        ]])
        let handler = SceneToolHandler()
        let (events, error) = await drain(brain(factory).respond(to: BrainTurns.speech("écris « Merci » dans le ciel"), tools: handler))
        XCTAssertNil(error)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 2, "the repair was validated against the picture as the first round left it, and ran")
        XCTAssertEqual(calls.last?.first?.action, .editText)
        XCTAssertEqual(calls.last?.first?.ref, .layer(1))
        let engine = try XCTUnwrap(factory.engines.first)
        let result = try XCTUnwrap(engine.sent[1].first?.toolResultContent)
        XCTAssertTrue(result.contains("Add Text (l1)"), result)
        XCTAssertTrue(result.contains("verify failed 1/1: text missing"), result)
        XCTAssertEqual(events.end, .editApplied)
    }

    // Still unreadable after the repair round: one honest sentence, no third try.
    func testACheckThatStillFailsIsSaidHonestly() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je remplis."), Say.call("apply_edits", Self.fill), Say.done()],
            [Say.call("apply_edits", Self.fillAll, id: "call_2"), Say.done()],
            [Say.call("apply_edits", Self.fillAll, id: "call_3"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.unreadable] }
        let (events, _) = await drain(brain(factory).respond(to: BrainTurns.speech("remplis toutes les cases avec des 1"), tools: handler))
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 2, "one repair round")
        XCTAssertEqual(events.end, .editApplied)
        XCTAssertTrue(events.said.hasPrefix("Je remplis. C'est fait en partie : 1 case sur 1 ne se lit pas bien"), events.said)
    }

    // finish() never speaks the executor's raw text: the reason-aware line, or the sanitized message.
    func testFinishNeverSpeaksRawExecutorText() async throws {
        let factory = FakeEngineFactory(scripts: [[[Say.call("apply_edits", Self.behind), Say.done()], [Say.done()]]])
        let handler = CodedToolHandler()
        await MainActor.run {
            handler.results = [{ intents in [LiveStepResult(index: 0, action: intents[0].action, status: .failed, message: "Je ne trouve pas « subject » sur la photo.")] }]
        }
        let (events, _) = await drain(brain(factory).respond(to: BrainTurns.speech("mets 1 derrière la personne"), tools: handler))
        XCTAssertEqual(events.said, "Je ne trouve pas « sujet » sur la photo.")
        XCTAssertFalse(events.said.contains("subject"))
    }

    // Sampling per turn: edits 0.25 and no presence penalty; questions, opinions, the session start 0.6.
    func testSamplingFollowsTheTurn() async throws {
        let answer: [LocalChatEvent] = [.text("D'accord."), Say.done()]
        for (turn, temperature) in [(BrainTurns.speech("plus chaud"), 0.25), (BrainTurns.speech("tu en penses quoi ?"), 0.6),
                                    (BrainTurns.speech("pourquoi le ciel est gris ?"), 0.6), (BrainTurns.speech("les autres aussi"), 0.25),
                                    (BrainTurns.sessionStart(), 0.6)] {
            let factory = FakeEngineFactory(scripts: [[answer]])
            _ = await drain(brain(factory).respond(to: turn, tools: ScriptedToolHandler()))
            let options = try XCTUnwrap(factory.engines.first?.options.first)
            XCTAssertEqual(options.temperature, temperature, turn.text)
            XCTAssertEqual(options.topK, 20)
            XCTAssertEqual(options.presencePenalty, temperature == 0.25 ? 0 : 0.3, turn.text)
        }
    }

    // RC12: model.tool carries the step actions and the reason codes, never the words.
    func testTheToolLogCarriesActionsAndReasons() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Self.behind), Say.done()],
            [Say.call("apply_edits", Self.behind, id: "call_2"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.noSubject] }
        let entries = LogCollectorBox()
        _ = await drain(brain(factory, log: { entries.add($0) }).respond(to: BrainTurns.speech("mets 1 derrière la personne"), tools: handler))
        let tools = entries.all.filter { $0.event == "model.tool" }
        XCTAssertEqual(tools.map { $0.fields["actions"] }, ["textBehind", "textBehind"])
        XCTAssertEqual(tools.map { $0.fields["reasons"] }, ["no_subject", "repeat"])
        XCTAssertTrue(entries.events.contains("model.repair_exhausted"))
        for entry in entries.all { XCTAssertFalse(entry.fields.values.contains { $0.contains("derrière") }) }
    }

    // A call made only of repeats does not count toward maxApplyEdits: it comes back blocked, not "too many".
    func testABlockedCallDoesNotCountTowardTheLimit() async throws {
        var limits = LocalModelLiveBrain.Limits()
        limits.maxApplyEdits = 1
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Self.behind), Say.done()],
            [Say.call("apply_edits", Self.behind, id: "call_2"), Say.done()],
            [.text("D'accord."), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.noSubject] }
        let brain = brain(factory, limits: limits)
        _ = await drain(brain.respond(to: BrainTurns.speech("mets 1 derrière"), tools: handler))
        _ = await drain(brain.respond(to: BrainTurns.speech("ok", id: 2, version: 11), tools: handler))
        let owed = try XCTUnwrap(factory.engines.first?.sent[2].first?.toolResultContent)
        XCTAssertTrue(owed.hasPrefix("1 textBehind blocked[repeat]"), owed)
    }

    // Two steps, one a repeat: the other runs, the repeat comes back blocked in its place.
    func testOnlyTheRepeatIsBlockedInAMixedCall() async throws {
        let mixed: JSONValue = ["steps": [["action": "textBehind", "text": "1"], ["action": "fillCells", "cells": "empty", "text": "1"]]]
        let factory = FakeEngineFactory(scripts: [[
            [Say.call("apply_edits", Self.behind), Say.done()],
            [.text("Je remplis plutôt les cases."), Say.call("apply_edits", mixed, id: "call_2"), Say.done()],
        ]])
        let handler = CodedToolHandler()
        await MainActor.run { handler.results = [CodedToolHandler.noSubject, CodedToolHandler.filled] }
        let (events, _) = await drain(brain(factory).respond(to: BrainTurns.speech("remplis le tableau"), tools: handler))
        let calls = await handler.calls
        XCTAssertEqual(calls.map { $0.map(\.action) }, [[.textBehind], [.fillCells]])
        let finished = events.compactMap { event -> LiveExecution? in
            if case .toolFinished(_, _, let result) = event { return result.execution }
            return nil
        }
        XCTAssertEqual(finished.last?.steps.map(\.status), [.blocked, .applied])
        XCTAssertEqual(finished.last?.steps.map(\.index), [0, 1])
    }
}

/// An editor on the poster's scene map: an applied addText adds the layer l1 to the map (as the session's
/// overlaid map does), with a failed check the first time.
@MainActor final class SceneToolHandler: LiveToolHandler {
    private(set) var calls: [[EditIntent]] = []
    private var scene = SceneFixtures.posterScene()
    private var version = 10

    nonisolated init() {}

    func context() -> IntentContext { IntentContext(mode: .photo, scene: scene) }

    func perform(_ call: LiveToolCall) async -> LiveToolResult {
        guard case .applyEdits(let intents) = call.tool else { return ToolResultEncoder.compare() }
        calls.append(intents)
        version += 1
        var steps: [LiveStepResult] = []
        for (index, intent) in intents.enumerated() {
            var step = LiveStepResult(index: index, action: intent.action, status: .applied, label: intent.action == .addText ? "Add Text" : "Edit Text")
            if intent.action == .addText {
                var element = TextElement(text: intent.text ?? "")
                element.center = PSPoint(x: 0.84, y: 0.31)
                element.relativeSize = 0.012
                scene = scene.overlaying([Layer(name: element.text, content: .text(element))])
                step.createdRef = scene.texts.last?.id
                let check = VerificationCheck(kind: .textPresent, region: PSRect(x: 0.7, y: 0.22, width: 0.28, height: 0.18), text: intent.text, tag: "text")
                step.verification = VerificationReport(intentID: intent.id, action: .addText, items: [.init(check: check, outcome: .failed)], method: .pixels)
                step.hint = ToolHints.hint(for: .verifyFailed, action: .addText, hasTable: false)
            }
            steps.append(step)
        }
        return ToolResultEncoder.applyEdits(LiveExecution(steps: steps, version: version, canUndo: true))
    }
}
