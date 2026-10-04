#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PicshopCore
@testable import PicshopImaging

/// Reading exported files back (the export tests).
enum ExportReadback {
    struct Samples {
        var width: Int
        var height: Int
        var bitsPerComponent: Int
        /// RGB(A) samples as integers, `components` per pixel, in R, G, B order (alpha wherever the file keeps it).
        var values: [Int]
        var components: Int
        /// The offset of red in a pixel (1 when alpha comes first).
        var redOffset: Int
        var alphaOffset: Int?
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return properties
    }

    /// The file's first image, its samples as stored (no colour conversion), byte order resolved.
    static func samples(_ url: URL) -> Samples? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let data = image.dataProvider?.data as Data? else { return nil }
        let bits = image.bitsPerComponent
        let components = image.bitsPerPixel / max(1, bits)
        let alpha = image.alphaInfo
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
        let little = image.bitmapInfo.contains(.byteOrder16Little) || image.bitmapInfo.contains(.byteOrder32Little)
        var values = [Int](repeating: 0, count: image.width * image.height * components)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<image.height {
                for x in 0..<image.width {
                    for c in 0..<components {
                        let index = (y * image.width + x) * components + c
                        if bits == 16 {
                            let offset = y * image.bytesPerRow + (x * components + c) * 2
                            let first = Int(raw[offset]), second = Int(raw[offset + 1])
                            values[index] = little ? first | second << 8 : first << 8 | second
                        } else {
                            values[index] = Int(raw[y * image.bytesPerRow + x * components + c])
                        }
                    }
                }
            }
        }
        return Samples(width: image.width, height: image.height, bitsPerComponent: bits, values: values, components: components,
                       redOffset: alphaFirst && components == 4 ? 1 : 0,
                       alphaOffset: hasAlpha && components == 4 ? (alphaFirst ? 0 : 3) : nil)
    }

    /// The whole render's 16-bit samples (Core Image's byte order resolved), RGBA premultiplied.
    static func values16(_ bytes: [UInt8], bigEndian: Bool) -> [Int] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { i in
            bigEndian ? Int(bytes[i]) << 8 | Int(bytes[i + 1]) : Int(bytes[i]) | Int(bytes[i + 1]) << 8
        }
    }

    /// A source photo carrying EXIF (the metadata an export keeps).
    static func sourceWithMetadata(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source-\(UUID().uuidString).jpg")
        guard let image = ImageSupport.rgbaImage(width: 8, height: 8, bytes: LayerFixtures.solid(0.5, 0.5, 0.5, width: 8, height: 8),
                                                 colorSpace: RenderContext.colorSpace) else { throw PicshopError.renderFailed("source") }
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:06:01 14:22:10", kCGImagePropertyExifLensModel: "Objectif d'essai"]
        try ImageSupport.write(image, to: url, type: .jpeg, quality: 0.9, properties: [kCGImagePropertyExifDictionary: exif])
        return url
    }
}

/// D16: PNG and TIFF at 16 bits per component equal a `.RGBA16` whole render; the ICC profile and the metadata are
/// kept.
final class Export16BitTests: XCTestCase {
    private let width = 96, height = 64

    /// A smooth ramp: 16 bits keep steps 8 bits would merge.
    private func document(_ fixture: LayerFixtures.Project) throws -> PhotoDocument {
        var document = fixture.document
        guard let baseID = document.baseLayerID else { return document }
        document.apply(.adjust(.exposure, value: 0.13), to: baseID)
        document.apply(.toneCurve(ToneCurve(rgb: [ToneCurve.Point(0, 0.02), ToneCurve.Point(0.5, 0.47), ToneCurve.Point(1, 1)])), to: baseID)
        let gradient = GradientFill(style: .linear, stops: [GradientStop(location: 0, color: PSColor(red: 0.2, green: 0.4, blue: 0.9)),
                                                            GradientStop(location: 1, color: PSColor(red: 0.95, green: 0.6, blue: 0.2))],
                                    angle: 0, dither: false)
        document.layers.append(Layer(name: "Dégradé", content: .gradientFill(gradient), opacity: 0.5))
        return document
    }

    private func ramp() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / (width - 1))
                bytes[i + 1] = UInt8(y * 255 / (height - 1))
                bytes[i + 2] = 128
            }
        }
        return bytes
    }

    private func check(_ format: ExportOptions.Format) async throws {
        let fixture = try LayerFixtures.project(width: width, height: height, base: ramp())
        defer { fixture.cleanup() }
        let document = try document(fixture)
        let source = try ExportReadback.sourceWithMetadata(in: fixture.root)
        let url = try await PhotoExporter.export(document, renderer: fixture.renderer,
                                                 options: ExportOptions(format: format, saveToPhotos: false, bitDepth: 16), source: source)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, format.fileExtension)
        let whole = try await fixture.renderer.stripRendered(document, options: .full, bitsPerComponent: 16, rowsPerStrip: nil)
        guard let file = ExportReadback.samples(url) else { return XCTFail("\(format): unreadable") }
        XCTAssertEqual(file.bitsPerComponent, 16, "\(format) keeps 16 bits per component")
        XCTAssertEqual(file.width, whole.width)
        XCTAssertEqual(file.height, whole.height)
        let reference = ExportReadback.values16(whole.bytes, bigEndian: whole.isBigEndian16)
        var worst = 0
        for pixel in 0..<(file.width * file.height) {
            for channel in 0..<3 {
                let got = file.values[pixel * file.components + file.redOffset + channel]
                let want = reference[pixel * 4 + channel]
                worst = max(worst, abs(got - want))
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "\(format): within 2/65535 of the whole render")
        let properties = ExportReadback.properties(url)
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3", "\(format) keeps its ICC profile")
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if format == .tiff {
            XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:06:01 14:22:10", "TIFF keeps the EXIF")
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFCompression] as? Int, ExportWriters.tiffLZW, "LZW")
        } else if exif?[kCGImagePropertyExifDateTimeOriginal] == nil {
            // PNG keeps EXIF through its eXIf chunk on current systems; an older ImageIO drops it silently.
            print("EXPORT16: this ImageIO wrote no EXIF into the PNG")
        }
    }

    func testPNG16() async throws {
        try await check(.png)
    }

    func testTIFF16() async throws {
        try await check(.tiff)
    }

    func testAnUnsupportedDepthFallsBackTo8Bits() {
        XCTAssertEqual(ExportOptions(format: .jpeg, bitDepth: 16).effectiveBitDepth, 8)
        XCTAssertEqual(ExportOptions(format: .heic, bitDepth: 10).effectiveBitDepth, 10)
        XCTAssertEqual(ExportOptions(format: .png, bitDepth: 10).effectiveBitDepth, 8)
        XCTAssertEqual(ExportOptions(format: .psd, bitDepth: 16).effectiveBitDepth, 16)
    }
}
#endif
