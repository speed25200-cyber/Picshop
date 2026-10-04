import Foundation

/// The colour and tone maths shared by the CPU reference (MaskRaster), the GPU cubes and tables (M2) and the
/// pixel postconditions: Lab from gamma sRGB, Rec.709 luma, smoothstep, trapezoids and colour-range scoring.
///
/// One function per quantity, used by every path: the GPU colour cube is filled from `colorRange`, the depth
/// curve from `trapezoid`, and PixelStats measures with `lab`, so a sampled colour, a colour-range mask and a
/// pixel check all agree by construction (D5).
public enum MaskMath {
    // MARK: Colour

    /// Gamma sRGB 0…1, D65: sRGB → linear (IEC 61966-2-1) → XYZ → CIE L*a*b* with the CIE ε and κ.
    /// White is exactly (100, 0, 0): the reference white is the matrix's own white.
    public static func lab(r: Double, g: Double, b: Double) -> LabColor {
        labFromLinear(linearize(r), linearize(g), linearize(b))
    }

    public static func lab(_ color: PSColor) -> LabColor {
        lab(r: color.red, g: color.green, b: color.blue)
    }

    /// Lab of three gamma sRGB bytes (a table lookup for the transfer curve): what the reference and PixelStats
    /// read per pixel.
    public static func lab(bytes r: UInt8, _ g: UInt8, _ b: UInt8) -> LabColor {
        let table = linearTable
        return labFromLinear(table[Int(r)], table[Int(g)], table[Int(b)])
    }

