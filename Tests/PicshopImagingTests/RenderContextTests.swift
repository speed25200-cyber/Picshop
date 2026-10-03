#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
@testable import PicshopImaging

/// Background readbacks never share the canvas's context: they run at low GPU
/// priority with no intermediate cache, so they cannot evict the canvas's bitmap.
final class RenderContextTests: XCTestCase {
    func testBackgroundIsLowPriorityWithoutCache() {
        let options = RenderContext.options(name: "Picshop.background", cacheIntermediates: false, lowPriority: true)
        XCTAssertEqual(options[.priorityRequestLow] as? Bool, true)
        XCTAssertEqual(options[.cacheIntermediates] as? Bool, false)
        XCTAssertEqual(options[.name] as? String, "Picshop.background")
    }

    func testCanvasCachesAndIsNotLowPriority() {
        let options = RenderContext.options(name: "Picshop.canvas", cacheIntermediates: true, lowPriority: false)
        XCTAssertEqual(options[.cacheIntermediates] as? Bool, true)
        XCTAssertNil(options[.priorityRequestLow])
        XCTAssertNotNil(options[.workingColorSpace])
    }

    func testTheContextsAreSeparate() {
        XCTAssertFalse(RenderContext.interactive === RenderContext.background)
        XCTAssertFalse(RenderContext.interactive === RenderContext.shared)
        XCTAssertFalse(RenderContext.background === RenderContext.shared)
        XCTAssertFalse(RenderContext.background === RenderContext.export)
    }

    func testReadbacksDefaultToTheBackgroundContext() throws {
        // A readback draws through the background context and still reads upright pixels.
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = try XCTUnwrap(ImageSupport.rgbaBytes(of: image))
        XCTAssertGreaterThan(bytes[0], 200)
        XCTAssertLessThan(bytes[1], 60)
    }
}
#endif
