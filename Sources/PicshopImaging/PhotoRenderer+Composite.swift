#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// The space the v2 compositor blends in (D6).
enum CompositeSpace: Sendable, Equatable {
    /// Gamma-encoded Display P3, premultiplied: every mode, normal included, follows W3C Compositing Level 1 exactly
    /// as `BlendMath.compositeRGBA` and `CompositeReference` do on the CPU, as Photoshop composites. The default.
    case encoded
    /// Linear working-space values blended through W1's `BlendModes.composite` (the proTone kill switch off).
    case linear
}

/// What the executor draws with, already prepared: the actor's render and a snapshot's frame fill it from their own
/// sources (D11, D13), so both draw through the same code.
struct CompositeInputs {
    /// The canvas in Core Image coordinates (origin at zero in practice).
    var canvas: CGRect
    var background: PSColor
    var space: CompositeSpace
    /// A layer's pixels placed on the canvas, its masks applied (legacy × stack, linked or not), linear working-space
    /// values, premultiplied, cropped to the canvas; nil draws nothing (a hidden or empty content, an unsupported one).
    var content: (UUID) -> CIImage?
    /// An adjustment layer's or a group's mask on the canvas (gray, raw values); nil: no mask.
    var mask: (UUID) -> CIImage?
    /// An adjustment layer's recipe applied to a linear backdrop (D9).
    var adjust: (UUID, CIImage) -> CIImage
    /// Dissolve's noise offset per layer.
    var seed: (UUID) -> UInt64 = { PhotoRenderer.dissolveSeed(for: $0) }
}

/// The CompositePlan executor (W3, D11): groups (D4), clipping groups (D5), fill then opacity (D6), adjustment and fill
/// layers (D9), on Core Image. Static and nonisolated, so the renderer actor and a snapshot's frame on the main actor
/// run the same code (D13). Graph construction only: nothing here renders a pixel.
enum CompositeExecutor {
    /// The plan drawn bottom → top over the document's background; linear working-space values, cropped to the canvas.
    static func render(_ plan: [CompositeNode], inputs: CompositeInputs) -> CIImage {
        let backdrop = background(inputs)
        let drawn = run(plan, onto: backdrop, inputs: inputs, backdropIsOpaque: inputs.background.alpha >= 0.9995)
        return fromSpace(drawn, inputs: inputs)
    }

    /// The background in the executor's space.
    static func background(_ inputs: CompositeInputs) -> CIImage {
        let color = CIImage(color: inputs.background.ciColor).cropped(to: inputs.canvas)
        return toSpace(color, inputs: inputs)
    }

    /// Transparent over the canvas (isolated groups, rasterising layers onto nothing).
    static func clear(_ canvas: CGRect) -> CIImage {
        CIImage(color: .clear).cropped(to: canvas)
    }

    /// Nodes drawn in order onto `backdrop` (in the executor's space).
    static func run(_ nodes: [CompositeNode], onto backdrop: CIImage, inputs: CompositeInputs, backdropIsOpaque: Bool) -> CIImage {
        nodes.reduce(backdrop) { draw($1, onto: $0, inputs: inputs, backdropIsOpaque: backdropIsOpaque) }
    }

