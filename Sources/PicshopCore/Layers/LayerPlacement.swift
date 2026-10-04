import Foundation

// D10 placement maths shared by the renderer (L2), the transform handles and guides (L3), re-grounding (L4) and the
// document itself (D10b). Pure, Linux-tested. A layer's content (its unit square, top-left origin) lands on the
// canvas (normalised, top-left origin) through
//   P(u,v) = T(cx·W, cy·H) · R(θ) · K(kx, ky) · S(±fit·s·sx, ±fit·s·sy) · T(−w/2, −h/2) · (u·w, v·h)
// in pixels, normalised by (W, H), with fit = min(W/w, H/h, 1) (W1's composite), θ clockwise in y-down
// coordinates, K = [[1, tan kx], [tan ky, 1]] and ± the flips; a 4-corner `quad` replaces all of it.

public enum LayerPlacement {
    /// Image layers: the asset's pixel size through the layer's geometric operations; nil for other contents.
    public static func contentSize(of layer: Layer) -> PSSize? {
        guard let asset = layer.imageAsset else { return nil }
        return layer.edits.outputSize(sourcePixels: asset.pixelSize)
    }

    /// The content size where Core knows it at a canvas size: image layers as above; shapes, the raster
    /// TextRasterizer draws (the shape's canvas-relative size, at least 2 px); fill, gradient, adjustment and group
    /// layers cover the canvas. Nil for text (its size needs font metrics: L2's `contentSize(of:in:)`).
    public static func contentSize(of layer: Layer, canvasSize: PSSize) -> PSSize? {
        switch layer.content {
        case .image: return contentSize(of: layer)
        case .shape(let shape):
            return PSSize(width: max(2, shape.relativeSize.width * canvasSize.width), height: max(2, shape.relativeSize.height * canvasSize.height))
        case .fill, .gradientFill, .adjustment, .group: return canvasSize
        case .text, .unsupported: return nil
        }
    }

    /// Text layers: (centre, rotation) from the TextElement; others from the transform (the W1 OverlayPlacement rule).
    public static func textPlacement(of layer: Layer) -> (center: PSPoint, rotation: Double) {
        if let element = layer.textElement { return (element.center, element.rotation) }
        return (layer.transform.center, layer.transform.rotation)
    }

    /// D10: content unit square (top-left) → canvas-normalised (top-left). The base layer, and a degenerate size: the
    /// identity. A valid `quad` (4 finite corners, not degenerate) wins over every other field.
    public static func map(for layer: Layer, contentSize: PSSize, canvasSize: PSSize, isBase: Bool) -> PSHomography {
        guard !isBase else { return .identity }
        if let quad = layer.transform.quad, quad.count == 4, let homography = PSHomography.quad(from: RasterRef.unitCorners, to: quad) {
            return homography
        }
        guard contentSize.width > 0, contentSize.height > 0, canvasSize.width > 0, canvasSize.height > 0,
              contentSize.width.isFinite, contentSize.height.isFinite, canvasSize.width.isFinite, canvasSize.height.isFinite else { return .identity }
        let (center, rotation) = textPlacement(of: layer)
        let fit = fitScale(contentSize: contentSize, canvasSize: canvasSize)
        let a = linearPart(of: layer.transform, rotation: rotation, fit: fit)
        let w = contentSize.width, h = contentSize.height, width = canvasSize.width, height = canvasSize.height
        // x_n = cx + (A11 (u·w − w/2) + A12 (v·h − h/2)) / W, y_n likewise with the second row and H.
        return .affine(a: a.m11 * w / width, b: a.m21 * w / height, c: a.m12 * h / width, d: a.m22 * h / height,
                       tx: center.x - (a.m11 * w / 2 + a.m12 * h / 2) / width,
                       ty: center.y - (a.m21 * w / 2 + a.m22 * h / 2) / height)
    }

