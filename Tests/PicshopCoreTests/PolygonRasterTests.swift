import XCTest
@testable import PicshopCore

final class PolygonRasterTests: XCTestCase {
    func testSquareFillsItsArea() {
        let square = [PSPoint(x: 0.25, y: 0.25), PSPoint(x: 0.75, y: 0.25), PSPoint(x: 0.75, y: 0.75), PSPoint(x: 0.25, y: 0.75)]
        let bytes = PolygonRaster.fill([square], width: 100, height: 100)
        XCTAssertEqual(bytes.filter { $0 == 255 }.count, 2500)
        XCTAssertEqual(bytes[50 * 100 + 50], 255)
        XCTAssertEqual(bytes[10 * 100 + 10], 0)
    }

    func testTwoPolygonsAndHoles() {
        let outer = [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.9, y: 0.1), PSPoint(x: 0.9, y: 0.9), PSPoint(x: 0.1, y: 0.9)]
        let inner = [PSPoint(x: 0.4, y: 0.4), PSPoint(x: 0.6, y: 0.4), PSPoint(x: 0.6, y: 0.6), PSPoint(x: 0.4, y: 0.6)]
        let bytes = PolygonRaster.fill([outer, inner], width: 50, height: 50)
        XCTAssertEqual(bytes[25 * 50 + 25], 0, "even-odd leaves the inner square open")
        XCTAssertEqual(bytes[10 * 50 + 10], 255)
    }

    func testEllipseArea() {
        let bytes = PolygonRaster.fill([PolygonRaster.ellipse(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.4, radiusY: 0.2, segments: 96)], width: 200, height: 200)
        let area = Double(bytes.filter { $0 == 255 }.count)
        XCTAssertEqual(area, Double.pi * 80 * 40, accuracy: Double.pi * 80 * 40 * 0.03)
    }
}
