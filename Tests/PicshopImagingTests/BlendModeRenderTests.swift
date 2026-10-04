#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// Every blend mode on Core Image against the reference formulas (BlendMath), opacity,
/// and dissolve's grain.
final class BlendModeRenderTests: XCTestCase {
    /// The six colour pairs of BlendMathTests (8-bit Display P3 values).
    private static let pairs: [(backdrop: BlendMath.RGB, source: BlendMath.RGB)] = [
        (.init(bytes: 204, 128, 51), .init(bytes: 51, 153, 230)),
        (.init(bytes: 30, 60, 90), .init(bytes: 200, 180, 40)),
        (.init(bytes: 255, 255, 255), .init(bytes: 128, 64, 0)),
        (.init(bytes: 0, 0, 0), .init(bytes: 100, 150, 200)),
        (.init(bytes: 120, 200, 80), .init(bytes: 128, 128, 128)),
        (.init(bytes: 250, 20, 130), .init(bytes: 10, 240, 90)),
    ]

    /// The centre pixel of `top` blended over `bottom`.
    private func blended(_ mode: BlendMode, _ pair: (backdrop: BlendMath.RGB, source: BlendMath.RGB), opacity: Double = 1) -> [Int] {
        let result = BlendModes.composite(ToneTestImages.solid(pair.source), over: ToneTestImages.solid(pair.backdrop), mode: mode, opacity: opacity)
        let bytes = ToneTestImages.bytes(result, width: 8, height: 8)
        let i = (4 * 8 + 4) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }

    func testEveryModeMatchesTheReference() {
        var worst: (mode: BlendMode, difference: Int) = (.normal, 0)
        for mode in BlendMode.allCases where mode != .dissolve {
            for pair in Self.pairs {
                let expected = BlendMath.blend(mode, backdrop: pair.backdrop, source: pair.source)
                let got = blended(mode, pair)
                for (value, reference) in zip(got, [expected.r, expected.g, expected.b]) {
                    let difference = abs(value - Int((reference * 255).rounded()))
                    if difference > worst.difference { worst = (mode, difference) }
                    XCTAssertLessThanOrEqual(difference, 3, "\(mode): \(pair.source) over \(pair.backdrop) gave \(got), expected \(expected)")
                }
            }
        }
        print("BLEND-MODES worst difference \(worst.difference)/255 (\(worst.mode))")
    }

    func testOpacityMixesTheBlendWithTheBackdrop() {
        for mode in [BlendMode.multiply, .screen, .overlay, .difference, .colorBurn, .hardMix, .darkerColor] {
            let pair = Self.pairs[0]
            let expected = BlendMath.composite(mode, backdrop: pair.backdrop, source: pair.source, alpha: 0.5)
            let got = blended(mode, pair, opacity: 0.5)
            for (value, reference) in zip(got, [expected.r, expected.g, expected.b]) {
                XCTAssertEqual(value, Int((reference * 255).rounded()), accuracy: 3, "\(mode) at 50 %: \(got) vs \(expected)")
            }
        }
        // No opacity: the backdrop as it was.
        for (value, expected) in zip(blended(.multiply, Self.pairs[0], opacity: 0), [204, 128, 51]) {
            XCTAssertEqual(value, expected, accuracy: 1)
        }
    }

    func testDissolveTakesHalfThePixelsAtHalfOpacity() {
        let side = 200
        let top = ToneTestImages.solid(BlendMath.RGB(1, 0, 0), side: side)
        let bottom = ToneTestImages.solid(BlendMath.RGB(0, 0, 1), side: side)
        let result = BlendModes.composite(top, over: bottom, mode: .dissolve, opacity: 0.5, seed: 7)
        let bytes = ToneTestImages.bytes(result, width: side, height: side)
        var fromTop = 0, other = 0
        for index in 0..<(side * side) {
            let r = bytes[index * 4], b = bytes[index * 4 + 2]
            if r > 250 && b < 5 { fromTop += 1 } else if b > 250 && r < 5 { other += 1 }
        }
        XCTAssertEqual(fromTop + other, side * side, "every pixel is one or the other, never a mix")
        XCTAssertEqual(Double(fromTop) / Double(side * side), 0.5, accuracy: 0.05)
        // The same seed gives the same grain.
        let again = ToneTestImages.bytes(BlendModes.composite(top, over: bottom, mode: .dissolve, opacity: 0.5, seed: 7), width: side, height: side)
        XCTAssertEqual(again, bytes)
        // Full opacity takes every pixel.
        let full = ToneTestImages.bytes(BlendModes.composite(top, over: bottom, mode: .dissolve, opacity: 1), width: side, height: side)
        XCTAssertTrue(stride(from: 0, to: full.count, by: 4).allSatisfy { full[$0] > 250 })
    }

