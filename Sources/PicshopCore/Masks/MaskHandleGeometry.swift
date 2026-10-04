import Foundation

// The maths behind the Masques canvas handles and the range editor (W2, M3): where each knob sits on screen,
// which one a touch grabs, what a drag does to the spec, and the brush cursor's size. Pure, so Linux tests it;
// the SwiftUI overlay only draws what this returns and hands it the touches.
//
// Spaces: specs are normalised to the layer's output space (top-left origin, y down, D3); radii are fractions of
// the longest side. Everything on screen is in view points, through a `Placement` (the picture's frame). Hit areas
// are fixed in points (44), so a handle stays as easy to grab at 8× as at 1×.

public enum MaskHandleGeometry {
    /// A touch grabs a knob within this square around it, at every zoom.
    public static let hitSide: Double = 44
    public static var hitRadius: Double { hitSide / 2 }
    /// How far beyond the ellipse's top the rotation knob sits, in points.
    public static let rotationKnobOffset: Double = 28
    /// The shortest gradient and the smallest radius a drag may leave, as a fraction of the longest side.
    public static let minimumLength = 0.005
    /// How far outside the picture a gradient point or a centre may be dragged (normalised units).
    public static let reach = 1.0

    // MARK: - Placement

    /// The picture on screen: its frame in view points (fitted, zoomed and panned).
    public struct Placement: Hashable, Sendable {
        public var frame: PSRect

        public init(frame: PSRect) {
            self.frame = frame
        }

        /// The displayed longest side in points: what a fraction-of-longest-side radius is measured against.
        public var longestSide: Double { max(frame.width, frame.height) }

        /// A normalised point (top-left origin) in view points.
        public func view(_ point: PSPoint) -> PSPoint {
            PSPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
        }

        /// A view point as a normalised point (not clamped: a drag may leave the picture).
        public func normalized(_ point: PSPoint) -> PSPoint {
            guard frame.width > 0, frame.height > 0 else { return .zero }
            return PSPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        }

        /// A view translation as a normalised one.
        public func normalizedDelta(_ delta: PSPoint) -> PSPoint {
            guard frame.width > 0, frame.height > 0 else { return .zero }
            return PSPoint(x: delta.x / frame.width, y: delta.y / frame.height)
        }
    }

    // MARK: - Handles

    public enum Handle: String, Hashable, Sendable, CaseIterable {
        /// The three parallel lines of a linear gradient: full effect, centre, no effect.
        case linearStart, linearCenter, linearEnd
        /// The ellipse's centre, its four edge knobs (along its own axes), the rotation knob above it, and the
        /// feather knob on the dashed inner ellipse.
        case radialCenter, radialPositiveX, radialNegativeX, radialPositiveY, radialNegativeY, radialRotation, radialFeather

        public var isLinear: Bool { self == .linearStart || self == .linearCenter || self == .linearEnd }
    }

    /// A knob on screen and the square a touch grabs it in.
    public struct Knob: Hashable, Sendable {
        public var handle: Handle
        /// View points.
        public var position: PSPoint

        public init(handle: Handle, position: PSPoint) {
            self.handle = handle
            self.position = position
        }

        /// 44 × 44 points around the knob.
        public var hitArea: PSRect {
            PSRect(x: position.x - MaskHandleGeometry.hitRadius, y: position.y - MaskHandleGeometry.hitRadius,
                   width: MaskHandleGeometry.hitSide, height: MaskHandleGeometry.hitSide)
        }
    }

    // MARK: Linear

    /// The unit direction from start to end in view points ((0, 1), downwards, when they meet).
    static func axis(_ spec: LinearGradientSpec, in placement: Placement) -> PSPoint {
        let start = placement.view(spec.start), end = placement.view(spec.end)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9, length.isFinite else { return PSPoint(x: 0, y: 1) }
        return PSPoint(x: dx / length, y: dy / length)
    }

    /// Start, centre and end knobs in view points.
    public static func knobs(_ spec: LinearGradientSpec, in placement: Placement) -> [Knob] {
        let start = placement.view(spec.start), end = placement.view(spec.end)
        let center = PSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return [Knob(handle: .linearStart, position: start), Knob(handle: .linearCenter, position: center), Knob(handle: .linearEnd, position: end)]
    }

