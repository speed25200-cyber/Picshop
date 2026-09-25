import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// What the user hears and taps (contract §12, A8, A12): the speech sanitizer, the reason-aware lines,
/// outcomeText's rule, the table count line, the honest verification line, and the idea chips that
/// follow the picture. Plus the handler's verify pass on an executor-backed editor.
final class SpeechAndIdeasTests: XCTestCase {
    // MARK: Sanitizer (A8)

    func testNoInternalWordIsEverSpokenInFrench() {
        let cases: [(String, String)] = [
            ("Je ne trouve pas « subject » sur la photo.", "Je ne trouve pas « sujet » sur la photo."),
            ("Je ne trouve pas « background » ici.", "Je ne trouve pas « arrière-plan » ici."),
            ("Je ne trouve pas « thing » sur la photo.", "Je ne trouve pas ça sur la photo."),
            ("C'est fait (table:action=fillCells;changed=4).", "C'est fait."),
            ("reason:no_subject", ""),
            ("Impossible [no_table] ici.", "Impossible ici."),
            ("Échec : no_subject.", "Échec."),
            ("Le textBehind a échoué.", "Le a échoué."),
            ("Je réessaie. Hint: use fillCells.", "Je réessaie."),
            ("Presque : verify failed 1/3: r1c2 reads '7'.", "Presque"),
            ("<tool_call>Je remplis.", "Je remplis."),
            // Ids and cell addresses the state lines teach are never heard (« J'efface t neuf »).
            ("J'efface t9.", "J'efface ce texte."),
            ("Je mets 1 dans r6c3.", "Je mets 1 dans cette case."),
            ("J'écris dans f1, sous o1.", "J'écris dans cet endroit, sous cet élément."),
            ("J'agrandis l2.", "J'agrandis ce texte."),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(LiveSpeechSanitizer.clean(raw, language: .french), expected, raw)
            XCTAssertFalse(LiveSpeechSanitizer.isClean(raw, language: .french), raw)
        }
        // The user's own words and Live's own lines pass through unchanged.
        for clean in ["Je ne trouve pas « panneau » sur la photo.", "J'ai mis un 1 dans les 45 cases.", "C'est fait.", "« Été 2026 » ajouté.",
                      "Sur une capture de tableau, il n'y a pas de sujet à détacher. Je remplis les cases à la place ?", "-50% sur tout"] {
            XCTAssertTrue(LiveSpeechSanitizer.isClean(clean, language: .french), clean)
        }
        XCTAssertEqual(LiveSpeechSanitizer.clean("I couldn't find “subject”. reason:not_found", language: .english), "I couldn't find “subject”.")
        XCTAssertEqual(LiveSpeechSanitizer.clean("Erasing t3 and r2c4.", language: .english), "Erasing that text and that cell.")
    }

    func testEveryLiveLineIsClean() {
        for reason in ExecutionReason.allCases {
            for action in IntentAction.allCases where action.isAllowed(in: .photo) {
                for hasTable in [false, true] {
                    for language in [NormalizedUtterance.Language.french, .english] {
                        let line = LiveLines.outcome(reason, action: action, hasTable: hasTable, language)
                        XCTAssertTrue(LiveSpeechSanitizer.isClean(line, language: language), line)
                        if language == .french { XCTAssertFalse(line.lowercased().contains("subject"), line) }
                    }
                }
            }
        }
    }

    // MARK: Lines

