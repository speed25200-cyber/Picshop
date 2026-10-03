#if canImport(CoreImage)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// The colour-cube cache: least recently used (a hot cube survives a drag), small
/// cubes while dragging, and a `.cube` file parsed once however often it is used.
final class ColorCubeCacheTests: XCTestCase {
    private let picture = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))

    func testAHotKeySurvivesThirtyInserts() {
        let cache = ColorCube(capacity: 24)
        _ = cache.cube(for: -1) { (2, ColorCube.identity2) }
        for key in 0..<30 {
            _ = cache.cube(for: key) { (2, ColorCube.identity2) }
            // The colour match of the clip on screen is used every frame.
            _ = cache.cube(for: -1) { XCTFail("the hot cube was evicted at insert \(key)"); return (2, ColorCube.identity2) }
        }
        XCTAssertTrue(cache.contains(-1))
        XCTAssertFalse(cache.contains(0), "the coldest cube went")
    }

    func testFirstInFirstOutIsGone() {
        let cache = ColorCube(capacity: 3)
        for key in 0..<3 { _ = cache.cube(for: key) { (2, ColorCube.identity2) } }
        _ = cache.cube(for: 0) { (2, ColorCube.identity2) }
        _ = cache.cube(for: 3) { (2, ColorCube.identity2) }
        XCTAssertTrue(cache.contains(0), "a hit moved it to the back")
        XCTAssertFalse(cache.contains(1))
    }

    func testDragsBake17AndSettledFrames33() {
        let cache = ColorCube()
        let mixer = ColorMixer(saturation: [0, 0, 0, 0, 0, 0.4])
        _ = cache.apply(mixer: mixer, grade: nil, to: picture, interactive: true)
        XCTAssertEqual(cache.lastDimension, ColorCube.interactiveDimension)
        _ = cache.apply(mixer: mixer, grade: nil, to: picture, interactive: false)
        XCTAssertEqual(cache.lastDimension, ColorCube.settledDimension)
        _ = cache.apply(mixer: mixer, grade: nil, to: picture, interactive: true)
        XCTAssertEqual(cache.lastDimension, ColorCube.settledDimension, "the sharp cube, once baked, serves the drag too")
    }

    func testParallelBakeMatchesTheEngine() {
        let grade = ColorGrade(shadows: ColorWheel(hue: 210, amount: 0.3, luminance: 0))
        let parallel = ColorCube.bakeConcurrently(mixer: nil, grade: grade, dimension: 9)
        let serial = ColorEngine.cube(mixer: nil, grade: grade, dimension: 9)
        XCTAssertEqual(parallel.count, serial.count)
        for index in parallel.indices { XCTAssertEqual(parallel[index], serial[index], accuracy: 1e-6) }
    }

    func testACubeFileIsParsedOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("look-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(Double(r) * 0.9) \(Double(g)) \(Double(b))\n" } } }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let cache = ColorCube()
        for _ in 0..<100 { _ = cache.apply(lutAt: url, intensity: 1, to: picture) }
        XCTAssertEqual(cache.fileParses, 1)
        XCTAssertEqual(cache.lastDimension, 2)
    }
}
#endif
