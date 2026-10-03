#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Clone, paint and heal strokes are drawn into their mask once; text is drawn once and only placed after.
final class StrokeCacheTests: XCTestCase {
    private let width = 256, height = 192

    private func strokes(_ count: Int) -> [BrushStroke] {
        (0..<count).map { index in
            let y = 0.05 + 0.9 * Double(index) / Double(count)
            return BrushStroke(points: (0...20).map { PSPoint(x: 0.1 + 0.8 * Double($0) / 20, y: y) }, radius: 0.01, hardness: 1)
        }
    }

    private func cloneDocument(_ fixture: (renderer: PhotoRenderer, document: PhotoDocument, store: ProjectStore, projectID: UUID, root: URL), strokes count: Int) -> PhotoDocument {
        var document = fixture.document
        document.apply(.cloneStamp(strokes: strokes(count), offset: PSPoint(x: 0.05, y: 0)))
        return document
    }

    func testASecondRenderDrawsNoStroke() async throws {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(90, width: width, height: height), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let document = cloneDocument(fixture, strokes: 50)
        _ = try await fixture.renderer.renderedRGBA(document)
        let first = await fixture.renderer.strokeRasterizations
        XCTAssertEqual(first, 50)
        _ = try await fixture.renderer.renderedRGBA(document)
        let second = await fixture.renderer.strokeRasterizations
        XCTAssertEqual(second, first, "0 rasterizations on the second render")
        // A paint step on top draws its own strokes once, and the clone's none.
        var painted = document
        painted.apply(.pixelPaint(strokes: strokes(3), color: .red))
        _ = try await fixture.renderer.renderedRGBA(painted)
        _ = try await fixture.renderer.renderedRGBA(painted)
        let third = await fixture.renderer.strokeRasterizations
        XCTAssertEqual(third, first + 3)
    }

    func testRenderTimeBarelyGrowsWithTheStrokeCount() async throws {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(90, width: width, height: height), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        func averageTime(_ document: PhotoDocument) async throws -> Double {
            _ = try await fixture.renderer.renderedRGBA(document)
            let start = Date()
            for _ in 0..<5 { _ = try await fixture.renderer.renderedRGBA(document) }
            return Date().timeIntervalSince(start) / 5
        }
        let few = try await averageTime(cloneDocument(fixture, strokes: 5))
        let many = try await averageTime(cloneDocument(fixture, strokes: 50))
        print("STROKE-CACHE render 5 strokes \(Int(few * 1000)) ms, 50 strokes \(Int(many * 1000)) ms")
        // Rasterized every render, ten times the strokes would cost several times more; cached,
        // the cost stays flat. The bound leaves room for a loaded runner's noise (the exact
        // count of rasterizations is asserted above).
        XCTAssertLessThan(many, few * 2 + 0.005)
    }

    #if canImport(UIKit)
    func testMovingATextLayerDrawsItsTextOnce() async throws {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(90, width: width, height: height), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let text = Layer(name: "Title", content: .text(TextElement(text: "Bonjour")))
        document.addLayer(text)
        _ = try await fixture.renderer.renderedRGBA(document)
        let drawn = await fixture.renderer.overlayRasterizations
        for step in 1...10 {
            document.update(layerID: text.id) { layer in
                layer.textElement?.center = PSPoint(x: 0.3 + Double(step) * 0.03, y: 0.4)
                layer.textElement?.rotation = Double(step) * 3
            }
            _ = try await fixture.renderer.renderedRGBA(document)
        }
        let after = await fixture.renderer.overlayRasterizations
        XCTAssertEqual(after, drawn, "a drag places the same raster")
    }
    #endif
}
#endif
