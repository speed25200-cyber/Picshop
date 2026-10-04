#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// The 27 blend modes on Core Image, matching BlendMath (W3C and Photoshop formulas).
///
/// - The colours are blended as gamma-encoded values, like a photo editor does: both
///   pictures go through the sRGB transfer curve (Display P3 shares it) before the blend
///   and the result comes back to the linear working space. Normal stays a plain
///   source-over in the working space.
/// - The blend uses the layer's opaque colours; its coverage (alpha × opacity) then mixes
///   the blend with what is beneath, in the same gamma-encoded values: (1 − α)·Cb + α·B(Cb, Cs).
/// - 21 modes are Core Image built-ins. The others are built from built-ins whose meaning
///   is symmetric, so no operand order can be got wrong: subtract is Cb − min(Cb, Cs) (a
///   difference against darken), divide is colour dodge by the inverted layer, hard mix a
///   thresholded linear dodge, darker and lighter colour a mask from the channel sums, and
///   dissolve takes each pixel from the layer with a probability equal to its coverage,
///   from a fixed seeded noise tile so a pixel never flickers between frames.
public enum BlendModes {
    public static func composite(_ top: CIImage, over bottom: CIImage, mode: BlendMode) -> CIImage {
        composite(top, over: bottom, mode: mode, opacity: 1)
    }

    /// `opacity` (0…1) scales the layer's coverage. `seed` moves dissolve's noise (one per layer).
    /// `legacy`: the 12 modes before W1 blend as they did then, on linear values (the proTone
    /// kill switch); the 15 newer ones always blend the new way.
    /// W3 (D6): `fill` (0…1) scales the layer's alpha before the blend and `opacity` mixes the result after; without
    /// layer styles they give the same pixels, so the coverage is alpha × fill × opacity. `backdropIsOpaque: false`
    /// (isolated groups, clipping groups, rasterising layers onto transparent) blends every mode but normal and
    /// dissolve with W3C Compositing's source-over formula, in gamma-encoded values, so a multiply child over nothing
    /// stays the child instead of turning black.
    public static func composite(_ top: CIImage, over bottom: CIImage, mode: BlendMode, opacity: Double, seed: UInt64 = 0, legacy: Bool = false,
                                 fill: Double = 1, backdropIsOpaque: Bool = true) -> CIImage {
        let opacity = (opacity.clamped(to: 0...1) * fill.clamped(to: 0...1)).clamped(to: 0...1)
        guard opacity > 0.0005 else { return bottom }
        let bounds = bottom.extent
        if mode == .normal {
            return faded(top, opacity).composited(over: bottom).cropped(to: bounds)
        }
        if legacy, legacyModes.contains(mode) {
            return builtIn(mode, top: faded(top, opacity), bottom: bottom).cropped(to: bounds)
        }
        let area = top.extent.isInfinite ? bounds : top.extent.intersection(bounds)
        guard !area.isEmpty, !area.isNull else { return bottom }
        if !backdropIsOpaque, mode != .dissolve, !bounds.isInfinite {
            // D6 over a backdrop of any alpha: both sides gamma-encoded, the W3C formula, back to linear.
            let source = encoded(top.cropped(to: area), in: area)
            let backdrop = encoded(bottom, in: bounds)
            let blended = compositeEncoded(source, over: backdrop, mode: mode, coverage: opacity, seed: seed, backdropIsOpaque: false)
            return decoded(blended, in: bounds)
        }
        // The layer's own colours, opaque over its area.
        let colours = top.cropped(to: area).unpremultiplyingAlpha().settingAlphaOne(in: area)
        let coverage = faded(top.cropped(to: area), opacity)

        if mode == .dissolve {
            let mask = dissolveMask(coverage: coverage, area: area, seed: seed)
            return blendWithMask(colours, over: bottom, mask: mask).cropped(to: bounds)
        }

        let source = gamma(colours), backdrop = gamma(bottom.cropped(to: area))
        let blended: CIImage
        switch mode {
        case .darkerColor, .lighterColor:
            // One whole pixel or the other, chosen by the channel sums.
            let choose = sumMask(top: source, bottom: backdrop, topIsLighter: mode == .lighterColor)
            blended = blendWithMask(source, over: backdrop, mask: choose)
        default:
            blended = separable(mode, top: source, bottom: backdrop, area: area)
        }
        // Mixed with what is beneath by the layer's coverage, in the same gamma-encoded values.
        let mix = CIFilter.blendWithAlphaMask()
        mix.inputImage = blended.cropped(to: area)
        mix.backgroundImage = backdrop
        mix.maskImage = coverage
        let mixed = linear((mix.outputImage ?? backdrop).cropped(to: area))
        return mixed.composited(over: bottom).cropped(to: bounds)
    }

