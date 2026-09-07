import XCTest
@testable import PicshopCore

final class PDFTests: XCTestCase {
    func testRotationRoundTrip() {
        let point = PSPoint(x: 0.2, y: 0.7)
        for rotation in [0, 90, 180, 270, -90, 450] {
            let displayed = PDFGeometry.displayedPoint(fromBase: point, rotation: rotation)
            let back = PDFGeometry.basePoint(fromDisplayed: displayed, rotation: rotation)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9, "rotation \(rotation)")
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9, "rotation \(rotation)")
        }
        // Base top-left corner shows at the top-right after a 90° clockwise rotation.
        XCTAssertEqual(PDFGeometry.displayedPoint(fromBase: PSPoint(x: 0, y: 0), rotation: 90), PSPoint(x: 1, y: 0))
    }

    func testPagePointsConversion() {
        let size = PSSize(width: 600, height: 800)
        let base = PSRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25)
        let points = PDFGeometry.pagePoints(fromBase: base, size: size)
        XCTAssertEqual(points.minX, 60, accuracy: 1e-9)
        XCTAssertEqual(points.minY, 520, accuracy: 1e-9)
        let back = PDFGeometry.baseNormalized(fromPagePoints: points, size: size)
        XCTAssertEqual(back.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(back.height, 0.25, accuracy: 1e-9)
    }

    func testDocumentPageOperations() {
        let asset = MediaAsset(kind: .image, relativePath: "media/doc.pdf", pixelSize: .zero)
        var document = PDFDocumentModel(title: "Doc", sourceAsset: asset, pageSizes: Array(repeating: PSSize(width: 595, height: 842), count: 4))
        XCTAssertEqual(document.resolvePageIndex(nil), 0)
        XCTAssertEqual(document.resolvePageIndex(-1), 3)
        XCTAssertNil(document.resolvePageIndex(9))
        document.movePage(from: 3, to: 0)
        if case .original(let index) = document.pages[0].source { XCTAssertEqual(index, 3) } else { XCTFail() }
        document.rotatePage(at: 0, by: -90)
        XCTAssertEqual(document.pages[0].rotation, 270)
        XCTAssertEqual(document.pages[0].displaySize, PSSize(width: 842, height: 595))
        document.duplicatePage(at: 0)
        XCTAssertEqual(document.pageCount, 5)
        document.deletePage(at: 4)
        XCTAssertEqual(document.pageCount, 4)
        document.addMarkup(PDFMarkup(kind: .highlight(rects: [PSRect(x: 0.1, y: 0.1, width: 0.3, height: 0.02)], color: .yellow)), toPageAt: 1)
        XCTAssertEqual(document.allMarkups.count, 1)
        document.removeMarkup(id: document.pages[1].markups[0].id)
        XCTAssertTrue(document.allMarkups.isEmpty)
    }
}
