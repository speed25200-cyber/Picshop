import Foundation

// D3: every mask coordinate is normalised [0,1]², top-left origin, y down, in the layer's output space. A
// geometric edit moves those points; these maps say how, so masks and the selection follow a crop or a turn.
//
// Each map reproduces what PhotoRenderer does to the pixels (crop, rotate, straighten, flip, perspective,
// expand), in top-left normalised space: Core Image is bottom-left, so every formula below was converted with
// y_tl = H − y_ci. Lengths that are fractions of the longest side (radii, brush radii, feather) scale with the
// map's local scale in longest-side units, which needs the aspect before and after the edit.

/// A 3×3 projective map of normalised points (top-left origin), row-major.
public struct PSHomography: Hashable, Codable, Sendable {
    public var m: [Double]

    /// Nine values, row-major; anything else is the identity.
    public init(_ m: [Double]) {
        self.m = m.count == 9 ? m : [1, 0, 0, 0, 1, 0, 0, 0, 1]
    }

    private enum CodingKeys: String, CodingKey { case m }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.container(keyedBy: CodingKeys.self).decode([Double].self, forKey: .m))
    }

    public static let identity = PSHomography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// x' = a·x + c·y + tx, y' = b·x + d·y + ty
    public static func affine(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) -> PSHomography {
        PSHomography([a, c, tx, b, d, ty, 0, 0, 1])
    }

    /// The map sending `from[i]` to `to[i]` (4 points each); nil when degenerate (three points on a line, a
    /// repeated point, a non-finite value).
    public static func quad(from: [PSPoint], to: [PSPoint]) -> PSHomography? {
        guard from.count == 4, to.count == 4,
              (from + to).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        if from == RasterRef.unitCorners { return unitSquare(to: to) }
        guard let source = unitSquare(to: from), let inverse = source.inverse, let target = unitSquare(to: to) else { return nil }
        return inverse.then(target).normalized
    }

    public func apply(_ point: PSPoint) -> PSPoint {
        let x = m[0] * point.x + m[1] * point.y + m[2]
        let y = m[3] * point.x + m[4] * point.y + m[5]
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard w != 0, w.isFinite else { return PSPoint(x: x, y: y) }
        return PSPoint(x: x / w, y: y / w)
    }

    /// self, then next.
    public func then(_ next: PSHomography) -> PSHomography {
        // next × self, row-major.
        var product = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for k in 0..<3 {
                    sum += next.m[row * 3 + k] * m[k * 3 + column]
                }
                product[row * 3 + column] = sum
            }
        }
        return PSHomography(product)
    }

    public var inverse: PSHomography? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let co00 = e * i - f * h, co01 = -(d * i - f * g), co02 = d * h - e * g
        let determinant = a * co00 + b * co01 + c * co02
        guard abs(determinant) > 1e-12, determinant.isFinite else { return nil }
        let adjugate = [co00, -(b * i - c * h), b * f - c * e,
                        co01, a * i - c * g, -(a * f - c * d),
                        co02, -(a * h - b * g), a * e - b * d]
        return PSHomography(adjugate.map { $0 / determinant })
    }

    /// No projective part: x' and y' are affine in x and y.
    public var isAffine: Bool { m[6] == 0 && m[7] == 0 && m[8] != 0 }

    /// Every coefficient within `tolerance` of the other map's, after scaling both to m[8] = 1.
    public func isApproximatelyEqual(to other: PSHomography, tolerance: Double = 1e-12) -> Bool {
        zip(normalized.m, other.normalized.m).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// The Jacobian of the normalised map at `point`, row-major: ∂x'/∂x, ∂x'/∂y, ∂y'/∂x, ∂y'/∂y.
    public func jacobian(at point: PSPoint) -> [Double] {
        let x = m[0] * point.x + m[1] * point.y + m[2]
        let y = m[3] * point.x + m[4] * point.y + m[5]
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard abs(w) > 1e-15, w.isFinite else { return [0, 0, 0, 0] }
        let w2 = w * w
        return [(m[0] * w - x * m[6]) / w2, (m[1] * w - x * m[7]) / w2,
                (m[3] * w - y * m[6]) / w2, (m[4] * w - y * m[7]) / w2]
    }

    /// The Jacobian in longest-side units (D3): J_L = diag(w′/L′, h′/L′) · J_n · diag(L/w, L/h), so that a length
    /// written as a fraction of the longest side maps through it.
    public func longestSideJacobian(at point: PSPoint, aspectBefore: Double, aspectAfter: Double) -> [Double] {
        let j = jacobian(at: point)
        let before = Self.longestSideShares(aspectBefore), after = Self.longestSideShares(aspectAfter)
        return [after.width * j[0] / before.width, after.width * j[1] / before.height,
                after.height * j[2] / before.width, after.height * j[3] / before.height]
    }

    /// How a length that is a fraction of the longest side scales at `point` (brush radii, ellipse radii):
    /// √|det J_L| with |det J_L| = |det J_n| · (w′h′/L′²) / (wh/L²), from the aspects before and after.
    public func localScale(at point: PSPoint, aspectBefore: Double, aspectAfter: Double) -> Double {
        let j = jacobian(at: point)
        let before = Self.longestSideShares(aspectBefore), after = Self.longestSideShares(aspectAfter)
        let determinant = abs(j[0] * j[3] - j[1] * j[2]) * (after.width * after.height) / (before.width * before.height)
        let scale = determinant.squareRoot()
        return scale.isFinite && scale > 0 ? scale : 1
    }

    // MARK: Internals

    /// w/L and h/L for an aspect w/h (a non-finite or non-positive aspect counts as square).
    static func longestSideShares(_ aspect: Double) -> (width: Double, height: Double) {
        let a = aspect.isFinite && aspect > 0 ? aspect : 1
        return a >= 1 ? (1, 1 / a) : (a, 1)
    }

    /// Scaled so that m[8] = 1 when it can be.
    var normalized: PSHomography {
        guard abs(m[8]) > 1e-15, m[8] != 1 else { return self }
        return PSHomography(m.map { $0 / m[8] })
    }

    /// The unit square's corners (0,0), (1,0), (1,1), (0,1) to the four points (Heckbert's square-to-quad).
    static func unitSquare(to q: [PSPoint]) -> PSHomography? {
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y, x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        let map: PSHomography
        if abs(sx) < 1e-14, abs(sy) < 1e-14 {
            map = PSHomography([x1 - x0, x2 - x1, x0, y1 - y0, y2 - y1, y0, 0, 0, 1])
        } else {
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let denominator = dx1 * dy2 - dx2 * dy1
            guard abs(denominator) > 1e-14 else { return nil }
            let g = (sx * dy2 - dx2 * sy) / denominator
            let h = (dx1 * sy - sx * dy1) / denominator
            map = PSHomography([x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1])
        }
        // Degenerate when the corners collapse (three on a line).
        return map.inverse == nil ? nil : map
    }
}

