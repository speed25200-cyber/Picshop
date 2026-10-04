import XCTest
import PicshopCore
import PicshopIntent
@testable import PicshopImaging

/// Taps, boxes and strokes as SAM 2.1 prompts (W2, D9). Pure Swift, runs on Linux.
final class SAMPromptingTests: XCTestCase {
    private func horizontalStroke(from x0: Double, to x1: Double, y: Double = 0.5, steps: Int = 200) -> [PSPoint] {
        (0...steps).map { PSPoint(x: x0 + (x1 - x0) * Double($0) / Double(steps), y: y) }
    }

    func testSamplesAreSpacedByOneAndAHalfRadiiOrTwoPercent() {
        let aspect = 1.0
        // A big brush: 1.5 × 0.04 = 0.06 between samples.
        let wide = SAMPrompting.samples(along: horizontalStroke(from: 0.1, to: 0.3), radius: 0.04, aspect: aspect)
        XCTAssertEqual(wide.first, PSPoint(x: 0.1, y: 0.5), "the stroke's first point is a sample")
        for (a, b) in zip(wide, wide.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.distance(to: b), 0.06 - 1e-9)
        }
        XCTAssertEqual(wide.count, 4, "0.20 long at 0.06 apart: 0.10, 0.16, 0.22, 0.28")
        // A tiny brush still keeps 2 % of the longest side between samples.
        let fine = SAMPrompting.samples(along: horizontalStroke(from: 0.1, to: 0.2), radius: 0.001, aspect: aspect)
        for (a, b) in zip(fine, fine.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.distance(to: b), 0.02 - 1e-9)
        }
        XCTAssertEqual(fine.count, 6)
    }

    func testALongStrokeSpreadsAtMostEightSamplesOverItsLength() {
        let samples = SAMPrompting.samples(along: horizontalStroke(from: 0.05, to: 0.95), radius: 0.005, aspect: 1)
        XCTAssertEqual(samples.count, SAMPrompting.maxSamplesPerStroke)
        XCTAssertGreaterThan(samples.last?.x ?? 0, 0.85, "the samples reach the end of the stroke")
    }

    func testSpacingIsMeasuredInLongestSideUnitsOnANonSquarePicture() {
        // A 2:1 picture: a vertical move of 0.1 (normalised) is 0.05 of the longest side.
        let vertical = (0...100).map { PSPoint(x: 0.5, y: 0.2 + 0.4 * Double($0) / 100) }
        let samples = SAMPrompting.samples(along: vertical, radius: 0.02, aspect: 2)
        let spacing = SAMPrompting.spacing(radius: 0.02)
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(abs(b.y - a.y) * 0.5, spacing - 1e-9)
        }
    }

    func testEraseStrokesAreNegativePrompts() {
        let prompts = SAMPrompting.prompts(along: horizontalStroke(from: 0.2, to: 0.4), radius: 0.03, aspect: 1, erase: true)
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { !$0.isPositive })
    }

    func testAtMostTwelvePromptsTheLatestKeptBoxCornersFirst() {
        let points = (0..<20).map { MaskPrompt(PSPoint(x: Double($0) / 20, y: 0.5), positive: $0 % 3 != 0) }
        let box = PSRect(x: 0.25, y: 0.1, width: 0.5, height: 0.6)
        let encoded = SAMPrompting.encode(points, box: box)
        XCTAssertEqual(encoded.count, SAMPrompting.maxPrompts)
        XCTAssertEqual(encoded.coordinates.count, encoded.count * 2)
        XCTAssertEqual(Array(encoded.labels.prefix(2)), [2, 3], "box corners first")
        XCTAssertEqual(Array(encoded.coordinates.prefix(4)), [256, 102.4, 768, 716.8].map { Float($0) })
        // The latest ten points follow, in order, positive 1 and negative 0.
        let kept = Array(points.suffix(10))
        for (offset, prompt) in kept.enumerated() {
            XCTAssertEqual(encoded.labels[2 + offset], prompt.isPositive ? 1 : 0)
            XCTAssertEqual(encoded.coordinates[4 + offset * 2], Float(prompt.point.x * 1024), accuracy: 1e-3)
        }
        let pointsOnly = SAMPrompting.encode(Array(points.prefix(5)))
        XCTAssertEqual(pointsOnly.count, 5)
        XCTAssertFalse(pointsOnly.labels.contains(2))
    }

    func testCoordinatesGoToModelPixelsAndBack() {
        for point in [PSPoint(x: 0, y: 0), PSPoint(x: 1, y: 1), PSPoint(x: 0.3125, y: 0.7)] {
            let model = SAMPrompting.modelPoint(point)
            XCTAssertEqual(Double(model.x), point.x * 1024, accuracy: 1e-3)
            XCTAssertEqual(Double(model.y), point.y * 1024, accuracy: 1e-3)
            let back = SAMPrompting.normalised(x: model.x, y: model.y)
            XCTAssertEqual(back.x, point.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
        }
        // Outside the picture is clamped to its edge.
        XCTAssertEqual(SAMPrompting.modelPoint(PSPoint(x: -0.2, y: 1.4)).x, 0)
        XCTAssertEqual(SAMPrompting.modelPoint(PSPoint(x: -0.2, y: 1.4)).y, 1024)
    }

    func testAnEmptyBoxIsLeftOutAndAnchorsFollowThePositives() {
        let encoded = SAMPrompting.encode([MaskPrompt(PSPoint(x: 0.5, y: 0.5))], box: PSRect(x: 0.4, y: 0.4, width: 0, height: 0.2))
        XCTAssertEqual(encoded.labels, [1])
        XCTAssertTrue(encoded.hasPositive)
        XCTAssertFalse(SAMPrompting.encode([MaskPrompt(PSPoint(x: 0.5, y: 0.5), positive: false)]).hasPositive)
        let anchors = SAMPrompting.anchors([MaskPrompt(PSPoint(x: 0.1, y: 0.1)), MaskPrompt(PSPoint(x: 0.9, y: 0.9), positive: false)],
                                           box: PSRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        XCTAssertEqual(anchors, [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.4, y: 0.4)])
    }

    // MARK: - Decoder output

    func testTheBestMaskIsTheHighestScore() {
        XCTAssertEqual(SAMPrompting.bestMask(scores: [0.2, 0.9, 0.5]), 1)
        XCTAssertEqual(SAMPrompting.bestMask(scores: [0.7]), 0)
    }

    func testLogitsAreUpsampledNonUniformlyAndPassThroughASigmoid() {
        // A 4 × 4 logit plane: strongly positive on the left half, negative on the right.
        let side = 4
        let logits: [Float] = (0..<(side * side)).map { ($0 % side) < 2 ? 12 : -12 }
        let bytes = SAMPrompting.maskBytes(fromLogits: logits, side: side, width: 40, height: 10)
        XCTAssertEqual(bytes.count, 400)
        XCTAssertEqual(bytes[5 * 40 + 2], 255, "left: sigmoid(12) ≈ 1")
        XCTAssertEqual(bytes[5 * 40 + 37], 0, "right: sigmoid(−12) ≈ 0")
        // The edge falls in the middle of the stretched width: logit 0 → 0.5 at x = 20.
        XCTAssertEqual(Int(bytes[5 * 40 + 19]) + Int(bytes[5 * 40 + 20]), 255, accuracy: 2)
        XCTAssertEqual(SAMPrompting.maskBytes(fromLogits: [0], side: 1, width: 2, height: 1), [128, 128])
    }

    func testCleaningKeepsTheRegionUnderThePromptAndDropsSpecks() {
        let width = 100, height = 60
        var bytes = [UInt8](repeating: 0, count: width * height)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            for y in y0..<y1 { for x in x0..<x1 { bytes[y * width + x] = 255 } }
        }
        fill(10, 10, 40, 40)   // under the tap
        fill(60, 10, 90, 40)   // another object
        fill(50, 50, 51, 51)   // a speck
        let tap = [PSPoint(x: 0.25, y: 0.4)]
        let cleaned = SAMPrompting.cleaned(bytes, width: width, height: height, anchors: tap, box: nil)
        XCTAssertEqual(cleaned[20 * width + 20], 255)
        XCTAssertEqual(cleaned[20 * width + 70], 0, "the other object goes")
        XCTAssertEqual(cleaned[50 * width + 50], 0, "the speck goes")
        // An anchor on a hole: the regions centred in the box stay.
        let box = PSRect(x: 0.55, y: 0.1, width: 0.4, height: 0.6)
        let byBox = SAMPrompting.cleaned(bytes, width: width, height: height, anchors: [PSPoint(x: 0.99, y: 0.99)], box: box)
        XCTAssertEqual(byBox[20 * width + 70], 255)
        XCTAssertEqual(byBox[20 * width + 20], 0)
    }
}

