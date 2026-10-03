import XCTest
@testable import PicshopCore

/// Curves, Levels, the tone table and the histogram: the maths behind the Curves
/// and Levels panels, Auto Tone and the histogram card.
final class ToneMathTests: XCTestCase {
    private typealias P = ToneCurve.Point

    /// A small deterministic generator, so the property tests are the same on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Spline

    func testTwoPointsAreTheIdentity() {
        let straight = [P(0, 0), P(1, 1)]
        for index in 0...100 {
            let x = Double(index) / 100
            XCTAssertEqual(CurveSpline.evaluate(straight, at: x), x, accuracy: 1e-12)
        }
        XCTAssertTrue(CurveSpline.isIdentity(straight))
        XCTAssertTrue(CurveSpline.isIdentity(ToneCurve.linear))
        XCTAssertTrue(CurveSpline.isIdentity([]))
        XCTAssertTrue(ToneCurve.identity.isIdentity)
    }

    func testTheSplinePassesThroughItsPoints() {
        var generator = SeededGenerator(state: 7)
        for _ in 0..<200 {
            let count = Int.random(in: 2...ToneCurve.maxPoints, using: &generator)
            var inputs = Set<Double>()
            while inputs.count < count { inputs.insert((Double.random(in: 0...1, using: &generator) * 1000).rounded() / 1000) }
            let points = inputs.sorted().map { P($0, Double.random(in: 0...1, using: &generator)) }
            for point in points {
                XCTAssertEqual(CurveSpline.evaluate(points, at: point.input), point.output, accuracy: 1e-6, "\(points)")
            }
        }
    }