// MARK: - What each geometric edit does to normalised points

public extension EditOperation.Kind {
    /// How this geometric edit moves the layer's normalised points, given its aspect (w/h) before; nil when it moves none.
    func geometryMap(aspectBefore: Double) -> PSHomography? {
        let aspect = PSHomography.saneAspect(aspectBefore)
        switch self {
        case .crop(let rect):
            // The renderer crops to the rect's intersection with the image; an empty one changes nothing.
            guard let r = Self.effectiveCrop(rect), r != .unit else { return nil }
            return .affine(a: 1 / r.width, b: 0, c: 0, d: 1 / r.height, tx: -r.minX / r.width, ty: -r.minY / r.height)
        case .rotate(let degrees):
            return Self.rotationMap(degrees: degrees, aspect: aspect, cropToContent: false)
        case .straighten(let degrees):
            return Self.rotationMap(degrees: degrees, aspect: aspect, cropToContent: true)
        case .flip(let axis):
            return axis == .horizontal ? .affine(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0) : .affine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case .perspective(let horizontal, let vertical):
            guard let corners = Self.perspectiveCorners(horizontal: horizontal, vertical: vertical, aspect: aspect) else { return nil }
            return PSHomography.quad(from: RasterRef.unitCorners, to: corners.normalized)
        case .expand(let placement):
            // The renderer leaves a placement this small alone (as `PhotoDocument.apply` does the canvas).
            guard placement.width > 0.05, placement.height > 0.05 else { return nil }
            return .affine(a: placement.width, b: 0, c: 0, d: placement.height, tx: placement.minX, ty: placement.minY)
        default:
            // Upscale keeps every point where it is; every other kind moves none.
            return nil
        }
    }

