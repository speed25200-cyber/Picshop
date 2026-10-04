#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// W3: a local adjustment on an image layer other than the base works in that layer's content space: it acts only
/// inside its mask, which moves with the layer, and its overlay lands where it acts.
final class NonBaseLocalAdjustTests: XCTestCase {
    private let width = 200, height = 150
    private let side = 64

    private var options: PhotoRenderer.Options {
        PhotoRenderer.Options(targetLongestSide: Double(width), includeOverlays: true, allowExpensiveWork: true)
    }

    /// A grey layer, turned and moved, with a local adjustment on its content's left half.
    private func document(_ fixture: LayerFixtures.Project, transform: LayerTransform) throws -> (PhotoDocument, Layer, LocalAdjustment) {
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.4, 0.4, 0.4, width: side, height: side), width: side, height: side)
        let layer = Layer(name: "Gris", content: .image(asset), transform: transform)
        document.layers.append(layer)
        let adjustment = LocalAdjustment(stack: try fixture.stack(LayerFixtures.halfMask(width: side, height: side), width: side, height: side),
                                         adjustments: Adjustments([.exposure: 1]))
        document.apply(.localAdjust(adjustment), to: layer.id)
        guard let placed = document.layer(id: layer.id) else { throw PicshopError.objectNotFound("layer") }
        return (document, placed, adjustment)
    }

    private func point(_ quad: [PSPoint], _ u: Double, _ v: Double) -> (x: Int, y: Int) {
        let top = PSPoint(x: quad[0].x + (quad[1].x - quad[0].x) * u, y: quad[0].y + (quad[1].y - quad[0].y) * u)
        let bottom = PSPoint(x: quad[3].x + (quad[2].x - quad[3].x) * u, y: quad[3].y + (quad[2].y - quad[3].y) * u)
        return (Int(((top.x + (bottom.x - top.x) * v) * Double(width)).rounded(.down)), Int(((top.y + (bottom.y - top.y) * v) * Double(height)).rounded(.down)))
    }

    func testTheAdjustmentActsOnlyInsideItsMaskPlacedWithTheLayer() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(0.15, 0.15, 0.15, width: width, height: height))
        defer { fixture.cleanup() }
        for transform in [LayerTransform(center: PSPoint(x: 0.4, y: 0.5), scale: 0.8, rotation: 30),
                          LayerTransform(center: PSPoint(x: 0.65, y: 0.45), scale: 0.6, rotation: -15, isFlippedHorizontally: true)] {
            let (document, layer, _) = try document(fixture, transform: transform)
            let rendered = try await fixture.renderer.renderedRGBA(document, options: options)
            let quad = LayerPlacement.quad(for: layer, contentSize: PSSize(width: Double(side), height: Double(side)), canvasSize: document.canvasSize, isBase: false)
            let inside = point(quad, 0.25, 0.5), outside = point(quad, 0.75, 0.5)
            let lit = LayerFixtures.pixel(rendered.bytes, width: width, x: inside.x, y: inside.y)
            let plain = LayerFixtures.pixel(rendered.bytes, width: width, x: outside.x, y: outside.y)
            XCTAssertEqual(Double(plain[0]), 0.4 * 255, accuracy: 3, "outside the mask: the layer as it is (\(transform.rotation)°)")
            XCTAssertGreaterThan(lit[0], plain[0] + 40, "inside the mask: brighter (\(transform.rotation)°)")
            // The base is untouched.
            XCTAssertEqual(Double(LayerFixtures.pixel(rendered.bytes, width: width, x: 2, y: 2)[0]), 0.15 * 255, accuracy: 2)
        }
    }

    func testTheOverlayAlignsWithWhereTheAdjustmentActs() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(0.15, 0.15, 0.15, width: width, height: height))
        defer { fixture.cleanup() }
        let (document, layer, adjustment) = try document(fixture, transform: LayerTransform(center: PSPoint(x: 0.45, y: 0.55), scale: 0.9, rotation: 35))
        var without = document
        without.update(layerID: layer.id) { drawn in
            drawn.edits.operations.removeAll { operation in
                if case .localAdjust = operation.kind { return true }
                return false
            }
        }
        let plain = try await fixture.renderer.renderedRGBA(without, options: options)
        let rendered = try await fixture.renderer.renderedRGBA(document, options: options,
                                                               overlay: MaskOverlayRequest(target: .localAdjustment(adjustment.id), style: .tint, opacity: 1))
        guard let overlay = rendered.overlay else { return XCTFail("no overlay") }
        XCTAssertEqual(rendered.width, width)
        // Where the adjustment acts (brighter than without it) and where the overlay is: the same place.
        var acts = (x: 0.0, y: 0.0, n: 0.0), shown = (x: 0.0, y: 0.0, n: 0.0)
        var both = 0, either = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let isActing = Int(rendered.frame[i]) - Int(plain.bytes[i]) > 20
                let isShown = overlay[i + 3] > 127
                if isActing { acts = (acts.x + Double(x), acts.y + Double(y), acts.n + 1) }
                if isShown { shown = (shown.x + Double(x), shown.y + Double(y), shown.n + 1) }
                if isActing && isShown { both += 1 }
                if isActing || isShown { either += 1 }
            }
        }
        XCTAssertGreaterThan(acts.n, 200, "the adjustment acts on a visible area")
        XCTAssertGreaterThan(shown.n, 200, "the overlay shows")
        let dx = acts.x / max(1, acts.n) - shown.x / max(1, shown.n), dy = acts.y / max(1, acts.n) - shown.y / max(1, shown.n)
        XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), 1.5, "the overlay sits where the adjustment acts")
        XCTAssertGreaterThan(Double(both) / Double(max(1, either)), 0.9, "and covers the same pixels")
    }
}
#endif
