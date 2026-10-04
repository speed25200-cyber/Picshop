import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (D20): outline-then-fill. Which goals are long, the parser for a small model's messy outline, the requests, the
/// 4B brain running outline → fill 1 → fill 2 on a scripted engine, « continue », the expiry, and the 2B's honest line.
final class OutlineTests: XCTestCase {
    static let longGoals = [
        "prépare cette photo pour la boutique : fond blanc, carré, plus lumineux, ombre douce, export PNG",
        "recadre en carré, éclaircis les ombres, ajoute un titre en haut et floute le fond",
        "redresse l'horizon, puis rends le ciel plus bleu, ajoute du grain, une vignette, un titre en haut et exporte en JPEG",
        "crop it square, brighten the shadows, add a title at the top and blur the background",
        "straighten the horizon, make the sky bluer, add grain, a vignette, a title at the top and export as a PNG",
        "supprime le fond, mets un fond blanc, recadre en carré et augmente le contraste",
        "remove the background, add a white fill layer, make it square and boost the contrast",
        "enlève les passants, réchauffe la photo, ajoute une vignette, floute le fond, ajoute un titre et exporte en TIFF",
        "remove the people in the back, warm it up, blur the background, add a vignette, add a title and export as a TIFF",
        "ajoute un calque de courbes, un dégradé noir en bas, un titre blanc et exporte en PSD",
        "add a curves layer, a black gradient at the bottom, a white title and export as PSD",
        "éclaircis le visage, adoucis la peau, blanchis les dents et floute l'arrière-plan",
        "brighten the face, smooth the skin, whiten the teeth, blur the background, crop to 4:5 and export as JPEG",
        "mets la photo en noir et blanc, ajoute du grain, recadre en 4:5 et ajoute un texte en bas",
        "convert to black and white, add grain, crop to 4:5 and add a text at the bottom",
        "corrige la perspective, redresse, augmente la netteté, réduis le bruit, ajoute une courbe en S et exporte en TIFF 16 bits",
        "fix the perspective, straighten it, sharpen it, reduce the noise, add an S curve and export a 16-bit TIFF",
        "fais tout : recadre en carré, réchauffe les couleurs, plus de netteté, ajoute un titre en haut, une vignette et exporte en PNG",
        "do everything: square crop, warmer colours, more sharpness and a title",
        "éclaircis le ciel, assombris le bas, sature les couleurs et ajoute un cadre blanc",
        "brighten the sky, darken the bottom, saturate the colours and add a vignette",
        "retire le logo, floute les visages, recadre en 16:9, ajoute un dégradé noir en bas, un titre et exporte en PNG",
    ]

    static let shortRequests = [
        "plus lumineux", "recadre en carré", "ajoute un titre", "supprime le fond", "rends-la plus chaude", "tu en penses quoi ?", "merci",
        "continue", "éclaircis et ajoute du contraste", "brighten it", "make it square", "add a title", "remove the background",
        "warmer please", "what do you think?", "thanks", "annule", "exporte en PNG", "ajoute un calque de courbes", "flatten the image",
        "merge down", "groupe les calques", "plus de contraste et plus de saturation", "everything looks great",
        // One batch is enough for these four-part goals (fewer than 7 operations): no outline.
        "corrige la perspective, redresse, augmente la netteté et réduis le bruit", "fix the perspective, straighten it, sharpen it and reduce the noise",
        "retire le logo, floute les visages, recadre en 16:9 et exporte en PNG",
    ]

    static func turn(_ text: String, mode: EditorMode = .photo) -> LiveUserTurn {
        LiveUserTurn(id: 1, kind: .speech, text: text, language: NormalizedUtterance(text).language, image: nil, editorState: BrainTurns.state(mode: mode))
    }

    func testLongGoals() {
        XCTAssertGreaterThanOrEqual(Self.longGoals.count, 20)
        for text in Self.longGoals { XCTAssertTrue(GoalOutline.isLongGoal(turn: Self.turn(text), mode: .photo), text) }
    }

    func testShortRequestsAreNotLongGoals() {
        XCTAssertGreaterThanOrEqual(Self.shortRequests.count, 20)
        for text in Self.shortRequests { XCTAssertFalse(GoalOutline.isLongGoal(turn: Self.turn(text), mode: .photo), text) }
        XCTAssertFalse(GoalOutline.isLongGoal(turn: LiveUserTurn(id: 1, kind: .sessionStart, text: Self.longGoals[0], language: .french, image: nil,
                                                                 editorState: BrainTurns.state()), mode: .photo), "never the session start")
    }

