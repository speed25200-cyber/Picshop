import XCTest
@testable import PicshopImaging

/// Depth maps: percentile normalisation, the portrait rotation, 16-bit samples and half floats (W2, D10).
/// Pure Swift, runs on Linux.
final class DepthMathTests: XCTestCase {
    func testPercentileNormalisationMapsTheFirstAndNinetyNinthPercentilesToZeroAndOne() {
        // 0…999 with two outliers that must not stretch the range.
        var values = (0..<1000).map { Float($0) }
        values[0] = -50_000
        values[999] = 80_000
        let normalised = DepthMath.normalized(values)
        let p1 = DepthMath.percentile(values, 0.01), p99 = DepthMath.percentile(values, 0.99)
        XCTAssertEqual(p1, 10, accuracy: 1)
        XCTAssertEqual(p99, 989, accuracy: 1)
        XCTAssertEqual(normalised[0], 0, "outliers clamp")
        XCTAssertEqual(normalised[999], 1)
        XCTAssertEqual(normalised[500], (500 - p1) / (p99 - p1), accuracy: 1e-5)
        // Monotone: nearer stays nearer.
        for index in 1..<999 { XCTAssertGreaterThanOrEqual(normalised[index], normalised[index - 1]) }
    }

    func testNormalisationCanFlipAndHandlesFlatMapsAndNaN() {
        let values: [Float] = [0, 1, 2, 3, .nan]
        let flipped = DepthMath.normalized(values, nearIsLarger: false, low: 0, high: 1)
        XCTAssertEqual(flipped[0], 1)
        XCTAssertEqual(flipped[3], 0)
        XCTAssertEqual(flipped[4], 0, "NaN is far")
        XCTAssertEqual(DepthMath.normalized([4, 4, 4]), [0.5, 0.5, 0.5])
        XCTAssertEqual(DepthMath.normalized([]), [])
    }

    func testThePortraitRotationRoundTrips() {
        let width = 3, height = 5
        let plane = (0..<(width * height)).map { $0 }
        let turned = DepthMath.rotatedClockwise(plane, width: width, height: height)
        // Clockwise: the source's top-left pixel lands top-right of a plane `height` wide.
        XCTAssertEqual(turned[height - 1], plane[0])
        // The source's bottom-left lands top-left.
        XCTAssertEqual(turned[0], plane[(height - 1) * width])
        XCTAssertEqual(DepthMath.rotatedCounterClockwise(turned, width: height, height: width), plane)
        XCTAssertTrue(DepthMath.needsRotation(width: 3024, height: 4032))
        XCTAssertFalse(DepthMath.needsRotation(width: 4032, height: 3024))
    }

    func testSixteenBitPackingIsBigEndianAndRoundTrips() {
        let values: [Float] = [0, 1, 0.5, 0.25, 2, -1, .nan]
        let bytes = DepthMath.pack16(values)
        XCTAssertEqual(bytes.count, values.count * 2)
        XCTAssertEqual(Array(bytes[2...3]), [0xFF, 0xFF], "1 is 65535, big-endian")
        XCTAssertEqual(Array(bytes[4...5]), [0x80, 0x00], "0.5 is 32768")
        let back = DepthMath.unpack16(bytes)
        XCTAssertEqual(back[0], 0)
        XCTAssertEqual(back[1], 1)
        XCTAssertEqual(back[2], 0.5, accuracy: 1 / 65535)
        XCTAssertEqual(back[3], 0.25, accuracy: 1 / 65535)
        XCTAssertEqual(back[4], 1, "clamped")
        XCTAssertEqual(back[5], 0, "clamped")
        XCTAssertEqual(back[6], 0, "NaN")
        // Every 16-bit level survives.
        let ramp = (0..<65536).map { Float($0) / 65535 }
        XCTAssertEqual(DepthMath.unpack16(DepthMath.pack16(ramp)), ramp)
    }

    func testHalfFloatsDecode() {
        XCTAssertEqual(DepthMath.float(fromHalf: 0x0000), 0)
        XCTAssertEqual(DepthMath.float(fromHalf: 0x3C00), 1)
        XCTAssertEqual(DepthMath.float(fromHalf: 0xC000), -2)
        XCTAssertEqual(DepthMath.float(fromHalf: 0x3555), 0.333251953125)
        XCTAssertEqual(DepthMath.float(fromHalf: 0x7BFF), 65504)
        XCTAssertEqual(DepthMath.float(fromHalf: 0x0001), 5.960464477539063e-8, "the smallest subnormal")
        XCTAssertEqual(DepthMath.float(fromHalf: 0x7C00), .infinity)
        XCTAssertTrue(DepthMath.float(fromHalf: 0x7E00).isNaN)
        let plane = DepthMath.floats(fromHalfPlane: [0x3C00, 0x0000, 0xFFFF, 0x4000, 0x3800, 0xFFFF], width: 2, height: 2, rowStride: 3)
        XCTAssertEqual(plane, [1, 0, 2, 0.5], "row padding is skipped")
    }

    func testResamplingKeepsARampMonotoneAndItsEnds() {
        let ramp = (0..<10).map { Float($0) / 9 }
        let up = DepthMath.resampled(ramp, width: 10, height: 1, toWidth: 37, toHeight: 3)
        XCTAssertEqual(up.count, 37 * 3)
        XCTAssertEqual(up[0], 0, accuracy: 1e-6)
        XCTAssertEqual(up[36], 1, accuracy: 1e-6)
        for x in 1..<37 { XCTAssertGreaterThanOrEqual(up[x], up[x - 1]) }
    }
}