    /// The IEC 61966-2-1 transfer curve, gamma value → linear light.
    public static func linearize(_ value: Double) -> Double {
        let c = value.isFinite ? value.clamped(to: 0...1) : 0
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Chroma C*ab and hue h(ab) in degrees 0…360 (LCh of a Lab colour).
    public static func lch(_ lab: LabColor) -> (c: Double, h: Double) {
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        var hue = atan2(lab.b, lab.a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (chroma, hue)
    }

    /// CIE76 colour difference: the Euclidean distance in Lab.
    public static func deltaE(_ lhs: LabColor, _ rhs: LabColor) -> Double {
        let dl = lhs.l - rhs.l, da = lhs.a - rhs.a, db = lhs.b - rhs.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// 0.2126, 0.7152, 0.0722 on gamma values.
    public static func luma(r: Double, g: Double, b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: Ramps

    /// 0 at and below `edge0`, 1 at and above `edge1`, Hermite between. Equal edges give a step at the edge;
    /// reversed edges give the falling ramp (GLSL semantics).
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard !x.isNaN else { return 0 }
        guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// 1 on [low, high] (swapped when reversed), falling to 0 over `feather` on each side by smoothstep; feather 0
    /// is a hard range. Luminance and depth ranges, and the GPU depth table.
    public static func trapezoid(_ x: Double, low: Double, high: Double, feather: Double) -> Double {
        let lower = min(low, high), upper = max(low, high)
        let soft = feather.isFinite ? max(0, feather) : 0
        guard soft > 0 else { return x >= lower && x <= upper ? 1 : 0 }
        let rising = smoothstep(lower - soft, lower, x)
        let falling = 1 - smoothstep(upper, upper + soft, x)
        return min(rising, falling)
    }

    // MARK: Colour range

    /// The ΔE76 radius below which a sample selects fully: 4 + 36 × fuzziness (fuzziness 0…1).
    public static func colorRangeInner(fuzziness: Double) -> Double {
        4 + 36 * fuzziness.clamped(to: 0...1)
    }

    /// 1 − smoothstep(inner, inner × 1.6, ΔE76), inner = 4 + 36 × fuzziness; the max over samples and the preset.
    public static func colorRange(_ lab: LabColor, _ spec: ColorRangeSpec) -> Double {
        colorRange(lab, lch: nil, spec)
    }

    /// `colorRange(_:_:)` with the colour's chroma and hue already known (a cube's precomputed grid): same value.
    public static func colorRange(_ lab: LabColor, chroma: Double, hue: Double, _ spec: ColorRangeSpec) -> Double {
        colorRange(lab, lch: (chroma, hue), spec)
    }

    private static func colorRange(_ lab: LabColor, lch known: (c: Double, h: Double)?, _ spec: ColorRangeSpec) -> Double {
        var best = 0.0
        if !spec.samples.isEmpty {
            let inner = colorRangeInner(fuzziness: spec.fuzziness)
            let outer = inner * 1.6
            for sample in spec.samples.prefix(8) {
                best = max(best, 1 - smoothstep(inner, outer, deltaE(lab, sample)))
                if best >= 1 { return 1 }
            }
        }
        if let preset = spec.preset {
            let (chroma, hue) = known ?? lch(lab)
            best = max(best, presetValue(lab, chroma: chroma, hue: hue, preset, fuzziness: spec.fuzziness))
        }
        return best
    }

    /// The colour range of a gamma sRGB colour (what the GPU cube holds at that grid point).
    public static func colorRange(r: Double, g: Double, b: Double, _ spec: ColorRangeSpec) -> Double {
        colorRange(lab(r: r, g: g, b: b), spec)
    }

    /// The luminance range of a gamma sRGB colour: its Rec.709 luma through the spec's trapezoid.
    public static func luminanceRange(r: Double, g: Double, b: Double, _ spec: LuminanceRangeSpec) -> Double {
        trapezoid(luma(r: r, g: g, b: b), low: spec.low, high: spec.high, feather: spec.feather)
    }

    /// Hue sectors in LCh(ab): centre and half-width in degrees, at the default fuzziness 0.4.
    ///
    /// Measured on sRGB: in Lab the primaries are not where HSV puts them (#FF0000 sits at 40°, #FF8000 at 60°,
    /// #FFFF00 at 103°, #00FF00 at 136°, #00FFFF at 196°, #0000FF at 306°, #FF00FF at 328°), so the sectors follow
    /// the Lab hues: reds 3°–45° (crimson 25°, red 40°), oranges 46°–74°, yellows 77°–113°, greens 114°–170°,
    /// cyans 173°–221°, blues 224°–312° (dodger blue 279°, pure blue 306°), magentas 316°–354°. Skin tones span
    /// 25°–80° (ColorChecker skins sit near 50°, pale and peach skins near 78°).
    public static func presetSector(_ preset: ColorRangeSpec.Preset) -> (center: Double, halfWidth: Double) {
        switch preset {
        case .reds: return (24, 21)
        case .oranges: return (60, 14)
        case .yellows: return (95, 18)
        case .greens: return (142, 28)
        case .cyans: return (197, 24)
        case .blues: return (268, 44)
        case .magentas: return (335, 19)
        case .skinTones: return (52.5, 27.5)
        }
    }

    /// A preset's membership of a colour, 0…1.
    /// - Hue families: inside the sector's half-width, falling to 0 over the next 10° (a smoothstep); chroma
    ///   gated around C* 12 (smoothstep 9…15), so greys belong to no family.
    /// - Skin tones: the hue sector, with C* 10–45 and L* 25–92, each with a soft edge of 5 units.
    /// The tolerance widens or narrows the sector: half-width × (0.6 + fuzziness), so the default 0.4 gives
    /// exactly the sectors above and the « Tolérance » slider still means something with a preset.
    public static func presetValue(_ lab: LabColor, _ preset: ColorRangeSpec.Preset, fuzziness: Double = 0.4) -> Double {
        let (chroma, hue) = lch(lab)
        return presetValue(lab, chroma: chroma, hue: hue, preset, fuzziness: fuzziness)
    }

    /// `presetValue(_:_:fuzziness:)` with the colour's chroma and hue already known: same value.
    public static func presetValue(_ lab: LabColor, chroma: Double, hue: Double, _ preset: ColorRangeSpec.Preset, fuzziness: Double = 0.4) -> Double {
        let sector = presetSector(preset)
        let half = sector.halfWidth * (0.6 + fuzziness.clamped(to: 0...1))
        var distance = abs(hue - sector.center).truncatingRemainder(dividingBy: 360)
        if distance > 180 { distance = 360 - distance }
        let hueValue = 1 - smoothstep(half, half + 10, distance)
        guard hueValue > 0 else { return 0 }
        if preset == .skinTones {
            let chromaValue = trapezoid(chroma, low: 10, high: 45, feather: 5)
            let lightness = trapezoid(lab.l, low: 25, high: 92, feather: 5)
            return hueValue * chromaValue * lightness
        }
        return hueValue * smoothstep(9, 15, chroma)
    }

    // MARK: GPU tables

    /// RGBA float32 cube data for CIColorCube with no colour space (R fastest), axes gamma sRGB 0…1 (D5: the input is
    /// converted to sRGB first), the value in R, G and B, alpha 1. Grid points sit at i / (n − 1). Empty outside
    /// 2…128.
    public static func cube(dimension: Int, _ value: (_ r: Double, _ g: Double, _ b: Double) -> Double) -> [Float] {
        guard dimension >= 2, dimension <= 128 else { return [] }
        let n = dimension
        let step = 1 / Double(n - 1)
        var data = [Float](repeating: 1, count: n * n * n * 4)
        data.withUnsafeMutableBufferPointer { buffer in
            var index = 0
            for blue in 0..<n {
                let b = Double(blue) * step
                for green in 0..<n {
                    let g = Double(green) * step
                    for red in 0..<n {
                        let raw = value(Double(red) * step, g, b)
                        let v = Float(raw.isNaN ? 0 : raw.clamped(to: 0...1))
                        buffer[index] = v
                        buffer[index + 1] = v
                        buffer[index + 2] = v
                        // Alpha stays 1.
                        index += 4
                    }
                }
            }
        }
        return data
    }

    /// A cube's grid points as Lab, with their chroma and hue, in `cube(dimension:_:)`'s order (R fastest): the same
    /// colours that function scores, converted once per dimension.
    public struct LabGrid: Sendable {
        public let dimension: Int
        public let lab: [LabColor]
        public let chroma: [Double]
        public let hue: [Double]

        init(dimension n: Int) {
            dimension = n
            let step = 1 / Double(max(1, n - 1))
            var lab: [LabColor] = [], chroma: [Double] = [], hue: [Double] = []
            let count = n * n * n
            lab.reserveCapacity(count)
            chroma.reserveCapacity(count)
            hue.reserveCapacity(count)
            for blue in 0..<n {
                let b = Double(blue) * step
                for green in 0..<n {
                    let g = Double(green) * step
                    for red in 0..<n {
                        let color = MaskMath.lab(r: Double(red) * step, g: g, b: b)
                        let polar = MaskMath.lch(color)
                        lab.append(color)
                        chroma.append(polar.c)
                        hue.append(polar.h)
                    }
                }
            }
            self.lab = lab
            self.chroma = chroma
            self.hue = hue
        }
    }

    /// The grid of a dimension, converted on first use and kept (a 48³ grid is 110,592 sRGB → Lab conversions).
    public static func labGrid(dimension: Int) -> LabGrid {
        labGrids.grid(dimension)
    }

    /// A cube of a function of each grid point's Lab, chroma and hue: `cube(dimension:_:)`'s layout and values for a
    /// colour function, without converting the grid again (a « Tolérance » drag rebuilds a colour range every frame).
    public static func labCube(dimension: Int, _ value: (_ lab: LabColor, _ chroma: Double, _ hue: Double) -> Double) -> [Float] {
        guard dimension >= 2, dimension <= 128 else { return [] }
        let grid = labGrid(dimension: dimension)
        let count = dimension * dimension * dimension
        var data = [Float](repeating: 1, count: count * 4)
        data.withUnsafeMutableBufferPointer { buffer in
            for point in 0..<count {
                let raw = value(grid.lab[point], grid.chroma[point], grid.hue[point])
                let v = Float(raw.isNaN ? 0 : raw.clamped(to: 0...1))
                buffer[point * 4] = v
                buffer[point * 4 + 1] = v
                buffer[point * 4 + 2] = v
                // Alpha stays 1.
            }
        }
        return data
    }

    private final class LabGridCache: @unchecked Sendable {
        private let lock = NSLock()
        private var grids: [Int: LabGrid] = [:]

        func grid(_ dimension: Int) -> LabGrid {
            lock.lock()
            defer { lock.unlock() }
            if let grid = grids[dimension] { return grid }
            let grid = LabGrid(dimension: dimension)
            grids[dimension] = grid
            return grid
        }
    }

    private static let labGrids = LabGridCache()

    /// `count` samples of trapezoid(x) over 0…1 (x = i / (count − 1)) as RGB float triplets (3·count floats,
    /// R = G = B), CIColorCurves' curvesData layout. Empty outside 2…65536.
    public static func trapezoidTable(low: Double, high: Double, feather: Double, count: Int = 256) -> [Float] {
        guard count >= 2, count <= 65_536 else { return [] }
        var data = [Float](repeating: 0, count: 3 * count)
        for index in 0..<count {
            let v = Float(trapezoid(Double(index) / Double(count - 1), low: low, high: high, feather: feather))
            data[3 * index] = v
            data[3 * index + 1] = v
            data[3 * index + 2] = v
        }
        return data
    }

    // MARK: Internals

    /// sRGB byte → linear light, the 256 values of the transfer curve.
    static let linearTable: [Double] = (0..<256).map { linearize(Double($0) / 255) }

    // The sRGB (D65) to XYZ matrix; the reference white is its row sums, so white has a = b = 0 exactly.
    private static let x0 = 0.4124564, x1 = 0.3575761, x2 = 0.1804375
    private static let y0 = 0.2126729, y1 = 0.7151522, y2 = 0.0721750
    private static let z0 = 0.0193339, z1 = 0.1191920, z2 = 0.9503041
    private static let whiteX = x0 + x1 + x2
    private static let whiteY = y0 + y1 + y2
    private static let whiteZ = z0 + z1 + z2
    private static let epsilon = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    private static func labFromLinear(_ r: Double, _ g: Double, _ b: Double) -> LabColor {
        let fx = f((x0 * r + x1 * g + x2 * b) / whiteX)
        let fy = f((y0 * r + y1 * g + y2 * b) / whiteY)
        let fz = f((z0 * r + z1 * g + z2 * b) / whiteZ)
        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func f(_ t: Double) -> Double {
        t > epsilon ? cbrt(t) : (kappa * t + 16) / 116
    }
}
