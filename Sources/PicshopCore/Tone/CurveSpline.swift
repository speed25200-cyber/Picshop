import Foundation

public extension ToneCurve {
    /// The four curves of a ToneCurve: the rgb master and one per colour channel.
    enum Channel: String, Codable, Sendable, CaseIterable, Identifiable {
        case rgb, red, green, blue

        public var id: String { rawValue }
    }

    /// Control points per channel at most (the curves panel and the catalog's points param).
    static let maxPoints: Int = 16

    /// The two-point straight line: what the curves panel shows for an untouched channel.
    static let straight: [Point] = [Point(0, 0), Point(1, 1)]

    func points(_ channel: Channel) -> [Point] {
        switch channel {
        case .rgb: return rgb
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// Sets a channel's points: sorted by input, one point per input (the later one wins),
    /// at most `maxPoints` (the first and last kept, the middle thinned evenly). Fewer than
    /// two points leave the straight line.
    mutating func setPoints(_ points: [Point], for channel: Channel) {
        let cleaned = Self.sanitized(points)
        switch channel {
        case .rgb: rgb = cleaned
        case .red: red = cleaned
        case .green: green = cleaned
        case .blue: blue = cleaned
        }
    }

    /// Whether one channel leaves every value where it is (within 1/1024).
    func isIdentity(_ channel: Channel) -> Bool {
        CurveSpline.isIdentity(points(channel))
    }

    /// Points as `setPoints` stores them.
    static func sanitized(_ points: [Point]) -> [Point] {
        let merged = CurveSpline.merged(points)
        guard merged.count >= 2 else { return straight }
        guard merged.count > maxPoints else { return merged }
        // Thin the middle evenly, keeping both ends.
        let step = Double(merged.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { merged[Int((Double($0) * step).rounded())] }
    }
}

/// Evaluates a tone curve's control points: a monotone cubic (Fritsch–Carlson)
/// spline. It passes through every point, never overshoots between two of them
/// (a rising run of points gives a rising curve), and is flat beyond the first
/// and last points. Points are sorted by input first; points at the same input
/// are merged (the later one wins). No points is the identity.
public enum CurveSpline {
    public static func evaluate(_ points: [ToneCurve.Point], at x: Double) -> Double {
        Prepared(points).value(at: x)
    }

    /// `count` samples of the curve at 0, 1/(count-1) … 1.
    public static func table(_ points: [ToneCurve.Point], count: Int) -> [Float] {
        guard count > 1 else { return count == 1 ? [Float(evaluate(points, at: 0))] : [] }
        let spline = Prepared(points)
        var segment = 0
        var table = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let x = Double(index) / Double(count - 1)
            table[index] = Float(spline.value(at: x, from: &segment))
        }
        return table
    }

    /// Whether the curve leaves every value where it is, within 1/1024 (sampled at 257 inputs).
    public static func isIdentity(_ points: [ToneCurve.Point]) -> Bool {
        if points.isEmpty || points == ToneCurve.straight || points == ToneCurve.linear { return true }
        // Every point must sit on the diagonal first: cheaper, and exact for the points themselves.
        guard points.allSatisfy({ abs($0.output - $0.input) <= 1.0 / 1024 }) else { return false }
        let samples = table(points, count: 257)
        for (index, value) in samples.enumerated() where abs(Double(value) - Double(index) / 256) > 1.0 / 1024 {
            return false
        }
        return true
    }

    /// Sorted by input, one point per input (inputs closer than 1e-6 are the same; the later point wins).
    static func merged(_ points: [ToneCurve.Point]) -> [ToneCurve.Point] {
        // Stable sort keeps the given order among equal inputs, so the later point is last.
        let sorted = points.enumerated().sorted { a, b in
            a.element.input != b.element.input ? a.element.input < b.element.input : a.offset < b.offset
        }.map(\.element)
        var result: [ToneCurve.Point] = []
        result.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = result.last, abs(point.input - last.input) < 1e-6 {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }

    /// The spline's knots and tangents, computed once per curve.
    struct Prepared {
        let xs: [Double]
        let ys: [Double]
        let tangents: [Double]

        init(_ points: [ToneCurve.Point]) {
            let knots = CurveSpline.merged(points)
            xs = knots.map(\.input)
            ys = knots.map(\.output)
            tangents = Self.tangents(xs, ys)
        }

        /// Fritsch–Carlson: secant averages inside, zero at local extrema, then scaled so
        /// that no segment overshoots (α² + β² ≤ 9).
        static func tangents(_ xs: [Double], _ ys: [Double]) -> [Double] {
            let n = xs.count
            guard n >= 2 else { return [Double](repeating: 0, count: n) }
            var secants = [Double](repeating: 0, count: n - 1)
            for k in 0..<(n - 1) {
                secants[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k])
            }
            var m = [Double](repeating: 0, count: n)
            m[0] = secants[0]
            m[n - 1] = secants[n - 2]
            if n > 2 {
                for k in 1..<(n - 1) {
                    m[k] = secants[k - 1] * secants[k] <= 0 ? 0 : (secants[k - 1] + secants[k]) / 2
                }
            }
            for k in 0..<(n - 1) {
                let d = secants[k]
                if d == 0 {
                    m[k] = 0
                    m[k + 1] = 0
                    continue
                }
                let alpha = m[k] / d, beta = m[k + 1] / d
                // A tangent against the secant's direction would leave the segment's range.
                if alpha < 0 { m[k] = 0 }
                if beta < 0 { m[k + 1] = 0 }
                let a = max(0, alpha), b = max(0, beta)
                let sum = a * a + b * b
                if sum > 9 {
                    let tau = 3 / sum.squareRoot()
                    m[k] = tau * a * d
                    m[k + 1] = tau * b * d
                }
            }
            return m
        }

        func value(at x: Double) -> Double {
            var segment = 0
            return value(at: x, from: &segment)
        }

        /// The value at `x`, searching segments from `segment` on (ascending samples reuse it).
        func value(at x: Double, from segment: inout Int) -> Double {
            guard let first = xs.first, let last = xs.last else { return min(max(x, 0), 1) }
            if xs.count == 1 || x <= first { return clamp(ys[0]) }
            if x >= last { return clamp(ys[ys.count - 1]) }
            if segment >= xs.count - 1 || xs[segment] > x { segment = 0 }
            while segment < xs.count - 2, xs[segment + 1] < x { segment += 1 }
            let x0 = xs[segment], x1 = xs[segment + 1]
            let h = x1 - x0
            let t = (x - x0) / h
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * ys[segment] + h10 * h * tangents[segment] + h01 * ys[segment + 1] + h11 * h * tangents[segment + 1]
            return clamp(y)
        }

        private func clamp(_ y: Double) -> Double { min(max(y, 0), 1) }
    }
}