    func testTheTableCountLine() {
        let all = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1", alternative: "random")
        XCTAssertEqual(LiveLines.tableDone(all, .french), "J'ai mis un 1 dans les 45 cases. Je peux mettre des chiffres au hasard à la place.")
        XCTAssertEqual(LiveLines.tableDone(all, .english), "I put a 1 in all 45 cells. I can put random numbers instead.")
        let column = TableEditReport(action: .fillCells, changed: 9, kept: 0, emptyLeft: 36, dataRows: 9, dataColumns: 5, value: "random 50–90")
        XCTAssertEqual(LiveLines.tableDone(column, .french), "J'ai mis des nombres au hasard entre 50 et 90 dans 9 cases. Il reste 36 cases vides.")
        let rest = TableEditReport(action: .fillCells, changed: 44, kept: 1, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1")
        XCTAssertEqual(LiveLines.tableDone(rest, .french), "J'ai mis un 1 dans 44 cases. Une case était déjà remplie, j'ai gardé sa valeur.")
        let one = TableEditReport(action: .fillCells, changed: 1, kept: 0, emptyLeft: 44, dataRows: 9, dataColumns: 5, value: "90%")
        XCTAssertTrue(LiveLines.tableDone(one, .french).hasPrefix("J'ai mis « 90% » dans la case."))
        XCTAssertEqual(LiveLines.tableDone(TableEditReport(action: .clearCells, changed: 9, kept: 0, emptyLeft: 9, dataRows: 9, dataColumns: 5), .french), "J'ai vidé 9 cases.")
        XCTAssertEqual(LiveLines.tableDone(TableEditReport(action: .fillCells, changed: 3, kept: 0, emptyLeft: 0, dataRows: 1, dataColumns: 3, value: "8"), .english),
                       "I put an 8 in all 3 cells.")
    }

    func testTheHonestLineAfterAFailedCheck() {
        let cells = (1...3).map { VerificationCheck(kind: .textPresent, region: .unit, text: "1", tag: "r\($0)c1") }
        let report = VerificationReport(intentID: UUID(), action: .fillCells,
                                        items: [.init(check: cells[0], outcome: .failed, observed: "7"), .init(check: cells[1], outcome: .passed), .init(check: cells[2], outcome: .passed)],
                                        method: .pixels)
        XCTAssertEqual(LiveLines.verification(report, .french), "C'est fait en partie : 1 case sur 3 ne se lit pas bien — vérifie-la.")
        XCTAssertEqual(LiveLines.verification(report, .english), "Partly done: 1 of 3 cells don't read right — worth a check.")
        let gone = VerificationReport(intentID: UUID(), action: .removeObject,
                                      items: [.init(check: VerificationCheck(kind: .objectAbsent, region: .unit, label: "dog", tag: "dog"), outcome: .failed)], method: .pixels)
        XCTAssertEqual(LiveLines.verification(gone, .french), "Je l'ai retiré, mais on le voit encore un peu.")
    }

    // MARK: outcomeText

    func testOutcomeTextIsReasonAwareAndNeverRaw() {
        var refused = LiveExecution(steps: [LiveStepResult(index: 0, action: .textBehind, status: .failed, message: "Je ne trouve pas « subject » sur la photo.",
                                                           reason: .noSubject)], version: 2, canUndo: true)
        refused.pictureIsTable = true
        XCTAssertEqual(refused.outcomeText(language: .french), "Sur une capture de tableau, il n'y a pas de sujet à détacher. Je remplis les cases à la place ?")
        refused.pictureIsTable = false
        XCTAssertEqual(refused.outcomeText(language: .french), "Je ne vois personne à détacher sur cette photo.")
        let raw = LiveExecution(steps: [LiveStepResult(index: 0, action: .removeObject, status: .failed, message: "Je ne trouve pas « subject » sur la photo.")],
                                version: 2, canUndo: true)
        XCTAssertEqual(raw.outcomeText(language: .french), "Je ne trouve pas « sujet » sur la photo.")
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1")
        let filled = LiveExecution(steps: [LiveStepResult(index: 0, action: .fillCells, status: .applied, label: "Fill Cells", report: report)], version: 3, canUndo: true)
        XCTAssertEqual(filled.outcomeText(language: .french), "J'ai mis un 1 dans les 45 cases.")
        let blocked = LiveExecution(steps: [LiveStepResult(index: 0, action: .textBehind, status: .blocked, reason: .noSubject)], version: 3, canUndo: true)
        XCTAssertEqual(blocked.outcomeText(language: .french), "Je ne vois personne à détacher sur cette photo.")
        XCTAssertEqual(LiveExecution(steps: [LiveStepResult(index: 0, action: .adjust, status: .applied, label: "Warmth +15")], version: 3, canUndo: true)
            .outcomeText(language: .french), "C'est fait.")
    }

    // MARK: Questions answered by code (the no-model lane)

    func testQuestionsAboutTheTableAndTheTextAreAnsweredByCode() {
        let values = TableFixtures.benchmark(withValues: true)
        func table(_ words: String, _ language: NormalizedUtterance.Language = .french) -> String? {
            LiveQuestionAnswers.answer(words, table: values, scene: nil, language: language)
        }
        XCTAssertEqual(table("que vaut Opus 5 en Agentic coding ?"), "Opus 5 en Agentic coding : 77,2 %.")
        XCTAssertEqual(table("quelle est la valeur de la dernière ligne de la colonne Opus 5 ?"), "Opus 5 en Knowledge work : 74,6 %.")
        XCTAssertEqual(table("quelle est la meilleure valeur de la colonne Opus 5.5 ?"), "87,0 %, en Graduate-level reasoning.")
        XCTAssertEqual(table("which model is best at Knowledge work?", .english), "Opus 5.5, with 79.4%.")
        XCTAssertEqual(table("c'est quoi la dernière colonne ?"), "GPT-6 Astra.")
        XCTAssertEqual(LiveQuestionAnswers.answer("combien de cases sont vides ?", table: TableFixtures.benchmark(), scene: nil, language: .french), "Les 45 cases sont vides.")
        XCTAssertNil(table("remplis la colonne Opus 5 avec 1"), "a command is not a question")
        XCTAssertNil(table("tu en penses quoi ?"), "an opinion is the model's")
        let poster = SceneFixtures.posterScene()
        XCTAssertEqual(LiveQuestionAnswers.answer("c'est écrit quoi en bas ?", table: nil, scene: poster, language: .french), "C'est écrit « 29,99 € ».")
        XCTAssertEqual(LiveQuestionAnswers.answer("what does the title say?", table: nil, scene: poster, language: .english), "It says “SOLDES D'ÉTÉ”.")
        XCTAssertEqual(LiveQuestionAnswers.answer("tu vois une personne ?", table: nil, scene: poster, language: .french), "Oui, une personne.")
    }

    // MARK: Ideas (A12)

    private func tableState() -> LiveEditorState {
        var state = LiveEditorState(mode: .photo, version: 1)
        state.table = TableFixtures.benchmark()
        state.sceneMap = SceneFixtures.benchmarkScene()
        state.scene = SceneDescription(labels: ["screenshot", "document"], hasText: true, brightness: 0.92, colourfulness: 0.04)
        return state
    }

    func testTableIdeasAreAboutTheTable() {
        let ideas = IdeaEngine.heuristic(tableState(), dismissed: [], language: .french)
        XCTAssertEqual(ideas.map(\.title), ["Surligner Opus 5.5", "Texte plus net", "Fond blanc pur"], "the column the title names")
        XCTAssertFalse(ideas.contains { IdeaEngine.isLookOrColour($0) }, "no look, vibrance or colour on a table")
        XCTAssertFalse(ideas.contains { $0.steps.contains { $0.action == "fillCells" } }, "no chip invents values (D6)")
        XCTAssertEqual(ideas.first?.steps.first, RawIntentStep(action: "highlightCells", color: "yellow", column: "Opus 5.5"))
        // Every chip validates against the table it was built for.
        let context = IntentContext(mode: .photo, table: TableFixtures.benchmark(), scene: SceneFixtures.benchmarkScene())
        for idea in ideas {
            guard case .success = ToolInputValidator(mode: .photo).steps(raw: idea.steps, context: context) else { return XCTFail(idea.title) }
        }
        // A plain screenshot without a table: legibility too, never a colour look.
        var document = LiveEditorState(mode: .photo, version: 1)
        document.scene = SceneDescription(labels: ["screenshot"], hasText: true, brightness: 0.9, colourfulness: 0.05)
        XCTAssertFalse(IdeaEngine.heuristic(document, dismissed: [], language: .french).contains { IdeaEngine.isLookOrColour($0) })
    }

    func testTheModelsColourIdeasGiveWayOnATable() {
        let look = LiveIdea(title: "Couleurs éclatantes", why: "Plus de peps.", symbol: "sparkles", steps: [RawIntentStep(action: "applyLook", look: "vivid")], source: .model)
        let contrast = LiveIdea(title: "Contraste accru", why: "Plus net.", symbol: "sparkles",
                                steps: [RawIntentStep(action: "adjust", parameter: "contrast", amount: 20)], source: .model)
        let fill = IdeaEngine.heuristic(tableState(), dismissed: [], language: .french)
        let merged = IdeaEngine.merge(current: [], incoming: [look, contrast], dismissed: [], fill: fill, state: tableState())
        XCTAssertEqual(merged.map(\.title), ["Contraste accru", "Surligner Opus 5.5", "Texte plus net"], "the vivid look goes, the table chips fill in")
        let asked = IdeaEngine.merge(current: [], incoming: [look, contrast], dismissed: [], fill: fill, state: tableState(), userWords: "mets plus de couleurs")
        XCTAssertEqual(asked.first?.title, "Couleurs éclatantes", "the user talked colour")
        XCTAssertEqual(IdeaEngine.merge(current: [], incoming: [look], dismissed: [], fill: []), [look], "without a state: as before")
    }

    func testAfterAFillTheAlternativeTheUserNamedComesFirst() {
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1", alternative: "random")
        let ideas = IdeaEngine.afterTableEdit(report, language: .french)
        XCTAssertEqual(ideas.map(\.title), ["Chiffres au hasard"])
        XCTAssertEqual(ideas.first?.steps, [RawIntentStep(action: "fillCells", cells: "all", values: "random")])
        let ranged = IdeaEngine.afterTableEdit(TableEditReport(action: .fillCells, changed: 9, kept: 0, emptyLeft: 36, dataRows: 9, dataColumns: 5, value: "1",
                                                               alternative: "random 50–90"), language: .english)
        XCTAssertEqual(ranged.first?.steps.first?.min, 50)
        XCTAssertEqual(ranged.first?.steps.first?.max, 90)
        XCTAssertEqual(ranged.first?.title, "Random numbers")
        XCTAssertTrue(IdeaEngine.afterTableEdit(TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5, value: "1"),
                                                language: .french).isEmpty, "no alternative named: no fill chip (D6)")
        let context = IntentContext(mode: .photo, table: TableFixtures.benchmark())
        guard case .success = ToolInputValidator(mode: .photo).steps(raw: ideas[0].steps, context: context) else { return XCTFail("the chip validates") }
    }