    /// The three parallel lines (start, centre, end), each as two view points far enough apart to cross the whole
    /// picture; the overlay clips them to the frame.
    public static func lines(_ spec: LinearGradientSpec, in placement: Placement) -> [(handle: Handle, from: PSPoint, to: PSPoint)] {
        let direction = axis(spec, in: placement)
        let normal = PSPoint(x: -direction.y, y: direction.x)
        let reach = (placement.frame.width * placement.frame.width + placement.frame.height * placement.frame.height).squareRoot() * 2
        return knobs(spec, in: placement).map { knob in
            (knob.handle, PSPoint(x: knob.position.x - normal.x * reach, y: knob.position.y - normal.y * reach),
             PSPoint(x: knob.position.x + normal.x * reach, y: knob.position.y + normal.y * reach))
        }
    }

    /// The handle a touch at `point` (view points) grabs: the nearest knob within the hit radius, else a line within
    /// it; nil when the touch is elsewhere (the canvas pans instead).
    public static func hit(_ point: PSPoint, linear spec: LinearGradientSpec, in placement: Placement) -> Handle? {
        if let knob = nearest(knobs(spec, in: placement), to: point) { return knob }
        let direction = axis(spec, in: placement)
        var best: (handle: Handle, distance: Double)?
        for knob in knobs(spec, in: placement) {
            // Distance to the line through the knob, perpendicular to the axis: the offset along the axis.
            let distance = abs((point.x - knob.position.x) * direction.x + (point.y - knob.position.y) * direction.y)
            guard distance <= hitRadius else { continue }
            if best == nil || distance < best!.distance { best = (knob.handle, distance) }
        }
        return best?.handle
    }

    /// The spec after a drag of `handle` from `start` to `current` (view points), from the spec the drag started on:
    /// the centre line moves the whole gradient; an end line moves that end alone (rotating and spreading it).
    public static func dragged(_ spec: LinearGradientSpec, handle: Handle, from start: PSPoint, to current: PSPoint,
                               in placement: Placement) -> LinearGradientSpec {
        let delta = placement.normalizedDelta(PSPoint(x: current.x - start.x, y: current.y - start.y))
        var result = spec
        switch handle {
        case .linearCenter:
            result.start = clamped(spec.start + delta)
            result.end = clamped(spec.end + delta)
        case .linearStart:
            result.start = clamped(spec.start + delta)
        case .linearEnd:
            result.end = clamped(spec.end + delta)
        default:
            return spec
        }
        // Never let the two ends meet: the gradient would select nothing.
        let longest = placement.longestSide
        let length = placement.view(result.start).distance(to: placement.view(result.end)) / max(1e-9, longest)
        return length >= minimumLength ? result : spec
    }

    // MARK: Radial

    /// The ellipse's own axes in view space: x turned clockwise by `rotation` (y down), y perpendicular to it.
    static func axes(_ spec: RadialGradientSpec) -> (x: PSPoint, y: PSPoint) {
        let theta = (spec.rotation.isFinite ? spec.rotation : 0) * .pi / 180
        let c = cos(theta), s = sin(theta)
        return (PSPoint(x: c, y: s), PSPoint(x: -s, y: c))
    }

    /// The radii in view points.
    static func viewRadii(_ spec: RadialGradientSpec, in placement: Placement) -> (x: Double, y: Double) {
        (max(0, spec.radiusX) * placement.longestSide, max(0, spec.radiusY) * placement.longestSide)
    }

    /// Centre, the four edge knobs, the rotation knob above the top edge and the feather knob on the inner ellipse
    /// (at 45° between +x and +y, so it never sits on an edge knob).
    public static func knobs(_ spec: RadialGradientSpec, in placement: Placement) -> [Knob] {
        let center = placement.view(spec.center)
        let (ax, ay) = axes(spec)
        let (rx, ry) = viewRadii(spec, in: placement)
        func at(_ u: Double, _ v: Double) -> PSPoint {
            PSPoint(x: center.x + ax.x * u + ay.x * v, y: center.y + ax.y * u + ay.y * v)
        }
        let inner = 1 - (spec.feather.isFinite ? spec.feather.clamped(to: 0...1) : 0)
        let diagonal = 0.5.squareRoot()
        return [
            Knob(handle: .radialCenter, position: center),
            Knob(handle: .radialPositiveX, position: at(rx, 0)),
            Knob(handle: .radialNegativeX, position: at(-rx, 0)),
            Knob(handle: .radialPositiveY, position: at(0, ry)),
            Knob(handle: .radialNegativeY, position: at(0, -ry)),
            Knob(handle: .radialRotation, position: at(0, -(ry + rotationKnobOffset))),
            Knob(handle: .radialFeather, position: at(inner * rx * diagonal, inner * ry * diagonal)),
        ]
    }

