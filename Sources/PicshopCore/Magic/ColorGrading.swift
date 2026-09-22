import Foundation

/// Hue, saturation and luminance per colour band — Lightroom's HSL mixer.
///
/// Bands overlap smoothly (each pixel belongs to its two nearest bands in a
/// partition of unity) and act in proportion to the pixel's own saturation,
/// so greys and skin under a "less orange" stay natural.
public struct ColorMixer: Hashable, Codable, Sendable {
    public enum Band: Int, CaseIterable, Codable, Sendable, Identifiable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        public var id: Int { rawValue }

        /// Centre hue in degrees.
        public var centerHue: Double { [0, 32, 60, 120, 180, 225, 270, 315][rawValue] }

        public var englishName: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
        public var frenchName: String { ["Rouge", "Orange", "Jaune", "Vert", "Cyan", "Bleu", "Violet", "Magenta"][rawValue] }

        public var aliases: [String] {
            switch self {
            case .red: return ["red", "reds", "rouge", "rouges"]
            case .orange: return ["orange", "oranges", "skin tones", "tons chair"]
            case .yellow: return ["yellow", "yellows", "jaune", "jaunes"]
            case .green: return ["green", "greens", "vert", "verts", "foliage", "feuillage", "vegetation"]
            case .aqua: return ["aqua", "cyan", "cyans", "turquoise", "teal"]
            case .blue: return ["blue", "blues", "bleu", "bleus", "sky", "ciel"]
            case .purple: return ["purple", "purples", "violet", "violets"]
            case .magenta: return ["magenta", "magentas", "pink", "rose", "roses"]
            }
        }

        public static func matching(_ text: String) -> Band? {
            let query = " " + text.normalizedForMatching + " "
            return allCases.first { band in band.aliases.contains { query.contains(" \($0) ") } }
        }
    }

    /// −1…1 per band: ±30° of hue.
    public var hue: [Double]
    /// −1…1 per band: from grey to twice as saturated.
    public var saturation: [Double]
    /// −1…1 per band: darker or lighter.
    public var luminance: [Double]

    public init(hue: [Double] = [], saturation: [Double] = [], luminance: [Double] = []) {
        func normalized(_ values: [Double]) -> [Double] {
            (0..<Band.allCases.count).map { $0 < values.count ? values[$0].clamped(to: -1...1) : 0 }
        }
        self.hue = normalized(hue)
        self.saturation = normalized(saturation)
        self.luminance = normalized(luminance)
    }

    public static let neutral = ColorMixer()

    public var isNeutral: Bool {
        (hue + saturation + luminance).allSatisfy { abs($0) < 0.0005 }
    }

    public enum Channel: String, CaseIterable, Codable, Sendable, Identifiable {
        case hue, saturation, luminance
        public var id: String { rawValue }
    }

    public subscript(band: Band, channel: Channel) -> Double {
        get {
            switch channel {
            case .hue: return hue[band.rawValue]
            case .saturation: return saturation[band.rawValue]
            case .luminance: return luminance[band.rawValue]
            }
        }
        set {
            let value = newValue.clamped(to: -1...1)
            switch channel {
            case .hue: hue[band.rawValue] = value
            case .saturation: saturation[band.rawValue] = value
            case .luminance: luminance[band.rawValue] = value
            }
        }
    }

    /// Weights of the two bands nearest to `hueDegrees` (a partition of unity).
    static func weights(forHue hueDegrees: Double) -> [(Int, Double)] {
        let h = (hueDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let centers = Band.allCases.map(\.centerHue)
        for index in 0..<centers.count {
            let start = centers[index]
            let end = index + 1 < centers.count ? centers[index + 1] : 360
            if h >= start && h < end {
                let t = (h - start) / (end - start)
                let smooth = t * t * (3 - 2 * t)
                return [(index, 1 - smooth), ((index + 1) % centers.count, smooth)]
            }
        }
        return [(0, 1)]
    }
}

/// One wheel of a three-way grade: a tint (hue and how much) and a lift.
public struct ColorWheel: Hashable, Codable, Sendable {
    /// Degrees, 0 = red.
    public var hue: Double
    /// 0…1.
    public var amount: Double
    /// −1…1: darker or lighter in this tonal range.
    public var luminance: Double

    public init(hue: Double = 0, amount: Double = 0, luminance: Double = 0) {
        self.hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        self.amount = amount.clamped(to: 0...1)
        self.luminance = luminance.clamped(to: -1...1)
    }

    public var isNeutral: Bool { amount < 0.0005 && abs(luminance) < 0.0005 }
}

/// Three-way colour grading — shadows, midtones, highlights — the way
/// film colourists warm the highlights and cool the shadows.
public struct ColorGrade: Hashable, Codable, Sendable {
    public var shadows: ColorWheel
    public var midtones: ColorWheel
    public var highlights: ColorWheel
    /// −1…1: moves the split between shadows and highlights.
    public var balance: Double

