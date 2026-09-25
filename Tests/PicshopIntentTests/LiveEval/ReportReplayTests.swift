import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The conversation of the report, replayed (A3, A4): "Remplis chaque case du tableau avec le chiffre 1 ou
/// des chiffres aléatoires", then "Il faut remplir les autres cases aussi.", on the benchmark screenshot,
/// through the real executor. The old build put one giant "1" in a cell, then said « Je ne trouve pas
/// « subject » sur la photo. » and offered two unrelated look chips.
final class ReportReplayTests: XCTestCase {
    static let first = "Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires"
    static let second = "Il faut remplir les autres cases aussi."

    // A3: the model lane fills the table in one step: coerced (a number as text), validated, run once.
    func testTheModelFillsTheTableInOneStep() async throws { try await ReplayScenarios.modelFillsInOneStep() }

    // A4: a worst-case model that follows the hint after the refusal ends with 45 cells filled.
    func testAModelThatFollowsTheHintFillsTheTable() async throws { try await ReplayScenarios.followsTheHint() }

    // A4: a model that insists is blocked, never runs textBehind, and the turn says why in French.
    func testAModelThatInsistsIsToldWhyAndNeverRunsIt() async throws { try await ReplayScenarios.insists() }

    // A4, grammar lane: both sentences take the fast lane with the model loaded, and the table ends full.
    func testTheGrammarLaneHandlesBothSentencesAlone() async throws { try await ReplayScenarios.grammarLane() }

    // A4: no generic look chips on the table screenshot, even when the model proposes them.
    func testNoGenericLookChipsOnTheTable() async throws { try await ReplayScenarios.noLookChips() }
}

@MainActor private enum ReplayScenarios {
    static func make(_ factory: FakeEngineFactory, _ log: (@Sendable (LiveLogEntry) -> Void)?) -> LocalModelLiveBrain {
        LocalModelLiveBrain(mode: .photo, info: .qwen4B, makeEngine: factory.factory, fallback: nil, clock: BrainTestClock(), log: log)
    }

    static func turn(_ text: String, id: Int, host: TableEditorHost, handler: EditorToolHandler) -> LiveUserTurn {
        LiveUserTurn(id: id, kind: .speech, text: text, language: .french, image: nil, editorState: host.liveContextSummary(),
                     recentActions: Array(handler.recentActions.suffix(3)))
    }

    static func assertNoInternalWord(_ spoken: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(spoken.isEmpty, "never silent", file: file, line: line)
        XCTAssertFalse(spoken.lowercased().contains("subject"), spoken, file: file, line: line)
        XCTAssertFalse(spoken.contains("« "), "no label inside « »: \(spoken)", file: file, line: line)
        XCTAssertTrue(LiveSpeechSanitizer.isClean(spoken, language: .french), spoken, file: file, line: line)
    }

