import XCTest
@testable import PicshopCore

/// The Masques canvas handles and the range editor's thumbs (W2, M3): 44-point hit areas at every zoom, drags that
/// land the knob under the finger, rotation knobs, range thumbs, and the brush cursor's size on screen.
final class MaskHandleGeometryTests: XCTestCase {
    typealias Geometry = MaskHandleGeometry

    /// A 4:3 picture fitted at 400 × 300 points, then the same picture zoomed.
    private func placement(zoom: Double = 1, offset: PSPoint = PSPoint(x: 20, y: 100)) -> Geometry.Placement {
        Geometry.Placement(frame: PSRect(x: offset.x, y: offset.y, width: 400 * zoom, height: 300 * zoom))
    }

    private let zooms: [Double] = [0.5, 1, 2.5, 8]

    // MARK: Placement

    func testPlacementRoundTripsPoints() {
        let place = placement(zoom: 2.5)
        let point = PSPoint(x: 0.3, y: 0.85)
        let view = place.view(point)
        XCTAssertEqual(view.x, 20 + 0.3 * 1000, accuracy: 1e-9)
        XCTAssertEqual(view.y, 100 + 0.85 * 750, accuracy: 1e-9)
        let back = place.normalized(view)
        XCTAssertEqual(back.x, point.x, accuracy: 1e-12)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-12)
        XCTAssertEqual(place.longestSide, 1000)
    }

    // MARK: Hit areas

    func testEveryKnobHasA44PointHitAreaAtEveryZoom() {
        let linear = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.1), end: PSPoint(x: 0.5, y: 0.6))
        let radial = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2, rotation: 30, feather: 0.4)
        for zoom in zooms {
            let place = placement(zoom: zoom)
            for knob in Geometry.knobs(linear, in: place) + Geometry.knobs(radial, in: place) {
                XCTAssertGreaterThanOrEqual(knob.hitArea.width, 44, "zoom \(zoom)")
                XCTAssertGreaterThanOrEqual(knob.hitArea.height, 44, "zoom \(zoom)")
                // A touch 21 points from the knob, in any direction, still grabs a handle (the knob itself unless a
                // nearer one overlaps it).
                for angle in stride(from: 0.0, to: 360, by: 45) {
                    let touch = PSPoint(x: knob.position.x + 21 * cos(angle * .pi / 180), y: knob.position.y + 21 * sin(angle * .pi / 180))
                    let hit = knob.handle.isLinear ? Geometry.hit(touch, linear: linear, in: place) : Geometry.hit(touch, radial: radial, in: place)
                    XCTAssertNotNil(hit, "zoom \(zoom) \(knob.handle) at \(angle)°")
                }
            }
        }
    }

    func testTheExactKnobWinsWhenTouchedDead_on() {
        let radial = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2, rotation: 30, feather: 0.4)
        let linear = LinearGradientSpec(start: PSPoint(x: 0.2, y: 0.2), end: PSPoint(x: 0.8, y: 0.7))
        for zoom in zooms {
            let place = placement(zoom: zoom)
            for knob in Geometry.knobs(radial, in: place) where zoom >= 1 {
                XCTAssertEqual(Geometry.hit(knob.position, radial: radial, in: place), knob.handle, "zoom \(zoom)")
            }
            for knob in Geometry.knobs(linear, in: place) where zoom >= 1 {
                XCTAssertEqual(Geometry.hit(knob.position, linear: linear, in: place), knob.handle, "zoom \(zoom)")
            }
        }
    }

    func testLinearLinesAreGrabbableAnywhereAlongThem() {
        let linear = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.2), end: PSPoint(x: 0.5, y: 0.8))
        let place = placement()
        // Far left on the end line (y = 0.8), 10 points above it.
        let touch = PSPoint(x: place.frame.minX + 10, y: place.view(linear.end).y - 10)
        XCTAssertEqual(Geometry.hit(touch, linear: linear, in: place), .linearEnd)
        // Between the lines and away from them: nothing (the canvas pans).
        let away = PSPoint(x: place.frame.minX + 10, y: place.view(PSPoint(x: 0.5, y: 0.35)).y)
        XCTAssertNil(Geometry.hit(away, linear: linear, in: place))
    }

    func testRadialInsideMovesOutlineResizesOutsideMisses() {
        let radial = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.25, radiusY: 0.15, rotation: 0, feather: 0.5)
        let place = placement(zoom: 2)
        let center = place.view(radial.center)
        // Inside, away from every knob.
        XCTAssertEqual(Geometry.hit(PSPoint(x: center.x + 60, y: center.y - 45), radial: radial, in: place), .radialCenter)
        // On the outline at 20° (not near an edge knob): the x axis resizes.
        let rx = 0.25 * place.longestSide, ry = 0.15 * place.longestSide
        let onOutline = PSPoint(x: center.x + rx * cos(0.35), y: center.y + ry * sin(0.35))
        XCTAssertEqual(Geometry.hit(onOutline, radial: radial, in: place), .radialPositiveX)
        // Well outside.
        XCTAssertNil(Geometry.hit(PSPoint(x: center.x + rx + 200, y: center.y), radial: radial, in: place))
    }

    // MARK: Drags

    func testLinearDragRoundTripsTheKnobUnderTheFinger() {
        let start = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.1), end: PSPoint(x: 0.5, y: 0.5))
        for zoom in zooms {
            let place = placement(zoom: zoom)
            for knob in Geometry.knobs(start, in: place) {
                let target = PSPoint(x: knob.position.x + 37 * zoom, y: knob.position.y - 23 * zoom)
                let moved = Geometry.dragged(start, handle: knob.handle, from: knob.position, to: target, in: place)
                let after = Geometry.knobs(moved, in: place).first { $0.handle == knob.handle }!
                XCTAssertEqual(after.position.x, target.x, accuracy: 1e-6, "\(knob.handle) zoom \(zoom)")
                XCTAssertEqual(after.position.y, target.y, accuracy: 1e-6, "\(knob.handle) zoom \(zoom)")
            }
        }
    }

    func testLinearCentreMovesBothEndsAndAnEndRotates() {
        let spec = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.1), end: PSPoint(x: 0.5, y: 0.5))
        let place = placement()
        let center = Geometry.knobs(spec, in: place)[1].position
        let moved = Geometry.dragged(spec, handle: .linearCenter, from: center, to: PSPoint(x: center.x + 40, y: center.y), in: place)
        XCTAssertEqual(moved.start.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(moved.end.x, 0.6, accuracy: 1e-12)
        XCTAssertEqual(moved.start.y, 0.1, accuracy: 1e-12)
        // The end swung 90°: the axis now runs horizontally from the start.
        let end = place.view(spec.end), from = place.view(spec.start)
        let swung = PSPoint(x: from.x + (end.y - from.y), y: from.y)
        let rotated = Geometry.dragged(spec, handle: .linearEnd, from: end, to: swung, in: place)
        XCTAssertEqual(rotated.start, spec.start)
        XCTAssertEqual(rotated.end.y, spec.start.y, accuracy: 1e-12)
        XCTAssertGreaterThan(rotated.end.x, spec.start.x)
    }

    func testAnEndDraggedOntoTheOtherIsRefused() {
        let spec = LinearGradientSpec(start: PSPoint(x: 0.2, y: 0.2), end: PSPoint(x: 0.6, y: 0.6))
        let place = placement()
        let end = place.view(spec.end)
        let collapsed = Geometry.dragged(spec, handle: .linearEnd, from: end, to: place.view(spec.start), in: place)
        XCTAssertEqual(collapsed, spec)
    }

    func testRadialEdgeDragsRoundTrip() {
        let spec = RadialGradientSpec(center: PSPoint(x: 0.45, y: 0.55), radiusX: 0.2, radiusY: 0.1, rotation: 25, feather: 0.3)
        for zoom in zooms {
            let place = placement(zoom: zoom)
            let knobs = Geometry.knobs(spec, in: place)
            let center = knobs.first { $0.handle == .radialCenter }!.position
            for handle in [Geometry.Handle.radialPositiveX, .radialNegativeX, .radialPositiveY, .radialNegativeY] {
                let knob = knobs.first { $0.handle == handle }!.position
                // Pull the knob 30 % further out along its axis.
                let target = PSPoint(x: center.x + (knob.x - center.x) * 1.3, y: center.y + (knob.y - center.y) * 1.3)
                let resized = Geometry.dragged(spec, handle: handle, from: knob, to: target, in: place)
                let after = Geometry.knobs(resized, in: place).first { $0.handle == handle }!.position
                XCTAssertEqual(after.x, target.x, accuracy: 1e-6, "\(handle) zoom \(zoom)")
                XCTAssertEqual(after.y, target.y, accuracy: 1e-6, "\(handle) zoom \(zoom)")
            }
        }
    }

    func testRadialCentreAndFeatherDragsRoundTrip() {
        let spec = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2, rotation: -40, feather: 0.5)
        let place = placement(zoom: 2)
        let knobs = Geometry.knobs(spec, in: place)
        let center = knobs.first { $0.handle == .radialCenter }!.position
        let moved = Geometry.dragged(spec, handle: .radialCenter, from: center, to: PSPoint(x: center.x - 80, y: center.y + 60), in: place)
        XCTAssertEqual(place.view(moved.center).x, center.x - 80, accuracy: 1e-9)
        XCTAssertEqual(place.view(moved.center).y, center.y + 60, accuracy: 1e-9)
        // The feather knob dragged to the inner ellipse at 70 % of the radii: feather 0.3, knob under the finger.
        let feather = knobs.first { $0.handle == .radialFeather }!.position
        let target = PSPoint(x: center.x + (feather.x - center.x) * 0.7 / 0.5, y: center.y + (feather.y - center.y) * 0.7 / 0.5)
        let softened = Geometry.dragged(spec, handle: .radialFeather, from: feather, to: target, in: place)
        XCTAssertEqual(softened.feather, 0.3, accuracy: 1e-9)
        let after = Geometry.knobs(softened, in: place).first { $0.handle == .radialFeather }!.position
        XCTAssertEqual(after.x, target.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, target.y, accuracy: 1e-6)
    }

    // MARK: Rotation

    func testRotationKnobFacesTheFinger() {
        let spec = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2, rotation: 0, feather: 0.5)
        let place = placement()
        let center = place.view(spec.center)
        let knob = Geometry.knobs(spec, in: place).first { $0.handle == .radialRotation }!.position
        // At rotation 0 the knob is straight above the centre.
        XCTAssertEqual(knob.x, center.x, accuracy: 1e-9)
        XCTAssertLessThan(knob.y, center.y)
        for (target, expected) in [(PSPoint(x: center.x + 100, y: center.y), 90.0), (PSPoint(x: center.x, y: center.y + 100), 180.0),
                                   (PSPoint(x: center.x - 100, y: center.y), -90.0), (PSPoint(x: center.x + 50, y: center.y - 50), 45.0)] {
            let turned = Geometry.dragged(spec, handle: .radialRotation, from: knob, to: target, in: place)
            XCTAssertEqual(turned.rotation, expected, accuracy: 1e-9)
            // The knob now points at the finger.
            let after = Geometry.knobs(turned, in: place).first { $0.handle == .radialRotation }!.position
            let wanted = atan2(target.y - center.y, target.x - center.x)
            let got = atan2(after.y - center.y, after.x - center.x)
            XCTAssertEqual(cos(wanted - got), 1, accuracy: 1e-9)
        }
    }

    func testRotationBy90SwapsTheEdgeKnobs() {
        let place = placement()
        let upright = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.1, rotation: 0)
        let turned = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.1, rotation: 90)
        let a = Geometry.knobs(upright, in: place).first { $0.handle == .radialPositiveX }!.position
        let b = Geometry.knobs(turned, in: place).first { $0.handle == .radialPositiveX }!.position
        let center = place.view(upright.center)
        // +x points right at 0°, down (clockwise) at 90°.
        XCTAssertEqual(a.x - center.x, 0.3 * place.longestSide, accuracy: 1e-9)
        XCTAssertEqual(b.y - center.y, 0.3 * place.longestSide, accuracy: 1e-9)
        XCTAssertEqual(b.x, center.x, accuracy: 1e-9)
    }

    func testEllipseOutlineMatchesTheReferenceEdge() {
        // Every outline point has elliptical distance 1, as MaskRaster's radial evaluation measures it.
        let spec = RadialGradientSpec(center: PSPoint(x: 0.4, y: 0.6), radiusX: 0.2, radiusY: 0.12, rotation: 33, feather: 0.25)
        let place = placement(zoom: 1.7)
        for point in Geometry.ellipse(spec, in: place) {
            XCTAssertEqual(Geometry.ellipticalDistance(point, spec, in: place).distance, 1, accuracy: 1e-9)
        }
        for point in Geometry.ellipse(spec, scale: 0.75, in: place) {
            XCTAssertEqual(Geometry.ellipticalDistance(point, spec, in: place).distance, 0.75, accuracy: 1e-9)
        }
    }

    // MARK: Range thumbs

    func testRangeThumbsHitDragAndKeepTheirGap() {
        let width = 300.0
        XCTAssertEqual(Geometry.thumbX(0.25, trackWidth: width), 75)
        XCTAssertEqual(Geometry.hitThumb(at: 80, low: 0.25, high: 0.75, trackWidth: width), .low)
        XCTAssertEqual(Geometry.hitThumb(at: 230, low: 0.25, high: 0.75, trackWidth: width), .high)
        XCTAssertNil(Geometry.hitThumb(at: 150, low: 0.25, high: 0.75, trackWidth: width))
        // Thumbs on top of each other come apart by the side the finger is on.
        XCTAssertEqual(Geometry.hitThumb(at: 140, low: 0.5, high: 0.5, trackWidth: width), .low)
        XCTAssertEqual(Geometry.hitThumb(at: 160, low: 0.5, high: 0.5, trackWidth: width), .high)
        // Drags.
        var range = Geometry.draggedRange(low: 0.25, high: 0.75, thumb: .low, to: 120, trackWidth: width)
        XCTAssertEqual(range.low, 0.4, accuracy: 1e-12)
        XCTAssertEqual(range.high, 0.75)
        range = Geometry.draggedRange(low: 0.25, high: 0.75, thumb: .low, to: 290, trackWidth: width)
        XCTAssertEqual(range.low, 0.74, accuracy: 1e-12)
        range = Geometry.draggedRange(low: 0.25, high: 0.75, thumb: .high, to: -40, trackWidth: width)
        XCTAssertEqual(range.high, 0.26, accuracy: 1e-12)
        range = Geometry.draggedRange(low: 0.25, high: 0.75, thumb: .high, to: 400, trackWidth: width)
        XCTAssertEqual(range.high, 1)
    }

    func testEyedropperSetsTheRangeAroundTheTappedValue() {
        var range = Geometry.sampledRange(at: 0.5)
        XCTAssertEqual(range.low, 0.4, accuracy: 1e-12)
        XCTAssertEqual(range.high, 0.6, accuracy: 1e-12)
        range = Geometry.sampledRange(at: 0.04)
        XCTAssertEqual(range.low, 0)
        XCTAssertEqual(range.high, 0.14, accuracy: 1e-12)
        range = Geometry.sampledRange(at: .nan)
        XCTAssertEqual(range.low, 0.4, accuracy: 1e-12)
    }

    // MARK: Brush

    func testBrushCursorIsTheRadiusTimesTheDisplayedLongestSide() {
        for zoom in zooms {
            let place = placement(zoom: zoom)
            XCTAssertEqual(Geometry.brushCursorRadius(0.03, in: place), 0.03 * 400 * zoom, accuracy: 1e-9)
            XCTAssertEqual(Geometry.brushRadius(forCursor: Geometry.brushCursorRadius(0.03, in: place), in: place), 0.03, accuracy: 1e-12)
        }
        // Portrait: the height is the longest side.
        let portrait = Geometry.Placement(frame: PSRect(x: 0, y: 0, width: 300, height: 500))
        XCTAssertEqual(Geometry.brushCursorRadius(0.1, in: portrait), 50, accuracy: 1e-9)
    }

    func testDegenerateInputsNeverTrap() {
        let empty = Geometry.Placement(frame: .zero)
        let spec = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0, radiusY: 0)
        _ = Geometry.hit(PSPoint(x: 1, y: 1), radial: spec, in: empty)
        _ = Geometry.dragged(spec, handle: .radialFeather, from: .zero, to: PSPoint(x: 3, y: 3), in: empty)
        _ = Geometry.dragged(spec, handle: .radialRotation, from: .zero, to: .zero, in: empty)
        let linear = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.5), end: PSPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(Geometry.knobs(linear, in: placement()).count, 3)
        XCTAssertEqual(Geometry.normalizedDegrees(540), 180)
        XCTAssertEqual(Geometry.normalizedDegrees(-190), 170, accuracy: 1e-12)
    }
}
