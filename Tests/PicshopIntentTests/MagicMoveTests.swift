import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class MagicMoveTests: XCTestCase {
    let engine = RuleBasedIntentEngine()
    let dog = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3), confidence: 0.9)

    private func document() -> PhotoDocument {
        PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000)))
    }

    private func parse(_ text: String) -> EditIntent? { engine.parse(text, context: .photo).intents.first }

    func testGrammar() {
        let left = parse("déplace le chien vers la gauche")
        XCTAssertEqual(left?.action, .moveObject)
        XCTAssertEqual(left?.target?.label, "dog")
        XCTAssertEqual(left?.degrees ?? 0, 180, accuracy: 0.001)

        let up = parse("bouge la personne un peu plus haut")
        XCTAssertEqual(up?.action, .moveObject)
        XCTAssertEqual(up?.target?.label, "person")
        XCTAssertEqual(up?.degrees ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(up?.amount?.value ?? 0, 0.07, accuracy: 0.001)

        XCTAssertEqual(parse("move the car to the right")?.degrees ?? 99, 0, accuracy: 0.001)
        XCTAssertEqual(parse("déplace le bateau au centre")?.placement, .center)
        // Text moves with its own command, and removing still removes.
        XCTAssertNotEqual(parse("déplace le texte vers le haut")?.action, .moveObject)
        XCTAssertEqual(parse("efface le chien")?.action, .removeObject)
    }

    func testExecutorMovesAndKeepsItInFrame() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [dog]))
        var intent = EditIntent(action: .moveObject, target: ObjectTarget(label: "dog", originalPhrase: "le chien"))
        intent.degrees = 180
        intent.amount = .absolute(0.9)
        let (moved, result) = await executor.execute(intent, on: document(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        guard case .moveObject(_, let offset)? = moved.baseLayer?.edits.operations.last?.kind else { return XCTFail("expected a move") }
        // Asked for 0.9 to the left; there is only 0.4 of room.
        XCTAssertEqual(offset.x, -0.4, accuracy: 1e-9)
        XCTAssertEqual(offset.y, 0, accuracy: 1e-9)
    }

    func testCentring() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [dog]))
        var intent = EditIntent(action: .moveObject, target: ObjectTarget(label: "dog", originalPhrase: "le chien"))
        intent.placement = .center
        let (moved, _) = await executor.execute(intent, on: document(), context: .photo)
        guard case .moveObject(_, let offset)? = moved.baseLayer?.edits.operations.last?.kind else { return XCTFail("expected a move") }
        XCTAssertEqual(offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(offset.y, -0.15, accuracy: 1e-9)
    }
}

final class PortraitRetouchTests: XCTestCase {
    func testSkinTeethAndLips() async {
        let engine = RuleBasedIntentEngine()
        XCTAssertEqual(engine.parse("lisse la peau", context: .photo).intents.first?.target?.label, "skin")
        let teeth = engine.parse("blanchis les dents", context: .photo).intents.first
        XCTAssertEqual(teeth?.target?.label, "teeth")
        XCTAssertEqual(engine.parse("make the lips red", context: .photo).intents.first?.target?.label, "lips")

        let smile = ObjectCandidate(label: "teeth", boundingBox: PSRect(x: 0.45, y: 0.6, width: 0.1, height: 0.03), confidence: 0.9)
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [smile]))
        guard let intent = teeth else { return XCTFail("no intent") }
        let document = PhotoDocument(title: "t", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 3000, height: 4000)))
        let (whitened, result) = await executor.execute(intent, on: document, context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        guard case .selectiveAdjust(_, let adjustments)? = whitened.baseLayer?.edits.operations.last?.kind else { return XCTFail("expected a selective adjustment") }
        XCTAssertGreaterThan(adjustments[.brightness], 0)
        XCTAssertLessThan(adjustments[.saturation], 0)
    }
}

final class ClauseSplittingTests: XCTestCase {
    func testCommasSeparateCommandsButNotQuotesOrDecimals() {
        XCTAssertEqual(UtteranceSegmenter.clauses(of: "lisse la peau, éclaircis les yeux"), ["lisse la peau", "éclaircis les yeux"])
        XCTAssertEqual(UtteranceSegmenter.clauses(of: "ajoute le texte « Paris, je t'aime »").count, 1)
        XCTAssertEqual(UtteranceSegmenter.clauses(of: "coupe à 10,5 secondes").count, 1)
        let engine = RuleBasedIntentEngine()
        let plan = engine.parse("lisse la peau, éclaircis les yeux", context: .photo)
        XCTAssertEqual(plan.intents.map { $0.target?.label }, ["skin", "eyes"])
    }
}

final class TeleportTests: XCTestCase {
    func testPutMeSomewhereGeneratesTheBackground() {
        let engine = RuleBasedIntentEngine()
        let beach = engine.parse("mets-moi sur une plage au coucher du soleil", context: .photo).intents.first
        XCTAssertEqual(beach?.action, .generativeFill)
        XCTAssertEqual(beach?.target?.label, "background")
        XCTAssertEqual(beach?.text, "une plage au coucher du soleil")
        XCTAssertEqual(engine.parse("put us in Paris", context: .photo).intents.first?.target?.label, "background")
        // A look is not a place.
        XCTAssertNotEqual(engine.parse("mets moi en noir et blanc", context: .photo).intents.first?.target?.label, "background")
    }
}
