#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D4 groups and D5 clipping groups on the GPU, and D6's compositing over a backdrop that is not opaque.
final class GroupClipRenderTests: XCTestCase {
    private let width = 32, height = 24

    private func project(base: (Double, Double, Double) = (1, 1, 1)) throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(base.0, base.1, base.2, width: width, height: height))
    }

    private func solidLayer(_ fixture: LayerFixtures.Project, _ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, name: String = "Layer") throws -> Layer {
        Layer(name: name, content: .image(try fixture.imageAsset(LayerFixtures.solid(r, g, b, alpha: alpha, width: width, height: height), width: width, height: height)))
    }

    private func centre(_ fixture: LayerFixtures.Project, _ document: PhotoDocument) async throws -> [Float] {
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        return LayerFixtures.pixel(LayerFixtures.straight(rendered.bytes), width: rendered.width, x: width / 2, y: height / 2)
    }

    func testAnIsolatedGroupKeepsAMultiplyChildFromItsBackdrop() async throws {
        // Over white (D4's check) and over grey, where a multiply that reached the backdrop would darken it.
        for grey in [1.0, 0.5] {
            let fixture = try project(base: (grey, grey, grey))
            defer { fixture.cleanup() }
            var child = try solidLayer(fixture, 0.8, 0.3, 0.2)
            child.blendMode = .multiply
            var grouped = fixture.document
            let group = Layer(name: "Group", content: .group(LayerFolder(passThrough: false)))
            child.parentID = group.id
            grouped.layers += [child, group]
            var plain = fixture.document
            var normal = child
            normal.parentID = nil
            normal.blendMode = .normal
            plain.layers.append(normal)
            let a = try await centre(fixture, grouped), b = try await centre(fixture, plain)
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1.5 / 255, "base \(grey)") }
            XCTAssertEqual(Double(a[0]), 0.8, accuracy: 2.0 / 255, "base \(grey)")
        }
    }

    func testAPassThroughGroupAtFullOpacityEqualsItsChildrenUngrouped() async throws {
        let fixture = try project(base: (0.6, 0.5, 0.4))
        defer { fixture.cleanup() }
        var first = try solidLayer(fixture, 0.2, 0.7, 0.3, alpha: 0.5)
        var second = try solidLayer(fixture, 0.9, 0.2, 0.6)
        second.blendMode = .overlay
        second.opacity = 0.7
        var ungrouped = fixture.document
        ungrouped.layers += [first, second]
        var grouped = fixture.document
        let group = Layer(name: "Group", content: .group(LayerFolder(passThrough: true)))
        first.parentID = group.id
        second.parentID = group.id
        grouped.layers += [first, second, group]
        let a = try await centre(fixture, grouped), b = try await centre(fixture, ungrouped)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1.5 / 255) }
    }

    func testClippedPixelsTakeTheBaseAlphaAndBlendOntoItsColour() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        document.layers[0].isVisible = false
        document.backgroundColor = .clear
        let b = (0.2, 0.4, 0.8), c = (0.9, 0.6, 0.1)
        let base = try solidLayer(fixture, b.0, b.1, b.2, alpha: 0.5, name: "Base")
        var clipped = try solidLayer(fixture, c.0, c.1, c.2, name: "Clipped")
        clipped.isClipped = true
        clipped.opacity = 0.5
        document.layers += [base, clipped]
        let pixel = try await centre(fixture, document)
        // D5's hand check: alpha 0.5, straight colour (b + c) / 2 (the rejected recipe gives 0.375 and (2c + b) / 3).
        XCTAssertEqual(Double(pixel[3]), 0.5, accuracy: 1.5 / 255)
        XCTAssertEqual(Double(pixel[0]), (b.0 + c.0) / 2, accuracy: 2.5 / 255)
        XCTAssertEqual(Double(pixel[1]), (b.1 + c.1) / 2, accuracy: 2.5 / 255)
        XCTAssertEqual(Double(pixel[2]), (b.2 + c.2) / 2, accuracy: 2.5 / 255)

        // A clipped layer never shows where its base is clear.
        var halfBase = document
        var left = LayerFixtures.solid(0, 0, 0, alpha: 0, width: width, height: height)
        for y in 0..<height { for x in 0..<(width / 2) { left.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 4), with: LayerFixtures.premultipliedPixel(b.0, b.1, b.2, 1)) } }
        halfBase.layers[1].content = .image(try fixture.imageAsset(left, width: width, height: height))
        let rendered = try await fixture.renderer.renderedRGBA(halfBase, options: .full)
        for y in [2, height / 2, height - 3] {
            XCTAssertEqual(LayerFixtures.pixel(rendered.bytes, width: width, x: width - 3, y: y)[3], 0, "clear base, clear clip at y \(y)")
            XCTAssertGreaterThan(LayerFixtures.pixel(rendered.bytes, width: width, x: 3, y: y)[3], 250)
        }
    }

    func testEveryModeOverAHalfTransparentBackdropFollowsTheW3CFormula() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let backdrop = BlendMath.RGB(0.3, 0.6, 0.8), source = BlendMath.RGB(0.7, 0.25, 0.5)
        var worst = 0.0
        for mode in BlendMode.allCases where ![.dissolve, .hardMix, .darkerColor, .lighterColor].contains(mode) {
            for isolated in [false, true] {
                var document = fixture.document
                document.layers[0].isVisible = false
                document.backgroundColor = .clear
                var lower = try solidLayer(fixture, backdrop.r, backdrop.g, backdrop.b, alpha: 0.5)
                var upper = try solidLayer(fixture, source.r, source.g, source.b)
                upper.blendMode = mode
                if isolated {
                    let group = Layer(name: "Group", content: .group(LayerFolder(passThrough: false)))
                    lower.parentID = group.id
                    upper.parentID = group.id
                    document.layers += [lower, upper, group]
                } else {
                    document.layers += [lower, upper]
                }
                let pixel = try await centre(fixture, document)
                let expected = BlendMath.compositeRGBA(mode, backdrop: backdrop, backdropAlpha: 0.5, source: source, sourceAlpha: 1)
                XCTAssertEqual(Double(pixel[3]), expected.alpha, accuracy: 1.5 / 255, "\(mode) alpha")
                for (got, want) in zip(pixel.prefix(3), [expected.rgb.r, expected.rgb.g, expected.rgb.b]) {
                    worst = max(worst, abs(Double(got) - want))
                    XCTAssertEqual(Double(got), want, accuracy: 3.5 / 255, "\(mode) (isolated \(isolated))")
                }
            }
        }
        print("W3C-BACKDROP worst \(worst * 255)/255")
    }

    func testAGroupBaseClipsToItsChildrensComposite() async throws {
        // D5: a group as the clip base; its isolated composite is the base content, its children stay on the canvas.
        let fixture = try project()
        defer { fixture.cleanup() }
        var document = fixture.document
        document.layers[0].isVisible = false
        document.backgroundColor = .clear
        let b = (0.2, 0.4, 0.8), c = (0.9, 0.6, 0.1)
        var left = LayerFixtures.solid(0, 0, 0, alpha: 0, width: width, height: height)
        for y in 0..<height { for x in 0..<(width / 2) { left.replaceSubrange(((y * width + x) * 4)..<((y * width + x) * 4 + 4), with: LayerFixtures.premultipliedPixel(b.0, b.1, b.2, 1)) } }
        let group = Layer(name: "Group", content: .group(LayerFolder(passThrough: false)))
        var child = Layer(name: "Child", content: .image(try fixture.imageAsset(left, width: width, height: height)))
        child.parentID = group.id
        var clipped = try solidLayer(fixture, c.0, c.1, c.2, name: "Clipped")
        clipped.isClipped = true
        clipped.opacity = 0.5
        document.layers += [child, group, clipped]
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        let straight = LayerFixtures.straight(rendered.bytes)
        for y in [2, height / 2, height - 3] {
            let inside = LayerFixtures.pixel(straight, width: width, x: 3, y: y)
            XCTAssertEqual(Double(inside[3]), 1, accuracy: 1.5 / 255, "the group's child is drawn at y \(y)")
            XCTAssertEqual(Double(inside[0]), (b.0 + c.0) / 2, accuracy: 2.5 / 255, "clipped onto the child at y \(y)")
            XCTAssertEqual(Double(inside[1]), (b.1 + c.1) / 2, accuracy: 2.5 / 255)
            XCTAssertEqual(Double(inside[2]), (b.2 + c.2) / 2, accuracy: 2.5 / 255)
            XCTAssertEqual(LayerFixtures.pixel(rendered.bytes, width: width, x: width - 3, y: y)[3], 0, "clear group, clear clip at y \(y)")
        }
    }

    func testAHiddenBaseHidesItsClippedLayers() async throws {
        let fixture = try project(base: (0.5, 0.5, 0.5))
        defer { fixture.cleanup() }
        var document = fixture.document
        var base = try solidLayer(fixture, 0.1, 0.8, 0.1, name: "Base")
        base.isVisible = false
        var clipped = try solidLayer(fixture, 0.9, 0.1, 0.1, name: "Clipped")
        clipped.isClipped = true
        document.layers += [base, clipped]
        let pixel = try await centre(fixture, document)
        XCTAssertEqual(Double(pixel[0]), 0.5, accuracy: 2.0 / 255, "only the photo shows")
        XCTAssertEqual(Double(pixel[1]), 0.5, accuracy: 2.0 / 255)
    }
}
#endif
