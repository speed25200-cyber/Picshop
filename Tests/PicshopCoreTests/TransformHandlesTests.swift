import XCTest
@testable import PicshopCore

/// D10 free transform: 44 pt targets at every zoom, the hit priority, and each drag mode's geometry in canvas pixels.
final class TransformHandlesTests: XCTestCase {
    private let canvas = PSSize(width: 4000, height: 3000)
    private let content = PSSize(width: 1200, height: 1600)

    private func layer(_ transform: LayerTransform) -> Layer {
        Layer(name: "Tasse", content: .image(MediaAsset(kind: .image, relativePath: "media/cup.png", pixelSize: content)), transform: transform)
    }

    private func quad(_ transform: LayerTransform) -> [PSPoint] {
        LayerPlacement.quad(for: layer(transform), contentSize: content, canvasSize: canvas, isBase: false)
    }

    private func pixels(_ point: PSPoint) -> PSPoint { PSPoint(x: point.x * canvas.width, y: point.y * canvas.height) }

    private func drag(_ kind: TransformHandleKind, _ mode: TransformMode, _ start: LayerTransform, by translation: PSPoint,
                      location: PSPoint = PSPoint(x: 0, y: 0), anchorAtCenter: Bool = false) -> LayerTransform {
        TransformHandles.drag(kind, mode: mode, start: start, startQuad: quad(start), translation: translation, location: location,
                              anchorAtCenter: anchorAtCenter, contentSize: content, canvasSize: canvas)
    }

    private func assertSame(_ a: PSPoint, _ b: PSPoint, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let pa = pixels(a), pb = pixels(b)
        XCTAssertEqual(pa.x, pb.x, accuracy: 1e-9 * canvas.width, message, file: file, line: line)
        XCTAssertEqual(pa.y, pb.y, accuracy: 1e-9 * canvas.height, message, file: file, line: line)
    }

