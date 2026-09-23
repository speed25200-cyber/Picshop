import XCTest
@testable import PicshopCore
@testable import PicshopIntent

/// What a user reported: a photo left upside down with no way back, "supprime
/// toutes les données du tableau" not understood, and replies in English
/// without the accents they typed.
final class UnderstandingFixesTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func document(_ kinds: [EditOperation.Kind] = []) -> PhotoDocument {
        var document = PhotoDocument(title: "t", baseImage: MediaAsset(kind: .image, relativePath: "a.jpg", pixelSize: PSSize(width: 1709, height: 2048)))
        for kind in kinds { document.apply(kind) }
        return document
    }

    // MARK: - Orientation

    func testMirrorThenHalfTurnIsAVerticalFlip() {
        let stack = document([.flip(.horizontal), .rotate(degrees: 180)]).baseLayer!.edits
        XCTAssertTrue(stack.netOrientation.isVerticallyFlipped)
        XCTAssertTrue(document([.flip(.vertical)]).baseOrientation.isVerticallyFlipped)
        XCTAssertTrue(document([.flip(.vertical), .flip(.vertical)]).baseOrientation.isUpright)
        XCTAssertTrue(document([.rotate(degrees: 90), .rotate(degrees: -90)]).baseOrientation.isUpright)
        XCTAssertTrue(document([.rotate(degrees: 12), .straighten(degrees: 3)]).baseOrientation.isUpright, "tilts are deliberate")
    }

    func testResetOrientationBringsEveryCombinationUpright() {
        let steps: [EditOperation.Kind] = [.flip(.horizontal), .flip(.vertical), .rotate(degrees: 90), .rotate(degrees: 180), .rotate(degrees: -90), .rotate(degrees: 270)]
        for first in steps {
            for second in steps {
                for third in steps {
                    let cropped = document([.crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))])
                    var doc = document([.crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)), first, second, third])
                    let before = doc.baseLayer!.edits.operations.count
                    let changed = doc.resetOrientation()
                    XCTAssertTrue(doc.baseOrientation.isUpright, "\(first) \(second) \(third)")
                    XCTAssertEqual(changed, doc.baseLayer!.edits.operations.count > before)
                    XCTAssertLessThanOrEqual(doc.baseLayer!.edits.operations.count - before, 2)
                    XCTAssertEqual(doc.baseLayer!.edits.resolvedCrop, PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), "earlier edits stay")
                    XCTAssertEqual(doc.canvasSize, cropped.canvasSize, "upright again means the frame is the cropped photo's own shape")
                }
            }
        }
    }

    func testRestoredToImportDropsEditsFromEarlierSessions() {
        let doc = document([.flip(.horizontal), .rotate(degrees: 90), .crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let restored = doc.restoredToImport()
        XCTAssertTrue(restored.baseLayer!.edits.isEmpty)
        XCTAssertEqual(restored.canvasSize, PSSize(width: 1709, height: 2048))
    }

    func testUpsideDownComplaintPutsItRightWayUp() {
        for phrase in ["c'est à l'envers", "l'image est à l'envers", "la photo s'affiche à l'envers", "remets-la à l'endroit", "mets-la dans le bon sens",
                       "it's upside down", "put it the right way up", "annule le miroir"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.action, .resetOrientation, phrase)
        }
        let turn = engine.parse("mets-la à l'envers", context: .photo).intents.first
        XCTAssertEqual(turn?.action, .rotate)
        XCTAssertEqual(turn?.degrees, 180)
    }

    func testInverseAloneIsNotAMirror() {
        XCTAssertNotEqual(engine.parse("inverse les couleurs", context: .photo).intents.first?.action, .flip)
        XCTAssertEqual(engine.parse("inverse l'image horizontalement", context: .photo).intents.first?.flipAxis, .horizontal)
        XCTAssertEqual(engine.parse("retourne de haut en bas", context: .photo).intents.first?.flipAxis, .vertical)
        XCTAssertEqual(engine.parse("mirror it", context: .photo).intents.first?.flipAxis, .horizontal)
        XCTAssertEqual(Replies.reply(for: EditIntent(action: .flip, flipAxis: .horizontal), language: .french), "Image retournée en miroir.")
    }

    func testResetExecutorUndoesTheFlipOrTurnsAnUpsideDownShot() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        let (fixed, result) = await executor.execute(EditIntent(action: .resetOrientation), on: document([.flip(.horizontal), .rotate(degrees: 180)]), context: .photo)
        XCTAssertTrue(fixed.baseOrientation.isUpright)
        guard case .applied = result.outcome else { return XCTFail("expected an edit") }
        let (turned, _) = await executor.execute(EditIntent(action: .resetOrientation), on: document(), context: .photo)
        XCTAssertEqual(turned.baseLayer?.edits.operations.last?.kind, .rotate(degrees: 180), "a photo shot upside down is turned over")
    }

    // MARK: - Words in pictures

    func testTableDataIsText() {
        let plan = engine.parse("Supprime toutes les données du tableau.", context: .photo)
        let intent = plan.intents.first
        XCTAssertEqual(intent?.action, .removeObject)
        XCTAssertEqual(intent?.target?.label, "text")
        XCTAssertEqual(intent?.target?.matchesAll, true)
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, "understood at once, no model needed")
        XCTAssertEqual(intent?.target?.originalPhrase, "toutes les données du tableau")
        XCTAssertEqual(plan.reply, "J'efface toutes les données du tableau.")
        for phrase in ["efface les chiffres", "enlève les dates", "remove all the numbers", "efface les légendes", "supprime les valeurs du tableau", "erase the data"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.target?.label, "text", phrase)
        }
        XCTAssertEqual(engine.parse("remove the cell phone", context: .photo).intents.first?.target?.label, "phone")
        XCTAssertNotEqual(engine.parse("supprime les données de localisation", context: .photo).intents.first?.target?.label, "text")
    }

    func testRepliesKeepTheWordsAsSaid() {
        XCTAssertEqual(engine.parse("efface l'arbre", context: .photo).reply, "J'efface l'arbre.")
        XCTAssertEqual(engine.parse("enlève le vélo à gauche", context: .photo).intents.first?.target?.originalPhrase, "le vélo à gauche")
    }

    func testUnknownThingsGetTheModelsFullAttention() async {
        struct ThoughtfulEngine: IntentEngine {
            let kind: IntentEngineKind = .proLocal
            func isAvailable() async -> Bool { true }
            func plan(_ utterance: String, context: IntentContext, hint: EditPlan?) async throws -> EditPlan {
                try await Task.sleep(for: .milliseconds(300))
                return EditPlan(utterance: utterance, intents: [EditIntent(action: .removeObject, target: ObjectTarget(label: "text"))], confidence: 0.9, engine: .proLocal)
            }
        }
        let router = HybridIntentRouter(preferredEngine: .proLocal, configuration: .init(llmTimeout: .seconds(3), improveTimeout: .milliseconds(50)))
        await router.register(ThoughtfulEngine())
        let plan = await router.plan("efface le zinzin", context: .photo)
        XCTAssertEqual(plan.engine, .proLocal, "a noun the grammar does not know is worth waiting for")
    }
}
