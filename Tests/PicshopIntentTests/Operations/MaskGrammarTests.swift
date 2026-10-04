import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The grammar's W2 rules (§8.4): anchored patterns at 0.9, and the phrases they must leave alone.
final class MaskGrammarTests: XCTestCase {
    private let engine = RuleBasedIntentEngine()

    private func call(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> OperationCall? {
        let plan = engine.parse(text, context: IntentContext(mode: .photo))
        guard plan.intents.count == 1, let call = plan.intents.first?.operation, call.source == .grammar else { return nil }
        XCTAssertGreaterThanOrEqual(plan.intents[0].confidence, 0.9, text, file: file, line: line)
        return call
    }

    func testToneOnARegion() throws {
        let cases: [(String, String, String, Double)] = [
            ("assombris le bas", "bottom", "exposure", -20), ("éclaircis un peu le haut", "top", "exposure", 10),
            ("assombris beaucoup les bords", "edges", "exposure", -40), ("réchauffe le sujet", "subject", "temperature", 20),
            ("refroidis l'arrière-plan", "background", "temperature", -20), ("désature le fond", "background", "saturation", -20),
            ("plus de contraste sur le sujet", "subject", "contrast", 20), ("darken the bottom", "bottom", "exposure", -20),
            ("brighten the left side", "left", "exposure", 20), ("more contrast on the subject", "subject", "contrast", 20),
            ("assombri le ba", "bottom", "exposure", -20), ("éclaircis le centre stp", "center", "exposure", 20),
        ]
        for (text, region, parameter, amount) in cases {
            let call = try XCTUnwrap(self.call(text), text)
            XCTAssertEqual(call.id, "maskAdjust", text)
            XCTAssertEqual(call.args["where"], .string(region), text)
            XCTAssertEqual(call.args["parameter"], .string(parameter), text)
            XCTAssertEqual(call.args["amount"], .number(amount), text)
        }
    }

    func testTheSkyStaysOnSelectiveAdjust() {
        let plan = engine.parse("éclaircis le ciel", context: IntentContext(mode: .photo))
        XCTAssertEqual(plan.intents.first?.action, .selectiveAdjust)
        XCTAssertNil(plan.intents.first?.operation)
    }

    func testSelect() throws {
        let cases: [(String, [String: OpValue])] = [
            ("sélectionne le sujet", ["what": "subject"]), ("sélectionne le ciel", ["what": "sky"]), ("sélectionne l'arrière-plan", ["what": "background"]),
            ("sélectionne les personnes", ["what": "people"]), ("sélectionne tout", ["what": "all"]), ("select the subject", ["what": "subject"]),
            ("sélectionne la tasse bleue", ["what": "object", "target": "cup", "attributes": .list(["blue"])]),
            ("select the blue cup", ["what": "object", "target": "cup", "attributes": .list(["blue"])]),
            ("sélectionne la deuxième personne", ["what": "person", "index": 2]),
            ("sélectionne cette couleur", ["what": "color"]), ("sélectionne le rouge", ["what": "color", "color": "red"]),
            ("ajoute le ciel à la sélection", ["what": "sky", "mode": "add"]), ("retire le sujet de la sélection", ["what": "subject", "mode": "subtract"]),
        ]
        for (text, args) in cases {
            let call = try XCTUnwrap(self.call(text), text)
            XCTAssertEqual(call.id, "select", text)
            for (key, value) in args { XCTAssertEqual(call.args[key], value, "\(text) \(key)") }
        }
    }

    func testAnUnknownNounGoesToTheModel() {
        let plan = engine.parse("sélectionne la tace bleue", context: IntentContext(mode: .photo))
        XCTAssertLessThan(plan.confidence, 0.85, "a speech slip is the model's to read")
    }

    func testSelectionModifyAndApply() throws {
        let cases: [(String, String, [String: OpValue])] = [
            ("inverse la sélection", "selectionModify", ["invert": true]), ("désélectionne", "selectionModify", ["deselect": true]),
            ("désélectionne tout", "selectionModify", ["deselect": true]), ("agrandis la sélection de 20 pixels", "selectionModify", ["grow": 20]),
            ("réduis la sélection", "selectionModify", ["shrink": 10]), ("adoucis la sélection", "selectionModify", ["feather": 10]),
            ("invert the selection", "selectionModify", ["invert": true]),
            ("efface la sélection", "selectionApply", ["use": "erase"]), ("floute la sélection", "selectionApply", ["use": "blur", "amount": 60]),
            ("remplis la sélection de blanc", "selectionApply", ["use": "fill", "color": "white"]),
            ("recolore la sélection en vert", "selectionApply", ["use": "recolor", "color": "green"]),
            ("fill the selection with black", "selectionApply", ["use": "fill", "color": "black"]),
        ]
        for (text, id, args) in cases {
            let call = try XCTUnwrap(self.call(text), text)
            XCTAssertEqual(call.id.raw, id, text)
            for (key, value) in args { XCTAssertEqual(call.args[key], value, "\(text) \(key)") }
        }
    }

    /// The phrases a looser rule would steal keep their owners (§8.4, risk "grammar regressions").
    func testOtherRulesKeepTheirPhrases() {
        let owners: [(String, IntentAction)] = [
            ("sélectionne le calque 2", .selectLayer), ("supprime le fond", .removeBackground), ("floute le fond", .blurBackground),
            ("éclaircis", .adjust), ("assombris la photo", .adjust), ("enlève le chien", .removeObject),
        ]
        for (text, action) in owners {
            let plan = engine.parse(text, context: IntentContext(mode: .photo))
            XCTAssertEqual(plan.intents.first?.action, action, text)
            XCTAssertNil(plan.intents.first?.operation, text)
        }
        // Anchored: words after the region that are not a qualifier send the clause on.
        XCTAssertNil(call("assombris le bas de la robe rouge"))
        XCTAssertNil(call("sélectionne le calque du texte"))
        // Video and PDF never read these rules.
        let video = engine.parse("sélectionne le sujet", context: IntentContext(mode: .video))
        XCTAssertFalse(video.intents.contains { $0.operation?.id == "select" })
    }

    func testGestureOnlyPhrasesOpenTheirTool() throws {
        let cases: [(String, String)] = [("peins un masque", "masks.brush.paint"), ("lasso", "select.mode.lasso"), ("sélection rapide", "select.mode.quick"),
                                         ("pipette", "masks.colorRange.sample.add"), ("pinceau de masque", "masks.brush.paint")]
        for (text, control) in cases {
            let call = try XCTUnwrap(self.call(text), text)
            XCTAssertEqual(call.args["openTool"], .string(control), text)
        }
    }
}
