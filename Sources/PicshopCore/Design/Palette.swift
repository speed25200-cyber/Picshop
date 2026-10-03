import Foundation

/// The colours of PSBackdrop, taken from the user's own pictures.
///
/// `derive` runs a seeded k-means (k = 6, 5 passes) in OKLab on a small
/// thumbnail, keeps the four most populated clusters, and maps each into the
/// backdrop's band: OKLCH lightness 0.14…0.28 (the cluster's own lightness,
/// scaled into the band, so a bright photo stays a little lighter than a dark
/// one) and chroma at most 0.08, keeping the hue. Text at 62 % white and above
/// therefore keeps at least 4.5:1 over every stop (`contrastRatio`).
///
/// Pure Swift: it builds and is tested on Linux. The UI turns the stops into a
/// static mesh gradient once per palette change.
public struct PSPalette: Hashable, Sendable {
    /// Four colours, darkest first.
    public var stops: [PSColor]
    /// A brighter colour of the dominant hue (OKLCH lightness 0.45, chroma ≤ 0.12):
    /// the hero card's shadow and the backdrop's top light.
    public var glow: PSColor

    public init(stops: [PSColor], glow: PSColor) {
        self.stops = stops
        self.glow = glow
    }

    /// The backdrop's band.
    public static let lightnessRange: ClosedRange<Double> = 0.14...0.28
    public static let maxChroma = 0.08
    public static let glowLightness = 0.45
    public static let glowMaxChroma = 0.12
    /// Clusters, passes and kept stops.
    public static let clusterCount = 6
    public static let passes = 5
    public static let stopCount = 4

    /// A cool graphite, for a library without pictures and for previews.
    public static let fallback = PSPalette(
        stops: [
            OKLCH(l: 0.15, c: 0.020, h: 275).color,
            OKLCH(l: 0.18, c: 0.030, h: 280).color,
            OKLCH(l: 0.22, c: 0.040, h: 290).color,
            OKLCH(l: 0.26, c: 0.045, h: 300).color,
        ],
        glow: OKLCH(l: glowLightness, c: 0.08, h: 285).color
    )

    // MARK: Deriving

    /// The palette of an RGBA8 image (sRGB, row-major, `width × height × 4` bytes).
    /// Transparent pixels are skipped; large images are sampled down to about
    /// 4,096 pixels. The same pixels and seed always give the same palette.
    /// Returns `fallback` when there is nothing to read.
    public static func derive(rgba: [UInt8], width: Int, height: Int, seed: UInt64 = 1) -> PSPalette {
        let samples = Self.samples(rgba: rgba, width: width, height: height)
        guard !samples.isEmpty else { return fallback }
        let clusters = KMeans.run(samples, k: clusterCount, passes: passes, seed: seed)
        guard let dominant = clusters.first else { return fallback }

        // The four most populated colours, then darkest first.
        var picked = clusters.prefix(stopCount).map(\.center)
        // A picture with fewer than four distinct colours: steps of the dominant one.
        let steps: [Double] = [-0.18, 0.12, -0.08, 0.2]
        var step = 0
        while picked.count < stopCount {
            var lab = dominant.center
            lab.l = min(1, max(0, lab.l + steps[step % steps.count]))
            picked.append(lab)
            step += 1
        }
        let stops = picked
            .map { band(OKLCH(lab: $0)) }
            .sorted { $0.l < $1.l }
            .map(\.color)

        // The glow takes the hue that is both common and colourful.
        let hueSource = clusters.max { lhs, rhs in
            Double(lhs.count) * OKLCH(lab: lhs.center).c < Double(rhs.count) * OKLCH(lab: rhs.center).c
        } ?? dominant
        let hue = OKLCH(lab: hueSource.center)
        let glow = OKLCH(l: glowLightness, c: min(glowMaxChroma, hue.c), h: hue.h).fitted().color
        return PSPalette(stops: stops, glow: glow)
    }

    /// A colour moved into the backdrop's band: its lightness scaled into 0.14…0.28,
    /// its chroma capped at 0.08, its hue kept, then brought into the sRGB gamut.
    public static func band(_ color: OKLCH) -> OKLCH {
        let lightness = lightnessRange.lowerBound + (lightnessRange.upperBound - lightnessRange.lowerBound) * min(1, max(0, color.l))
        return OKLCH(l: lightness, c: min(maxChroma, max(0, color.c)), h: color.h).fitted()
    }

    /// Opaque pixels as OKLab, at most about 4,096 of them.
    static func samples(rgba: [UInt8], width: Int, height: Int) -> [OKLab] {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return [] }
        let pixels = width * height
        let stride = max(1, Int((Double(pixels) / 4096).squareRoot().rounded(.up)))
        var result: [OKLab] = []
        result.reserveCapacity(pixels / (stride * stride) + 1)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let index = (y * width + x) * 4
                if rgba[index + 3] >= 128 {
                    let color = PSColor(red: Double(rgba[index]) / 255, green: Double(rgba[index + 1]) / 255, blue: Double(rgba[index + 2]) / 255)
                    result.append(OKLab(color))
                }
                x += stride
            }
            y += stride
        }
        return result
    }

    // MARK: Contrast

    /// WCAG 2.x contrast ratio, 1…21. A translucent foreground is first laid
    /// over the background (in gamma-encoded sRGB, as the UI composites).
    public static func contrastRatio(_ a: PSColor, _ b: PSColor) -> Double {
        let top = a.alpha < 1 ? a.composited(over: b) : a
        let first = relativeLuminance(top)
        let second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG 2.x relative luminance of an opaque sRGB colour.
    public static func relativeLuminance(_ color: PSColor) -> Double {
        0.2126 * OKLab.linear(color.red) + 0.7152 * OKLab.linear(color.green) + 0.0722 * OKLab.linear(color.blue)
    }
}

