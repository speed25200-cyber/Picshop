import XCTest
@testable import PicshopImaging

final class SelectionTests: XCTestCase {
    private func image(width: Int, height: Int) -> [UInt8] {
        // Left half red, right half blue, with a green square in the red half.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let inSquare = x >= 10 && x < 20 && y >= 10 && y < 20
                let (r, g, b): (UInt8, UInt8, UInt8) = inSquare ? (30, 200, 40) : (x < width / 2 ? (220, 40, 40) : (40, 40, 220))
                rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b
            }
        }
        return rgba
    }

    func testMagicWandSelectsContiguousColour() {
        let width = 64, height = 40
        let mask = Selection.magicWand(rgba: image(width: width, height: height), width: width, height: height, seed: (0.1, 0.9), tolerance: 0.2)
        XCTAssertEqual(mask[36 * width + 5], 255, "red region selected")
        XCTAssertEqual(mask[15 * width + 15], 0, "green square excluded")
        XCTAssertEqual(mask[20 * width + 60], 0, "blue half excluded")
        let selected = mask.filter { $0 == 255 }.count
        XCTAssertEqual(selected, width / 2 * height - 100)
    }

    func testMagicWandGlobalMode() {
        let width = 64, height = 40
        var rgba = image(width: width, height: height)
        // A second red island on the far right.
        for y in 30..<35 { for x in 55..<60 { let i = (y * width + x) * 4; rgba[i] = 220; rgba[i + 1] = 40; rgba[i + 2] = 40 } }
        let contiguous = Selection.magicWand(rgba: rgba, width: width, height: height, seed: (0.1, 0.9), tolerance: 0.2)
        let global = Selection.magicWand(rgba: rgba, width: width, height: height, seed: (0.1, 0.9), tolerance: 0.2, contiguous: false)
        XCTAssertEqual(contiguous[32 * width + 57], 0)
        XCTAssertEqual(global[32 * width + 57], 255)
    }

    func testLassoFillsPolygon() {
        let width = 50, height = 50
        let mask = Selection.lasso(points: [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)], width: width, height: height)
        XCTAssertEqual(mask[25 * width + 25], 255)
        XCTAssertEqual(mask[5 * width + 5], 0)
        XCTAssertEqual(mask[45 * width + 25], 0)
        let count = mask.filter { $0 == 255 }.count
        XCTAssertEqual(count, 900, accuracy: 60)
    }

    func testDespeckle() {
        let width = 20, height = 20
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 5..<15 { for x in 5..<15 { mask[y * width + x] = 255 } }
        mask[0] = 255
        mask[1] = 255
        let cleaned = Selection.despeckled(mask, width: width, height: height, minimumPixels: 5)
        XCTAssertEqual(cleaned[0], 0)
        XCTAssertEqual(cleaned[10 * width + 10], 255)
    }
}
