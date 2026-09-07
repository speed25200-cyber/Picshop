import XCTest
@testable import PicshopCore

final class GeometryTests: XCTestCase {
    func testRectIntersectionAndIOU() {
        let a = PSRect(x: 0, y: 0, width: 10, height: 10)
        let b = PSRect(x: 5, y: 5, width: 10, height: 10)
        let inter = a.intersection(b)
        XCTAssertEqual(inter, PSRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(a.iou(b), 25.0 / 175.0, accuracy: 1e-9)
        XCTAssertEqual(a.iou(PSRect(x: 20, y: 20, width: 1, height: 1)), 0)
    }

    func testNormalizedRoundTrip() {
        let size = PSSize(width: 4000, height: 3000)
        let pixel = PSRect(x: 400, y: 300, width: 2000, height: 1500)
        let unit = pixel.normalized(in: size)
        XCTAssertEqual(unit, PSRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        XCTAssertEqual(unit.denormalized(in: size), pixel)
    }

    func testClampToUnit() {
        let rect = PSRect(x: -0.2, y: 0.5, width: 0.6, height: 0.9)
        let clamped = rect.clampedToUnit()
        XCTAssertEqual(clamped.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(clamped.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(clamped.height, 0.5, accuracy: 1e-9)
    }

    func testSizeLimitedToLongestSide() {
        let size = PSSize(width: 4032, height: 3024)
        let limited = size.limited(toLongestSide: 1024)
        XCTAssertEqual(limited.width, 1024)
        XCTAssertEqual(limited.height, 768)
        XCTAssertEqual(PSSize(width: 100, height: 50).limited(toLongestSide: 1024), PSSize(width: 100, height: 50))
    }

    func testColorNames() {
        XCTAssertEqual(PSColor.named("Rouge"), .red)
        XCTAssertEqual(PSColor.named("bleu clair")?.luminance ?? 0 > PSColor.blue.luminance, true)
        XCTAssertEqual(PSColor.named("dark green")?.luminance ?? 1 < PSColor.green.luminance, true)
        XCTAssertNil(PSColor.named("banana"))
        XCTAssertEqual(PSColor(hex: "#FF0000"), PSColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(PSColor.red.hexString, "#FF3B30")
    }
}