    /// The four placed corners (TL, TR, BR, BL of the content), canvas-normalised.
    public static func quad(for layer: Layer, contentSize: PSSize, canvasSize: PSSize, isBase: Bool) -> [PSPoint] {
        let placement = map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: isBase)
        return RasterRef.unitCorners.map(placement.apply)
    }

    /// The axis-aligned box of the placed corners, canvas-normalised.
    public static func bounds(for layer: Layer, contentSize: PSSize, canvasSize: PSSize, isBase: Bool) -> PSRect {
        boundingBox(of: quad(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: isBase))
    }

    /// Canvas-normalised → the content unit square; nil when the placement is degenerate.
    public static func inverseMap(for layer: Layer, contentSize: PSSize, canvasSize: PSSize, isBase: Bool) -> PSHomography? {
        map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: isBase).inverse
    }

    /// The fitted content size in canvas pixels before scale (min(W/w, H/h, 1)), shared with L2.
    public static func fitScale(contentSize: PSSize, canvasSize: PSSize) -> Double {
        guard contentSize.width > 0, contentSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        let fit = min(canvasSize.width / contentSize.width, canvasSize.height / contentSize.height, 1)
        return fit.isFinite && fit > 0 ? fit : 1
    }

    /// The transform that places the content exactly on `quad` (canvas-normalised, TL TR BR BL) when it is a
    /// parallelogram, else nil. The decomposition keeps rotation, a uniform scale, scaleX/Y at 1 when the quad's sides
    /// are in the content's proportions, the shear in skewX (skewY 0), and at most one flip (the vertical one).
    public static func affineTransform(fromQuad quad: [PSPoint], contentSize: PSSize, canvasSize: PSSize) -> LayerTransform? {
        affineTransform(fromQuad: quad, contentSize: contentSize, canvasSize: canvasSize, preferring: nil)
    }

    /// D10 align and distribute: a canvas-normalised translation for every box. The alignments move each box onto the
    /// reference: the canvas when `canvas` is true, else the union of the boxes. distributeH and distributeV keep the
    /// outer two boxes (by centre) and equalise the gaps between ≥ 3 boxes; with fewer, nothing moves. Callers skip
    /// position-locked layers and apply every translation as `.transform` in one history step.
    public static func alignment(_ alignment: LayerAlignment, boxes: [UUID: PSRect], canvas: Bool) -> [UUID: PSPoint] {
        guard !boxes.isEmpty else { return [:] }
        let reference = canvas ? PSRect.unit : boxes.values.dropFirst().reduce(boxes.values.first!) { $0.union($1) }
        var result: [UUID: PSPoint] = [:]
        switch alignment {
        case .left, .centerH, .right, .top, .centerV, .bottom:
            for (id, box) in boxes {
                switch alignment {
                case .left: result[id] = PSPoint(x: reference.minX - box.minX, y: 0)
                case .centerH: result[id] = PSPoint(x: reference.midX - box.midX, y: 0)
                case .right: result[id] = PSPoint(x: reference.maxX - box.maxX, y: 0)
                case .top: result[id] = PSPoint(x: 0, y: reference.minY - box.minY)
                case .centerV: result[id] = PSPoint(x: 0, y: reference.midY - box.midY)
                case .bottom: result[id] = PSPoint(x: 0, y: reference.maxY - box.maxY)
                case .distributeH, .distributeV: break
                }
            }
        case .distributeH, .distributeV:
            let horizontal = alignment == .distributeH
            for id in boxes.keys { result[id] = .zero }
            guard boxes.count >= 3 else { return result }
            let ordered = boxes.sorted { lhs, rhs in
                let a = horizontal ? lhs.value.midX : lhs.value.midY, b = horizontal ? rhs.value.midX : rhs.value.midY
                return a != b ? a < b : lhs.key.uuidString < rhs.key.uuidString
            }
            func low(_ r: PSRect) -> Double { horizontal ? r.minX : r.minY }
            func high(_ r: PSRect) -> Double { horizontal ? r.maxX : r.maxY }
            func length(_ r: PSRect) -> Double { horizontal ? r.width : r.height }
            let first = ordered.first!.value, last = ordered.last!.value
            let inner = ordered.dropFirst().dropLast()
            let gap = (low(last) - high(first) - inner.reduce(0) { $0 + length($1.value) }) / Double(ordered.count - 1)
            var cursor = high(first) + gap
            for (id, box) in inner {
                let delta = cursor - low(box)
                result[id] = horizontal ? PSPoint(x: delta, y: 0) : PSPoint(x: 0, y: delta)
                cursor += length(box) + gap
            }
        }
        return result
    }

    // MARK: Internals

    /// R(θ) · K(kx, ky) · S(±fit·s·sx, ±fit·s·sy), the pixel-space linear part (skews clamped to ±80°).
    static func linearPart(of transform: LayerTransform, rotation: Double, fit: Double) -> (m11: Double, m12: Double, m21: Double, m22: Double) {
        let radians = (rotation.isFinite ? rotation : 0) * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        let skewX = tan(clampedSkew(transform.skewX) * .pi / 180), skewY = tan(clampedSkew(transform.skewY) * .pi / 180)
        let scale = fit * (transform.scale.isFinite ? transform.scale : 1)
        let a = scale * (transform.scaleX.isFinite ? transform.scaleX : 1) * (transform.isFlippedHorizontally ? -1 : 1)
        let b = scale * (transform.scaleY.isFinite ? transform.scaleY : 1) * (transform.isFlippedVertically ? -1 : 1)
        // K · S = [[a, kx·b], [ky·a, b]], then R on the left.
        let k11 = a, k12 = skewX * b, k21 = skewY * a, k22 = b
        return (cosine * k11 - sine * k21, cosine * k12 - sine * k22, sine * k11 + cosine * k21, sine * k12 + cosine * k22)
    }

    static func clampedSkew(_ degrees: Double) -> Double {
        degrees.isFinite ? degrees.clamped(to: -80...80) : 0
    }

    static func boundingBox(of points: [PSPoint]) -> PSRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return PSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether four canvas-normalised corners form a parallelogram, measured in pixels (TL + BR = TR + BL).
    static func isParallelogram(_ quad: [PSPoint], canvasSize: PSSize, tolerance: Double = 1e-9) -> Bool {
        guard quad.count == 4 else { return false }
        let width = max(canvasSize.width, 1e-9), height = max(canvasSize.height, 1e-9)
        let dx = (quad[0].x + quad[2].x - quad[1].x - quad[3].x) * width
        let dy = (quad[0].y + quad[2].y - quad[1].y - quad[3].y) * height
        let size = max(boundingBox(of: quad).width * width, boundingBox(of: quad).height * height, 1)
        return (dx * dx + dy * dy).squareRoot() <= tolerance * size
    }

    /// `affineTransform(fromQuad:)` keeping a previous transform's representation where the quad allows it (D10b):
    /// its skew parametrisation, its flips, its scaleX : scaleY product and its rotation's turn, so a layer moved with
    /// the photo changes only what the move changed. Snaps values within 1e-12 of the hint's (or of the defaults).
    static func affineTransform(fromQuad quad: [PSPoint], contentSize: PSSize, canvasSize: PSSize, preferring hint: LayerTransform?) -> LayerTransform? {
        guard quad.count == 4, quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), contentSize.width > 0, contentSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0, isParallelogram(quad, canvasSize: canvasSize) else { return nil }
        let width = canvasSize.width, height = canvasSize.height, w = contentSize.width, h = contentSize.height
        // The pixel-space linear part: its columns are the content's x and y axes, per content pixel.
        let a11 = (quad[1].x - quad[0].x) * width / w, a21 = (quad[1].y - quad[0].y) * height / w
        let a12 = (quad[3].x - quad[0].x) * width / h, a22 = (quad[3].y - quad[0].y) * height / h
        guard abs(a11 * a22 - a12 * a21) > 1e-18 else { return nil }
        let hint = hint ?? .identity
        // Which skew stays fixed: skewY at 0 (the default), skewX at 0 for a layer sheared along y, else the hint's skewX.
        let fixesSkewY = hint.skewY == 0 || !hint.skewY.isFinite
        let fixedSkewX = tan(clampedSkew(hint.skewX == 0 || fixesSkewY ? 0 : hint.skewX) * .pi / 180)
        let theta0: Double = fixesSkewY ? atan2(a21, a11) : atan2(-(a12 - fixedSkewX * a22), a22 + fixedSkewX * a12)
        struct Candidate { var theta: Double; var a: Double; var b: Double; var tanX: Double; var tanY: Double }
        func candidate(_ theta: Double) -> Candidate {
            let c = cos(theta), s = sin(theta)
            // M = R(−θ) · A = K · diag(a, b).
            let m11 = c * a11 + s * a21, m12 = c * a12 + s * a22, m21 = -s * a11 + c * a21, m22 = -s * a12 + c * a22
            if fixesSkewY {
                return Candidate(theta: theta, a: m11, b: m22, tanX: abs(m22) > 1e-300 ? m12 / m22 : 0, tanY: 0)
            }
            return Candidate(theta: theta, a: m11, b: m22, tanX: fixedSkewX, tanY: abs(m11) > 1e-300 ? m21 / m11 : 0)
        }
        let hintRotation = (hint.rotation.isFinite ? hint.rotation : 0) * .pi / 180
        func flipMismatch(_ k: Candidate) -> Int {
            ((k.a < 0) != hint.isFlippedHorizontally ? 1 : 0) + ((k.b < 0) != hint.isFlippedVertically ? 1 : 0)
        }
        func turnDistance(_ k: Candidate) -> Double {
            let delta = (k.theta - hintRotation).truncatingRemainder(dividingBy: 2 * .pi)
            let wrapped = abs(delta) > .pi ? 2 * .pi - abs(delta) : abs(delta)
            return wrapped
        }
        let first = candidate(theta0), second = candidate(theta0 + .pi)
        let chosen: Candidate
        if flipMismatch(first) != flipMismatch(second) {
            chosen = flipMismatch(first) < flipMismatch(second) ? first : second
        } else if hint.isFlippedHorizontally == hint.isFlippedVertically, (first.a < 0) != (first.b < 0) {
            // One flip is needed and the hint has none (or both): the vertical one, keeping the hint's turn (W2 rule).
            chosen = turnDistance(first) <= turnDistance(second) ? first : second
        } else {
            chosen = turnDistance(first) <= turnDistance(second) ? first : second
        }
        let fit = fitScale(contentSize: contentSize, canvasSize: canvasSize)
        let hintX = hint.scaleX.isFinite && hint.scaleX > 0 ? hint.scaleX : 1
        let hintY = hint.scaleY.isFinite && hint.scaleY > 0 ? hint.scaleY : 1
        let scale = (abs(chosen.a * chosen.b) / (hintX * hintY)).squareRoot() / fit
        guard scale.isFinite, scale > 0 else { return nil }
        func snap(_ value: Double, to target: Double) -> Double { abs(value - target) <= 1e-12 * max(1, abs(target)) ? target : value }
        var result = hint
        result.quad = nil
        result.center = PSPoint(x: (quad[0].x + quad[2].x) / 2, y: (quad[0].y + quad[2].y) / 2)
        // The rotation in degrees, on the hint's turn (its multiple of 360° kept).
        var degrees = chosen.theta * 180 / .pi
        let reference = hint.rotation.isFinite ? hint.rotation : 0
        degrees += 360 * ((reference - degrees) / 360).rounded()
        result.rotation = snap(snap(degrees, to: reference), to: degrees.rounded())
        result.scale = snap(scale, to: hint.scale)
        result.scaleX = snap(abs(chosen.a) / (fit * scale), to: hintX)
        result.scaleY = snap(abs(chosen.b) / (fit * scale), to: hintY)
        result.skewX = snap(atan(chosen.tanX) * 180 / .pi, to: hint.skewX)
        result.skewY = snap(atan(chosen.tanY) * 180 / .pi, to: hint.skewY)
        result.isFlippedHorizontally = chosen.a < 0
        result.isFlippedVertically = chosen.b < 0
        return result
    }
}

