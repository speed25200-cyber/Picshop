import XCTest
@testable import PicshopCore

/// SelectionAlgebra (§5 item 7): D1 on bytes, the Modify operations, resampling and measures; every function
/// total on empty or malformed input.
final class SelectionAlgebraTests: XCTestCase {
    private func random(width: Int, height: Int, seed: UInt64) -> GrayRaster {
        var generator = MaskTestRandom(seed: seed)
        return GrayRaster(width: width, height: height, bytes: (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// A filled axis-aligned rectangle (pixel bounds, end exclusive).
    private func rectangle(width: Int, height: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> GrayRaster {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in y0..<y1 { for x in x0..<x1 { bytes[y * width + x] = 255 } }
        return GrayRaster(width: width, height: height, bytes: bytes)
    }

    // MARK: Combine

    func testCombineFollowsD1() {
        let a = random(width: 13, height: 7, seed: 1), b = random(width: 13, height: 7, seed: 2)
        for mode in CombineMode.allCases {
            let combined = SelectionAlgebra.combine(a, b, mode: mode)
            // The reference on the same values, as a two-component stack (the base, then `b` in that mode).
            let source = MaskTestSource(rasters: ["a": FloatRaster(a), "b": FloatRaster(b)])
            let stack = MaskStack(components: [MaskComponent(.raster(MaskTestSource.raster("a", width: 13, height: 7))),
                                               MaskComponent(.raster(MaskTestSource.raster("b", width: 13, height: 7)), mode: mode)])
            let reference = MaskRaster.render(stack, width: 13, height: 7, source: source).grayRaster
            XCTAssertEqual(combined.width, 13)
            for index in combined.bytes.indices {
                XCTAssertEqual(Int(combined.bytes[index]), Int(reference.bytes[index]), accuracy: 1, "\(mode)")
            }
        }
    }

    func testANewSelectionReplacesAndAMissingBaseIsEmpty() {
        let a = random(width: 6, height: 4, seed: 3), b = random(width: 6, height: 4, seed: 4)
        XCTAssertEqual(SelectionAlgebra.combine(a, b, mode: nil), b)
        XCTAssertEqual(SelectionAlgebra.combine(nil, b, mode: nil), b)
        XCTAssertEqual(SelectionAlgebra.combine(nil, b, mode: .add), b)
        XCTAssertEqual(SelectionAlgebra.combine(nil, b, mode: .subtract), GrayRaster(width: 6, height: 4))
        XCTAssertEqual(SelectionAlgebra.combine(nil, b, mode: .intersect), GrayRaster(width: 6, height: 4))
    }

    func testANewRasterIsResampledToTheBase() {
        let base = rectangle(width: 100, height: 50, x0: 0, y0: 0, x1: 50, y1: 50)
        // The right half at half the size.
        let right = rectangle(width: 50, height: 25, x0: 25, y0: 0, x1: 50, y1: 25)
        let union = SelectionAlgebra.combine(base, right, mode: .add)
        XCTAssertEqual(union.width, 100)
        XCTAssertEqual(union.height, 50)
        XCTAssertEqual(SelectionAlgebra.coverage(union), 1, accuracy: 0.03)
        let cut = SelectionAlgebra.combine(union, right, mode: .subtract)
        XCTAssertEqual(SelectionAlgebra.coverage(cut), 0.5, accuracy: 0.03)
    }

    // MARK: Modify

    func testInvertGrowAndShrink() {
        let square = rectangle(width: 60, height: 60, x0: 20, y0: 20, x1: 40, y1: 40)
        XCTAssertEqual(SelectionAlgebra.inverted(SelectionAlgebra.inverted(square)), square)
        XCTAssertEqual(SelectionAlgebra.coverage(SelectionAlgebra.inverted(square)), 1 - 400.0 / 3600, accuracy: 1e-12)
        let grown = SelectionAlgebra.grown(square, radius: 3)
        // The edge moves by the radius along the axes, and the corners round off.
        XCTAssertEqual(grown.bytes[30 * 60 + 17], 255)
        XCTAssertEqual(grown.bytes[30 * 60 + 16], 0)
        XCTAssertEqual(grown.bytes[17 * 60 + 17], 0)
        let shrunk = SelectionAlgebra.shrunk(square, radius: 3)
        XCTAssertEqual(shrunk.bytes[30 * 60 + 23], 255)
        XCTAssertEqual(shrunk.bytes[30 * 60 + 22], 0)
        XCTAssertEqual(SelectionAlgebra.boundingBox(shrunk), PSRect(x: 23.0 / 60, y: 23.0 / 60, width: 14.0 / 60, height: 14.0 / 60))
        // Radius 0: unchanged.
        XCTAssertEqual(SelectionAlgebra.grown(square, radius: 0), square)
        XCTAssertEqual(SelectionAlgebra.shrunk(square, radius: -2), square)
    }

    func testFeatherKeepsTheMass() {
        let square = rectangle(width: 80, height: 80, x0: 25, y0: 25, x1: 55, y1: 55)
        let soft = SelectionAlgebra.feathered(square, sigma: 3)
        let before = square.bytes.reduce(0) { $0 + Int($1) }, after = soft.bytes.reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Double(after), Double(before), accuracy: 0.01 * Double(before))
        XCTAssertGreaterThan(soft.bytes.filter { $0 > 10 && $0 < 245 }.count, 100)
        XCTAssertEqual(SelectionAlgebra.feathered(square, sigma: 0), square)
    }

    func testSmoothingRemovesSpecksAndKeepsASquare() {
        var raster = rectangle(width: 64, height: 64, x0: 20, y0: 20, x1: 40, y1: 40)
        // Isolated pixels outside, a pin hole inside.
        for (x, y) in [(5, 5), (50, 10), (58, 58), (10, 50)] { raster.bytes[y * 64 + x] = 255 }
        raster.bytes[30 * 64 + 30] = 0
        let smooth = SelectionAlgebra.smoothed(raster, radius: 2)
        for (x, y) in [(5, 5), (50, 10), (58, 58), (10, 50)] { XCTAssertEqual(smooth.bytes[y * 64 + x], 0) }
        XCTAssertEqual(smooth.bytes[30 * 64 + 30], 255)
        // The 20 px square is kept (its corners may round by a pixel or two).
        var kept = 0
        for y in 20..<40 {
            for x in 20..<40 where smooth.bytes[y * 64 + x] > 127 { kept += 1 }
        }
        XCTAssertGreaterThanOrEqual(kept, 380)
        XCTAssertEqual(SelectionAlgebra.boundingBox(smooth, threshold: 127), PSRect(x: 20.0 / 64, y: 20.0 / 64, width: 20.0 / 64, height: 20.0 / 64))
        // Radius 0 still drops a lone speck (the 3×3 majority).
        XCTAssertEqual(SelectionAlgebra.smoothed(raster, radius: 0).bytes[5 * 64 + 5], 0)
    }

    // MARK: Resampling and measures

    func testResamplingPreservesCoverage() {
        // A disc, then shapes at the selection's working size and below.
        var disc = GrayRaster(width: 1536, height: 1024)
        for y in 0..<1024 {
            for x in 0..<1536 {
                let dx = Double(x) + 0.5 - 700, dy = Double(y) + 0.5 - 480
                if dx * dx + dy * dy < 300 * 300 { disc.bytes[y * 1536 + x] = 255 }
            }
        }
        let coverage = SelectionAlgebra.coverage(disc)
        for (width, height) in [(768, 512), (500, 333), (2048, 1365), (97, 64)] {
            let resampled = SelectionAlgebra.resampled(disc, width: width, height: height)
            XCTAssertEqual(resampled.width, width)
            XCTAssertEqual(resampled.height, height)
            XCTAssertEqual(SelectionAlgebra.coverage(resampled), coverage, accuracy: 0.005, "\(width)×\(height)")
        }
        // A thin line survives a large reduction (area weights), as a faint line.
        var line = GrayRaster(width: 1000, height: 10)
        for y in 0..<10 { line.bytes[y * 1000 + 500] = 255 }
        XCTAssertGreaterThan(SelectionAlgebra.resampled(line, width: 100, height: 10).bytes.max()!, 20)
        // Same size: unchanged. Upsampling a constant stays constant.
        XCTAssertEqual(SelectionAlgebra.resampled(disc, width: 1536, height: 1024), disc)
        let flat = GrayRaster(width: 3, height: 2, bytes: [200, 200, 200, 200, 200, 200])
        XCTAssertTrue(SelectionAlgebra.resampled(flat, width: 7, height: 5).bytes.allSatisfy { $0 == 200 })
    }

    func testCoverageAndBoundingBox() {
        let raster = GrayRaster(width: 4, height: 2, bytes: [0, 127, 128, 255, 33, 32, 0, 0])
        XCTAssertEqual(SelectionAlgebra.coverage(raster), 2.0 / 8)
        XCTAssertEqual(SelectionAlgebra.boundingBox(raster), PSRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(SelectionAlgebra.boundingBox(raster, threshold: 127), PSRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(SelectionAlgebra.boundingBox(GrayRaster(width: 4, height: 4)), .zero)
    }

    func testEverythingIsTotal() {
        let empty = GrayRaster(width: 0, height: 0, bytes: [])
        let broken = GrayRaster(width: 10, height: 10, bytes: [1, 2, 3])
        for raster in [empty, broken] {
            XCTAssertEqual(SelectionAlgebra.coverage(raster), 0)
            XCTAssertEqual(SelectionAlgebra.boundingBox(raster), .zero)
            _ = SelectionAlgebra.inverted(raster)
            _ = SelectionAlgebra.grown(raster, radius: 3)
            _ = SelectionAlgebra.shrunk(raster, radius: 3)
            _ = SelectionAlgebra.feathered(raster, sigma: 2)
            _ = SelectionAlgebra.smoothed(raster, radius: 2)
            _ = SelectionAlgebra.combine(raster, raster, mode: .add)
            _ = SelectionAlgebra.combine(random(width: 5, height: 5, seed: 9), raster, mode: .intersect)
            _ = SelectionAlgebra.combine(raster, random(width: 5, height: 5, seed: 9), mode: .subtract)
        }
        // A broken raster counts as nothing at its size.
        XCTAssertEqual(SelectionAlgebra.inverted(broken).bytes, [UInt8](repeating: 255, count: 100))
        XCTAssertEqual(SelectionAlgebra.resampled(broken, width: 4, height: 4), GrayRaster(width: 4, height: 4))
        XCTAssertEqual(SelectionAlgebra.resampled(random(width: 5, height: 5, seed: 1), width: 0, height: 3).bytes, [])
        XCTAssertEqual(SelectionAlgebra.resampled(random(width: 5, height: 5, seed: 1), width: -2, height: 3).bytes, [])
    }
}
