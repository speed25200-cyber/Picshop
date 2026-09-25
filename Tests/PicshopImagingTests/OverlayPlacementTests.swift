import XCTest
import PicshopCore
@testable import PicshopImaging

/// The compositor places a text layer where its element says (the text tool and hit-testing move the
/// element), every other overlay where its transform says. TextRasterizer draws text with UIKit, so a
/// macOS `swift test` renders no text layer at all; the placement rule is checked here instead, on Linux.
final class OverlayPlacementTests: XCTestCase {
    func testATextLayerSitsWhereItsElementIs() {
        var element = TextElement(text: "Merci")
        element.center = PSPoint(x: 0.2, y: 0.8)
        element.rotation = 12
        // An old project's text layer: identity transform, the element moved by the text tool.
        let layer = Layer(name: "Merci", content: .text(element))
        let placed = OverlayPlacement.placement(of: layer)
        XCTAssertEqual(placed.center, PSPoint(x: 0.2, y: 0.8), "not the canvas centre of the identity transform")
        XCTAssertEqual(placed.rotation, 12)
        // placeTextBehindSubject's title: element at y 0.32, drawn there.
        var document = PhotoDocument(title: "p", baseImage: MediaAsset(kind: .image, relativePath: "a.jpg", pixelSize: PSSize(width: 100, height: 100)))
        _ = document.placeTextBehindSubject("Paris", subjectMask: MaskReference(source: .subject, boundingBox: PSRect(x: 0.3, y: 0.3, width: 0.4, height: 0.6)),
                                            placeholder: "Titre")
        let title = document.layers.first { $0.textElement?.text == "Paris" }
        XCTAssertEqual(title.map { OverlayPlacement.placement(of: $0).center.y }, 0.32)
    }

    func testOtherOverlaysFollowTheirTransform() {
        let shape = Layer(name: "box", content: .shape(ShapeElement(kind: .rectangle)), transform: LayerTransform(center: PSPoint(x: 0.7, y: 0.3), rotation: 30))
        let placed = OverlayPlacement.placement(of: shape)
        XCTAssertEqual(placed.center, PSPoint(x: 0.7, y: 0.3))
        XCTAssertEqual(placed.rotation, 30)
    }
}