/// D10 align and distribute: to the selection's union box (or the canvas for one layer); distribute keeps the outer
/// two of ≥ 3 boxes and equalises the gaps.
public enum LayerAlignment: String, Hashable, Sendable, CaseIterable {
    case left, centerH, right, top, centerV, bottom, distributeH, distributeV
}

// MARK: - D10b: layers follow the photo

public extension PhotoDocument {
    /// D10b, called by `append` for a geometric kind on the base (after the canvas update and `reconcileMasks`), by
    /// the W2 reconcile entry point and by `restoredToImport`: every other layer moves with the photo through
    /// M = inverse(old chain) ∘ new chain (canvas-normalised, as `reconcileMasks`):
    /// - image layers: their placed corners Q on the old canvas go to M(Q), written back as a transform on the new
    ///   canvas (`affineTransform(fromQuad:)`, keeping the layer's representation), or as `quad` when M(Q) is not a
    ///   parallelogram (a perspective of the base) or the layer already had one;
    /// - text and shapes: their centre and rotation through M, their canvas-relative sizes rescaled so their pixel size
    ///   changes only as the photo's pixels do (the local scale of M along their own axes);
    /// - gradient fills: centre through M, angle through M's linear part, scale by its mean scale;
    /// - layer masks in canvas space (unlinked ones, and every mask of a fill, adjustment or group layer):
    ///   `MaskStack.remapped`. Linked masks, legacy masks and non-base local adjustments live in the layer's content
    ///   space and move with it.
    /// A layer that ends off the canvas is kept. Locks do not stop it: it is the photo that moved.
    mutating func followBaseGeometry(previousBaseEdits: EditStack, previousCanvas: PSSize) {
        guard let baseID = baseLayerID, let base = layer(id: baseID), layers.count > 1 else { return }
        let newCanvas = canvasSize
        guard !previousCanvas.isEmpty, !newCanvas.isEmpty, previousCanvas.width.isFinite, previousCanvas.height.isFinite else { return }
        let source = sourceAspect(of: base)
        let old = previousBaseEdits.geometryChain(sourceAspect: source)
        let new = base.edits.geometryChain(sourceAspect: source)
        let sameMap = old.map.isApproximatelyEqual(to: new.map) && abs(old.aspect - new.aspect) <= 1e-12
        guard !(sameMap && previousCanvas == newCanvas), let back = old.map.inverse else { return }
        let map = back.then(new.map)
        let follower = LayerFollower(map: map, oldCanvas: previousCanvas, newCanvas: newCanvas, oldAspect: old.aspect, newAspect: new.aspect)
        for index in layers.indices where layers[index].id != baseID {
            let moved = follower.followed(layers[index])
            if moved != layers[index] { layers[index] = moved }
        }
    }
}

