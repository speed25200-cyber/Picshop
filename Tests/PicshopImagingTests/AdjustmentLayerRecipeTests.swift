#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D9: an adjustment layer carries any develop recipe in its own edits (curves, levels, the HSL mixer, a LUT, a look),
/// drawn by the image layer's own develop step (DevelopRenderer) on everything beneath, through its mask.
final class AdjustmentLayerRecipeTests: XCTestCase {
    private let width = 48, height = 32

    /// A colourful photo: a saturated red, a mid grey, a blue and a skin-ish orange.
    private func project() throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height,
                                  base: LayerFixtures.quadrants([(0.85, 0.15, 0.12), (0.5, 0.5, 0.5), (0.15, 0.3, 0.85), (0.85, 0.55, 0.35)], width: width, height: height))
    }

    /// A small .cube that swaps red and blue.
    private func swapLUT(_ fixture: LayerFixtures.Project) throws -> LUTReference {
        var lines = ["TITLE \"swap\"", "LUT_3D_SIZE 2"]
        for b in 0...1 { for g in 0...1 { for r in 0...1 { lines.append("\(b) \(g) \(r)") } } }
        let path = "media/lut-swap.cube"
        try lines.joined(separator: "\n").write(to: fixture.store.url(for: path, in: fixture.projectID), atomically: true, encoding: .utf8)
        return LUTReference(relativePath: path, title: "swap")
    }

    private func recipes(_ fixture: LayerFixtures.Project) throws -> [(String, AdjustmentLayerKind, EditStack)] {
        var curves = EditStack()
        curves.append(.toneCurve(ToneCurve(rgb: [ToneCurve.Point(0, 0.1), ToneCurve.Point(0.5, 0.75), ToneCurve.Point(1, 1)])))
        var levels = EditStack()
        levels.append(.levels(Levels(rgb: Levels.Channel(inBlack: 0.15, inWhite: 0.75, gamma: 1.4))))
        var hsl = EditStack()
        hsl.append(.colorMixer(ColorMixer(saturation: [-1])))
        var lut = EditStack()
        lut.append(.lut(try swapLUT(fixture)))
        var look = EditStack()
        look.append(.look(.dramaticCool, intensity: 1))
        return [("curves", .curves, curves), ("levels", .levels, levels), ("hsl", .hsl, hsl), ("lut", .lut, lut), ("look", .look, look)]
    }

    func testEachRecipeChangesOnlyTheMaskedRegion() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let before = try await fixture.renderer.renderedRGBA(fixture.document, options: .full)
        let mask = try fixture.stack(LayerFixtures.halfMask(width: width, height: height), width: width, height: height)
        for (name, kind, edits) in try recipes(fixture) {
            var document = fixture.document
            document.layers.append(Layer(name: kind.frenchName, content: .adjustment(.neutral), edits: edits, maskStack: mask, recipeKind: kind))
            let after = try await fixture.renderer.renderedRGBA(document, options: .full)
            // Right half (outside the mask): as it was.
            for y in [3, height - 4] {
                for x in [width / 2 + 3, width - 4] {
                    let a = LayerFixtures.pixel(after.bytes, width: width, x: x, y: y), b = LayerFixtures.pixel(before.bytes, width: width, x: x, y: y)
                    for k in 0..<3 { XCTAssertEqual(a[k], b[k], accuracy: 1, "\(name) outside at \(x),\(y)") }
                }
            }
            // Left half: changed somewhere (the red top-left quadrant reacts to every recipe here).
            let a = LayerFixtures.pixel(after.bytes, width: width, x: 4, y: 4), b = LayerFixtures.pixel(before.bytes, width: width, x: 4, y: 4)
            XCTAssertGreaterThan(zip(a.prefix(3), b.prefix(3)).map { abs($0 - $1) }.max() ?? 0, 6, "\(name) inside")
        }
    }

    func testAnAdjustmentLayerAtZeroOpacityIsTheIdentity() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let before = try await fixture.renderer.renderedRGBA(fixture.document, options: .full)
        for (name, kind, edits) in try recipes(fixture) {
            var document = fixture.document
            document.layers.append(Layer(name: kind.frenchName, content: .adjustment(Adjustments([.exposure: 0.4])), opacity: 0, edits: edits, recipeKind: kind))
            let after = try await fixture.renderer.renderedRGBA(document, options: .full)
            for (a, b) in zip(after.bytes, before.bytes) { XCTAssertEqual(Int(a), Int(b), accuracy: 1, name) }
        }
    }

    func testTheLightKindKeepsItsDialsInItsContent() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let before = try await fixture.renderer.renderedRGBA(fixture.document, options: .full)
        var document = fixture.document
        document.layers.append(Layer(name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.5])), recipeKind: .light))
        let after = try await fixture.renderer.renderedRGBA(document, options: .full)
        // The grey quadrant brightens.
        XCTAssertGreaterThan(LayerFixtures.pixel(after.bytes, width: width, x: width - 4, y: 4)[0],
                             LayerFixtures.pixel(before.bytes, width: width, x: width - 4, y: 4)[0] + 20)
        // A parameter the stack sets wins over the content's (D9: the content's dials sit under the edits').
        var edits = EditStack()
        edits.append(.adjust(.exposure, value: 0))
        document.layers[1].edits = edits
        let overridden = try await fixture.renderer.renderedRGBA(document, options: .full)
        XCTAssertEqual(LayerFixtures.pixel(overridden.bytes, width: width, x: width - 4, y: 4)[0],
                       LayerFixtures.pixel(before.bytes, width: width, x: width - 4, y: 4)[0], accuracy: 1)
    }
}
#endif
