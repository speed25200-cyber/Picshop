import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// What the model reads and hears back (contract §11, A11): the table, scene and last lines, the
/// grounded editor state and its budgets, the look policy, the reason-coded results (compactText v2),
/// the hints, and the validator's checks against the table and the scene map.
final class GroundingLinesTests: XCTestCase {
    private let photo = ToolInputValidator(mode: .photo)

    // MARK: Table lines

    func testTheTableLinesOfTheReport() {
        let lines = LiveSceneLines.table(TableFixtures.benchmark())
        XCTAssertEqual(lines[0], "table: 9 rows x 5 cols, title \"Claude Opus 5.5\"")
        XCTAssertEqual(lines[1], "cols: 1 Opus 5.5 | 2 Opus 5 | 3 Fable 5.1 | 4 Gemini 3.5 Pro | 5 GPT-6 Astra")
        XCTAssertTrue(lines[2].hasPrefix("rows: 1 Agentic coding | 2 Agentic terminal… | 3 Scaled tool use"), lines[2])
        XCTAssertTrue(lines[2].hasSuffix("| 9 Knowledge work"))
        XCTAssertEqual(lines[3], "cells: 45 empty, 0 printed")
        XCTAssertLessThanOrEqual(lines.joined(separator: "\n").count, LocalLivePrompt.Budgets.tableLines)

        // The user's state: the stray "1" of the old build in r6c3.
        let stray = TableFixtures.benchmark().overlaying(TableFixtures.strayOne(in: TableFixtures.document()).layers)
        let strayLines = LiveSceneLines.table(stray)
        XCTAssertTrue(strayLines.contains("cells: 44 empty, 1 filled by you (r6c3 \"1\"), 0 printed"), "\(strayLines)")
        XCTAssertLessThanOrEqual(strayLines.joined(separator: "\n").count, LocalLivePrompt.Budgets.tableLines)
        XCTAssertEqual(LiveSceneLines.table(TableFixtures.benchmark(withValues: true))[3], "cells: 0 empty, 45 printed")
    }

    func testEmptyRunsSayWhereTheHolesAre() {
        let stray = TableFixtures.benchmark().overlaying(TableFixtures.strayOne(in: TableFixtures.document()).layers)
        XCTAssertEqual(LiveSceneLines.emptyRunsLine(stray), "empty at: r1-5 c1-5; r6 c1-2,4-5; r7-9 c1-5")
        XCTAssertNil(LiveSceneLines.emptyRunsLine(TableFixtures.benchmark()), "all empty: nothing to locate")
        XCTAssertEqual(LiveSceneLines.ranges([1, 2, 4, 5, 7]), "1-2,4-5,7")
    }

    func testTheTableFocusAnswersAQuestionWithoutATool() {
        let grid = TableFixtures.benchmark(withValues: true)
        XCTAssertEqual(LiveSceneLines.tableFocus(grid, words: "que vaut Opus 5 en Agentic coding ?"), "table_focus: r1c2 (Agentic coding, Opus 5) = \"77.2%\"")
        let column = LiveSceneLines.tableFocus(grid, words: "et la colonne Opus 5.5 ?") ?? ""
        XCTAssertTrue(column.hasPrefix("table_focus: col 1 Opus 5.5 = r1 \"80.9%\" | r2 \"59.3%\""), "Opus 5.5, never Opus 5: \(column)")
        XCTAssertLessThanOrEqual(column.count, LocalLivePrompt.Budgets.tableFocus)
        XCTAssertTrue(LiveSceneLines.tableFocus(grid, words: "la ligne Knowledge work")?.hasPrefix("table_focus: row 9 Knowledge work = c1 \"79.4%\"") ?? false)
        XCTAssertEqual(LiveSceneLines.tableFocus(TableFixtures.benchmark(), words: "Gemini 3.5 Pro ?"), "table_focus: col 4 Gemini 3.5 Pro: all 9 empty")
        XCTAssertTrue(LiveSceneLines.tableFocus(grid, words: "la colonne 3")?.contains("col 3 Fable 5.1") ?? false)
        XCTAssertNil(LiveSceneLines.tableFocus(grid, words: "plus chaud"))
    }

    // MARK: Scene lines

