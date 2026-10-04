import Foundation
import PicshopCore

/// Select & Mask on the CPU (W2, §6 item 9): the reference the GPU graph (`EdgeRefine`) is tested against, and
/// what the sky heuristic's edge uses where Core Image is not available. Pure Swift, Linux-tested.
///
/// Planes are row-major `Float`s (row 0 at the top), one value per pixel: masks 0…1, guides 0…1 (luma).
/// The refine order is fixed:
/// 1. guided filter (He et al.): radius = radius × 0.02 × L, ε = 1e-2 × (1 − contrast) + 1e-4;
/// 2. smooth: a Gaussian of σ = 0.006 × L × smooth, re-thresholded towards a hard edge at 0.5 (smoothstep 0.4…0.6),
///    mixed in by `smooth`;
/// 3. feather: a Gaussian of σ = feather × 0.01 × L;
/// 4. contrast and shift edge: (m − 0.5) × (1 + 6 × contrast) + 0.5 + 0.25 × shiftEdge, then clamped.
public enum EdgeRefineReference {
    /// The guided filter's ε for a refinement.
    public static func epsilon(contrast: Double) -> Double {
        1e-2 * (1 - contrast.clamped(to: 0...1)) + 1e-4
    }

    /// The guided filter's radius in pixels at a longest side of `longestSide`.
    public static func guidedRadius(_ refinement: SelectionRefinement, longestSide: Int) -> Double {
        refinement.radius.clamped(to: 0...1) * 0.02 * Double(longestSide)
    }

    /// The smooth step's σ in pixels.
    public static func smoothSigma(_ refinement: SelectionRefinement, longestSide: Int) -> Double {
        0.006 * Double(longestSide) * refinement.smooth.clamped(to: 0...1)
    }

    /// The feather's σ in pixels.
    public static func featherSigma(_ refinement: SelectionRefinement, longestSide: Int) -> Double {
        refinement.feather.clamped(to: 0...1) * 0.01 * Double(longestSide)
    }

    /// Slope and offset of the contrast and shift-edge step: m′ = m × slope + bias, clamped.
    public static func contrastLine(_ refinement: SelectionRefinement) -> (slope: Double, bias: Double) {
        let slope = 1 + 6 * refinement.contrast.clamped(to: 0...1)
        return (slope, 0.5 - 0.5 * slope + 0.25 * refinement.shiftEdge.clamped(to: -1...1))
    }

    /// The re-threshold of the smooth step: smoothstep(0.4, 0.6, x).
    public static func rethreshold(_ x: Double) -> Double {
        let t = ((x - 0.4) / 0.2).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Refine

    /// Select & Mask: the four steps above on `mask`, guided by `guide`, at `width` × `height`.
    public static func refine(mask: [Float], guide: [Float], width: Int, height: Int, refinement: SelectionRefinement) -> [Float] {
        guard width > 0, height > 0, mask.count >= width * height, guide.count >= width * height else { return mask }
        let longest = max(width, height)
        var m = Array(mask.prefix(width * height))
        let radius = Int(guidedRadius(refinement, longestSide: longest).rounded())
        if radius >= 1 {
            m = guidedFilter(input: m, guide: Array(guide.prefix(width * height)), width: width, height: height, radius: radius,
                             epsilon: Float(epsilon(contrast: refinement.contrast)))
            clamp(&m)
        }
        let smooth = refinement.smooth.clamped(to: 0...1)
        if smooth > 0 {
            let blurred = gaussianBlur(m, width: width, height: height, sigma: smoothSigma(refinement, longestSide: longest))
            for index in m.indices {
                let target = Float(rethreshold(Double(blurred[index])))
                m[index] += (target - m[index]) * Float(smooth)
            }
        }
        let feather = featherSigma(refinement, longestSide: longest)
        if feather > 0 { m = gaussianBlur(m, width: width, height: height, sigma: feather) }
        let line = contrastLine(refinement)
        let slope = Float(line.slope), bias = Float(line.bias)
        for index in m.indices { m[index] = min(1, max(0, m[index] * slope + bias)) }
        return m
    }

    // MARK: - Guided filter

    /// He, Sun and Tang's guided filter with a gray guide: q = mean(a) × I + mean(b), a = cov(I, p) / (var(I) + ε),
    /// b = mean(p) − a × mean(I), all means over a (2r + 1)² box clipped at the edges.
    public static func guidedFilter(input p: [Float], guide i: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let count = width * height
        guard width > 0, height > 0, radius >= 1, p.count >= count, i.count >= count else { return p }
        var ii = [Float](repeating: 0, count: count)
        var ip = [Float](repeating: 0, count: count)
        for index in 0..<count {
            ii[index] = i[index] * i[index]
            ip[index] = i[index] * p[index]
        }
        let meanI = boxMean(i, width: width, height: height, radius: radius)
        let meanP = boxMean(p, width: width, height: height, radius: radius)
        let corrI = boxMean(ii, width: width, height: height, radius: radius)
        let corrIP = boxMean(ip, width: width, height: height, radius: radius)
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let variance = max(0, corrI[index] - meanI[index] * meanI[index])
            let covariance = corrIP[index] - meanI[index] * meanP[index]
            a[index] = covariance / (variance + epsilon)
            b[index] = meanP[index] - a[index] * meanI[index]
        }
        let meanA = boxMean(a, width: width, height: height, radius: radius)
        let meanB = boxMean(b, width: width, height: height, radius: radius)
        var q = [Float](repeating: 0, count: count)
        for index in 0..<count { q[index] = meanA[index] * i[index] + meanB[index] }
        return q
    }

