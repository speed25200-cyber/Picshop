import XCTest
@testable import PicshopCore

/// MaskMath (§5 item 2): Lab, luma, smoothstep, trapezoids, colour-range scoring, presets, and the GPU cube and
/// table layouts the Imaging lane uploads as they are.
final class MaskMathTests: XCTestCase {
    private func lab(hex: String) -> LabColor {
        MaskMath.lab(PSColor(hex: hex)!)
    }

    // MARK: Lab

    func testLabOfWhiteGreyAndBlack() {
        let white = MaskMath.lab(r: 1, g: 1, b: 1)
        XCTAssertEqual(white.l, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)
        let grey = lab(hex: "#777777")
        XCTAssertEqual(grey.l, 50.0, accuracy: 0.3)
        XCTAssertEqual(grey.a, 0, accuracy: 0.01)
        XCTAssertEqual(grey.b, 0, accuracy: 0.01)
        let black = MaskMath.lab(r: 0, g: 0, b: 0)
        XCTAssertEqual(black.l, 0, accuracy: 1e-9)
    }

    func testLabOfThePrimariesMatchesTheCIEValues() {
        // Published sRGB D65 values (Bruce Lindbloom).
        let red = MaskMath.lab(r: 1, g: 0, b: 0)
        XCTAssertEqual(red.l, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.05)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.05)
        let green = MaskMath.lab(r: 0, g: 1, b: 0)
        XCTAssertEqual(green.l, 87.73, accuracy: 0.05)
        XCTAssertEqual(green.a, -86.18, accuracy: 0.05)
        XCTAssertEqual(green.b, 83.18, accuracy: 0.05)
        let blue = MaskMath.lab(r: 0, g: 0, b: 1)
        XCTAssertEqual(blue.l, 32.30, accuracy: 0.05)
        XCTAssertEqual(blue.a, 79.19, accuracy: 0.05)
        XCTAssertEqual(blue.b, -107.86, accuracy: 0.05)
    }

    func testTheByteTableMatchesTheCurve() {
        for value in stride(from: 0, through: 255, by: 17) {
            let byte = UInt8(value), other = UInt8(255 - value)
            let direct = MaskMath.lab(r: Double(byte) / 255, g: Double(other) / 255, b: 0.5 * Double(byte) / 255)
            let table = MaskMath.lab(bytes: byte, other, UInt8((0.5 * Double(byte)).rounded()))
            XCTAssertEqual(direct.l, table.l, accuracy: 0.3)
            XCTAssertEqual(direct.a, table.a, accuracy: 0.5)
            XCTAssertEqual(MaskMath.lab(bytes: byte, byte, byte).l, MaskMath.lab(r: Double(byte) / 255, g: Double(byte) / 255, b: Double(byte) / 255).l, accuracy: 1e-9)
        }
        // The transfer curve's two pieces meet.
        XCTAssertEqual(MaskMath.linearize(0.04045), 0.04045 / 12.92, accuracy: 1e-7)
        XCTAssertEqual(MaskMath.linearize(1), 1, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.linearize(-1), 0)
        XCTAssertEqual(MaskMath.linearize(.nan), 0)
    }

    func testLumaIsRec709OnGammaValues() {
        XCTAssertEqual(MaskMath.luma(r: 1, g: 1, b: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.luma(r: 1, g: 0, b: 0), 0.2126, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.luma(r: 0, g: 1, b: 0), 0.7152, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.luma(r: 0, g: 0, b: 1), 0.0722, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.luma(r: 0.5, g: 0.5, b: 0.5), 0.5, accuracy: 1e-12)
    }

    // MARK: Ramps

    func testSmoothstep() {
        XCTAssertEqual(MaskMath.smoothstep(0, 1, -1), 0)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, 0), 0)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, 0.25), 0.15625, accuracy: 1e-12)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, 1), 1)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, 7), 1)
        // Equal edges: a step. Reversed edges: the falling ramp.
        XCTAssertEqual(MaskMath.smoothstep(0.5, 0.5, 0.49), 0)
        XCTAssertEqual(MaskMath.smoothstep(0.5, 0.5, 0.5), 1)
        XCTAssertEqual(MaskMath.smoothstep(1, 0, 0.25), 1 - MaskMath.smoothstep(0, 1, 0.25), accuracy: 1e-12)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, .nan), 0)
        XCTAssertEqual(MaskMath.smoothstep(0, 1, .infinity), 1)
    }

    func testTrapezoid() {
        XCTAssertEqual(MaskMath.trapezoid(0.5, low: 0.33, high: 0.66, feather: 0.15), 1)
        XCTAssertEqual(MaskMath.trapezoid(0.33, low: 0.33, high: 0.66, feather: 0.15), 1)
        XCTAssertEqual(MaskMath.trapezoid(0.10, low: 0.33, high: 0.66, feather: 0.15), 0)
        XCTAssertEqual(MaskMath.trapezoid(0.255, low: 0.33, high: 0.66, feather: 0.15), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MaskMath.trapezoid(0.735, low: 0.33, high: 0.66, feather: 0.15), 0.5, accuracy: 1e-9)
        // Shadows from 0: black is fully inside.
        XCTAssertEqual(MaskMath.trapezoid(0, low: 0, high: 0.25, feather: 0.15), 1)
        // Feather 0 is a hard range; reversed bounds are the same range.
        XCTAssertEqual(MaskMath.trapezoid(0.2, low: 0.25, high: 0.5, feather: 0), 0)
        XCTAssertEqual(MaskMath.trapezoid(0.25, low: 0.25, high: 0.5, feather: 0), 1)
        XCTAssertEqual(MaskMath.trapezoid(0.3, low: 0.5, high: 0.25, feather: 0.1), MaskMath.trapezoid(0.3, low: 0.25, high: 0.5, feather: 0.1))
    }

    // MARK: Colour range

    func testASampleAgainstItselfIsOneAndFarAwayIsZero() {
        let sample = LabColor(l: 55, a: 30, b: -20)
        for fuzziness in [0.0, 0.2, 0.4, 0.8, 1.0] {
            let spec = ColorRangeSpec(samples: [sample], fuzziness: fuzziness)
            XCTAssertEqual(MaskMath.colorRange(sample, spec), 1)
            let inner = MaskMath.colorRangeInner(fuzziness: fuzziness)
            let outer = 1.6 * inner
            // ΔE = 2 × outer along L: 0.
            XCTAssertEqual(MaskMath.colorRange(LabColor(l: 55 + 2 * outer, a: 30, b: -20), spec), 0)
            // Inside the inner radius: 1. Midway between inner and outer: 0.5.
            XCTAssertEqual(MaskMath.colorRange(LabColor(l: 55 + 0.9 * inner, a: 30, b: -20), spec), 1)
            XCTAssertEqual(MaskMath.colorRange(LabColor(l: 55, a: 30 + (inner + outer) / 2, b: -20), spec), 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(MaskMath.colorRangeInner(fuzziness: 0), 4)
        XCTAssertEqual(MaskMath.colorRangeInner(fuzziness: 1), 40)
        // No sample and no preset selects nothing.
        XCTAssertEqual(MaskMath.colorRange(sample, ColorRangeSpec()), 0)
    }

    func testTheValueIsTheMaxOverSamplesAndPreset() {
        let near = LabColor(l: 50, a: 0, b: 0), far = LabColor(l: 90, a: 0, b: 0)
        let probe = LabColor(l: 52, a: 0, b: 0)
        XCTAssertEqual(MaskMath.colorRange(probe, ColorRangeSpec(samples: [far, near], fuzziness: 0)), 1)
        let red = MaskMath.lab(r: 1, g: 0, b: 0)
        let spec = ColorRangeSpec(samples: [far], fuzziness: 0.4, preset: .reds)
        XCTAssertEqual(MaskMath.colorRange(red, spec), 1)
        XCTAssertEqual(MaskMath.colorRange(r: 1, g: 0, b: 0, spec), 1)
    }

    func testFallsOffMonotonically() {
        let sample = LabColor(l: 60, a: 10, b: 10)
        let spec = ColorRangeSpec(samples: [sample], fuzziness: 0.3)
        var previous = 2.0
        for step in 0...60 {
            let value = MaskMath.colorRange(LabColor(l: 60, a: 10 + Double(step), b: 10), spec)
            XCTAssertLessThanOrEqual(value, previous)
            previous = value
        }
        XCTAssertEqual(previous, 0)
    }

    /// 24 named sRGB swatches, three per family: the expected family is the strongest hue preset (≥ 0.9), and
    /// skin swatches are skin tones. Greys belong to no family.
    func testPresetsOnReferenceSwatches() {
        let hueFamilies: [(ColorRangeSpec.Preset, [String])] = [
            (.reds, ["#FF0000", "#DC143C", "#E0115F"]),
            (.oranges, ["#FF7F00", "#FF8C00", "#CC5500"]),
            (.yellows, ["#FFFF00", "#FFD700", "#F4C430"]),
            (.greens, ["#00FF00", "#228B22", "#2E8B57"]),
            (.cyans, ["#00FFFF", "#00CED1", "#40E0D0"]),
            (.blues, ["#0000FF", "#1E90FF", "#4169E1"]),
            (.magentas, ["#FF00FF", "#BA55D3", "#8B008B"]),
        ]
        let hues = ColorRangeSpec.Preset.allCases.filter { $0 != .skinTones }
        for (family, swatches) in hueFamilies {
            for swatch in swatches {
                let color = lab(hex: swatch)
                let values = Dictionary(uniqueKeysWithValues: hues.map { ($0, MaskMath.presetValue(color, $0)) })
                let best = values.max { $0.value < $1.value }!.key
                XCTAssertEqual(best, family, "\(swatch): \(values)")
                XCTAssertGreaterThanOrEqual(values[family]!, 0.9, swatch)
            }
        }
        // ColorChecker dark and light skin, and a pale skin.
        for swatch in ["#735244", "#C29682", "#E8BEAC"] {
            XCTAssertGreaterThanOrEqual(MaskMath.presetValue(lab(hex: swatch), .skinTones), 0.9, swatch)
        }
        // Greys, white and black: no family. Saturated non-skin colours are not skin.
        for swatch in ["#808080", "#FFFFFF", "#000000", "#C0C0C0", "#333333"] {
            for preset in ColorRangeSpec.Preset.allCases {
                XCTAssertLessThan(MaskMath.presetValue(lab(hex: swatch), preset), 0.05, "\(swatch) \(preset)")
            }
        }
        for swatch in ["#0000FF", "#00FF00", "#FF00FF", "#00FFFF"] {
            XCTAssertEqual(MaskMath.presetValue(lab(hex: swatch), .skinTones), 0, swatch)
        }
    }

    func testTheToleranceWidensAPreset() {
        // A hue just past the reds' sector edge (24° + 21°): out at a low tolerance, in at a high one.
        let edge = LabColor(l: 50, a: 40 * cos(50 * .pi / 180), b: 40 * sin(50 * .pi / 180))
        XCTAssertLessThan(MaskMath.presetValue(edge, .reds, fuzziness: 0), 0.05)
        XCTAssertEqual(MaskMath.presetValue(edge, .reds, fuzziness: 1), 1)
        // The default tolerance is exactly the documented sector.
        let inside = LabColor(l: 50, a: 40 * cos(44 * .pi / 180), b: 40 * sin(44 * .pi / 180))
        XCTAssertEqual(MaskMath.presetValue(inside, .reds), 1)
    }

    // MARK: GPU layouts

    func testTheCubeLayout() {
        let cube = MaskMath.cube(dimension: 4) { r, g, b in r * 0.5 + g * 0.25 + b * 0.125 }
        XCTAssertEqual(cube.count, 4 * 4 * 4 * 4)
        func entry(_ r: Int, _ g: Int, _ b: Int) -> ArraySlice<Float> {
            let index = ((b * 4 + g) * 4 + r) * 4
            return cube[index..<(index + 4)]
        }
        // R fastest, values at i / (n − 1), R = G = B, alpha 1.
        XCTAssertEqual(Array(entry(1, 0, 0)), [Float(0.5 / 3), Float(0.5 / 3), Float(0.5 / 3), 1])
        XCTAssertEqual(Array(entry(0, 3, 0)), [0.25, 0.25, 0.25, 1])
        XCTAssertEqual(Array(entry(3, 3, 3)), [0.875, 0.875, 0.875, 1])
        // Clamped values, and no cube outside 2…128.
        XCTAssertEqual(MaskMath.cube(dimension: 2) { _, _, _ in 7 }.first, 1)
        XCTAssertEqual(MaskMath.cube(dimension: 2) { _, _, _ in .nan }.first, 0)
        XCTAssertTrue(MaskMath.cube(dimension: 1) { _, _, _ in 1 }.isEmpty)
    }

    /// The 48³ cube, read with trilinear interpolation as CIColorCube reads it, against direct evaluation at 1,000
    /// random colours: a mean error under 0.005 and 95 % of colours within 0.025. A cube cell can span several ΔE
    /// where Lab moves fast (saturated blues, near black), so a few colours on a selection's soft edge differ by
    /// more (bounded here at 0.2 for samples; a preset's hue edge near the grey axis turns within one cell, so only
    /// its mean and 95th percentile are bounded): the GPU parity tolerance for colour ranges (mean 3/255) is set
    /// by this.
    func testTheColorRangeCubeMatchesDirectEvaluation() {
        let n = 48
        let specs = [
            ColorRangeSpec(samples: [LabColor(l: 62, a: 28, b: 40), LabColor(l: 40, a: -20, b: 25)], fuzziness: 0.4),
            ColorRangeSpec(samples: [LabColor(l: 70, a: -5, b: -30)], fuzziness: 0.7),
            ColorRangeSpec(preset: .skinTones),
        ]
        var generator = MaskTestRandom(seed: 0xC0FFEE)
        for spec in specs {
            let cube = MaskMath.cube(dimension: n) { r, g, b in MaskMath.colorRange(r: r, g: g, b: b, spec) }
            var errors: [Double] = []
            for _ in 0..<1000 {
                let r = Double.random(in: 0...1, using: &generator)
                let g = Double.random(in: 0...1, using: &generator)
                let b = Double.random(in: 0...1, using: &generator)
                let interpolated = Self.trilinear(cube, n: n, r: r, g: g, b: b)
                errors.append(abs(interpolated - MaskMath.colorRange(r: r, g: g, b: b, spec)))
            }
            errors.sort()
            XCTAssertLessThanOrEqual(errors.reduce(0, +) / Double(errors.count), 0.005, "\(spec)")
            XCTAssertLessThanOrEqual(errors[950], 0.025, "\(spec)")
            if spec.preset == nil { XCTAssertLessThanOrEqual(errors[999], 0.2, "\(spec)") }
        }
    }

    /// The precomputed grid gives the colour-range cube bit for bit: the renderer's faster build changes no value.
    func testTheLabGridCubeIsTheSameCube() {
        let specs = [
            ColorRangeSpec(samples: [LabColor(l: 62, a: 28, b: 40), LabColor(l: 40, a: -20, b: 25)], fuzziness: 0.4),
            ColorRangeSpec(samples: [LabColor(l: 70, a: -5, b: -30)], fuzziness: 0.7, preset: .blues),
            ColorRangeSpec(preset: .skinTones),
        ]
        for n in [2, 17] {
            for spec in specs {
                let direct = MaskMath.cube(dimension: n) { r, g, b in MaskMath.colorRange(r: r, g: g, b: b, spec) }
                let fromGrid = MaskMath.labCube(dimension: n) { lab, chroma, hue in MaskMath.colorRange(lab, chroma: chroma, hue: hue, spec) }
                XCTAssertEqual(direct, fromGrid, "\(n): \(spec)")
            }
        }
        XCTAssertEqual(MaskMath.labGrid(dimension: 17).lab.count, 17 * 17 * 17)
        XCTAssertEqual(MaskMath.labCube(dimension: 1) { _, _, _ in 1 }, [])
    }

    func testTheTrapezoidTable() {
        let table = MaskMath.trapezoidTable(low: 0.6, high: 1, feather: 0.15)
        XCTAssertEqual(table.count, 768)
        for index in 0..<256 {
            XCTAssertEqual(table[3 * index], table[3 * index + 1])
            XCTAssertEqual(table[3 * index], table[3 * index + 2])
            let x = Double(index) / 255
            XCTAssertEqual(Double(table[3 * index]), MaskMath.trapezoid(x, low: 0.6, high: 1, feather: 0.15), accuracy: 1e-6)
        }
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[765], 1)
        XCTAssertEqual(MaskMath.trapezoidTable(low: 0, high: 0.35, feather: 0.15, count: 2), [1, 1, 1, 0, 0, 0])
        XCTAssertTrue(MaskMath.trapezoidTable(low: 0, high: 1, feather: 0, count: 1).isEmpty)
    }

    // MARK: Helpers

    static func trilinear(_ cube: [Float], n: Int, r: Double, g: Double, b: Double) -> Double {
        func value(_ ri: Int, _ gi: Int, _ bi: Int) -> Double { Double(cube[((bi * n + gi) * n + ri) * 4]) }
        let scale = Double(n - 1)
        let fr = r * scale, fg = g * scale, fb = b * scale
        let r0 = min(Int(fr), n - 2), g0 = min(Int(fg), n - 2), b0 = min(Int(fb), n - 2)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)
        var sum = 0.0
        for (dr, wr) in [(0, 1 - tr), (1, tr)] {
            for (dg, wg) in [(0, 1 - tg), (1, tg)] {
                for (db, wb) in [(0, 1 - tb), (1, tb)] {
                    sum += value(r0 + dr, g0 + dg, b0 + db) * wr * wg * wb
                }
            }
        }
        return sum
    }
}

/// A small deterministic generator (SplitMix64) so random cases are the same on every run.
struct MaskTestRandom: RandomNumberGenerator {
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
}