    // MARK: Parsing

    func testParseCleansAMessyOutline() {
        let text = """
        Voici le plan :
        1. crop carré
        2) removeBackground fond transparent
        - **addFillLayer** fond blanc sous le produit
        • adjust plus lumineux
        3. teleport nulle part
        4. adjust encore plus lumineux
        Step 5: `exportPhoto` PNG pour la boutique en ligne
        6 - layer_via sujet à part
        """
        let steps = GoalOutline.parse(text, catalog: .shared)
        XCTAssertEqual(steps.map(\.op.raw), ["crop", "removeBackground", "addFillLayer", "adjust", "exportPhoto", "layerVia"])
        XCTAssertEqual(steps[0].purpose, "carré")
        XCTAssertEqual(steps[2].purpose, "fond blanc sous le", "at most 4 words")
        XCTAssertEqual(steps[3].purpose, "plus lumineux", "a repeated id keeps its first purpose")
        XCTAssertEqual(steps[4].purpose, "PNG pour la boutique")
    }

    func testParseKeepsTwelveAtMost() {
        let ids = ["adjust", "curves", "levels", "hsl", "colorGrade", "crop", "straighten", "removeBackground", "addFillLayer", "layerVia", "addText",
                   "exportPhoto", "autoTone", "mergeLayers"]
        let steps = GoalOutline.parse(ids.enumerated().map { "\($0.offset + 1). \($0.element) pour voir" }.joined(separator: "\n"), catalog: .shared)
        XCTAssertEqual(steps.count, GoalOutline.maxSteps)
        XCTAssertEqual(steps.first?.op, "adjust")
    }

    func testRequestsAndRecap() {
        let steps = (1...8).map { OutlineStep(op: $0.isMultiple(of: 2) ? "adjust" : "curves", purpose: "étape \($0)") }
        XCTAssertEqual(GoalOutline.batch(1, of: steps).count, 6)
        XCTAssertEqual(GoalOutline.batch(2, of: steps).count, 2)
        XCTAssertEqual(GoalOutline.batch(3, of: steps).count, 0)
        let second = GoalOutline.fillRequest(batch: 2, steps: steps, language: .fr)
        XCTAssertTrue(second.hasPrefix("Now do steps 7 to 8 of your plan in ONE apply_edits call"), second)
        XCTAssertTrue(second.contains("\n7. curves étape 7\n8. adjust étape 8"), second)
        XCTAssertTrue(second.contains("in French"))
        XCTAssertTrue(GoalOutline.outlineRequest(language: .en).contains("at most 12 numbered lines"))
        XCTAssertEqual(GoalOutline.recapLine([OutlineStep(op: "curves", purpose: "S doux"), OutlineStep(op: "addFillLayer", purpose: "")]),
                       "outline: curves S doux | addFillLayer")
        XCTAssertNil(GoalOutline.recapLine([]))
        let recap = LocalLivePrompt.recap(LocalRecapInput(appliedEdits: [], lastExchanges: [], openQuestion: nil, lastLook: nil,
                                                          outline: "outline: curves S doux"))
        XCTAssertTrue(recap.contains("\noutline: curves S doux\n"), recap)
        XCTAssertEqual(GoalOutline.spokenOutline(steps, french: true), "Je fais ça en deux temps : étape 1, étape 2, étape 3 et 5 autres étapes.")
        XCTAssertEqual(GoalOutline.stoppedLine(done: 6, french: true), "J'ai fait les 6 premières étapes ; dis « continue » pour la suite.")
        XCTAssertEqual(GoalOutline.firstStepsLine(french: true), "Je fais les 6 premières étapes ; redis-moi la suite.")
    }

    // MARK: The 4B brain

    static let outline = """
    1. crop carré
    2. adjust plus lumineux
    3. curves contraste doux
    4. hsl bleus plus vifs
    5. autoTone équilibre
    6. levels points noir blanc
    7. exportPhoto PNG
    """

