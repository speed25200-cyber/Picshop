import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (§8.4): the grammar's layer, recipe and export phrases (anchored), the collisions with the W1/W2 rules, the
/// gesture rules of the photo panels and « continue ».
final class LayerGrammarTests: XCTestCase {
    static func plan(_ text: String, mode: EditorMode = .photo, pendingOutline: Bool = false, last: EditIntent? = nil,
                     lastParameter: AdjustmentParameter? = nil) -> EditPlan {
        var context: IntentContext
        switch mode {
        case .video: context = IntentContext(mode: .video, clipCount: 3, playheadSeconds: 4, timelineDuration: 30)
        default: context = IntentContext(mode: mode)
        }
        context.hasPendingOutline = pendingOutline
        context.lastIntent = last
        if let lastParameter {
            context.lastParameter = lastParameter
            context.lastAdjustmentDirection = 1
        }
        return RuleBasedIntentEngine().parse(text, context: context)
    }

    static func call(_ text: String, mode: EditorMode = .photo) -> OperationCall? {
        let plan = plan(text, mode: mode)
        guard plan.confidence >= 0.85 else { return nil }
        return plan.intents.first?.operation
    }

    /// The owned phrases: the operation and the arguments said.
    func testTheOwnedPhrasesParse() {
        let cases: [(String, OpID, [String: OpValue])] = [
            ("calque par copier", "layerVia", ["mode": "copy"]),
            ("calque par couper depuis la sélection", "layerVia", ["mode": "cut", "useSelection": true]),
            ("layer via copy", "layerVia", ["mode": "copy"]),
            ("fusionne avec le calque du dessous", "mergeLayers", ["mode": "down"]),
            ("merge down", "mergeLayers", ["mode": "down"]),
            ("fusionne les calques visibles", "mergeLayers", ["mode": "visible"]),
            ("aplatis l'image", "mergeLayers", ["mode": "flatten"]),
            ("flatten the image", "mergeLayers", ["mode": "flatten"]),
            ("tampon des calques visibles", "mergeLayers", ["mode": "stamp"]),
            ("stamp visible", "mergeLayers", ["mode": "stamp"]),
            ("crée un masque d'écrêtage", "layerClip", ["clip": true]),
            ("clip to the layer below", "layerClip", ["clip": true]),
            ("libère le masque d'écrêtage", "layerClip", ["clip": false]),
            ("groupe les calques", "groupLayers", ["all": true]),
            ("dissocie le groupe", "groupLayers", ["ungroup": true]),
            ("ungroup", "groupLayers", ["ungroup": true]),
            ("ajoute un calque de courbes", "addAdjustmentLayer", ["kind": "curves"]),
            ("calque de réglage niveaux", "addAdjustmentLayer", ["kind": "levels"]),
            ("ajoute un calque de teinte saturation", "addAdjustmentLayer", ["kind": "hsl"]),
            ("add a levels adjustment layer", "addAdjustmentLayer", ["kind": "levels"]),
            ("add a curves layer", "addAdjustmentLayer", ["kind": "curves"]),
            ("calque de remplissage blanc", "addFillLayer", ["fill": "solid", "color": "white"]),
            ("ajoute un calque de remplissage", "addFillLayer", ["fill": "solid"]),
            ("add a red fill layer", "addFillLayer", ["fill": "solid", "color": "red"]),
            ("exporte en PSD avec les calques", "exportPhoto", ["format": "psd", "layers": true]),
            ("exporte en png 16 bits", "exportPhoto", ["format": "png", "bitDepth": "16"]),
            ("export as tiff", "exportPhoto", ["format": "tiff"]),
            ("export as a 16 bit tiff", "exportPhoto", ["format": "tiff", "bitDepth": "16"]),
            ("prépare pour Instagram", "recipe", ["name": "instagramPost"]),
            ("make it instagram ready", "recipe", ["name": "instagramPost"]),
            ("photo produit", "recipe", ["name": "productPhoto"]),
            ("photo produit sur fond noir", "recipe", ["name": "productPhoto", "background": "black"]),
            ("product photo for etsy", "recipe", ["name": "productPhoto"]),
            ("retouche portrait", "recipe", ["name": "portraitRetouch"]),
            ("retouche portrait légère", "recipe", ["name": "portraitRetouch", "strength": 30]),
        ]
        for (text, op, args) in cases {
            guard let call = Self.call(text) else { XCTFail("« \(text) »: \(Self.plan(text).intents.map(\.action)) at \(Self.plan(text).confidence)"); continue }
            XCTAssertEqual(call.id, op, text)
            for (key, value) in args {
                let got = call.args[key]
                if case .number(let number) = value {
                    XCTAssertEqual(got?.double ?? .nan, number, accuracy: 1e-9, "\(text): \(key)")
                } else {
                    XCTAssertEqual(got, value, "\(text): \(key)")
                }
            }
        }
    }

