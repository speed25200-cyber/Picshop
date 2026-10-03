import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// IntentAction.operation is a seam, never a word: no model is told about it, the validator
/// refuses it as an action name, and the photo executor answers an operation it has no handler
/// for with today's unsupported outcome.
final class OperationSeamTests: XCTestCase {
    private func document() -> PhotoDocument {
        PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
    }

    func testNoModelIsToldTheWord() {
        for mode in [EditorMode.photo, .video, .pdf] {
            XCTAssertFalse(LiveToolSchema.allowedActions(for: mode).contains(.operation), "\(mode)")
        }
        XCTAssertTrue(LiveToolSchema.excluded.contains(.operation))
        XCTAssertFalse(IntentPrompt.actionList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("operation"))
    }

    func testTheValidatorRefusesIt() {
        let validator = ToolInputValidator(mode: .photo)
        let raw = #"{"steps":[{"action":"operation"}]}"#
        guard case .failure = validator.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: raw), context: .photo) else {
            return XCTFail("operation must not validate")
        }
    }

    func testThePhotoExecutorAnswersUnknownOperationsUnsupported() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .french)
        let intent = EditIntent(action: .operation, operation: OperationCall("warpDrive", args: ["speed": .number(9)]))
        let (document, result) = await executor.execute(intent, on: document(), context: .photo)
        XCTAssertEqual(result.reason, .unsupported)
        XCTAssertTrue(document.baseLayer?.edits.isEmpty ?? false)
        let (_, bare) = await PhotoCommandExecutor(services: FakePhotoServices(candidates: []), language: .english)
            .execute(EditIntent(action: .operation), on: self.document(), context: .photo)
        XCTAssertEqual(bare.reason, .unsupported)
        XCTAssertNil(PhotoOperationHandlers.table["warpDrive"])
    }

    func testServicesHaveNoHistogramByDefault() async {
        let histogram = await FakePhotoServices(candidates: []).histogram(of: document())
        XCTAssertNil(histogram)
    }

    func testEditorModesMapToDomains() {
        XCTAssertEqual(EditorMode.photo.opDomain, .photo)
        XCTAssertEqual(EditorMode.video.opDomain, .video)
        XCTAssertEqual(EditorMode.pdf.opDomain, .pdf)
        // The catalog is filled in: the machinery the seam declared now finds things (the lanes test it in detail).
        let query = OperationQuery(text: "courbe en S légère", domain: .photo, language: .french, hints: [.subject])
        XCTAssertEqual(OperationIndex.shared.retrieve(query, limit: 8).first?.id, "curves")
        XCTAssertEqual(OperationIndex.shared.top(query)?.id, "curves")
        XCTAssertEqual(OperationAbstention.namesUnownedOp("mets le calque en mode produit", domain: .photo), "layerBlend")
        XCTAssertEqual(OperationArguments.json(OperationCall("curves", args: ["amount": .number(30)])), ["action": "curves", "amount": 30])
    }
}