    /// The mean over a (2r + 1)² box clipped at the edges (an integral image in Double).
    public static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard width > 0, height > 0, values.count >= width * height else { return values }
        let stride = width + 1
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                integral[(y + 1) * stride + (x + 1)] = integral[y * stride + (x + 1)] + row
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let sum = integral[(y1 + 1) * stride + (x1 + 1)] - integral[y0 * stride + (x1 + 1)]
                    - integral[(y1 + 1) * stride + x0] + integral[y0 * stride + x0]
                out[y * width + x] = Float(sum / Double((x1 - x0 + 1) * (y1 - y0 + 1)))
            }
        }
        return out
    }

    // MARK: - Gaussian

    /// A separable Gaussian, kernel radius ⌈3σ⌉, edges clamped (Core Image's `clampedToExtent` blur).
    public static func gaussianBlur(_ values: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        guard width > 0, height > 0, sigma > 0.01, values.count >= width * height else { return values }
        let radius = Int((3 * sigma).rounded(.up))
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var sum: Float = 0
                for k in -radius...radius {
                    sum += values[row + min(width - 1, max(0, x + k))] * kernel[k + radius]
                }
                horizontal[row + x] = sum
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in -radius...radius {
                    sum += horizontal[min(height - 1, max(0, y + k)) * width + x] * kernel[k + radius]
                }
                out[y * width + x] = sum
            }
        }
        return out
    }

    // MARK: - Decontamination

    /// The decontamination weight at alpha `a`: amount × (1 − |2a − 1|), largest on the half-transparent edge.
    public static func decontaminationWeight(alpha a: Double, amount: Double) -> Double {
        amount.clamped(to: 0...1) * (1 - abs(2 * a.clamped(to: 0...1) - 1))
    }

    /// Colour decontamination: F = unpremultiply(blur(I × α_hard)) with α_hard = α > 0.95 carried in alpha and a
    /// Gaussian of σ = `sigma` (0.01 × L), then out = mix(I, F, amount × (1 − |2α − 1|)). `rgb` holds three values
    /// per pixel; where the blur saw no foreground at all, the pixel keeps its colour.
    public static func decontaminate(rgb: [Float], alpha: [Float], width: Int, height: Int, amount: Double, sigma: Double) -> [Float] {
        let count = width * height
        guard width > 0, height > 0, rgb.count >= count * 3, alpha.count >= count, amount > 0 else { return rgb }
        var planes = [[Float]](repeating: [Float](repeating: 0, count: count), count: 4)
        for index in 0..<count {
            let hard: Float = alpha[index] > 0.95 ? 1 : 0
            planes[0][index] = rgb[index * 3] * hard
            planes[1][index] = rgb[index * 3 + 1] * hard
            planes[2][index] = rgb[index * 3 + 2] * hard
            planes[3][index] = hard
        }
        let blurred = planes.map { gaussianBlur($0, width: width, height: height, sigma: sigma) }
        var out = Array(rgb.prefix(count * 3))
        for index in 0..<count {
            let weight = Float(decontaminationWeight(alpha: Double(alpha[index]), amount: amount))
            let coverage = blurred[3][index]
            guard weight > 0, coverage > 1e-4 else { continue }
            for channel in 0..<3 {
                let foreground = blurred[channel][index] / coverage
                out[index * 3 + channel] += (foreground - out[index * 3 + channel]) * weight
            }
        }
        return out
    }

    // MARK: - Helpers

    static func clamp(_ values: inout [Float]) {
        for index in values.indices { values[index] = min(1, max(0, values[index])) }
    }

    /// Rec. 709 luma of RGBA8 bytes (gamma values), 0…1: the guide the reference uses.
    public static func luma(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let count = width * height
        guard rgba.count >= count * 4 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let r = Float(rgba[index * 4]), g = Float(rgba[index * 4 + 1]), b = Float(rgba[index * 4 + 2])
            out[index] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return out
    }
}
