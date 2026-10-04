import XCTest
@testable import PicshopCore

/// D3 and §5 items 4–5: each geometric edit's map of normalised points equals what the renderer does to the
/// pixels (checked against an independent simulation of `PhotoRenderer` in Core Image's bottom-left pixel space),
/// homographies invert and compose, and remapped masks stay on the same pixels.
final class MaskGeometryTests: XCTestCase {
    private let aspects = [0.75, 1, 1.5]

    private var geometricKinds: [EditOperation.Kind] {
        [
            .crop(PSRect(x: 0.1, y: 0.2, width: 0.5, height: 0.7)),
            .crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)),
            .crop(PSRect(x: -0.2, y: 0.5, width: 0.9, height: 0.8)),
            .rotate(degrees: 90), .rotate(degrees: -90), .rotate(degrees: 180), .rotate(degrees: 270), .rotate(degrees: 30), .rotate(degrees: -47),
            .straighten(degrees: 5), .straighten(degrees: -12.5), .straighten(degrees: 44),
            .flip(.horizontal), .flip(.vertical),
            .perspective(horizontal: 0.4, vertical: 0), .perspective(horizontal: -0.3, vertical: 0.5),
            .perspective(horizontal: 0.2, vertical: -0.6), .perspective(horizontal: 0, vertical: -1),
            .expand(PSRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)), .expand(PSRect(x: 0, y: 0.25, width: 1, height: 0.5)),
            .upscale(factor: 2),
        ]
    }

    /// Points to follow: the unit corners, the centre and two inner points.
    private let probes = RasterRef.unitCorners + [PSPoint(x: 0.5, y: 0.5), PSPoint(x: 0.2, y: 0.7), PSPoint(x: 0.9, y: 0.15)]

    // MARK: Maps against the renderer

    func testEveryKindMapsLikeTheRenderer() throws {
        for kind in geometricKinds {
            for aspect in aspects {
                var simulation = RendererSimulation(aspect: aspect, points: probes)
                simulation.apply(kind)
                let map = kind.geometryMap(aspectBefore: aspect) ?? .identity
                for (index, probe) in probes.enumerated() {
                    let expected = simulation.normalizedPoint(index)
                    let mapped = map.apply(probe)
                    XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-6, "\(kind) at \(aspect): \(probe)")
                    XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-6, "\(kind) at \(aspect): \(probe)")
                }
                XCTAssertEqual(kind.aspect(after: aspect), simulation.aspect, accuracy: 1e-9, "\(kind) at \(aspect)")
            }
        }
    }

    func testAChainMapsLikeTheRenderer() {
        let kinds: [EditOperation.Kind] = [.rotate(degrees: 90), .crop(PSRect(x: 0.1, y: 0, width: 0.8, height: 0.6)), .flip(.horizontal),
                                           .straighten(degrees: 4), .adjust(.exposure, value: 0.3), .perspective(horizontal: 0.2, vertical: 0.1),
                                           .expand(PSRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)), .upscale(factor: 2)]
        var stack = EditStack()
        for kind in kinds { stack.append(kind) }
        stack.setLocalAdjustment(LocalAdjustment(stack: MaskStack()))
        for aspect in aspects {
            var simulation = RendererSimulation(aspect: aspect, points: probes)
            for kind in kinds { simulation.apply(kind) }
            let chain = stack.geometryChain(sourceAspect: aspect)
            for (index, probe) in probes.enumerated() {
                let mapped = chain.map.apply(probe), expected = simulation.normalizedPoint(index)
                XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-6)
                XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-6)
            }
            XCTAssertEqual(chain.aspect, simulation.aspect, accuracy: 1e-9)
            XCTAssertEqual(stack.outputAspect(sourceAspect: aspect), simulation.aspect, accuracy: 1e-9)
        }
        // No geometry: the identity and the source aspect.
        XCTAssertEqual(EditStack().geometryChain(sourceAspect: 1.5).map, .identity)
        XCTAssertEqual(EditStack().geometryChain(sourceAspect: 1.5).aspect, 1.5)
    }

    func testKindsThatMoveNothing() {
        XCTAssertNil(EditOperation.Kind.upscale(factor: 2).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.adjust(.exposure, value: 0.2).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.localAdjust(LocalAdjustment(stack: MaskStack())).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.rotate(degrees: 0).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.perspective(horizontal: 0, vertical: 0).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.crop(.unit).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.crop(PSRect(x: 2, y: 2, width: 1, height: 1)).geometryMap(aspectBefore: 1.5))
        XCTAssertNil(EditOperation.Kind.expand(PSRect(x: 0, y: 0, width: 0.01, height: 1)).geometryMap(aspectBefore: 1.5))
        XCTAssertEqual(EditOperation.Kind.upscale(factor: 2).aspect(after: 1.5), 1.5)
        // Quarter turns are exact.
        let turn = EditOperation.Kind.rotate(degrees: 90).geometryMap(aspectBefore: 4.0 / 3)!
        XCTAssertEqual(turn.apply(PSPoint(x: 0, y: 0)), PSPoint(x: 1, y: 0))
        XCTAssertEqual(turn.apply(PSPoint(x: 1, y: 1)), PSPoint(x: 0, y: 1))
        XCTAssertEqual(EditOperation.Kind.rotate(degrees: 90).aspect(after: 4.0 / 3), 0.75, accuracy: 1e-15)
    }

    // MARK: Homographies

    func testQuadMapsTheCornersAndInverts() throws {
        let from = [PSPoint(x: 0.1, y: 0.05), PSPoint(x: 0.9, y: 0.12), PSPoint(x: 0.82, y: 0.95), PSPoint(x: 0.03, y: 0.88)]
        let to = [PSPoint(x: 0, y: 0.1), PSPoint(x: 1.2, y: 0), PSPoint(x: 1, y: 1.3), PSPoint(x: -0.1, y: 0.9)]
        let map = try XCTUnwrap(PSHomography.quad(from: from, to: to))
        for (a, b) in zip(from, to) {
            let mapped = map.apply(a)
            XCTAssertEqual(mapped.x, b.x, accuracy: 1e-9)
            XCTAssertEqual(mapped.y, b.y, accuracy: 1e-9)
        }
        let inverse = try XCTUnwrap(map.inverse)
        XCTAssertTrue(map.then(inverse).isApproximatelyEqual(to: .identity, tolerance: 1e-9))
        XCTAssertTrue(inverse.then(map).isApproximatelyEqual(to: .identity, tolerance: 1e-9))
        for point in [PSPoint(x: 0.3, y: 0.4), PSPoint(x: 0.77, y: 0.21)] {
            let back = inverse.apply(map.apply(point))
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        }
        // Unit corners to themselves: the identity. Degenerate quads: nil.
        XCTAssertTrue(try XCTUnwrap(PSHomography.quad(from: RasterRef.unitCorners, to: RasterRef.unitCorners)).isApproximatelyEqual(to: .identity))
        XCTAssertNil(PSHomography.quad(from: RasterRef.unitCorners, to: [PSPoint(x: 0, y: 0), PSPoint(x: 1, y: 1), PSPoint(x: 2, y: 2), PSPoint(x: 3, y: 3)]))
        XCTAssertNil(PSHomography.quad(from: [.zero, .zero, .zero, .zero], to: RasterRef.unitCorners))
        XCTAssertNil(PSHomography.quad(from: RasterRef.unitCorners, to: [.zero]))
        XCTAssertNil(PSHomography.quad(from: RasterRef.unitCorners, to: [PSPoint(x: .nan, y: 0), .zero, .zero, .zero]))
        // An affine quad stays affine.
        let shifted = try XCTUnwrap(PSHomography.quad(from: RasterRef.unitCorners, to: RasterRef.unitCorners.map { $0 + PSPoint(x: 0.25, y: -0.5) }))
        XCTAssertTrue(shifted.isAffine)
        XCTAssertTrue(shifted.isApproximatelyEqual(to: .affine(a: 1, b: 0, c: 0, d: 1, tx: 0.25, ty: -0.5)))
    }

    func testEveryGeometricMapInverts() throws {
        for kind in geometricKinds {
            for aspect in aspects {
                guard let map = kind.geometryMap(aspectBefore: aspect) else { continue }
                let inverse = try XCTUnwrap(map.inverse, "\(kind)")
                XCTAssertTrue(inverse.then(map).isApproximatelyEqual(to: .identity, tolerance: 1e-9), "\(kind) at \(aspect)")
            }
        }
    }

    // MARK: Local scale

    func testLocalScale() {
        // The left 75 % of a 4:3 photo (1:1 after) scales fractions of the longest side by 4/3.
        let crop = EditOperation.Kind.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1))
        let map = crop.geometryMap(aspectBefore: 4.0 / 3)!
        XCTAssertEqual(crop.aspect(after: 4.0 / 3), 1, accuracy: 1e-12)
        XCTAssertEqual(map.localScale(at: PSPoint(x: 0.3, y: 0.3), aspectBefore: 4.0 / 3, aspectAfter: 1), 4.0 / 3, accuracy: 1e-12)
        // Turns, flips and straighten keep pixel sizes; straighten's crop enlarges them by 1/k.
        for aspect in aspects {
            for kind: EditOperation.Kind in [.rotate(degrees: 90), .rotate(degrees: 30), .flip(.horizontal), .rotate(degrees: 180)] {
                let after = kind.aspect(after: aspect)
                var simulation = RendererSimulation(aspect: aspect, points: [])
                simulation.apply(kind)
                let expected = simulation.sourceLongestSide / simulation.longestSide
                XCTAssertEqual(kind.geometryMap(aspectBefore: aspect)!.localScale(at: PSPoint(x: 0.4, y: 0.6), aspectBefore: aspect, aspectAfter: after),
                               expected, accuracy: 1e-9, "\(kind) at \(aspect)")
            }
        }
        // The identity at any aspect.
        XCTAssertEqual(PSHomography.identity.localScale(at: .zero, aspectBefore: 0.75, aspectAfter: 0.75), 1, accuracy: 1e-15)
    }

    // MARK: Remapped masks

    /// A radial and a brush made before a crop, a quarter turn, a flip and straighten land where the same
    /// pixels are after it: centre through the map, pixel radius kept.
    func testARemappedRadialAndBrushKeepTheirPixels() {
        let aspect = 4.0 / 3
        let radial = RadialGradientSpec(center: PSPoint(x: 0.3, y: 0.4), radiusX: 0.08, radiusY: 0.05, rotation: 20, feather: 0.4)
        let stroke = BrushStroke(points: [PSPoint(x: 0.2, y: 0.3), PSPoint(x: 0.4, y: 0.35)], radius: 0.03, hardness: 0.5, flow: 0.7)
        let stack = MaskStack(components: [MaskComponent(.radial(radial)), MaskComponent(.brush(BrushSpec(strokes: [stroke])))], feather: 0.2, expand: 0.1)
        for kind: EditOperation.Kind in [.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)), .crop(PSRect(x: 0.1, y: 0.1, width: 0.5, height: 0.6)),
                                         .rotate(degrees: 90), .rotate(degrees: -90), .flip(.horizontal), .flip(.vertical), .straighten(degrees: 5)] {
            let map = kind.geometryMap(aspectBefore: aspect)!
            let after = kind.aspect(after: aspect)
            let remapped = stack.remapped(by: map, aspectBefore: aspect, aspectAfter: after)
            var simulation = RendererSimulation(aspect: aspect, points: [radial.center] + stroke.points)
            simulation.apply(kind)
            // Lengths in source pixels: fraction × longest side.
            let pixelScale = simulation.sourceLongestSide / simulation.longestSide
            guard case .radial(let moved) = remapped.components[0].kind, case .brush(let brush) = remapped.components[1].kind else { return XCTFail() }
            XCTAssertEqual(moved.center.x, simulation.normalizedPoint(0).x, accuracy: 1e-9)
            XCTAssertEqual(moved.center.y, simulation.normalizedPoint(0).y, accuracy: 1e-9)
            XCTAssertEqual(moved.radiusX, radial.radiusX * pixelScale, accuracy: 1e-9)
            XCTAssertEqual(moved.radiusY, radial.radiusY * pixelScale, accuracy: 1e-9)
            XCTAssertEqual(brush.strokes[0].radius, stroke.radius * pixelScale, accuracy: 1e-9)
            XCTAssertEqual(brush.strokes[0].points[1].x, simulation.normalizedPoint(2).x, accuracy: 1e-9)
            XCTAssertEqual(brush.strokes[0].flow, 0.7)
            XCTAssertEqual(remapped.feather, 0.2 * pixelScale, accuracy: 1e-9)
            XCTAssertEqual(remapped.expand, 0.1 * pixelScale, accuracy: 1e-9)
        }
    }

    /// The same check on rendered pixels: the remapped mask, rendered at the output size, equals the original
    /// rendered at the source size and moved the way the renderer moves pixels.
    func testRenderedMasksStayOnTheSamePixels() {
        let width = 80, height = 60
        let source = MaskTestSource()
        let stack = MaskStack(components: [
            MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.3, y: 0.4), radiusX: 0.15, radiusY: 0.1, rotation: 30, feather: 0.5))),
            MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.1, y: 0.9), end: PSPoint(x: 0.6, y: 0.5))), mode: .add, opacity: 0.6),
        ])
        let original = MaskRaster.render(stack, width: width, height: height, source: source)
        let cases: [(EditOperation.Kind, Int, Int, (Int, Int) -> (Int, Int))] = [
            // Output pixel → source pixel.
            (.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)), 60, 60, { x, y in (x, y) }),
            (.crop(PSRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)), 40, 30, { x, y in (x + 20, y + 30) }),
            (.rotate(degrees: 90), 60, 80, { x, y in (y, height - 1 - x) }),
            (.rotate(degrees: -90), 60, 80, { x, y in (width - 1 - y, x) }),
            (.rotate(degrees: 180), 80, 60, { x, y in (width - 1 - x, height - 1 - y) }),
            (.flip(.horizontal), 80, 60, { x, y in (width - 1 - x, y) }),
            (.flip(.vertical), 80, 60, { x, y in (x, height - 1 - y) }),
        ]
        let aspect = Double(width) / Double(height)
        for (kind, outWidth, outHeight, sourcePixel) in cases {
            let after = kind.aspect(after: aspect)
            XCTAssertEqual(after, Double(outWidth) / Double(outHeight), accuracy: 1e-12)
            let remapped = stack.remapped(by: kind.geometryMap(aspectBefore: aspect)!, aspectBefore: aspect, aspectAfter: after)
            let moved = MaskRaster.render(remapped, width: outWidth, height: outHeight, source: source)
            var worst: Float = 0
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    let (sx, sy) = sourcePixel(x, y)
                    worst = max(worst, abs(moved[x, y] - original[sx, sy]))
                }
            }
            XCTAssertLessThan(worst, 1e-4, "\(kind)")
        }
    }

    func testRemappingComposes() {
        let raster = RasterRef(path: "masks/a.png", origin: .sky, pixelWidth: 64, pixelHeight: 48)
        let depth = RasterRef(path: "masks/depth-0011223344556677.png", origin: .depth, pixelWidth: 518, pixelHeight: 392, bitDepth: 16)
        let stack = MaskStack(components: [
            MaskComponent(.raster(raster)),
            MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.3, y: 0.6), radiusX: 0.2, radiusY: 0.1, rotation: 35))),
            MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.7, y: 0.3), radiusX: 0.05, radiusY: 0.12, rotation: -60))),
            MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0), end: PSPoint(x: 0.5, y: 0.5)))),
            MaskComponent(.brush(BrushSpec(strokes: [BrushStroke(points: [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.3, y: 0.2)], radius: 0.04)]))),
            MaskComponent(.depthRange(DepthRangeSpec(depth: depth, low: 0.6, high: 1))),
            MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.2, high: 0.4))),
        ], feather: 0.3, expand: -0.2)
        let sequences: [[EditOperation.Kind]] = [
            [.crop(PSRect(x: 0.1, y: 0, width: 0.6, height: 0.9)), .rotate(degrees: 90)],
            [.flip(.horizontal), .straighten(degrees: 7), .rotate(degrees: 30)],
            [.expand(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)), .crop(PSRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)), .flip(.vertical)],
        ]
        for kinds in sequences {
            var aspect = 1.5
            var stepwise = stack
            var composed = PSHomography.identity
            for kind in kinds {
                let map = kind.geometryMap(aspectBefore: aspect)!
                let after = kind.aspect(after: aspect)
                stepwise = stepwise.remapped(by: map, aspectBefore: aspect, aspectAfter: after)
                composed = composed.then(map)
                aspect = after
            }
            let direct = stack.remapped(by: composed, aspectBefore: 1.5, aspectAfter: aspect)
            assertClose(stepwise, direct)
        }
    }

    func testRangesAndUnsupportedComponentsDoNotMove() {
        let stack = MaskStack(components: [MaskComponent(.colorRange(ColorRangeSpec(preset: .blues))),
                                           MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.1, high: 0.2))),
                                           MaskComponent(.unsupported(#"{"type":"spiral"}"#))])
        let map = EditOperation.Kind.rotate(degrees: 90).geometryMap(aspectBefore: 1.5)!
        XCTAssertEqual(stack.remapped(by: map, aspectBefore: 1.5, aspectAfter: 1 / 1.5).components, stack.components)
    }

    func testAnEllipseTurnsWithTheImage() {
        let spec = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1, rotation: 10)
        let stack = MaskStack.single(MaskComponent(.radial(spec)))
        func turned(_ kind: EditOperation.Kind) -> RadialGradientSpec {
            let remapped = stack.remapped(by: kind.geometryMap(aspectBefore: 1.5)!, aspectBefore: 1.5, aspectAfter: kind.aspect(after: 1.5))
            guard case .radial(let result) = remapped.components[0].kind else { return spec }
            return result
        }
        XCTAssertEqual(turned(.rotate(degrees: 90)).rotation, 100, accuracy: 1e-9)
        XCTAssertEqual(turned(.rotate(degrees: -30)).rotation, -20, accuracy: 1e-9)
        // A mirror reflects the axis: 10° becomes 170° (the same line as −10°).
        XCTAssertEqual(turned(.flip(.horizontal)).rotation, 170, accuracy: 1e-9)
        XCTAssertEqual(turned(.flip(.vertical)).rotation, -10, accuracy: 1e-9)
        // A tall ellipse follows its major axis too.
        let tall = MaskStack.single(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.05, radiusY: 0.2, rotation: 10))))
        guard case .radial(let result) = tall.remapped(by: EditOperation.Kind.rotate(degrees: 90).geometryMap(aspectBefore: 1)!, aspectBefore: 1, aspectAfter: 1).components[0].kind else { return XCTFail() }
        XCTAssertEqual(result.rotation, 100, accuracy: 1e-9)
    }

    // MARK: Helpers

    private func assertClose(_ a: MaskStack, _ b: MaskStack, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.feather, b.feather, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.expand, b.expand, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.components.count, b.components.count, file: file, line: line)
        func close(_ p: PSPoint, _ q: PSPoint) {
            XCTAssertEqual(p.x, q.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-9, file: file, line: line)
        }
        for (x, y) in zip(a.components, b.components) {
            switch (x.kind, y.kind) {
            case (.raster(let r), .raster(let s)):
                zip(r.corners, s.corners).forEach(close)
            case (.depthRange(let r), .depthRange(let s)):
                zip(r.depth.corners, s.depth.corners).forEach(close)
            case (.radial(let r), .radial(let s)):
                close(r.center, s.center)
                XCTAssertEqual(r.radiusX, s.radiusX, accuracy: 1e-9, file: file, line: line)
                XCTAssertEqual(r.radiusY, s.radiusY, accuracy: 1e-9, file: file, line: line)
                // Rotations are equal as lines (mod 180°).
                let difference = (r.rotation - s.rotation).truncatingRemainder(dividingBy: 180)
                XCTAssertTrue(abs(difference) < 1e-9 || abs(abs(difference) - 180) < 1e-9, "\(r.rotation) vs \(s.rotation)", file: file, line: line)
            case (.linear(let r), .linear(let s)):
                close(r.start, s.start)
                close(r.end, s.end)
            case (.brush(let r), .brush(let s)):
                for (p, q) in zip(r.strokes, s.strokes) {
                    zip(p.points, q.points).forEach(close)
                    XCTAssertEqual(p.radius, q.radius, accuracy: 1e-9, file: file, line: line)
                }
            default:
                XCTAssertEqual(x, y, file: file, line: line)
            }
        }
    }
}

