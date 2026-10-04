import XCTest
@testable import PicshopCore

/// The marching ants' outline (W2, M3): marching squares at 128, then Douglas–Peucker.
final class SelectionContourTests: XCTestCase {
    /// A hard-edged disc (or ring) of pixels whose centres lie within the radii.
    private func ring(width: Int, height: Int, center: PSPoint, outer: Double, inner: Double = 0, value: UInt8 = 255) -> GrayRaster {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let d = PSPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).distance(to: center)
                if d <= outer, d >= inner { bytes[y * width + x] = value }
            }
        }
        return GrayRaster(width: width, height: height, bytes: bytes)
    }

    func testADiscGivesOneClosedPathWithinAPixel() {
        let center = PSPoint(x: 60, y: 45)
        let paths = SelectionContour.paths(ring(width: 120, height: 90, center: center, outer: 30))
        XCTAssertEqual(paths.count, 1)
        let path = paths[0]
        XCTAssertGreaterThanOrEqual(path.count, 8)
        // Closed: the last point is not the first again, and every edge, the closing one included, hugs the circle.
        XCTAssertNotEqual(path.first, path.last)
        for (index, point) in path.enumerated() {
            XCTAssertEqual(point.distance(to: center), 30, accuracy: 1, "\(point)")
            let next = path[(index + 1) % path.count]
            let middle = PSPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            XCTAssertEqual(middle.distance(to: center), 30, accuracy: 1.5, "edge \(index)")
        }
        XCTAssertEqual(abs(SelectionContour.signedArea(path)), Double.pi * 30 * 30, accuracy: Double.pi * 30 * 30 * 0.03)
    }

    func testHolesGiveInnerPathsTurningTheOtherWay() {
        let center = PSPoint(x: 50, y: 50)
        let paths = SelectionContour.paths(ring(width: 100, height: 100, center: center, outer: 35, inner: 15))
        XCTAssertEqual(paths.count, 2)
        // Larger outline first.
        let outer = paths[0], hole = paths[1]
        for point in outer { XCTAssertEqual(point.distance(to: center), 35, accuracy: 1) }
        for point in hole { XCTAssertEqual(point.distance(to: center), 15, accuracy: 1) }
        // Outlines and holes turn opposite ways, so an even-odd fill is the selection.
        XCTAssertLessThan(SelectionContour.signedArea(outer) * SelectionContour.signedArea(hole), 0)
    }

    func testSeparateBlobsGiveSeparatePaths() {
        var raster = ring(width: 120, height: 60, center: PSPoint(x: 30, y: 30), outer: 12)
        let other = ring(width: 120, height: 60, center: PSPoint(x: 90, y: 30), outer: 8)
        raster.bytes = zip(raster.bytes, other.bytes).map { max($0, $1) }
        let paths = SelectionContour.paths(raster)
        XCTAssertEqual(paths.count, 2)
        // Both turn the same way: two outlines, no hole.
        XCTAssertGreaterThan(SelectionContour.signedArea(paths[0]) * SelectionContour.signedArea(paths[1]), 0)
    }

    func testToleranceBoundsThePointCount() {
        let raster = ring(width: 100, height: 100, center: PSPoint(x: 50, y: 50), outer: 40)
        let raw = SelectionContour.paths(raster, tolerance: 0)[0].count
        let fine = SelectionContour.paths(raster, tolerance: 0.75)[0].count
        let coarse = SelectionContour.paths(raster, tolerance: 3)[0].count
        // A circle of radius R kept within t needs about π / √(2t / R) points; Douglas–Peucker on a pixel outline
        // stays within 2.5 times that.
        XCTAssertLessThanOrEqual(fine, Int(2.5 * Double.pi / (2 * 0.75 / 40).squareRoot()) + 4)
        XCTAssertLessThan(coarse, fine)
        XCTAssertGreaterThan(raw, fine * 3)
        // Every simplified point is one of the outline's own points.
        let all = Set(SelectionContour.paths(raster, tolerance: 0)[0].map { "\($0.x),\($0.y)" })
        for point in SelectionContour.paths(raster, tolerance: 0.75)[0] {
            XCTAssertTrue(all.contains("\(point.x),\(point.y)"))
        }
    }

    func testTheWholePictureIsOneRectangleAtItsBorder() {
        let raster = GrayRaster(width: 40, height: 30, bytes: [UInt8](repeating: 255, count: 1200))
        let paths = SelectionContour.paths(raster)
        XCTAssertEqual(paths.count, 1)
        let xs = paths[0].map(\.x), ys = paths[0].map(\.y)
        XCTAssertEqual(xs.min()!, 0, accuracy: 0.51)
        XCTAssertEqual(xs.max()!, 40, accuracy: 0.51)
        XCTAssertEqual(ys.min()!, 0, accuracy: 0.51)
        XCTAssertEqual(ys.max()!, 30, accuracy: 0.51)
        XCTAssertLessThanOrEqual(paths[0].count, 8)
    }

    func testTheThresholdAndTheSoftEdge() {
        // A soft ramp from 0 to 255 along x: the 128 outline is where the ramp crosses 127.5.
        let width = 64, height = 16
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = UInt8(min(255, x * 4)) } }
        let paths = SelectionContour.paths(GrayRaster(width: width, height: height, bytes: bytes))
        XCTAssertEqual(paths.count, 1)
        // 127.5 is between x = 31 (124) and x = 32 (128): pixel centres 31.5 and 32.5, crossing at 32.375.
        let left = paths[0].map(\.x).min()!
        XCTAssertEqual(left, 32.375, accuracy: 1e-9)
        // Below the threshold nothing is selected.
        XCTAssertTrue(SelectionContour.paths(GrayRaster(width: 4, height: 4, bytes: [UInt8](repeating: 127, count: 16))).isEmpty)
    }

    func testEmptyAndInvalidRastersGiveNothing() {
        XCTAssertTrue(SelectionContour.paths(GrayRaster(width: 10, height: 10, bytes: [UInt8](repeating: 0, count: 100))).isEmpty)
        XCTAssertTrue(SelectionContour.paths(GrayRaster(width: 0, height: 0, bytes: [])).isEmpty)
        XCTAssertTrue(SelectionContour.paths(GrayRaster(width: 10, height: 10, bytes: [1, 2, 3])).isEmpty)
    }

    func testNormalisedPathsAndADeterministicOrder() {
        let raster = ring(width: 80, height: 40, center: PSPoint(x: 40, y: 20), outer: 10)
        let paths = SelectionContour.paths(raster)
        XCTAssertEqual(paths, SelectionContour.paths(raster))
        let normalized = SelectionContour.normalized(paths, width: 80, height: 40)
        for (a, b) in zip(paths[0], normalized[0]) {
            XCTAssertEqual(b.x, a.x / 80, accuracy: 1e-12)
            XCTAssertEqual(b.y, a.y / 40, accuracy: 1e-12)
        }
        XCTAssertTrue(SelectionContour.normalized(paths, width: 0, height: 40).isEmpty)
    }

    func testAWorkingSizeSelectionTracesInReasonableTime() {
        // 768 × 576 (a quarter of the working size): orders of magnitude only (lesson 6).
        let raster = ring(width: 768, height: 576, center: PSPoint(x: 384, y: 288), outer: 250, inner: 80)
        let start = Date()
        let paths = SelectionContour.paths(raster)
        XCTAssertEqual(paths.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    /// A speckled selection (a subject with a ragged edge in foliage-like noise): the ants' outline stays within its
    /// point budget, drops the specks, and keeps the main outline.
    func testTheAntsOutlineIsBounded() {
        let width = 512, height = 384
        var state: UInt64 = 0x5EED
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        // Value noise on 3 px and 8 px cells.
        func grid(_ cell: Int) -> (columns: Int, values: [Double]) {
            let columns = width / cell + 2, rows = height / cell + 2
            return (columns, (0..<(columns * rows)).map { _ in random() })
        }
        let fine = grid(3), coarse = grid(8)
        func noise(_ x: Int, _ y: Int, _ g: (columns: Int, values: [Double]), _ cell: Int) -> Double {
            let fx = Double(x) / Double(cell), fy = Double(y) / Double(cell)
            let i = Int(fx), j = Int(fy), tx = fx - Double(i), ty = fy - Double(j)
            func v(_ a: Int, _ b: Int) -> Double { g.values[b * g.columns + a] }
            let top = v(i, j) * (1 - tx) + v(i + 1, j) * tx, bottom = v(i, j + 1) * (1 - tx) + v(i + 1, j + 1) * tx
            return top * (1 - ty) + bottom * ty
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let n = 0.6 * noise(x, y, fine, 3) + 0.4 * noise(x, y, coarse, 8)
                let dx = (Double(x) - 256) / 150, dy = (Double(y) - 192) / 120
                let inSubject = dx * dx + dy * dy < 0.8 + 0.4 * n
                bytes[y * width + x] = inSubject || n > 0.68 ? 255 : 0
            }
        }
        let raster = GrayRaster(width: width, height: height, bytes: bytes)
        let unbounded = SelectionContour.paths(raster)
        let bounded = SelectionContour.paths(raster, minimumExtent: 3, maximumPoints: 1_500)
        XCTAssertGreaterThan(unbounded.reduce(0) { $0 + $1.count }, 1_500, "the fixture is over the budget")
        XCTAssertFalse(bounded.isEmpty)
        XCTAssertLessThanOrEqual(bounded.reduce(0) { $0 + $1.count }, 1_500)
        XCTAssertLessThan(bounded.count, unbounded.count, "the specks are gone")
        func box(_ ring: [PSPoint]) -> Double {
            let xs = ring.map(\.x), ys = ring.map(\.y)
            return ((xs.max() ?? 0) - (xs.min() ?? 0)) * ((ys.max() ?? 0) - (ys.min() ?? 0))
        }
        let largest = unbounded.map(box).max() ?? 0
        XCTAssertGreaterThanOrEqual(box(bounded[0]), 0.5 * largest, "the main outline is kept")
        // A tight budget still keeps the main outline first.
        let tight = SelectionContour.paths(raster, minimumExtent: 3, maximumPoints: 40)
        XCTAssertLessThanOrEqual(tight.reduce(0) { $0 + $1.count }, 40)
        XCTAssertGreaterThanOrEqual(tight.first.map(box) ?? 0, 0.5 * largest)
        // An outline over the budget on its own is decimated, never dropped.
        let disc = SelectionContour.paths(raster, tolerance: 0, minimumExtent: 3, maximumPoints: 3)
        XCTAssertEqual(disc.count, 1)
        XCTAssertLessThanOrEqual(disc[0].count, 3)
    }
}