    /// The owned whole-clause phrases reach their operation through both routers without a model: another operation's
    /// trigger inside the phrase (« calque visible », « le masque », « courbes ») does not cap them. A plan with an
    /// unread clause, or a recipe guessed from a word anywhere in the sentence, is still capped.
    func testTheOwnedLayerPhrasesRouteWithoutAModel() async {
        let cases: [(String, OpID)] = [
            ("fusionne les calques visibles", "mergeLayers"), ("tampon des calques visibles", "mergeLayers"),
            ("fais un tampon des calques visibles", "mergeLayers"), ("crée un masque d'écrêtage", "layerClip"),
            ("libère le masque d'écrêtage", "layerClip"), ("ajoute un calque de courbes", "addAdjustmentLayer"),
            ("calque de réglage niveaux", "addAdjustmentLayer"), ("add a levels adjustment layer", "addAdjustmentLayer"),
            ("add a curves layer", "addAdjustmentLayer"), ("ajoute un calque d'étalonnage", "addAdjustmentLayer"),
        ]
        for (text, op) in cases {
            let routed = await HybridIntentRouter(preferredEngine: .rules).plan(text, context: IntentContext(mode: .photo))
            XCTAssertEqual(routed.intents.first?.operation?.id, op, "« \(text) »: \(routed.intents.map(\.action)) \(routed.reply ?? "")")
            XCTAssertGreaterThanOrEqual(routed.confidence, 0.85, text)
            let lane = LiveTurnRouter.route(text, grammar: Self.plan(text), brain: .local, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: .photo)
            guard case .local(let plan) = lane else { XCTFail("Live: \(text) → \(lane)"); continue }
            XCTAssertEqual(plan.intents.first?.operation?.id, op, "Live: \(text)")
        }
        for text in ["courbe en S pour vinted", "ajoute un calque de courbes et courbe en S"] {
            let capped = OperationAbstention.capped(Self.plan(text), utterance: text, domain: .photo)
            XCTAssertLessThan(capped.confidence, 0.85, text)
        }
    }