// MARK: - OKLab and OKLCH

/// Björn Ottosson's OKLab (2020): perceptual lightness, a and b.
public struct OKLab: Hashable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From gamma-encoded sRGB (alpha ignored).
    public init(_ color: PSColor) {
        let r = Self.linear(color.red), g = Self.linear(color.green), bl = Self.linear(color.blue)
        let lms = (
            0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl,
            0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl,
            0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl
        )
        let l_ = Foundation.cbrt(lms.0), m_ = Foundation.cbrt(lms.1), s_ = Foundation.cbrt(lms.2)
        l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    }

    /// Linear sRGB, unclamped (a channel outside 0…1 means out of gamut).
    public var linearRGB: (red: Double, green: Double, blue: Double) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        return (
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        )
    }

    /// Whether the colour fits sRGB (within `tolerance` on each linear channel).
    public func isInGamut(tolerance: Double = 1e-6) -> Bool {
        let rgb = linearRGB
        let range = -tolerance...(1 + tolerance)
        return range.contains(rgb.red) && range.contains(rgb.green) && range.contains(rgb.blue)
    }

    /// Gamma-encoded sRGB, clamped.
    public var color: PSColor {
        let rgb = linearRGB
        return PSColor(red: Self.encoded(rgb.red), green: Self.encoded(rgb.green), blue: Self.encoded(rgb.blue))
    }

    /// sRGB transfer function, decoding.
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// sRGB transfer function, encoding (clamped to 0…1).
    static func encoded(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// OKLab in polar form: lightness 0…1, chroma, hue in degrees.
public struct OKLCH: Hashable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    public init(lab: OKLab) {
        l = lab.l
        c = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let degrees = atan2(lab.b, lab.a) * 180 / Double.pi
        h = degrees < 0 ? degrees + 360 : degrees
    }

    public init(_ color: PSColor) {
        self.init(lab: OKLab(color))
    }

    public var lab: OKLab {
        let radians = h * Double.pi / 180
        return OKLab(l: l, a: c * cos(radians), b: c * sin(radians))
    }

    public var color: PSColor { lab.color }

    /// The same lightness and hue with the chroma lowered until the colour fits sRGB.
    public func fitted() -> OKLCH {
        if lab.isInGamut() { return self }
        var low = 0.0, high = c
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if OKLCH(l: l, c: mid, h: h).lab.isInGamut() { low = mid } else { high = mid }
        }
        return OKLCH(l: l, c: low, h: h)
    }
}

extension PSColor {
    /// This colour at its alpha over an opaque `background`, in gamma-encoded sRGB.
    public func composited(over background: PSColor) -> PSColor {
        PSColor(red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha))
    }
}

// MARK: - k-means

/// Lloyd's k-means in OKLab with a k-means++ start from a seeded SplitMix64 (PaletteRandom),
/// so a given picture always gives the same palette.
enum KMeans {
    struct Cluster: Equatable {
        var center: OKLab
        var count: Int
    }

    /// Non-empty clusters, most populated first (ties: darker first).
    static func run(_ points: [OKLab], k: Int, passes: Int, seed: UInt64) -> [Cluster] {
        guard !points.isEmpty, k > 0 else { return [] }
        var random = PaletteRandom(seed: seed)
        var centers = seeds(points, k: min(k, points.count), random: &random)
        var assignment = [Int](repeating: 0, count: points.count)
        var counts = [Int](repeating: 0, count: centers.count)
        for _ in 0..<max(1, passes) {
            var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for (index, point) in points.enumerated() {
                let nearest = Self.nearest(point, in: centers)
                assignment[index] = nearest
                counts[nearest] += 1
                sums[nearest].0 += point.l
                sums[nearest].1 += point.a
                sums[nearest].2 += point.b
            }
            for index in centers.indices where counts[index] > 0 {
                let n = Double(counts[index])
                centers[index] = OKLab(l: sums[index].0 / n, a: sums[index].1 / n, b: sums[index].2 / n)
            }
        }
        return zip(centers, counts)
            .filter { $0.1 > 0 }
            .map { Cluster(center: $0.0, count: $0.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.center.l < $1.center.l }
    }

    /// k-means++: each next seed is drawn with probability proportional to its squared distance.
    private static func seeds(_ points: [OKLab], k: Int, random: inout PaletteRandom) -> [OKLab] {
        var centers = [points[Int(random.next() % UInt64(points.count))]]
        var distances = points.map { distance($0, centers[0]) }
        while centers.count < k {
            let total = distances.reduce(0, +)
            guard total > 0 else { break }
            var target = random.unit() * total
            var chosen = points.count - 1
            for (index, value) in distances.enumerated() {
                target -= value
                if target <= 0 {
                    chosen = index
                    break
                }
            }
            let center = points[chosen]
            centers.append(center)
            for index in points.indices {
                distances[index] = min(distances[index], distance(points[index], center))
            }
        }
        return centers
    }

    private static func nearest(_ point: OKLab, in centers: [OKLab]) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, center) in centers.enumerated() {
            let d = distance(point, center)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }

    static func distance(_ lhs: OKLab, _ rhs: OKLab) -> Double {
        let dl = lhs.l - rhs.l, da = lhs.a - rhs.a, db = lhs.b - rhs.b
        return dl * dl + da * da + db * db
    }
}

/// A tiny deterministic generator: Steele, Lea and Flood's SplitMix64.
struct PaletteRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
