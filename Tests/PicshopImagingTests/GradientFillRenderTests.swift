#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D9 gradient fills: the GPU ramp and colour strip against Core's `GradientFill.parameter(at:aspect:)` and
/// `color(at:)` (the shared maths) at 25 points, for every style, with stops' alpha.
final class GradientFillRenderTests: XCTestCase {
    private let width = 160, height = 100

    private func project() throws -> LayerFixtures.Project {
        try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(1, 1, 1, width: width, height: height))
    }

    private func gradients() -> [(String, GradientFill)] {
        let stops = [GradientStop(location: 0, color: PSColor(red: 0.9, green: 0.2, blue: 0.1)),
                     GradientStop(location: 0.4, color: PSColor(red: 0.95, green: 0.85, blue: 0.2)),
                     GradientStop(location: 1, color: PSColor(red: 0.1, green: 0.3, blue: 0.85))]
        return [
            ("linear 90°", GradientFill(style: .linear, stops: stops, angle: 90, dither: false)),
            ("linear 30° scale 60", GradientFill(style: .linear, stops: stops, angle: 30, scale: 60, center: PSPoint(x: 0.4, y: 0.55), dither: false)),
            ("linear reversed, dithered", GradientFill(style: .linear, stops: stops, angle: 0, reverse: true, dither: true)),
            ("radial", GradientFill(style: .radial, stops: stops, angle: 90, scale: 80, center: PSPoint(x: 0.45, y: 0.5), dither: false)),
            ("reflected", GradientFill(style: .reflected, stops: stops, angle: 120, scale: 70, dither: false)),
        ]
    }

    func testEveryStyleMatchesCoresMaths() async throws {
        let fixture = try project()
        defer { fixture.cleanup() }
        let aspect = Double(width) / Double(height)
        var worst = 0.0
        for (name, gradient) in gradients() {
            var document = fixture.document
            document.layers.append(Layer(name: "Dégradé", content: .gradientFill(gradient)))
            let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
            let straight = LayerFixtures.straight(rendered.bytes)
            for row in 0..<5 {
                for column in 0..<5 {
                    let x = (column * 2 + 1) * width / 10, y = (row * 2 + 1) * height / 10
                    let point = PSPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
                    let expected = gradient.color(at: gradient.parameter(at: point, aspect: aspect))
                    let got = LayerFixtures.pixel(straight, width: width, x: x, y: y)
                    for (value, want) in zip(got.prefix(3), [expected.red, expected.green, expected.blue]) {
                        worst = max(worst, abs(Double(value) - want))
                        XCTAssertEqual(Double(value), want, accuracy: 2.5 / 255, "\(name) at \(x),\(y)")
                    }
                }
            }
        }
        print("GRADIENT worst \(worst * 255)/255")
    }

    func testStopAlphaShowsWhatIsBeneath() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(0.2, 0.6, 0.3, width: width, height: height))
        defer { fixture.cleanup() }
        let gradient = GradientFill(style: .linear, stops: [GradientStop(location: 0, color: PSColor(red: 0, green: 0, blue: 0, alpha: 0)),
                                                            GradientStop(location: 1, color: PSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))],
                                    angle: 0, dither: false)
        var document = fixture.document
        document.layers.append(Layer(name: "Dégradé", content: .gradientFill(gradient)))
        let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
        let straight = LayerFixtures.straight(rendered.bytes)
        let aspect = Double(width) / Double(height)
        for x in [8, width / 2, width - 8] {
            let point = PSPoint(x: (Double(x) + 0.5) / Double(width), y: 0.5)
            let colour = gradient.color(at: gradient.parameter(at: point, aspect: aspect))
            // Source-over in gamma-encoded values (D6).
            let expected = [colour.red * colour.alpha + 0.2 * (1 - colour.alpha), colour.green * colour.alpha + 0.6 * (1 - colour.alpha),
                            colour.blue * colour.alpha + 0.3 * (1 - colour.alpha)]
            let got = LayerFixtures.pixel(straight, width: width, x: x, y: height / 2)
            for (value, want) in zip(got.prefix(3), expected) { XCTAssertEqual(Double(value), want, accuracy: 2.5 / 255, "x \(x)") }
        }
    }
}
#endif
