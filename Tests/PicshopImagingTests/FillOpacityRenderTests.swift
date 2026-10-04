#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D6: fill opacity scales the layer's alpha before the blend, opacity mixes the result after; without layer styles
/// they give the same pixels, in every mode, and they multiply.
final class FillOpacityRenderTests: XCTestCase {
    private let width = 24, height = 16

    private func render(_ fixture: LayerFixtures.Project, mode: BlendMode, opacity: Double, fill: Double, layer: MediaAsset) async throws -> [UInt8] {
        var document = fixture.document
        document.layers.append(Layer(name: "Layer", content: .image(layer), opacity: opacity, blendMode: mode, fillOpacity: fill))
        return try await fixture.renderer.renderedRGBA(document, options: .full).bytes
    }

    func testFillEqualsOpacityInEveryMode() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.8, 0.5, 0.2), (0.1, 0.3, 0.9), (0.6, 0.6, 0.6), (0.2, 0.9, 0.4)], width: width, height: height))
        defer { fixture.cleanup() }
        let layer = try fixture.imageAsset(LayerFixtures.quadrants([(0.2, 0.6, 0.9), (0.9, 0.2, 0.3), (0.5, 0.5, 0.1), (0.95, 0.95, 0.95)], width: width, height: height),
                                           width: width, height: height)
        var worst = 0
        for mode in BlendMode.allCases {
            let byFill = try await render(fixture, mode: mode, opacity: 1, fill: 0.5, layer: layer)
            let byOpacity = try await render(fixture, mode: mode, opacity: 0.5, fill: 1, layer: layer)
            XCTAssertEqual(byFill.count, byOpacity.count)
            for (a, b) in zip(byFill, byOpacity) {
                worst = max(worst, abs(Int(a) - Int(b)))
                XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1, "\(mode)")
            }
        }
        print("FILL-OPACITY worst \(worst)/255")
    }

    func testFillAndOpacityMultiply() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(0.7, 0.4, 0.2, width: width, height: height))
        defer { fixture.cleanup() }
        let layer = try fixture.imageAsset(LayerFixtures.solid(0.1, 0.5, 0.9, width: width, height: height), width: width, height: height)
        for mode in [BlendMode.normal, .multiply, .screen, .overlay, .difference] {
            let both = try await render(fixture, mode: mode, opacity: 0.6, fill: 0.5, layer: layer)
            let product = try await render(fixture, mode: mode, opacity: 0.3, fill: 1, layer: layer)
            for (a, b) in zip(both, product) { XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1, "\(mode)") }
        }
        // No fill: the photo as it was.
        let none = try await render(fixture, mode: .normal, opacity: 1, fill: 0, layer: layer)
        XCTAssertEqual(LayerFixtures.pixel(none, width: width, x: 4, y: 4)[0], Int((0.7 * 255).rounded()), accuracy: 1)
    }
}
#endif
