import Foundation

// D10 free transform: the handles around a placed layer, their hit test, and one drag frame → a new LayerTransform.
// Pure (view points in, canvas-normalised maths), Linux-tested; L3 draws and drives them. The maths runs in canvas
// pixels (normalised × canvas size) so angles and proportions are the ones the person sees.

public enum TransformMode: String, Hashable, Sendable, CaseIterable { case free, uniform, skew, distort, perspective }

public enum TransformHandleKind: Hashable, Sendable {
    /// 0 TL, 1 TR, 2 BR, 3 BL.
    case corner(Int)
    /// 0 top, 1 right, 2 bottom, 3 left.
    case edge(Int)
    case rotate, pivot, inside
}

public struct TransformHandle: Hashable, Sendable {
    public var kind: TransformHandleKind
    /// View points.
    public var position: PSPoint

    public init(kind: TransformHandleKind, position: PSPoint) {
        self.kind = kind
        self.position = position
    }
}

public enum TransformHandles {
    /// 44 pt targets.
    public static let hitRadius = 22.0
    /// The rotation knob's distance outward from the top-edge midpoint, in points.
    public static let rotateOffset = 28.0
    /// The smallest scale factor a drag may reach in one frame before it counts as degenerate.
    static let minimumFactor = 1e-3

    /// Corners (TL, TR, BR, BL), edge midpoints (top, right, bottom, left), rotation knob, pivot; from the quad in view
    /// points. The knob sits `rotateOffset` outward from the top edge's midpoint, along the edge's normal pointing away
    /// from the pivot (the quad's centroid). [] for anything but 4 finite points.
    public static func handles(viewQuad: [PSPoint]) -> [TransformHandle] {
        guard viewQuad.count == 4, viewQuad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var result = viewQuad.enumerated().map { TransformHandle(kind: .corner($0.offset), position: $0.element) }
        for index in 0..<4 {
            result.append(TransformHandle(kind: .edge(index), position: midpoint(viewQuad[index], viewQuad[(index + 1) % 4])))
        }
        result.append(TransformHandle(kind: .rotate, position: knob(viewQuad)))
        result.append(TransformHandle(kind: .pivot, position: centroid(viewQuad)))
        return result
    }

    /// The handle under `point`, by priority corner > edge > rotate > inside (the nearest of a kind when several are in
    /// reach); nil outside every target. Targets are `hitRadius` around each handle whatever the zoom: the quad is in
    /// view points. The pivot is drawn, not dragged.
    public static func hit(_ point: PSPoint, viewQuad: [PSPoint]) -> TransformHandleKind? {
        let all = handles(viewQuad: viewQuad)
        guard !all.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        func nearest(_ matches: (TransformHandleKind) -> Bool) -> TransformHandleKind? {
            all.filter { matches($0.kind) && $0.position.distance(to: point) <= hitRadius }
                .min { $0.position.distance(to: point) < $1.position.distance(to: point) }?.kind
        }
        if let corner = nearest({ if case .corner = $0 { return true } else { return false } }) { return corner }
        if let edge = nearest({ if case .edge = $0 { return true } else { return false } }) { return edge }
        if let rotate = nearest({ $0 == .rotate }) { return rotate }
        return contains(viewQuad, point) ? .inside : nil
    }

