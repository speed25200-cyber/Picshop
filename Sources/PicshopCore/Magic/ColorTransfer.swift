import Foundation

/// Mean and spread of an image's colours in CIE L*a*b*, the statistics colour
/// transfer works on (Reinhard et al., 2001).
public struct ColorStatistics: Hashable, Codable, Sendable {
    public var mean: [Double]
    public var deviation: [Double]

    public init(mean: [Double], deviation: [Double]) {
        self.mean = mean.count == 3 ? mean : [50, 0, 0]
        self.deviation = deviation.count == 3 ? deviation : [20, 10, 10]
    }

    /// Statistics of 8-bit sRGB pixels (RGBA or RGB, `stride` bytes per pixel).
    /// Near-black and clipped pixels are ignored: they carry no colour.
    public static func measure(rgba bytes: [UInt8], stride: Int = 4) -> ColorStatistics {
        var sum = [0.0, 0.0, 0.0]
        var squares = [0.0, 0.0, 0.0]
        var count = 0.0
        var index = 0
        while index + 2 < bytes.count {
            let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
            index += stride
            let maximum = max(r, g, b), minimum = min(r, g, b)
            if maximum < 0.02 || minimum > 0.98 { continue }
            let lab = ColorSpaceMath.lab(fromSRGB: (r, g, b))
            for channel in 0..<3 {
                sum[channel] += lab[channel]
                squares[channel] += lab[channel] * lab[channel]
            }
            count += 1
        }
        guard count > 0 else { return ColorStatistics(mean: [50, 0, 0], deviation: [20, 10, 10]) }
        let mean = sum.map { $0 / count }
        let deviation = (0..<3).map { max(0.5, (squares[$0] / count - mean[$0] * mean[$0]).squareRoot()) }
        return ColorStatistics(mean: mean, deviation: deviation)
    }
}

/// "Make this look like that": the colour mood of a reference applied to a
/// photo or clip. Stored as the two statistics, so it stays exact at any size
/// and re-renders as a 3D LUT on the GPU.
public struct ColorMatch: Hashable, Codable, Sendable {
    public var source: ColorStatistics
    public var reference: ColorStatistics
    /// 0 = untouched, 1 = full transfer.
    public var strength: Double
    /// Also match brightness and contrast (off = colour only).
    public var matchesLuminance: Bool

    public init(source: ColorStatistics, reference: ColorStatistics, strength: Double = 0.8, matchesLuminance: Bool = true) {
        self.source = source
        self.reference = reference
        self.strength = strength.clamped(to: 0...1)
        self.matchesLuminance = matchesLuminance
    }

    /// Transfers one sRGB colour.
    public func transfer(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        var lab = ColorSpaceMath.lab(fromSRGB: rgb)
        let original = lab
        for channel in 0..<3 {
            if channel == 0 && !matchesLuminance { continue }
            // Ratios are bounded so a flat reference cannot crush or explode the image.
            let ratio = (reference.deviation[channel] / max(0.5, source.deviation[channel])).clamped(to: 0.5...2.0)
            lab[channel] = (lab[channel] - source.mean[channel]) * ratio + reference.mean[channel]
        }
        let t = strength
        let mixed = [original[0] + (lab[0] - original[0]) * t, original[1] + (lab[1] - original[1]) * t, original[2] + (lab[2] - original[2]) * t]
        return ColorSpaceMath.sRGB(fromLab: mixed)
    }

    /// A `dimension`³ RGBA float cube (red fastest) for Core Image's colour cube filters.
    public func cube(dimension: Int = 32) -> [Float] {
        let n = max(2, dimension)
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let input = (Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1))
                    let output = transfer(input)
                    data[offset] = Float(output.0)
                    data[offset + 1] = Float(output.1)
                    data[offset + 2] = Float(output.2)
                    data[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return data
    }
}

/// sRGB ↔ CIE L*a*b* (D65).
public enum ColorSpaceMath {
    static func linearize(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func gamma(_ value: Double) -> Double {
        let v = max(0, value)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    public static func lab(fromSRGB rgb: (Double, Double, Double)) -> [Double] {
        let r = linearize(rgb.0), g = linearize(rgb.1), b = linearize(rgb.2)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    public static func sRGB(fromLab lab: [Double]) -> (Double, Double, Double) {
        let fy = (lab[0] + 16) / 116
        let fx = fy + lab[1] / 500
        let fz = fy - lab[2] / 200
        func inverse(_ t: Double) -> Double {
            let cube = t * t * t
            return cube > 216.0 / 24389.0 ? cube : (116 * t - 16) / (24389.0 / 27.0)
        }
        let x = inverse(fx) * 0.95047
        let y = inverse(fy)
        let z = inverse(fz) * 1.08883
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (gamma(r).clamped(to: 0...1), gamma(g).clamped(to: 0...1), gamma(b).clamped(to: 0...1))
    }
}

/// A `.cube` look saved in the project, and how strongly it is applied.
public struct LUTReference: Hashable, Codable, Sendable {
    /// Path inside the project package (`media/lut-….cube`).
    public var relativePath: String
    public var title: String
    /// 0…1, blended over the ungraded picture.
    public var intensity: Double

    public init(relativePath: String, title: String, intensity: Double = 1) {
        self.relativePath = relativePath
        self.title = title
        self.intensity = intensity.clamped(to: 0...1)
    }
}

/// A 3D look-up table read from an Adobe/Resolve `.cube` file.
public struct CubeLUT: Hashable, Sendable {
    public var title: String
    public var dimension: Int
    /// RGBA floats, red fastest — Core Image's colour cube layout.
    public var data: [Float]

    public enum ParseError: Error, Equatable {
        case missingSize
        case unsupported(String)
        case wrongEntryCount(expected: Int, found: Int)
    }

    /// Parses the text of a `.cube` file (3D tables; 1D tables are rejected).
    public static func parse(_ text: String, fallbackTitle: String = "LUT") throws -> CubeLUT {
        var title = fallbackTitle
        var dimension = 0
        var domainMin = [0.0, 0.0, 0.0]
        var domainMax = [1.0, 1.0, 1.0]
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                dimension = Int(parts.dropFirst().first ?? "") ?? 0
            case "LUT_1D_SIZE":
                throw ParseError.unsupported("1D LUT")
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap(Double.init)
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap(Double.init)
            default:
                let numbers = parts.compactMap(Double.init)
                if numbers.count == 3 {
                    for channel in 0..<3 {
                        let low = channel < domainMin.count ? domainMin[channel] : 0
                        let high = channel < domainMax.count ? domainMax[channel] : 1
                        values.append(Float(((numbers[channel] - low) / max(1e-9, high - low)).clamped(to: 0...1)))
                    }
                    values.append(1)
                }
            }
        }
        guard dimension >= 2 else { throw ParseError.missingSize }
        let expected = dimension * dimension * dimension * 4
        guard values.count == expected else { throw ParseError.wrongEntryCount(expected: expected / 4, found: values.count / 4) }
        return CubeLUT(title: title, dimension: dimension, data: values)
    }
}