    /// The ellipse (scale 1) or the feather's inner ellipse (scale 1 − feather) as a closed polygon in view points.
    public static func ellipse(_ spec: RadialGradientSpec, scale: Double = 1, in placement: Placement, segments: Int = 72) -> [PSPoint] {
        let center = placement.view(spec.center)
        let (ax, ay) = axes(spec)
        let (rx, ry) = viewRadii(spec, in: placement)
        let count = max(8, segments)
        return (0..<count).map { index in
            let t = Double(index) / Double(count) * 2 * .pi
            let u = cos(t) * rx * scale, v = sin(t) * ry * scale
            return PSPoint(x: center.x + ax.x * u + ay.x * v, y: center.y + ax.y * u + ay.y * v)
        }
    }

    /// The point's elliptical distance from the centre: 1 on the ellipse, 0 at the centre.
    static func ellipticalDistance(_ point: PSPoint, _ spec: RadialGradientSpec, in placement: Placement) -> (distance: Double, u: Double, v: Double) {
        let center = placement.view(spec.center)
        let (ax, ay) = axes(spec)
        let (rx, ry) = viewRadii(spec, in: placement)
        let dx = point.x - center.x, dy = point.y - center.y
        let u = dx * ax.x + dy * ax.y, v = dx * ay.x + dy * ay.y
        guard rx > 1e-9, ry > 1e-9 else { return (.infinity, u, v) }
        return (((u / rx) * (u / rx) + (v / ry) * (v / ry)).squareRoot(), u, v)
    }

    /// The handle a touch grabs: the nearest knob within the hit radius; else the outline within it (the axis the
    /// touch is closest to resizes); else inside the ellipse moves it; nil outside.
    public static func hit(_ point: PSPoint, radial spec: RadialGradientSpec, in placement: Placement) -> Handle? {
        if let knob = nearest(knobs(spec, in: placement), to: point) { return knob }
        let (distance, u, v) = ellipticalDistance(point, spec, in: placement)
        let (rx, ry) = viewRadii(spec, in: placement)
        // How far from the outline, in points, along the touch's direction from the centre.
        let radius = distance > 0 && distance.isFinite ? (u * u + v * v).squareRoot() / distance : 0
        if distance.isFinite, abs(distance - 1) * radius <= hitRadius {
            let alongX = abs(u) / max(1e-9, rx) >= abs(v) / max(1e-9, ry)
            if alongX { return u >= 0 ? .radialPositiveX : .radialNegativeX }
            return v >= 0 ? .radialPositiveY : .radialNegativeY
        }
        return distance < 1 ? .radialCenter : nil
    }

    /// The spec after a drag of `handle` from `start` to `current` (view points), from the spec the drag started on:
    /// the centre moves; an edge knob sets that axis's radius to the touch's distance along it; the rotation knob
    /// turns the ellipse to face the touch; the feather knob sets the inner ellipse through the touch.
    public static func dragged(_ spec: RadialGradientSpec, handle: Handle, from start: PSPoint, to current: PSPoint,
                               in placement: Placement) -> RadialGradientSpec {
        var result = spec
        let center = placement.view(spec.center)
        let (ax, ay) = axes(spec)
        let longest = max(1e-9, placement.longestSide)
        let dx = current.x - center.x, dy = current.y - center.y
        switch handle {
        case .radialCenter:
            let delta = placement.normalizedDelta(PSPoint(x: current.x - start.x, y: current.y - start.y))
            result.center = clamped(spec.center + delta)
        case .radialPositiveX, .radialNegativeX:
            result.radiusX = clampedRadius(abs(dx * ax.x + dy * ax.y) / longest)
        case .radialPositiveY, .radialNegativeY:
            result.radiusY = clampedRadius(abs(dx * ay.x + dy * ay.y) / longest)
        case .radialRotation:
            guard dx * dx + dy * dy > 1 else { return spec }
            // The knob sits along −y: at rotation 0 it points straight up (−90° in y-down screen angles).
            result.rotation = normalizedDegrees(atan2(dy, dx) * 180 / .pi + 90)
        case .radialFeather:
            let (distance, _, _) = ellipticalDistance(current, spec, in: placement)
            guard distance.isFinite else { return spec }
            result.feather = (1 - distance).clamped(to: 0...1)
        case .linearStart, .linearCenter, .linearEnd:
            return spec
        }
        return result
    }