    static func modelFillsInOneStep() async throws {
        let host = TableEditorHost.benchmark()
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je remplis les 45 cases."), Say.call("apply_edits", ["steps": [["action": "fillCells", "cells": "empty", "text": 1]]]), Say.done()],
        ]])
        let brain = make(factory, nil)
        let (events, error) = await collect(brain.respond(to: turn(ReportReplayTests.first, id: 1, host: host, handler: handler), tools: handler))
        XCTAssertNil(error)
        XCTAssertEqual(events.completion, .editApplied)
        XCTAssertEqual(host.runs.map(\.action), [.fillCells], "one call, one step")
        XCTAssertEqual(host.cellLayers.count, 45)
        XCTAssertEqual(host.cellText(row: 6, column: 3), "1")
        let finished = events.compactMap { event -> LiveToolResult? in
            if case .toolFinished(_, _, let result) = event { return result }
            return nil
        }
        XCTAssertEqual(finished.count, 1)
        let text = ToolResultEncoder.compactText(try XCTUnwrap(finished.first))
        XCTAssertTrue(text.contains("filled 45"), text)
        XCTAssertEqual(events.spoken, "Je remplis les 45 cases.")
    }

    /// The worst-case turn 1 of the report: addText at the centre, then textBehind, in one answer.
    static let worstFirst: [LocalChatEvent] = [
        .text("Je remplis la case avec un 1."),
        Say.call("apply_edits", ["steps": [["action": "addText", "text": "1", "placement": "center", "color": "black"], ["action": "textBehind", "text": "1"]]]),
        Say.done(),
    ]
    static let behind: [LocalChatEvent] = [Say.call("apply_edits", ["steps": [["action": "textBehind", "text": "1"]]], id: "call_2"), Say.done()]
    static let fill: [LocalChatEvent] = [.text("Je remplis plutôt les cases."), Say.call("apply_edits", ["steps": [["action": "fillCells", "cells": "empty", "text": "1"]]], id: "call_3"), Say.done()]

    static func followsTheHint() async throws {
        let host = TableEditorHost.benchmark()
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let factory = FakeEngineFactory(scripts: [[worstFirst, fill, behind, fill]])
        let entries = LogCollectorBox()
        let brain = make(factory, { entries.add($0) })
        let (first, _) = await collect(brain.respond(to: turn(ReportReplayTests.first, id: 1, host: host, handler: handler), tools: handler))
        // The addText ran (its own step), the textBehind never reached the editor; the repair round filled the table.
        XCTAssertFalse(host.runs.contains { $0.action == .textBehind }, "the validator refuses it on a table screenshot")
        XCTAssertEqual(host.filledCells, 45)
        let refusal = try XCTUnwrap(factory.engines.first?.sent[1].first?.toolResultContent)
        XCTAssertTrue(refusal.contains("textBehind failed[no_subject]"), refusal)
        XCTAssertTrue(refusal.contains("Hint: To write in the table use fillCells"), refusal)
        XCTAssertEqual(factory.engines.first?.options[1].temperature, 0, "the repair round is greedy")
        assertNoInternalWord(first.spoken)

        let (second, _) = await collect(brain.respond(to: turn(ReportReplayTests.second, id: 2, host: host, handler: handler), tools: handler))
        XCTAssertEqual(host.filledCells, 45)
        XCTAssertFalse(host.runs.contains { $0.action == .textBehind })
        assertNoInternalWord(second.spoken)
        XCTAssertTrue(entries.all.contains { $0.event == "model.tool" && $0.fields["reasons"] == "no_subject" }, "model.tool carries the reason (RC12)")
    }

    static func insists() async throws {
        let host = TableEditorHost.benchmark()
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let factory = FakeEngineFactory(scripts: [[worstFirst, behind, behind, behind, behind]])
        let brain = make(factory, nil)
        let expected = LiveLines.outcome(.noSubject, action: .textBehind, hasTable: true, .french)
        let (first, _) = await collect(brain.respond(to: turn(ReportReplayTests.first, id: 1, host: host, handler: handler), tools: handler))
        XCTAssertEqual(first.spoken, "Je remplis la case avec un 1. " + expected, "the failure is said after the model's sentence")
        let (second, _) = await collect(brain.respond(to: turn(ReportReplayTests.second, id: 2, host: host, handler: handler), tools: handler))
        XCTAssertEqual(second.spoken, expected)
        XCTAssertFalse(host.runs.contains { $0.action == .textBehind }, "never an executor run of textBehind")
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 4, "one repair round per turn, never a third try")
        XCTAssertTrue(engine.sent[3].contains { $0.toolResultContent?.hasPrefix("1 textBehind failed[no_subject]") == true })
        let owed = engine.sent[2].compactMap(\.toolResultContent).joined(separator: " | ")
        XCTAssertTrue(owed.contains("blocked[repeat]"), owed)
        assertNoInternalWord(first.spoken)
        assertNoInternalWord(second.spoken)
    }

    static func grammarLane() async throws {
        // The user's own project: the empty table and the giant "1" the old build wrote.
        let host = TableEditorHost.benchmark(strayOne: true)
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let brain = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: .photo)
        for (id, text) in [ReportReplayTests.first, ReportReplayTests.second].enumerated() {
            let plan = RuleBasedIntentEngine().parse(text, context: host.liveIntentContext())
            let lane = LiveTurnRouter.route(text, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true)
            guard case .local = lane else { return XCTFail("\(text): \(lane)") }
            let (events, error) = await collect(brain.respond(to: turn(text, id: id + 1, host: host, handler: handler), tools: handler))
            XCTAssertNil(error)
            assertNoInternalWord(events.spoken)
            if id == 0 {
                XCTAssertEqual(host.filledCells, 45)
                XCTAssertEqual(host.cellLayers.count, 45, "the stray 1 is adopted into the group")
                XCTAssertTrue(events.spoken.contains("Je peux mettre des chiffres au hasard"), events.spoken)
            } else {
                XCTAssertEqual(host.filledCells, 45)
            }
        }
    }

    static func noLookChips() async throws {
        let host = TableEditorHost.benchmark()
        let state = host.liveContextSummary()
        let generic = [
            LiveIdea(title: "Couleurs éclatantes", why: "Plus de peps.", symbol: "sparkles", steps: [RawIntentStep(action: "adjust", parameter: "vibrance", amount: 30)], source: .model),
            LiveIdea(title: "Contraste accru", why: "Plus net.", symbol: "sparkles", steps: [RawIntentStep(action: "applyLook", look: "dramatic")], source: .model),
        ]
        let shown = IdeaEngine.merge(current: [], incoming: generic, dismissed: [], fill: IdeaEngine.heuristic(state, dismissed: [], language: .french), state: state)
        XCTAssertEqual(shown.map(\.title), ["Surligner Opus 5.5", "Texte plus net", "Fond blanc pur"])
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1", alternative: "random")
        let after = IdeaEngine.merge(current: [], incoming: [], dismissed: [], fill: IdeaEngine.afterTableEdit(report, language: .french) + IdeaEngine.heuristic(state, dismissed: [], language: .french), state: state)
        XCTAssertEqual(after.first?.title, "Chiffres au hasard", "after the fill, the alternative the user named comes first (A12)")
    }
}
