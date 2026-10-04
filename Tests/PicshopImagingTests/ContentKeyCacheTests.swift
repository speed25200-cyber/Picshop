#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// A fill engine that paints the hole green and counts its runs.
final class CountingInpainter: Inpainter, @unchecked Sendable {
    let name = "counting"
    let preferredLongestSide = 256
    private let lock = NSLock()
    private var runs = 0

    var count: Int { lock.withLock { runs } }

    func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        lock.withLock { runs += 1 }
        var out = rgba
        for index in 0..<(width * height) where mask[index] > 127 {
            out[index * 4] = 0
            out[index * 4 + 1] = 255
            out[index * 4 + 2] = 0
            out[index * 4 + 3] = 255
        }
        return out
    }
}

/// D12: expensive results are keyed by what they depend on (the source and the operations up to them), so later dials,
/// other layers and undo never recompute them, and a change before them always does.
final class ContentKeyCacheTests: XCTestCase {
    private let width = 96, height = 64

    private func project(_ engine: CountingInpainter) throws -> (LayerFixtures.Project, MaskReference) {
        let base = LayerFixtures.quadrants([(0.8, 0.2, 0.2), (0.2, 0.7, 0.3), (0.2, 0.3, 0.8), (0.7, 0.7, 0.2)], width: width, height: height)
        let fixture = try LayerFixtures.project(width: width, height: height, base: base, inpainting: InpaintingPipeline(neural: engine, fallback: engine))
        var hole = [UInt8](repeating: 0, count: width * height)
        for y in 24..<40 { for x in 40..<56 { hole[y * width + x] = 255 } }
        let mask = try MaskStore(store: fixture.store, projectID: fixture.projectID).save(bytes: hole, width: width, height: height, source: .brush, feather: 0)
        return (fixture, mask)
    }

    private func withEdits(_ document: PhotoDocument, _ operations: [EditOperation.Kind]) -> PhotoDocument {
        var document = document
        guard let baseID = document.baseLayerID else { return document }
        document.update(layerID: baseID) { $0.edits = EditStack(operations: operations.map { EditOperation(kind: $0) }) }
        return document
    }

    func testAnEraseIsComputedOnceAcrossADialDrag() async throws {
        let engine = CountingInpainter()
        let (fixture, mask) = try project(engine)
        defer { fixture.cleanup() }
        for step in 0...12 {
            let exposure = Double(step) * 0.05
            let document = withEdits(fixture.document, [.removeObject(mask), .adjust(.exposure, value: exposure)])
            _ = try await fixture.renderer.renderedRGBA(document, options: .full)
        }
        XCTAssertEqual(engine.count, 1, "the dials after the erase never recompute it")
        // The erase really is in the picture: the hole is green.
        let document = withEdits(fixture.document, [.removeObject(mask)])
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        let centre = LayerFixtures.pixel(rendered.bytes, width: rendered.width, x: 48, y: 32)
        XCTAssertGreaterThan(centre[1], 200)
        XCTAssertLessThan(centre[0], 60)
        XCTAssertEqual(engine.count, 1)
    }

    func testReorderingACropBeforeTheEraseRecomputesItAndUndoHitsTheCache() async throws {
        let engine = CountingInpainter()
        let (fixture, mask) = try project(engine)
        defer { fixture.cleanup() }
        let crop = EditOperation.Kind.crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let eraseFirst = withEdits(fixture.document, [.removeObject(mask), crop])
        let cropFirst = withEdits(fixture.document, [crop, .removeObject(mask)])
        _ = try await fixture.renderer.renderedRGBA(eraseFirst, options: .full)
        XCTAssertEqual(engine.count, 1)
        _ = try await fixture.renderer.renderedRGBA(cropFirst, options: .full)
        XCTAssertEqual(engine.count, 2, "a crop moved before the erase changes its input: recomputed")
        _ = try await fixture.renderer.renderedRGBA(eraseFirst, options: .full)
        XCTAssertEqual(engine.count, 2, "undoing the reorder finds the first result again")
        _ = try await fixture.renderer.renderedRGBA(cropFirst, options: .full)
        XCTAssertEqual(engine.count, 2, "and redoing it finds the second")
    }

    func testAnotherLayersVisibilityRecomputesNothing() async throws {
        let engine = CountingInpainter()
        let (fixture, mask) = try project(engine)
        defer { fixture.cleanup() }
        var document = withEdits(fixture.document, [.removeObject(mask)])
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.2, 0.2, 0.9, alpha: 0.5, width: 32, height: 32), width: 32, height: 32)
        let other = Layer(name: "Autre", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.25, y: 0.3), scale: 1, rotation: 0))
        document.layers.append(other)
        _ = try await fixture.renderer.renderedRGBA(document, options: .full)
        let runs = await fixture.renderer.expensiveRuns
        XCTAssertEqual(engine.count, 1)
        for visible in [false, true, false, true] {
            document.update(layerID: other.id) { $0.isVisible = visible }
            _ = try await fixture.renderer.renderedRGBA(document, options: .full)
        }
        // A move of the other layer neither.
        document.update(layerID: other.id) { $0.transform = LayerTransform(center: PSPoint(x: 0.7, y: 0.6), scale: 1.3, rotation: 15) }
        _ = try await fixture.renderer.renderedRGBA(document, options: .full)
        XCTAssertEqual(engine.count, 1, "the photo's erase does not depend on another layer")
        let after = await fixture.renderer.expensiveRuns
        XCTAssertEqual(after, runs, "no expensive work at all")
    }

    /// The content key is the same for equal content and differs when an operation before the result changes.
    func testOperationKeysChainTheSteps() throws {
        let engine = CountingInpainter()
        let (fixture, mask) = try project(engine)
        defer { fixture.cleanup() }
        guard let asset = fixture.document.baseLayer?.imageAsset else { return XCTFail("no base") }
        let erase = EditOperation(kind: .removeObject(mask))
        let dimmer = EditOperation(kind: .adjust(.exposure, value: 0.2))
        let brighter = EditOperation(kind: .adjust(.exposure, value: 0.4))
        let a = RenderKeys.operationKeys(source: asset, edits: EditStack(operations: [erase, dimmer]))
        let b = RenderKeys.operationKeys(source: asset, edits: EditStack(operations: [erase, brighter]))
        let c = RenderKeys.operationKeys(source: asset, edits: EditStack(operations: [dimmer, erase]))
        XCTAssertNotNil(a[erase.id])
        XCTAssertEqual(a[erase.id], b[erase.id], "the erase's key ignores the later dial")
        XCTAssertNotEqual(a[dimmer.id], b[brighter.id])
        XCTAssertNotEqual(a[erase.id], c[erase.id], "an exposure before the erase changes its key")
    }
}
#endif