/// D10b for one layer (see `followBaseGeometry`).
struct LayerFollower {
    let map: PSHomography
    let oldCanvas: PSSize
    let newCanvas: PSSize
    let oldAspect: Double
    let newAspect: Double

    func followed(_ input: Layer) -> Layer {
        var layer = input
        // Masks in canvas space.
        let canvasSpaceContent: Bool
        switch layer.content {
        case .image, .text, .shape: canvasSpaceContent = false
        case .fill, .gradientFill, .adjustment, .group, .unsupported: canvasSpaceContent = true
        }
        if let stack = layer.maskStack, canvasSpaceContent || !layer.isMaskLinked {
            layer.maskStack = stack.remapped(by: map, aspectBefore: oldAspect, aspectAfter: newAspect)
        }
        switch layer.content {
        case .image:
            guard let contentSize = LayerPlacement.contentSize(of: layer), !contentSize.isEmpty else { break }
            let corners = LayerPlacement.quad(for: layer, contentSize: contentSize, canvasSize: oldCanvas, isBase: false).map(map.apply)
            guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { break }
            if layer.transform.quad == nil,
               let transform = LayerPlacement.affineTransform(fromQuad: corners, contentSize: contentSize, canvasSize: newCanvas, preferring: layer.transform) {
                layer.transform = transform
            } else {
                layer.transform.quad = corners
            }
        case .text(var element):
            let moved = place(center: element.center, rotation: element.rotation)
            element.center = moved.center
            element.rotation = moved.rotation
            element.relativeSize = element.relativeSize * oldCanvas.height * moved.scaleV / newCanvas.height
            element.maxRelativeWidth = element.maxRelativeWidth * oldCanvas.width * moved.scaleU / newCanvas.width
            element.frameWidth = element.frameWidth.map { $0 * oldCanvas.width * moved.scaleU / newCanvas.width }
            layer.content = .text(element)
            if let quad = layer.transform.quad { layer.transform.quad = quad.map(map.apply) }
        case .shape(var shape):
            let moved = place(center: layer.transform.center, rotation: layer.transform.rotation)
            layer.transform.center = moved.center
            layer.transform.rotation = moved.rotation
            shape.relativeSize = PSSize(width: shape.relativeSize.width * oldCanvas.width * moved.scaleU / newCanvas.width,
                                        height: shape.relativeSize.height * oldCanvas.height * moved.scaleV / newCanvas.height)
            layer.content = .shape(shape)
            if let quad = layer.transform.quad { layer.transform.quad = quad.map(map.apply) }
        case .gradientFill(var gradient):
            let jacobian = pixelJacobian(at: gradient.center)
            let radians = (gradient.angle.isFinite ? gradient.angle : 90) * .pi / 180
            // The direction (cos a, −sin a) in y-down pixels, through J, back to Photoshop's angle.
            let direction = (cos(radians), -sin(radians))
            let mapped = (jacobian[0] * direction.0 + jacobian[1] * direction.1, jacobian[2] * direction.0 + jacobian[3] * direction.1)
            if mapped.0 * mapped.0 + mapped.1 * mapped.1 > 1e-24 {
                gradient.angle = PSHomography.normalizedDegrees(atan2(-mapped.1, mapped.0) * 180 / .pi)
            }
            let meanScale = abs(jacobian[0] * jacobian[3] - jacobian[1] * jacobian[2]).squareRoot()
            let oldDiagonal = (oldCanvas.width * oldCanvas.width + oldCanvas.height * oldCanvas.height).squareRoot()
            let newDiagonal = (newCanvas.width * newCanvas.width + newCanvas.height * newCanvas.height).squareRoot()
            if meanScale.isFinite, meanScale > 0, newDiagonal > 0 { gradient.scale = gradient.scale * oldDiagonal * meanScale / newDiagonal }
            gradient.center = map.apply(gradient.center)
            layer.content = .gradientFill(gradient)
        case .fill, .adjustment, .group, .unsupported:
            break
        }
        return layer
    }

