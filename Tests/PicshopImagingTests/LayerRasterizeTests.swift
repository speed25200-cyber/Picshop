#if canImport(CoreImage) && canImport(Metal) && canImport(Photos)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D17: merge down is the two layers' isolated plan (the lower one at full opacity, in normal mode), cropped to their
/// bounds; merge selected keeps every layer's own opacity; a stamp is the visible composite at canvas size.
final class LayerRasterizeTests: XCTestCase {
    private let width = 160, height = 120

    /// The written asset read back (premultiplied RGBA8, Display P3) with its size.
    private func readBack(_ result: LayerRasterResult, _ fixture: LayerFixtures.Project) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let url = fixture.store.url(for: result.asset.relativePath, in: fixture.projectID)
        let image = try ImageSupport.loadCGImage(at: url)
        return (ImageSupport.rgbaBytes(from: image, colorSpace: RenderContext.colorSpace), image.width, image.height)
    }

    private func compare(_ got: [UInt8], _ want: [UInt8], tolerance: Int, _ label: String) {
        XCTAssertEqual(got.count, want.count, label)
        var worst = 0
        for index in stride(from: 0, to: min(got.count, want.count), by: 4) where want[index + 3] >= 26 || got[index + 3] >= 26 {
            for k in 0..<4 { worst = max(worst, abs(Int(got[index + k]) - Int(want[index + k]))) }
        }
        XCTAssertLessThanOrEqual(worst, tolerance, "\(label): worst \(worst)/255")
    }

    func testMergeDownEqualsTheTwoLayerIsolatedPlan() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.9, 0.9, 0.9), (0.2, 0.3, 0.4)], width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        let lowerAsset = try fixture.imageAsset(LayerFixtures.solid(0.8, 0.3, 0.2, alpha: 0.7, width: 64, height: 48), width: 64, height: 48)
        let upperAsset = try fixture.imageAsset(LayerFixtures.solid(0.2, 0.5, 0.9, width: 48, height: 48), width: 48, height: 48)
        var lower = Layer(name: "Bas", content: .image(lowerAsset), transform: LayerTransform(center: PSPoint(x: 0.4, y: 0.45), scale: 0.6, rotation: 10))
        lower.opacity = 0.6
        lower.blendMode = .multiply
        var upper = Layer(name: "Haut", content: .image(upperAsset), transform: LayerTransform(center: PSPoint(x: 0.55, y: 0.55), scale: 0.5, rotation: -20))
        upper.blendMode = .screen
        upper.opacity = 0.8
        upper.maskStack = try fixture.stack(LayerFixtures.rampMask(width: 48, height: 48), width: 48, height: 48)
        document.layers += [lower, upper]

        let result = try await fixture.renderer.rasterize(.layers([lower.id, upper.id]), in: document)
        let got = try readBack(result, fixture)
        XCTAssertLessThan(got.width, width, "cropped to the two layers' bounds")
        XCTAssertEqual(result.asset.pixelSize.width, Double(got.width))

        // The reference: the two layers alone onto transparent, the lower one at 100 % in normal mode.
        var alone = document
        alone.backgroundColor = .clear
        alone.update(layerID: alone.baseLayerID ?? lower.id) { $0.isVisible = false }
        alone.update(layerID: lower.id) {
            $0.opacity = 1
            $0.blendMode = .normal
        }
        let reference = try await fixture.renderer.renderedRGBA(alone, options: .full)
        let x0 = Int((result.opaqueBounds.x * Double(width)).rounded()), y0 = Int((result.opaqueBounds.y * Double(height)).rounded())
        var crop: [UInt8] = []
        for row in y0..<(y0 + got.height) {
            let start = (row * reference.width + x0) * 4
            crop += reference.bytes[start..<(start + got.width * 4)]
        }
        compare(got.bytes, crop, tolerance: 2, "merge down")
    }

    func testMergeSelectedKeepsTheLowestLayersOwnOpacity() async throws {
        // The merged layer is drawn at 100 % in normal mode, so its pixels carry the lowest layer's 50 % (D17).
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(0.9, 0.9, 0.9, width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        let lowerAsset = try fixture.imageAsset(LayerFixtures.solid(0.8, 0.3, 0.2, width: 64, height: 48), width: 64, height: 48)
        let upperAsset = try fixture.imageAsset(LayerFixtures.solid(0.2, 0.5, 0.9, width: 32, height: 32), width: 32, height: 32)
        var lower = Layer(name: "Bas", content: .image(lowerAsset), transform: LayerTransform(center: PSPoint(x: 0.35, y: 0.5), scale: 0.6))
        lower.opacity = 0.5
        let upper = Layer(name: "Haut", content: .image(upperAsset), transform: LayerTransform(center: PSPoint(x: 0.65, y: 0.5), scale: 0.5))
        document.layers += [lower, upper]

        let result = try await fixture.renderer.rasterize(.merged([lower.id, upper.id]), in: document)
        let got = try readBack(result, fixture)
        var alone = document
        alone.backgroundColor = .clear
        alone.update(layerID: alone.baseLayerID ?? lower.id) { $0.isVisible = false }
        let reference = try await fixture.renderer.renderedRGBA(alone, options: .full)
        let x0 = Int((result.opaqueBounds.x * Double(width)).rounded()), y0 = Int((result.opaqueBounds.y * Double(height)).rounded())
        var crop: [UInt8] = []
        for row in y0..<(y0 + got.height) {
            let start = (row * reference.width + x0) * 4
            crop += reference.bytes[start..<(start + got.width * 4)]
        }
        compare(got.bytes, crop, tolerance: 2, "merge selected")
        let bounds = LayerPlacement.bounds(for: lower, contentSize: lowerAsset.pixelSize, canvasSize: document.canvasSize, isBase: false)
        let x = Int(((bounds.x + bounds.width * 0.15) * Double(width)).rounded()) - x0
        XCTAssertEqual(Double(got.bytes[((got.height / 2) * got.width + x) * 4 + 3]), 127.5, accuracy: 8, "the lower layer at 50 %")
    }

    func testAStampEqualsTheVisibleComposite() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height,
                                                base: LayerFixtures.quadrants([(0.7, 0.4, 0.3), (0.3, 0.6, 0.5), (0.4, 0.4, 0.8), (0.9, 0.8, 0.2)], width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.1, 0.8, 0.4, alpha: 0.5, width: 64, height: 64), width: 64, height: 64)
        var layer = Layer(name: "Vert", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.3, y: 0.6), scale: 0.7))
        layer.blendMode = .overlay
        var hidden = Layer(name: "Caché", content: .fill(PSColor(red: 1, green: 0, blue: 0)))
        hidden.isVisible = false
        document.layers += [layer, Layer(name: "Lumière", content: .adjustment(Adjustments([.exposure: 0.2]))), hidden]
        let result = try await fixture.renderer.rasterize(.visible, in: document)
        XCTAssertEqual(result.opaqueBounds, PSRect(x: 0, y: 0, width: 1, height: 1))
        let got = try readBack(result, fixture)
        XCTAssertEqual(got.width, width)
        XCTAssertEqual(got.height, height)
        let composite = try await fixture.renderer.renderedRGBA(document, options: .full)
        compare(got.bytes, composite.bytes, tolerance: 2, "stamp")
    }

    func testApplyingAMaskKeepsTheLayerOwnSizeAndPlace() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: LayerFixtures.solid(1, 1, 1, width: width, height: height))
        defer { fixture.cleanup() }
        var document = fixture.document
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.2, 0.2, width: 40, height: 40), width: 40, height: 40)
        var layer = Layer(name: "Rouge", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.25, y: 0.5), scale: 0.5))
        layer.maskStack = try fixture.stack(LayerFixtures.halfMask(width: 40, height: 40), width: 40, height: 40)
        document.layers.append(layer)
        let result = try await fixture.renderer.rasterize(.layers([layer.id]), in: document)
        let bounds = LayerPlacement.bounds(for: layer, contentSize: asset.pixelSize, canvasSize: document.canvasSize, isBase: false)
        XCTAssertEqual(result.opaqueBounds.x, bounds.x, accuracy: 1.5 / Double(width))
        XCTAssertEqual(result.opaqueBounds.width, bounds.width, accuracy: 2.5 / Double(width))
        let got = try readBack(result, fixture)
        // Left half kept, right half cleared.
        let row = got.height / 2
        XCTAssertGreaterThan(got.bytes[(row * got.width + got.width / 4) * 4 + 3], 240)
        XCTAssertLessThan(got.bytes[(row * got.width + got.width * 3 / 4) * 4 + 3], 15)
    }
}
#endif
