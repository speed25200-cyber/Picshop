import XCTest
import PicshopCore
@testable import PicshopImaging

/// Select & Mask's CPU reference (W2, §6 item 9): the guided filter snaps a mask edge to the picture's edge,
/// the steps keep their order and ranges, and decontamination pulls edge colours to the foreground's.
/// Pure Swift, runs on Linux.
final class EdgeRefineReferenceTests: XCTestCase {
    private let width = 64, height = 48

    /// A guide with a vertical step at `edge` (dark left, bright right).
    private func stepGuide(edge: Int) -> [Float] {
        (0..<(width * height)).map { ($0 % width) < edge ? 0.1 : 0.9 }
    }

    /// A rough mask whose edge sits at `edge`.
    private func stepMask(edge: Int) -> [Float] {
        (0..<(width * height)).map { ($0 % width) < edge ? 0 : 1 }
    }

    /// The column where a row of the mask crosses 0.5.
    private func crossing(_ mask: [Float], row: Int) -> Double? {
        for x in 1..<width {
            let a = mask[row * width + x - 1], b = mask[row * width + x]
            if (a - 0.5) * (b - 0.5) <= 0, a != b {
                return Double(x - 1) + Double((0.5 - a) / (b - a)) + 0.5
            }
        }
        return nil
    }

    /// A rough mask as an AI model gives it: a soft edge (a smoothstep `softness` px wide) centred at `centre`.
    private func softMask(centre: Double, softness: Double, width w: Int, height h: Int) -> [Float] {
        (0..<(w * h)).map { index in
            let x = Double(index % w) + 0.5
            let t = ((x - centre) / softness + 0.5).clamped(to: 0...1)
            return Float(t * t * (3 - 2 * t))
        }
    }

    func testTheGuidedFilterMovesTheEdgeOntoTheGuidesEdge() throws {
        // The picture's edge is at x = 32; the rough mask is soft (8 px) and centred 2 px off, at x = 30.
        let rough = softMask(centre: 30, softness: 8, width: width, height: height)
        XCTAssertEqual(try XCTUnwrap(crossing(rough, row: 0)), 30, accuracy: 0.5)
        let refined = EdgeRefineReference.guidedFilter(input: rough, guide: stepGuide(edge: 32), width: width, height: height,
                                                       radius: 6, epsilon: 1e-4)
        for row in [0, height / 2, height - 1] {
            let edge = try XCTUnwrap(crossing(refined, row: row))
            XCTAssertEqual(edge, 32, accuracy: 1, "row \(row)")
        }
        // And the edge is the picture's: one step between x = 31 and x = 32, sharper than the rough mask's.
        let refinedStep = refined[32] - refined[31], roughStep = rough[32] - rough[31]
        XCTAssertGreaterThan(refinedStep, 0.3)
        XCTAssertGreaterThan(refinedStep, roughStep * 1.5)
    }

    func testRefineAtItsRadiusAlignsTheEdgeWithinAPixel() throws {
        // 200 px: radius 1 is 0.02 × 200 = 4 px. The picture's edge at x = 100, the rough mask's at 98.5, soft.
        let side = 200
        var guide = [Float](repeating: 0, count: side * side)
        for index in guide.indices { guide[index] = index % side < 100 ? 0.15 : 0.85 }
        let rough = softMask(centre: 98.5, softness: 6, width: side, height: side)
        let refined = EdgeRefineReference.refine(mask: rough, guide: guide, width: side, height: side,
                                                 refinement: SelectionRefinement(radius: 1, smooth: 0, feather: 0, contrast: 0.2))
        var crossingX: Double?
        for x in 1..<side where crossingX == nil {
            let a = refined[100 * side + x - 1], b = refined[100 * side + x]
            if a < 0.5, b >= 0.5 { crossingX = Double(x - 1) + Double((0.5 - a) / (b - a)) + 0.5 }
        }
        XCTAssertEqual(try XCTUnwrap(crossingX), 100, accuracy: 1)
    }

    func testStepsStayInRangeAndContrastAndShiftActAroundOneHalf() {
        let ramp = (0..<(width * height)).map { Float($0 % width) / Float(width - 1) }
        let flatGuide = [Float](repeating: 0.5, count: width * height)
        let none = SelectionRefinement(radius: 0, smooth: 0, feather: 0, contrast: 0, shiftEdge: 0)
        let unchanged = EdgeRefineReference.refine(mask: ramp, guide: flatGuide, width: width, height: height, refinement: none)
        for index in ramp.indices { XCTAssertEqual(unchanged[index], ramp[index], accuracy: 1e-6) }

        let contrasted = EdgeRefineReference.refine(mask: ramp, guide: flatGuide, width: width, height: height,
                                                    refinement: SelectionRefinement(radius: 0, contrast: 1))
        // Slope 7 around 0.5: a value of 0.6 becomes 1.
        XCTAssertEqual(EdgeRefineReference.contrastLine(SelectionRefinement(contrast: 1)).slope, 7)
        XCTAssertEqual(contrasted[38], 1, "0.603 → 1")
        XCTAssertEqual(contrasted[25], 0, "0.397 → 0")

        let shifted = EdgeRefineReference.refine(mask: ramp, guide: flatGuide, width: width, height: height,
                                                 refinement: SelectionRefinement(radius: 0, shiftEdge: 1))
        XCTAssertEqual(shifted[10], min(1, ramp[10] + 0.25), accuracy: 1e-5, "shift edge +1 adds 0.25")
        for value in contrasted + shifted { XCTAssertTrue((0...1).contains(value)) }
    }

