#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// An adjustment layer changes what is beneath it through its mask, opacity and blend mode,
/// not the whole canvas.
final class AdjustmentLayerTests: XCTestCase {
    private let width = 64, height = 32

    /// A mask whose left half is selected.
    private func leftHalfMask(store: ProjectStore, projectID: UUID) throws -> MaskReference {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<(width / 2) { bytes[y * width + x] = 255 } }
        return try MaskStore(store: store, projectID: projectID).save(bytes: bytes, width: width, height: height, source: .brush, feather: 0)
    }

    private func pixel(_ bytes: [UInt8], x: Int, y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }

    func testAMaskedAdjustmentLayerChangesOnlyItsHalf() async throws {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(100, width: width, height: height), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let before = try await fixture.renderer.renderedRGBA(document)
        let mask = try leftHalfMask(store: fixture.store, projectID: fixture.projectID)
        document.addLayer(Layer(name: "Brighter", content: .adjustment(Adjustments([.exposure: 0.5])), mask: mask))
        let after = try await fixture.renderer.renderedRGBA(document)
        XCTAssertEqual(after.width, width)
        for y in [2, height / 2, height - 3] {
            // Right half: as it was (ΔE well under 0.5 means at most a rounding step here).
            for x in [width / 2 + 2, width - 3] {
                for (a, b) in zip(pixel(after.bytes, x: x, y: y), pixel(before.bytes, x: x, y: y)) { XCTAssertEqual(a, b, accuracy: 1, "right half at \(x),\(y)") }
            }
            // Left half: brighter.
            XCTAssertGreaterThan(pixel(after.bytes, x: 4, y: y)[0], pixel(before.bytes, x: 4, y: y)[0] + 20, "left half at \(y)")
        }
    }

    func testOpacityAndBlendModeApplyToAnAdjustmentLayer() async throws {
        let fixture = try ToneTestImages.project(rgba: ToneTestImages.grey(100, width: width, height: height), width: width, height: height)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var document = fixture.document
        let before = try await fixture.renderer.renderedRGBA(document)
        let layer = Layer(name: "Brighter", content: .adjustment(Adjustments([.exposure: 0.5])), opacity: 0)
        document.addLayer(layer)
        let hidden = try await fixture.renderer.renderedRGBA(document)
        XCTAssertEqual(pixel(hidden.bytes, x: 10, y: 10), pixel(before.bytes, x: 10, y: 10), "at 0 % it changes nothing")
        document.update(layerID: layer.id) { $0.opacity = 1 }
        let full = try await fixture.renderer.renderedRGBA(document)
        document.update(layerID: layer.id) { $0.opacity = 0.5 }
        let half = try await fixture.renderer.renderedRGBA(document)
        let b = pixel(before.bytes, x: 10, y: 10)[0], f = pixel(full.bytes, x: 10, y: 10)[0], h = pixel(half.bytes, x: 10, y: 10)[0]
        XCTAssertGreaterThan(h, b)
        XCTAssertLessThan(h, f)
        // Darken with a brighter version of the same picture changes nothing.
        document.update(layerID: layer.id) { $0.opacity = 1; $0.blendMode = .darken }
        let darkened = try await fixture.renderer.renderedRGBA(document)
        XCTAssertEqual(pixel(darkened.bytes, x: 10, y: 10)[0], b, accuracy: 1)
    }
}
#endif
