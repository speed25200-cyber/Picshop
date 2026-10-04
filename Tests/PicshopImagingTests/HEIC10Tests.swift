#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import ImageIO
import PicshopCore
@testable import PicshopImaging

/// D16: a 10-bit HEIC export reads back with a depth of 10. Virtualised runners often lack the HEVC encoder, so the
/// test is skipped there (a one-time probe writes a 16 × 16 HEIC); the device sign-off is the HEIC 10 gate.
final class HEIC10Tests: XCTestCase {
    static var canEncodeHEIC: Bool { ExportWriters.canEncodeHEIC }

    func testA10BitHEICReadsBackWithDepth10() async throws {
        try XCTSkipUnless(Self.canEncodeHEIC, "no HEVC encoder on this runner")
        let width = 128, height = 96
        var ramp = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                ramp[i] = UInt8(x * 255 / (width - 1))
                ramp[i + 1] = UInt8(y * 255 / (height - 1))
                ramp[i + 2] = 90
            }
        }
        let fixture = try LayerFixtures.project(width: width, height: height, base: ramp)
        defer { fixture.cleanup() }
        let source = try ExportReadback.sourceWithMetadata(in: fixture.root)
        let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer,
                                                 options: ExportOptions(format: .heic, saveToPhotos: false, bitDepth: 10), source: source)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "heic")
        let properties = ExportReadback.properties(url)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 10)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:06:01 14:22:10", "the metadata is kept")
    }

    func testAn8BitHEICStays8Bits() async throws {
        try XCTSkipUnless(Self.canEncodeHEIC, "no HEVC encoder on this runner")
        let fixture = try LayerFixtures.project(width: 64, height: 48, base: LayerFixtures.solid(0.4, 0.5, 0.6, width: 64, height: 48))
        defer { fixture.cleanup() }
        let url = try await PhotoExporter.export(fixture.document, renderer: fixture.renderer, options: ExportOptions(format: .heic, saveToPhotos: false))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ExportReadback.properties(url)[kCGImagePropertyDepth] as? Int, 8)
    }
}
#endif
