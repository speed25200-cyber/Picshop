#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PicshopCore
@testable import PicshopImaging

/// D17 image layers from Photos: decoded upright, alpha kept as PNG, downsized under `maxPixels`, opaque pictures as
/// HEIC (JPEG where the runner has no HEVC encoder, with the extension written).
final class ImageLayerImportTests: XCTestCase {
    private func project() throws -> (store: ProjectStore, projectID: UUID, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let projectID = UUID()
        try store.createPackage(for: projectID)
        return (store, projectID, root)
    }

    /// Encoded bytes of top-down premultiplied RGBA8 as `type`, with `properties`.
    private func encoded(_ rgba: [UInt8], width: Int, height: Int, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: RenderContext.colorSpace) else {
            throw PicshopError.renderFailed("fixture")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw PicshopError.renderFailed("fixture")
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PicshopError.renderFailed("fixture") }
        return data as Data
    }

    private func decoded(_ asset: MediaAsset, store: ProjectStore, projectID: UUID) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let image = try ImageSupport.loadCGImage(at: store.url(for: asset.relativePath, in: projectID))
        return (ImageSupport.rgbaBytes(from: image, colorSpace: RenderContext.colorSpace), image.width, image.height)
    }

    func testOrientationIsApplied() throws {
        let (store, projectID, root) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        // Stored 80 × 40: left half red, right half blue; EXIF 6 says "turn 90° clockwise to show".
        let width = 80, height = 40
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = x < width / 2 ? 230 : 20
                rgba[i + 1] = 20
                rgba[i + 2] = x < width / 2 ? 20 : 230
            }
        }
        let data = try encoded(rgba, width: width, height: height, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let asset = try ImageLayerImporter.importImage(data, store: store, projectID: projectID, localIdentifier: "ABC/L0/001")
        XCTAssertEqual(asset.pixelSize, PSSize(width: 40, height: 80), "upright: the turn is applied")
        XCTAssertEqual(asset.origin, .photoLibrary(localIdentifier: "ABC/L0/001"))
        let image = try decoded(asset, store: store, projectID: projectID)
        XCTAssertEqual(image.width, 40)
        // The stored left half is now on top.
        let top = LayerFixtures.pixel(image.bytes, width: image.width, x: 20, y: 10)
        let bottom = LayerFixtures.pixel(image.bytes, width: image.width, x: 20, y: 70)
        XCTAssertGreaterThan(top[0], 180, "red on top")
        XCTAssertGreaterThan(bottom[2], 180, "blue below")
    }

    func testAlphaIsKeptAsPNG() throws {
        let (store, projectID, root) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 32, height = 32
        var rgba = LayerFixtures.solid(0.2, 0.8, 0.3, width: width, height: height)
        for y in 0..<height { for x in (width / 2)..<width { for k in 0..<4 { rgba[(y * width + x) * 4 + k] = 0 } } }
        let data = try encoded(rgba, width: width, height: height, type: .png)
        let asset = try ImageLayerImporter.importImage(data, store: store, projectID: projectID)
        XCTAssertEqual((asset.relativePath as NSString).pathExtension, "png")
        XCTAssertEqual(asset.origin, .file)
        let image = try decoded(asset, store: store, projectID: projectID)
        XCTAssertGreaterThan(LayerFixtures.pixel(image.bytes, width: width, x: 4, y: 16)[3], 250)
        XCTAssertEqual(LayerFixtures.pixel(image.bytes, width: width, x: 28, y: 16)[3], 0, "the transparent half stays transparent")
    }

    func testA60MegapixelPictureIsDownsizedUnderTheLimit() throws {
        let (store, projectID, root) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        // 8,000 × 7,500 = 60 MP, a flat colour (small to encode).
        let url = root.appendingPathComponent("big.jpg")
        let big = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 8_000, height: 7_500))
        try ImageSupport.write(big, to: url, type: .jpeg, quality: 0.8)
        let asset = try ImageLayerImporter.importImage(try Data(contentsOf: url), store: store, projectID: projectID)
        let pixels = asset.pixelSize.width * asset.pixelSize.height
        XCTAssertLessThanOrEqual(pixels, 50_000_000)
        XCTAssertGreaterThan(pixels, 45_000_000, "downsized just enough")
        XCTAssertEqual(asset.pixelSize.width / asset.pixelSize.height, 8_000.0 / 7_500, accuracy: 0.01, "the aspect is kept")
        // A smaller limit, the same way.
        let small = try ImageLayerImporter.importImage(try Data(contentsOf: url), store: store, projectID: projectID, maxPixels: 1_000_000)
        XCTAssertLessThanOrEqual(small.pixelSize.width * small.pixelSize.height, 1_000_000)
    }

    func testAnOpaquePictureIsHEICWhenTheRunnerCanEncodeIt() throws {
        let (store, projectID, root) = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try encoded(LayerFixtures.solid(0.6, 0.4, 0.3, width: 48, height: 32), width: 48, height: 32, type: .jpeg)
        let asset = try ImageLayerImporter.importImage(data, store: store, projectID: projectID)
        let ext = (asset.relativePath as NSString).pathExtension
        XCTAssertEqual(ext, ExportWriters.canEncodeHEIC ? "heic" : "jpg", "the extension written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: asset.relativePath, in: projectID).path))
        let image = try decoded(asset, store: store, projectID: projectID)
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 32)
        let centre = LayerFixtures.pixel(image.bytes, width: 48, x: 24, y: 16)
        XCTAssertEqual(Double(centre[0]), 0.6 * 255, accuracy: 6)
    }
}
#endif