    /// The Jacobian of M in pixels (old canvas → new canvas) at a canvas-normalised point, row-major.
    func pixelJacobian(at point: PSPoint) -> [Double] {
        let j = map.jacobian(at: point)
        let sx = newCanvas.width / oldCanvas.width, sy = newCanvas.height / oldCanvas.height
        // diag(W′, H′) · J · diag(1/W, 1/H).
        return [j[0] * sx, j[1] * newCanvas.width / oldCanvas.height, j[2] * newCanvas.height / oldCanvas.width, j[3] * sy]
    }

    /// A centre and a rotation through M, and how M scales lengths along the element's own axes (u along its
    /// baseline, v across it). Under a reflection the element is not mirrored: its baseline keeps the reading
    /// direction closest to where it was.
    func place(center: PSPoint, rotation: Double) -> (center: PSPoint, rotation: Double, scaleU: Double, scaleV: Double) {
        let jacobian = pixelJacobian(at: center)
        let radians = (rotation.isFinite ? rotation : 0) * .pi / 180
        let u = (cos(radians), sin(radians)), v = (-sin(radians), cos(radians))
        let ju = (jacobian[0] * u.0 + jacobian[1] * u.1, jacobian[2] * u.0 + jacobian[3] * u.1)
        let jv = (jacobian[0] * v.0 + jacobian[1] * v.1, jacobian[2] * v.0 + jacobian[3] * v.1)
        let scaleU = (ju.0 * ju.0 + ju.1 * ju.1).squareRoot(), scaleV = (jv.0 * jv.0 + jv.1 * jv.1).squareRoot()
        var degrees = rotation
        if scaleU > 1e-12 {
            degrees = atan2(ju.1, ju.0) * 180 / .pi
            let determinant = jacobian[0] * jacobian[3] - jacobian[1] * jacobian[2]
            if determinant < 0 {
                // Mirrored: of the two directions of the mapped baseline, the one nearest the old reading direction.
                let flipped = degrees + 180
                degrees = angularDistance(flipped, rotation) < angularDistance(degrees, rotation) ? flipped : degrees
            }
            degrees += 360 * ((rotation - degrees) / 360).rounded()
            if abs(degrees - degrees.rounded()) < 1e-9 { degrees = degrees.rounded() }
        }
        return (map.apply(center), degrees, scaleU.isFinite && scaleU > 0 ? scaleU : 1, scaleV.isFinite && scaleV > 0 ? scaleV : 1)
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let delta = abs((a - b).truncatingRemainder(dividingBy: 360))
        return min(delta, 360 - delta)
    }
}