    /// The modes PhotoRenderer had before W1.
    static let legacyModes: Set<BlendMode> = [.multiply, .screen, .overlay, .softLight, .hardLight, .darken, .lighten, .difference, .luminosity, .color, .hue]

    // MARK: - W3: the v2 compositor's space (D6)

    /// One layer composited in gamma-encoded Display P3 (the v2 compositor's space, D6), W3C Compositing Level 1:
    /// co = cs·αs·(1 − αb) + cb·αb·(1 − αs) + αs·αb·B(cb, cs), αo = αs + αb·(1 − αs), with
    /// `BlendMath.compositeRGBA` as the CPU reference. `source` and `backdrop` are premultiplied gamma-encoded values;
    /// `coverage` (fill × opacity) scales the source's alpha. Normal is a plain source-over of those values, which is
    /// the formula with B = cs. A known-opaque backdrop skips the (1 − αb)·Cs term, which is then zero.
    static func compositeEncoded(_ source: CIImage, over backdrop: CIImage, mode: BlendMode, coverage: Double, seed: UInt64,
                                 backdropIsOpaque: Bool) -> CIImage {
        let amount = coverage.clamped(to: 0...1)
        guard amount > 0.0005 else { return backdrop }
        let bounds = backdrop.extent
        let fadedSource = faded(source, amount)
        if mode == .normal {
            return fadedSource.composited(over: backdrop).cropped(to: bounds)
        }
        let area = source.extent.isInfinite ? bounds : source.extent.intersection(bounds)
        guard !area.isEmpty, !area.isNull, !area.isInfinite else { return backdrop }
        // The layer's own colours, opaque over its area.
        let colours = opaqueColours(source.cropped(to: area), in: area)
        let coverageImage = fadedSource.cropped(to: area)
        if mode == .dissolve {
            // Coordinate-seeded noise (absolute canvas coordinates): strips and tiles take the same pixels.
            let mask = dissolveMask(coverage: coverageImage, area: area, seed: seed)
            return blendWithMask(colours, over: backdrop, mask: mask).cropped(to: bounds)
        }
        let backdropArea = backdrop.cropped(to: area)
        let base = backdropIsOpaque ? backdropArea.settingAlphaOne(in: area) : opaqueColours(backdropArea, in: area)
        let blended: CIImage
        switch mode {
        case .darkerColor, .lighterColor:
            let choose = sumMask(top: colours, bottom: base, topIsLighter: mode == .lighterColor)
            blended = blendWithMask(colours, over: base, mask: choose)
        default:
            blended = separable(mode, top: colours, bottom: base, area: area)
        }
        // Cs′ = (1 − αb)·Cs + αb·B: where nothing lies beneath, the layer keeps its own colour.
        let mixed = backdropIsOpaque ? blended.cropped(to: area) : alphaMix(blended.cropped(to: area), background: colours, alphaOf: backdropArea)
        // Cs′ with the layer's coverage, source-over onto the backdrop.
        let piece = withAlpha(mixed, from: coverageImage, in: area)
        return piece.composited(over: backdrop).cropped(to: bounds)
    }

    /// Premultiplied linear values → premultiplied gamma-encoded values (the sRGB transfer curve, which Display P3
    /// shares). The colour is made opaque before the curve and its alpha put back after, so the curve never sees a
    /// premultiplied value whatever the filter does with alpha.
    static func encoded(_ image: CIImage, in rect: CGRect) -> CIImage {
        guard !rect.isEmpty, !rect.isInfinite, !rect.isNull else { return image }
        let straight = image.cropped(to: rect).unpremultiplyingAlpha()
        return withAlpha(gamma(straight.settingAlphaOne(in: rect)), from: straight, in: rect)
    }

    /// The inverse of `encoded`.
    static func decoded(_ image: CIImage, in rect: CGRect) -> CIImage {
        guard !rect.isEmpty, !rect.isInfinite, !rect.isNull else { return image }
        let straight = image.cropped(to: rect).unpremultiplyingAlpha()
        return withAlpha(linear(straight.settingAlphaOne(in: rect)), from: straight, in: rect)
    }