    func testTheSceneLinesOfAPoster() {
        let lines = LiveSceneLines.scene(SceneFixtures.posterScene())
        XCTAssertEqual(lines, [
            "texts: t1 \"SOLDES D'ÉTÉ\" 120,50,880,140 large light bold | t2 \"-50% sur tout\" 300,160,700,200 body light medium | t3 \"29,99 €\" 60,860,280,910 large yellow bold",
            "objects: o1 person 300,240,700,940",
            "free: f1 700,220,980,400 teal | f2 300,930,980,990 light",
        ])
        // Tight: the free areas and the smallest texts go first, the title last.
        let tight = LiveSceneLines.scene(SceneFixtures.posterScene(), budget: 120)
        XCTAssertLessThanOrEqual(tight.joined(separator: "\n").count, 120)
        XCTAssertTrue(tight.first?.contains("t1 \"SOLDES D'ÉTÉ\"") ?? false, "\(tight)")
        XCTAssertTrue(LiveSceneLines.scene(SceneFixtures.posterScene(), budget: 0).isEmpty)
    }

    func testTheTableTextIsLeftToTheTableLines() {
        let lines = LiveSceneLines.scene(SceneFixtures.benchmarkScene(), budget: LocalLivePrompt.Budgets.sceneLinesWithTable)
        XCTAssertEqual(lines.first, "texts: t1 \"Claude Opus 5.5\" 30,35,450,75 body dark bold")
        XCTAssertFalse(lines.joined().contains("Agentic coding"), "headers and labels are in the table lines")
        var state = LiveEditorState(mode: .photo, version: 1)
        state.table = TableFixtures.benchmark()
        XCTAssertEqual(LiveSceneLines.kind(state), "table screenshot")
        state.table = nil
        state.sceneMap = SceneFixtures.posterScene()
        XCTAssertNil(LiveSceneLines.kind(state))
    }

    // MARK: Last line

    func testTheLastLineKeepsTheArguments() {
        let report = TableEditReport(action: .fillCells, changed: 44, kept: 1, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1")
        let fill = LiveActionRecord(source: .grammar, steps: [RawIntentStep(action: "fillCells", text: "1", cells: "empty")],
                                    results: [LiveStepResult(index: 0, action: .fillCells, status: .applied, label: "Fill Cells", report: report)], version: 4)
        XCTAssertEqual(fill.line(), "last: fillCells text=1 cells=empty → applied, filled 44, kept 1, empty left 0 (grammar)")
        let behind = LiveActionRecord(source: .model, steps: [RawIntentStep(action: "textBehind", text: "Été 2026")],
                                      results: [LiveStepResult(index: 0, action: .textBehind, status: .failed, reason: .noSubject)], version: 4)
        XCTAssertEqual(behind.line(), "last: textBehind text=\"Été 2026\" → failed[no_subject] (model)")
        let long = LiveActionRecord(source: .idea, steps: (0..<5).map { RawIntentStep(action: "addText", text: "A fairly long title \($0)", placement: "top", color: "red") },
                                    results: [LiveStepResult(index: 0, action: .addText, status: .applied)], version: 9)
        XCTAssertLessThanOrEqual(long.line().count, LiveSceneLines.lastBudget)
        XCTAssertTrue(long.line().hasSuffix("(idea)"))
    }

    // MARK: The grounded state

    private func tableTurn(_ text: String, recent: [LiveActionRecord] = [], stray: Bool = true) -> LiveUserTurn {
        var document = TableFixtures.document()
        if stray { document = TableFixtures.strayOne(in: document) }
        var state = LiveEditorState(mode: .photo, version: 3)
        state.canvasPixels = TableFixtures.canvas
        state.table = TableFixtures.benchmark().overlaying(document.layers)
        state.sceneMap = SceneFixtures.benchmarkScene().overlaying(document.layers)
        state.scene = SceneDescription(labels: ["screenshot", "document"], hasText: true, brightness: 0.92, colourfulness: 0.04)
        state.appliedEdits = ["Add Text"]
        return LiveUserTurn(id: 2, kind: .speech, text: text, language: .french, image: nil, editorState: state, recentActions: recent)
    }

    func testTheFirstGroundedMessageCarriesTheTableAndTheLastAction() {
        let record = LiveActionRecord(source: .model, steps: [RawIntentStep(action: "addText", text: "1", placement: "center")],
                                      results: [LiveStepResult(index: 0, action: .addText, status: .applied, label: "Add Text")], version: 3)
        let turn = tableTurn("Il faut remplir les autres cases aussi.", recent: [record])
        let message = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false)
        for line in ["scene: table screenshot; text", "table: 9 rows x 5 cols, title \"Claude Opus 5.5\"", "cols: 1 Opus 5.5 | 2 Opus 5",
                     "cells: 44 empty, 1 filled by you (r6c3 \"1\"), 0 printed", "texts: t1 \"Claude Opus 5.5\"",
                     "last: addText text=1 placement=center → applied (model)", "langue: fr"] {
            XCTAssertTrue(message.contains(line), line)
        }
        XCTAssertTrue(message.hasSuffix("Il faut remplir les autres cases aussi."))
        XCTAssertLessThanOrEqual(message.count, LocalLivePrompt.Budgets.userMessageGrounded)
        XCTAssertLessThanOrEqual(LocalLivePrompt.editorDelta(turn, previous: nil, imageAttached: false).count, LocalLivePrompt.Budgets.editorDeltaGrounded)
        XCTAssertFalse(message.lowercased().contains("<media_text>\n1"), "a cell's value is in the table line, not media text")
    }