// MARK: - Output sizes (the renderer's extents)

public extension EditStack {
    /// Output pixel size after every geometric operation, from the source's pixel size: crop rect × size, rounded;
    /// quarter turns swap; rotate's bounding box; straighten's crop-to-content factor; perspective's moved-corner
    /// bounding box; expand ÷ placement; upscale × factor (each rounded, as `PhotoDocument.apply` rounds the canvas).
    func outputSize(sourcePixels: PSSize) -> PSSize {
        operations.reduce(sourcePixels) { size, operation in
            operation.kind.isGeometric ? operation.kind.outputPixelSize(from: size) : size
        }
    }
}

public extension EditOperation.Kind {
    /// The pixel size after this operation from `size` (`EditStack.outputSize`; the base's step also moves the
    /// canvas in `PhotoDocument.append`). Non-geometric kinds keep it.
    func outputPixelSize(from size: PSSize) -> PSSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return size }
        let width = size.width, height = size.height
        func rounded(_ w: Double, _ h: Double) -> PSSize {
            guard w.isFinite, h.isFinite, w > 0, h > 0 else { return size }
            return PSSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        }
        switch self {
        case .crop(let rect):
            guard let r = Self.effectiveCrop(rect) else { return size }
            return rounded(width * r.width, height * r.height)
        case .rotate(let degrees):
            guard degrees != 0, degrees.isFinite else { return size }
            let (c, s) = Self.cosSin(degrees)
            if c == 0 || s == 0 { return c == 0 ? PSSize(width: height, height: width) : size }
            return rounded(width * abs(c) + height * abs(s), width * abs(s) + height * abs(c))
        case .straighten(let degrees):
            guard degrees != 0, degrees.isFinite else { return size }
            let angle = abs((-degrees * .pi / 180).truncatingRemainder(dividingBy: .pi / 2))
            let sinA = abs(sin(angle)), cosA = abs(cos(angle))
            let k = min(width / (width * cosA + height * sinA), height / (width * sinA + height * cosA))
            return rounded(width * k, height * k)
        case .perspective(let horizontal, let vertical):
            guard let corners = Self.perspectiveCorners(horizontal: horizontal, vertical: vertical, aspect: width / height) else { return size }
            return rounded(corners.size.width * height, corners.size.height * height)
        case .expand(let placement):
            guard placement.width > 0.05, placement.height > 0.05 else { return size }
            return rounded(width / placement.width, height / placement.height)
        case .upscale(let factor):
            guard factor.isFinite, factor > 0 else { return size }
            return rounded(width * factor, height * factor)
        default:
            return size
        }
    }
}
