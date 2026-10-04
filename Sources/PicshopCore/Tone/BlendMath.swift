import Foundation

/// Per-pixel reference formulas for the 27 blend modes, on gamma-encoded RGB in
/// 0…1: the W3C Compositing and Blending formulas (separable and non-separable
/// modes), plus Photoshop's linear burn and dodge, vivid, linear and pin light,
/// hard mix, subtract, divide, darker and lighter colour, and dissolve.
/// Imaging's BlendModes is tested against these.
public enum BlendMath {
    public struct RGB: Hashable, Sendable, CustomStringConvertible {
        public var r: Double, g: Double, b: Double

        public init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// From 8-bit values.
        public init(bytes r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.init(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        }

        public var description: String { String(format: "(%.4f, %.4f, %.4f)", r, g, b) }

        /// Sum of the channels: what darker and lighter colour compare.
        public var sum: Double { r + g + b }

        func map(_ other: RGB, _ f: (Double, Double) -> Double) -> RGB {
            RGB(f(r, other.r), f(g, other.g), f(b, other.b))
        }

        var clampedToUnit: RGB { RGB(r.clamped(to: 0...1), g.clamped(to: 0...1), b.clamped(to: 0...1)) }
    }

    /// B(Cb, Cs): the blended colour of an opaque `source` over an opaque `backdrop`.
    /// Dissolve returns the source (which pixels it takes is `dissolveTakesSource`).
    public static func blend(_ mode: BlendMode, backdrop cb: RGB, source cs: RGB) -> RGB {
        switch mode {
        case .normal, .dissolve: return cs
        case .multiply: return cb.map(cs) { $0 * $1 }
        case .screen: return cb.map(cs, screen)
        case .overlay: return cb.map(cs) { b, s in hardLight(s: b, b: s) }
        case .softLight: return cb.map(cs) { b, s in softLight(b: b, s: s) }
        case .hardLight: return cb.map(cs) { b, s in hardLight(s: s, b: b) }
        case .darken: return cb.map(cs) { min($0, $1) }
        case .lighten: return cb.map(cs) { max($0, $1) }
        case .difference: return cb.map(cs) { abs($0 - $1) }
        case .exclusion: return cb.map(cs) { $0 + $1 - 2 * $0 * $1 }
        case .colorDodge: return cb.map(cs, colorDodge)
        case .colorBurn: return cb.map(cs, colorBurn)
        case .linearBurn: return cb.map(cs) { max(0, $0 + $1 - 1) }
        case .linearDodge: return cb.map(cs) { min(1, $0 + $1) }
        case .linearLight: return cb.map(cs) { b, s in (b + 2 * s - 1).clamped(to: 0...1) }
        case .vividLight:
            return cb.map(cs) { b, s in s <= 0.5 ? colorBurn(b, 2 * s) : colorDodge(b, 2 * (s - 0.5)) }
        case .pinLight:
            return cb.map(cs) { b, s in s <= 0.5 ? min(b, 2 * s) : max(b, 2 * (s - 0.5)) }
        case .hardMix: return cb.map(cs) { b, s in b + s >= 1 ? 1 : 0 }
        case .subtract: return cb.map(cs) { max(0, $0 - $1) }
        case .divide: return cb.map(cs) { b, s in s <= 0 ? (b <= 0 ? 0 : 1) : min(1, b / s) }
        case .darkerColor: return cs.sum < cb.sum ? cs : cb
        case .lighterColor: return cs.sum > cb.sum ? cs : cb
        case .hue: return setLum(setSat(cs, sat(cb)), lum(cb))
        case .saturation: return setLum(setSat(cb, sat(cs)), lum(cb))
        case .color: return setLum(cs, lum(cb))
        case .luminosity: return setLum(cb, lum(cs))
        }
    }

    /// A source with coverage `alpha` (opacity × its own alpha) over an opaque backdrop:
    /// (1 − α)·Cb + α·B(Cb, Cs). Dissolve takes all or nothing per pixel instead (see
    /// `dissolveTakesSource`); here it mixes like Normal.
    public static func composite(_ mode: BlendMode, backdrop: RGB, source: RGB, alpha: Double) -> RGB {
        let a = alpha.clamped(to: 0...1)
        let blended = blend(mode, backdrop: backdrop, source: source)
        return backdrop.map(blended) { b, x in (1 - a) * b + a * x }
    }