    public init(shadows: ColorWheel = ColorWheel(), midtones: ColorWheel = ColorWheel(), highlights: ColorWheel = ColorWheel(), balance: Double = 0) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.balance = balance.clamped(to: -1...1)
    }

    public static let neutral = ColorGrade()

    public var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }

    public enum Range: String, CaseIterable, Codable, Sendable, Identifiable {
        case shadows, midtones, highlights
        public var id: String { rawValue }
    }

    public subscript(range: Range) -> ColorWheel {
        get {
            switch range {
            case .shadows: return shadows
            case .midtones: return midtones
            case .highlights: return highlights
            }
        }
        set {
            switch range {
            case .shadows: shadows = newValue
            case .midtones: midtones = newValue
            case .highlights: highlights = newValue
            }
        }
    }

    /// The classic cinematic grade: teal shadows, warm highlights.
    public static let tealAndOrange = ColorGrade(shadows: ColorWheel(hue: 195, amount: 0.45), midtones: ColorWheel(), highlights: ColorWheel(hue: 32, amount: 0.4), balance: 0)
}

/// Pure colour maths for the mixer and the grade, and the 3D LUT that
/// carries both to the GPU.
public enum ColorEngine {
    public static func apply(mixer: ColorMixer?, grade: ColorGrade?, to rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        var color = rgb
        if let mixer, !mixer.isNeutral { color = applyMixer(mixer, to: color) }
        if let grade, !grade.isNeutral { color = applyGrade(grade, to: color) }
        return color
    }

    static func applyMixer(_ mixer: ColorMixer, to rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        var (h, s, l) = hsl(fromRGB: rgb)
        guard s > 0.001 else { return rgb }
        // Greys are left alone; the effect grows with how colourful the pixel is.
        let chroma = smoothstep(0.02, 0.3, s * (1 - abs(2 * l - 1)) * 2)
        var hueShift = 0.0, saturationFactor = 0.0, luminanceShift = 0.0
        for (band, weight) in ColorMixer.weights(forHue: h) {
            hueShift += weight * mixer.hue[band]
            saturationFactor += weight * mixer.saturation[band]
            luminanceShift += weight * mixer.luminance[band]
        }
        h += hueShift * 30 * chroma
        s = (s * (1 + saturationFactor * chroma)).clamped(to: 0...1)
        let delta = luminanceShift * 0.3 * chroma
        l = (l + delta * (delta > 0 ? (1 - l) : l) * 1.6).clamped(to: 0...1)
        return Self.rgb(fromHSL: (h, s, l))
    }

    static func applyGrade(_ grade: ColorGrade, to rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let luma = (0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2).clamped(to: 0...1)
        // The balance bends the tonal split: positive gives the highlights more of the range.
        let y = pow(luma, pow(2, grade.balance))
        let shadowWeight = (1 - y) * (1 - y)
        let highlightWeight = y * y
        let midWeight = max(0, 1 - shadowWeight - highlightWeight)
        var result = rgb
        for (wheel, weight) in [(grade.shadows, shadowWeight), (grade.midtones, midWeight), (grade.highlights, highlightWeight)] where !wheel.isNeutral && weight > 0 {
            let tint = Self.rgb(fromHSL: (wheel.hue, 1, 0.5))
            let tintLuma = 0.2126 * tint.0 + 0.7152 * tint.1 + 0.0722 * tint.2
            let strength = wheel.amount * 0.3 * weight
            result.0 += (tint.0 - tintLuma) * strength
            result.1 += (tint.1 - tintLuma) * strength
            result.2 += (tint.2 - tintLuma) * strength
            let lift = wheel.luminance * 0.25 * weight
            result.0 += lift
            result.1 += lift
            result.2 += lift
        }
        return (result.0.clamped(to: 0...1), result.1.clamped(to: 0...1), result.2.clamped(to: 0...1))
    }

    /// A `dimension`³ RGBA cube (red fastest) for Core Image's colour cube filters.
    public static func cube(mixer: ColorMixer?, grade: ColorGrade?, dimension: Int = 33) -> [Float] {
        let n = max(2, dimension)
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = apply(mixer: mixer, grade: grade, to: (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)))
                    data[offset] = Float(out.0)
                    data[offset + 1] = Float(out.1)
                    data[offset + 2] = Float(out.2)
                    data[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return data
    }

    // MARK: HSL

    public static func hsl(fromRGB rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let (r, g, b) = rgb
        let maximum = max(r, g, b), minimum = min(r, g, b)
        let l = (maximum + minimum) / 2
        guard maximum - minimum > 1e-9 else { return (0, 0, l) }
        let d = maximum - minimum
        let s = l > 0.5 ? d / (2 - maximum - minimum) : d / (maximum + minimum)
        var h: Double
        if maximum == r { h = (g - b) / d + (g < b ? 6 : 0) } else if maximum == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    public static func rgb(fromHSL hsl: (Double, Double, Double)) -> (Double, Double, Double) {
        let h = (hsl.0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = hsl.1, l = hsl.2
        guard s > 1e-9 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}