    // MARK: The handler's verify pass (act-then-verify)

    func testTheHandlerChecksTheResultAndHintsTheModel() async throws { try await VerifyScenarios.checksAndHints() }
    func testTheGrammarLaneGetsTheSameCheck() async throws { try await VerifyScenarios.grammarLane() }
}

@MainActor private enum VerifyScenarios {
    static func checksAndHints() async throws {
        let host = TableEditorHost.benchmark(failingChecks: ["r2c1"])
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let fill = EditIntent(action: .fillCells, confidence: 0.9, table: TableEditSpec(value: .constant("1")))
        let result = await handler.perform(LiveToolCall(id: "t", tool: .applyEdits([fill])))
        let execution = try XCTUnwrap(result.execution)
        XCTAssertEqual(host.verifyCalls, 1, "one look for the whole run")
        XCTAssertEqual(execution.steps.first?.report?.changed, 45)
        XCTAssertEqual(execution.verifications.first?.status, .failed)
        XCTAssertEqual(execution.verificationSummary, "verify failed 1/45: r2c1 missing")
        XCTAssertNotNil(execution.steps.first?.hint)
        XCTAssertTrue(execution.pictureIsTable)
        XCTAssertTrue(ToolResultEncoder.compactText(result).contains("verify failed 1/45"))
        XCTAssertEqual(execution.outcomeText(language: .french), "C'est fait en partie : 1 case sur 45 ne se lit pas bien — vérifie-la.")

        // The subject step on the table screenshot: coded, hinted toward fillCells.
        let behind = await handler.perform(LiveToolCall(id: "u", tool: .applyEdits([EditIntent(action: .textBehind, text: "1")])))
        let refused = try XCTUnwrap(behind.execution?.steps.first)
        XCTAssertEqual(refused.reason, .noSubject)
        XCTAssertTrue(refused.hint?.contains("fillCells") ?? false)
        XCTAssertEqual(behind.execution?.outcomeText(language: .french), LiveLines.outcome(.noSubject, action: .textBehind, hasTable: true, .french))
    }

    static func grammarLane() async throws {
        let host = TableEditorHost.benchmark()
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let plan = RuleBasedIntentEngine().parse("Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires", context: host.liveIntentContext())
        let execution = await handler.runPlan(plan)
        XCTAssertEqual(host.verifyCalls, 1)
        XCTAssertEqual(execution.verifications.first?.status, .passed)
        XCTAssertEqual(host.cellLayers.count, 45)
        XCTAssertEqual(LocalLiveBrain.reply(to: plan, intents: plan.intents, execution: execution, language: .french),
                       "J'ai mis un 1 dans les 45 cases. Je peux mettre des chiffres au hasard à la place.")
        XCTAssertEqual(handler.recentActions.last?.source, .grammar)
        XCTAssertTrue(handler.recentActions.last?.line().hasPrefix("last: fillCells text=1 cells=empty → applied, filled 45") ?? false,
                      handler.recentActions.last?.line() ?? "")
    }
}
