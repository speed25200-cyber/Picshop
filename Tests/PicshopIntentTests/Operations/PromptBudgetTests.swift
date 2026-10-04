import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The catalog layout's prompt budgets (I6): the byte-stable prefix (system prompt, tool specs and the
/// behavioural examples, rendered through Qwen3.5's template) stays under 8,700 characters for the 4B and
/// 6,050 for the 2B (about 2,600 and 1,800 tokens at the measured 3.36 characters a token), in photo and
/// video; the per-turn <ops> block under 1,000 and 600; the PDF planner sees no photo example and no
/// photo or video action.
final class PromptBudgetTests: XCTestCase {
    static func prefix(_ mode: EditorMode, _ size: LocalPromptSize) -> String {
        let setup = LocalChatSetup(system: LocalLivePrompt.system(mode: mode, size: size, layout: .catalog), tools: LocalLivePrompt.toolSpecs(mode: mode, layout: .catalog),
                                   history: LocalModelLiveBrain.exampleHistory(mode: mode, size: size, layout: .catalog), imageMaxPixels: 196_608)
        return QwenChatTemplate.render(setup, addGenerationPrompt: false)
    }

    func testStablePrefixBudgets() {
        for mode in [EditorMode.photo, .video] {
            for size in [LocalPromptSize.full, .compact] {
                let text = Self.prefix(mode, size)
                let system = LocalLivePrompt.system(mode: mode, size: size, layout: .catalog)
                let core = OperationCards.coreBlock(for: mode.opDomain, size: size)
                let budget = size == .full ? 8_700 : 6_050
                XCTAssertLessThanOrEqual(text.count, budget, "\(mode) \(size): prefix \(text.count) (system \(system.count), core \(core.count))")
                XCTAssertLessThanOrEqual(core.count, 1_400, "\(mode) \(size) core block")
            }
        }
    }

    /// W2 (§8.5): one grounding rule (≤ 180 characters) in the photo catalog prompt, and a fresh look when a
    /// select or mask word names a visible thing.
    func testTheGroundingRuleAndTheFreshLook() {
        XCTAssertLessThanOrEqual(LocalLivePrompt.groundingRule.count, 180)
        for size in [LocalPromptSize.full, .compact] {
            XCTAssertTrue(LocalLivePrompt.system(mode: .photo, size: size, layout: .catalog).contains(LocalLivePrompt.groundingRule))
            XCTAssertFalse(LocalLivePrompt.system(mode: .video, size: size, layout: .catalog).contains(LocalLivePrompt.groundingRule))
        }
        func look(_ text: String) -> Bool {
            var turn = LiveUserTurn.speech(text)
            turn.kind = .speech
            return LocalLivePrompt.needsFreshLook(turn, versionsSinceLastLook: 0)
        }
        XCTAssertTrue(look("sélectionne la tasse"))
        XCTAssertTrue(look("masque le chien"))
        XCTAssertTrue(look("select the mug"))
        XCTAssertFalse(look("inverse la sélection"))
        XCTAssertFalse(look("plus chaud"))
    }

    func testThePrefixIsByteStableAndCarriesNoTurnState() {
        for mode in [EditorMode.photo, .video] {
            XCTAssertEqual(Self.prefix(mode, .full), Self.prefix(mode, .full))
            let system = LocalLivePrompt.system(mode: mode, size: .full, layout: .catalog)
            XCTAssertFalse(system.contains("<editor_state v="), "the state travels with the turn")
            XCTAssertTrue(system.contains("<ops>"), "the system prompt says where the turn's cards come")
            XCTAssertTrue(system.hasPrefix("Tu es Picshop Live"))
        }
    }