    /// « On aplatit ? » has no candidates: « oui » confirms it (the executor re-runs the flatten with `confirm`), on the
    /// voice path and on Live's local lane even with a model loaded; « non » still cancels.
    func testYesConfirmsAPendingFlatten() {
        let call = OperationCall("mergeLayers", args: ["mode": "flatten", "confirm": true], source: .grammar)
        let pending = ClarificationRequest(question: "Les calques masqués seront supprimés. On aplatit ?", candidates: [],
                                           pendingIntent: EditIntent(action: .operation, confidence: 0.85, operation: call))
        var context = IntentContext(mode: .photo)
        context.pendingClarification = pending
        for word in ["oui", "ok", "yes", "oui vas-y", "d'accord", "on aplatit", "c'est bon"] {
            let plan = RuleBasedIntentEngine().parse(word, context: context)
            XCTAssertEqual(plan.intents.map(\.action), [.confirm], word)
            XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, word)
            let lane = LiveTurnRouter.route(word, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: .photo,
                                            pendingYesNo: true)
            XCTAssertEqual(lane, .local(plan), "Live: \(word)")
        }
        XCTAssertEqual(RuleBasedIntentEngine().parse("non", context: context).intents.map(\.action), [.cancel])
        // Without the editor's question, « oui » answers the model (its own spoken offer).
        let plain = RuleBasedIntentEngine().parse("oui", context: IntentContext(mode: .photo))
        XCTAssertNotEqual(LiveTurnRouter.route("oui", grammar: plain, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true, mode: .photo),
                          .local(plain))
    }

    func testTheVlogRecipeIsAVideoPhrase() {
        XCTAssertEqual(Self.call("nettoie mon vlog", mode: .video)?.args["name"], .string("vlogCleanup"))
        XCTAssertNotEqual(Self.call("nettoie mon vlog")?.id, "recipe", "not on a photo")
    }

    /// §8.4: the W1 product goal now lands on the recipe; the other goals are unchanged.
    func testParseGoalProductPhrasesLandOnTheRecipe() {
        for text in ["photo produit", "je veux la vendre sur vinted", "pour leboncoin", "fiche produit", "product photo"] {
            let plan = Self.plan(text)
            XCTAssertEqual(plan.intents.first?.operation?.id, "recipe", text)
            XCTAssertFalse(plan.intents.contains { $0.action == .replaceBackground }, "\(text): not the W1 goal")
        }
        XCTAssertEqual(Self.plan("transforme ça en photo de profil").intents.map(\.action), [.autoEnhance, .crop], "the other goals stay")
        for text in ["photo pour amazon", "photo catalogue"] {
            XCTAssertEqual(Self.plan(text).intents.first?.operation?.id, "recipe", text)
        }
        // A product word inside an export, a text or an edit of the photo is not the recipe.
        let others: [(String, IntentAction)] = [
            ("exporte la photo pour vendre", .export), ("write \"for sale\" at the top", .addText), ("écris « Promo eBay » en haut", .addText),
            ("add the text Etsy shop at the bottom", .addText), ("enlève le fond de la photo produit", .removeBackground),
            ("mets le prix en rouge sur la photo produit", .recolor),
        ]
        for (text, action) in others {
            let plan = Self.plan(text)
            XCTAssertFalse(plan.intents.contains { $0.operation?.id == "recipe" }, "« \(text) »: \(plan.intents.map(\.action))")
            XCTAssertEqual(plan.intents.first?.action, action, text)
        }
    }

    /// The collisions of §8.4.
    func testTheCollisionsResolve() {
        // W1 export and share stay W1 when no format is said.
        XCTAssertEqual(Self.plan("exporte").intents.first?.action, .export)
        XCTAssertEqual(Self.plan("enregistre la photo").intents.first?.action, .export)
        // « masque le calque » hides it (W1 layerVisibility), never a layer mask.
        XCTAssertNotEqual(Self.plan("masque le calque").intents.first?.operation?.id, "layerMask")
        // « fusionne les calques » is the model's (which merge?), never a confident W1 answer.
        let merge = Self.plan("fusionne les calques")
        XCTAssertFalse(merge.confidence >= 0.85 && merge.intents.contains { $0.action != .unknown && $0.operation?.id != "mergeLayers" }, "\(merge.intents.map(\.action))")
        // A layer mask said in words goes to the model: the W2 mask rules do not take it.
        let layerMask = Self.plan("ajoute un masque de fusion qui garde le sujet")
        XCTAssertFalse(layerMask.confidence >= 0.85 && layerMask.intents.contains { $0.operation?.id == "maskAdjust" })
        // « baisse l'exposition du calque de réglage j4 » names the layer j4, it does not add one.
        let tone = Self.plan("baisse l'exposition du calque de réglage j4")
        XCTAssertNil(OperationAbstention.reason(for: tone, utterance: "baisse l'exposition du calque de réglage j4", domain: .photo))
    }

    /// D20: « continue » resumes the brain's outline while there is one; otherwise it keeps its W1 meaning.
    func testContinueWithAndWithoutAPendingOutline() {
        let last = EditIntent(action: .adjust, parameter: .brightness, amount: .relative(10))
        for word in ["continue", "la suite", "vas-y", "keep going", "go on"] {
            let pending = Self.plan(word, pendingOutline: true, last: last, lastParameter: .brightness)
            XCTAssertFalse(pending.intents.contains { $0.action == .adjust }, "« \(word) » with an outline: \(pending.intents.map(\.action))")
        }
        let repeated = Self.plan("continue", pendingOutline: false, last: last, lastParameter: .brightness)
        XCTAssertEqual(repeated.intents.first?.action, .adjust, "W1: repeat the last slider")
        XCTAssertTrue(GoalOutline.isContinue("Continue !"))
        XCTAssertFalse(GoalOutline.isContinue("continue la courbe"))
    }

    /// I1 at W3: the photo panels' gesture-only controls said aloud open their tool.
    func testPhotoGestureRulesOpenTheirTool() async {
        for rule in RuleBasedIntentEngine.photoGestureRules {
            for phrase in rule.phrases {
                let plan = Self.plan(phrase)
                guard let call = plan.intents.first?.operation else { XCTFail("« \(phrase) » → \(plan.intents.map(\.action))"); continue }
                XCTAssertEqual(call.args["openTool"], .string(rule.control), phrase)
                XCTAssertGreaterThanOrEqual(plan.confidence, 0.85, phrase)
            }
        }
        let document = OperationFixtures.photoWithLayers()
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .french)
        let plan = Self.plan("peins le masque de fusion")
        let (after, result) = await executor.execute(plan.intents[0], on: document, context: OperationFixtures.photoContext(document))
        XCTAssertEqual(after, document)
        XCTAssertTrue(result.effects.contains(.message("openTool:layers.mask.paint")), "\(result.effects)")
        XCTAssertEqual(result.outcome.message, "Peins sur la photo : blanc révèle, noir masque.")
    }

    /// The layer rules stay off the other editors and behind their flags' gate.
    func testLayerPhrasesStayOnPhotos() {
        XCTAssertNil(Self.call("aplatis l'image", mode: .video))
        XCTAssertNil(Self.call("calque par copier", mode: .pdf))
    }
}
