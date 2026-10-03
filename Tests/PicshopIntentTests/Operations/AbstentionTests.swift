import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// OperationAbstention's rules, one by one.
final class AbstentionTests: XCTestCase {
    private let engine = RuleBasedIntentEngine()

    private func plan(_ text: String, _ domain: OpDomain = .photo) -> EditPlan {
        engine.parse(text, context: GrammarLaneTests.context(domain))
    }

    private func reason(_ text: String, _ domain: OpDomain = .photo) -> OperationAbstention.Reason? {
        OperationAbstention.reason(for: plan(text, domain), utterance: text, domain: domain)
    }

    func testUnownedOperationsAreNamed() {
        XCTAssertEqual(OperationAbstention.namesUnownedOp("mets le calque en mode produit", domain: .photo), "layerBlend")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("corrige la perspective", domain: .photo), "perspective")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("baisse l'opacité du calque à 50 %", domain: .photo), "layerOpacity")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("applique une courbe en S", domain: .photo), "curves")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("auto levels", domain: .photo), "levels")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("désature les bleus", domain: .photo), "hsl", "a colour band as a group")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("des ombres un peu froides", domain: .photo), "colorGrade", "a tinted range")
        XCTAssertNil(OperationAbstention.namesUnownedOp("duplique le calque", domain: .photo))
        XCTAssertNil(OperationAbstention.namesUnownedOp("rends le ciel plus bleu", domain: .photo))
        XCTAssertNil(OperationAbstention.namesUnownedOp("corrige la perspective", domain: .video), "no such operation in video")
    }

    func testConfidentWrongAnswersAreCapped() {
        // The audit's examples: the grammar answered these at ≥ 0.85, wrongly.
        let photo = ["corrige la perspective", "mets le calque en mode produit", "désature les bleus", "ombres bleues et hautes lumières orangées",
                     "auto levels", "supprime les yeux rouges", "ajoute un flou de mouvement", "agrandis la toile vers la gauche"]
        for text in photo {
            let original = plan(text)
            let capped = OperationAbstention.capped(original, utterance: text, domain: .photo)
            XCTAssertLessThanOrEqual(capped.confidence, 0.5, text)
            XCTAssertTrue(capped.intents.allSatisfy { $0.confidence <= 0.5 }, text)
            XCTAssertEqual(capped.intents.map(\.action), original.intents.map(\.action), "the plan is kept, only trusted less")
        }
        XCTAssertEqual(reason("corrige la perspective"), .unownedOperation("perspective"))
        XCTAssertEqual(reason("supprime les yeux rouges"), .plannedOperation("yeux rouges"))
        XCTAssertEqual(reason("agrandis la toile vers la gauche"), .retrievalDisagrees("expandCanvas"))
        XCTAssertEqual(reason("ajoute un zoom lent", .video), .retrievalDisagrees("kenBurns"))
        XCTAssertEqual(reason("rends le ciel plus bleu", .video), .outsideDomain(.selectiveAdjust))
        XCTAssertEqual(reason("dessine une flèche", .pdf), .plannedOperation("fleche"))
    }

    func testRightAnswersStand() {
        for (text, domain) in [("plus lumineux", OpDomain.photo), ("recadre en carré", .photo), ("duplique le calque", .photo), ("lisse la peau", .photo),
                               ("floute l'arrière-plan", .photo), ("réduis le bruit de 40", .photo), ("accélère x2", .video),
                               ("enlève les silences", .video), ("supprime la page 3", .pdf), ("cherche le mot facture", .pdf)] {
            let original = plan(text, domain)
            XCTAssertEqual(OperationAbstention.capped(original, utterance: text, domain: domain), original, text)
        }
    }

    func testDialogueAndLowConfidenceAreLeftAlone() {
        let undo = EditPlan(utterance: "annule la courbe", intents: [EditIntent(action: .undo)], confidence: 1)
        XCTAssertEqual(OperationAbstention.capped(undo, utterance: undo.utterance, domain: .photo), undo)
        let low = EditPlan(utterance: "courbe en S", intents: [EditIntent(action: .adjust, parameter: .contrast)], confidence: 0.4)
        XCTAssertEqual(OperationAbstention.capped(low, utterance: low.utterance, domain: .photo), low)
        let question = EditPlan(utterance: "mets le calque en mode produit", intents: [EditIntent(action: .generativeFill)], confidence: 0.9,
                                clarification: "Lequel ?")
        XCTAssertEqual(OperationAbstention.capped(question, utterance: question.utterance, domain: .photo), question, "already asking")
        XCTAssertEqual(OperationAbstention.cappedConfidence, 0.5)
    }

    func testPlannedPhrasesMatchWholeWords() {
        XCTAssertNil(OperationAbstention.planned(TextFolding.tokens("cherche le mot facture"), domain: .pdf), "cherchable ≠ cherche")
        XCTAssertEqual(OperationAbstention.planned(TextFolding.tokens("rends le texte cherchable"), domain: .pdf), "cherchable")
        XCTAssertEqual(OperationAbstention.planned(TextFolding.tokens("ajoute un keyframe de zoom"), domain: .video), "keyframe")
        for (domain, phrases) in OperationAbstention.plannedPhrases {
            for phrase in phrases { XCTAssertEqual(TextFolding.tokens(phrase).joined(separator: " "), phrase, "\(domain): « \(phrase) » is folded") }
        }
    }
}
