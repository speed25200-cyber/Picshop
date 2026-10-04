#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Select & Mask on the GPU (W2, §6 item 9): the same steps, in the same order and with the same constants, as
/// `EdgeRefineReference`, which tests it. Lazy Core Image graphs: `refinePreview` draws them at the interactive
/// size, `refineSelection` at the working size.
///
/// The guided filter is Core Image's `CIGuidedFilter`, reached by name (inputImage, inputGuideImage, inputRadius,
/// inputEpsilon) so the build never depends on a typed accessor; without it the mask goes on unguided.
public enum EdgeRefine {
    /// The guided filter of `mask` (opaque, value in RGB) by `guide` (the picture), radius in pixels.
    public static func guided(_ mask: CIImage, guide: CIImage, radius: Double, epsilon: Double) -> CIImage {
        let extent = mask.extent
        guard radius >= 1, !extent.isInfinite else { return mask }
        guard let filter = CIFilter(name: "CIGuidedFilter") else { return mask }
        filter.setValue(mask.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(guide.clampedToExtent(), forKey: "inputGuideImage")
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(epsilon, forKey: "inputEpsilon")
        guard let output = filter.outputImage else { return mask }
        return MaskComponentImages.opaque(output.cropped(to: extent), extent: extent)
    }

    /// The four Select & Mask steps on `mask`, guided by `guide`, at the mask's extent.
    public static func refine(_ mask: CIImage, guide: CIImage, refinement: SelectionRefinement) -> CIImage {
        let extent = mask.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return mask }
        let longest = Int(max(extent.width, extent.height))
        var m = mask
        let radius = EdgeRefineReference.guidedRadius(refinement, longestSide: longest).rounded()
        if radius >= 1 {
            m = guided(m, guide: guide, radius: radius, epsilon: EdgeRefineReference.epsilon(contrast: refinement.contrast))
            m = MaskComponentImages.line(m, slope: 1, bias: 0)
        }
        let smooth = refinement.smooth.clamped(to: 0...1)
        if smooth > 0 {
            let sigma = EdgeRefineReference.smoothSigma(refinement, longestSide: longest)
            let blurred = sigma >= 0.3 ? m.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent) : m
            let target = MaskComponentImages.curves(blurred, table: rethresholdTable)
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = m
            mix.targetImage = target
            mix.time = Float(smooth)
            m = mix.outputImage?.cropped(to: extent) ?? target
        }
        let feather = EdgeRefineReference.featherSigma(refinement, longestSide: longest)
        if feather >= 0.3 {
            m = m.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: extent)
        }
        let line = EdgeRefineReference.contrastLine(refinement)
        return MaskComponentImages.line(m, slope: line.slope, bias: line.bias)
    }

    /// smoothstep(0.4, 0.6, x) as 256 RGB triplets: the smooth step's re-threshold.
    static let rethresholdTable: Data = {
        var values: [Float] = []
        for index in 0..<256 {
            let y = Float(EdgeRefineReference.rethreshold(Double(index) / 255))
            values += [y, y, y]
        }
        return Data(floats: values)
    }()

    /// The decontamination weight table: 1 − |2α − 1|, times `amount` (applied to the mask as 256 triplets).
    static func weightTable(amount: Double) -> Data {
        var values: [Float] = []
        for index in 0..<256 {
            let y = Float(EdgeRefineReference.decontaminationWeight(alpha: Double(index) / 255, amount: amount))
            values += [y, y, y]
        }
        return Data(floats: values)
    }

    /// Colour decontamination of `image` along the edge of `alpha` (opaque mask, value in RGB): F =
    /// unpremultiply(blur(I × α_hard)) with α_hard = α > 0.95 in alpha and σ = 0.01 × L, then mix(I, F, amount ×
    /// (1 − |2α − 1|)). Where the blur saw no foreground, F is clear and the pixel keeps its colour.
    public static func decontaminate(_ image: CIImage, alpha: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        guard amount > 0.001, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        let hard = MaskComponentImages.line(alpha.cropped(to: extent), slope: 1000, bias: -950)
        let premultiplied = AdjustmentPipeline.applyingAlpha(mask: hard, to: image)
        let sigma = 0.01 * Double(max(extent.width, extent.height))
        let blurred = premultiplied.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, sigma)).cropped(to: extent)
        // The foreground colour estimate, unpremultiplied and made opaque. Where the blur saw no foreground at all
        // it comes back black, so the weight is cut to 0 there (coverage below 1e-4 keeps the pixel's colour).
        let foreground = blurred.unpremultiplyingAlpha().settingAlphaOne(in: extent)
        let weight = MaskComponentImages.curves(alpha.cropped(to: extent), table: weightTable(amount: amount))
        let coverage = MaskComponentImages.line(alphaChannel(of: blurred), slope: 1e4, bias: 0)
        let finalWeight = MaskComponentImages.minimum(weight, coverage)
        return AdjustmentPipeline.blendWithMask(foreground: foreground.cropped(to: extent), background: image, mask: finalWeight)
    }

    /// The alpha of `image` as an opaque gray image.
    static func alphaChannel(of image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (matrix.outputImage ?? image).cropped(to: image.extent)
    }
}
#endif
