import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Phase 0 of the table, scene-map and act-then-verify work (B0): the Live signatures the session
/// builds against keep their defaults, the machine channel reaches the step results, the recent
/// actions are kept by lane, and the new photo step fields go through the coercer and the validator.
final class GroundingContractTests: XCTestCase {
    private let photo = ToolInputValidator(mode: .photo)

    private func edits(_ steps: String, validator: ToolInputValidator? = nil, context: IntentContext = .photo) -> Result<LiveToolCall, ToolValidationError> {
        (validator ?? photo).validate(RawToolUse(id: "t", name: "apply_edits", rawInput: #"{"steps":["# + steps + "]}"), context: context)
    }

    private func intents(_ result: Result<LiveToolCall, ToolValidationError>) -> [EditIntent] {
        if case .success(let call) = result, case .applyEdits(let intents) = call.tool { return intents }
        return []
    }

    private func problems(_ result: Result<LiveToolCall, ToolValidationError>) -> [String] {
        if case .failure(.problems(let problems)) = result { return problems }
        return []
    }

    // MARK: Types and defaults

    func testNewFieldsDefaultToNothing() {
        var state = LiveEditorState(mode: .photo, version: 1)
        XCTAssertNil(state.table)
        XCTAssertNil(state.sceneMap)
        state.table = TableFixtures.benchmark()
        state.sceneMap = SceneFixtures.benchmarkScene()
        let turn = LiveUserTurn(id: 1, kind: .speech, text: "remplis tout", language: .french, image: nil, editorState: state)
        XCTAssertTrue(turn.recentActions.isEmpty)
        XCTAssertEqual(turn.editorState.table?.dataCells.count, 45)

        let step = LiveStepResult(index: 0, action: .fillCells, status: .applied)
        XCTAssertNil(step.reason)
        XCTAssertNil(step.report)
        XCTAssertNil(step.hint)
        XCTAssertNil(step.verification)
        XCTAssertEqual(LiveStepResult.Status.blocked.rawValue, "blocked")
        XCTAssertNil(LiveRunResult(outcome: .ignored).verificationRequest)
        XCTAssertNil(LocalPromptExample(user: "u", assistant: "a").afterResult)
        XCTAssertEqual(LocalLivePrompt.examples(mode: .photo, size: .full).filter { $0.afterResult != nil }.count, 1, "only the recovery speaks after its result")
        XCTAssertEqual(LocalModelLiveBrain.Limits().maxRepairRounds, 1)
        XCTAssertEqual(LiveTurnRouter.tableActions, [.fillCells, .clearCells, .highlightCells])
        XCTAssertGreaterThan(LocalLivePrompt.Budgets.userMessageGrounded, LocalLivePrompt.Budgets.userMessage)
        XCTAssertGreaterThan(LocalLivePrompt.Budgets.editorDeltaGrounded, LocalLivePrompt.Budgets.editorDelta)
    }

    func testStepResultReadsTheMachineChannel() {
        let report = TableEditReport(action: .fillCells, changed: 44, kept: 1, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1", alternative: "random")
        let filled = LiveStepResult(index: 0, intent: EditIntent(action: .fillCells), run: LiveRunResult(outcome: .applied(label: "Fill Cells"), effects: [report.effect]))
        XCTAssertEqual(filled.status, .applied)
        XCTAssertEqual(filled.report, report)
        XCTAssertNil(filled.reason)
        XCTAssertNil(filled.message, "a machine message is never a spoken line")

        let refused = LiveStepResult(index: 0, intent: EditIntent(action: .textBehind, text: "1"),
                                     run: LiveRunResult(outcome: .failed(message: "Je ne vois ni personne ni sujet."), effects: [ExecutionReason.noSubject.effect]))
        XCTAssertEqual(refused.reason, .noSubject)

        XCTAssertEqual(LiveExecution(steps: [filled], version: 2, canUndo: true).tableReport, report)
        XCTAssertNil(LiveExecution(steps: [filled], version: 2, canUndo: true).reason)
        XCTAssertEqual(LiveExecution(steps: [refused], version: 2, canUndo: true).reason, .noSubject)
    }

    func testAFailedCheckIsAReason() {
        let check = VerificationCheck(kind: .textPresent, region: PSRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05), text: "1", tag: "r2c1")
        let intentID = UUID()
        let failed = VerificationReport(intentID: intentID, action: .fillCells, items: [.init(check: check, outcome: .failed, observed: "7")], method: .pixels)
        let step = LiveStepResult(index: 0, action: .fillCells, status: .applied, verification: failed)
        let execution = LiveExecution(steps: [step], version: 3, canUndo: true)
        XCTAssertTrue(execution.verificationFailed)
        XCTAssertEqual(execution.reason, .verifyFailed)
        XCTAssertEqual(execution.verifications, [failed])
        XCTAssertEqual(execution.verificationSummary, "verify failed 1/1: r2c1 reads '7'")
        let passed = VerificationReport(intentID: intentID, action: .fillCells, items: [.init(check: check, outcome: .passed)], method: .pixels)
        XCTAssertFalse(LiveExecution(steps: [LiveStepResult(index: 0, action: .fillCells, status: .applied, verification: passed)], version: 3, canUndo: true).verificationFailed)
        XCTAssertFalse(LiveLines.verification(failed, .french).isEmpty)
    }

    // MARK: Host and handler

    func testHostsThatCannotLookVerifyNothing() async {
        let request = VerificationRequest(intentID: UUID(), action: .addText,
                                          checks: [VerificationCheck(kind: .textPresent, region: .unit, text: "Été", tag: "text")])
        let reports = await GroundingScenarios.verify([request])
        XCTAssertTrue(reports.isEmpty)
    }

    func testHandlerKeepsRecentActionsByLane() async throws { try await GroundingScenarios.recentActionsByLane() }

    // MARK: Lines

    func testEveryReasonHasAFrenchAndEnglishLine() {
        for reason in ExecutionReason.allCases {
            for hasTable in [false, true] {
                let french = LiveLines.outcome(reason, action: .fillCells, hasTable: hasTable, .french)
                let english = LiveLines.outcome(reason, action: .textBehind, hasTable: hasTable, .english)
                XCTAssertFalse(french.isEmpty, "\(reason)")
                XCTAssertFalse(english.isEmpty, "\(reason)")
                XCTAssertFalse(french.lowercased().contains("subject"), "\(reason)")
                XCTAssertFalse(french.contains("«"), "\(reason): no quoted label")
                XCTAssertTrue(LiveSpeechSanitizer.isClean(french, language: .french), "\(reason)")
                _ = ToolHints.hint(for: reason, action: .textBehind, hasTable: hasTable)
            }
        }
        XCTAssertEqual(LiveLines.outcome(.noSubject, action: .textBehind, hasTable: true, .french),
                       "Sur une capture de tableau, il n'y a pas de sujet à détacher. Je remplis les cases à la place ?")
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1")
        XCTAssertTrue(LiveLines.tableDone(report, .french).contains("45"))
        XCTAssertTrue(LiveLines.tableDone(report, .english).contains("45"))
    }

    func testIdeasMergeKeepsItsOldBehaviourWithoutState() {
        let ideas = IdeaEngine.generic(mode: .photo, language: .french)
        XCTAssertEqual(IdeaEngine.merge(current: [], incoming: ideas, dismissed: [], fill: []),
                       IdeaEngine.merge(current: [], incoming: ideas, dismissed: [], fill: [], state: nil))
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1", alternative: "random")
        XCTAssertLessThanOrEqual(IdeaEngine.afterTableEdit(report, language: .french).count, 3)
    }

    func testSceneLinesSpeakTheModelsGrid() {
        XCTAssertEqual(LiveSceneLines.box(PSRect(x: 0.12, y: 0.04, width: 0.26, height: 0.05)), "120,40,380,90")
        XCTAssertEqual(LiveSceneLines.box(PSRect(x: -0.1, y: 0.5, width: 2, height: 0.5)), "0,500,1000,1000")
        let record = LiveActionRecord(source: .grammar, steps: [RawIntentStep(action: "fillCells", text: "1", cells: "empty")],
                                      results: [LiveStepResult(index: 0, action: .fillCells, status: .applied)], version: 4)
        XCTAssertTrue(record.applied)
        XCTAssertTrue(record.line().contains("fillCells"))
        XCTAssertLessThanOrEqual(record.line().count, LiveSceneLines.lastBudget)
        XCTAssertLessThanOrEqual(LiveSceneLines.table(TableFixtures.benchmark()).joined(separator: "\n").count, LocalLivePrompt.Budgets.tableLines)
        XCTAssertLessThanOrEqual(LiveSceneLines.scene(SceneFixtures.posterScene()).joined(separator: "\n").count, LocalLivePrompt.Budgets.sceneLines)
    }

    // MARK: Router

    func testTablePlansTakeTheLocalLane() {
        let text = "remplis les cases vides avec des nombres au hasard entre 50 et 90"
        let fill = EditIntent(action: .fillCells, confidence: 0.92, table: TableEditSpec(value: .random(min: 50, max: 90, decimals: nil)))
        let plan = EditPlan(utterance: text, intents: [fill], confidence: 0.92)
        XCTAssertEqual(LiveTurnRouter.route(text, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true), .local(plan))
        XCTAssertEqual(LiveTurnRouter.route(text, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: false), .brain(isQuestion: false))
        let question = "que penses-tu de la colonne Opus 5 ?"
        XCTAssertEqual(LiveTurnRouter.route(question, grammar: EditPlan(utterance: question, intents: [fill], confidence: 0.92), brain: .model,
                                            ideasOnScreen: 0, jobRunning: false, fastLane: true), .brain(isQuestion: true))
        let unsure = EditPlan(utterance: text, intents: [fill], confidence: 0.75)
        XCTAssertEqual(LiveTurnRouter.route(text, grammar: unsure, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true), .brain(isQuestion: false))
    }

    // MARK: Schema, coercer, validator

    func testPhotoFieldsOnlyInThePhotoSchema() {
        let photoKeys = Set(LiveToolSchema.stepSchema(for: .photo)["properties"]?.object?.keys.map { $0 } ?? [])
        let videoKeys = Set(LiveToolSchema.stepSchema(for: .video)["properties"]?.object?.keys.map { $0 } ?? [])
        XCTAssertEqual(LiveToolSchema.photoFields.count, 14)
        XCTAssertTrue(LiveToolSchema.photoFields.isSubset(of: photoKeys))
        XCTAssertTrue(LiveToolSchema.photoFields.isDisjoint(with: videoKeys))
        XCTAssertTrue(LiveToolSchema.photoFields.isDisjoint(with: LiveToolSchema.videoFields))
    }

    func testTableStepDecodes() {
        let result = edits(#"{"action":"fillCells","cells":"all","row":"Agentic coding","column":"2","values":"random","min":50,"max":90,"decimals":1}"#)
        XCTAssertEqual(problems(result), [])
        let spec = intents(result).first?.table
        XCTAssertEqual(spec?.onlyEmpty, false)
        XCTAssertEqual(spec?.rows, [.name("Agentic coding")])
        XCTAssertEqual(spec?.columns, [.index(2)])
        XCTAssertEqual(spec?.value, .random(min: 50, max: 90, decimals: 1))
        XCTAssertEqual(intents(edits(#"{"action":"fillCells","cells":"empty","text":"1"}"#)).first?.table?.value, .constant("1"))
    }

    func testPrimitiveStepsDecode() {
        let edit = intents(edits(#"{"action":"editText","ref":"t3","text":"Total 2025","size":"x1.5","weight":"bold","align":"left","font":"serif"}"#)).first
        XCTAssertEqual(edit?.ref, .text(3))
        XCTAssertEqual(edit?.textStyle?.size, .scale(1.5))
        XCTAssertEqual(edit?.textStyle?.weight, .bold)
        XCTAssertEqual(edit?.textStyle?.alignment, .leading)
        XCTAssertEqual(edit?.textStyle?.design, .serif)
        let erase = intents(edits(#"{"action":"eraseRegion","box":[0.1,0.2,0.3,0.4]}"#)).first
        XCTAssertEqual(erase?.region?.minX ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(erase?.region?.height ?? 0, 0.2, accuracy: 1e-9)
        let styled = intents(edits(#"{"action":"addText","text":"Été 2026","ref":"f1","size":"match","match":"t1"}"#)).first
        XCTAssertEqual(styled?.ref, .area(1))
        XCTAssertEqual(styled?.textStyle?.match, .ref(.text(1)))
    }

    func testPhotoFieldsAreStrict() {
        let cases: [(String, String)] = [
            (#"{"action":"fillCells","text":"1","cells":"some"}"#, "cells"),
            (#"{"action":"fillCells","values":"guess"}"#, "values"),
            (#"{"action":"fillCells","values":"random","min":90,"max":50}"#, "max"),
            (#"{"action":"fillCells","values":"random","decimals":5}"#, "decimals"),
            (#"{"action":"editText","ref":"x9","text":"a"}"#, "ref"),
            (#"{"action":"editText","ref":"t1","weight":"heavy"}"#, "weight"),
            (#"{"action":"addText","text":"a","align":"justify"}"#, "align"),
            (#"{"action":"addText","text":"a","font":"comic"}"#, "font"),
            (#"{"action":"addText","text":"a","size":"huge-ish"}"#, "size"),
            (#"{"action":"addText","text":"a","match":"yes please"}"#, "match"),
            (#"{"action":"eraseRegion","box":[0.5,0.5,0.4,0.9]}"#, "box"),
            (#"{"action":"eraseRegion","box":[0.1,0.1,1.5,0.9]}"#, "box"),
            (#"{"action":"eraseRegion","box":[0.1,0.1]}"#, "box"),
            (#"{"action":"fillCells","text":"1","row":3}"#, "row"),
        ]
        for (step, field) in cases {
            let found = problems(edits(step))
            XCTAssertTrue(found.contains { $0.contains(".\(field)") }, "\(step): \(found)")
        }
        let video = ToolInputValidator(mode: .video)
        XCTAssertTrue(problems(edits(#"{"action":"mute","cells":"all"}"#, validator: video, context: IntentContext(mode: .video, clipCount: 1, timelineDuration: 10)))
            .contains { $0.contains("cells: unknown field") })
        guard case .failure(.problems(let typed)) = video.steps(raw: [RawIntentStep(action: "mute", row: "2")], context: IntentContext(mode: .video, clipCount: 1)) else {
            return XCTFail("a photo field on a video step is refused")
        }
        XCTAssertTrue(typed.contains { $0.contains("row: not available for a video") })
    }

    func testCoercerReadsPhotoFieldsLoosely() throws {
        let use = ToolArgumentCoercer.rawToolUse(id: "c", name: "apply_edits", arguments: ["steps": [
            ["action": "fillCells", "row": 3, "column": "Opus 5", "min": "50", "max": "90", "decimals": "1", "values": "Random", "cells": "ALL"],
            ["action": "erase_region", "bbox_2d": [100, 200, 300, 400]],
            ["action": "addText", "text": 2026, "size": 24, "weight": "Bold", "align": "Left", "box": "100, 50, 900, 150"],
            ["action": "removeObject", "target": "sign", "box": [100, 200, 300, 400]],
        ]])
        let steps = try JSONValue.parse(use.rawInput)["steps"]?.array ?? []
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps[0]["row"], "3")
        XCTAssertEqual(steps[0]["min"], 50)
        XCTAssertEqual(steps[0]["decimals"], 1)
        XCTAssertEqual(steps[0]["values"], "random")
        XCTAssertEqual(steps[0]["cells"], "all")
        XCTAssertEqual(steps[1]["action"], "eraseRegion")
        XCTAssertEqual(steps[1]["box"], [0.1, 0.2, 0.3, 0.4])
        XCTAssertNil(steps[1]["point"])
        XCTAssertEqual(steps[2]["size"], "24")
        XCTAssertEqual(steps[2]["weight"], "bold")
        XCTAssertEqual(steps[2]["align"], "left")
        XCTAssertEqual(steps[2]["box"], [0.1, 0.05, 0.9, 0.15])
        XCTAssertNil(steps[3]["box"], "an object's box is a way to point at it")
        XCTAssertEqual(steps[3]["point"], ["x": 0.2, "y": 0.3])
        XCTAssertEqual(problems(photo.validate(use, context: .photo)), [])
    }

    // MARK: Model loop pieces

    func testSamplingStylesAndStepSignatures() {
        let edit = LocalGenerationOptions(style: .edit, maxTokens: 120)
        XCTAssertEqual(edit.temperature, 0.25)
        XCTAssertEqual(edit.presencePenalty, 0)
        XCTAssertEqual(edit.maxTokens, 120)
        XCTAssertEqual(LocalGenerationOptions(style: .conversation, maxTokens: 320).temperature, 0.6)
        XCTAssertEqual(LocalGenerationOptions(style: .repair, maxTokens: 120).temperature, 0)
        XCTAssertEqual(LocalModelLiveBrain.style(for: .speech("tu en penses quoi ?")), .conversation)
        XCTAssertEqual(LocalModelLiveBrain.style(for: .speech("remplis les autres cases aussi")), .edit)

        let behind = EditIntent(action: .textBehind, text: "1")
        XCTAssertEqual(LocalModelLiveBrain.StepSignature(behind), LocalModelLiveBrain.StepSignature(EditIntent(action: .textBehind, text: "1")))
        XCTAssertNotEqual(LocalModelLiveBrain.StepSignature(behind), LocalModelLiveBrain.StepSignature(EditIntent(action: .textBehind, text: "2")))
        XCTAssertNotEqual(LocalModelLiveBrain.StepSignature(EditIntent(action: .fillCells, table: TableEditSpec(columns: [.index(1)], value: .constant("1")))),
                          LocalModelLiveBrain.StepSignature(EditIntent(action: .fillCells, table: TableEditSpec(columns: [.index(2)], value: .constant("1")))))
    }
}

/// The handler scenarios run on the main actor, as the session does.
@MainActor private enum GroundingScenarios {
    static func verify(_ requests: [VerificationRequest]) async -> [VerificationReport] {
        await FakePhotoHost().liveVerify(requests)
    }

    static func recentActionsByLane() async throws {
        let host = FakePhotoHost()
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        XCTAssertTrue(handler.recentActions.isEmpty)
        _ = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits([EditIntent(action: .adjust, parameter: .brightness, amount: .relative(0.2))])))
        _ = await handler.runPlan(RuleBasedIntentEngine().parse("plus lumineux", context: .photo))
        let idea = IdeaEngine.generic(mode: .photo, language: .french).first { $0.steps.first?.action == "autoEnhance" }!
        _ = await handler.runIdea(idea)
        XCTAssertEqual(handler.recentActions.map(\.source), [.model, .grammar, .idea])
        XCTAssertEqual(handler.recentActions[0].steps.first?.action, "adjust")
        XCTAssertEqual(handler.recentActions[0].steps.first?.parameter, "brightness")
        XCTAssertEqual(handler.recentActions[0].results.map(\.status), [.applied])
        XCTAssertEqual(handler.recentActions.map(\.version), [1, 2, 3])
        for _ in 0..<10 { _ = await handler.runPlan(RuleBasedIntentEngine().parse("plus lumineux", context: .photo)) }
        XCTAssertEqual(handler.recentActions.count, EditorToolHandler.recentActionsCapacity)
        XCTAssertEqual(handler.recentActions.last?.source, .grammar)
    }
}