    /// One node onto `backdrop`.
    static func draw(_ node: CompositeNode, onto backdrop: CIImage, inputs: CompositeInputs, backdropIsOpaque: Bool) -> CIImage {
        switch node {
        case .layer(let draw):
            guard let content = inputs.content(draw.layerID) else { return backdrop }
            let source = toSpace(content, inputs: inputs)
            return blend(source, over: backdrop, mode: draw.blendMode, coverage: draw.opacity * draw.fillOpacity,
                         seed: inputs.seed(draw.layerID), inputs: inputs, backdropIsOpaque: backdropIsOpaque)

        case .adjustment(let draw):
            return adjustment(draw, onto: backdrop, inputs: inputs)

        case .clippingGroup(let base, let clipped):
            // D5: the base's content through its masks and fill (alpha αb); the clipped layers composited onto its
            // opaque colour; the result premultiplied by αb (alpha replaced, never multiplied); then drawn with the
            // base's blend mode and opacity. A base that draws nothing hides its clipped layers.
            let canvas = inputs.canvas
            let baseContent: CIImage
            if base.groupChildren.isEmpty {
                guard let content = inputs.content(base.layerID) else { return backdrop }
                baseContent = toSpace(content, inputs: inputs)
            } else {
                // A group base: its children's isolated composite through the group's mask (already in this space).
                var inside = run(base.groupChildren, onto: clear(canvas), inputs: inputs, backdropIsOpaque: false)
                if let mask = inputs.mask(base.layerID) { inside = AdjustmentPipeline.applyingAlpha(mask: mask, to: inside) }
                baseContent = inside
            }
            let baseRGBA = BlendModes.faded(baseContent, base.fillOpacity.clamped(to: 0...1)).cropped(to: canvas)
            let opaque = BlendModes.opaqueColours(baseRGBA, in: canvas)
            let accumulated = run(clipped, onto: opaque, inputs: inputs, backdropIsOpaque: true)
            let group = BlendModes.withAlpha(accumulated, from: baseRGBA, in: canvas)
            return blend(group, over: backdrop, mode: base.blendMode, coverage: base.opacity, seed: inputs.seed(base.layerID),
                         inputs: inputs, backdropIsOpaque: backdropIsOpaque)

        case .group(let draw, let passThrough, let children):
            let canvas = inputs.canvas
            if passThrough {
                // D4: the children straight onto the running backdrop, then mixed with the backdrop as it was by
                // mask × opacity. The group's blend mode is pass-through itself.
                let after = run(children, onto: backdrop, inputs: inputs, backdropIsOpaque: backdropIsOpaque)
                let mask = inputs.mask(draw.layerID)
                let amount = draw.opacity.clamped(to: 0...1)
                if mask == nil, amount >= 0.9995 { return after }
                guard amount > 0.0005 else { return backdrop }
                let weight = scaledMask(mask ?? MaskComponentImages.white(canvas), by: amount)
                return AdjustmentPipeline.blendWithMask(foreground: after, background: backdrop, mask: weight).cropped(to: canvas)
            }
            // Isolated: the children onto transparent, then the result drawn like a layer with the group's mask,
            // blend mode and opacity.
            var inside = run(children, onto: clear(canvas), inputs: inputs, backdropIsOpaque: false)
            if let mask = inputs.mask(draw.layerID) { inside = AdjustmentPipeline.applyingAlpha(mask: mask, to: inside) }
            return blend(inside, over: backdrop, mode: draw.blendMode, coverage: draw.opacity, seed: inputs.seed(draw.layerID),
                         inputs: inputs, backdropIsOpaque: backdropIsOpaque)
        }
    }

    /// D9: adjusted = recipe(backdrop); result = mix(backdrop, blend(backdrop, adjusted, mode), mask × fill × opacity),
    /// the backdrop's alpha kept.
    static func adjustment(_ draw: LayerDraw, onto backdrop: CIImage, inputs: CompositeInputs) -> CIImage {
        let canvas = inputs.canvas
        let amount = (draw.opacity * draw.fillOpacity).clamped(to: 0...1)
        guard amount > 0.0005 else { return backdrop }
        let adjustedLinear = inputs.adjust(draw.layerID, fromSpace(backdrop, inputs: inputs)).cropped(to: canvas)
        let adjusted = toSpace(adjustedLinear, inputs: inputs)
        let mask = inputs.mask(draw.layerID)
        if inputs.space == .linear {
            // W1: the adjusted picture laid back through the mask, opacity and blend mode.
            let source = mask.map { AdjustmentPipeline.applyingAlpha(mask: $0, to: adjusted) } ?? adjusted
            return BlendModes.composite(source, over: backdrop, mode: draw.blendMode, opacity: amount, seed: inputs.seed(draw.layerID),
                                        legacy: true).cropped(to: canvas)
        }
        if mask == nil, amount >= 0.9995, draw.blendMode == .normal || draw.blendMode == .dissolve { return adjusted }
        let weight = scaledMask(mask ?? MaskComponentImages.white(canvas), by: amount)
        switch draw.blendMode {
        case .normal, .dissolve:
            // Both sides carry the backdrop's alpha: a plain mix keeps it.
            return AdjustmentPipeline.blendWithMask(foreground: adjusted, background: backdrop, mask: weight).cropped(to: canvas)
        default:
            let base = BlendModes.opaqueColours(backdrop, in: canvas)
            let colours = BlendModes.opaqueColours(adjusted, in: canvas)
            let blended = blendColours(draw.blendMode, top: colours, bottom: base, area: canvas)
            let mixed = AdjustmentPipeline.blendWithMask(foreground: blended, background: base, mask: weight).cropped(to: canvas)
            return BlendModes.withAlpha(mixed, from: backdrop, in: canvas)
        }
    }

