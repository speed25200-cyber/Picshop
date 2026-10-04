import XCTest
import PicshopCore
@testable import PicshopImaging

/// The W2 Lab magic wand and Quick Selection's fallback without SAM (D8). Pure Swift, runs on Linux.
final class WandLabTests: XCTestCase {
    private let width = 96, height = 64

    private func picture(_ colour: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y)
                let i = (y * width + x) * 4
                rgba[i] = c.0; rgba[i + 1] = c.1; rgba[i + 2] = c.2
            }
        }
        return rgba
    }

    func testLabOfReferenceColours() {
        let white = Selection.Lab.of(r: 255, g: 255, b: 255)
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        let grey = Selection.Lab.of(r: 0x77, g: 0x77, b: 0x77)
        XCTAssertEqual(grey.l, 50.0, accuracy: 0.3)
        let red = Selection.Lab.of(r: 255, g: 0, b: 0)
        XCTAssertEqual(red.l, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.1)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.1)
        XCTAssertEqual(Selection.Lab.of(r: 0, g: 0, b: 0).l, 0, accuracy: 1e-9)
    }

    func testTheThresholdIsTwoPlusFortyEightTimesTheTolerance() {
        XCTAssertEqual(Selection.wandThreshold(tolerance: 0), 2)
        XCTAssertEqual(Selection.wandThreshold(tolerance: 1), 50)
        XCTAssertEqual(Selection.wandThreshold(tolerance: 0.18), 10.64, accuracy: 1e-9)
    }

    func testDeltaEDecidesWhatIsIn() {
        // Left half grey 0x80; right half a grey step to the right whose ΔE is about 5.
        let rgba = picture { x, _ in x < 48 ? (0x80, 0x80, 0x80) : (0x8D, 0x8D, 0x8D) }
        let delta = Selection.Lab.of(r: 0x80, g: 0x80, b: 0x80).distance(to: Selection.Lab.of(r: 0x8D, g: 0x8D, b: 0x8D))
        XCTAssertGreaterThan(delta, 3)
        XCTAssertLessThan(delta, 8)
        let tight = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (0.2, 0.5), tolerance: 0, antiAlias: false)
        XCTAssertEqual(tight[30 * width + 70], 0, "ΔE \(delta) > 2: out")
        XCTAssertEqual(tight[30 * width + 10], 255)
        let loose = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (0.2, 0.5), tolerance: 0.2, antiAlias: false)
        XCTAssertEqual(loose[30 * width + 70], 255, "ΔE \(delta) < 11.6: in")
    }

    func testContiguityAndTheGlobalMode() {
        // Two red squares separated by blue.
        let rgba = picture { x, y in
            let inA = x >= 8 && x < 28 && y >= 8 && y < 28
            let inB = x >= 60 && x < 80 && y >= 30 && y < 50
            return inA || inB ? (220, 30, 30) : (30, 40, 200)
        }
        let contiguous = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (15.0 / 96, 15.0 / 64), tolerance: 0.1, antiAlias: false)
        XCTAssertEqual(contiguous[40 * width + 70], 0)
        XCTAssertEqual(contiguous[15 * width + 15], 255)
        let global = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (15.0 / 96, 15.0 / 64), tolerance: 0.1, contiguous: false,
                                            antiAlias: false)
        XCTAssertEqual(global[40 * width + 70], 255)
        XCTAssertEqual(global.filter { $0 == 255 }.count, 800)
    }

    func testSampleSizeAveragesTheSeedWindow() {
        // A noisy checker of two greys: one pixel alone is one grey, the 3 × 3 mean is in between.
        let rgba = picture { x, y in (x + y) % 2 == 0 ? (100, 100, 100) : (140, 140, 140) }
        let one = Selection.averageLab(rgba: rgba, width: width, height: height, x: 10, y: 10, sampleSize: 1)
        let three = Selection.averageLab(rgba: rgba, width: width, height: height, x: 10, y: 10, sampleSize: 3)
        let five = Selection.averageLab(rgba: rgba, width: width, height: height, x: 10, y: 10, sampleSize: 5)
        XCTAssertEqual(one, Selection.Lab.of(r: 100, g: 100, b: 100))
        XCTAssertGreaterThan(three.l, one.l)
        let mean: Double = (5.0 * 100 + 4.0 * 140) / 9 / 255
        XCTAssertEqual(three.l, Selection.Lab.of(red: mean, green: mean, blue: mean).l, accuracy: 1e-6)
        XCTAssertNotEqual(three, five)
        // With a 3 × 3 sample and a middling tolerance, the whole checker is one region.
        let wand = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (0.1, 0.15), tolerance: 0.2, sampleSize: 3, antiAlias: false)
        XCTAssertEqual(wand.filter { $0 == 255 }.count, width * height)
    }

    func testTheAntiAliasBandIsOnePixelOnTheInnerBoundary() {
        let rgba = picture { x, _ in x < 40 ? (240, 240, 240) : (20, 20, 20) }
        let mask = Selection.magicWandLab(rgba: rgba, width: width, height: height, seed: (0.1, 0.5), tolerance: 0.1)
        let row = 30 * width
        XCTAssertEqual(mask[row + 38], 255, "inside")
        XCTAssertGreaterThan(mask[row + 39], 0, "the edge pixel is partly in")
        XCTAssertLessThan(mask[row + 39], 255)
        XCTAssertEqual(mask[row + 40], 0, "outside stays out")
        XCTAssertEqual(mask[row + 39], 170, "6 of 9 neighbours")
    }

    // MARK: - Quick Selection fallback

    /// Whether (x, y) lies on the test object: an ellipse centred at (48, 32), 22 × 18 px radii.
    private func onObject(_ x: Int, _ y: Int) -> Bool {
        let dx = Double(x - 48) / 22, dy = Double(y - 32) / 18
        return dx * dx + dy * dy <= 1
    }

    /// A two-colour object (orange top, red bottom) on a grey-blue background.
    private func object() -> (rgba: [UInt8], truth: [Bool]) {
        var truth = [Bool](repeating: false, count: width * height)
        let background: (UInt8, UInt8, UInt8) = (90, 100, 120)
        let orange: (UInt8, UInt8, UInt8) = (240, 150, 40)
        let red: (UInt8, UInt8, UInt8) = (200, 30, 40)
        let rgba = picture { (x: Int, y: Int) -> (UInt8, UInt8, UInt8) in
            if !self.onObject(x, y) { return background }
            return y < 32 ? orange : red
        }
        for y in 0..<height {
            for x in 0..<width { truth[y * width + x] = onObject(x, y) }
        }
        return (rgba, truth)
    }

    private func iou(_ mask: [UInt8], _ truth: [Bool]) -> Double {
        var both = 0, either = 0
        for index in truth.indices {
            let selected = mask[index] > 127
            if selected && truth[index] { both += 1 }
            if selected || truth[index] { either += 1 }
        }
        return either == 0 ? 0 : Double(both) / Double(either)
    }

    func testAStrokeAcrossATwoColourObjectSelectsIt() {
        let fixture = object()
        // A vertical stroke through both colours, brush radius 5 % of the longest side (disk reach 0.2 × 96 ≈ 19 px).
        let stroke = (0...20).map { PSPoint(x: 0.5, y: 0.25 + 0.5 * Double($0) / 20) }
        let mask = QuickSelectFallback.stroke(rgba: fixture.rgba, width: width, height: height, points: stroke, radius: 0.05, erase: false, base: nil)
        XCTAssertGreaterThanOrEqual(iou(mask, fixture.truth), 0.7)
        XCTAssertEqual(mask[5 * width + 5], 0, "the background is left alone")
    }

    func testAnEraseStrokeRemovesWhatItCrosses() {
        let fixture = object()
        let base = fixture.truth.map { $0 ? UInt8(255) : 0 }
        // Erase across the red bottom only.
        let stroke = (0...20).map { PSPoint(x: 0.3 + 0.4 * Double($0) / 20, y: 0.75) }
        let mask = QuickSelectFallback.stroke(rgba: fixture.rgba, width: width, height: height, points: stroke, radius: 0.04, erase: true, base: base)
        XCTAssertEqual(mask[48 * width + 48], 0, "the red under the stroke is gone")
        XCTAssertEqual(mask[20 * width + 48], 255, "the orange top stays")
        // Erasing never adds.
        for index in mask.indices { XCTAssertLessThanOrEqual(mask[index], base[index]) }
    }

    func testAStrokeAddsToTheExistingSelection() {
        let fixture = object()
        var base = [UInt8](repeating: 0, count: width * height)
        base[2 * width + 2] = 255
        let stroke = [PSPoint(x: 0.5, y: 0.3), PSPoint(x: 0.5, y: 0.35)]
        let mask = QuickSelectFallback.stroke(rgba: fixture.rgba, width: width, height: height, points: stroke, radius: 0.05, erase: false, base: base)
        XCTAssertEqual(mask[2 * width + 2], 255, "kept")
        XCTAssertEqual(mask[25 * width + 48], 255, "added")
    }

    // MARK: - One Lab for the wand, the samples and the colour range

    func testTheWandsLabIsCoresLab() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let r = UInt8.random(in: 0...255, using: &random), g = UInt8.random(in: 0...255, using: &random), b = UInt8.random(in: 0...255, using: &random)
            let fast = Selection.Lab.of(r: r, g: g, b: b)
            let core = MaskMath.lab(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
            XCTAssertEqual(fast.l, core.l, accuracy: 1e-6)
            XCTAssertEqual(fast.a, core.a, accuracy: 1e-6)
            XCTAssertEqual(fast.b, core.b, accuracy: 1e-6)
        }
    }

    func testSampledColoursAreTheWindowMeansInLab() throws {
        // Left half one colour, right half another; a window straddling the edge averages them.
        let rgba = picture { x, _ in x < 48 ? (200, 40, 40) : (40, 40, 200) }
        let samples = ColorRangeSampler.labColors(rgba: rgba, width: width, height: height,
                                                  at: [PSPoint(x: 0.1, y: 0.5), PSPoint(x: 0.9, y: 0.5)], radius: 2)
        XCTAssertEqual(samples.count, 2)
        let red = MaskMath.lab(r: 200.0 / 255, g: 40.0 / 255, b: 40.0 / 255)
        XCTAssertEqual(samples[0].l, red.l, accuracy: 1e-6)
        XCTAssertEqual(samples[0].a, red.a, accuracy: 1e-6)
        // A sample is in its own colour range at full strength.
        XCTAssertEqual(MaskMath.colorRange(samples[1], ColorRangeSpec(samples: [samples[1]], fuzziness: 0.1)), 1, accuracy: 1e-9)
        let edge = try XCTUnwrap(ColorRangeSampler.meanColor(rgba: rgba, width: width, height: height, at: PSPoint(x: 48.0 / 96, y: 0.5), radius: 1))
        XCTAssertEqual(edge.r, (200.0 + 2 * 40) / 3 / 255, accuracy: 1e-9, "a 3 × 3 window: one column of red, two of blue")
        let luma = try XCTUnwrap(ColorRangeSampler.luma(rgba: rgba, width: width, height: height, at: PSPoint(x: 0.1, y: 0.5), radius: 0))
        XCTAssertEqual(luma, MaskMath.luma(r: 200.0 / 255, g: 40.0 / 255, b: 40.0 / 255), accuracy: 1e-9)
    }
}