    /// The straight colour of a premultiplied image, opaque over `rect` (black where it is transparent).
    static func opaqueColours(_ image: CIImage, in rect: CGRect) -> CIImage {
        image.cropped(to: rect).unpremultiplyingAlpha().settingAlphaOne(in: rect)
    }

    /// An opaque colour image given the alpha of `alphaSource`: premultiplied (c·α, α) over `rect`, clear elsewhere.
    static func withAlpha(_ opaque: CIImage, from alphaSource: CIImage, in rect: CGRect) -> CIImage {
        alphaMix(opaque.cropped(to: rect), background: CIImage(color: .clear).cropped(to: rect), alphaOf: alphaSource.cropped(to: rect))
    }

    /// `image` × α + `background` × (1 − α), α being `alphaOf`'s alpha (CIBlendWithAlphaMask).
    static func alphaMix(_ image: CIImage, background: CIImage, alphaOf mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithAlphaMask()
        filter.inputImage = image
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? background
    }

    // MARK: - Pieces

    /// The layer with its alpha scaled by `opacity`.
    static func faded(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 0.9995 else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        return matrix.outputImage ?? image
    }

    static func gamma(_ image: CIImage) -> CIImage {
        let filter = CIFilter.linearToSRGBToneCurve()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    static func linear(_ image: CIImage) -> CIImage {
        let filter = CIFilter.sRGBToneCurveToLinear()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    static func blendWithMask(_ image: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = image
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? background
    }

    /// B(Cb, Cs) of a separable or component mode, on gamma-encoded opaque pictures.
    static func separable(_ mode: BlendMode, top: CIImage, bottom: CIImage, area: CGRect) -> CIImage {
        switch mode {
        case .hardMix:
            // 1 where Cb + Cs reaches 1, else 0, per channel: linear dodge is min(1, Cb + Cs).
            let sum = builtIn(.linearDodge, top: top, bottom: bottom)
            let threshold = CIFilter.colorThreshold()
            threshold.inputImage = sum
            threshold.threshold = Float(1 - 0.5 / 255)
            return (threshold.outputImage ?? sum).cropped(to: area).settingAlphaOne(in: area)
        case .subtract:
            // max(0, Cb − Cs) = Cb − min(Cb, Cs).
            return builtIn(.difference, top: builtIn(.darken, top: top, bottom: bottom), bottom: bottom)
        case .divide:
            // Cb / Cs is colour dodge by 1 − Cs (and white where Cs is black, black where Cb is too).
            let inverted = CIFilter.colorInvert()
            inverted.inputImage = top
            return builtIn(.colorDodge, top: awayFromEnds((inverted.outputImage ?? top).cropped(to: area)), bottom: bottom)
        case .colorBurn, .colorDodge, .vividLight:
            return builtIn(mode, top: awayFromEnds(top), bottom: bottom)
        default:
            return builtIn(mode, top: top, bottom: bottom)
        }
    }

    /// The layer's values kept a quarter level away from 0 and 1: the dodge and burn divisions then
    /// give the formulas' answers at the ends (white or black) whatever Core Image does with 0 / 0.
    static func awayFromEnds(_ image: CIImage) -> CIImage {
        let epsilon = CGFloat(0.25 / 255)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: epsilon, y: epsilon, z: epsilon, w: 0)
        clamp.maxComponents = CIVector(x: 1 - epsilon, y: 1 - epsilon, z: 1 - epsilon, w: 1)
        return clamp.outputImage ?? image
    }

    /// The Core Image filter for a mode it has.
    static func builtIn(_ mode: BlendMode, top: CIImage, bottom: CIImage) -> CIImage {
        let filter: CIFilter & CICompositeOperation
        switch mode {
        // Composed in `separable` and `composite`, never asked for here.
        case .normal, .dissolve, .hardMix, .darkerColor, .lighterColor, .subtract, .divide: filter = CIFilter.sourceOverCompositing()
        case .multiply: filter = CIFilter.multiplyBlendMode()
        case .screen: filter = CIFilter.screenBlendMode()
        case .overlay: filter = CIFilter.overlayBlendMode()
        case .softLight: filter = CIFilter.softLightBlendMode()
        case .hardLight: filter = CIFilter.hardLightBlendMode()
        case .darken: filter = CIFilter.darkenBlendMode()
        case .lighten: filter = CIFilter.lightenBlendMode()
        case .difference: filter = CIFilter.differenceBlendMode()
        case .exclusion: filter = CIFilter.exclusionBlendMode()
        case .colorBurn: filter = CIFilter.colorBurnBlendMode()
        case .colorDodge: filter = CIFilter.colorDodgeBlendMode()
        case .linearBurn: filter = CIFilter.linearBurnBlendMode()
        case .linearDodge: filter = CIFilter.linearDodgeBlendMode()
        case .linearLight: filter = CIFilter.linearLightBlendMode()
        case .vividLight: filter = CIFilter.vividLightBlendMode()
        case .pinLight: filter = CIFilter.pinLightBlendMode()
        case .hue: filter = CIFilter.hueBlendMode()
        case .saturation: filter = CIFilter.saturationBlendMode()
        case .color: filter = CIFilter.colorBlendMode()
        case .luminosity: filter = CIFilter.luminosityBlendMode()
        }
        filter.inputImage = top
        filter.backgroundImage = bottom
        return filter.outputImage ?? bottom
    }

    /// White where the layer's pixel wins: its channel sum is lower (darker colour) or higher (lighter colour).
    static func sumMask(top: CIImage, bottom: CIImage, topIsLighter: Bool) -> CIImage {
        let topSum = average(top), bottomSum = average(bottom)
        // min (or max) of the two sums, against the backdrop's: non-zero exactly where the layer wins.
        let winner = builtIn(topIsLighter ? .lighten : .darken, top: topSum, bottom: bottomSum)
        let margin = builtIn(.difference, top: winner, bottom: bottomSum)
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = margin
        threshold.threshold = 1e-5
        return threshold.outputImage ?? bottomSum
    }

    /// (R + G + B) / 3 as an opaque grey.
    static func average(_ image: CIImage) -> CIImage {
        let third = CGFloat(1.0 / 3.0)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: third, y: third, z: third, w: 0)
        matrix.gVector = CIVector(x: third, y: third, z: third, w: 0)
        matrix.bVector = CIVector(x: third, y: third, z: third, w: 0)
        return matrix.outputImage ?? image
    }

