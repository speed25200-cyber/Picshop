import XCTest
@testable import PicshopCore

/// Brush strokes into masks: hardness shapes the edge, and a stroke list drawn once is never drawn again.
final class BrushRasterTests: XCTestCase {
    private let side = 200

    /// One dot of radius 40 px at the centre of a 200 × 200 mask.
    private func dot(hardness: Double, mode: BrushStroke.Mode = .add) -> BrushStroke {
        BrushStroke(points: [PSPoint(x: 0.5, y: 0.5)], radius: 0.2, hardness: hardness, mode: mode)
    }

    /// The mask value along the row through the centre, at `x` pixels from it.
    private func profile(_ bytes: [UInt8], at offset: Int) -> UInt8 {
        bytes[(side / 2) * side + side / 2 + offset]
    }

    /// What the brush gives the pixel `offset` columns right of the centre (pixel centres sit at +0.5).
    private func expected(at offset: Int, hardness: Double) -> Int {
        let d = ((Double(offset) + 0.5) * (Double(offset) + 0.5) + 0.25).squareRoot()
        return Int((BrushRaster.coverage(distance: d, radius: 40, hardness: hardness) * 255).rounded())
    }

    func testHardnessShapesTheEdge() {
        var hard = [UInt8](repeating: 0, count: side * side)
        BrushRaster.draw(dot(hardness: 1), width: side, height: side, into: &hard)
        var soft = [UInt8](repeating: 0, count: side * side)
        BrushRaster.draw(dot(hardness: 0), width: side, height: side, into: &soft)
        var half = [UInt8](repeating: 0, count: side * side)
        BrushRaster.draw(dot(hardness: 0.5), width: side, height: side, into: &half)
        // Hard: full to the radius, a one-pixel anti-aliased edge, nothing past it.
        XCTAssertEqual(profile(hard, at: 0), 255)
        XCTAssertEqual(profile(hard, at: 38), 255)
        XCTAssertEqual(profile(hard, at: 41), 0)
        // Soft: full only at the centre, falling smoothly to nothing at the radius.
        XCTAssertGreaterThanOrEqual(profile(soft, at: 0), 252)
        XCTAssertLessThan(profile(soft, at: 30), profile(soft, at: 10))
        XCTAssertEqual(profile(soft, at: 41), 0)
        for offset in 1..<45 { XCTAssertLessThanOrEqual(profile(soft, at: offset), profile(soft, at: offset - 1)) }
        // Hardness 0.5: full to 20 px, then the falloff.
        XCTAssertEqual(profile(half, at: 19), 255)
        XCTAssertLessThan(profile(half, at: 30), 200)
        XCTAssertGreaterThan(profile(half, at: 30), 60)
        // Every pixel of the profile is the smoothstep of its distance.
        for offset in 0..<45 {
            XCTAssertEqual(Int(profile(soft, at: offset)), expected(at: offset, hardness: 0), accuracy: 1, "soft at \(offset)")
            XCTAssertEqual(Int(profile(half, at: offset)), expected(at: offset, hardness: 0.5), accuracy: 1, "half at \(offset)")
            XCTAssertEqual(Int(profile(hard, at: offset)), expected(at: offset, hardness: 1), accuracy: 1, "hard at \(offset)")
        }
        XCTAssertEqual(BrushRaster.coverage(distance: 20, radius: 40, hardness: 0), 0.5, accuracy: 1e-12, "halfway out, one half")
        XCTAssertEqual(BrushRaster.coverage(distance: 30, radius: 40, hardness: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(BrushRaster.coverage(distance: 40.5, radius: 40, hardness: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(BrushRaster.coverage(distance: 40, radius: 40, hardness: 1), 0.5, accuracy: 1e-12)
    }

    func testSubtractLowersAndAddNeverLowers() {
        var bytes = [UInt8](repeating: 0, count: side * side)
        BrushRaster.draw(dot(hardness: 1), width: side, height: side, into: &bytes)
        let eraser = BrushStroke(points: [PSPoint(x: 0.5, y: 0.5)], radius: 0.05, hardness: 1, mode: .subtract)
        BrushRaster.draw(eraser, width: side, height: side, into: &bytes)
        XCTAssertEqual(profile(bytes, at: 0), 0, "a hole in the middle")
        XCTAssertEqual(profile(bytes, at: 30), 255, "the ring stays")
        // A soft add over a full area leaves it full.
        BrushRaster.draw(dot(hardness: 0), width: side, height: side, into: &bytes)
        XCTAssertEqual(profile(bytes, at: 30), 255)
    }

    func testAStrokeCoversItsPathWithRoundCaps() {
        var bytes = [UInt8](repeating: 0, count: side * side)
        let line = BrushStroke(points: [PSPoint(x: 0.2, y: 0.5), PSPoint(x: 0.8, y: 0.5)], radius: 0.02, hardness: 1)
        BrushRaster.draw(line, width: side, height: side, into: &bytes)
        let row = (side / 2) * side
        XCTAssertEqual(bytes[row + 100], 255)
        XCTAssertEqual(bytes[row + 40], 255)
        XCTAssertEqual(bytes[row + 37], 255, "round cap past the end point")
        XCTAssertEqual(bytes[row + 30], 0)
        XCTAssertEqual(bytes[(side / 2 - 10) * side + 100], 0, "4 px radius: 10 rows up is clear")
        // Off-canvas points and empty strokes are harmless.
        BrushRaster.draw(BrushStroke(points: [PSPoint(x: -1, y: 3)], radius: 0.1), width: side, height: side, into: &bytes)
        BrushRaster.draw(BrushStroke(points: [], radius: 0.1), width: side, height: side, into: &bytes)
        var tiny = [UInt8](repeating: 0, count: 3)
        BrushRaster.draw(line, width: side, height: side, into: &tiny)
        XCTAssertEqual(tiny, [0, 0, 0])
    }

    private func strokes(_ count: Int) -> [BrushStroke] {
        (0..<count).map { index in
            let y = 0.1 + 0.8 * Double(index) / Double(max(1, count))
            let digits = String(index)
            let id = UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
            return BrushStroke(id: id,
                               points: [PSPoint(x: 0.1, y: y), PSPoint(x: 0.9, y: y)], radius: 0.01, hardness: 0.8)
        }
    }

    func testACachedListIsNeverDrawnAgain() {
        var cache = StrokeRasterCache()
        let list = strokes(50)
        let first = cache.mask(for: list, width: 160, height: 120)
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(cache.strokesDrawn, 50)
        let second = cache.mask(for: list, width: 160, height: 120)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(cache.strokesDrawn, 50, "the second render draws nothing")
        XCTAssertEqual(second.bytes, first.bytes)
        XCTAssertEqual(second.key, first.key)
        // Another size is another mask.
        _ = cache.mask(for: list, width: 80, height: 60)
        XCTAssertEqual(cache.strokesDrawn, 100)
        XCTAssertEqual(cache.count, 2)
    }

    func testALongerListDrawsOnlyItsNewStrokes() {
        var cache = StrokeRasterCache()
        let all = strokes(12)
        _ = cache.mask(for: Array(all.prefix(10)), width: 160, height: 120)
        let extended = cache.mask(for: all, width: 160, height: 120)
        XCTAssertEqual(cache.strokesDrawn, 12, "10, then the 2 new ones")
        // Same pixels as drawing them all at once.
        var direct = [UInt8](repeating: 0, count: 160 * 120)
        BrushRaster.draw(all, width: 160, height: 120, into: &direct)
        XCTAssertEqual(extended.bytes, direct)
        // A list that is not a continuation is drawn from scratch.
        _ = cache.mask(for: Array(all.suffix(3)), width: 160, height: 120)
        XCTAssertEqual(cache.strokesDrawn, 15)
    }

    func testTheCacheStaysUnderItsByteLimit() {
        var cache = StrokeRasterCache(byteLimit: 100 * 100 * 3)
        for count in 1...6 { _ = cache.mask(for: strokes(count * 2), width: 100, height: 100) }
        XCTAssertLessThanOrEqual(cache.count, 3)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    /// A gesture as the brush draws it: one 2-point segment per frame, then the polyline it is merged into.
    private func gesture(_ index: Int, points: Int) -> (segments: [BrushStroke], polyline: BrushStroke) {
        let y = 0.1 + 0.8 * Double(index % 40) / 40
        let spine = (0..<points).map { PSPoint(x: 0.05 + 0.9 * Double($0) / Double(max(1, points - 1)), y: y) }
        let segments = (1..<points).map { BrushStroke(points: [spine[$0 - 1], spine[$0]], radius: 0.01, hardness: 0.8) }
        return (segments, BrushStroke(points: spine, radius: 0.01, hardness: 0.8))
    }

    /// A drag's per-frame rasters never push out the settled-size raster the stroke's settle extends.
    func testADragsFramesGoBeforeTheSettledRaster() {
        var cache = StrokeRasterCache(byteLimit: 32 * 1_048_576)
        let committed = (0..<3).map { gesture($0, points: 8).polyline }
        _ = cache.mask(for: committed, width: 2048, height: 1536)
        let drag = gesture(3, points: 61)
        for count in 1...drag.segments.count {
            _ = cache.mask(for: committed + drag.segments.prefix(count), width: 1280, height: 960)
        }
        let before = cache.strokesDrawn
        _ = cache.mask(for: committed + [drag.polyline], width: 2048, height: 1536)
        XCTAssertEqual(cache.strokesDrawn - before, 1, "the settle draws only the new stroke")
    }

    /// The merged polyline keeps the raster its segments drew: the next gesture draws one stroke, not the history.
    func testACoalescedGestureKeepsItsRaster() {
        var cache = StrokeRasterCache()
        let committed = (0..<10).map { gesture($0, points: 8).polyline }
        _ = cache.mask(for: committed, width: 320, height: 240)
        let drag = gesture(10, points: 12)
        for count in 1...drag.segments.count {
            _ = cache.mask(for: committed + drag.segments.prefix(count), width: 320, height: 240)
        }
        cache.alias(committed + drag.segments, as: committed + [drag.polyline])
        let next = gesture(11, points: 2).segments[0]
        let before = cache.strokesDrawn
        let drawn = cache.mask(for: committed + [drag.polyline, next], width: 320, height: 240)
        XCTAssertEqual(cache.strokesDrawn - before, 1, "only the new segment")
        var direct = [UInt8](repeating: 0, count: 320 * 240)
        BrushRaster.draw(committed + [drag.polyline, next], width: 320, height: 240, into: &direct)
        XCTAssertEqual(drawn.bytes, direct, "the segments and the polyline draw the same pixels")
    }
}