    /// B(Cb, Cs) of opaque pictures in the executor's space.
    static func blendColours(_ mode: BlendMode, top: CIImage, bottom: CIImage, area: CGRect) -> CIImage {
        switch mode {
        case .normal, .dissolve:
            return top
        case .darkerColor, .lighterColor:
            let choose = BlendModes.sumMask(top: top, bottom: bottom, topIsLighter: mode == .lighterColor)
            return BlendModes.blendWithMask(top, over: bottom, mask: choose).cropped(to: area)
        default:
            return BlendModes.separable(mode, top: top, bottom: bottom, area: area).cropped(to: area)
        }
    }

    /// `source` (premultiplied, in the executor's space) composited onto `backdrop` with `coverage` = fill × opacity.
    static func blend(_ source: CIImage, over backdrop: CIImage, mode: BlendMode, coverage: Double, seed: UInt64, inputs: CompositeInputs,
                      backdropIsOpaque: Bool) -> CIImage {
        switch inputs.space {
        case .encoded:
            return BlendModes.compositeEncoded(source, over: backdrop, mode: mode, coverage: coverage, seed: seed, backdropIsOpaque: backdropIsOpaque)
                .cropped(to: inputs.canvas)
        case .linear:
            return BlendModes.composite(source, over: backdrop, mode: mode, opacity: coverage, seed: seed, legacy: true,
                                        backdropIsOpaque: backdropIsOpaque).cropped(to: inputs.canvas)
        }
    }

    /// A gray mask × `amount` (raw values).
    static func scaledMask(_ mask: CIImage, by amount: Double) -> CIImage {
        amount >= 0.9995 ? mask : MaskComponentImages.scaled(mask, by: amount)
    }

    // MARK: - Space

    static func toSpace(_ image: CIImage, inputs: CompositeInputs) -> CIImage {
        guard inputs.space == .encoded else { return image.cropped(to: inputs.canvas) }
        let area = image.extent.isInfinite ? inputs.canvas : image.extent.intersection(inputs.canvas)
        guard !area.isNull, !area.isEmpty else { return clear(inputs.canvas) }
        return BlendModes.encoded(image, in: area)
    }

    static func fromSpace(_ image: CIImage, inputs: CompositeInputs) -> CIImage {
        guard inputs.space == .encoded else { return image.cropped(to: inputs.canvas) }
        return BlendModes.decoded(image, in: inputs.canvas)
    }
}

// MARK: - Placement (D10)