    func testTheCatalogExamplesAreBehavioural() {
        let photo = LocalLivePrompt.examples(mode: .photo, size: .full, layout: .catalog)
        XCTAssertGreaterThanOrEqual(photo.count, 6)
        XCTAssertLessThanOrEqual(photo.count, 7)
        XCTAssertTrue(photo.contains { $0.toolName == .undo }, "undo")
        XCTAssertTrue(photo.contains { $0.toolName == .proposeIdeas }, "ideas")
        XCTAssertTrue(photo.contains { $0.repair != nil }, "repair after verify failed")
        XCTAssertTrue(photo.contains { $0.toolName == nil && $0.assistant.contains("?") }, "honest refusal with the nearest operation")
        XCTAssertTrue(photo.contains { $0.user.contains("last:") }, "a follow-up on last:")
        XCTAssertEqual(LocalLivePrompt.examples(mode: .video, size: .full, layout: .catalog).count, 4)
        XCTAssertEqual(LocalLivePrompt.examples(mode: .photo, size: .compact, layout: .catalog).count, 3)
        // A catalog call written from a card, as the cards print it (not in the prefix: the budget keeps the six behaviours).
        let curves = Examples.catalogCall(user: "applique une courbe en S légère", language: .french, version: 4, id: "curves",
                                          arguments: ["preset": "sCurve", "amount": 30], said: "Je pose une courbe en S légère.", label: "Curves")
        XCTAssertEqual(curves.arguments?["steps"]?.array?.first?["action"], "curves")
        XCTAssertFalse(LocalLivePrompt.examples(mode: .pdf, size: .full, layout: .catalog).contains { $0.toolName != nil },
                       "no PDF Live call before W5: the PDF set talks")
    }

    func testTurnCardsStayWithinTheirBudget() {
        let retrieved = OperationCatalog.shared.specs(in: .photo).prefix(12).map { RetrievedOperation(id: $0.id, score: 1) }
        let full = OperationCards.turnBlock(Array(retrieved.prefix(8)), language: .fr, budget: 1_000)
        let compact = OperationCards.turnBlock(Array(retrieved.prefix(5)), language: .fr, budget: 600)
        XCTAssertLessThanOrEqual(full.count, 1_000)
        XCTAssertLessThanOrEqual(compact.count, 600)
        var turn = LiveUserTurn.speech("applique une courbe en S")
        turn.editorState.appliedEdits = ["Warmth +15"]
        let message = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false, cards: full)
        if !full.isEmpty { XCTAssertTrue(message.contains(full), "the cards are never cut") }
        XCTAssertTrue(message.hasSuffix("applique une courbe en S"))
        XCTAssertLessThan(message.range(of: "langue:")?.lowerBound ?? message.startIndex, message.endIndex)
    }

    func testThePDFPlannerSeesOnlyPDFActionsAndPDFExamples() {
        let instructions = IntentPrompt.systemInstructions(mode: .pdf)
        for action in IntentAction.allCases where action.isPhotoOnly || action.isVideoOnly {
            XCTAssertNil(instructions.range(of: "\\b\(action.rawValue)\\b", options: .regularExpression), "PDF planner names \(action.rawValue)")
        }
        let examples = IntentPrompt.fewShotExamples(for: .pdf)
        XCTAssertFalse(examples.isEmpty)
        let photoActions = IntentAction.allCases.filter { $0.isPhotoOnly || $0.isVideoOnly || [.adjust, .applyLook, .removeObject].contains($0) }
        for (_, json) in examples {
            for action in photoActions { XCTAssertFalse(json.contains("\"action\":\"\(action.rawValue)\""), json) }
        }
        XCTAssertTrue(examples.contains { $0.1.contains("\"movePage\",\"clipNumber\":2,\"choiceIndex\":-1") }, "movePage: clipNumber is the page moved")
        // The video planner lists every video action and no photo-only one.
        let video = IntentPrompt.systemInstructions(mode: .video)
        for action in IntentAction.allCases where action.isVideoOnly {
            XCTAssertTrue(video.contains(action.rawValue), action.rawValue)
        }
        XCTAssertFalse(IntentPrompt.actionList(for: .video).split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "fillCells" })
    }
}