    /// The layer's aspect after this edit (crops, quarter turns, expand, rotate's bounding box).
    func aspect(after aspectBefore: Double) -> Double {
        let aspect = PSHomography.saneAspect(aspectBefore)
        switch self {
        case .crop(let rect):
            guard let r = Self.effectiveCrop(rect) else { return aspect }
            return aspect * r.width / r.height
        case .rotate(let degrees):
            guard degrees != 0, degrees.isFinite else { return aspect }
            let (c, s) = Self.cosSin(degrees)
            return (aspect * abs(c) + abs(s)) / (aspect * abs(s) + abs(c))
        case .perspective(let horizontal, let vertical):
            guard let corners = Self.perspectiveCorners(horizontal: horizontal, vertical: vertical, aspect: aspect) else { return aspect }
            return corners.size.width / corners.size.height
        case .expand(let placement):
            guard placement.width > 0.05, placement.height > 0.05 else { return aspect }
            return aspect * placement.height / placement.width
        default:
            // Straighten crops back to the original aspect; flips and upscale keep it.
            return aspect
        }
    }
}

extension EditOperation.Kind {
    /// The crop the renderer makes: the rect within the image, nil when nothing of it is left.
    static func effectiveCrop(_ rect: PSRect) -> PSRect? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        let r = rect.clampedToUnit()
        return r.width > 1e-9 && r.height > 1e-9 ? r : nil
    }

    /// Exact for quarter turns, so a 90° turn maps corners onto corners.
    static func cosSin(_ degrees: Double) -> (Double, Double) {
        let turns = degrees / 90
        if abs(turns) < 1e9, abs(turns - turns.rounded()) < 1e-12 {
            switch ((Int(turns.rounded()) % 4) + 4) % 4 {
            case 0: return (1, 0)
            case 1: return (0, 1)
            case 2: return (-1, 0)
            default: return (0, -1)
            }
        }
        let radians = degrees * .pi / 180
        return (cos(radians), sin(radians))
    }

    /// `PhotoRenderer.rotated`: a clockwise turn about the centre (y down: R = [[c, −s], [s, c]]) in pixel space
    /// (W = aspect, H = 1), then re-normalised by the rotated bounding box, or, for straighten, by the centred
    /// crop of scale k = min(W / (W·cosA + H·sinA), H / (W·sinA + H·cosA)) with the renderer's reduced angle.
    static func rotationMap(degrees: Double, aspect: Double, cropToContent: Bool) -> PSHomography? {
        guard degrees != 0, degrees.isFinite else { return nil }
        let (c, s) = cosSin(degrees)
        let width = aspect, height = 1.0
        let outWidth: Double, outHeight: Double
        if cropToContent {
            let radians = -degrees * .pi / 180
            let angle = abs(radians.truncatingRemainder(dividingBy: .pi / 2))
            let sinA = abs(sin(angle)), cosA = abs(cos(angle))
            let k = min(width / (width * cosA + height * sinA), height / (width * sinA + height * cosA))
            outWidth = k * width
            outHeight = k * height
        } else {
            outWidth = width * abs(c) + height * abs(s)
            outHeight = width * abs(s) + height * abs(c)
        }
        guard outWidth > 0, outHeight > 0 else { return nil }
        return .affine(a: c * width / outWidth, b: s * width / outHeight,
                       c: -s * height / outWidth, d: c * height / outHeight,
                       tx: 0.5 - (c * width - s * height) / (2 * outWidth),
                       ty: 0.5 - (s * width + c * height) / (2 * outHeight))
    }

    /// `PhotoRenderer.perspective` in top-left space: the image's corners (TL, TR, BR, BL) moved by
    /// hAmount = h·0.15·H and vAmount = v·0.15·W, and their bounding box (pixel units, W = aspect, H = 1).
    /// `normalized` is the moved corners in the output's normalised space. Nil when nothing moves.
    static func perspectiveCorners(horizontal: Double, vertical: Double, aspect: Double) -> (normalized: [PSPoint], size: PSSize)? {
        guard horizontal.isFinite, vertical.isFinite, horizontal != 0 || vertical != 0 else { return nil }
        let width = aspect, height = 1.0
        var topLeft = PSPoint(x: 0, y: 0), topRight = PSPoint(x: width, y: 0)
        var bottomRight = PSPoint(x: width, y: height), bottomLeft = PSPoint(x: 0, y: height)
        let hAmount = horizontal.clamped(to: -1...1) * height * 0.15
        let vAmount = vertical.clamped(to: -1...1) * width * 0.15
        // Core Image: tl.y −= h, bl.y += h (h > 0), else tr.y += h, br.y −= h; y flips in top-left space.
        if hAmount > 0 {
            topLeft.y += hAmount
            bottomLeft.y -= hAmount
        } else {
            topRight.y -= hAmount
            bottomRight.y += hAmount
        }
        // tl.x += v, tr.x −= v (v > 0), else bl.x −= v, br.x += v: x is the same in both spaces.
        if vAmount > 0 {
            topLeft.x += vAmount
            topRight.x -= vAmount
        } else {
            bottomLeft.x -= vAmount
            bottomRight.x += vAmount
        }
        let corners = [topLeft, topRight, bottomRight, bottomLeft]
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        guard maxX - minX > 1e-12, maxY - minY > 1e-12 else { return nil }
        let normalized = corners.map { PSPoint(x: ($0.x - minX) / (maxX - minX), y: ($0.y - minY) / (maxY - minY)) }
        return (normalized, PSSize(width: maxX - minX, height: maxY - minY))
    }
}

