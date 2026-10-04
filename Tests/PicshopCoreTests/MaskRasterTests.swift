import XCTest
@testable import PicshopCore

/// The CPU reference (§5 item 3): D1's algebra, the stack's expand, feather, invert and density, and every
/// component kind. The GPU rasterizer (M2) is tested against these numbers.
final class MaskRasterTests: XCTestCase {
    // MARK: D1 algebra

    /// Every mode × invert × opacity on 2×1 rasters, after a first component, against D1 written out.
    func testTheD1TruthTable() {
        let a: [Float] = [0.2, 0.8], b: [Float] = [0.6, 0.3]
        let source = MaskTestSource(rasters: ["a": FloatRaster(width: 2, height: 1, values: a), "b": FloatRaster(width: 2, height: 1, values: b)])
        for mode in CombineMode.allCases {
            for inverted in [false, true] {
                for opacity in [1.0, 0.5, 0] {
                    let stack = MaskStack(components: [
                        MaskComponent(.raster(MaskTestSource.raster("a", width: 2, height: 1))),
                        MaskComponent(.raster(MaskTestSource.raster("b", width: 2, height: 1)), mode: mode, isInverted: inverted, opacity: opacity),
                    ])
                    let result = MaskRaster.render(stack, width: 2, height: 1, source: source)
                    for index in 0..<2 {
                        var v = Double(b[index])
                        if inverted { v = 1 - v }
                        v *= opacity
                        let m = Double(a[index])
                        let expected: Double
                        switch mode {
                        case .add: expected = max(m, v)
                        case .subtract: expected = min(m, 1 - v)
                        case .intersect: expected = min(m, v)
                        }
                        XCTAssertEqual(Double(result.values[index]), expected, accuracy: 1e-6, "\(mode) inverted \(inverted) opacity \(opacity)")
                    }
                }
            }
        }
    }

    func testAFirstComponentInSubtractModeStartsFromEverything() {
        let source = MaskTestSource(rasters: ["b": FloatRaster(width: 2, height: 1, values: [0.25, 1])])
        let stack = MaskStack(components: [MaskComponent(.raster(MaskTestSource.raster("b", width: 2, height: 1)), mode: .subtract)])
        XCTAssertEqual(MaskRaster.render(stack, width: 2, height: 1, source: source).values, [0.75, 0])
        // An intersect first component starts from nothing.
        let intersect = MaskStack(components: [MaskComponent(.raster(MaskTestSource.raster("b", width: 2, height: 1)), mode: .intersect)])
        XCTAssertEqual(MaskRaster.render(intersect, width: 2, height: 1, source: source).values, [0, 0])
    }

