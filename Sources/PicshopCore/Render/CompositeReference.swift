import Foundation

// D11's CPU reference: executes a CompositePlan on small straight-alpha rasters, so the plan, groups (D4), clipping
// (D5) and fill/opacity (D6) are checked on Linux and L2's GPU executor is compared against it. Tests only: it is
// exact, not fast.

/// Straight RGBA, gamma Display P3 values 0…1, row 0 at the top.
public struct RGBARaster: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// width × height × 4 values.
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public static func filled(width: Int, height: Int, color: PSColor) -> RGBARaster {
        let pixel = [Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha)]
        let count = max(0, width) * max(0, height)
        var pixels: [Float] = []
        pixels.reserveCapacity(count * 4)
        for _ in 0..<count { pixels.append(contentsOf: pixel) }
        return RGBARaster(width: max(0, width), height: max(0, height), pixels: pixels)
    }

    /// The straight colour and alpha at a pixel (zero outside the raster or past its data).
    public func pixel(x: Int, y: Int) -> (rgb: BlendMath.RGB, alpha: Double) {
        let index = (y * width + x) * 4
        guard x >= 0, y >= 0, x < width, y < height, index + 3 < pixels.count else { return (BlendMath.RGB(0, 0, 0), 0) }
        return (BlendMath.RGB(Double(pixels[index]), Double(pixels[index + 1]), Double(pixels[index + 2])), Double(pixels[index + 3]))
    }

    public mutating func setPixel(x: Int, y: Int, rgb: BlendMath.RGB, alpha: Double) {
        let index = (y * width + x) * 4
        guard x >= 0, y >= 0, x < width, y < height, index + 3 < pixels.count else { return }
        pixels[index] = Float(rgb.r)
        pixels[index + 1] = Float(rgb.g)
        pixels[index + 2] = Float(rgb.b)
        pixels[index + 3] = Float(alpha)
    }
}

public enum CompositeReference {
    /// Executes a plan on CPU rasters already placed on the canvas: `content` gives each layer's placed RGBA (nil:
    /// nothing), `mask` its combined mask (legacy × stack, canvas pixels, row 0 at the top; nil: none), `adjust` an
    /// adjustment layer's recipe applied to a backdrop. The maths of D4, D5, D6 and D9:
    /// - a layer: its alpha × mask × fill × opacity, composited with its mode by W3C Compositing 1
    ///   (`BlendMath.compositeRGBA`); dissolve shows the source wherever a coordinate-seeded noise is below that alpha;
    /// - an adjustment layer: mix(backdrop, B(backdrop, recipe(backdrop)), mask × fill × opacity), alpha unchanged;
    /// - a clipping group: the base through its mask and fill (αb), its colour made opaque, the clipped nodes drawn on
    ///   it, alpha replaced by αb, then drawn with the base's mode and opacity;
    /// - an isolated group: its children on transparent, drawn like a layer (mask, opacity, mode); a pass-through
    ///   group: its children straight on the backdrop, then mixed with the backdrop as it was by mask × opacity.
    public static func render(_ plan: [CompositeNode], width: Int, height: Int, background: PSColor,
                              content: (UUID) -> RGBARaster?, mask: (UUID) -> [Float]?,
                              adjust: (UUID, RGBARaster) -> RGBARaster) -> RGBARaster {
        withoutActuallyEscaping(content) { content in
            withoutActuallyEscaping(mask) { mask in
                withoutActuallyEscaping(adjust) { adjust in
                    let executor = Executor(width: width, height: height, content: content, mask: mask, adjust: adjust)
                    var canvas = RGBARaster.filled(width: width, height: height, color: background)
                    executor.draw(plan, onto: &canvas)
                    return canvas
                }
            }
        }
    }

