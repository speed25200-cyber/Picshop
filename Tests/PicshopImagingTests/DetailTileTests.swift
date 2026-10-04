#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import PicshopCore
@testable import PicshopImaging

/// D14 detail tiles: a tile is a crop of the render at its density, and neighbouring tiles agree on their seam.
final class DetailTileTests: XCTestCase {
    // Dyadic sizes, so normalised regions land on whole pixels exactly.
    private let width = 1024, height = 768

    /// Diagonal stripes and a ramp: every column differs from its neighbour.
    private func pattern() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let stripe = ((x + y) / 7) % 2 == 0
                bytes[i] = UInt8(clamping: x * 255 / width)
                bytes[i + 1] = stripe ? 200 : 60
                bytes[i + 2] = UInt8(clamping: y * 255 / height)
            }
        }
        return bytes
    }

    private func document(_ fixture: LayerFixtures.Project) throws -> PhotoDocument {
        var document = fixture.document
        guard let baseID = document.baseLayerID else { return document }
        document.apply(.adjust(.contrast, value: 0.2), to: baseID)
        document.apply(.sharpen(amount: 0.5), to: baseID)
        let asset = try fixture.imageAsset(LayerFixtures.solid(0.9, 0.6, 0.2, alpha: 0.6, width: 200, height: 150), width: 200, height: 150)
        var layer = Layer(name: "Calque", content: .image(asset), transform: LayerTransform(center: PSPoint(x: 0.45, y: 0.4), scale: 0.6, rotation: 25))
        layer.blendMode = .multiply
        document.layers.append(layer)
        return document
    }

    private func crop(_ bytes: [UInt8], width: Int, x: Int, y: Int, w: Int, h: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(w * h * 4)
        for row in y..<(y + h) {
            let start = (row * width + x) * 4
            out += bytes[start..<(start + w * 4)]
        }
        return out
    }

    func testATileEqualsACropOfTheFullResolutionRender() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: pattern())
        defer { fixture.cleanup() }
        let document = try document(fixture)
        let full = try await fixture.renderer.renderedRGBA(document, options: .full)
        XCTAssertEqual(full.width, width)
        // Columns 256…511, rows 192…383: one source pixel per tile pixel.
        let region = PSRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
        let tile = try await fixture.renderer.detailRGBA(document, region: region, pixelsAcross: 256)
        XCTAssertEqual(tile.width, 256)
        XCTAssertEqual(tile.height, 192)
        let expected = crop(full.bytes, width: full.width, x: 256, y: 192, w: 256, h: 192)
        var worst = 0
        for (a, b) in zip(tile.bytes, expected) { worst = max(worst, abs(Int(a) - Int(b))) }
        XCTAssertLessThanOrEqual(worst, 2, "the tile is the full render's crop")
        // Asked again, the same tile comes from the tile cache.
        let again = try await fixture.renderer.detailRGBA(document, region: region, pixelsAcross: 256)
        XCTAssertEqual(again.bytes, tile.bytes)
    }

    func testATileBelowFullResolutionIsACropOfTheRenderAtItsDensity() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: pattern())
        defer { fixture.cleanup() }
        let document = try document(fixture)
        // 128 pixels over 256 canvas columns: the canvas at half scale (512 × 384).
        let half = try await fixture.renderer.renderedRGBA(document, options: PhotoRenderer.Options(targetLongestSide: 512))
        let tile = try await fixture.renderer.detailRGBA(document, region: PSRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25), pixelsAcross: 128)
        XCTAssertEqual(tile.width, 128)
        XCTAssertEqual(tile.height, 96)
        let expected = crop(half.bytes, width: half.width, x: 256, y: 192, w: 128, h: 96)
        var worst = 0
        for (a, b) in zip(tile.bytes, expected) { worst = max(worst, abs(Int(a) - Int(b))) }
        XCTAssertLessThanOrEqual(worst, 2)
    }

    func testAdjacentTilesShowNoSeam() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: pattern())
        defer { fixture.cleanup() }
        let document = try document(fixture)
        // Left: columns 256…511; right: columns 511…766, so column 511 is in both.
        let left = try await fixture.renderer.detailRGBA(document, region: PSRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25), pixelsAcross: 256)
        let right = try await fixture.renderer.detailRGBA(document, region: PSRect(x: 511.0 / 1024, y: 0.25, width: 0.25, height: 0.25), pixelsAcross: 256)
        XCTAssertEqual(left.height, right.height)
        var worst = 0
        for row in 0..<min(left.height, right.height) {
            for channel in 0..<4 {
                let a = left.bytes[(row * left.width + left.width - 1) * 4 + channel]
                let b = right.bytes[(row * right.width) * 4 + channel]
                worst = max(worst, abs(Int(a) - Int(b)))
            }
        }
        XCTAssertLessThanOrEqual(worst, 1, "the shared column agrees across the seam")
        // A tile above the left one shares its top row the same way (rows 191…382 against 192…383).
        let above = try await fixture.renderer.detailRGBA(document, region: PSRect(x: 0.25, y: 191.0 / 768, width: 0.25, height: 0.25), pixelsAcross: 256)
        var rowWorst = 0
        for column in 0..<min(above.width, left.width) {
            for channel in 0..<4 {
                let a = above.bytes[((1) * above.width + column) * 4 + channel]
                let b = left.bytes[column * 4 + channel]
                rowWorst = max(rowWorst, abs(Int(a) - Int(b)))
            }
        }
        XCTAssertLessThanOrEqual(rowWorst, 1)
    }

    func testAnyDocumentChangeDropsTheTiles() async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: pattern())
        defer { fixture.cleanup() }
        var document = try document(fixture)
        let region = PSRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
        let before = try await fixture.renderer.detailRGBA(document, region: region, pixelsAcross: 256)
        guard let baseID = document.baseLayerID else { return XCTFail("no base") }
        document.apply(.adjust(.exposure, value: 1), to: baseID)
        let after = try await fixture.renderer.detailRGBA(document, region: region, pixelsAcross: 256)
        XCTAssertNotEqual(before.bytes, after.bytes, "a changed document never shows an old tile")
    }
}
#endif
