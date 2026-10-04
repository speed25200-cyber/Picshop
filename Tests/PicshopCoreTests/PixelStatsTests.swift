import XCTest
@testable import PicshopCore

/// PixelStats (§5 item 8): Lab statistics from gamma bytes, weighted by a mask; what the pixel postconditions
/// compare before and after an edit.
final class PixelStatsTests: XCTestCase {
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        pixels.flatMap { [$0.0, $0.1, $0.2, 255] }
    }

    func testAUniformImageHasNoSpread() {
        let rgba = image(Array(repeating: (119, 119, 119), count: 64))
        let stats = PixelStats.measure(rgba: rgba, width: 8, height: 8, weights: nil)
        XCTAssertEqual(stats.meanL, 50, accuracy: 0.3)
        XCTAssertEqual(stats.stdL, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanChroma, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.weight, 64)
    }

    func testInsideAndOutsideAreHandComputable() {
        // Left half black, right half white; the mask covers the right half.
        var pixels: [(UInt8, UInt8, UInt8)] = []
        var mask: [Float] = []
        for _ in 0..<4 {
            for x in 0..<8 {
                pixels.append(x < 4 ? (0, 0, 0) : (255, 255, 255))
                mask.append(x < 4 ? 0 : 1)
            }
        }
        let regions = PixelStats.regions(rgba: image(pixels), width: 8, height: 4, mask: mask)
        XCTAssertEqual(regions.coverage, 0.5, accuracy: 1e-12)
        XCTAssertEqual(regions.inside.meanL, 100, accuracy: 0.01)
        XCTAssertEqual(regions.inside.weight, 16)
        XCTAssertEqual(regions.outside.meanL, 0, accuracy: 0.01)
        XCTAssertEqual(regions.outside.weight, 16)
        // The whole image: half black, half white.
        let whole = PixelStats.measure(rgba: image(pixels), width: 8, height: 4, weights: nil)
        XCTAssertEqual(whole.meanL, 50, accuracy: 0.01)
        XCTAssertEqual(whole.stdL, 50, accuracy: 0.01)
    }

    func testSoftWeightsAndTheOutsideThreshold() {
        // Two pixels: pure red at weight 0.25, pure blue at weight 0.75; the outside takes neither (both ≥ 0.05).
        let rgba = image([(255, 0, 0), (0, 0, 255)])
        let regions = PixelStats.regions(rgba: rgba, width: 2, height: 1, mask: [0.25, 0.75])
        let red = MaskMath.lab(r: 1, g: 0, b: 0), blue = MaskMath.lab(r: 0, g: 0, b: 1)
        XCTAssertEqual(regions.inside.meanL, 0.25 * red.l + 0.75 * blue.l, accuracy: 1e-9)
        XCTAssertEqual(regions.inside.meanA, 0.25 * red.a + 0.75 * blue.a, accuracy: 1e-9)
        XCTAssertEqual(regions.inside.meanB, 0.25 * red.b + 0.75 * blue.b, accuracy: 1e-9)
        let chroma = 0.25 * (red.a * red.a + red.b * red.b).squareRoot() + 0.75 * (blue.a * blue.a + blue.b * blue.b).squareRoot()
        XCTAssertEqual(regions.inside.meanChroma, chroma, accuracy: 1e-9)
        let mean = 0.25 * red.l + 0.75 * blue.l
        let deviation = (0.25 * pow(red.l - mean, 2) + 0.75 * pow(blue.l - mean, 2)).squareRoot()
        XCTAssertEqual(regions.inside.stdL, deviation, accuracy: 1e-9)
        XCTAssertEqual(regions.inside.weight, 1, accuracy: 1e-12)
        XCTAssertEqual(regions.outside, PixelStats())
        XCTAssertEqual(regions.coverage, 0.5, accuracy: 1e-12)
        // Weights in measure() give the same inside.
        XCTAssertEqual(PixelStats.measure(rgba: rgba, width: 2, height: 1, weights: [0.25, 0.75]), regions.inside)
    }

    func testMismatchedSizesGiveNothing() {
        let rgba = image([(10, 20, 30)])
        XCTAssertEqual(PixelStats.measure(rgba: rgba, width: 2, height: 1, weights: nil), PixelStats())
        XCTAssertEqual(PixelStats.measure(rgba: rgba, width: 1, height: 1, weights: [1, 1]), PixelStats())
        XCTAssertEqual(PixelStats.measure(rgba: [], width: 0, height: 0, weights: nil), PixelStats())
        XCTAssertEqual(PixelStats.regions(rgba: rgba, width: 1, height: 1, mask: []).coverage, 0)
        // A NaN in the mask counts as 0.
        XCTAssertEqual(PixelStats.regions(rgba: rgba, width: 1, height: 1, mask: [.nan]).outside.weight, 1)
    }

    func testAnExposureChangeShowsInside() {
        // The kind of comparison a postcondition makes: brighter inside, unchanged outside.
        var before: [(UInt8, UInt8, UInt8)] = [], after: [(UInt8, UInt8, UInt8)] = []
        var mask: [Float] = []
        for index in 0..<100 {
            let inside = index < 50
            before.append((90, 120, 160))
            after.append(inside ? (120, 150, 190) : (90, 120, 160))
            mask.append(inside ? 1 : 0)
        }
        let b = PixelStats.regions(rgba: image(before), width: 10, height: 10, mask: mask)
        let a = PixelStats.regions(rgba: image(after), width: 10, height: 10, mask: mask)
        XCTAssertGreaterThan(a.inside.meanL - b.inside.meanL, 5)
        XCTAssertEqual(a.outside.meanL, b.outside.meanL, accuracy: 1e-12)
    }
}