    func testAnUnsupportedComponentIsSkippedAndAMissingRasterIsEmpty() {
        let source = MaskTestSource(rasters: ["b": FloatRaster(width: 2, height: 1, values: [0.25, 1])])
        let unsupported = MaskComponent(.unsupported(#"{"type":"spiral"}"#))
        // Skipped, and not the first component: the subtract after it still starts from everything.
        let stack = MaskStack(components: [unsupported, MaskComponent(.raster(MaskTestSource.raster("b", width: 2, height: 1)), mode: .subtract)])
        XCTAssertEqual(MaskRaster.render(stack, width: 2, height: 1, source: source).values, [0.75, 0])
        XCTAssertNil(MaskRaster.evaluate(unsupported, width: 2, height: 1, source: source))
        // A raster whose file is gone adds nothing and intersects to nothing.
        let missing = MaskComponent(.raster(MaskTestSource.raster("gone", width: 2, height: 1)))
        XCTAssertNil(MaskRaster.evaluate(missing, width: 2, height: 1, source: source))
        let full = MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0, y: -10), end: PSPoint(x: 0, y: -9))), isInverted: true)
        XCTAssertEqual(MaskRaster.render(MaskStack(components: [full, missing]), width: 2, height: 1, source: source).values, [1, 1])
        var intersect = missing
        intersect.mode = .intersect
        XCTAssertEqual(MaskRaster.render(MaskStack(components: [full, intersect]), width: 2, height: 1, source: source).values, [0, 0])
        // Nothing at all.
        XCTAssertEqual(MaskRaster.render(MaskStack(), width: 3, height: 2, source: source).values, [Float](repeating: 0, count: 6))
        XCTAssertEqual(MaskRaster.render(MaskStack(), width: 0, height: 2, source: source).values, [])
    }

    func testStackInvertAndDensity() {
        let source = MaskTestSource(rasters: ["a": FloatRaster(width: 2, height: 1, values: [0.2, 0.8])])
        let component = MaskComponent(.raster(MaskTestSource.raster("a", width: 2, height: 1)))
        let inverted = MaskRaster.render(MaskStack(components: [component], isInverted: true), width: 2, height: 1, source: source)
        XCTAssertEqual(inverted.values[0], 0.8, accuracy: 1e-6)
        XCTAssertEqual(inverted.values[1], 0.2, accuracy: 1e-6)
        // Density scales linearly, after the inversion.
        for density in [0.0, 0.25, 0.5, 1] {
            let result = MaskRaster.render(MaskStack(components: [component], isInverted: true, density: density), width: 2, height: 1, source: source)
            XCTAssertEqual(Double(result.values[0]), 0.8 * density, accuracy: 1e-6)
            XCTAssertEqual(Double(result.values[1]), 0.2 * density, accuracy: 1e-6)
        }
    }

    func testFeatherKeepsTheMass() {
        let disc = MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, feather: 0)))
        let source = MaskTestSource()
        let hard = MaskRaster.render(MaskStack(components: [disc]), width: 128, height: 128, source: source)
        for feather in [0.3, 1.0] {
            let soft = MaskRaster.render(MaskStack(components: [disc], feather: feather), width: 128, height: 128, source: source)
            let before = hard.values.reduce(0, +), after = soft.values.reduce(0, +)
            XCTAssertEqual(Double(after), Double(before), accuracy: 0.01 * Double(before))
            // And it is soft: values between 0.05 and 0.95 appear.
            XCTAssertGreaterThan(soft.values.filter { $0 > 0.05 && $0 < 0.95 }.count, hard.values.filter { $0 > 0.05 && $0 < 0.95 }.count)
        }
    }

    /// expand ±r moves a straight edge by r ± 1 px (r = |expand| × 0.02 × L).
    func testExpandMovesAStraightEdge() {
        let width = 200, height = 100
        // Left half selected, a hard vertical edge at x = 100.
        let half = FloatRaster(width: width, height: height, values: (0..<(width * height)).map { $0 % width < 100 ? 1 : 0 })
        let source = MaskTestSource(rasters: ["half": half])
        let component = MaskComponent(.raster(MaskTestSource.raster("half", width: width, height: height)))
        func edge(_ raster: FloatRaster) -> Int {
            // The first column (middle row) below 0.5.
            (0..<width).first { raster[$0, height / 2] < 0.5 } ?? width
        }
        XCTAssertEqual(edge(MaskRaster.render(MaskStack(components: [component]), width: width, height: height, source: source)), 100)
        for expand in [0.5, 1.0] {
            let r = expand * MaskStack.expandRadiusFraction * Double(width)
            let grown = edge(MaskRaster.render(MaskStack(components: [component], expand: expand), width: width, height: height, source: source))
            let shrunk = edge(MaskRaster.render(MaskStack(components: [component], expand: -expand), width: width, height: height, source: source))
            XCTAssertEqual(Double(grown - 100), r, accuracy: 1)
            XCTAssertEqual(Double(100 - shrunk), r, accuracy: 1)
        }
    }

    // MARK: Gradients

    func testLinear() {
        let height = 101
        let spec = LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.5 / Double(height)), end: PSPoint(x: 0.5, y: 100.5 / Double(height)))
        let raster = MaskRaster.evaluate(MaskComponent(.linear(spec)), width: 3, height: height, source: MaskTestSource())!
        XCTAssertEqual(raster[1, 0], 1, accuracy: 1e-6)
        XCTAssertEqual(raster[1, 100], 0, accuracy: 1e-6)
        XCTAssertEqual(raster[1, 50], 0.5, accuracy: 0.01)
        for y in 1..<height {
            XCTAssertLessThanOrEqual(raster[1, y], raster[1, y - 1])
        }
        // Constant across the gradient's axis.
        XCTAssertEqual(raster[0, 30], raster[2, 30])
        // Start and end on the same point: nothing.
        let flat = MaskRaster.evaluate(MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0.5), end: PSPoint(x: 0.5, y: 0.5)))), width: 4, height: 4, source: MaskTestSource())!
        XCTAssertEqual(flat.values, [Float](repeating: 0, count: 16))
    }

    func testRadialRotationSwapsTheAxesAndFeatherZeroIsHard() {
        let source = MaskTestSource()
        let wide = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.1, rotation: 90, feather: 0.5)
        let tall = RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.3, rotation: 0, feather: 0.5)
        let a = MaskRaster.evaluate(MaskComponent(.radial(wide)), width: 64, height: 64, source: source)!
        let b = MaskRaster.evaluate(MaskComponent(.radial(tall)), width: 64, height: 64, source: source)!
        for index in a.values.indices {
            XCTAssertEqual(a.values[index], b.values[index], accuracy: 1e-5)
        }
        // Inside (1 − feather) of the ellipse it is full; past its edge, nothing.
        XCTAssertEqual(b[32, 32], 1)
        XCTAssertEqual(b[32, 32 + 8], 1)
        XCTAssertEqual(b[32 + 10, 32], 0)
        // Feather 0: a hard edge, no value between 0 and 1.
        let hard = MaskRaster.evaluate(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.4, y: 0.6), radiusX: 0.25, radiusY: 0.15, rotation: 30, feather: 0))),
                                       width: 80, height: 60, source: source)!
        XCTAssertTrue(hard.values.allSatisfy { $0 == 0 || $0 == 1 })
        XCTAssertGreaterThan(hard.values.filter { $0 == 1 }.count, 100)
        // Radii are fractions of the longest side: a circle stays round on a wide raster.
        let circle = MaskRaster.evaluate(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.1, radiusY: 0.1, feather: 0))),
                                         width: 200, height: 100, source: source)!
        let row = (0..<200).filter { circle[$0, 50] == 1 }.count, column = (0..<100).filter { circle[100, $0] == 1 }.count
        XCTAssertEqual(Double(row), Double(column), accuracy: 1)
    }

    func testInvertingAComponentIsItsComplement() {
        let source = MaskTestSource()
        let spec = RadialGradientSpec(center: PSPoint(x: 0.3, y: 0.6), radiusX: 0.2, radiusY: 0.3, rotation: 20)
        let plain = MaskRaster.render(.single(MaskComponent(.radial(spec))), width: 50, height: 40, source: source)
        let inverted = MaskRaster.render(.single(MaskComponent(.radial(spec), isInverted: true)), width: 50, height: 40, source: source)
        for index in plain.values.indices {
            XCTAssertEqual(plain.values[index] + inverted.values[index], 1, accuracy: 1e-6)
        }
    }

    // MARK: Rasters, brushes, ranges

    func testARasterIsPlacedByItsCorners() {
        let source = MaskTestSource(rasters: ["ones": FloatRaster(width: 4, height: 4, values: [Float](repeating: 1, count: 16))])
        // The raster covers the left half of the layer.
        var raster = MaskTestSource.raster("ones", width: 4, height: 4)
        raster.corners = [PSPoint(x: 0, y: 0), PSPoint(x: 0.5, y: 0), PSPoint(x: 0.5, y: 1), PSPoint(x: 0, y: 1)]
        let placed = MaskRaster.evaluate(MaskComponent(.raster(raster)), width: 20, height: 10, source: source)!
        XCTAssertEqual(placed[4, 5], 1)
        XCTAssertEqual(placed[15, 5], 0)
        // In subtract mode after a full component, the mask outside its quad is untouched (D5 item 4).
        let full = MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0, y: -10), end: PSPoint(x: 0, y: -9))), isInverted: true)
        let stack = MaskStack(components: [full, MaskComponent(.raster(raster), mode: .subtract)])
        let result = MaskRaster.render(stack, width: 20, height: 10, source: source)
        XCTAssertEqual(result[4, 5], 0)
        XCTAssertEqual(result[15, 5], 1)
    }

    func testASoftRasterKeepsItsValues() {
        // A soft 0.5 edge is never gamma-shifted: the reference reads raw values.
        let values: [Float] = [0, 0.25, 0.5, 0.75, 1, 0.5]
        let source = MaskTestSource(rasters: ["soft": FloatRaster(width: 6, height: 1, values: values)])
        let raster = MaskRaster.evaluate(MaskComponent(.raster(MaskTestSource.raster("soft", width: 6, height: 1))), width: 6, height: 1, source: source)!
        for index in values.indices { XCTAssertEqual(raster.values[index], values[index], accuracy: 1e-6) }
        // Resampled at twice the size, bilinear between centres.
        let doubled = MaskRaster.evaluate(MaskComponent(.raster(MaskTestSource.raster("soft", width: 6, height: 1))), width: 12, height: 1, source: source)!
        XCTAssertEqual(doubled.values[0], 0, accuracy: 1e-6)
        XCTAssertEqual(doubled.values[3], 0.3125, accuracy: 1e-6)
    }

    func testABrushHonoursFlowAndSubtract() {
        let stroke = BrushStroke(points: [PSPoint(x: 0.2, y: 0.5), PSPoint(x: 0.8, y: 0.5)], radius: 0.1, hardness: 1, flow: 0.5)
        let half = MaskRaster.evaluate(MaskComponent(.brush(BrushSpec(strokes: [stroke]))), width: 100, height: 50, source: MaskTestSource())!
        XCTAssertEqual(half[50, 25], 128 / 255, accuracy: 1e-6)
        XCTAssertEqual(half[50, 2], 0)
        var full = stroke
        full.flow = nil
        let erase = BrushStroke(points: [PSPoint(x: 0.5, y: 0.5)], radius: 0.05, hardness: 1, mode: .subtract)
        let painted = MaskRaster.evaluate(MaskComponent(.brush(BrushSpec(strokes: [full, erase]))), width: 100, height: 50, source: MaskTestSource())!
        XCTAssertEqual(painted[30, 25], 1)
        XCTAssertEqual(painted[50, 25], 0)
    }

    func testLuminanceAndColorRangesReadThePixels() {
        // Four pixels: black, mid grey, white, saturated red.
        let rgba: [UInt8] = [0, 0, 0, 255, 128, 128, 128, 255, 255, 255, 255, 255, 255, 0, 0, 255]
        let source = MaskTestSource(rgba: rgba)
        let shadows = MaskRaster.evaluate(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0, high: 0.25))), width: 4, height: 1, source: source)!
        XCTAssertEqual(shadows.values[0], 1)
        XCTAssertEqual(shadows.values[2], 0)
        let highlights = MaskRaster.evaluate(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.75, high: 1))), width: 4, height: 1, source: source)!
        XCTAssertEqual(highlights.values[2], 1)
        XCTAssertEqual(highlights.values[0], 0)
        let spec = ColorRangeSpec(preset: .reds)
        let reds = MaskRaster.evaluate(MaskComponent(.colorRange(spec)), width: 4, height: 1, source: source)!
        XCTAssertEqual(reds.values, [0, 0, 0, 1])
        for index in 0..<4 {
            let lab = MaskMath.lab(bytes: rgba[4 * index], rgba[4 * index + 1], rgba[4 * index + 2])
            XCTAssertEqual(Double(reds.values[index]), MaskMath.colorRange(lab, spec), accuracy: 1e-6)
        }
        // Without pixels a range has no input: nil, and the stack counts it as empty.
        XCTAssertNil(MaskRaster.evaluate(MaskComponent(.colorRange(spec)), width: 4, height: 1, source: MaskTestSource()))
    }

    func testADepthRangeGoesThroughTheTrapezoid() {
        let ramp = FloatRaster(width: 11, height: 1, values: (0...10).map { Float($0) / 10 })
        let source = MaskTestSource(rasters: ["depth": ramp])
        var depth = MaskTestSource.raster("depth", width: 11, height: 1)
        depth.origin = .depth
        depth.bitDepth = 16
        let near = MaskRaster.evaluate(MaskComponent(.depthRange(DepthRangeSpec(depth: depth, low: 0.6, high: 1, feather: 0))), width: 11, height: 1, source: source)!
        XCTAssertEqual(near.values, (0...10).map { $0 >= 6 ? 1 : 0 })
        let far = MaskRaster.evaluate(MaskComponent(.depthRange(DepthRangeSpec(depth: depth, low: 0, high: 0.35))), width: 11, height: 1, source: source)!
        XCTAssertEqual(far.values[0], 1)
        XCTAssertEqual(far.values[10], 0)
        XCTAssertEqual(Double(far.values[4]), MaskMath.trapezoid(0.4, low: 0, high: 0.35, feather: 0.15), accuracy: 1e-6)
    }

    // MARK: Cost

    /// A reference, not a hot path: 512 × 512 with six components (one of each pixel-reading kind) stays well
    /// inside a second on a debug build. The bound here is an order of magnitude looser (loaded CI runners).
    func testSixComponentsAt512RenderQuickly() {
        let side = 512
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            rgba[4 * index] = UInt8(index % 256)
            rgba[4 * index + 1] = UInt8((index / side) % 256)
            rgba[4 * index + 2] = UInt8((index * 7) % 256)
        }
        let ai = FloatRaster(width: 384, height: 384, values: (0..<(384 * 384)).map { Float($0 % 384) / 383 })
        let source = MaskTestSource(rgba: rgba, rasters: ["ai": ai])
        var raster = MaskTestSource.raster("ai", width: 384, height: 384)
        raster.corners = [PSPoint(x: 0.1, y: 0), PSPoint(x: 1, y: 0.05), PSPoint(x: 0.95, y: 1), PSPoint(x: 0, y: 0.9)]
        let stack = MaskStack(components: [
            MaskComponent(.raster(raster)),
            MaskComponent(.brush(BrushSpec(strokes: [BrushStroke(points: [PSPoint(x: 0.1, y: 0.1), PSPoint(x: 0.9, y: 0.8)], radius: 0.05, flow: 0.8)]))),
            MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 1), end: PSPoint(x: 0.5, y: 0.5))), mode: .intersect),
            MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.2, rotation: 15)), mode: .add),
            MaskComponent(.colorRange(ColorRangeSpec(samples: [LabColor(l: 60, a: 20, b: 10)], fuzziness: 0.4)), mode: .subtract),
            MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.3, high: 0.6)), mode: .add, opacity: 0.5),
        ], feather: 0.2, expand: 0.1)
        let start = Date()
        let result = MaskRaster.render(stack, width: side, height: side, source: source)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.values.count, side * side)
        XCTAssertLessThan(elapsed, 10)
    }
}

/// Raster samples and pixels for the reference, keyed by raster path.
struct MaskTestSource: MaskPixelSource {
    var rgba: [UInt8]?
    var rasters: [String: FloatRaster] = [:]

    init(rgba: [UInt8]? = nil, rasters: [String: FloatRaster] = [:]) {
        self.rgba = rgba
        self.rasters = rasters
    }

    func samples(of raster: RasterRef) -> FloatRaster? {
        rasters[raster.path]
    }

    static func raster(_ path: String, width: Int, height: Int) -> RasterRef {
        RasterRef(path: path, origin: .subject, pixelWidth: width, pixelHeight: height)
    }
}