    func testADeltaCarriesOnlyWhatChangedInTheTable() {
        let first = tableTurn("remplis la colonne Opus 5.5 avec 1")
        // After a column fill: only the cells line (and where the holes are), no header, no scene lines again.
        var next = first
        next.text = "les autres aussi"
        var document = TableFixtures.strayOne(in: TableFixtures.document())
        for row in 1...9 {
            let cell = TableFixtures.benchmark().cell(dataRow: row, dataColumn: 1)!
            let element = TextElement(text: "1", relativeSize: 0.0156, center: cell.contentRect.center)
            document.addLayer(Layer(name: "1", content: .text(element), group: LayerGroup(id: UUID(), kind: .tableCells, row: row, column: 1)))
        }
        next.editorState.table = TableFixtures.benchmark().overlaying(document.layers)
        next.editorState.version = 4
        next.editorState.appliedEdits = ["Add Text", "Fill Cells"]
        let delta = LocalLivePrompt.editorDelta(next, previous: first.editorState, imageAttached: false)
        XCTAssertTrue(delta.contains("new: Fill Cells"))
        XCTAssertTrue(delta.contains("cells: 35 empty, 10 filled by you (all \"1\"), 0 printed"), delta)
        XCTAssertTrue(delta.contains("empty at: r1-5 c2-5; r6 c2,4-5; r7-9 c2-5"), delta)
        XCTAssertFalse(delta.contains("cols:"))
        XCTAssertFalse(delta.contains("texts:"))

        var same = next
        same.editorState.version = 5
        let unchanged = LocalLivePrompt.editorDelta(same, previous: next.editorState, imageAttached: false)
        XCTAssertFalse(unchanged.contains("cells:"), unchanged)
        XCTAssertTrue(unchanged.contains("unchanged"))
        var question = same
        question.text = "que vaut Opus 5.5 en Agentic coding ?"
        XCTAssertTrue(LocalLivePrompt.editorDelta(question, previous: next.editorState, imageAttached: false)
            .contains("table_focus: r1c1 (Agentic coding, Opus 5.5) = \"1\" (yours)"))
    }

