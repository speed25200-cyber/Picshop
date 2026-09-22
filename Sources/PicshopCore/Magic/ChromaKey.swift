import Foundation

/// Green-screen keying: pixels near the key colour become transparent, with
/// a soft edge and spill suppression so the subject keeps a clean outline.
/// Rendered as a 3D LUT that writes alpha, like every other colour tool.
public struct ChromaKey: Hashable, Codable, Sendable {
    /// Key hue in degrees (120 = green, 225 = blue).
    public var hue: Double
    /// How far around the key hue counts as background, in degrees.
    public var tolerance: Double
    /// Width of the soft edge, in degrees.
    public var softness: Double
    /// 0…1: how much of the key colour reflected on the subject is removed.
    public var spill: Double

    public init(hue: Double = 120, tolerance: Double = 38, softness: Double = 18, spill: Double = 0.6) {
        self.hue = hue
        self.tolerance = max(4, min(90, tolerance))
        self.softness = max(1, min(60, softness))
        self.spill = spill.clamped(to: 0...1)
    }

    public static let green = ChromaKey()
    public static let blue = ChromaKey(hue: 225)

    /// Straight (unpremultiplied) colour and alpha for one sRGB pixel.
    public func key(_ rgb: (Double, Double, Double)) -> (r: Double, g: Double, b: Double, a: Double) {
        let (h, s, l) = ColorEngine.hsl(fromRGB: rgb)
        // Only saturated, not-too-dark, not-too-bright pixels can be background.
        let chroma = ColorEngine.smoothstep(0.12, 0.3, s) * ColorEngine.smoothstep(0.06, 0.18, l) * (1 - ColorEngine.smoothstep(0.88, 0.97, l))
        var distance = abs(h - hue).truncatingRemainder(dividingBy: 360)
        if distance > 180 { distance = 360 - distance }
        let inside = 1 - ColorEngine.smoothstep(tolerance, tolerance + softness, distance)
        let alpha = 1 - inside * chroma
        var (r, g, b) = rgb
        // Spill: pull the key channel down towards the other two near the key hue.
        if spill > 0, distance < tolerance + softness * 2 {
            let amount = spill * (1 - ColorEngine.smoothstep(tolerance, tolerance + softness * 2, distance))
            if abs(hue - 120) <= 60 {
                g = g - (g - min(g, (r + b) / 2)) * amount
            } else if abs(hue - 225) <= 60 {
                b = b - (b - min(b, (r + g) / 2)) * amount
            }
        }
        return (r, g, b, alpha)
    }

    /// A `dimension`³ premultiplied RGBA cube (red fastest) for Core Image.
    public func cube(dimension: Int = 32) -> [Float] {
        let n = max(2, dimension)
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var offset = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = key((Double(r) / Double(n - 1), Double(g) / Double(n - 1), Double(b) / Double(n - 1)))
                    data[offset] = Float(out.r * out.a)
                    data[offset + 1] = Float(out.g * out.a)
                    data[offset + 2] = Float(out.b * out.a)
                    data[offset + 3] = Float(out.a)
                    offset += 4
                }
            }
        }
        return data
    }
}
