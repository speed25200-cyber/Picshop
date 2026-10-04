import XCTest
@testable import PicshopCore

/// D10b: every layer moves with the photo when the base is cropped, turned, flipped, straightened, expanded, upscaled
/// or re-framed. The photo's own source corners land where its geometry chain (checked against the renderer in W2's
/// MaskGeometryTests) sends them; a layer via copy made before the edits must land exactly there.
final class LayerFollowsBaseTests: XCTestCase {
    private typealias W3 = W3Documents

    private func chainMap(_ document: PhotoDocument) -> PSHomography {
        let base = document.baseLayer!
        return base.edits.geometryChain(sourceAspect: base.imageAsset!.pixelSize.aspectRatio).map
    }

    private func placedQuad(_ layer: Layer, in document: PhotoDocument) -> [PSPoint] {
        let size = LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize)!
        return LayerPlacement.quad(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
    }

    /// The square crop `setAspect 1:1` lowers to on the current canvas.
    private func squareCrop(_ canvas: PSSize) -> EditOperation.Kind {
        if canvas.width >= canvas.height {
            let width = canvas.height / canvas.width
            return .crop(PSRect(x: (1 - width) / 2, y: 0, width: width, height: 1))
        }
        let height = canvas.width / canvas.height
        return .crop(PSRect(x: 0, y: (1 - height) / 2, width: 1, height: height))
    }