    func testRisingPointsGiveARisingCurve() {
        var generator = SeededGenerator(state: 42)
        for _ in 0..<1000 {
            let count = Int.random(in: 2...ToneCurve.maxPoints, using: &generator)
            var inputs = Set<Double>()
            while inputs.count < count { inputs.insert(Double.random(in: 0...1, using: &generator)) }
            let outputs = (0..<count).map { _ in Double.random(in: 0...1, using: &generator) }.sorted()
            let points = zip(inputs.sorted(), outputs).map { P($0, $1) }
            let table = CurveSpline.table(points, count: 512)
            for index in 1..<table.count {
                XCTAssertGreaterThanOrEqual(table[index], table[index - 1] - 1e-6, "not monotone at \(index) for \(points)")
            }
            XCTAssertTrue(table.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    func testEndpointsClampAndPointsAreSortedAndMerged() {
        // Flat before the first point and after the last.
        let inside = [P(0.2, 0.3), P(0.8, 0.6)]
        XCTAssertEqual(CurveSpline.evaluate(inside, at: 0), 0.3, accuracy: 1e-12)
        XCTAssertEqual(CurveSpline.evaluate(inside, at: 1), 0.6, accuracy: 1e-12)
        // Order does not matter.
        let shuffled = [P(1, 1), P(0, 0), P(0.5, 0.7)]
        XCTAssertEqual(CurveSpline.evaluate(shuffled, at: 0.5), 0.7, accuracy: 1e-12)
        XCTAssertEqual(CurveSpline.evaluate(shuffled, at: 0.25), CurveSpline.evaluate([P(0, 0), P(0.5, 0.7), P(1, 1)], at: 0.25), accuracy: 1e-12)
        // Two points at one input: the later one wins.
        let duplicate = [P(0, 0), P(0.5, 0.2), P(0.5, 0.8), P(1, 1)]
        XCTAssertEqual(CurveSpline.evaluate(duplicate, at: 0.5), 0.8, accuracy: 1e-12)
        // An inverted curve is allowed and stays in range.
        XCTAssertEqual(CurveSpline.evaluate([P(0, 1), P(1, 0)], at: 0.25), 0.75, accuracy: 1e-12)
    }

    func testNoOvershootAroundAPeak() {
        // Up then down: the peak stays the highest value, nothing rings past it.
        let points = [P(0, 0), P(0.4, 0.9), P(0.5, 1), P(0.6, 0.9), P(1, 0)]
        let table = CurveSpline.table(points, count: 1001)
        XCTAssertLessThanOrEqual(table.max() ?? 2, 1)
        XCTAssertEqual(Double(table[500]), 1, accuracy: 1e-6)
    }

    func testIdentityIsNumeric() {
        var curve = ToneCurve.identity
        curve.setPoints([P(0, 0), P(0.3, 0.3), P(1, 1)], for: .red)
        XCTAssertTrue(curve.isIdentity, "points on the diagonal change nothing")
        curve.setPoints([P(0, 0), P(0.3, 0.3005), P(1, 1)], for: .green)
        XCTAssertTrue(curve.isIdentity, "within 1/1024")
        curve.setPoints([P(0, 0), P(0.3, 0.32), P(1, 1)], for: .blue)
        XCTAssertFalse(curve.isIdentity)
        // A curve that starts late is not the identity even though its points are on the diagonal.
        XCTAssertFalse(CurveSpline.isIdentity([P(0.2, 0.2), P(1, 1)]))
    }

    func testOldFivePointCurvesDecodeUnchanged() throws {
        // As every build before W1 wrote a ToneCurve.
        let json = #"{"blue":[{"input":0,"output":0},{"input":0.25,"output":0.25},{"input":0.5,"output":0.5},{"input":0.75,"output":0.75},{"input":1,"output":1}],"green":[{"input":0,"output":0},{"input":0.25,"output":0.25},{"input":0.5,"output":0.5},{"input":0.75,"output":0.75},{"input":1,"output":1}],"red":[{"input":0,"output":0},{"input":0.25,"output":0.25},{"input":0.5,"output":0.5},{"input":0.75,"output":0.75},{"input":1,"output":1}],"rgb":[{"input":0,"output":0},{"input":0.25,"output":0.166},{"input":0.5,"output":0.5},{"input":0.75,"output":0.834},{"input":1,"output":1}]}"#
        let curve = try JSONDecoder().decode(ToneCurve.self, from: Data(json.utf8))
        XCTAssertEqual(curve.rgb.count, 5)
        XCTAssertEqual(curve.rgb[1].output, 0.166)
        XCTAssertEqual(curve.red, ToneCurve.linear)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try JSONDecoder().decode(ToneCurve.self, from: encoder.encode(curve)), curve)
    }

    func testSetPointsSortsMergesAndCaps() {
        var curve = ToneCurve.identity
        curve.setPoints([P(1, 1), P(0.5, 0.4), P(0, 0), P(0.5, 0.6)], for: .rgb)
        XCTAssertEqual(curve.rgb, [P(0, 0), P(0.5, 0.6), P(1, 1)])
        curve.setPoints([P(0.4, 0.4)], for: .red)
        XCTAssertEqual(curve.red, ToneCurve.straight, "fewer than two points is the straight line")
        let many = (0...30).map { P(Double($0) / 30, Double($0) / 30) }
        curve.setPoints(many, for: .blue)
        XCTAssertEqual(curve.blue.count, ToneCurve.maxPoints)
        XCTAssertEqual(curve.blue.first, P(0, 0))
        XCTAssertEqual(curve.blue.last, P(1, 1))
    }

    func testPresetsMatchTheirShapes() {
        XCTAssertTrue(CurveSpline.isIdentity(ToneCurve.Preset.linear.points(strength: 1)))
        XCTAssertEqual(ToneCurve.Preset.sCurve.points(strength: 0.5), ToneCurve.sCurve(strength: 0.5).rgb)
        let s = ToneCurve.Preset.strongS.points(strength: 1)
        XCTAssertLessThan(CurveSpline.evaluate(s, at: 0.25), 0.25)
        XCTAssertGreaterThan(CurveSpline.evaluate(s, at: 0.75), 0.75)
        XCTAssertEqual(CurveSpline.evaluate(ToneCurve.Preset.invert.points(strength: 0), at: 0.2), 0.8, accuracy: 1e-12)
        XCTAssertGreaterThan(CurveSpline.evaluate(ToneCurve.Preset.fade.points(strength: 1), at: 0), 0)
        XCTAssertGreaterThan(CurveSpline.evaluate(ToneCurve.Preset.brighten.points(strength: 1), at: 0.5), 0.5)
        XCTAssertLessThan(CurveSpline.evaluate(ToneCurve.Preset.darken.points(strength: 1), at: 0.5), 0.5)
        for preset in ToneCurve.Preset.allCases {
            XCTAssertFalse(preset.englishName.isEmpty)
            XCTAssertFalse(preset.frenchName.isEmpty)
            XCTAssertLessThanOrEqual(preset.points(strength: 1).count, ToneCurve.maxPoints)
        }
    }

    // MARK: Levels

    func testIdentityLevelsChangeNothing() {
        for index in 0...255 {
            let x = Double(index) / 255
            XCTAssertEqual(Levels.identity.rgb.map(x), x, accuracy: 1e-12)
            for channel in ToneCurve.Channel.allCases {
                XCTAssertEqual(Levels.identity.map(x, channel: channel), x, accuracy: 1e-12)
            }
        }
        XCTAssertTrue(Levels.identity.isIdentity)
        XCTAssertTrue(ToneLUT.make(levels: .identity, curve: .identity).isIdentity)
    }

    func testLevelsHandles() {
        let channel = Levels.Channel(inBlack: 0.2, inWhite: 0.8, gamma: 1, outBlack: 0.1, outWhite: 0.9)
        XCTAssertEqual(channel.map(0.1), 0.1, accuracy: 1e-12, "below the black point: output black")
        XCTAssertEqual(channel.map(0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(channel.map(0.95), 0.9, accuracy: 1e-12)
        // Gamma above 1 lifts the midtones, below 1 lowers them; the ends stay.
        let lift = Levels.Channel(gamma: 2)
        XCTAssertEqual(lift.map(0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(lift.map(0), 0, accuracy: 1e-12)
        XCTAssertEqual(lift.map(1), 1, accuracy: 1e-12)
        XCTAssertLessThan(Levels.Channel(gamma: 0.5).map(0.5), 0.5)
        // Output black above output white inverts.
        XCTAssertEqual(Levels.Channel(outBlack: 1, outWhite: 0).map(0.3), 0.7, accuracy: 1e-12)
        // A collapsed input range is a threshold.
        let threshold = Levels.Channel(inBlack: 0.5, inWhite: 0.5)
        XCTAssertEqual(threshold.map(0.49), 0)
        XCTAssertEqual(threshold.map(0.51), 1)
        // Gamma is kept in its range.
        XCTAssertEqual(Levels.Channel(gamma: 50).map(0.5), pow(0.5, 1 / 9.99), accuracy: 1e-12)
    }

    func testChannelLevelsComeBeforeTheMaster() {
        let levels = Levels(rgb: Levels.Channel(inWhite: 0.5), red: Levels.Channel(outWhite: 0.5))
        // Red: 0.8 → 0.4 (its own), → 0.8 (master). The other way round it would be 1 → 0.5.
        XCTAssertEqual(levels.map(0.8, channel: .red), 0.8, accuracy: 1e-12)
        XCTAssertEqual(levels.map(0.8, channel: .green), 1, accuracy: 1e-12)
    }

    /// A histogram from per-bin counts (the same in R, G, B and luma: a grey picture).
    private func grey(_ counts: [Int: UInt32]) -> Histogram {
        var bins = [UInt32](repeating: 0, count: Histogram.binCount)
        for (bin, count) in counts { bins[bin] = count }
        return Histogram(red: bins, green: bins, blue: bins, luma: bins)
    }

    /// Fraction of a grey histogram's pixels the levels send to 0 and to 1.
    private func clipped(_ histogram: Histogram, by levels: Levels) -> (shadows: Double, highlights: Double) {
        let total = Double(histogram.total)
        var low = 0.0, high = 0.0
        for (bin, count) in histogram.luma.enumerated() where count > 0 {
            let value = levels.map(Double(bin) / 255, channel: .red)
            if value <= 1e-9 { low += Double(count) }
            if value >= 1 - 1e-9 { high += Double(count) }
        }
        return (low / total, high / total)
    }

    func testAutoLevelsClipATenthOfAPercentOnEachSide() {
        // The picture sits between 20 and 230 with a few stray pixels below and above.
        var counts: [Int: UInt32] = [3: 60, 9: 40, 240: 50, 251: 50]
        for bin in 20...230 { counts[bin] = 1000 }
        let histogram = grey(counts)
        let levels = Levels.auto(from: histogram)
        XCTAssertTrue(levels.red.isIdentity && levels.green.isIdentity && levels.blue.isIdentity, "tone only: no colour change")
        // 211 000 pixels: 0.1 % is 211, so the 100 strays on each side go and the picture's ends stay.
        XCTAssertEqual(levels.rgb.inBlack * 255, 19, accuracy: 1e-9)
        XCTAssertEqual(levels.rgb.inWhite * 255, 231, accuracy: 1e-9)
        let clip = clipped(histogram, by: levels)
        XCTAssertLessThanOrEqual(clip.shadows, 0.001)
        XCTAssertLessThanOrEqual(clip.highlights, 0.001)
        XCTAssertGreaterThan(clip.shadows, 0)
        XCTAssertGreaterThan(clip.highlights, 0)
    }

    func testAutoLevelsLetGoOfNoMoreThanTheClip() {
        // Tails heavier than 0.1 %: the black point stops before them.
        var counts: [Int: UInt32] = [:]
        for bin in 0...255 { counts[bin] = 100 }
        counts[0] = 1000
        let histogram = grey(counts)
        let levels = Levels.auto(from: histogram, clip: 0.001)
        XCTAssertEqual(levels.rgb.inBlack, 0, "the darkest bin alone holds more than 0.1 %")
        XCTAssertEqual(levels.rgb.inWhite, 1)
        let wider = Levels.auto(from: histogram, clip: 0.05)
        let clip = clipped(histogram, by: wider)
        XCTAssertLessThanOrEqual(clip.shadows, 0.05)
        XCTAssertLessThanOrEqual(clip.highlights, 0.05)
        XCTAssertGreaterThan(wider.rgb.inBlack, 0)
    }

    func testAutoLevelsLiftADarkPictureAndLeaveAFullOneAlone() {
        // Dark: everything between 0 and 120, most of it low.
        var dark: [Int: UInt32] = [:]
        for bin in 0...120 { dark[bin] = UInt32(max(1, 400 - bin * 3)) }
        let lifted = Levels.auto(from: grey(dark))
        XCTAssertLessThan(lifted.rgb.inWhite, 0.5)
        XCTAssertGreaterThan(lifted.rgb.gamma, 1, "dark midtones are lifted")
        XCTAssertLessThanOrEqual(lifted.rgb.gamma, 1.5)
        // A full, balanced range: nothing to do.
        var full: [Int: UInt32] = [:]
        for bin in 0...255 { full[bin] = 500 }
        XCTAssertTrue(Levels.auto(from: grey(full)).isIdentity)
        // An empty histogram and a flat picture never blow up.
        XCTAssertEqual(Levels.auto(from: grey([:])), .identity)
        let flat = Levels.auto(from: grey([128: 5000]))
        XCTAssertGreaterThanOrEqual(flat.rgb.inWhite - flat.rgb.inBlack, 0.25 - 1e-9, "at most a 4× stretch")
    }

    func testAutoLevelsDoNotClipASaturatedChannel() {
        // A red patch: red at 250, green and blue at 20; a grey ramp elsewhere tops out at 200.
        var red = [UInt32](repeating: 0, count: 256), green = red, blue = red, luma = red
        for bin in 40...200 { red[bin] += 100; green[bin] += 100; blue[bin] += 100; luma[bin] += 100 }
        red[250] += 2000; green[20] += 2000; blue[20] += 2000; luma[71] += 2000
        let levels = Levels.auto(from: Histogram(red: red, green: green, blue: blue, luma: luma))
        XCTAssertGreaterThanOrEqual(levels.rgb.inWhite * 255, 250 - 1e-9, "the red channel's highlights are not blown")
        XCTAssertLessThanOrEqual(levels.rgb.inBlack * 255, 20 + 1e-9)
    }

    // MARK: Tone table

    func testTheTableAppliesLevelsThenTheChannelCurveThenTheMaster() {
        var curve = ToneCurve.identity
        curve.setPoints([P(0, 0), P(1, 0.5)], for: .red)       // red halves
        curve.setPoints([P(0, 0), P(0.5, 1), P(1, 1)], for: .rgb) // master: rises to 1 at 0.5, then flat
        let levels = Levels(rgb: Levels.Channel(inBlack: 0.5)) // the top half stretched over the range
        let lut = ToneLUT.make(levels: levels, curve: curve, count: 256)
        // x = 0.8: levels → 0.6, red curve → 0.3, master → 0.744.
        let x = 0.8
        let expected = CurveSpline.evaluate(curve.rgb, at: CurveSpline.evaluate(curve.red, at: levels.map(x, channel: .red)))
        XCTAssertEqual(expected, 0.744, accuracy: 1e-9)
        XCTAssertEqual(lut.value(x, channel: .red), expected, accuracy: 2e-3)
        // Green has no curve of its own: levels, then the master (flat at 1 past 0.5).
        XCTAssertEqual(lut.value(x, channel: .green), 1, accuracy: 2e-3)
        // The curves first would give 0.856: the order is pinned.
        let curveFirst = levels.map(CurveSpline.evaluate(curve.rgb, at: CurveSpline.evaluate(curve.red, at: x)), channel: .red)
        XCTAssertGreaterThan(abs(curveFirst - expected), 0.05)
        XCTAssertEqual(lut.red.count, 256)
        XCTAssertEqual(lut.interleaved.count, 256 * 3)
        XCTAssertEqual(lut.interleaved[3 * 10 + 1], lut.green[10])
        XCTAssertFalse(lut.isIdentity)
    }

    func testAToneTableOnlyWhenSomethingChanges() {
        var stack = EditStack()
        XCTAssertNil(stack.resolvedToneLUT)
        XCTAssertNil(stack.resolvedUserToneCurve)
        stack.append(.look(.cinematic, intensity: 1))
        XCTAssertNil(stack.resolvedToneLUT, "a look's curve renders with the adjustments, not in the table")
        XCTAssertEqual(stack.resolvedLookToneCurve, FilterPreset.cinematic.toneCurve)
        stack.setTone(.toneCurve(ToneCurve.identity))
        XCTAssertNil(stack.resolvedToneLUT)
        var curve = ToneCurve.identity
        curve.setPoints(ToneCurve.Preset.sCurve.points(strength: 1), for: .green)
        stack.setTone(.toneCurve(curve))
        XCTAssertNotNil(stack.resolvedToneLUT)
        XCTAssertEqual(stack.resolvedLookToneCurve, FilterPreset.cinematic.toneCurve, "the look's curve stays under the person's")
        stack.append(.levels(Levels(rgb: Levels.Channel(inBlack: 0.1))))
        let stripped = stack.removingToneTable()
        XCTAssertNil(stripped.resolvedToneLUT)
        XCTAssertEqual(stripped.resolvedLook?.preset, .cinematic)
        XCTAssertEqual(stripped.operations.count, 1)
    }

    // MARK: Histogram

    func testHistogramComputeIsExact() {
        // 4 × 2 pixels: black, white, red, green / blue, mid grey, (10, 20, 30), white.
        let pixels: [[UInt8]] = [[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 255, 0], [0, 0, 255], [128, 128, 128], [10, 20, 30], [255, 255, 255]]
        let rgba: [UInt8] = pixels.flatMap { $0 + [UInt8(255)] }
        let histogram = Histogram.compute(rgba: rgba, width: 4, height: 2)
        XCTAssertEqual(histogram.total, 8)
        XCTAssertEqual(histogram.red[255], 3)
        XCTAssertEqual(histogram.red[0], 3)
        XCTAssertEqual(histogram.red[128], 1)
        XCTAssertEqual(histogram.red[10], 1)
        XCTAssertEqual(histogram.green[20], 1)
        XCTAssertEqual(histogram.blue[30], 1)
        XCTAssertEqual(histogram.blue[255], 3)
        // Luma, Rec. 709: red 54, green 182, blue 18, (10, 20, 30) → 18.6 → 19.
        XCTAssertEqual(histogram.luma[0], 1)
        XCTAssertEqual(histogram.luma[255], 2)
        XCTAssertEqual(histogram.luma[54], 1)
        XCTAssertEqual(histogram.luma[182], 1)
        XCTAssertEqual(histogram.luma[18], 1)
        XCTAssertEqual(histogram.luma[128], 1)
        XCTAssertEqual(histogram.luma[19], 1)
        for channel in HistogramChannel.allCases {
            XCTAssertEqual(histogram.bins(channel).reduce(0, +), 8)
            XCTAssertEqual(histogram.bins(channel).count, Histogram.binCount)
        }
        // A short buffer counts only what it holds.
        XCTAssertEqual(Histogram.compute(rgba: Array(rgba.prefix(8)), width: 4, height: 2).total, 2)
    }

    func testPremultipliedReadbacksSkipTransparentPixels() {
        // Opaque white, transparent, and red at half alpha (premultiplied 128, 0, 0, 128).
        let rgba: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 0, 128, 0, 0, 128]
        let histogram = Histogram.compute(premultipliedRGBA: rgba, width: 3, height: 1)
        XCTAssertEqual(histogram.total, 2)
        XCTAssertEqual(histogram.red[255], 2, "the half-transparent red is unpremultiplied")
        XCTAssertEqual(histogram.green[0], 1)
    }

    func testPercentilesAndClipping() {
        var counts: [Int: UInt32] = [:]
        for bin in 0...99 { counts[bin] = 1 }
        let histogram = grey(counts)
        XCTAssertEqual(histogram.percentile(0.5, .luma), 49.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(histogram.percentile(1, .red), 99.0 / 255, accuracy: 1e-12)
        XCTAssertEqual(histogram.percentile(0, .green), 0)
        XCTAssertEqual(histogram.clipping.shadows, 0.02, accuracy: 1e-12, "bins 0 and 1")
        XCTAssertEqual(histogram.clipping.highlights, 0)
        XCTAssertEqual(Histogram.blackPoint(of: histogram.luma, clip: 0.05), 4)
        XCTAssertEqual(Histogram.whitePoint(of: histogram.luma, clip: 0.05), 95, "the empty top is free, then five pixels")
        XCTAssertEqual(Histogram.Clipping.warningFraction, 0.005)
    }
}
