import XCTest
@testable import PicshopCore

/// Levels in the edit stack and the curve channels. The tone maths are in ToneMathTests.
final class EditStackToneTests: XCTestCase {
    func testResolvedLevelsIsTheLastOne() {
        var stack = EditStack()
        XCTAssertEqual(stack.resolvedLevels, .identity)
        XCTAssertTrue(stack.resolvedLevels.isIdentity)
        stack.append(.levels(Levels(red: Levels.Channel(outWhite: 0.9))))
        stack.append(.adjust(.contrast, value: 0.1))
        stack.append(.levels(Levels(rgb: Levels.Channel(gamma: 1.4))))
        XCTAssertEqual(stack.resolvedLevels.rgb.gamma, 1.4)
        XCTAssertEqual(stack.resolvedLevels.red, .identity)
    }

    func testSetToneCoalescesADrag() {
        var stack = EditStack()
        stack.append(.adjust(.exposure, value: 0.2))
        for step in 1...60 {
            stack.setTone(.levels(Levels(rgb: Levels.Channel(inBlack: Double(step) / 600))))
        }
        XCTAssertEqual(stack.operations.count, 2, "one undo step for the whole drag")
        XCTAssertEqual(stack.resolvedLevels.rgb.inBlack, 0.1, accuracy: 1e-9)
        stack.setTone(.toneCurve(.sCurve(strength: 0.5)))
        stack.setTone(.toneCurve(.sCurve(strength: 0.8)))
        XCTAssertEqual(stack.operations.count, 3, "a curve after levels is a new step, then coalesces")
        XCTAssertEqual(stack.resolvedToneCurve, .sCurve(strength: 0.8))
        XCTAssertEqual(stack.operations.last?.label, "Curves")
    }

    func testLevelsChannelsAndCurvePoints() {
        var levels = Levels.identity
        levels[.green] = Levels.Channel(inWhite: 0.8)
        XCTAssertEqual(levels.green.inWhite, 0.8)
        XCTAssertFalse(levels.isIdentity)
        var curve = ToneCurve.identity
        let points = [ToneCurve.Point(0, 0.1), ToneCurve.Point(1, 0.9)]
        curve.setPoints(points, for: .blue)
        XCTAssertEqual(curve.points(.blue), points)
        XCTAssertEqual(curve.points(.rgb), ToneCurve.linear)
        XCTAssertEqual(ToneCurve.maxPoints, 16)
        XCTAssertEqual(EditOperation.Kind.levels(levels).defaultLabel, "Levels")
    }

    func testIdentityToneTables() {
        let lut = ToneLUT.make(levels: .identity, curve: .identity)
        XCTAssertEqual(lut.red.count, 256)
        XCTAssertTrue(lut.isIdentity)
        XCTAssertEqual(CurveSpline.evaluate(ToneCurve.linear, at: 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(CurveSpline.table([], count: 3), [0, 0.5, 1])
        XCTAssertFalse(ToneLUT.make(levels: Levels(rgb: Levels.Channel(gamma: 1.4)), curve: .identity).isIdentity)
    }

    func testCurveDragsAndLevelsDragsAreOneStepEach() {
        var stack = EditStack()
        var curve = ToneCurve.identity
        for step in 1...60 {
            curve.setPoints([ToneCurve.Point(0, 0), ToneCurve.Point(0.5, 0.5 + Double(step) / 300), ToneCurve.Point(1, 1)], for: .rgb)
            stack.setTone(.toneCurve(curve))
        }
        XCTAssertEqual(stack.operations.count, 1)
        XCTAssertEqual(stack.resolvedUserToneCurve?.rgb[1].output ?? 0, 0.7, accuracy: 1e-9)
        stack.setColor(.colorMixer(ColorMixer()))
        stack.setTone(.toneCurve(.identity))
        XCTAssertEqual(stack.operations.count, 3, "a curve after another edit is a new step")
    }

    func testHistogramCountsPixels() {
        // Two pixels: pure red and white.
        let histogram = Histogram.compute(rgba: [255, 0, 0, 255, 255, 255, 255, 255], width: 2, height: 1)
        XCTAssertEqual(histogram.total, 2)
        XCTAssertEqual(histogram.red[255], 2)
        XCTAssertEqual(histogram.green[0], 1)
        XCTAssertEqual(histogram.luma[255], 1)
        // Both pixels clip in red; luma clips for the white one only. The worst channel counts.
        XCTAssertEqual(histogram.clipping.highlights, 1)
        XCTAssertEqual(histogram.clipping.shadows, 0.5, "green and blue are crushed in the red pixel")
        XCTAssertEqual(Histogram.binCount, 256)
    }
}
