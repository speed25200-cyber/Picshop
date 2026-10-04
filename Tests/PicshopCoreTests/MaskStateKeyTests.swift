import XCTest
@testable import PicshopCore

/// W3: an AI raster on a non-base image layer is made on that layer's own pixels (its content space), so it goes stale
/// with that layer's state, never with the photo's.
final class MaskStateKeyTests: XCTestCase {
    private typealias W3 = W3Documents

    func testALayersMaskStateIsItsOwn() throws {
        var document = W3.base(95, title: "mask state")
        let cup = W3.image(96, "Tasse")
        document.layers.append(cup)
        XCTAssertEqual(document.maskStateKey(on: nil), document.baseStateKey)
        XCTAssertEqual(document.maskStateKey(on: document.baseLayerID), document.baseStateKey)
        let key = document.maskStateKey(on: cup.id)
        XCTAssertNotEqual(key, document.baseStateKey)

        // The proxy is the layer alone, at its content size, under its own id.
        let proxy = try XCTUnwrap(document.contentSpaceDocument(of: cup.id))
        XCTAssertEqual(proxy.layers.count, 1)
        XCTAssertEqual(proxy.baseLayerID, cup.id)
        XCTAssertEqual(proxy.canvasSize, W3.cup.pixelSize)
        XCTAssertEqual(proxy.id, document.id)
        XCTAssertNil(document.contentSpaceDocument(of: W3.id(9999)))

        // A crop of the photo moves the canvas, not the layer's own pixels: its masks stay current.
        XCTAssertTrue(document.apply(.crop(PSRect(x: 0.1, y: 0, width: 0.8, height: 1)), to: document.baseLayerID))
        XCTAssertEqual(document.maskStateKey(on: cup.id), key)
        // A tonal edit on the layer changes nothing either; a geometric one on it does.
        XCTAssertTrue(document.apply(.adjust(.exposure, value: 0.3), to: cup.id))
        XCTAssertEqual(document.maskStateKey(on: cup.id), key)
        XCTAssertTrue(document.apply(.rotate(degrees: 90), to: cup.id))
        XCTAssertNotEqual(document.maskStateKey(on: cup.id), key)
    }
}
