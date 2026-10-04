import Foundation

/// Lab statistics of a rendered proxy, weighted by a mask: what the pixel postconditions compare (D14).
public struct PixelStats: Hashable, Sendable {
    public var meanL: Double
    public var stdL: Double
    public var meanChroma: Double
    public var meanA: Double
    public var meanB: Double
    /// Σ weights (pixels).
    public var weight: Double

    public init(meanL: Double = 0, stdL: Double = 0, meanChroma: Double = 0, meanA: Double = 0, meanB: Double = 0, weight: Double = 0) {
        self.meanL = meanL
        self.stdL = stdL
        self.meanChroma = meanChroma
        self.meanA = meanA
        self.meanB = meanB
        self.weight = weight
    }

    public struct Regions: Hashable, Sendable {
        /// Weights m.
        public var inside: PixelStats
        /// Weights 1, where m < 0.05.
        public var outside: PixelStats
        /// Mean m.
        public var coverage: Double

        public init(inside: PixelStats, outside: PixelStats, coverage: Double) {
            self.inside = inside
            self.outside = outside
            self.coverage = coverage
        }
    }

    /// Where a pixel counts as outside the mask (m below it).
    public static let outsideThreshold: Float = 0.05

    /// Gamma sRGB RGBA8 → Lab (MaskMath.lab, alpha ignored); `weights` 0…1 per pixel (nil: all 1). Weighted means of
    /// L*, a*, b* and chroma √(a² + b²), the weighted standard deviation of L*, and Σ weights. All zero when the
    /// sizes do not match or no pixel has weight.
    public static func measure(rgba: [UInt8], width: Int, height: Int, weights: [Float]?) -> PixelStats {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return PixelStats() }
        if let weights, weights.count != width * height { return PixelStats() }
        return accumulate(rgba: rgba, count: width * height) { index in weights.map { Double($0[index]) } ?? 1 }
    }

    /// Inside (weights m), outside (weights 1 where m < 0.05) and coverage (mean m) of a mask over the image.
    public static func regions(rgba: [UInt8], width: Int, height: Int, mask: [Float]) -> Regions {
        let count = width * height
        guard width > 0, height > 0, rgba.count >= count * 4, mask.count == count else {
            return Regions(inside: PixelStats(), outside: PixelStats(), coverage: 0)
        }
        let clamped = mask.map { $0.isNaN ? 0 : min(1, max(0, $0)) }
        let inside = accumulate(rgba: rgba, count: count) { Double(clamped[$0]) }
        let outside = accumulate(rgba: rgba, count: count) { clamped[$0] < outsideThreshold ? 1 : 0 }
        let coverage = clamped.reduce(0.0) { $0 + Double($1) } / Double(count)
        return Regions(inside: inside, outside: outside, coverage: coverage)
    }

    /// One pass for the weighted sums, a second for the deviation around the mean (numerically stable).
    private static func accumulate(rgba: [UInt8], count: Int, weight: (Int) -> Double) -> PixelStats {
        var labs = [LabColor]()
        labs.reserveCapacity(count)
        var weights = [Double]()
        weights.reserveCapacity(count)
        var total = 0.0, sumL = 0.0, sumA = 0.0, sumB = 0.0, sumChroma = 0.0
        rgba.withUnsafeBufferPointer { bytes in
            for index in 0..<count {
                let w = weight(index)
                guard w > 0, w.isFinite else { continue }
                let lab = MaskMath.lab(bytes: bytes[4 * index], bytes[4 * index + 1], bytes[4 * index + 2])
                labs.append(lab)
                weights.append(w)
                total += w
                sumL += w * lab.l
                sumA += w * lab.a
                sumB += w * lab.b
                sumChroma += w * (lab.a * lab.a + lab.b * lab.b).squareRoot()
            }
        }
        guard total > 0 else { return PixelStats() }
        let meanL = sumL / total
        var variance = 0.0
        for (lab, w) in zip(labs, weights) {
            let d = lab.l - meanL
            variance += w * d * d
        }
        return PixelStats(meanL: meanL, stdL: (variance / total).squareRoot(), meanChroma: sumChroma / total,
                          meanA: sumA / total, meanB: sumB / total, weight: total)
    }
}

// MARK: - W3: per-pixel composite delta (§4.8)

public extension PixelStats {
    /// Per-pixel CIE ΔE76 between two renders of the same size: its mean and its 99th percentile. The composite
    /// postconditions read it, so pixels that moved without changing the average colour still count (a merge placed
    /// at the wrong offset).
    struct CompositeDelta: Hashable, Sendable {
        public var mean: Double
        public var p99: Double

        public init(mean: Double, p99: Double) {
            self.mean = mean
            self.p99 = p99
        }
    }

    /// The delta between two gamma sRGB RGBA8 renders (alpha ignored, as `regions` does); nil when either is short
    /// of `width × height` pixels or empty.
    static func compositeDelta(before: [UInt8], after: [UInt8], width: Int, height: Int) -> CompositeDelta? {
        let count = width * height
        guard width > 0, height > 0, before.count >= count * 4, after.count >= count * 4 else { return nil }
        var deltas = [Double](repeating: 0, count: count)
        var sum = 0.0
        for index in 0..<count {
            let i = index * 4
            let delta = MaskMath.deltaE(MaskMath.lab(bytes: before[i], before[i + 1], before[i + 2]),
                                        MaskMath.lab(bytes: after[i], after[i + 1], after[i + 2]))
            deltas[index] = delta
            sum += delta
        }
        deltas.sort()
        let p99 = deltas[min(count - 1, Int((Double(count) * 0.99).rounded(.down)))]
        return CompositeDelta(mean: sum / Double(count), p99: p99)
    }
}
