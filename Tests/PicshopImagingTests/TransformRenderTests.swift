#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D10 on the GPU: a layer's corners land where `LayerPlacement.quad` says, for every kind of transform; the base never
/// moves; and after the base is cropped and turned, a layer via copy of it still lies on it pixel for pixel (D10b).
final class TransformRenderTests: XCTestCase {
    private let width = 240, height = 180
    private let contentWidth = 60, contentHeight = 40

    private func transforms() -> [(String, LayerTransform)] {
        [
            ("uniform", LayerTransform(center: PSPoint(x: 0.45, y: 0.55), scale: 1.4, rotation: 20)),
            ("non-uniform", LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1, scaleX: 2, scaleY: 0.7)),
            ("skew", LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: 1.2, rotation: -10, skewX: 20)),
            ("flipped", LayerTransform(center: PSPoint(x: 0.6, y: 0.4), scale: 1.1, rotation: 35, isFlippedHorizontally: true)),
            ("quad", LayerTransform(quad: [PSPoint(x: 0.2, y: 0.25), PSPoint(x: 0.75, y: 0.15), PSPoint(x: 0.8, y: 0.8), PSPoint(x: 0.3, y: 0.7)])),
        ]
    }

    /// Whether the red layer covers (x, y) (straight values, red > 0.5 and green < 0.5).
    private func isLayer(_ values: [Float], x: Double, y: Double) -> Bool {
        let px = Int(x.rounded(.down)), py = Int(y.rounded(.down))
        guard px >= 0, py >= 0, px < width, py < height else { return false }
        let p = LayerFixtures.pixel(values, width: width, x: px, y: py)
        return p[0] > 0.5 && p[1] < 0.5
    }

    func testCornersLandOnThePlacementQuad() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(1, 1, 1, width: width, height: height))
        defer { fixture.cleanup() }
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.1, 0.1, width: contentWidth, height: contentHeight), width: contentWidth, height: contentHeight)
        for (name, transform) in transforms() {
            var document = fixture.document
            let layer = Layer(name: name, content: .image(asset), transform: transform)
            document.layers.append(layer)
            let rendered = try await fixture.renderer.renderedRGBA(document, options: .full)
            let values = LayerFixtures.straight(rendered.bytes)
            let quad = LayerPlacement.quad(for: layer, contentSize: asset.pixelSize, canvasSize: document.canvasSize, isBase: false)
                .map { PSPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
            let centre = PSPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)
            for (index, corner) in quad.enumerated() {
                let dx = centre.x - corner.x, dy = centre.y - corner.y
                let length = max(1e-9, (dx * dx + dy * dy).squareRoot())
                let ux = dx / length, uy = dy / length
                // 1.5 px inside the corner is the layer; 1.5 px outside is not (within 1 px of the quad).
                XCTAssertTrue(isLayer(values, x: corner.x + 2.5 * ux, y: corner.y + 2.5 * uy), "\(name) corner \(index) inside")
                XCTAssertFalse(isLayer(values, x: corner.x - 1.5 * ux, y: corner.y - 1.5 * uy), "\(name) corner \(index) outside")
            }
            // The base is untouched where the layer is not: the canvas's corners stay white.
            for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] where !isLayer(values, x: Double(x), y: Double(y)) {
                let p = LayerFixtures.pixel(values, width: width, x: x, y: y)
                XCTAssertEqual(Double(p[0]), 1, accuracy: 1.5 / 255, "\(name) base at \(x),\(y)")
                XCTAssertEqual(Double(p[1]), 1, accuracy: 1.5 / 255, "\(name) base at \(x),\(y)")
            }
            XCTAssertEqual(rendered.width, width, "the base defines the canvas")
        }
    }

    /// A checkerboard of 12-px squares, two colours.
    private func checker(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let even = ((x / 12) + (y / 12)) % 2 == 0
                let pixel = even ? LayerFixtures.premultipliedPixel(0.85, 0.3, 0.2, 1) : LayerFixtures.premultipliedPixel(0.15, 0.4, 0.8, 1)
                for k in 0..<4 { bytes[(y * width + x) * 4 + k] = pixel[k] }
            }
        }
        return bytes
    }

    func testAViaCopyLayerFollowsACropAndAQuarterTurnOfThePhoto() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: checker(width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        let region = try fixture.stack([UInt8](repeating: 255, count: width * height), width: width, height: height)
        let made = document.applyStructureEdit(.viaCopy(source: baseID, region: region, name: "Copie"))
        guard case .applied = made.outcome, let copyID = made.layerID else { return XCTFail("via copy: \(made.outcome)") }
        // A 4:5 crop and a quarter turn of the photo: the copy follows it (D10b).
        // 0.54 × 240 = 129.6 px by 0.9 × 180 = 162 px: 4:5.
        document.apply(.crop(PSRect(x: 0.2, y: 0.05, width: 0.54, height: 0.9)), to: baseID)
        document.apply(.rotate(degrees: 90), to: baseID)
        var hidden = document
        hidden.update(layerID: copyID) { $0.isVisible = false }
        let withCopy = try await fixture.renderer.renderedRGBA(document, options: .full)
        let photoOnly = try await fixture.renderer.renderedRGBA(hidden, options: .full)
        XCTAssertEqual(withCopy.width, photoOnly.width)
        XCTAssertEqual(withCopy.height, photoOnly.height)
        var worst = 0
        for (a, b) in zip(withCopy.bytes, photoOnly.bytes) { worst = max(worst, abs(Int(a) - Int(b))) }
        XCTAssertLessThanOrEqual(worst, 2, "the copy lies on the photo")
        // And it really is drawn: hiding the photo leaves the copy's checkerboard.
        var copyOnly = document
        copyOnly.update(layerID: baseID) { $0.isVisible = false }
        let alone = try await fixture.renderer.renderedRGBA(copyOnly, options: .full)
        var close = 0
        for index in stride(from: 0, to: min(alone.bytes.count, photoOnly.bytes.count), by: 4) where abs(Int(alone.bytes[index]) - Int(photoOnly.bytes[index])) <= 2 {
            close += 1
        }
        XCTAssertGreaterThan(Double(close) / Double(alone.width * alone.height), 0.97)
    }
}
#endif