    func testTheCropToolTargetsThePhotoWhileAViaCopyLayerIsSelected() throws {
        // The session's crop, turn and flip pass the base: untargeted, they would land on the selected via-copy layer
        // (its own content space) and the canvas would never change.
        var document = W3.base(92, title: "crop tool")
        let region = MaskStack(components: [MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))])
        let via = try XCTUnwrap(document.applyStructureEdit(.viaCopy(source: document.baseLayerID!, region: region, name: nil)).layerID)
        XCTAssertEqual(document.selectedLayerID, via)
        XCTAssertEqual(document.activeImageLayerID, via, "untargeted geometry would go to the via-copy layer")
        let canvas = document.canvasSize
        XCTAssertTrue(document.apply(.crop(PSRect(x: 0.2, y: 0, width: 0.6, height: 1)), to: document.baseLayerID))
        XCTAssertNotEqual(document.canvasSize, canvas)
        let expected = RasterRef.unitCorners.map(chainMap(document).apply)
        for (got, want) in zip(placedQuad(try XCTUnwrap(document.layer(id: via)), in: document), expected) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
    }

    func testAViaCopyLayerStaysOnThePhotoThroughEveryGeometricEdit() throws {
        var document = W3.base(91, title: "follow")
        let region = MaskStack(components: [MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))])
        let via = try XCTUnwrap(document.applyStructureEdit(.viaCopy(source: document.baseLayerID!, region: region, name: nil)).layerID)
        let baseID = document.baseLayerID!
        let steps: [(String, (PSSize) -> EditOperation.Kind)] = [
            ("crop 4:5", { _ in .crop(PSRect(x: 0.2, y: 0, width: 0.6, height: 1)) }),
            ("quarter turn", { _ in .rotate(degrees: 90) }),
            ("flip", { _ in .flip(.horizontal) }),
            ("straighten 7°", { _ in .straighten(degrees: 7) }),
            ("expand 20 %", { _ in .expand(PSRect(x: 0.1, y: 0.1, width: 1 / 1.2, height: 1 / 1.2)) }),
            ("upscale 2×", { _ in .upscale(factor: 2) }),
            ("setAspect 1:1", { canvas in self.squareCrop(canvas) }),
        ]
        for (name, kind) in steps {
            XCTAssertTrue(document.apply(kind(document.canvasSize), to: baseID), name)
            let map = chainMap(document)
            let expected = RasterRef.unitCorners.map(map.apply)
            let layer = try XCTUnwrap(document.layer(id: via))
            let quad = placedQuad(layer, in: document)
            for (got, want) in zip(quad, expected) {
                XCTAssertEqual(got.x, want.x, accuracy: 1e-9, name)
                XCTAssertEqual(got.y, want.y, accuracy: 1e-9, name)
            }
            // The canvas is the base's developed size.
            XCTAssertEqual(document.canvasSize, document.baseLayer!.edits.outputSize(sourcePixels: W3.asset.pixelSize), name)
        }
        // Undoing to the import brings it back to the canvas corners.
        let restored = document.restoredToImport()
        let back = placedQuad(try XCTUnwrap(restored.layer(id: via)), in: restored)
        for (got, want) in zip(back, RasterRef.unitCorners) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
    }

    func testACropOffThePixelGridKeepsTheViaCopyOnTheRenderersPixels() throws {
        // 0.54 × 240 = 129.6 px: the renderer keeps 130 whole pixels from x = 48 (`pixelCrop`), and the stored crop is
        // those pixels, so after a quarter turn the copy maps every source pixel onto a whole canvas pixel (scale 1),
        // not 130 / 129.6 of it (TransformRenderTests on the GPU).
        let small = MediaAsset(kind: .image, relativePath: "media/small.png", pixelSize: PSSize(width: 240, height: 180))
        var document = PhotoDocument(title: "grid", baseImage: small)
        let baseID = try XCTUnwrap(document.baseLayerID)
        let region = MaskStack(components: [MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))])
        let via = try XCTUnwrap(document.applyStructureEdit(.viaCopy(source: baseID, region: region, name: nil)).layerID)
        let requested = PSRect(x: 0.2, y: 0.05, width: 0.54, height: 0.9)
        let pixels = try XCTUnwrap(EditOperation.Kind.pixelCrop(requested, in: small.pixelSize))
        XCTAssertEqual(pixels, PSRect(x: 48, y: 9, width: 130, height: 162))
        XCTAssertTrue(document.apply(.crop(requested), to: baseID))
        XCTAssertEqual(document.canvasSize, PSSize(width: 130, height: 162))
        let stored = try XCTUnwrap(document.baseLayer?.edits.resolvedCrop)
        XCTAssertEqual(stored.width * 240, 130, accuracy: 1e-9)
        XCTAssertEqual(EditOperation.Kind.snappedCrop(stored, in: small.pixelSize), stored, "idempotent")
        XCTAssertTrue(document.apply(.rotate(degrees: 90), to: baseID))
        XCTAssertEqual(document.canvasSize, PSSize(width: 162, height: 130))
        // The renderer: crop, then a clockwise quarter turn of 130 × 162, (x, y) → (162 − y, x).
        let want = [(0.0, 0.0), (240.0, 0.0), (240.0, 180.0), (0.0, 180.0)].map { PSPoint(x: 162 - ($0.1 - 9), y: $0.0 - 48) }
        let quad = placedQuad(try XCTUnwrap(document.layer(id: via)), in: document)
        for (got, want) in zip(quad, want) {
            XCTAssertEqual(got.x * 162, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y * 130, want.y, accuracy: 1e-9)
        }
    }

    func testATextLayerKeepsItsPixelSizeAndItsPlace() throws {
        var document = W3.base(92, title: "text")
        let text = W3.text(9202, "Soldes", center: PSPoint(x: 0.3, y: 0.4))
        document.layers.append(text)
        let element = try XCTUnwrap(text.textElement)
        let baseID = document.baseLayerID!
        // Crop the top half: the canvas height halves, the text keeps its pixel height and its spot on the photo.
        let before = document
        document.apply(.crop(PSRect(x: 0, y: 0, width: 1, height: 0.5)), to: baseID)
        var moved = try XCTUnwrap(document.layer(id: text.id)?.textElement)
        XCTAssertEqual(moved.relativeSize * document.canvasSize.height, element.relativeSize * before.canvasSize.height, accuracy: 1e-9)
        XCTAssertEqual(moved.center.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(moved.center.y, 0.8, accuracy: 1e-12)
        XCTAssertEqual(moved.rotation, 0)
        // A quarter turn: the text turns with the photo and keeps its pixel size.
        let turnedFrom = document
        document.apply(.rotate(degrees: 90), to: baseID)
        let map = try XCTUnwrap(chainMap(turnedFrom).inverse).then(chainMap(document))
        moved = try XCTUnwrap(document.layer(id: text.id)?.textElement)
        let previous = try XCTUnwrap(turnedFrom.layer(id: text.id)?.textElement)
        XCTAssertEqual(moved.center.x, map.apply(previous.center).x, accuracy: 1e-12)
        XCTAssertEqual(moved.center.y, map.apply(previous.center).y, accuracy: 1e-12)
        XCTAssertEqual(abs(moved.rotation), 90, accuracy: 1e-9, "a quarter turn either way, as the photo turned")
        XCTAssertEqual(moved.relativeSize * document.canvasSize.height, previous.relativeSize * turnedFrom.canvasSize.height, accuracy: 1e-9)
        XCTAssertEqual(moved.maxRelativeWidth * document.canvasSize.width, previous.maxRelativeWidth * turnedFrom.canvasSize.width, accuracy: 1e-9)
        // A mirror does not mirror the words.
        let flippedFrom = document
        document.apply(.flip(.horizontal), to: baseID)
        XCTAssertEqual(document.layer(id: text.id)?.textElement?.rotation, flippedFrom.layer(id: text.id)?.textElement?.rotation)
    }

    func testAGradientsCentreAndAnUnlinkedMaskFollow() throws {
        var document = W3.base(93, title: "gradient")
        let gradient = GradientFill(style: .radial, stops: [GradientStop(location: 0, color: .black), GradientStop(location: 1, color: .clear)],
                                    angle: 0, scale: 50, center: PSPoint(x: 0.6, y: 0.3))
        var masked = W3.image(9303, "Logo", W3.logo)
        masked.maskStack = W3.stack
        masked.isMaskLinked = false
        var linked = W3.image(9304, "Tasse")
        linked.maskStack = W3.stack
        document.layers += [Layer(id: W3.id(9302), name: "Dégradé", content: .gradientFill(gradient)), masked, linked]
        let before = document
        document.apply(.crop(PSRect(x: 0.5, y: 0, width: 0.5, height: 1)), to: document.baseLayerID!)
        let map = try XCTUnwrap(chainMap(before).inverse).then(chainMap(document))
        guard case .gradientFill(let moved) = document.layer(id: W3.id(9302))?.content else { return XCTFail("a gradient") }
        XCTAssertEqual(moved.center.x, map.apply(gradient.center).x, accuracy: 1e-12)
        XCTAssertEqual(moved.center.y, 0.3, accuracy: 1e-12)
        XCTAssertEqual(moved.angle, 0, accuracy: 1e-9)
        guard case .radial(let spec) = document.layer(id: masked.id)?.maskStack?.components.first?.kind else { return XCTFail("radial") }
        XCTAssertEqual(spec.center.x, map.apply(PSPoint(x: 0.4, y: 0.5)).x, accuracy: 1e-12)
        XCTAssertEqual(spec.center.x, -0.2, accuracy: 1e-12)
        // A linked mask lives in the layer's content: unchanged.
        XCTAssertEqual(document.layer(id: linked.id)?.maskStack, W3.stack)
    }

    func testALayerPushedOffTheCanvasIsKept() throws {
        var document = W3.base(94, title: "off")
        let corner = W3.image(9402, "Coin", W3.logo, transform: LayerTransform(center: PSPoint(x: 0.9, y: 0.9), scale: 0.1))
        document.layers.append(corner)
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5)), to: document.baseLayerID!)
        let layer = try XCTUnwrap(document.layer(id: corner.id))
        XCTAssertEqual(layer.transform.center.x, 1.8, accuracy: 1e-12)
        XCTAssertEqual(layer.transform.center.y, 1.8, accuracy: 1e-12)
        XCTAssertTrue(placedQuad(layer, in: document).allSatisfy { $0.x > 1 && $0.y > 1 })
        XCTAssertEqual(document.layers.count, 2)
    }

    func testLocksDoNotStopTheFollowAndNonBaseGeometryMovesNothingElse() throws {
        var document = W3.base(95, title: "locks")
        var locked = W3.image(9502, "Verrou", W3.logo, transform: LayerTransform(center: PSPoint(x: 0.25, y: 0.5), scale: 0.3))
        locked.isLocked = true
        let other = W3.image(9503, "Autre", W3.cup, transform: LayerTransform(center: PSPoint(x: 0.75, y: 0.5), scale: 0.3))
        document.layers += [locked, other]
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 1)), to: document.baseLayerID!)
        XCTAssertEqual(document.layer(id: locked.id)?.transform.center.x ?? 0, 0.5, accuracy: 1e-12)
        // A crop of a non-base layer moves no other layer and keeps the canvas.
        let canvas = document.canvasSize
        let before = document.layer(id: locked.id)
        XCTAssertTrue(document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5)), to: other.id))
        XCTAssertEqual(document.canvasSize, canvas)
        XCTAssertEqual(document.layer(id: locked.id), before)
    }
}
