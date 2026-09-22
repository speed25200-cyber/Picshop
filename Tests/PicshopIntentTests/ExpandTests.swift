import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class ExpandTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    func makeDocument() -> PhotoDocument {
        PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000)))
    }

    func testPhrasesParseAsExpand() {
        for phrase in ["étends l'image", "agrandis le cadre", "élargis le cadre", "expand the photo", "outpaint this", "uncrop it", "invente les bords"] {
            XCTAssertEqual(engine.parse(phrase, context: .photo).intents.first?.action, .expandCanvas, phrase)
        }
    }

    func testUpscaleStaysUpscale() {
        XCTAssertEqual(engine.parse("agrandis x2", context: .photo).intents.first?.action, .upscale)
        XCTAssertEqual(engine.parse("upscale 2x", context: .photo).intents.first?.action, .upscale)
    }

    func testAspectAndAmount() {
        let wide = engine.parse("étends l'image en 16:9", context: .photo).intents.first
        XCTAssertEqual(wide?.action, .expandCanvas)
        XCTAssertEqual(wide?.aspect, .ratio16x9)
        let percent = engine.parse("expand the image by 50 percent", context: .photo).intents.first
        XCTAssertEqual(percent?.amount?.value ?? 0, 1.5, accuracy: 0.001)
    }

    func testExpandToWideGrowsTheCanvasSideways() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        var intent = EditIntent(action: .expandCanvas)
        intent.aspect = .ratio16x9
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        guard case .expand(let placement)? = document.baseLayer?.edits.operations.last?.kind else {
            return XCTFail("expected an expand operation")
        }
        XCTAssertEqual(placement.height, 1, accuracy: 0.001)
        XCTAssertEqual(placement.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(document.canvasSize.height, 3000)
        XCTAssertEqual(document.canvasSize.aspectRatio, 16.0 / 9.0, accuracy: 0.01)
    }

    func testDefaultExpandAddsRoomAllRound() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        let (document, _) = await executor.execute(EditIntent(action: .expandCanvas), on: makeDocument(), context: .photo)
        XCTAssertEqual(document.canvasSize.width, 5000)
        XCTAssertEqual(document.canvasSize.height, 3750)
    }

    func testSameShapeIsRefused() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        var intent = EditIntent(action: .expandCanvas)
        intent.aspect = .ratio4x3
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(document.canvasSize.width, 4000)
    }

    func testVideoRejectsExpand() {
        XCTAssertNotEqual(engine.parse("expand the image", context: IntentContext(mode: .video, clipCount: 1, playheadSeconds: 0, timelineDuration: 5)).intents.first?.action, .expandCanvas)
    }
}
