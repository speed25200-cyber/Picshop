import XCTest
@testable import PicshopCore

/// D10: the placement map against an independent pixel-space simulation of the W1 compositing (content centred on
/// its fitted size, flipped, scaled, sheared, turned, then moved to its centre), the inverse, text layers, the output
/// sizes against the renderer simulation of W2's MaskGeometry tests, and affineTransform(fromQuad:) round trips.
final class LayerPlacementTests: XCTestCase {
    private let canvas = PSSize(width: 4000, height: 3000)
    private let content = PSSize(width: 1200, height: 1600)

    /// The W1 composite maths written out step by step on one content point (u, v ∈ 0…1, top-left origin).
    private func simulate(_ point: PSPoint, transform: LayerTransform, center: PSPoint, rotation: Double, content: PSSize, canvas: PSSize) -> PSPoint {
        let fit = min(canvas.width / content.width, canvas.height / content.height, 1)
        // 1. Content pixels about the content's centre.
        var x = point.x * content.width - content.width / 2
        var y = point.y * content.height - content.height / 2
        // 2. Flips.
        if transform.isFlippedHorizontally { x = -x }
        if transform.isFlippedVertically { y = -y }
        // 3. Fitted size × scale × the per-axis scales.
        x *= fit * transform.scale * transform.scaleX
        y *= fit * transform.scale * transform.scaleY
        // 4. Shear: x moves by tan(kx)·y, then y by tan(ky)·x (of the scaled point).
        let kx = tan(transform.skewX * .pi / 180), ky = tan(transform.skewY * .pi / 180)
        let sheared = (x: x + kx * y, y: ky * x + y)
        // 5. Rotation, clockwise on screen for a positive angle (y down).
        let r = rotation * .pi / 180
        let turned = (x: cos(r) * sheared.x - sin(r) * sheared.y, y: sin(r) * sheared.x + cos(r) * sheared.y)
        // 6. To the centre, normalised.
        return PSPoint(x: center.x + turned.x / canvas.width, y: center.y + turned.y / canvas.height)
    }