    func testFeatherSpreadsAndSmoothRemovesJaggedSteps() {
        // 400 px: smooth 1 is a Gaussian of σ = 0.006 × 400 = 2.4 px.
        let side = 400
        var jagged = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            // A staircase edge: ±2 px teeth, 2 rows each.
            let edge = 200 + ((y / 2) % 2 == 0 ? 2 : -2)
            for x in edge..<side { jagged[y * side + x] = 1 }
        }
        let guide = [Float](repeating: 0.5, count: side * side)
        let smoothed = EdgeRefineReference.refine(mask: jagged, guide: guide, width: side, height: side,
                                                  refinement: SelectionRefinement(radius: 0, smooth: 1))
        // The teeth shrink: the crossing varies less from row to row.
        func spread(_ mask: [Float]) -> Double {
            var crossings: [Double] = []
            for y in 20..<(side - 20) {
                for x in 1..<side where mask[y * side + x - 1] < 0.5 && mask[y * side + x] >= 0.5 {
                    let a = Double(mask[y * side + x - 1]), b = Double(mask[y * side + x])
                    crossings.append(Double(x - 1) + (0.5 - a) / (b - a))
                    break
                }
            }
            return (crossings.max() ?? 0) - (crossings.min() ?? 0)
        }
        XCTAssertLessThan(spread(smoothed), spread(jagged) / 2)

        let feathered = EdgeRefineReference.refine(mask: jagged, guide: guide, width: side, height: side,
                                                   refinement: SelectionRefinement(radius: 0, feather: 1))
        let softBefore = jagged.filter { $0 > 0.05 && $0 < 0.95 }.count
        let softAfter = feathered.filter { $0 > 0.05 && $0 < 0.95 }.count
        XCTAssertGreaterThan(softAfter, softBefore + side * 4, "a feather widens the soft band")
    }

    func testDecontaminationPullsEdgeColoursTowardsTheForeground() {
        // A red subject (left) on a green background, with a half-transparent band whose colour is the mix.
        let w = 80, h = 20
        var rgb = [Float](repeating: 0, count: w * h * 3)
        var alpha = [Float](repeating: 0, count: w * h)
        let foreground: [Float] = [0.9, 0.1, 0.1], background: [Float] = [0.1, 0.8, 0.1]
        for y in 0..<h {
            for x in 0..<w {
                let index = y * w + x
                let a: Float = x < 36 ? 1 : (x < 44 ? Float(44 - x) / 8 : 0)
                alpha[index] = a
                for c in 0..<3 { rgb[index * 3 + c] = foreground[c] * a + background[c] * (1 - a) }
            }
        }
        let out = EdgeRefineReference.decontaminate(rgb: rgb, alpha: alpha, width: w, height: h, amount: 1, sigma: 0.01 * Double(w) * 4)
        // The edge pixel at alpha 0.5 (x = 40) moves at least 70 % of the way to the foreground colour.
        let index = (h / 2) * w + 40
        XCTAssertEqual(alpha[index], 0.5, accuracy: 1e-6)
        for c in 0..<3 {
            let gap = foreground[c] - rgb[index * 3 + c]
            guard abs(gap) > 0.05 else { continue }
            let moved = out[index * 3 + c] - rgb[index * 3 + c]
            XCTAssertGreaterThanOrEqual(moved / gap, 0.7, "channel \(c)")
        }
        // Fully opaque and fully clear pixels keep their colour.
        let inside = (h / 2) * w + 10, outside = (h / 2) * w + 70
        for c in 0..<3 {
            XCTAssertEqual(out[inside * 3 + c], rgb[inside * 3 + c], accuracy: 1e-6)
            XCTAssertEqual(out[outside * 3 + c], rgb[outside * 3 + c], accuracy: 1e-6)
        }
        // Amount 0 is the identity.
        XCTAssertEqual(EdgeRefineReference.decontaminate(rgb: rgb, alpha: alpha, width: w, height: h, amount: 0, sigma: 2), rgb)
        XCTAssertEqual(EdgeRefineReference.decontaminationWeight(alpha: 0.5, amount: 1), 1)
        XCTAssertEqual(EdgeRefineReference.decontaminationWeight(alpha: 1, amount: 1), 0)
    }

    func testGaussianKeepsMassAndBoxMeanIsExact() {
        var dot = [Float](repeating: 0, count: width * height)
        dot[(height / 2) * width + width / 2] = 1
        let blurred = EdgeRefineReference.gaussianBlur(dot, width: width, height: height, sigma: 3)
        XCTAssertEqual(blurred.reduce(0, +), 1, accuracy: 1e-4)
        let ones = [Float](repeating: 1, count: width * height)
        XCTAssertTrue(EdgeRefineReference.boxMean(ones, width: width, height: height, radius: 5).allSatisfy { abs($0 - 1) < 1e-6 })
        let ramp = (0..<(width * height)).map { Float($0 % width) }
        let mean = EdgeRefineReference.boxMean(ramp, width: width, height: height, radius: 2)
        XCTAssertEqual(mean[10 * width + 20], 20, accuracy: 1e-4)
        XCTAssertEqual(mean[10 * width], 1, accuracy: 1e-4, "clipped at the edge: (0 + 1 + 2) / 3")
    }
}
