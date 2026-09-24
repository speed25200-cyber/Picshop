#if canImport(CoreImage) && canImport(ImageIO)
import XCTest
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PicshopImaging

/// What Picshop Live sends Claude: at most 1024 px, and nothing but the pixels.
final class LiveMediaEncoderTests: XCTestCase {
    /// EXIF keys that are only about the picture itself, which ImageIO may add on its own.
    private static let technicalExif: Set<String> = [
        kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String, kCGImagePropertyExifColorSpace as String,
        kCGImagePropertyExifVersion as String, kCGImagePropertyExifFlashPixVersion as String,
    ]

    private func properties(of data: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// A JPEG carrying a camera's metadata: place, time, device and a caption.
    private func taggedJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:14 21:00:00", kCGImagePropertyExifLensModel: "Test Lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestMaker", kCGImagePropertyTIFFModel: "TestPhone"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "A private caption"],
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // The fixture really carries what the encoder must drop.
        let written = try properties(of: data as Data)
        let tiff = written[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "TestMaker")
        return data as Data
    }

    private func assertNoPersonalMetadata(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let properties = try properties(of: data)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String], "GPS survived", file: file, line: line)
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary as String], "IPTC survived", file: file, line: line)
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let extra = Set(exif.keys).subtracting(Self.technicalExif)
            XCTAssertTrue(extra.isEmpty, "EXIF carries \(extra.sorted())", file: file, line: line)
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFArtist] {
                XCTAssertNil(tiff[key as String], "TIFF \(key) survived", file: file, line: line)
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        for marker in ["TestMaker", "TestPhone", "Test Lens", "A private caption", "2026:07:14"] {
            XCTAssertFalse(text.contains(marker), "\(marker) is in the bytes", file: file, line: line)
        }
    }

    func testCIImageIsScaledTo1024AtMost() throws {
        let image = CIImage(color: CIColor(red: 0.9, green: 0.3, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 4032, height: 3024))
        let result = try XCTUnwrap(LiveMediaEncoder.jpeg(from: image, maxPixel: 1024))
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 768)
        let decoded = try decoded(result.data)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1024)
        XCTAssertEqual(decoded.width, result.width)
        XCTAssertEqual(decoded.height, result.height)
    }

    func testPortraitAndOffsetExtentsFit() throws {
        let image = CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.2)).cropped(to: CGRect(x: 120, y: -40, width: 1500, height: 3000))
        let result = try XCTUnwrap(LiveMediaEncoder.jpeg(from: image, maxPixel: 1024))
        XCTAssertEqual(result.height, 1024)
        XCTAssertEqual(result.width, 512)
    }

    func testSmallImagesAreNotUpscaled() throws {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let result = try XCTUnwrap(LiveMediaEncoder.jpeg(from: image, maxPixel: 1024))
        XCTAssertEqual(result.width, 640)
        XCTAssertEqual(result.height, 480)
    }

    func testCGImagePathFitsAndIsSRGB() throws {
        let tagged = try taggedJPEG(width: 2400, height: 1200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let result = try XCTUnwrap(LiveMediaEncoder.jpeg(from: image, maxPixel: 1024, quality: 0.75))
        XCTAssertEqual(result.width, 1024)
        XCTAssertEqual(result.height, 512)
        let decoded = try decoded(result.data)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 1024)
        let name = decoded.colorSpace?.name.map { $0 as String }
        let profile = try properties(of: result.data)[kCGImagePropertyProfileName as String] as? String
        XCTAssertTrue(name == CGColorSpace.sRGB as String || profile?.contains("sRGB") == true, "colour space \(String(describing: name)), profile \(String(describing: profile))")
    }

    func testNoGPSOrEXIFFromATaggedPhoto() throws {
        let tagged = try taggedJPEG(width: 1800, height: 1200)
        // Through the CGImage path.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let fromCG = try XCTUnwrap(LiveMediaEncoder.jpeg(from: image, maxPixel: 1024))
        try assertNoPersonalMetadata(fromCG.data)
        // Through the Core Image path, from an image that knows its file's properties.
        let ciImage = try XCTUnwrap(CIImage(data: tagged, options: [.applyOrientationProperty: true]))
        XCTAssertFalse(ciImage.properties.isEmpty)
        let fromCI = try XCTUnwrap(LiveMediaEncoder.jpeg(from: ciImage, maxPixel: 1024))
        try assertNoPersonalMetadata(fromCI.data)
    }

    func testEmptyInputGivesNothing() {
        XCTAssertNil(LiveMediaEncoder.jpeg(from: CIImage.empty(), maxPixel: 1024))
        XCTAssertNil(LiveMediaEncoder.jpeg(from: CIImage(color: .red), maxPixel: 1024))
    }
}
#endif
