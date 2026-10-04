#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PicshopCore

/// Select & Mask on the GPU (W2, §6 item 9): the same steps, in the same order and with the same constants, as
/// `EdgeRefineReference`, which tests it. Lazy Core Image graphs: `refinePreview` draws them at the interactive
/// size, `refineSelection` at the working size.
///
/// The guided filter is the reference's own (He et al., a (2r + 1)² box clipped at the edges, the guide's luma), run
/// by four small kernels (`GuidedKernels`). Core Image's `CIGuidedFilter` is an upsampler whose radius and ε do not
/// mean the reference's: at radius 4 on a two-tone guide it left a soft edge where it was instead of moving it onto
/// the guide's, so it is only the fallback when the kernels cannot be built.
public enum EdgeRefine {
    /// The guided filter of `mask` (opaque, value in RGB) by `guide` (the picture), radius in pixels (rounded, as the
    /// reference's). The guide is read as the luma of its gamma-encoded (sRGB curve) working values, the reference's
    /// "luma of the picture's bytes"; the result is opaque, value in RGB, not clamped.
    public static func guided(_ mask: CIImage, guide: CIImage, radius: Double, epsilon: Double) -> CIImage {
        let extent = mask.extent
        guard radius >= 1, !extent.isInfinite else { return mask }
        let r = Int(radius.rounded())
        if let kernels = GuidedKernels.shared.kernels(radius: r) {
            let luma = guide.applyingFilter("CILinearToSRGBToneCurve")
            // Means over the box, carried premultiplied: the box sums values and coverage (alpha, 0 outside the
            // extent), so value / alpha is the mean over the in-extent pixels, the reference's clipped box.
            func box(_ image: CIImage?) -> CIImage? {
                var out = image?.cropped(to: extent)
                for direction in [CIVector(x: 1, y: 0), CIVector(x: 0, y: 1)] {
                    guard let input = out else { return nil }
                    let dx = CGFloat(r) * direction.x, dy = CGFloat(r) * direction.y
                    out = kernels.box.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -dx, dy: -dy) },
                                            arguments: [input, direction])
                }
                return out
            }
            if let first = box(kernels.prepare.apply(extent: extent, arguments: [luma, mask, 0])),
               let second = box(kernels.prepare.apply(extent: extent, arguments: [luma, mask, 1])),
               let coefficients = box(kernels.coefficients.apply(extent: extent, arguments: [first, second, epsilon])),
               let output = kernels.output.apply(extent: extent, arguments: [coefficients, luma]) {
                return MaskComponentImages.opaque(output, extent: extent)
            }
        }
        guard let filter = CIFilter(name: "CIGuidedFilter") else { return mask }
        // `CIGuidedFilter` upsamples its input to the guide's extent, so both go in finite and equal: an infinite
        // (clamped) extent gives it no scale and the output reads black. Clamped, then cropped 2r beyond the
        // extent (the reach of its two box passes), so the edge pixels still see replicated borders.
        let pad = CGFloat((2 * radius).rounded(.up))
        let padded = extent.insetBy(dx: -pad, dy: -pad)
        filter.setValue(mask.clampedToExtent().cropped(to: padded), forKey: kCIInputImageKey)
        filter.setValue(guide.clampedToExtent().cropped(to: padded), forKey: "inputGuideImage")
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        filter.setValue(epsilon, forKey: "inputEpsilon")
        guard let output = filter.outputImage else { return mask }
        return MaskComponentImages.opaque(output.cropped(to: extent), extent: extent)
    }

    /// The guided filter's kernels (Core Image Kernel Language, compiled once; the box once per radius, its loop
    /// bound a constant). Values are those of the reference with the guide centred (I − 0.5, which leaves a, and so
    /// q, unchanged) so I² and I·p keep their precision in half-float intermediates.
    final class GuidedKernels: @unchecked Sendable {
        static let shared = GuidedKernels()

        struct Kernels {
            /// (I, p, I², 1) for `second` 0, (I·p, 0, 0, 1) for 1, I the guide's luma − 0.5 and p the mask.
            let prepare: CIColorKernel
            /// The sum of 2r + 1 samples along `direction`, over 2r + 1: premultiplied means.
            let box: CIKernel
            /// (a, b, 0, 1) from the means: a = cov(I, p) / (var(I) + ε), b = mean(p) − a × mean(I).
            let coefficients: CIColorKernel
            /// q = mean(a) × I + mean(b), opaque gray.
            let output: CIColorKernel
        }

        private let lock = NSLock()
        private var boxes: [Int: CIKernel] = [:]
        private let base: (CIColorKernel, CIColorKernel, CIColorKernel)?

        init() {
            let luma = "dot(g.rgb, vec3(0.2126, 0.7152, 0.0722)) - 0.5"
            let prepare = CIColorKernel(source: """
                kernel vec4 picshopGuidedPrepare(__sample g, __sample m, float second) {
                    float i = \(luma);
                    float p = m.r;
                    return mix(vec4(i, p, i * i, 1.0), vec4(i * p, 0.0, 0.0, 1.0), second);
                }
                """)
            let coefficients = CIColorKernel(source: """
                kernel vec4 picshopGuidedCoefficients(__sample s, __sample t, float epsilon) {
                    vec3 m = s.rgb / max(s.a, 0.000001);
                    float ip = t.r / max(t.a, 0.000001);
                    float variance = max(0.0, m.b - m.r * m.r);
                    float a = (ip - m.r * m.g) / (variance + epsilon);
                    return vec4(a, m.g - a * m.r, 0.0, 1.0);
                }
                """)
            let output = CIColorKernel(source: """
                kernel vec4 picshopGuidedOutput(__sample ab, __sample g) {
                    float i = \(luma);
                    float q = (ab.r * i + ab.g) / max(ab.a, 0.000001);
                    return vec4(q, q, q, 1.0);
                }
                """)
            if let prepare, let coefficients, let output { base = (prepare, coefficients, output) } else { base = nil }
        }

        /// The kernels for a box of radius `radius`, nil when Core Image cannot build them.
        func kernels(radius: Int) -> Kernels? {
            guard let base, radius >= 1 else { return nil }
            lock.lock()
            defer { lock.unlock() }
            if boxes[radius] == nil {
                boxes[radius] = CIKernel(source: """
                    kernel vec4 picshopGuidedBox\(radius)(sampler src, vec2 direction) {
                        vec2 d = destCoord();
                        vec4 sum = vec4(0.0);
                        for (int k = -\(radius); k <= \(radius); k++) {
                            sum += sample(src, samplerTransform(src, d + direction * float(k)));
                        }
                        return sum / \(2 * radius + 1).0;
                    }
                    """)
            }
            guard let box = boxes[radius] else { return nil }
            return Kernels(prepare: base.0, box: box, coefficients: base.1, output: base.2)
        }
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