    static let batchOne: JSONValue = ["steps": [
        ["action": "crop", "aspect": "square"], ["action": "adjust", "parameter": "brightness", "amount": 20],
        ["action": "curves", "preset": "sCurve"], ["action": "hsl", "band": "blue", "saturation": 20],
        ["action": "autoTone"], ["action": "levels", "auto": true],
    ]]
    static let batchTwo: JSONValue = ["steps": [["action": "exportPhoto", "format": "png"]]]

    static func brain(_ factory: FakeEngineFactory, info: LocalModelInfo = .qwen4B, limits: LocalModelLiveBrain.Limits = .relaxedForTests) -> LocalModelLiveBrain {
        LocalModelLiveBrain(mode: .photo, info: info, makeEngine: factory.factory, fallback: nil, limits: limits, clock: BrainTestClock())
    }

    func testTheFourBOutlinesThenFillsTwoBatches() async throws {
        let goal = Self.longGoals[0]
        let factory = FakeEngineFactory(scripts: [[
            [.text(Self.outline), Say.done()],
            [.text("D'abord le cadre et la lumière."), Say.call("apply_edits", Self.batchOne, id: "c1"), Say.done()],
            [.text("Et l'export."), Say.call("apply_edits", Self.batchTwo, id: "c2"), Say.done()],
        ]])
        let brain = Self.brain(factory)
        let handler = ScriptedToolHandler()
        let (events, error) = await drain(brain.respond(to: BrainTurns.speech(goal), tools: handler))
        XCTAssertNil(error)
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 3, "outline, fill 1, fill 2: within maxRounds")
        guard engine.sent.count == 3 else { return }
        let first = engine.sent[0].compactMap(\.userText).joined()
        XCTAssertTrue(first.contains("<task>This is a long goal. Do not call any tool yet."), first)
        // D20: « ombre douce » is not possible yet: the prompt says so, and so does the spoken outline.
        XCTAssertTrue(first.contains("Not possible yet"), first)
        let second = engine.sent[1].compactMap(\.userText).joined()
        XCTAssertTrue(second.contains("Now do steps 1 to 6 of your plan"), second)
        XCTAssertTrue(second.contains("<ops>"), "the cards of exactly those operations")
        let third = engine.sent[2].compactMap(\.userText).joined()
        XCTAssertTrue(third.contains("Now do steps 7 to 7 of your plan"), third)
        XCTAssertTrue(third.contains("exportPhoto"), third)
        let said = events.said
        XCTAssertTrue(said.hasPrefix("Je fais ça en deux temps : carré, plus lumineux, contraste doux et 4 autres étapes. "), said)
        XCTAssertFalse(said.contains("1. crop"), "the outline is read, not said")
        XCTAssertTrue(said.contains("L'ombre portée n'est pas encore possible"), said)
        let calls = await handler.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(events.end, .editApplied)
        XCTAssertFalse(brain.hasPendingOutline, "everything done")
        assertSpeakable(events)
    }

    /// Out of rounds after the first batch: the rest waits for « continue », which runs the next batch with its cards.
    func testContinueResumesThePendingOutline() async throws {
        var limits = LocalModelLiveBrain.Limits.relaxedForTests
        limits.outlineMaxRounds = 2
        limits.maxRounds = 2
        let factory = FakeEngineFactory(scripts: [[
            [.text(Self.outline), Say.done()],
            [.text("Le cadre et la lumière."), Say.call("apply_edits", Self.batchOne, id: "c1"), Say.done()],
            [.text("L'export."), Say.call("apply_edits", Self.batchTwo, id: "c2"), Say.done()],
        ]])
        let brain = Self.brain(factory, limits: limits)
        let handler = ScriptedToolHandler()
        let (events, _) = await drain(brain.respond(to: BrainTurns.speech(Self.longGoals[0], id: 1), tools: handler))
        XCTAssertTrue(events.said.hasSuffix("J'ai fait les 6 premières étapes ; dis « continue » pour la suite."), events.said)
        XCTAssertTrue(brain.hasPendingOutline)
        let pending = await brain.pendingOutline
        XCTAssertEqual(pending.map(\.op.raw), ["exportPhoto"])
        // The grammar leaves « continue » to the brain while the outline is pending.
        let context = BrainSelector.intentContext(IntentContext(mode: .photo, lastParameter: .brightness, lastAdjustmentDirection: 1), brain: brain)
        XCTAssertTrue(context.hasPendingOutline)
        XCTAssertTrue(RuleBasedIntentEngine().parse("continue", context: context).intents.allSatisfy { $0.action != .adjust })

        let (resumed, _) = await drain(brain.respond(to: BrainTurns.speech("continue", id: 2, version: 11), tools: handler))
        let engine = try XCTUnwrap(factory.engines.first)
        let message = try XCTUnwrap(engine.sent.last?.compactMap(\.userText).joined())
        XCTAssertTrue(message.contains("Now do steps 7 to 7 of your plan"), message)
        XCTAssertTrue(message.contains("exportPhoto"), message)
        XCTAssertEqual(resumed.end, .editApplied)
        XCTAssertFalse(brain.hasPendingOutline)
    }

    /// Three turns without « continue » drop the outline; so does a manual edit.
    func testThePendingOutlineExpires() async throws {
        var limits = LocalModelLiveBrain.Limits.relaxedForTests
        limits.outlineMaxRounds = 2
        limits.maxRounds = 2
        let chat: [[LocalChatEvent]] = [[.text("D'accord."), Say.done()], [.text("Oui."), Say.done()], [.text("Bien."), Say.done()]]
        let factory = FakeEngineFactory(scripts: [[
            [.text(Self.outline), Say.done()], [.text("Premier lot."), Say.call("apply_edits", Self.batchOne, id: "c1"), Say.done()],
        ] + chat])
        let brain = Self.brain(factory, limits: limits)
        let handler = ScriptedToolHandler()
        _ = await drain(brain.respond(to: BrainTurns.speech(Self.longGoals[0], id: 1), tools: handler))
        XCTAssertTrue(brain.hasPendingOutline)
        for id in 2...3 {
            _ = await drain(brain.respond(to: BrainTurns.speech("tu aimes ?", id: id), tools: handler))
            XCTAssertTrue(brain.hasPendingOutline, "turn \(id)")
        }
        _ = await drain(brain.respond(to: BrainTurns.speech("c'est joli", id: 4), tools: handler))
        XCTAssertFalse(brain.hasPendingOutline, "three turns without « continue »")

        let manualFactory = FakeEngineFactory(scripts: [[
            [.text(Self.outline), Say.done()], [.text("Premier lot."), Say.call("apply_edits", Self.batchOne, id: "c1"), Say.done()],
            [.text("Je vois."), Say.done()],
        ]])
        let manual = Self.brain(manualFactory, limits: limits)
        _ = await drain(manual.respond(to: BrainTurns.speech(Self.longGoals[0], id: 1), tools: handler))
        XCTAssertTrue(manual.hasPendingOutline)
        var turn = BrainTurns.speech("regarde", id: 2)
        turn.sinceLastReply = ["Contrast +15 (manual)"]
        _ = await drain(manual.respond(to: turn, tools: handler))
        XCTAssertFalse(manual.hasPendingOutline, "a manual edit drops it")
    }

    /// The 2B keeps no outline: the first batch, then the honest line (never « continue »).
    func testTheTwoBAnswersHonestly() async throws {
        let factory = FakeEngineFactory(scripts: [[
            [.text("Je commence."), Say.call("apply_edits", Self.batchOne, id: "c1"), Say.done()],
        ]])
        let brain = Self.brain(factory, info: .qwen2B)
        let handler = ScriptedToolHandler()
        let (events, _) = await drain(brain.respond(to: BrainTurns.speech(Self.longGoals[0]), tools: handler))
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertEqual(engine.sent.count, 1)
        let first = engine.sent[0].compactMap(\.userText).joined()
        XCTAssertTrue(first.contains("<task>This is a long goal. Do only its first 6 steps now"), first)
        XCTAssertTrue(events.said.hasSuffix("Je fais les 6 premières étapes ; redis-moi la suite."), events.said)
        XCTAssertFalse(events.said.contains("continue"))
        XCTAssertFalse(brain.hasPendingOutline)
    }

    /// A short request on the 4B never outlines.
    func testAShortRequestNeverOutlines() async throws {
        let factory = FakeEngineFactory(scripts: [[[.text("Plus lumineuse."), Say.call("apply_edits", Say.warmer), Say.done()]]])
        let brain = Self.brain(factory)
        _ = await drain(brain.respond(to: BrainTurns.speech("plus lumineux"), tools: ScriptedToolHandler()))
        let engine = try XCTUnwrap(factory.engines.first)
        XCTAssertFalse(engine.sent[0].compactMap(\.userText).joined().contains("<task>"))
    }
}