    /// One drag frame (D10). `start` is the layer's transform at drag start as it places the layer
    /// (`LayerPlacement.effectiveTransform(of:)`: a text layer's centre and rotation come from its element), `startQuad`
    /// its placed corners then; `translation` (since the drag began) and `location` (the finger now) are
    /// canvas-normalised. Returns `start` unchanged when the result would be degenerate (a scale through zero, a skew
    /// past ±80°'s reach, an invalid quad).
    /// - free: a corner scales uniformly about the opposite corner (about the centre with `anchorAtCenter`, two
    ///   fingers), an edge scales its axis alone about the opposite edge;
    /// - uniform: corners and edges both scale uniformly;
    /// - skew: an edge shears along its own direction (top and bottom: skewX; left and right: skewY), clamped to ±80°;
    ///   corners scale as in free;
    /// - distort: a corner moves alone, an edge moves its two corners; writes `quad` (the affine placement is
    ///   converted on the first such drag);
    /// - perspective: a corner and its mirror on the same edge move symmetrically, along the axis the finger moved
    ///   most; writes `quad`.
    /// Inside moves the layer; the rotate knob turns it about the pivot (snapping is the caller's, `rotationSnap`).
    public static func drag(_ kind: TransformHandleKind, mode: TransformMode, start: LayerTransform, startQuad: [PSPoint],
                            translation: PSPoint, location: PSPoint, anchorAtCenter: Bool,
                            contentSize: PSSize, canvasSize: PSSize) -> LayerTransform {
        guard startQuad.count == 4, startQuad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), translation.x.isFinite, translation.y.isFinite,
              canvasSize.width > 0, canvasSize.height > 0 else { return start }
        let space = PixelSpace(canvas: canvasSize)
        let quad = startQuad.map(space.pixels)
        let move = PSPoint(x: translation.x * canvasSize.width, y: translation.y * canvasSize.height)
        let aspect = canvasSize.width / canvasSize.height
        switch kind {
        case .pivot:
            return start
        case .inside:
            var result = start
            if let startQuadPoints = start.quad {
                result.quad = startQuadPoints.map { PSPoint(x: $0.x + translation.x, y: $0.y + translation.y) }
            } else {
                result.center = PSPoint(x: start.center.x + translation.x, y: start.center.y + translation.y)
            }
            return result
        case .rotate:
            let pivot = centroid(quad)
            let finger = space.pixels(location)
            let grabbed = PSPoint(x: finger.x - move.x, y: finger.y - move.y)
            guard grabbed.distance(to: pivot) > 1e-9, finger.distance(to: pivot) > 1e-9 else { return start }
            let delta = atan2(finger.y - pivot.y, finger.x - pivot.x) - atan2(grabbed.y - pivot.y, grabbed.x - pivot.x)
            var result = start
            if start.quad != nil {
                result.quad = quad.map { rotated($0, about: pivot, by: delta) }.map(space.normalised)
            } else {
                var degrees = start.rotation + delta * 180 / .pi
                degrees += 360 * ((start.rotation - degrees) / 360).rounded()
                result.rotation = degrees
            }
            return result
        case .corner(let index):
            guard (0..<4).contains(index) else { return start }
            switch mode {
            case .distort:
                return quadResult(start, moving: [index: move], quad: quad, space: space, aspect: aspect)
            case .perspective:
                return perspectiveResult(start, corner: index, move: move, quad: quad, space: space, aspect: aspect)
            case .free, .uniform, .skew:
                let anchor = anchorAtCenter ? centroid(quad) : quad[(index + 2) % 4]
                let grabbed = quad[index]
                let dragged = PSPoint(x: grabbed.x + move.x, y: grabbed.y + move.y)
                let span = PSPoint(x: grabbed.x - anchor.x, y: grabbed.y - anchor.y)
                let length2 = span.x * span.x + span.y * span.y
                guard length2 > 1e-18 else { return start }
                let factor = ((dragged.x - anchor.x) * span.x + (dragged.y - anchor.y) * span.y) / length2
                return scaled(start, by: factor, factorY: factor, about: anchor, quad: quad, space: space, aspect: aspect)
            }
        case .edge(let index):
            guard (0..<4).contains(index) else { return start }
            let a = index, b = (index + 1) % 4
            switch mode {
            case .distort, .perspective:
                return quadResult(start, moving: [a: move, b: move], quad: quad, space: space, aspect: aspect)
            case .skew:
                return skewed(start, edge: index, move: move, anchorAtCenter: anchorAtCenter, quad: quad, contentSize: contentSize, space: space, aspect: aspect)
            case .free, .uniform:
                let dragged = midpoint(quad[a], quad[b])
                let opposite = midpoint(quad[(index + 2) % 4], quad[(index + 3) % 4])
                let anchor = anchorAtCenter ? centroid(quad) : opposite
                let span = PSPoint(x: dragged.x - anchor.x, y: dragged.y - anchor.y)
                let length2 = span.x * span.x + span.y * span.y
                guard length2 > 1e-18 else { return start }
                let moved = PSPoint(x: dragged.x + move.x, y: dragged.y + move.y)
                let factor = ((moved.x - anchor.x) * span.x + (moved.y - anchor.y) * span.y) / length2
                if mode == .uniform {
                    return scaled(start, by: factor, factorY: factor, about: anchor, quad: quad, space: space, aspect: aspect)
                }
                // Top and bottom edges scale the content's y axis, right and left its x axis.
                let alongY = index == 0 || index == 2
                return scaled(start, by: alongY ? 1 : factor, factorY: alongY ? factor : 1, about: anchor, quad: quad, space: space, aspect: aspect,
                              axisVector: span)
            }
        }
    }

    /// Snaps to the nearest multiple of `step` within `tolerance` degrees.
    public static func rotationSnap(_ degrees: Double, step: Double = 15, tolerance: Double = 2) -> (degrees: Double, snapped: Bool) {
        guard degrees.isFinite, step > 0 else { return (degrees, false) }
        let nearest = (degrees / step).rounded() * step
        return abs(degrees - nearest) <= tolerance ? (nearest, true) : (degrees, false)
    }

    /// A quad with a self-intersection or a corner angle ≥ 179° is invalid. `aspect` (w/h) turns canvas-normalised
    /// points into square units before the angles are measured.
    public static func isValidQuad(_ quad: [PSPoint], aspect: Double) -> Bool {
        guard quad.count == 4, quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 1
        let points = quad.map { PSPoint(x: $0.x * ratio, y: $0.y) }
        var sign = 0.0
        for index in 0..<4 {
            let previous = points[(index + 3) % 4], corner = points[index], next = points[(index + 1) % 4]
            let a = PSPoint(x: previous.x - corner.x, y: previous.y - corner.y)
            let b = PSPoint(x: next.x - corner.x, y: next.y - corner.y)
            let lengths = (a.x * a.x + a.y * a.y).squareRoot() * (b.x * b.x + b.y * b.y).squareRoot()
            guard lengths > 1e-12 else { return false }
            // Convex and simple: every turn has the same orientation.
            let cross = a.x * b.y - a.y * b.x
            guard abs(cross) > 1e-12 else { return false }
            if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
            let cosine = ((a.x * b.x + a.y * b.y) / lengths).clamped(to: -1...1)
            guard acos(cosine) * 180 / .pi < 179 else { return false }
        }
        return true
    }

    // MARK: Internals

    /// Canvas-normalised ↔ canvas pixels.
    struct PixelSpace {
        let canvas: PSSize
        func pixels(_ point: PSPoint) -> PSPoint { PSPoint(x: point.x * canvas.width, y: point.y * canvas.height) }
        func normalised(_ point: PSPoint) -> PSPoint { PSPoint(x: point.x / canvas.width, y: point.y / canvas.height) }
    }

    static func midpoint(_ a: PSPoint, _ b: PSPoint) -> PSPoint { PSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    static func centroid(_ quad: [PSPoint]) -> PSPoint {
        PSPoint(x: quad.reduce(0) { $0 + $1.x } / Double(quad.count), y: quad.reduce(0) { $0 + $1.y } / Double(quad.count))
    }

    static func rotated(_ point: PSPoint, about pivot: PSPoint, by radians: Double) -> PSPoint {
        let c = cos(radians), s = sin(radians)
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        return PSPoint(x: pivot.x + c * dx - s * dy, y: pivot.y + s * dx + c * dy)
    }

    static func knob(_ quad: [PSPoint]) -> PSPoint {
        let mid = midpoint(quad[0], quad[1])
        let edge = PSPoint(x: quad[1].x - quad[0].x, y: quad[1].y - quad[0].y)
        let length = (edge.x * edge.x + edge.y * edge.y).squareRoot()
        var normal = length > 1e-12 ? PSPoint(x: edge.y / length, y: -edge.x / length) : PSPoint(x: 0, y: -1)
        let center = centroid(quad)
        // Outward: away from the pivot.
        if (mid.x - center.x) * normal.x + (mid.y - center.y) * normal.y < 0 { normal = PSPoint(x: -normal.x, y: -normal.y) }
        return PSPoint(x: mid.x + normal.x * rotateOffset, y: mid.y + normal.y * rotateOffset)
    }

    /// Point in a (convex or not) quad, by the even-odd rule.
    static func contains(_ quad: [PSPoint], _ point: PSPoint) -> Bool {
        guard quad.count >= 3 else { return false }
        var inside = false
        var j = quad.count - 1
        for i in 0..<quad.count {
            let a = quad[i], b = quad[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Scales about a pixel-space anchor: uniformly (`factor` = `factorY`), or one content axis (`axisVector` the
    /// dragged direction); the centre follows so the anchor stays put. On a quad layer the quad's points scale.
    static func scaled(_ start: LayerTransform, by factor: Double, factorY: Double, about anchor: PSPoint, quad: [PSPoint],
                       space: PixelSpace, aspect: Double, axisVector: PSPoint? = nil) -> LayerTransform {
        guard factor.isFinite, factorY.isFinite, factor >= minimumFactor, factorY >= minimumFactor else { return start }
        let uniform = abs(factor - factorY) < 1e-15
        func moved(_ point: PSPoint) -> PSPoint {
            if uniform { return PSPoint(x: anchor.x + (point.x - anchor.x) * factor, y: anchor.y + (point.y - anchor.y) * factor) }
            // One axis: scale the component along the dragged direction only.
            guard let axis = axisVector else { return point }
            let length2 = axis.x * axis.x + axis.y * axis.y
            let k = factor != 1 ? factor : factorY
            let along = ((point.x - anchor.x) * axis.x + (point.y - anchor.y) * axis.y) / length2
            return PSPoint(x: point.x + axis.x * along * (k - 1), y: point.y + axis.y * along * (k - 1))
        }
        var result = start
        if start.quad != nil {
            let next = quad.map(moved).map(space.normalised)
            guard isValidQuad(next, aspect: aspect) else { return start }
            result.quad = next
            return result
        }
        let center = space.pixels(start.center)
        result.center = space.normalised(moved(center))
        if uniform {
            result.scale = start.scale * factor
        } else {
            result.scaleX = start.scaleX * factor
            result.scaleY = start.scaleY * factorY
        }
        return result
    }

    /// Skew mode: the dragged edge slides along its own direction; the opposite edge (or the centre) stays.
    static func skewed(_ start: LayerTransform, edge: Int, move: PSPoint, anchorAtCenter: Bool, quad: [PSPoint], contentSize: PSSize,
                       space: PixelSpace, aspect: Double) -> LayerTransform {
        guard start.quad == nil else {
            // A quad layer has no skew: its edge moves as in distort.
            return quadResult(start, moving: [edge: move, (edge + 1) % 4: move], quad: quad, space: space, aspect: aspect)
        }
        // The edge-to-edge vector (opposite edge → dragged edge) and the edge's own direction, in pixels.
        let dragged = midpoint(quad[edge], quad[(edge + 1) % 4]), opposite = midpoint(quad[(edge + 2) % 4], quad[(edge + 3) % 4])
        let across = PSPoint(x: dragged.x - opposite.x, y: dragged.y - opposite.y)
        let along = PSPoint(x: quad[(edge + 1) % 4].x - quad[edge].x, y: quad[(edge + 1) % 4].y - quad[edge].y)
        let alongLength = (along.x * along.x + along.y * along.y).squareRoot()
        guard alongLength > 1e-12 else { return start }
        let unit = PSPoint(x: along.x / alongLength, y: along.y / alongLength)
        let slide = move.x * unit.x + move.y * unit.y
        // The rotation frame: θ undoes the layer's turn; the shear is measured there.
        let theta = (start.rotation.isFinite ? start.rotation : 0) * .pi / 180
        func unrotated(_ p: PSPoint) -> PSPoint { PSPoint(x: cos(theta) * p.x + sin(theta) * p.y, y: -sin(theta) * p.x + cos(theta) * p.y) }
        let slideVector = unrotated(PSPoint(x: unit.x * slide, y: unit.y * slide))
        let acrossFrame = unrotated(across)
        let topOrBottom = edge == 0 || edge == 2
        // top/bottom: tan kx = x / y of the across vector (in the frame); left/right: tan ky = y / x.
        let span = anchorAtCenter ? 2.0 : 1.0
        var result = start
        if topOrBottom {
            guard abs(acrossFrame.y) > 1e-12 else { return start }
            let current = tan(LayerPlacement.clampedSkew(start.skewX) * .pi / 180)
            let next = current + span * slideVector.x / acrossFrame.y
            let degrees = atan(next) * 180 / .pi
            guard abs(degrees) <= 80 else { return start }
            result.skewX = degrees
        } else {
            guard abs(acrossFrame.x) > 1e-12 else { return start }
            let current = tan(LayerPlacement.clampedSkew(start.skewY) * .pi / 180)
            let next = current + span * slideVector.y / acrossFrame.x
            let degrees = atan(next) * 180 / .pi
            guard abs(degrees) <= 80 else { return start }
            result.skewY = degrees
        }
        if !anchorAtCenter {
            // The opposite edge stays: the centre slides by half the edge's move.
            let center = space.pixels(start.center)
            result.center = space.normalised(PSPoint(x: center.x + unit.x * slide / 2, y: center.y + unit.y * slide / 2))
        }
        return result
    }

    /// Distort: the given corners move by their pixel offsets; the result is a valid quad or `start`.
    static func quadResult(_ start: LayerTransform, moving offsets: [Int: PSPoint], quad: [PSPoint], space: PixelSpace, aspect: Double) -> LayerTransform {
        var next = quad
        for (index, offset) in offsets { next[index] = PSPoint(x: next[index].x + offset.x, y: next[index].y + offset.y) }
        let normalised = next.map(space.normalised)
        guard isValidQuad(normalised, aspect: aspect) else { return start }
        var result = start
        result.quad = normalised
        return result
    }

    /// Perspective: the corner and its mirror on one edge move symmetrically along that edge (the axis the finger
    /// moved most along: the top or bottom edge, else the left or right one).
    static func perspectiveResult(_ start: LayerTransform, corner: Int, move: PSPoint, quad: [PSPoint], space: PixelSpace, aspect: Double) -> LayerTransform {
        let horizontalMirror = [1, 0, 3, 2][corner], verticalMirror = [3, 2, 1, 0][corner]
        func unit(_ from: Int, _ to: Int) -> PSPoint? {
            let d = PSPoint(x: quad[to].x - quad[from].x, y: quad[to].y - quad[from].y)
            let length = (d.x * d.x + d.y * d.y).squareRoot()
            return length > 1e-12 ? PSPoint(x: d.x / length, y: d.y / length) : nil
        }
        guard let horizontal = unit(horizontalMirror, corner), let vertical = unit(verticalMirror, corner) else { return start }
        let alongH = move.x * horizontal.x + move.y * horizontal.y
        let alongV = move.x * vertical.x + move.y * vertical.y
        // Outward along the edge for this corner, inward for its mirror (they spread or close symmetrically).
        if abs(alongH) >= abs(alongV) {
            return quadResult(start, moving: [corner: PSPoint(x: horizontal.x * alongH, y: horizontal.y * alongH),
                                              horizontalMirror: PSPoint(x: -horizontal.x * alongH, y: -horizontal.y * alongH)],
                              quad: quad, space: space, aspect: aspect)
        }
        return quadResult(start, moving: [corner: PSPoint(x: vertical.x * alongV, y: vertical.y * alongV),
                                          verticalMirror: PSPoint(x: -vertical.x * alongV, y: -vertical.y * alongV)],
                          quad: quad, space: space, aspect: aspect)
    }
}

public extension LayerPlacement {
    /// The transform as it places the layer: a text layer's centre and rotation come from its element (the W1 rule,
    /// `textPlacement`), the rest from the layer. What `TransformHandles.drag` takes as `start` and what
    /// `applyLayerEdit(.transform)` writes back.
    static func effectiveTransform(of layer: Layer) -> LayerTransform {
        var transform = layer.transform
        let placement = textPlacement(of: layer)
        transform.center = placement.center
        transform.rotation = placement.rotation
        return transform
    }
}
