import XCTest
@testable import PicshopImaging

final class RegionMaskTests: XCTestCase {
    /// Blue sky gradient on top, green grass at the bottom, a blue box in the middle of the grass.
    private func landscape(width: Int, height: Int) -> [UInt8] {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if y < height / 2 {
                    rgba[i] = UInt8(90 + y / 2); rgba[i + 1] = UInt8(150 + y / 3); rgba[i + 2] = 235
                } else {
                    rgba[i] = 60; rgba[i + 1] = 150; rgba[i + 2] = 50
                }
                // Blue shirt in the grass: must not count as sky.
                if y > height * 3 / 4, y < height * 7 / 8, x > width / 3, x < width / 2 {
                    rgba[i] = 80; rgba[i + 1] = 120; rgba[i + 2] = 230
                }
            }
        }
        return rgba
    }

    func testSkyMaskCoversTopOnly() {
        let width = 120, height = 80
        let mask = RegionMask.mask(kind: .sky, rgba: landscape(width: width, height: height), width: width, height: height)
        XCTAssertEqual(mask.count, width * height)
        XCTAssertEqual(mask[10 * width + 60], 255, "sky pixel selected")
        XCTAssertEqual(mask[70 * width + 20], 0, "grass not selected")
        XCTAssertEqual(mask[65 * width + 50], 0, "blue shirt disconnected from the top is rejected")
        let coverage = RegionMask.coverage(mask)
        XCTAssertEqual(coverage, 0.5, accuracy: 0.05)
        let box = RegionMask.boundingBox(mask, width: width, height: height)
        XCTAssertEqual(box?.y ?? 1, 0, accuracy: 0.02)
        XCTAssertEqual(box?.h ?? 0, 0.5, accuracy: 0.06)
    }

    func testGrassMaskCoversBottom() {
        let width = 120, height = 80
        let mask = RegionMask.mask(kind: .grass, rgba: landscape(width: width, height: height), width: width, height: height)
        XCTAssertEqual(mask[70 * width + 20], 255)
        XCTAssertEqual(mask[10 * width + 60], 0)
        XCTAssertGreaterThan(RegionMask.coverage(mask), 0.35)
    }
}