    /// W3C Compositing Level 1, source-over with the mode's mix (W3, D6), over a backdrop of any alpha:
    /// co = cs·αs·(1 − αb) + cb·αb·(1 − αs) + αs·αb·B(cb, cs), αo = αs + αb·(1 − αs). Returns the straight colour
    /// (co ÷ αo; black where αo = 0) and αo. With αb = 1 it equals `composite(_:backdrop:source:alpha:)` within 1e-9.
    public static func compositeRGBA(_ mode: BlendMode, backdrop: RGB, backdropAlpha: Double, source: RGB, sourceAlpha: Double) -> (rgb: RGB, alpha: Double) {
        let ab = backdropAlpha.clamped(to: 0...1), as_ = sourceAlpha.clamped(to: 0...1)
        let alpha = as_ + ab * (1 - as_)
        guard alpha > 0 else { return (RGB(0, 0, 0), 0) }
        let mixed = blend(mode, backdrop: backdrop, source: source)
        func channel(_ cb: Double, _ cs: Double, _ b: Double) -> Double {
            (cs * as_ * (1 - ab) + cb * ab * (1 - as_) + as_ * ab * b) / alpha
        }
        return (RGB(channel(backdrop.r, source.r, mixed.r), channel(backdrop.g, source.g, mixed.g), channel(backdrop.b, source.b, mixed.b)), alpha)
    }

    /// Dissolve: a pixel shows the source when its random value (0…1) is below the source's coverage.
    public static func dissolveTakesSource(alpha: Double, noise: Double) -> Bool {
        noise < alpha
    }

    // MARK: Separable helpers (b: backdrop, s: source)

    static func screen(_ b: Double, _ s: Double) -> Double { b + s - b * s }

    static func hardLight(s: Double, b: Double) -> Double {
        s <= 0.5 ? b * 2 * s : screen(b, 2 * s - 1)
    }

    static func softLight(b: Double, s: Double) -> Double {
        if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
        let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
        return b + (2 * s - 1) * (d - b)
    }

    static func colorDodge(_ b: Double, _ s: Double) -> Double {
        if b <= 0 { return 0 }
        if s >= 1 { return 1 }
        return min(1, b / (1 - s))
    }

    static func colorBurn(_ b: Double, _ s: Double) -> Double {
        if b >= 1 { return 1 }
        if s <= 0 { return 0 }
        return 1 - min(1, (1 - b) / s)
    }

    // MARK: Non-separable helpers (W3C)

    static func lum(_ c: RGB) -> Double { 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }

    static func clipColor(_ c: RGB) -> RGB {
        let l = lum(c)
        let n = min(c.r, c.g, c.b), x = max(c.r, c.g, c.b)
        var result = c
        if n < 0 {
            result = RGB(l + (result.r - l) * l / (l - n), l + (result.g - l) * l / (l - n), l + (result.b - l) * l / (l - n))
        }
        if x > 1 {
            result = RGB(l + (result.r - l) * (1 - l) / (x - l), l + (result.g - l) * (1 - l) / (x - l), l + (result.b - l) * (1 - l) / (x - l))
        }
        return result.clampedToUnit
    }

    static func setLum(_ c: RGB, _ l: Double) -> RGB {
        let d = l - lum(c)
        return clipColor(RGB(c.r + d, c.g + d, c.b + d))
    }

    static func sat(_ c: RGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

    static func setSat(_ c: RGB, _ s: Double) -> RGB {
        let values = [c.r, c.g, c.b]
        let order = values.indices.sorted { values[$0] < values[$1] }
        let minIndex = order[0], midIndex = order[1], maxIndex = order[2]
        var out = [0.0, 0.0, 0.0]
        let span = values[maxIndex] - values[minIndex]
        if span > 0 {
            out[midIndex] = (values[midIndex] - values[minIndex]) * s / span
            out[maxIndex] = s
        }
        out[minIndex] = 0
        return RGB(out[0], out[1], out[2])
    }
}

public extension BlendMode {
    /// The blend menu's sections, in Photoshop's order.
    enum Group: String, Sendable, CaseIterable, Identifiable {
        case normal, darken, lighten, contrast, inversion, component

        public var id: String { rawValue }

        /// The modes of the section, in menu order.
        public var modes: [BlendMode] {
            switch self {
            case .normal: return [.normal, .dissolve]
            case .darken: return [.darken, .multiply, .colorBurn, .linearBurn, .darkerColor]
            case .lighten: return [.lighten, .screen, .colorDodge, .linearDodge, .lighterColor]
            case .contrast: return [.overlay, .softLight, .hardLight, .vividLight, .linearLight, .pinLight, .hardMix]
            case .inversion: return [.difference, .exclusion, .subtract, .divide]
            case .component: return [.hue, .saturation, .color, .luminosity]
            }
        }
    }

    var group: Group {
        Group.allCases.first { $0.modes.contains(self) } ?? .normal
    }
}
