import XCTest
@testable import PicshopImaging

final class PatchMatchTests: XCTestCase {
    /// Builds an RGBA image with a repeating diagonal stripe texture.
    private func stripes(width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let band = ((x + y) / 8) % 3
                let (r, g, b): (UInt8, UInt8, UInt8) = band == 0 ? (220, 60, 40) : (band == 1 ? (40, 160, 220) : (240, 220, 80))
                let i = (y * width + x) * 4
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = 255
            }
        }
        return rgba
    }

    func testFillsHoleWithSurroundingTexture() {
        let width = 96, height = 96
        let original = stripes(width: width, height: height)
        var mask = [UInt8](repeating: 0, count: width * height)
        var corrupted = original
        for y in 36..<60 {
            for x in 30..<66 {
                mask[y * width + x] = 255
                let i = (y * width + x) * 4
                corrupted[i] = 0; corrupted[i + 1] = 0; corrupted[i + 2] = 0
            }
        }
        let filled = PatchMatchCore.inpaint(rgba: corrupted, mask: mask, width: width, height: height, patchRadius: 3, iterationsPerLevel: [6, 5, 4])
        XCTAssertEqual(filled.count, original.count)

        // Untouched pixels are byte-identical.
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 0 {
                let i = (y * width + x) * 4
                XCTAssertEqual(filled[i], original[i])
                XCTAssertEqual(filled[i + 1], original[i + 1])
            }
        }
        // Hole pixels approximate the periodic texture much better than the black corruption did.
        var errorFilled = 0.0
        var errorCorrupted = 0.0
        var holes = 0.0
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] != 0 {
                let i = (y * width + x) * 4
                for c in 0..<3 {
                    errorFilled += abs(Double(filled[i + c]) - Double(original[i + c]))
                    errorCorrupted += abs(Double(corrupted[i + c]) - Double(original[i + c]))
                }
                holes += 3
            }
        }
        let meanFilled = errorFilled / holes
        let meanCorrupted = errorCorrupted / holes
        XCTAssertLessThan(meanFilled, meanCorrupted * 0.5, "mean error \(meanFilled) vs corrupted \(meanCorrupted)")
        XCTAssertLessThan(meanFilled, 60, "fill should look like the surrounding stripes, mean abs error \(meanFilled)")
        // Result is fully opaque and not flat black.
        let holeIndex = (48 * width + 48) * 4
        XCTAssertEqual(filled[holeIndex + 3], 255)
        XCTAssertGreaterThan(Int(filled[holeIndex]) + Int(filled[holeIndex + 1]) + Int(filled[holeIndex + 2]), 60)
    }

    func testNoMaskReturnsInput() {
        let width = 16, height = 16
        let original = stripes(width: width, height: height)
        let mask = [UInt8](repeating: 0, count: width * height)
        XCTAssertEqual(PatchMatchCore.inpaint(rgba: original, mask: mask, width: width, height: height), original)
    }

    func testSmoothGradientFill() {
        let width = 64, height = 64
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = UInt8(x * 4); rgba[i + 1] = UInt8(y * 4); rgba[i + 2] = 128
            }
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 24..<40 { for x in 24..<40 { mask[y * width + x] = 255 } }
        let filled = PatchMatchCore.inpaint(rgba: rgba, mask: mask, width: width, height: height, patchRadius: 2, iterationsPerLevel: [5, 4, 3])
        let center = (32 * width + 32) * 4
        // Expect roughly the gradient value (128, 128) ± tolerance.
        XCTAssertEqual(Double(filled[center]), 128, accuracy: 40)
        XCTAssertEqual(Double(filled[center + 1]), 128, accuracy: 40)
    }
}
