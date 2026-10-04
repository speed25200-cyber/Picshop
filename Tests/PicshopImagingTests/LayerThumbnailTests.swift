#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Layers column thumbnails (§4.11): a layer alone, a group's isolated composite, none for adjustment layers and
/// solid fills, and mask thumbnails in the layer's content space.
final class LayerThumbnailTests: XCTestCase {
    private let width = 176, height = 132
    private let side = 88

    private func project() throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height,
                                  base: LayerFixtures.quadrants([(0.8, 0.3, 0.2), (0.2, 0.7, 0.3), (0.3, 0.3, 0.8), (0.9, 0.9, 0.3)], width: width, height: height))
    }

    /// `document` drawn at the thumbnail's size: 88 × 66 for this 4:3 canvas, centred in the 88 square (rows 11…76).
    private func reference(_ fixture: LayerFixtures.Project, _ document: PhotoDocument) async throws -> [UInt8] {
        let rendered = try await fixture.renderer.renderedRGBA(document, options: PhotoRenderer.Options(targetLongestSide: Double(side), allowExpensiveWork: false))
        XCTAssertEqual(rendered.width, side)
        XCTAssertEqual(rendered.height, 66)
        var square = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0..<rendered.height {
            let from = row * rendered.width * 4
            let to = (row + 11) * side * 4
            square.replaceSubrange(to..<(to + rendered.width * 4), with: rendered.bytes[from..<(from + rendered.width * 4)])
        }
        return square
    }

    private func assertClose(_ got: [UInt8]?, _ want: [UInt8], _ label: String) {
        guard let got else { return XCTFail("\(label): no thumbnail") }
        XCTAssertEqual(got.count, want.count, label)
        var worst = 0
        for (a, b) in zip(got, want) { worst = max(worst, abs(Int(a) - Int(b))) }
        XCTAssertLessThanOrEqual(worst, 3, "\(label): worst \(worst)/255")
    }

    /// The document with only `ids` drawn (the base hidden unless listed) onto transparent.
    private func alone(_ document: PhotoDocument, keeping ids: Set<UUID>) -> PhotoDocument {
        var alone = document
        alone.backgroundColor = .clear
        alone.layers = document.layers.compactMap { layer in
            if ids.contains(layer.id) { return layer }
            guard layer.id == document.baseLayerID else { return nil }
            var hidden = layer
            hidden.isVisible = false
            return hidden
        }
        return alone
    }

    func testALayerThumbnailIsTheLayerDrawnAlone() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.5, 0.1, alpha: 0.8, width: 60, height: 40), width: 60, height: 40)
        var layer = Layer(name: "Orange", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.6, y: 0.4), scale: 0.6, rotation: 25))
        // Drawn at full opacity, in normal mode, without its mask: those are the row's.
        layer.opacity = 0.4
        layer.blendMode = .multiply
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: 60, height: 40), width: 60, height: 40)
        document.layers.append(layer)
        let thumbnail = try await fixture.renderer.layerThumbnailRGBA(layer.id, in: document, side: side)
        var plain = layer
        plain.opacity = 1
        plain.blendMode = .normal
        plain.maskStack = nil
        var drawn = document
        drawn.layers[drawn.layers.count - 1] = plain
        let want = try await reference(fixture, alone(drawn, keeping: [plain.id]))
        assertClose(thumbnail, want, "image layer")
        // The base's thumbnail is the photo.
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        let base = try await fixture.renderer.layerThumbnailRGBA(baseID, in: document, side: side)
        assertClose(base, try await reference(fixture, alone(document, keeping: [baseID])), "base")
    }

    func testAGroupsThumbnailIsItsIsolatedComposite() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let group = Layer(name: "Groupe", content: .group(LayerFolder(passThrough: true)), opacity: 0.5)
        let red = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.2, 0.2, width: 40, height: 40), width: 40, height: 40)
        let blue = try fixture.imageAsset(LayerFixtures.solid(0.2, 0.3, 0.9, alpha: 0.7, width: 40, height: 40), width: 40, height: 40)
        var bottom = Layer(name: "Rouge", content: .image(red), transform: LayerTransform(center: PSPoint(x: 0.4, y: 0.5), scale: 0.7))
        bottom.parentID = group.id
        var top = Layer(name: "Bleu", content: .image(blue), transform: LayerTransform(center: PSPoint(x: 0.6, y: 0.5), scale: 0.7))
        top.parentID = group.id
        top.blendMode = .multiply
        document.layers += [bottom, top, group]
        let thumbnail = try await fixture.renderer.layerThumbnailRGBA(group.id, in: document, side: side)
        // The reference: the group isolated, at full opacity, its children as they are.
        var isolated = document
        isolated.update(layerID: group.id) { layer in
            layer.opacity = 1
            layer.content = .group(LayerFolder(passThrough: false))
        }
        let want = try await reference(fixture, alone(isolated, keeping: [group.id, bottom.id, top.id]))
        assertClose(thumbnail, want, "group")
    }

    func testAdjustmentLayersAndSolidFillsHaveNone() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        let adjustment = Layer(name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.3])))
        let fill = Layer(name: "Couleur", content: .fill(PSColor(red: 0.2, green: 0.6, blue: 0.4)))
        let gradient = Layer(name: "Dégradé", content: .gradientFill(GradientFill(style: .linear, stops: [
            GradientStop(location: 0, color: PSColor(red: 0, green: 0, blue: 0)), GradientStop(location: 1, color: PSColor(red: 1, green: 1, blue: 1))],
            angle: 0, dither: false)))
        document.layers += [adjustment, fill, gradient]
        let none = try await fixture.renderer.layerThumbnailRGBA(adjustment.id, in: document, side: side)
        XCTAssertNil(none)
        let swatch = try await fixture.renderer.layerThumbnailRGBA(fill.id, in: document, side: side)
        XCTAssertNil(swatch)
        let ramp = try await fixture.renderer.layerThumbnailRGBA(gradient.id, in: document, side: side)
        XCTAssertNotNil(ramp, "a gradient has its picture")
    }

    func testAMaskThumbnailFollowsTheContentSpace() async throws {
        // A 2:1 canvas and a square layer: a linked mask's thumbnail is square, an unlinked one 2:1.
        let fixture = try LayerFixtures.project(width: 200, height: 100, base: LayerFixtures.solid(0.5, 0.5, 0.5, width: 200, height: 100))
        defer { fixture.cleanup() }
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.9, 0.9, width: 60, height: 60), width: 60, height: 60)
        var layer = Layer(name: "Carré", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.7, y: 0.5), scale: 0.5, rotation: 40))
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: 60, height: 60), width: 60, height: 60)
        document.layers.append(layer)
        guard let linked = try await fixture.renderer.layerMaskThumbnailBytes(layer.id, in: document, side: 88) else { return XCTFail("no mask thumbnail") }
        XCTAssertEqual(linked.width, linked.height, "the layer's own square, whatever its turn")
        let row = linked.height / 2
        XCTAssertGreaterThan(linked.bytes[row * linked.width + linked.width / 4], 240, "kept: the content's left half")
        XCTAssertLessThan(linked.bytes[row * linked.width + linked.width * 3 / 4], 15)

        document.update(layerID: layer.id) { $0.isMaskLinked = false }
        guard let unlinked = try await fixture.renderer.layerMaskThumbnailBytes(layer.id, in: document, side: 88) else { return XCTFail("no mask thumbnail") }
        XCTAssertEqual(unlinked.width, 88)
        XCTAssertEqual(unlinked.height, 44, "the canvas's 2:1")
        let none = try await fixture.renderer.layerMaskThumbnailBytes(fixture.document.baseLayerID ?? layer.id, in: fixture.document, side: 88)
        XCTAssertNil(none, "no mask, no thumbnail")
    }
}
#endif