    /// Dissolve's per-layer seed: the layer id's first 8 bytes (as PhotoRenderer's).
    public static func dissolveSeed(for id: UUID) -> UInt64 {
        let b = id.uuid
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Dissolve's noise in 0…1 at absolute canvas coordinates (D6: strips and tiles agree): SplitMix64 of the seed and
    /// the position.
    public static func dissolveNoise(seed: UInt64, x: Int, y: Int) -> Double {
        var z = seed &+ (UInt64(UInt32(truncatingIfNeeded: x)) << 32 | UInt64(UInt32(truncatingIfNeeded: y))) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    struct Executor {
        let width: Int
        let height: Int
        let content: (UUID) -> RGBARaster?
        let mask: (UUID) -> [Float]?
        let adjust: (UUID, RGBARaster) -> RGBARaster

        func draw(_ nodes: [CompositeNode], onto canvas: inout RGBARaster) {
            for node in nodes { draw(node, onto: &canvas) }
        }

        func draw(_ node: CompositeNode, onto canvas: inout RGBARaster) {
            switch node {
            case .layer(let draw):
                guard let source = content(draw.layerID) else { return }
                composite(source, mask: draw.hasMask ? mask(draw.layerID) : nil, coverage: draw.fillOpacity * draw.opacity,
                          mode: draw.blendMode, seed: dissolveSeed(for: draw.layerID), onto: &canvas)
            case .adjustment(let draw):
                adjustLayer(draw, onto: &canvas)
            case .clippingGroup(let base, let clipped):
                clippingGroup(base: base, clipped: clipped, onto: &canvas)
            case .group(let draw, let passThrough, let children):
                if passThrough {
                    let before = canvas
                    self.draw(children, onto: &canvas)
                    mix(before: before, after: &canvas, mask: draw.hasMask ? mask(draw.layerID) : nil, amount: draw.opacity)
                } else {
                    var isolated = RGBARaster.filled(width: width, height: height, color: .clear)
                    self.draw(children, onto: &isolated)
                    composite(isolated, mask: draw.hasMask ? mask(draw.layerID) : nil, coverage: draw.opacity, mode: draw.blendMode,
                              seed: dissolveSeed(for: draw.layerID), onto: &canvas)
                }
            }
        }

        /// Source-over with the mode's mix; alpha = source alpha × mask × coverage (fill × opacity, D6).
        func composite(_ source: RGBARaster, mask: [Float]?, coverage: Double, mode: BlendMode, seed: UInt64, onto canvas: inout RGBARaster) {
            for y in 0..<height {
                for x in 0..<width {
                    let s = source.pixel(x: x, y: y)
                    var alpha = s.alpha * coverage * maskValue(mask, x: x, y: y)
                    var blend = mode
                    if mode == .dissolve {
                        alpha = CompositeReference.dissolveNoise(seed: seed, x: x, y: y) < alpha ? 1 : 0
                        blend = .normal
                    }
                    guard alpha > 0 else { continue }
                    let b = canvas.pixel(x: x, y: y)
                    let out = BlendMath.compositeRGBA(blend, backdrop: b.rgb, backdropAlpha: b.alpha, source: s.rgb, sourceAlpha: alpha)
                    canvas.setPixel(x: x, y: y, rgb: out.rgb, alpha: out.alpha)
                }
            }
        }

        /// D9: mix(backdrop, B(backdrop, recipe(backdrop)), mask × fill × opacity); the alpha is the backdrop's.
        func adjustLayer(_ draw: LayerDraw, onto canvas: inout RGBARaster) {
            let adjusted = adjust(draw.layerID, canvas)
            let layerMask = draw.hasMask ? mask(draw.layerID) : nil
            let seed = dissolveSeed(for: draw.layerID)
            for y in 0..<height {
                for x in 0..<width {
                    var amount = draw.fillOpacity * draw.opacity * maskValue(layerMask, x: x, y: y)
                    var mode = draw.blendMode
                    if mode == .dissolve {
                        amount = CompositeReference.dissolveNoise(seed: seed, x: x, y: y) < amount ? 1 : 0
                        mode = .normal
                    }
                    guard amount > 0 else { continue }
                    let b = canvas.pixel(x: x, y: y)
                    let blended = BlendMath.blend(mode, backdrop: b.rgb, source: adjusted.pixel(x: x, y: y).rgb)
                    let rgb = BlendMath.RGB(b.rgb.r + (blended.r - b.rgb.r) * amount, b.rgb.g + (blended.g - b.rgb.g) * amount,
                                            b.rgb.b + (blended.b - b.rgb.b) * amount)
                    canvas.setPixel(x: x, y: y, rgb: rgb, alpha: b.alpha)
                }
            }
        }

        /// D5: the base's opaque colour, the clipped nodes on it, alpha replaced by the base's, drawn with the base's
        /// mode and opacity.
        func clippingGroup(base: LayerDraw, clipped: [CompositeNode], onto canvas: inout RGBARaster) {
            var baseContent: RGBARaster
            if base.groupChildren.isEmpty {
                guard let layerContent = content(base.layerID) else { return }
                baseContent = layerContent
            } else {
                baseContent = RGBARaster.filled(width: width, height: height, color: .clear)
                draw(base.groupChildren, onto: &baseContent)
            }
            let baseMask = base.hasMask ? mask(base.layerID) : nil
            var alphas = [Double](repeating: 0, count: width * height)
            var opaque = baseContent
            for y in 0..<height {
                for x in 0..<width {
                    let p = baseContent.pixel(x: x, y: y)
                    alphas[y * width + x] = p.alpha * base.fillOpacity * maskValue(baseMask, x: x, y: y)
                    opaque.setPixel(x: x, y: y, rgb: p.rgb, alpha: 1)
                }
            }
            draw(clipped, onto: &opaque)
            for y in 0..<height {
                for x in 0..<width {
                    opaque.setPixel(x: x, y: y, rgb: opaque.pixel(x: x, y: y).rgb, alpha: alphas[y * width + x])
                }
            }
            composite(opaque, mask: nil, coverage: base.opacity, mode: base.blendMode, seed: dissolveSeed(for: base.layerID), onto: &canvas)
        }

        /// Pass-through: the backdrop as it was, mixed with what the children made of it, by mask × amount
        /// (premultiplied, as Core Image's blendWithMask).
        func mix(before: RGBARaster, after canvas: inout RGBARaster, mask: [Float]?, amount: Double) {
            for y in 0..<height {
                for x in 0..<width {
                    let k = amount * maskValue(mask, x: x, y: y)
                    guard k < 1 else { continue }
                    let a = before.pixel(x: x, y: y), b = canvas.pixel(x: x, y: y)
                    let alpha = a.alpha + (b.alpha - a.alpha) * k
                    guard alpha > 1e-12 else {
                        canvas.setPixel(x: x, y: y, rgb: BlendMath.RGB(0, 0, 0), alpha: 0)
                        continue
                    }
                    func channel(_ u: Double, _ v: Double) -> Double { (u * a.alpha + (v * b.alpha - u * a.alpha) * k) / alpha }
                    canvas.setPixel(x: x, y: y, rgb: BlendMath.RGB(channel(a.rgb.r, b.rgb.r), channel(a.rgb.g, b.rgb.g), channel(a.rgb.b, b.rgb.b)), alpha: alpha)
                }
            }
        }

        func maskValue(_ mask: [Float]?, x: Int, y: Int) -> Double {
            guard let mask else { return 1 }
            let index = y * width + x
            guard index >= 0, index < mask.count else { return 0 }
            return Double(mask[index]).clamped(to: 0...1)
        }
    }
}