    // MARK: - Dissolve

    /// White where the layer shows: its coverage above the pixel's noise value.
    static func dissolveMask(coverage: CIImage, area: CGRect, seed: UInt64) -> CIImage {
        // The coverage (alpha × opacity) as an opaque grey; the alpha is never colour-managed.
        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = coverage
        alpha.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alpha.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alpha.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alpha.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let grey = (alpha.outputImage ?? coverage).cropped(to: area)
        let offset = CGAffineTransform(translationX: CGFloat(seed % 251), y: CGFloat((seed / 251) % 241))
        let noise = noiseTile.transformed(by: offset)
        let tiled = CIFilter.affineTile()
        tiled.inputImage = noise.cropped(to: CGRect(x: offset.tx, y: offset.ty, width: CGFloat(noiseSide), height: CGFloat(noiseSide)))
        tiled.transform = .identity
        let field = (tiled.outputImage ?? noise).cropped(to: area)
        // coverage − min(noise, coverage): above zero exactly where the noise is below the coverage.
        let margin = builtIn(.difference, top: builtIn(.darken, top: field, bottom: grey), bottom: grey)
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = margin
        threshold.threshold = 1e-6
        return (threshold.outputImage ?? grey).cropped(to: area)
    }

    static let noiseSide = 256

    /// A fixed 256 × 256 tile of uniform noise (seeded; values taken as they are, no colour
    /// management), k/256 for k in 0…255: below a full coverage everywhere, below 0.5 half the time.
    static let noiseTile: CIImage = {
        var state: UInt64 = 0x5EED_1234_ABCD_0001
        var bytes = [UInt8](repeating: 0, count: noiseSide * noiseSide)
        for index in bytes.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 56)
        }
        let tile = CIImage(bitmapData: Data(bytes), bytesPerRow: noiseSide, size: CGSize(width: noiseSide, height: noiseSide), format: .L8, colorSpace: nil)
        let scale = CGFloat(255.0 / 256.0)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = tile
        matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        return matrix.outputImage ?? tile
    }()
}
#endif