extension PSHomography {
    /// A usable aspect: finite and positive, else square.
    static func saneAspect(_ aspect: Double) -> Double {
        aspect.isFinite && aspect > 0 ? aspect : 1
    }

    /// Degrees into (−180, 180].
    static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value <= -180 { value += 360 }
        if value > 180 { value -= 360 }
        return value
    }
}

// MARK: - Masks through a map

public extension MaskStack {
    /// Points, brush strokes and raster corners moved by `map`; radii scaled by its local scale; ranges unchanged.
    /// `PhotoDocument` gets `aspectAfter` from `kind.aspect(after:)` (or the chain's aspect in reconcileMasks).
    ///
    /// The stack's feather and expand are lengths too (fractions of the longest side), so they scale with the map
    /// at the image centre: a mask keeps its soft edge on the same pixels after a crop.
    func remapped(by map: PSHomography, aspectBefore: Double, aspectAfter: Double) -> MaskStack {
        var stack = self
        stack.components = components.map { $0.remapped(by: map, aspectBefore: aspectBefore, aspectAfter: aspectAfter) }
        let scale = map.localScale(at: PSPoint(x: 0.5, y: 0.5), aspectBefore: aspectBefore, aspectAfter: aspectAfter)
        stack.feather = feather * scale
        stack.expand = expand * scale
        return stack
    }
}

public extension MaskComponent {
    /// This component in the space `map` leads to (D3): see `MaskStack.remapped(by:aspectBefore:aspectAfter:)`.
    func remapped(by map: PSHomography, aspectBefore: Double, aspectAfter: Double) -> MaskComponent {
        var component = self
        switch kind {
        case .raster(var raster):
            raster.corners = raster.corners.map(map.apply)
            component.kind = .raster(raster)
        case .brush(var spec):
            spec.strokes = spec.strokes.map { stroke in
                guard !stroke.points.isEmpty else { return stroke }
                var moved = stroke
                let centre = stroke.points.reduce(PSPoint.zero, +) * (1 / Double(stroke.points.count))
                moved.points = stroke.points.map(map.apply)
                moved.radius = stroke.radius * map.localScale(at: centre, aspectBefore: aspectBefore, aspectAfter: aspectAfter)
                return moved
            }
            component.kind = .brush(spec)
        case .linear(var spec):
            spec.start = map.apply(spec.start)
            spec.end = map.apply(spec.end)
            component.kind = .linear(spec)
        case .radial(let spec):
            component.kind = .radial(spec.remapped(by: map, aspectBefore: aspectBefore, aspectAfter: aspectAfter))
        case .depthRange(var spec):
            spec.depth.corners = spec.depth.corners.map(map.apply)
            component.kind = .depthRange(spec)
        case .colorRange, .luminanceRange, .unsupported:
            break
        }
        return component
    }
}

extension RadialGradientSpec {
    /// The centre through `map`, the radii by its local scale, and the rotation following the mapped major axis
    /// (exact for crops, turns, flips and expand, which are similarities in longest-side units).
    func remapped(by map: PSHomography, aspectBefore: Double, aspectAfter: Double) -> RadialGradientSpec {
        var spec = self
        spec.center = map.apply(center)
        let scale = map.localScale(at: center, aspectBefore: aspectBefore, aspectAfter: aspectAfter)
        spec.radiusX = radiusX * scale
        spec.radiusY = radiusY * scale
        let j = map.longestSideJacobian(at: center, aspectBefore: aspectBefore, aspectAfter: aspectAfter)
        let theta = rotation * .pi / 180
        // The major axis in longest-side units (y down, clockwise): along x when radiusX ≥ radiusY, else along y.
        let alongX = radiusX >= radiusY
        let axis = alongX ? (cos(theta), sin(theta)) : (-sin(theta), cos(theta))
        let mapped = (j[0] * axis.0 + j[1] * axis.1, j[2] * axis.0 + j[3] * axis.1)
        if (mapped.0 * mapped.0 + mapped.1 * mapped.1) > 1e-24 {
            spec.rotation = PSHomography.normalizedDegrees(atan2(mapped.1, mapped.0) * 180 / .pi - (alongX ? 0 : 90))
        }
        return spec
    }
}