    private let start = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 0.5, rotation: 20)

    // MARK: Targets

    func testTargetsAre44PointsAtEveryZoom() {
        for zoom in [0.25, 0.5, 1, 2, 4, 8] {
            // A 400 × 300 px layer at the origin, in view points.
            let view = [PSPoint(x: 0, y: 0), PSPoint(x: 400 * zoom, y: 0), PSPoint(x: 400 * zoom, y: 300 * zoom), PSPoint(x: 0, y: 300 * zoom)]
            let inReach = 21 / 2.0.squareRoot(), outOfReach = 23 / 2.0.squareRoot()
            XCTAssertEqual(TransformHandles.hit(PSPoint(x: -inReach, y: -inReach), viewQuad: view), .corner(0), "zoom \(zoom)")
            XCTAssertNil(TransformHandles.hit(PSPoint(x: -outOfReach, y: -outOfReach), viewQuad: view), "zoom \(zoom)")
            XCTAssertEqual(TransformHandles.hit(PSPoint(x: 400 * zoom + 21, y: 300 * zoom), viewQuad: view), .corner(2), "zoom \(zoom)")
            XCTAssertEqual(TransformHandles.hit(PSPoint(x: 400 * zoom + 15, y: 150 * zoom), viewQuad: view), .edge(1), "zoom \(zoom)")
        }
        let handles = TransformHandles.handles(viewQuad: [PSPoint(x: 0, y: 0), PSPoint(x: 200, y: 0), PSPoint(x: 200, y: 100), PSPoint(x: 0, y: 100)])
        XCTAssertEqual(handles.count, 10)
        XCTAssertEqual(handles.first { $0.kind == .rotate }?.position, PSPoint(x: 100, y: -28))
        XCTAssertEqual(handles.first { $0.kind == .pivot }?.position, PSPoint(x: 100, y: 50))
        XCTAssertEqual(TransformHandles.handles(viewQuad: []), [])
    }

    func testPriorityCornerEdgeRotateInside() {
        let small = [PSPoint(x: 0, y: 0), PSPoint(x: 30, y: 0), PSPoint(x: 30, y: 30), PSPoint(x: 0, y: 30)]
        // Nearer the top edge's midpoint than the corner, both in reach: the corner wins.
        XCTAssertEqual(TransformHandles.hit(PSPoint(x: 12, y: -1), viewQuad: small), .corner(0))
        let wide = [PSPoint(x: 0, y: 0), PSPoint(x: 200, y: 0), PSPoint(x: 200, y: 100), PSPoint(x: 0, y: 100)]
        XCTAssertEqual(TransformHandles.hit(PSPoint(x: 100, y: -10), viewQuad: wide), .edge(0), "edge before the knob")
        XCTAssertEqual(TransformHandles.hit(PSPoint(x: 100, y: -30), viewQuad: wide), .rotate)
        XCTAssertEqual(TransformHandles.hit(PSPoint(x: 100, y: 50), viewQuad: wide), .inside, "the pivot is drawn, not dragged")
        XCTAssertEqual(TransformHandles.hit(PSPoint(x: 60, y: 70), viewQuad: wide), .inside)
        XCTAssertNil(TransformHandles.hit(PSPoint(x: 300, y: 300), viewQuad: wide))
    }

    // MARK: Drags

    func testAFreeCornerDragKeepsTheOppositeCornerAndTheAspect() {
        let before = quad(start)
        for corner in 0..<4 {
            let result = drag(.corner(corner), .free, start, by: PSPoint(x: 0.05, y: 0.03))
            let after = quad(result)
            assertSame(after[(corner + 2) % 4], before[(corner + 2) % 4], "corner \(corner)")
            XCTAssertEqual(result.scaleX, 1)
            XCTAssertEqual(result.rotation, start.rotation)
            XCTAssertNotEqual(result.scale, start.scale)
        }
        // Two fingers: about the centre.
        let centred = drag(.corner(2), .free, start, by: PSPoint(x: 0.05, y: 0.05), anchorAtCenter: true)
        XCTAssertEqual(centred.center.x, start.center.x, accuracy: 1e-12)
        XCTAssertEqual(centred.center.y, start.center.y, accuracy: 1e-12)
    }

    func testUniformKeepsTheAspectFromAnEdge() {
        let result = drag(.edge(1), .uniform, start, by: PSPoint(x: 0.04, y: 0))
        let after = quad(result).map(pixels)
        let width = after[0].distance(to: after[1]), height = after[0].distance(to: after[3])
        XCTAssertEqual(width / height, content.width / content.height, accuracy: 1e-9)
        XCTAssertEqual(result.scaleX, 1)
        XCTAssertEqual(result.scaleY, 1)
        XCTAssertGreaterThan(result.scale, start.scale)
    }

    func testAnEdgeScalesOneAxis() {
        let before = quad(start)
        let result = drag(.edge(1), .free, start, by: PSPoint(x: 0.05, y: 0.01))
        XCTAssertEqual(result.scaleY, start.scaleY)
        XCTAssertEqual(result.scale, start.scale)
        XCTAssertGreaterThan(result.scaleX, 1)
        let after = quad(result)
        assertSame(after[0], before[0], "the left edge stays")
        assertSame(after[3], before[3], "the left edge stays")
        let bottom = drag(.edge(2), .free, start, by: PSPoint(x: 0, y: 0.04))
        XCTAssertEqual(bottom.scaleX, 1)
        XCTAssertGreaterThan(bottom.scaleY, 1)
        assertSame(quad(bottom)[0], before[0], "the top edge stays")
    }

    func testSkewMovesTheEdgeAlongItselfOnly() {
        let before = quad(start).map(pixels)
        let result = drag(.edge(0), .skew, start, by: PSPoint(x: 0.03, y: 0.02))
        let after = quad(result).map(pixels)
        // The bottom edge stays.
        XCTAssertEqual(after[2].distance(to: before[2]), 0, accuracy: 1e-6)
        XCTAssertEqual(after[3].distance(to: before[3]), 0, accuracy: 1e-6)
        // The top corners move by one vector, parallel to the top edge.
        let edge = PSPoint(x: before[1].x - before[0].x, y: before[1].y - before[0].y)
        let move0 = PSPoint(x: after[0].x - before[0].x, y: after[0].y - before[0].y)
        let move1 = PSPoint(x: after[1].x - before[1].x, y: after[1].y - before[1].y)
        XCTAssertEqual(move0.x, move1.x, accuracy: 1e-6)
        XCTAssertEqual(move0.y, move1.y, accuracy: 1e-6)
        XCTAssertEqual(move0.x * edge.y - move0.y * edge.x, 0, accuracy: 1e-6 * edge.distance(to: PSPoint(x: 0, y: 0)))
        XCTAssertGreaterThan(move0.distance(to: PSPoint(x: 0, y: 0)), 1)
        XCTAssertNotEqual(result.skewX, 0)
        XCTAssertEqual(result.skewY, 0)
        // A side edge shears skewY; past ±80° the drag is refused.
        XCTAssertNotEqual(drag(.edge(1), .skew, start, by: PSPoint(x: 0, y: 0.05)).skewY, 0)
        XCTAssertEqual(drag(.edge(0), .skew, start, by: PSPoint(x: 40, y: 0)), start)
    }

    func testDistortMovesOneCornerAndWritesAQuad() throws {
        let before = quad(start)
        let result = drag(.corner(1), .distort, start, by: PSPoint(x: 0.02, y: -0.03))
        let after = try XCTUnwrap(result.quad)
        assertSame(after[1], PSPoint(x: before[1].x + 0.02, y: before[1].y - 0.03))
        for index in [0, 2, 3] { assertSame(after[index], before[index], "corner \(index)") }
        // The quad now places the layer.
        let placed = quad(result)
        for (a, b) in zip(placed, after) { assertSame(a, b) }
    }

    func testPerspectiveMovesTwoCornersSymmetrically() throws {
        let flat = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 0.5)
        let before = quad(flat)
        let result = drag(.corner(1), .perspective, flat, by: PSPoint(x: 0.03, y: 0.005))
        let after = try XCTUnwrap(result.quad)
        // Along the top edge (the axis the finger moved most): TR out, TL out the other way, the bottom fixed.
        assertSame(after[1], PSPoint(x: before[1].x + 0.03, y: before[1].y))
        assertSame(after[0], PSPoint(x: before[0].x - 0.03, y: before[0].y))
        assertSame(after[2], before[2])
        assertSame(after[3], before[3])
        let vertical = try XCTUnwrap(drag(.corner(1), .perspective, flat, by: PSPoint(x: 0.001, y: -0.04)).quad)
        assertSame(vertical[1], PSPoint(x: before[1].x, y: before[1].y - 0.04))
        assertSame(vertical[2], PSPoint(x: before[2].x, y: before[2].y + 0.04))
    }

    func testADegenerateDragReturnsTheStart() {
        // A corner pulled through its anchor, an edge collapsed, a corner folded across the quad.
        XCTAssertEqual(drag(.corner(2), .free, start, by: PSPoint(x: -1, y: -1)), start)
        XCTAssertEqual(drag(.edge(1), .free, start, by: PSPoint(x: -1, y: 0)), start)
        let flat = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 0.5)
        XCTAssertEqual(drag(.corner(1), .distort, flat, by: PSPoint(x: -0.6, y: 0.6)), flat)
        XCTAssertEqual(TransformHandles.drag(.corner(0), mode: .free, start: start, startQuad: [], translation: PSPoint(x: 0.1, y: 0),
                                             location: PSPoint(x: 0, y: 0), anchorAtCenter: false, contentSize: content, canvasSize: canvas), start)
        XCTAssertEqual(drag(.pivot, .free, start, by: PSPoint(x: 0.1, y: 0.1)), start)
    }

    func testInsideMovesAndTheKnobTurns() throws {
        let moved = drag(.inside, .free, start, by: PSPoint(x: 0.1, y: -0.05))
        XCTAssertEqual(moved.center.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(moved.center.y, 0.45, accuracy: 1e-12)
        // The finger goes a quarter turn round the pivot (in pixels): +90°.
        let pivot = pixels(start.center)
        let grabbed = PSPoint(x: pivot.x + 500, y: pivot.y)
        let finger = PSPoint(x: pivot.x, y: pivot.y + 500)
        let turned = drag(.rotate, .free, start, by: PSPoint(x: (finger.x - grabbed.x) / canvas.width, y: (finger.y - grabbed.y) / canvas.height),
                          location: PSPoint(x: finger.x / canvas.width, y: finger.y / canvas.height))
        XCTAssertEqual(turned.rotation, start.rotation + 90, accuracy: 1e-9)
        XCTAssertEqual(turned.center, start.center)
    }

    func testRotationSnapsAt15DegreesWithin2() {
        XCTAssertEqual(TransformHandles.rotationSnap(16.9).degrees, 15)
        XCTAssertTrue(TransformHandles.rotationSnap(16.9).snapped)
        XCTAssertEqual(TransformHandles.rotationSnap(13).degrees, 15)
        XCTAssertFalse(TransformHandles.rotationSnap(17.5).snapped)
        XCTAssertEqual(TransformHandles.rotationSnap(17.5).degrees, 17.5)
        XCTAssertEqual(TransformHandles.rotationSnap(-44).degrees, -45)
        XCTAssertEqual(TransformHandles.rotationSnap(1.5).degrees, 0)
        XCTAssertFalse(TransformHandles.rotationSnap(7.5).snapped)
        XCTAssertFalse(TransformHandles.rotationSnap(.nan).snapped)
    }

    func testQuadValidity() {
        let square = [PSPoint(x: 0, y: 0), PSPoint(x: 1, y: 0), PSPoint(x: 1, y: 1), PSPoint(x: 0, y: 1)]
        XCTAssertTrue(TransformHandles.isValidQuad(square, aspect: 1))
        XCTAssertFalse(TransformHandles.isValidQuad([square[0], square[2], square[1], square[3]], aspect: 1), "self-intersecting")
        XCTAssertFalse(TransformHandles.isValidQuad([square[0], PSPoint(x: 1, y: 0.0001), PSPoint(x: 2, y: 0), PSPoint(x: 0, y: 1)], aspect: 1),
                       "a corner at ≥ 179°")
        XCTAssertFalse(TransformHandles.isValidQuad(Array(square.prefix(3)), aspect: 1))
    }
}