    private var cases: [(String, LayerTransform)] {
        [
            ("uniform", LayerTransform(center: PSPoint(x: 0.4, y: 0.6), scale: 0.7)),
            ("rotation 37°", LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 0.5, rotation: 37)),
            ("flips", LayerTransform(center: PSPoint(x: 0.3, y: 0.2), scale: 0.9, rotation: -20, isFlippedHorizontally: true, isFlippedVertically: true)),
            ("horizontal flip", LayerTransform(center: PSPoint(x: 0.6, y: 0.7), scale: 0.4, rotation: 110, isFlippedHorizontally: true)),
            ("sx ≠ sy", LayerTransform(center: PSPoint(x: 0.55, y: 0.45), scale: 0.6, rotation: 15, scaleX: 1.8, scaleY: 0.6)),
            ("skew", LayerTransform(center: PSPoint(x: 0.5, y: 0.4), scale: 0.8, rotation: -30, scaleX: 1.2, skewX: 20, skewY: -10)),
        ]
    }

    func testTheMapMatchesThePixelSimulation() {
        let probes = RasterRef.unitCorners + [PSPoint(x: 0.5, y: 0.5), PSPoint(x: 0.2, y: 0.9)]
        for (name, transform) in cases {
            let layer = Layer(name: name, content: .image(MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: content)), transform: transform)
            let map = LayerPlacement.map(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
            for probe in probes {
                let expected = simulate(probe, transform: transform, center: transform.center, rotation: transform.rotation, content: content, canvas: canvas)
                let mapped = map.apply(probe)
                XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-6, "\(name) \(probe)")
                XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-6, "\(name) \(probe)")
            }
            let quad = LayerPlacement.quad(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
            XCTAssertEqual(quad.count, 4)
            let box = LayerPlacement.bounds(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
            XCTAssertEqual(box.minX, quad.map(\.x).min()!, accuracy: 1e-15)
            XCTAssertEqual(box.maxY, quad.map(\.y).max()!, accuracy: 1e-15)
        }
    }

    func testAQuadWinsAndMapsTheCornersAndTheCentreToTheDiagonals() throws {
        let quad = [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.5, y: 0.15), PSPoint(x: 0.45, y: 0.5), PSPoint(x: 0.12, y: 0.4)]
        let layer = Layer(name: "q", content: .image(MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: content)),
                          transform: LayerTransform(center: PSPoint(x: 0.9, y: 0.9), scale: 3, rotation: 50, quad: quad))
        let map = LayerPlacement.map(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
        for (corner, expected) in zip(RasterRef.unitCorners, quad) {
            XCTAssertEqual(map.apply(corner).x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(map.apply(corner).y, expected.y, accuracy: 1e-9)
        }
        // A projective map sends the square's centre to where the quad's diagonals cross.
        let p = quad[0], r = quad[2], q = quad[1], s = quad[3]
        let d1 = PSPoint(x: r.x - p.x, y: r.y - p.y), d2 = PSPoint(x: s.x - q.x, y: s.y - q.y)
        let t = ((q.x - p.x) * d2.y - (q.y - p.y) * d2.x) / (d1.x * d2.y - d1.y * d2.x)
        let crossing = PSPoint(x: p.x + t * d1.x, y: p.y + t * d1.y)
        XCTAssertEqual(map.apply(PSPoint(x: 0.5, y: 0.5)).x, crossing.x, accuracy: 1e-9)
        XCTAssertEqual(map.apply(PSPoint(x: 0.5, y: 0.5)).y, crossing.y, accuracy: 1e-9)
        // A degenerate quad is ignored; the base is the identity.
        var flat = layer
        flat.transform.quad = [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.2, y: 0.1), PSPoint(x: 0.3, y: 0.1), PSPoint(x: 0.4, y: 0.1)]
        XCTAssertNotEqual(LayerPlacement.map(for: flat, contentSize: content, canvasSize: canvas, isBase: false).apply(PSPoint(x: 0, y: 0)).y, 0.1)
        XCTAssertEqual(LayerPlacement.map(for: layer, contentSize: content, canvasSize: canvas, isBase: true), .identity)
    }

    func testTheInverseComposesToTheIdentity() throws {
        var random = MaskTestRandom(seed: 37)
        for (name, transform) in cases {
            let layer = Layer(name: name, content: .image(MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: content)), transform: transform)
            let map = LayerPlacement.map(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
            let inverse = try XCTUnwrap(LayerPlacement.inverseMap(for: layer, contentSize: content, canvasSize: canvas, isBase: false))
            for _ in 0..<20 {
                let point = PSPoint(x: Double(random.next() % 1000) / 1000, y: Double(random.next() % 1000) / 1000)
                let back = inverse.apply(map.apply(point))
                XCTAssertEqual(back.x, point.x, accuracy: 1e-9, name)
                XCTAssertEqual(back.y, point.y, accuracy: 1e-9, name)
            }
        }
    }

    func testATextLayerUsesItsElementsCentreAndRotation() {
        let element = TextElement(text: "Soldes", center: PSPoint(x: 0.2, y: 0.3), rotation: 30)
        let layer = Layer(name: "Soldes", content: .text(element), transform: LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1.5, rotation: 0))
        let size = PSSize(width: 600, height: 200)
        let map = LayerPlacement.map(for: layer, contentSize: size, canvasSize: canvas, isBase: false)
        let centre = map.apply(PSPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(centre.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(centre.y, 0.3, accuracy: 1e-12)
        let expected = simulate(PSPoint(x: 1, y: 0), transform: layer.transform, center: element.center, rotation: 30, content: size, canvas: canvas)
        XCTAssertEqual(map.apply(PSPoint(x: 1, y: 0)).x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(map.apply(PSPoint(x: 1, y: 0)).y, expected.y, accuracy: 1e-9)
        XCTAssertEqual(LayerPlacement.textPlacement(of: layer).rotation, 30)
        let effective = LayerPlacement.effectiveTransform(of: layer)
        XCTAssertEqual(effective.center, element.center)
        XCTAssertEqual(effective.rotation, 30)
        XCTAssertEqual(effective.scale, 1.5)
        // Sizes: an image from its asset, a shape from its canvas-relative size, a fill is the canvas, a text unknown.
        XCTAssertNil(LayerPlacement.contentSize(of: layer, canvasSize: canvas))
        let shape = Layer(name: "s", content: .shape(ShapeElement(kind: .rectangle, relativeSize: PSSize(width: 0.25, height: 0.5))))
        XCTAssertEqual(LayerPlacement.contentSize(of: shape, canvasSize: canvas), PSSize(width: 1000, height: 1500))
        XCTAssertEqual(LayerPlacement.contentSize(of: Layer(name: "f", content: .fill(.red)), canvasSize: canvas), canvas)
    }

    func testOutputSizesMatchTheRendererExtents() {
        let kinds: [EditOperation.Kind] = [
            .crop(PSRect(x: 0.1, y: 0.2, width: 0.5, height: 0.7)), .crop(PSRect(x: -0.2, y: 0.5, width: 0.9, height: 0.8)),
            .rotate(degrees: 90), .rotate(degrees: -90), .rotate(degrees: 180), .rotate(degrees: 30), .rotate(degrees: -47),
            .straighten(degrees: 5), .straighten(degrees: -12.5), .straighten(degrees: 44),
            .flip(.horizontal), .flip(.vertical),
            .perspective(horizontal: 0.4, vertical: 0), .perspective(horizontal: -0.3, vertical: 0.5), .perspective(horizontal: 0, vertical: -1),
            .expand(PSRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)), .upscale(factor: 2),
        ]
        for kind in kinds {
            for aspect in [0.75, 1, 1.5] {
                var simulation = RendererSimulation(aspect: aspect, points: [])
                simulation.apply(kind)
                let size = kind.outputPixelSize(from: PSSize(width: 1000 * aspect, height: 1000))
                XCTAssertEqual(size.width, simulation.extent.w, accuracy: 0.5 + 1e-9, "\(kind) at \(aspect)")
                XCTAssertEqual(size.height, simulation.extent.h, accuracy: 0.5 + 1e-9, "\(kind) at \(aspect)")
                XCTAssertEqual(size.width, size.width.rounded())
            }
        }
        // A chain, and kinds that change nothing.
        let stack = EditStack(operations: [EditOperation(kind: .crop(PSRect(x: 0, y: 0, width: 0.5, height: 1))), EditOperation(kind: .rotate(degrees: 90)),
                                           EditOperation(kind: .adjust(.exposure, value: 0.5)), EditOperation(kind: .upscale(factor: 2))])
        XCTAssertEqual(stack.outputSize(sourcePixels: PSSize(width: 4000, height: 3000)), PSSize(width: 6000, height: 4000))
        XCTAssertEqual(EditOperation.Kind.adjust(.exposure, value: 0.5).outputPixelSize(from: canvas), canvas)
    }

    func testAffineTransformFromQuadRoundTrips() throws {
        let transforms = cases.map(\.1) + [
            LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1, rotation: 0),
            LayerTransform(center: PSPoint(x: 0.2, y: 0.8), scale: 0.3, rotation: 200, isFlippedVertically: true, scaleY: 2.5),
            LayerTransform(center: PSPoint(x: 0.7, y: 0.3), scale: 1.4, rotation: 89, skewX: -35),
        ]
        for transform in transforms {
            let layer = Layer(name: "r", content: .image(MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: content)), transform: transform)
            let quad = LayerPlacement.quad(for: layer, contentSize: content, canvasSize: canvas, isBase: false)
            let decomposed = try XCTUnwrap(LayerPlacement.affineTransform(fromQuad: quad, contentSize: content, canvasSize: canvas), "\(transform)")
            XCTAssertNil(decomposed.quad)
            var again = layer
            again.transform = decomposed
            let back = LayerPlacement.quad(for: again, contentSize: content, canvasSize: canvas, isBase: false)
            for (a, b) in zip(back, quad) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "\(transform)")
                XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "\(transform)")
            }
            // With the transform itself as the hint, the representation comes back as it was.
            let kept = try XCTUnwrap(LayerPlacement.affineTransform(fromQuad: quad, contentSize: content, canvasSize: canvas, preferring: transform))
            XCTAssertEqual(kept.scale, transform.scale, accuracy: 1e-9)
            XCTAssertEqual(kept.rotation, transform.rotation, accuracy: 1e-9)
            XCTAssertEqual(kept.scaleX, transform.scaleX, accuracy: 1e-9)
            XCTAssertEqual(kept.skewX, transform.skewX, accuracy: 1e-9)
            XCTAssertEqual(kept.isFlippedHorizontally, transform.isFlippedHorizontally)
        }
        // The canonical form: a plain rotation-scale quad gives scale and rotation, skew 0, no flip.
        let plain = Layer(name: "p", content: .image(MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: content)),
                          transform: LayerTransform(center: PSPoint(x: 0.4, y: 0.6), scale: 0.8, rotation: 25))
        let quad = LayerPlacement.quad(for: plain, contentSize: content, canvasSize: canvas, isBase: false)
        let canonical = try XCTUnwrap(LayerPlacement.affineTransform(fromQuad: quad, contentSize: content, canvasSize: canvas))
        XCTAssertEqual(canonical.scale, 0.8, accuracy: 1e-12)
        XCTAssertEqual(canonical.rotation, 25, accuracy: 1e-12)
        XCTAssertEqual(canonical.skewX, 0)
        XCTAssertEqual(canonical.center.x, 0.4, accuracy: 1e-12)
        // Not a parallelogram: nil.
        let trapezoid = [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.5, y: 0.15), PSPoint(x: 0.45, y: 0.5), PSPoint(x: 0.12, y: 0.4)]
        XCTAssertNil(LayerPlacement.affineTransform(fromQuad: trapezoid, contentSize: content, canvasSize: canvas))
    }
}
