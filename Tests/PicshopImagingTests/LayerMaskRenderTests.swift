#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D8 on the GPU: a linked mask stack lives in the layer's content space and moves with it; an unlinked one stays on
/// the canvas; a disabled one is ignored; the legacy mask and the stack multiply.
final class LayerMaskRenderTests: XCTestCase {
    private let width = 160, height = 100
    private let side = 40

    /// A point of the layer's quad at content coordinates (u, v), 0…1 from the top-left (bilinear: exact for affine maps).
    private func point(_ quad: [PSPoint], _ u: Double, _ v: Double) -> (x: Int, y: Int) {
        let top = PSPoint(x: quad[0].x + (quad[1].x - quad[0].x) * u, y: quad[0].y + (quad[1].y - quad[0].y) * u)
        let bottom = PSPoint(x: quad[3].x + (quad[2].x - quad[3].x) * u, y: quad[3].y + (quad[2].y - quad[3].y) * u)
        let x = (top.x + (bottom.x - top.x) * v) * Double(width)
        let y = (top.y + (bottom.y - top.y) * v) * Double(height)
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    /// Whether the red layer shows at (u, v) of its content in `document`.
    private func showsLayer(_ fixture: LayerFixtures.Project, _ document: PhotoDocument, layer: Layer, at samples: [(Double, Double)]) async throws -> [Bool] {
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        XCTAssertEqual(rendered.width, width)
        let values = LayerFixtures.straight(rendered.bytes)
        let quad = LayerPlacement.quad(for: layer, contentSize: PSSize(width: Double(side), height: Double(side)), canvasSize: document.canvasSize, isBase: false)
        return samples.map { sample in
            let p = point(quad, sample.0, sample.1)
            let pixel = LayerFixtures.pixel(values, width: width, x: min(width - 1, max(0, p.x)), y: min(height - 1, max(0, p.y)))
            return pixel[0] > 0.6 && pixel[1] < 0.4
        }
    }

    private func redLayer(_ fixture: LayerFixtures.Project, centre: PSPoint) throws -> Layer {
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.1, 0.1, width: side, height: side), width: side, height: side)
        return Layer(name: "Rouge", content: .image(asset), transform: LayerTransform(center: centre, scale: 1, rotation: 0))
    }

    private func project() throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(1, 1, 1, width: width, height: height))
    }

    /// The content's left and right quarters, half-way down.
    private let leftAndRight: [(Double, Double)] = [(0.25, 0.5), (0.75, 0.5)]

    func testALinkedStackMovesWithItsLayer() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var layer = try redLayer(fixture, centre: PSPoint(x: 0.3, y: 0.5))
        // Content space: the left half of the layer is kept.
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: side, height: side), width: side, height: side)
        layer.isMaskLinked = true
        for (centre, rotation) in [(PSPoint(x: 0.3, y: 0.5), 0.0), (PSPoint(x: 0.7, y: 0.45), 0.0), (PSPoint(x: 0.55, y: 0.5), 30.0)] {
            var moved = layer
            moved.transform = LayerTransform(center: centre, scale: 1.2, rotation: rotation)
            var document = fixture.document
            document.layers.append(moved)
            let shows = try await showsLayer(fixture, document, layer: moved, at: leftAndRight)
            XCTAssertEqual(shows, [true, false], "the mask keeps the layer's own left half at \(centre), \(rotation)°")
        }
    }

    func testAnUnlinkedStackStaysOnTheCanvas() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var layer = try redLayer(fixture, centre: PSPoint(x: 0.25, y: 0.5))
        // Canvas space: the canvas's left half is kept, wherever the layer goes.
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: width, height: height), width: width, height: height)
        layer.isMaskLinked = false
        var document = fixture.document
        document.layers.append(layer)
        let onTheLeft = try await showsLayer(fixture, document, layer: layer, at: leftAndRight)
        XCTAssertEqual(onTheLeft, [true, true], "inside the kept half")
        var moved = layer
        moved.transform = LayerTransform(center: PSPoint(x: 0.75, y: 0.5), scale: 1, rotation: 0)
        document.layers[document.layers.count - 1] = moved
        let onTheRight = try await showsLayer(fixture, document, layer: moved, at: leftAndRight)
        XCTAssertEqual(onTheRight, [false, false], "moved out of the kept half, the layer is hidden")
        // Straddling the edge: only the part over the canvas's left half shows.
        moved.transform = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1, rotation: 0)
        document.layers[document.layers.count - 1] = moved
        let straddling = try await showsLayer(fixture, document, layer: moved, at: leftAndRight)
        XCTAssertEqual(straddling, [true, false])
    }

    func testADisabledStackIsIgnored() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var layer = try redLayer(fixture, centre: PSPoint(x: 0.5, y: 0.5))
        layer.maskStack = try fixture.stack([UInt8](repeating: 0, count: side * side), width: side, height: side)
        layer.isMaskEnabled = false
        var document = fixture.document
        document.layers.append(layer)
        let shows = try await showsLayer(fixture, document, layer: layer, at: leftAndRight)
        XCTAssertEqual(shows, [true, true], "a disabled mask hides nothing")
        layer.isMaskEnabled = true
        document.layers[document.layers.count - 1] = layer
        let enabled = try await showsLayer(fixture, document, layer: layer, at: leftAndRight)
        XCTAssertEqual(enabled, [false, false], "enabled again, the empty mask hides the layer")
    }

    func testTheLegacyMaskAndTheStackMultiply() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var layer = try redLayer(fixture, centre: PSPoint(x: 0.5, y: 0.5))
        layer.transform = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1.5, rotation: 0)
        // Legacy: the top half; stack: the left half. Only the top-left quarter shows.
        var top = [UInt8](repeating: 0, count: side * side)
        for y in 0..<(side / 2) { for x in 0..<side { top[y * side + x] = 255 } }
        layer.mask = try MaskStore(store: fixture.store, projectID: fixture.projectID).save(bytes: top, width: side, height: side, source: .brush, feather: 0)
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: side, height: side), width: side, height: side)
        var document = fixture.document
        document.layers.append(layer)
        let shows = try await showsLayer(fixture, document, layer: layer, at: [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)])
        XCTAssertEqual(shows, [true, false, false, false])
    }
}
#endif
