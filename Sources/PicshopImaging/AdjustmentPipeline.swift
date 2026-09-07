#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Maps normalised `Adjustments` to concrete Core Image filters. Shared by the
/// photo renderer and the video compositor so a look renders identically in
/// both editors.
public enum AdjustmentPipeline {
    /// Applies `adjustments` (already combined with the look recipe) and the tone curve.
    /// `scale` is the ratio between the image being processed and the full-resolution
    /// original so radius-based effects stay consistent between preview and export.
    public static func apply(_ adjustments: Adjustments, toneCurve: ToneCurve, to input: CIImage, scale: Double = 1) -> CIImage {
        var image = input
        let extent = input.extent

        // Exposure & tone.
        if adjustments[.exposure] != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(adjustments[.exposure] * 2.0)
            image = filter.outputImage ?? image
        }
        if adjustments[.brightness] != 0 || adjustments[.contrast] != 0 || adjustments[.saturation] != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = Float(adjustments[.brightness] * 0.22)
            filter.contrast = Float(1 + adjustments[.contrast] * 0.55)
            filter.saturation = Float(max(0, 1 + adjustments[.saturation]))
            image = filter.outputImage ?? image
        }
        if adjustments[.shadows] != 0 || adjustments[.highlights] < 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.shadowAmount = Float(adjustments[.shadows])
            filter.highlightAmount = Float(1 + min(0, adjustments[.highlights]))
            filter.radius = Float(3 * scale)
            image = filter.outputImage ?? image
        }
        let curve = combinedToneCurve(adjustments, base: toneCurve)
        if !curve.isIdentity {
            let filter = CIFilter.toneCurve()
            filter.inputImage = image
            filter.point0 = curve.rgb[0].cgPoint
            filter.point1 = curve.rgb[1].cgPoint
            filter.point2 = curve.rgb[2].cgPoint
            filter.point3 = curve.rgb[3].cgPoint
            filter.point4 = curve.rgb[4].cgPoint
            image = filter.outputImage ?? image
        }

        // Colour.
        if adjustments[.vibrance] != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(adjustments[.vibrance])
            image = filter.outputImage ?? image
        }
        if adjustments[.temperature] != 0 || adjustments[.tint] != 0 || adjustments[.skinTone] != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            let kelvin = 6500 + (adjustments[.temperature] * 3000) + (adjustments[.skinTone] * 400)
            let tint = adjustments[.tint] * 60 + adjustments[.skinTone] * 8
            filter.targetNeutral = CIVector(x: kelvin, y: tint)
            image = filter.outputImage ?? image
        }
        if adjustments[.hue] != 0 {
            let filter = CIFilter.hueAdjust()
            filter.inputImage = image
            filter.angle = Float(adjustments[.hue] * .pi / 6)
            image = filter.outputImage ?? image
        }
        if adjustments[.skinTone] != 0 {
            // Skin smoothing: mild local contrast reduction limited to warm mid-tones.
            let soft = image.clampedToExtent().applyingGaussianBlur(sigma: 1.6 * scale).cropped(to: extent)
            image = blend(soft, over: image, alpha: adjustments[.skinTone] * 0.35)
        }

        // Detail.
        if adjustments[.noiseReduction] != 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(adjustments[.noiseReduction] * 0.08)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if adjustments[.clarity] > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(28 * scale)
            filter.intensity = Float(adjustments[.clarity] * 0.9)
            image = filter.outputImage?.cropped(to: extent) ?? image
        } else if adjustments[.clarity] < 0 {
            let soft = image.clampedToExtent().applyingGaussianBlur(sigma: 6 * scale).cropped(to: extent)
            image = blend(soft, over: image, alpha: -adjustments[.clarity] * 0.5)
        }
        if adjustments[.sharpness] != 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(2.2 * scale)
            filter.intensity = Float(adjustments[.sharpness] * 1.6)
            image = filter.outputImage?.cropped(to: extent) ?? image
        }

        // Effects.
        if adjustments[.vignette] != 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(max(extent.width, extent.height) * 0.72)
            filter.intensity = Float(adjustments[.vignette] * 1.1)
            filter.falloff = 0.45
            image = filter.outputImage?.cropped(to: extent) ?? image
        }
        if adjustments[.grain] != 0 {
            image = applyGrain(amount: adjustments[.grain], to: image, scale: scale)
        }
        return image.cropped(to: extent)
    }

    /// Adds whites/blacks/highlights(+)/fade to the base curve.
    static func combinedToneCurve(_ adjustments: Adjustments, base: ToneCurve) -> ToneCurve {
        var points = base.rgb
        guard points.count == 5 else { points = ToneCurve.linear; return ToneCurve(rgb: points) }
        let fade = adjustments[.fade] * 0.14
        let blacks = adjustments[.blacks] * 0.12
        let whites = adjustments[.whites] * 0.12
        let highlights = max(0, adjustments[.highlights]) * 0.1
        points[0] = ToneCurve.Point(0, (points[0].output + fade + blacks).clamped(to: 0...0.5))
        points[1] = ToneCurve.Point(0.25, (points[1].output + fade * 0.55 + blacks * 0.5).clamped(to: 0.02...0.6))
        points[3] = ToneCurve.Point(0.75, (points[3].output + highlights + whites * 0.4).clamped(to: 0.4...0.98))
        points[4] = ToneCurve.Point(1, (points[4].output + whites).clamped(to: 0.6...1))
        return ToneCurve(rgb: points, red: base.red, green: base.green, blue: base.blue)
    }

    static func applyGrain(amount: Double, to image: CIImage, scale: Double) -> CIImage {
        let extent = image.extent
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        // Scale noise so the grain size is resolution independent.
        let grainSize = max(1, 1.6 * scale)
        let scaledNoise = noise.transformed(by: CGAffineTransform(scaleX: grainSize, y: grainSize)).cropped(to: extent)
        let mono = scaledNoise.applyingFilter("CIMaximumComponent")
        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = mono
        alpha.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        alpha.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        alpha.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount * 0.45))
        guard let grain = alpha.outputImage else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// Alpha-blends `top` over `bottom`.
    public static func blend(_ top: CIImage, over bottom: CIImage, alpha: Double) -> CIImage {
        let clamped = alpha.clamped(to: 0...1)
        guard clamped > 0 else { return bottom }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = top
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(clamped))
        guard let faded = matrix.outputImage else { return bottom }
        return faded.composited(over: bottom).cropped(to: bottom.extent)
    }

    /// Blends `foreground` where `mask` is white and `background` elsewhere.
    public static func blendWithMask(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = foreground
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage?.cropped(to: background.extent) ?? background
    }

    /// Sets alpha from a mask (white = opaque).
    public static func applyingAlpha(mask: CIImage, to image: CIImage) -> CIImage {
        let transparent = CIImage(color: .clear).cropped(to: image.extent)
        return blendWithMask(foreground: image, background: transparent, mask: mask)
    }

    /// Full-strength adjustments for a look at `intensity`, combined with manual edits.
    public static func effectiveAdjustments(manual: Adjustments, look: (preset: FilterPreset, intensity: Double)?) -> Adjustments {
        guard let look else { return manual }
        return manual.combined(with: look.preset.recipe, weight: look.intensity)
    }
}

extension ToneCurve.Point {
    var cgPoint: CGPoint { CGPoint(x: input, y: output) }
}
#endif