    // MARK: Brush

    /// The brush cursor's radius on screen: a fraction of the longest side times the displayed longest side.
    public static func brushCursorRadius(_ radius: Double, in placement: Placement) -> Double {
        max(0, radius) * placement.longestSide
    }

    /// The brush radius (fraction of the longest side) for a cursor of `points` on screen: the inverse.
    public static func brushRadius(forCursor points: Double, in placement: Placement) -> Double {
        let longest = placement.longestSide
        return longest > 0 ? max(0, points) / longest : 0
    }

    // MARK: - Range thumbs (luminance and depth ranges)

    public enum RangeThumb: String, Hashable, Sendable { case low, high }

    /// The two thumbs never come closer than this (0…1).
    public static let minimumRangeGap = 0.01
    /// The eyedropper's range around the tapped value.
    public static let sampledSpread = 0.1

    /// A value's position on a track `width` points wide.
    public static func thumbX(_ value: Double, trackWidth width: Double) -> Double {
        value.clamped(to: 0...1) * max(0, width)
    }

    /// The thumb a touch at `x` grabs: the nearer within the hit radius; on top of each other, the one on the side
    /// the touch is (left: low, right: high), so two thumbs together can always be pulled apart.
    public static func hitThumb(at x: Double, low: Double, high: Double, trackWidth width: Double) -> RangeThumb? {
        let lowX = thumbX(low, trackWidth: width), highX = thumbX(high, trackWidth: width)
        let toLow = abs(x - lowX), toHigh = abs(x - highX)
        guard min(toLow, toHigh) <= hitRadius else { return nil }
        if abs(highX - lowX) < 1 {
            return x < lowX ? .low : (x > highX ? .high : (high < 1 ? .high : .low))
        }
        return toLow <= toHigh ? .low : .high
    }

    /// The range after `thumb` is dragged to `x`: the value under the finger, the other thumb kept at least
    /// `minimumRangeGap` away.
    public static func draggedRange(low: Double, high: Double, thumb: RangeThumb, to x: Double, trackWidth width: Double) -> (low: Double, high: Double) {
        let value = width > 0 ? (x / width).clamped(to: 0...1) : 0
        switch thumb {
        case .low: return (min(value, max(0, high - minimumRangeGap)), high)
        case .high: return (low, max(value, min(1, low + minimumRangeGap)))
        }
    }

    /// The eyedropper: the tapped value ± 0.1, inside 0…1.
    public static func sampledRange(at value: Double) -> (low: Double, high: Double) {
        let v = value.isFinite ? value.clamped(to: 0...1) : 0.5
        return (max(0, v - sampledSpread), min(1, v + sampledSpread))
    }

    // MARK: - Helpers

    static func nearest(_ knobs: [Knob], to point: PSPoint) -> Handle? {
        var best: (handle: Handle, distance: Double)?
        for knob in knobs {
            let distance = knob.position.distance(to: point)
            guard distance <= hitRadius else { continue }
            if best == nil || distance < best!.distance { best = (knob.handle, distance) }
        }
        return best?.handle
    }

    static func clamped(_ point: PSPoint) -> PSPoint {
        PSPoint(x: point.x.isFinite ? point.x.clamped(to: -reach...(1 + reach)) : 0.5,
                y: point.y.isFinite ? point.y.clamped(to: -reach...(1 + reach)) : 0.5)
    }

    static func clampedRadius(_ radius: Double) -> Double {
        radius.isFinite ? radius.clamped(to: minimumLength...2) : minimumLength
    }

    /// −180 < degrees ≤ 180.
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value <= -180 { value += 360 }
        if value > 180 { value -= 360 }
        return value
    }
}