/// An independent simulation of `PhotoRenderer`'s geometric operations, in Core Image's bottom-left pixel space
/// (source W = 1000 × aspect, H = 1000): the extent and a few tracked points go through the same affine
/// transforms, bounding boxes, crops and translations as the renderer's code, and the perspective transform is
/// solved here with an 8 × 8 linear system (the production code uses a closed form). Integral rounding is left out.
struct RendererSimulation {
    var extent: (x: Double, y: Double, w: Double, h: Double)
    var points: [(x: Double, y: Double)]
    let sourceLongestSide: Double

    init(aspect: Double, points: [PSPoint]) {
        let w = 1000 * aspect, h = 1000.0
        extent = (0, 0, w, h)
        sourceLongestSide = max(w, h)
        self.points = points.map { ($0.x * w, (1 - $0.y) * h) }
    }

    var aspect: Double { extent.w / extent.h }
    var longestSide: Double { max(extent.w, extent.h) }

    func normalizedPoint(_ index: Int) -> PSPoint {
        let p = points[index]
        return PSPoint(x: (p.x - extent.x) / extent.w, y: 1 - (p.y - extent.y) / extent.h)
    }

    mutating func apply(_ kind: EditOperation.Kind) {
        switch kind {
        case .crop(let rect):
            let r = (x: extent.x + rect.minX * extent.w, y: extent.y + (1 - rect.maxY) * extent.h, w: rect.width * extent.w, h: rect.height * extent.h)
            let x0 = max(r.x, extent.x), y0 = max(r.y, extent.y)
            let x1 = min(r.x + r.w, extent.x + extent.w), y1 = min(r.y + r.h, extent.y + extent.h)
            guard x1 > x0, y1 > y0 else { return }
            translate(-x0, -y0)
            extent = (0, 0, x1 - x0, y1 - y0)
        case .rotate(let degrees):
            rotate(degrees, cropToContent: false)
        case .straighten(let degrees):
            rotate(degrees, cropToContent: true)
        case .flip(let axis):
            transform(axis == .horizontal ? [-1, 0, 0, 1, 0, 0] : [1, 0, 0, -1, 0, 0])
            translate(-extent.x, -extent.y)
        case .perspective(let horizontal, let vertical):
            guard horizontal != 0 || vertical != 0 else { return }
            let w = extent.w, h = extent.h
            var tl = (x: extent.x, y: extent.y + h), tr = (x: extent.x + w, y: extent.y + h)
            var bl = (x: extent.x, y: extent.y), br = (x: extent.x + w, y: extent.y)
            let hAmount = max(-1, min(1, horizontal)) * h * 0.15
            let vAmount = max(-1, min(1, vertical)) * w * 0.15
            if hAmount > 0 { tl.y -= hAmount; bl.y += hAmount } else { tr.y += hAmount; br.y -= hAmount }
            if vAmount > 0 { tl.x += vAmount; tr.x -= vAmount } else { bl.x -= vAmount; br.x += vAmount }
            let from = [(extent.x, extent.y + h), (extent.x + w, extent.y + h), (extent.x + w, extent.y), (extent.x, extent.y)]
            let to = [tl, tr, br, bl].map { ($0.x, $0.y) }
            let h8 = Self.solveHomography(from: from, to: to)
            points = points.map { p in
                let d = h8[6] * p.x + h8[7] * p.y + 1
                return ((h8[0] * p.x + h8[1] * p.y + h8[2]) / d, (h8[3] * p.x + h8[4] * p.y + h8[5]) / d)
            }
            let xs = to.map(\.0), ys = to.map(\.1)
            extent = (xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
            translate(-extent.x, -extent.y)
        case .expand(let placement):
            guard placement.width > 0.05, placement.height > 0.05 else { return }
            let canvas = (w: extent.w / placement.width, h: extent.h / placement.height)
            let origin = (x: placement.minX * canvas.w, y: (1 - placement.maxY) * canvas.h)
            translate(origin.x - extent.x, origin.y - extent.y)
            extent = (0, 0, canvas.w, canvas.h)
        case .upscale(let factor):
            transform([factor, 0, 0, factor, 0, 0])
        default:
            return
        }
    }

    /// CGAffineTransform(translationX: c).rotated(by: −degrees).translatedBy(−c), then the crop to content.
    private mutating func rotate(_ degrees: Double, cropToContent: Bool) {
        guard degrees != 0 else { return }
        let radians = -degrees * .pi / 180
        let cx = extent.x + extent.w / 2, cy = extent.y + extent.h / 2
        let c = cos(radians), s = sin(radians)
        let w = extent.w, h = extent.h
        // p' = R (p − c) + c.
        transform([c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy])
        if cropToContent {
            let angle = abs(radians.truncatingRemainder(dividingBy: .pi / 2))
            let sinA = abs(sin(angle)), cosA = abs(cos(angle))
            let scale = min(w / (w * cosA + h * sinA), h / (w * sinA + h * cosA))
            let size = (w: w * scale, h: h * scale)
            let midX = extent.x + extent.w / 2, midY = extent.y + extent.h / 2
            extent = (midX - size.w / 2, midY - size.h / 2, size.w, size.h)
        }
        translate(-extent.x, -extent.y)
    }

    /// CGAffineTransform [a, b, c, d, tx, ty]: x' = a·x + c·y + tx, y' = b·x + d·y + ty; the extent becomes the
    /// bounding box of its transformed corners.
    private mutating func transform(_ t: [Double]) {
        func map(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) { (t[0] * p.x + t[2] * p.y + t[4], t[1] * p.x + t[3] * p.y + t[5]) }
        points = points.map(map)
        let corners = [(extent.x, extent.y), (extent.x + extent.w, extent.y), (extent.x, extent.y + extent.h), (extent.x + extent.w, extent.y + extent.h)].map(map)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        extent = (xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    }

    private mutating func translate(_ dx: Double, _ dy: Double) {
        points = points.map { ($0.x + dx, $0.y + dy) }
        extent = (extent.x + dx, extent.y + dy, extent.w, extent.h)
    }

    /// The eight coefficients (h33 = 1) of the projective map from[i] → to[i], by Gaussian elimination.
    static func solveHomography(from: [(Double, Double)], to: [(Double, Double)]) -> [Double] {
        var rows: [[Double]] = []
        for (p, q) in zip(from, to) {
            rows.append([p.0, p.1, 1, 0, 0, 0, -p.0 * q.0, -p.1 * q.0, q.0])
            rows.append([0, 0, 0, p.0, p.1, 1, -p.0 * q.1, -p.1 * q.1, q.1])
        }
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(rows[$0][column]) < abs(rows[$1][column]) }!
            rows.swapAt(column, pivot)
            for row in 0..<8 where row != column {
                let factor = rows[row][column] / rows[column][column]
                for k in column...8 { rows[row][k] -= factor * rows[column][k] }
            }
        }
        return (0..<8).map { rows[$0][8] / rows[$0][$0] }
    }
}