    func testALayerSmallerThanTheCanvasLeavesTheRestAlone() {
        let bottom = ToneTestImages.solid(BlendMath.RGB(0.8, 0.5, 0.2), side: 16)
        let top = ToneTestImages.solid(BlendMath.RGB(0.2, 0.6, 0.9), side: 8)
        for mode in BlendMode.allCases {
            let bytes = ToneTestImages.bytes(BlendModes.composite(top, over: bottom, mode: mode), width: 16, height: 16)
            // Top-left in bytes is outside the layer (Core Image's origin is bottom-left).
            XCTAssertEqual(Int(bytes[0]), 204, accuracy: 1, "\(mode)")
            XCTAssertEqual(Int(bytes[1]), 128, accuracy: 1, "\(mode)")
            XCTAssertEqual(Int(bytes[3]), 255, "\(mode): still opaque")
        }
    }
    /// W3 (D6): fill comes before the blend and opacity after, and both scale the same coverage: fill 0.5 equals
    /// opacity 0.5 for every mode, and they multiply.
    func testFillEqualsOpacityForEveryMode() {
        let pair = Self.pairs[1]
        for mode in BlendMode.allCases where mode != .dissolve {
            let source = ToneTestImages.solid(pair.source), backdrop = ToneTestImages.solid(pair.backdrop)
            let byFill = ToneTestImages.bytes(BlendModes.composite(source, over: backdrop, mode: mode, opacity: 1, fill: 0.5), width: 8, height: 8)
            let byOpacity = ToneTestImages.bytes(BlendModes.composite(source, over: backdrop, mode: mode, opacity: 0.5), width: 8, height: 8)
            let both = ToneTestImages.bytes(BlendModes.composite(source, over: backdrop, mode: mode, opacity: 0.5, fill: 0.5), width: 8, height: 8)
            let quarter = ToneTestImages.bytes(BlendModes.composite(source, over: backdrop, mode: mode, opacity: 0.25), width: 8, height: 8)
            for (a, b) in zip(byFill, byOpacity) { XCTAssertEqual(Int(a), Int(b), accuracy: 1, "\(mode): fill 0.5 = opacity 0.5") }
            for (a, b) in zip(both, quarter) { XCTAssertEqual(Int(a), Int(b), accuracy: 1, "\(mode): fill × opacity") }
        }
    }

    /// W3 (D6): over a backdrop that is not opaque, a mode blends where the backdrop is and shows the source where it
    /// is not (W3C compositing), as `BlendMath.compositeRGBA` says.
    func testAModeOverAHalfTransparentBackdropMatchesTheReference() {
        let pair = Self.pairs[0]
        // CIColor takes straight components.
        let backdropColor = CIColor(red: pair.backdrop.r, green: pair.backdrop.g, blue: pair.backdrop.b, alpha: 0.5,
                                    colorSpace: RenderContext.colorSpace) ?? CIColor(red: 0, green: 0, blue: 0)
        let backdrop = CIImage(color: backdropColor).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        for mode in [BlendMode.multiply, .screen, .overlay, .softLight, .difference, .color, .luminosity] {
            let result = BlendModes.composite(ToneTestImages.solid(pair.source), over: backdrop, mode: mode, opacity: 1, backdropIsOpaque: false)
            let bytes = ToneTestImages.bytes(result, width: 8, height: 8)
            let i = (4 * 8 + 4) * 4
            let expected = BlendMath.compositeRGBA(mode, backdrop: pair.backdrop, backdropAlpha: 0.5, source: pair.source, sourceAlpha: 1)
            XCTAssertEqual(Double(bytes[i + 3]) / 255, expected.alpha, accuracy: 1.5 / 255, "\(mode): alpha")
            let a = max(1e-6, Double(bytes[i + 3]) / 255)
            for (value, reference) in zip([bytes[i], bytes[i + 1], bytes[i + 2]], [expected.rgb.r, expected.rgb.g, expected.rgb.b]) {
                XCTAssertEqual(Double(value) / 255 / a, reference, accuracy: 3 / 255, "\(mode): colour")
            }
        }
    }

    /// W3 (D14): dissolve's grain belongs to canvas coordinates, so a strip or a tile of the inputs shows the same
    /// pixels where it overlaps the whole (no seam at strip boundaries).
    func testDissolveGrainFollowsCanvasCoordinates() {
        let side = 128
        let top = ToneTestImages.solid(BlendMath.RGB(1, 0, 0), side: side)
        let bottom = ToneTestImages.solid(BlendMath.RGB(0, 0, 1), side: side)
        let whole = ToneTestImages.bytes(BlendModes.composite(top, over: bottom, mode: .dissolve, opacity: 0.5, seed: 3), width: side, height: side)
        let rect = CGRect(x: 32, y: 40, width: 64, height: 48)
        let part = BlendModes.composite(top.cropped(to: rect), over: bottom.cropped(to: rect), mode: .dissolve, opacity: 0.5, seed: 3)
        guard let bytes = ImageSupport.rgbaBytes(of: part, rect: rect, colorSpace: RenderContext.colorSpace) else { return XCTFail("readback") }
        var differing = 0
        for row in 0..<Int(rect.height) {
            // Top-down row `row` of the part is canvas row (side − maxY + row) of the whole.
            let wholeRow = side - Int(rect.maxY) + row
            for column in 0..<Int(rect.width) {
                let a = (row * Int(rect.width) + column) * 4
                let b = (wholeRow * side + Int(rect.minX) + column) * 4
                if bytes[a] != whole[b] || bytes[a + 2] != whole[b + 2] { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0, "the same grain in the strip and in the whole")
    }
}
#endif