    func testAGroundedStateStaysWithinItsBudgets() {
        var turn = tableTurn("remplis tout avec des nombres au hasard entre 50 et 90")
        turn.sinceLastReply = (1...12).map { "manual change number \($0) with a long description" }
        turn.ideasOnScreen = ["Surligner Opus 5.5", "Texte plus net", "Fond blanc pur"]
        turn.editorState.appliedEdits = (1...12).map { "Edit number \($0)" }
        let delta = LocalLivePrompt.editorDelta(turn, previous: nil, imageAttached: true)
        XCTAssertLessThanOrEqual(delta.count, LocalLivePrompt.Budgets.editorDeltaGrounded)
        XCTAssertTrue(delta.contains("cols: 1 Opus 5.5"), "the table survives the cuts")
        XCTAssertTrue(delta.hasSuffix("</editor_state>"))
        XCTAssertLessThanOrEqual(LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: true).count, LocalLivePrompt.Budgets.userMessageGrounded)
        // No table, no scene map: the old budgets.
        let plain = LiveUserTurn.speech("plus chaud")
        XCTAssertLessThanOrEqual(LocalLivePrompt.userMessage(plain, previous: nil, imageAttached: false).count, LocalLivePrompt.Budgets.userMessage)
    }

    func testTableWordsNeedALookOnlyWithoutTableLines() {
        let withTable = tableTurn("remplis les cases de la colonne Opus 5")
        XCTAssertFalse(LocalLivePrompt.needsFreshLook(withTable, versionsSinceLastLook: 1), "the table lines say where the cells are")
        XCTAssertTrue(LocalLivePrompt.needsFreshLook(.speech("remplis les cases de la colonne Opus 5"), versionsSinceLastLook: 1))
        XCTAssertTrue(LocalLivePrompt.needsFreshLook(.speech("fill every cell with 1"), versionsSinceLastLook: 1))
    }

    func testTheOnDevicePromptIsGroundedToo() {
        let prompt = LivePrompt.onDevicePrompt(tableTurn("que vaut Opus 5 en Agentic coding ?"))
        XCTAssertTrue(prompt.contains("Scene: table screenshot"))
        XCTAssertTrue(prompt.contains("table: 9 rows x 5 cols"))
        XCTAssertTrue(prompt.contains("table_focus: r1c2 (Agentic coding, Opus 5) = empty"))
        XCTAssertTrue(prompt.hasSuffix("User: que vaut Opus 5 en Agentic coding ?"))
        let state = LivePrompt.editorState(tableTurn("x").editorState)
        XCTAssertTrue(state.contains("cells: 44 empty"))
    }

    // MARK: Results the model reads (compactText v2)

    func testCompactTextSpeaksInCodesNeverInTheUsersWords() {
        func text(_ steps: [LiveStepResult]) -> String { ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(LiveExecution(steps: steps, version: 2, canUndo: true))) }
        let report = TableEditReport(action: .fillCells, changed: 44, kept: 1, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1")
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .fillCells, status: .applied, label: "Fill Cells", report: report)]),
                       "1 fillCells applied: Fill Cells; filled 44, kept 1, empty left 0")
        let hint = ToolHints.hint(for: .noSubject, action: .textBehind, hasTable: true)
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .textBehind, status: .failed, message: "Je ne vois ni personne ni sujet à détacher sur cette image.",
                                            reason: .noSubject, hint: hint)]),
                       "1 textBehind failed[no_subject]: no person or main subject here. Do not retry this step. Hint: To write in the table use fillCells; to mark a row or column use highlightCells.")
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .fillCells, status: .info, message: "Je ne vois pas de tableau.", reason: .noTable,
                                            hint: ToolHints.hint(for: .noTable, action: .fillCells, hasTable: false))]),
                       "1 fillCells info[no_table]: no table found. Hint: Ask the user to crop to the table; never write cells with addText.")
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .textBehind, status: .blocked, reason: .noSubject)]),
                       "1 textBehind blocked[repeat]: already failed this turn. Say one sentence or ask one question.")
        let check = VerificationCheck(kind: .textPresent, region: .unit, text: "Été", tag: "text")
        let failed = VerificationReport(intentID: UUID(), action: .addText, items: [.init(check: check, outcome: .failed)], method: .pixels)
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .addText, status: .applied, label: "Add Text", hint: "Try a larger size.", verification: failed)]),
                       "1 addText applied: Add Text; verify failed 1/1: text missing. Hint: Try a larger size.")
        // Without a code, the executor's words stay (a question, an info).
        XCTAssertEqual(text([LiveStepResult(index: 0, action: .removeObject, status: .needsClarification, message: "Lequel ?", candidates: ["dog (left)"])]),
                       "1 removeObject needs_clarification: Lequel ? [1 dog (left)]")
        // Many coded steps stay within 300 characters and keep their codes.
        let many = (0..<6).map { LiveStepResult(index: $0, action: .textBehind, status: .failed, message: "x", reason: .noSubject, hint: hint) }
        let long = text(many)
        XCTAssertLessThanOrEqual(long.count, 300)
        XCTAssertTrue(long.hasPrefix("1 textBehind failed[no_subject]"))
        // The JSON payload carries the codes for the log and the Foundation Models bridge.
        let payload = ToolResultEncoder.applyEdits(LiveExecution(steps: [LiveStepResult(index: 0, action: .textBehind, status: .failed, message: "x", reason: .noSubject, hint: hint)],
                                                                 version: 1, canUndo: false)).payload
        XCTAssertEqual(payload["results"]?.array?.first?["code"], "no_subject")
        XCTAssertEqual(payload["results"]?.array?.first?["hint"], .string(hint ?? ""))
    }

    func testEveryReasonHasAHintOrAReasonNotTo() {
        XCTAssertTrue(ToolHints.hint(for: .noSubject, action: .textBehind, hasTable: true)?.contains("fillCells") ?? false)
        XCTAssertTrue(ToolHints.hint(for: .noSubject, action: .textBehind, hasTable: false)?.contains("addText") ?? false)
        XCTAssertTrue(ToolHints.hint(for: .unknownRef, action: .editText, hasTable: false)?.contains("texts") ?? false)
        XCTAssertNil(ToolHints.hint(for: .unsupported, action: .adjust, hasTable: false), "nothing better to say than the code")
        for reason in ExecutionReason.allCases {
            for action in [IntentAction.fillCells, .textBehind, .addText, .removeObject] {
                let hint = ToolHints.hint(for: reason, action: action, hasTable: true) ?? ""
                XCTAssertLessThanOrEqual(hint.count, 140, "\(reason) \(action)")
                XCTAssertFalse(hint.contains("«"), "hints are English")
            }
        }
    }

    // MARK: Validator: grounded checks

    private func problems(_ steps: String, context: IntentContext) -> [String] {
        let use = RawToolUse(id: "t", name: "apply_edits", rawInput: #"{"steps":["# + steps + "]}")
        if case .failure(.problems(let problems)) = photo.validate(use, context: context) { return problems }
        return []
    }

    private var tableContext: IntentContext {
        IntentContext(mode: .photo, table: TableFixtures.benchmark(), scene: SceneFixtures.benchmarkScene())
    }

    func testRowsAndColumnsResolveAgainstTheTable() {
        XCTAssertEqual(problems(#"{"action":"fillCells","column":"GPT 7","text":"1"}"#, context: tableContext),
                       ["steps[0].column: 'GPT 7' is not a column; columns: 1 Opus 5.5, 2 Opus 5, 3 Fable 5.1, 4 Gemini 3.5 Pro, 5 GPT-6 Astra"])
        XCTAssertTrue(problems(#"{"action":"fillCells","row":"Cooking","text":"1"}"#, context: tableContext).first?.hasPrefix("steps[0].row: 'Cooking' is not a row; rows: 1 Agentic coding") ?? false)
        XCTAssertEqual(problems(#"{"action":"fillCells","column":"gpt six astra","row":"last","text":"1"}"#, context: tableContext), [], "spoken names resolve")
        XCTAssertEqual(problems(#"{"action":"fillCells","column":"Opus","text":"1"}"#, context: tableContext), [], "ambiguous: the executor asks which")
        XCTAssertEqual(problems(#"{"action":"fillCells","column":"9","text":"1"}"#, context: tableContext).count, 1, "no 9th column")
        XCTAssertEqual(problems(#"{"action":"fillCells","column":"GPT 7","text":"1"}"#, context: .photo), [], "no table in the context: the executor answers")
    }

    func testTableStepsNeedAValueThatFitsACell() {
        XCTAssertTrue(problems(#"{"action":"fillCells","cells":"empty"}"#, context: tableContext)
            .contains("steps[0]: fillCells needs text or values (or color, weight or size to restyle filled cells)"))
        // Restyling the cells already filled: no value, a colour, weight or size.
        XCTAssertEqual(problems(#"{"action":"fillCells","cells":"all","weight":"bold"}"#, context: tableContext), [])
        XCTAssertEqual(problems(#"{"action":"fillCells","color":"red"}"#, context: tableContext), [])
        XCTAssertTrue(problems(#"{"action":"fillCells","text":"a value far too long for one table cell"}"#, context: tableContext)
            .contains("steps[0].text: at most 24 characters in a cell"))
        XCTAssertTrue(problems(#"{"action":"fillCells","values":"list","text":"1"}"#, context: tableContext).first?.contains("joined with |") ?? false)
        XCTAssertEqual(problems(#"{"action":"fillCells","values":"list","column":"Opus 5","text":"80|75|70|65|60|55|50|45|40"}"#, context: tableContext), [])
        XCTAssertTrue(problems(#"{"action":"highlightCells","color":"yellow"}"#, context: tableContext).contains("steps[0]: highlightCells needs row or column"))
        XCTAssertTrue(problems(#"{"action":"clearCells"}"#, context: tableContext).contains("steps[0]: clearCells needs row, column or cells"))
    }

    func testNoSubjectStepOnATableScreenshot() {
        let expected = "steps[0].action: " + ToolHints.noSubjectProblem
        for step in [#"{"action":"textBehind","text":"1"}"#, #"{"action":"removeBackground"}"#, #"{"action":"blurBackground","amount":50}"#,
                     #"{"action":"replaceBackground","background":"white"}"#, #"{"action":"selectiveAdjust","target":"background","parameter":"brightness","amount":10}"#] {
            XCTAssertEqual(problems(step, context: tableContext), [expected], step)
        }
        XCTAssertEqual(problems(#"{"action":"textBehind","text":"1"}"#, context: IntentContext(mode: .photo, scene: SceneFixtures.posterScene())), [], "a poster has a person")
        var screenshot = SceneFixtures.posterScene()
        screenshot.kind = .screenshot
        screenshot.objects = []
        XCTAssertEqual(problems(#"{"action":"removeBackground"}"#, context: IntentContext(mode: .photo, scene: screenshot)),
                       ["steps[0].action: " + ToolHints.noSubjectScreenshotProblem])
    }

    func testSceneIDsResolveAgainstTheSceneMap() {
        let poster = IntentContext(mode: .photo, scene: SceneFixtures.posterScene())
        XCTAssertEqual(problems(#"{"action":"editText","ref":"t2","text":"-70% sur tout"}"#, context: poster), [])
        XCTAssertEqual(problems(#"{"action":"editText","ref":"t9","text":"x"}"#, context: poster),
                       ["steps[0].ref: 't9' is not on the picture; ids: t1, t2, t3, o1, f1, f2"])
        XCTAssertEqual(problems(#"{"action":"removeText","ref":"o1"}"#, context: poster), ["steps[0].ref: o1 is not a text; removeText needs a text id (t or l)"])
        XCTAssertEqual(problems(#"{"action":"addText","text":"Été","ref":"f1","match":"t1"}"#, context: poster), [])
        XCTAssertEqual(problems(#"{"action":"addText","text":"Été","match":"t7"}"#, context: poster), ["steps[0].match: 't7' is not a text on the picture; ids: t1, t2, t3, o1, f1, f2"])
        XCTAssertTrue(problems(#"{"action":"eraseRegion"}"#, context: poster).contains("steps[0]: eraseRegion needs box or ref"))
        XCTAssertTrue(problems(#"{"action":"moveText","ref":"t3"}"#, context: poster).contains("steps[0]: moveText needs box, point or placement"))
        XCTAssertEqual(problems(#"{"action":"moveText","ref":"t3","placement":"top"}"#, context: poster), [])
    }

    // MARK: Coercer

    func testTheCoercerReadsTableStepsTheWayModelsWriteThem() throws {
        let use = ToolArgumentCoercer.rawToolUse(id: "c", name: "apply_edits", arguments: ["steps": [
            ["action": "fill_table", "value": 1, "scope": "remaining"],
            ["action": "populate", "value": "random", "range": [50, 90], "column": ["Opus 5", "Gemini 3.5 Pro"]],
            ["action": "set_cell", "value": "90%", "rows": "Agentic coding", "columns": "Opus 5"],
            ["action": "highlight_column", "column": 2, "color": "yellow"],
            ["action": "addText", "text": "Été", "fontSize": "large", "alignment": "left"],
            ["action": "adjust", "parameter": "contrast", "value": 10],
        ]])
        let steps = try XCTUnwrap(JSONValue.parse(use.rawInput)["steps"]?.array)
        XCTAssertEqual(steps[0], ["action": "fillCells", "text": "1", "cells": "empty"])
        XCTAssertEqual(steps[1], ["action": "fillCells", "values": "random", "min": 50, "max": 90, "column": "Opus 5|Gemini 3.5 Pro"])
        XCTAssertEqual(steps[2], ["action": "fillCells", "text": "90%", "row": "Agentic coding", "column": "Opus 5"])
        XCTAssertEqual(steps[3], ["action": "highlightCells", "column": "2", "color": "yellow"])
        XCTAssertEqual(steps[4], ["action": "addText", "text": "Été", "size": "large", "align": "left"])
        XCTAssertEqual(steps[5], ["action": "adjust", "parameter": "contrast", "amount": 10], "value is still the amount outside tables")
        let cased = ToolArgumentCoercer.rawToolUse(id: "d", name: "apply_edits", arguments: ["steps": [["action": "FillCells", "value": 7, "row": "Knowledge work"]]])
        XCTAssertEqual(try JSONValue.parse(cased.rawInput)["steps"]?.array?.first, ["action": "fillCells", "text": "7", "row": "Knowledge work"],
                       "the exact name read first, then the table aliases")
        XCTAssertEqual(problemsOf(use, context: tableContext), [])
    }

    private func problemsOf(_ use: RawToolUse, context: IntentContext) -> [String] {
        if case .failure(.problems(let problems)) = photo.validate(use, context: context) { return problems }
        return []
    }
}
