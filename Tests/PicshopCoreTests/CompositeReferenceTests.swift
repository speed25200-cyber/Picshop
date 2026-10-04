import XCTest
@testable import PicshopCore

/// D4, D5, D6, D9 on the CPU reference, against hand-computed pixels and the W3C Compositing formula written out here.
final class CompositeReferenceTests: XCTestCase {
    private let size = 4
    private let a = UUID(), b = UUID(), c = UUID(), g = UUID()

    private func draw(_ id: UUID, opacity: Double = 1, fill: Double = 1, mode: BlendMode = .normal, hasMask: Bool = false) -> LayerDraw {
        LayerDraw(layerID: id, opacity: opacity, fillOpacity: fill, blendMode: mode, hasMask: hasMask)
    }

    private func solid(_ rgb: BlendMath.RGB, _ alpha: Double) -> RGBARaster {
        RGBARaster.filled(width: size, height: size, color: PSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: alpha))
    }

    private func render(_ plan: [CompositeNode], background: PSColor, contents: [UUID: RGBARaster], masks: [UUID: [Float]] = [:],
                        adjust: @escaping (UUID, RGBARaster) -> RGBARaster = { _, raster in raster }) -> RGBARaster {
        CompositeReference.render(plan, width: size, height: size, background: background, content: { contents[$0] }, mask: { masks[$0] },
                                  adjust: adjust)
    }

    private func assertPixel(_ raster: RGBARaster, _ rgb: BlendMath.RGB, _ alpha: Double, accuracy: Double = 1e-6, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let p = raster.pixel(x: 1, y: 2)
        XCTAssertEqual(p.alpha, alpha, accuracy: accuracy, "alpha \(message)", file: file, line: line)
        guard alpha > 0 else { return }
        XCTAssertEqual(p.rgb.r, rgb.r, accuracy: accuracy, "r \(message)", file: file, line: line)
        XCTAssertEqual(p.rgb.g, rgb.g, accuracy: accuracy, "g \(message)", file: file, line: line)
        XCTAssertEqual(p.rgb.b, rgb.b, accuracy: accuracy, "b \(message)", file: file, line: line)
    }

    private let backdrop = BlendMath.RGB(0.2, 0.5, 0.8)
    private let colour = BlendMath.RGB(0.9, 0.3, 0.4)
    private var opaqueBackground: PSColor { PSColor(red: backdrop.r, green: backdrop.g, blue: backdrop.b, alpha: 1) }

    func testTwentySevenModesMatchBlendMathOverAnOpaqueBackdrop() {
        XCTAssertEqual(BlendMode.allCases.count, 27)
        for mode in BlendMode.allCases {
            let alpha = mode == .dissolve ? 1.0 : 0.7
            let result = render([.layer(draw(a, mode: mode))], background: opaqueBackground, contents: [a: solid(colour, alpha)])
            let expected = BlendMath.composite(mode, backdrop: backdrop, source: colour, alpha: alpha)
            assertPixel(result, expected, 1, mode.rawValue)
        }
        // Dissolve at 30 %: about 30 % of the pixels take the source, all or nothing.
        let big = 64
        let result = CompositeReference.render([.layer(draw(a, opacity: 0.3, mode: .dissolve))], width: big, height: big, background: opaqueBackground,
                                               content: { _ in RGBARaster.filled(width: big, height: big, color: .red) }, mask: { _ in nil },
                                               adjust: { _, raster in raster })
        var taken = 0
        for y in 0..<big {
            for x in 0..<big {
                let p = result.pixel(x: x, y: y)
                if p.rgb.r > 0.99 { taken += 1 } else { XCTAssertEqual(p.rgb.b, backdrop.b, accuracy: 1e-6) }
            }
        }
        XCTAssertGreaterThan(taken, big * big / 10)
        XCTAssertLessThan(taken, big * big / 2)
    }

    func testEveryModeOverASemiTransparentBackdropFollowsW3C() {
        let background = PSColor(red: backdrop.r, green: backdrop.g, blue: backdrop.b, alpha: 0.5)
        for mode in BlendMode.allCases where mode != .dissolve {
            let alphaS = 0.6, alphaB = 0.5
            let result = render([.layer(draw(a, mode: mode))], background: background, contents: [a: solid(colour, alphaS)])
            // co = cs·αs·(1 − αb) + cb·αb·(1 − αs) + αs·αb·B(cb, cs); αo = αs + αb·(1 − αs); straight = co / αo.
            let mixed = BlendMath.blend(mode, backdrop: backdrop, source: colour)
            let alphaO = alphaS + alphaB * (1 - alphaS)
            func channel(_ cb: Double, _ cs: Double, _ bx: Double) -> Double { (cs * alphaS * (1 - alphaB) + cb * alphaB * (1 - alphaS) + alphaS * alphaB * bx) / alphaO }
            assertPixel(result, BlendMath.RGB(channel(backdrop.r, colour.r, mixed.r), channel(backdrop.g, colour.g, mixed.g),
                                              channel(backdrop.b, colour.b, mixed.b)), alphaO, mode.rawValue)
        }
        // Over transparent, any mode shows the source as it is.
        for mode in BlendMode.allCases where mode != .dissolve {
            assertPixel(render([.layer(draw(a, mode: mode))], background: .clear, contents: [a: solid(colour, 0.6)]), colour, 0.6, mode.rawValue)
        }
    }

    func testFillEqualsOpacityInEveryModeAndTheyMultiply() {
        for mode in BlendMode.allCases {
            let byFill = render([.layer(draw(a, fill: 0.5, mode: mode))], background: opaqueBackground, contents: [a: solid(colour, 0.8)])
            let byOpacity = render([.layer(draw(a, opacity: 0.5, mode: mode))], background: opaqueBackground, contents: [a: solid(colour, 0.8)])
            XCTAssertEqual(byFill, byOpacity, mode.rawValue)
        }
        let both = render([.layer(draw(a, opacity: 0.4, fill: 0.5, mode: .multiply))], background: opaqueBackground, contents: [a: solid(colour, 1)])
        let product = render([.layer(draw(a, opacity: 0.2, mode: .multiply))], background: opaqueBackground, contents: [a: solid(colour, 1)])
        for (x, y) in zip(both.pixels, product.pixels) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        assertPixel(both, BlendMath.composite(.multiply, backdrop: backdrop, source: colour, alpha: 0.2), 1)
    }

    func testAMultiplyChildInAnIsolatedGroupOverTransparentIsTheChildAlone() {
        let contents = [a: solid(colour, 0.6)]
        let grouped = render([.group(draw(g), passThrough: false, children: [.layer(draw(a, mode: .multiply))])], background: opaqueBackground,
                             contents: contents)
        let alone = render([.layer(draw(a))], background: opaqueBackground, contents: contents)
        XCTAssertEqual(grouped, alone, "isolated: the multiply meets transparency, so the group is the child drawn normally")
        // Pass-through: the multiply reaches the backdrop.
        let through = render([.group(draw(g), passThrough: true, children: [.layer(draw(a, mode: .multiply))])], background: opaqueBackground,
                             contents: contents)
        assertPixel(through, BlendMath.composite(.multiply, backdrop: backdrop, source: colour, alpha: 0.6), 1)
    }

    func testPassThroughAtFullOpacityEqualsUngrouped() {
        let contents = [a: solid(colour, 0.6), b: solid(BlendMath.RGB(0.1, 0.8, 0.3), 0.5)]
        let children: [CompositeNode] = [.layer(draw(a, mode: .multiply)), .layer(draw(b, mode: .screen))]
        let grouped = render([.group(draw(g), passThrough: true, children: children)], background: opaqueBackground, contents: contents)
        let flat = render(children, background: opaqueBackground, contents: contents)
        for (x, y) in zip(grouped.pixels, flat.pixels) { XCTAssertEqual(x, y, accuracy: 1e-6) }
        // At 50 %: halfway between the backdrop and what the children made of it.
        let half = render([.group(draw(g, opacity: 0.5), passThrough: true, children: children)], background: opaqueBackground, contents: contents)
        let made = flat.pixel(x: 1, y: 2).rgb
        assertPixel(half, BlendMath.RGB((backdrop.r + made.r) / 2, (backdrop.g + made.g) / 2, (backdrop.b + made.b) / 2), 1)
    }

    func testAClippingGroupTakesItsBasesAlpha() {
        // αb = 0.5, one 50 % normal clipped layer: alpha 0.5, colour (b + c) / 2 (D5).
        let base = BlendMath.RGB(0.2, 0.4, 0.6)
        let result = render([.clippingGroup(base: draw(a), clipped: [.layer(draw(b, opacity: 0.5))])], background: .clear,
                            contents: [a: solid(base, 0.5), b: solid(colour, 1)])
        assertPixel(result, BlendMath.RGB((base.r + colour.r) / 2, (base.g + colour.g) / 2, (base.b + colour.b) / 2), 0.5)
        // The base's fill limits the group's alpha, its opacity too; a masked base clips by its mask.
        let filled = render([.clippingGroup(base: draw(a, opacity: 0.5, fill: 0.5), clipped: [.layer(draw(b))])], background: .clear,
                            contents: [a: solid(base, 1), b: solid(colour, 1)])
        assertPixel(filled, colour, 0.25)
        let mask = [Float](repeating: 0, count: size * size)
        let masked = render([.clippingGroup(base: draw(a, hasMask: true), clipped: [.layer(draw(b))])], background: opaqueBackground,
                            contents: [a: solid(base, 1), b: solid(colour, 1)], masks: [a: mask])
        assertPixel(masked, backdrop, 1, "a fully masked base shows nothing of its run")
        // A group as the base: its children's composite is the base.
        let groupBase = render([.clippingGroup(base: LayerDraw(layerID: g, opacity: 1, fillOpacity: 1, blendMode: .normal, hasMask: false,
                                                               groupChildren: [.layer(draw(a))]), clipped: [.layer(draw(b, opacity: 0.5))])],
                               background: .clear, contents: [a: solid(base, 0.5), b: solid(colour, 1)])
        assertPixel(groupBase, BlendMath.RGB((base.r + colour.r) / 2, (base.g + colour.g) / 2, (base.b + colour.b) / 2), 0.5)
    }

    func testAnAdjustmentLayerAtHalfOpacityIsHalfway() {
        let invert: (UUID, RGBARaster) -> RGBARaster = { _, raster in
            var out = raster
            for index in stride(from: 0, to: out.pixels.count, by: 4) {
                out.pixels[index] = 1 - out.pixels[index]
                out.pixels[index + 1] = 1 - out.pixels[index + 1]
                out.pixels[index + 2] = 1 - out.pixels[index + 2]
            }
            return out
        }
        let half = render([.adjustment(draw(c, opacity: 0.5))], background: opaqueBackground, contents: [:], adjust: invert)
        assertPixel(half, BlendMath.RGB(0.5, 0.5, 0.5), 1)
        let full = render([.adjustment(draw(c))], background: PSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.4), contents: [:], adjust: invert)
        assertPixel(full, BlendMath.RGB(0.8, 0.5, 0.2), 0.4, "the alpha stays the backdrop's")
        // Fill and a mask scale it the same way.
        let quarter = render([.adjustment(draw(c, opacity: 0.5, fill: 0.5))], background: opaqueBackground, contents: [:], adjust: invert)
        assertPixel(quarter, BlendMath.RGB(0.2 + 0.6 * 0.25, 0.5, 0.8 - 0.6 * 0.25), 1)
        let masked = render([.adjustment(draw(c, hasMask: true))], background: opaqueBackground, contents: [:],
                            masks: [c: [Float](repeating: 0.5, count: size * size)], adjust: invert)
        assertPixel(masked, BlendMath.RGB(0.5, 0.5, 0.5), 1)
    }

    func testDissolveNoiseIsDeterministicAndPositional() {
        let seed = CompositeReference.dissolveSeed(for: a)
        XCTAssertEqual(CompositeReference.dissolveNoise(seed: seed, x: 10, y: 20), CompositeReference.dissolveNoise(seed: seed, x: 10, y: 20))
        XCTAssertNotEqual(CompositeReference.dissolveNoise(seed: seed, x: 10, y: 20), CompositeReference.dissolveNoise(seed: seed, x: 11, y: 20))
        let values = (0..<1000).map { CompositeReference.dissolveNoise(seed: seed, x: $0, y: 3) }
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 < 1 })
        let mean = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.1)
        XCTAssertEqual(CompositeReference.dissolveSeed(for: UUID(uuidString: "01020304-0506-0708-0000-000000000000")!), 0x0102_0304_0506_0708)
    }
}