/// Where a layer's content lands on the canvas: `LayerPlacement.map` (content unit square, top-left → canvas-normalised,
/// top-left) turned into Core Image terms (y up, pixels).
enum ContentPlacement {
    /// The affine transform placing content of `extent` (any origin) through `map` onto `canvas`; nil when the map is
    /// projective (a 4-corner distort or perspective).
    static func affine(_ map: PSHomography, extent: CGRect, canvas: CGRect) -> CGAffineTransform? {
        guard map.isAffine, extent.width > 0, extent.height > 0 else { return nil }
        let k = map.m[8]
        guard abs(k) > 1e-12 else { return nil }
        let m = map.m.map { CGFloat($0 / k) }
        // Content pixels → the unit square (top-left), the map, then canvas-normalised → canvas pixels.
        let toUnit = CGAffineTransform(a: 1 / extent.width, b: 0, c: 0, d: -1 / extent.height,
                                       tx: -extent.minX / extent.width, ty: 1 + extent.minY / extent.height)
        let placement = CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
        let toCanvas = CGAffineTransform(a: canvas.width, b: 0, c: 0, d: -canvas.height, tx: canvas.minX, ty: canvas.minY + canvas.height)
        return toUnit.concatenating(placement).concatenating(toCanvas)
    }

    /// The four placed corners (TL, TR, BR, BL of the content) in Core Image pixels.
    static func corners(_ map: PSHomography, canvas: CGRect) -> [CGPoint] {
        RasterRef.unitCorners.map { MaskComponentImages.ciPoint(map.apply($0), in: canvas) }
    }

    /// `content` placed through `map` onto `canvas`, cropped to it. Linear sampling; Core Image's high-quality
    /// downsample when the content shrinks beyond half.
    static func place(_ content: CIImage, map: PSHomography, canvas: CGRect) -> CIImage {
        let extent = content.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return CIImage(color: .clear).cropped(to: canvas) }
        if var transform = affine(map, extent: extent, canvas: canvas) {
            // A placement that only moves by whole pixels (a canvas-sized layer, a merged raster at its bounds) is
            // applied exactly: floating noise would otherwise resample every pixel by a hair.
            if abs(transform.a - 1) < 1e-9, abs(transform.d - 1) < 1e-9, abs(transform.b) < 1e-9, abs(transform.c) < 1e-9,
               abs(transform.tx - transform.tx.rounded()) < 1e-6, abs(transform.ty - transform.ty.rounded()) < 1e-6 {
                transform = CGAffineTransform(translationX: transform.tx.rounded(), y: transform.ty.rounded())
                return (transform.isIdentity ? content : content.transformed(by: transform)).cropped(to: canvas)
            }
            let shrink = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            let placed = shrink < 0.5 ? content.transformed(by: transform, highQualityDownsample: true) : content.transformed(by: transform)
            return placed.cropped(to: canvas)
        }
        let points = corners(map, canvas: canvas)
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = content
        warp.topLeft = points[0]
        warp.topRight = points[1]
        warp.bottomRight = points[2]
        warp.bottomLeft = points[3]
        return (warp.outputImage ?? content).cropped(to: canvas)
    }

    /// A gray mask placed the same way (outside the content it reads 0).
    static func placeMask(_ mask: CIImage, map: PSHomography, canvas: CGRect) -> CIImage {
        place(mask, map: map, canvas: canvas).composited(over: MaskComponentImages.black(canvas)).cropped(to: canvas)
    }

    /// The canvas-pixel box of the placed content (integral, clipped to the canvas); null when it misses the canvas.
    static func bounds(_ map: PSHomography, canvas: CGRect) -> CGRect {
        let points = corners(map, canvas: canvas)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral.intersection(canvas)
    }

    /// The largest linear scale from content pixels (of `contentPixels`) to canvas pixels: how dense a source needs
    /// decoding for this placement.
    static func density(_ map: PSHomography, contentPixels: PSSize, canvasPixels: PSSize) -> Double {
        guard contentPixels.width > 0, contentPixels.height > 0 else { return 1 }
        let q = RasterRef.unitCorners.map(map.apply).map { PSPoint(x: $0.x * canvasPixels.width, y: $0.y * canvasPixels.height) }
        func length(_ a: PSPoint, _ b: PSPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let horizontal = max(length(q[0], q[1]), length(q[3], q[2])) / contentPixels.width
        let vertical = max(length(q[0], q[3]), length(q[1], q[2])) / contentPixels.height
        let value = max(horizontal, vertical)
        return value.isFinite && value > 0 ? value : 1
    }
}
#endif
