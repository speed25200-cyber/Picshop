#if canImport(CoreImage) && canImport(Photos) && canImport(ImageIO)
import XCTest
import CoreImage
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import PicshopCore
@testable import PicshopImaging

/// W0 export trust: the original's camera data, date and place survive an export
/// (the place can be removed), pixels are written upright, the colour space is the
/// one chosen, and pictures partly made by a model carry the IPTC mark.
final class ExportMetadataTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var picture: CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 48, height: 32))
    }

    /// A camera-like JPEG: taken 1 June 2024 at 14:22:10 (+02:00) in Paris, held sideways.
    private func cameraFile() throws -> URL {
        let url = directory.appendingPathComponent("camera.jpg")
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:06:01 14:22:10",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
                                             kCGImagePropertyExifFNumber: 1.8],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
                                            kCGImagePropertyGPSAltitude: 35.0, kCGImagePropertyGPSAltitudeRef: 0],
        ]
        try ImageSupport.write(picture, to: url, type: .jpeg, quality: 0.9, properties: properties)
        return url
    }

    private func readProperties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testReadsCaptureDateAndPlace() throws {
        let metadata = PhotoMetadata.read(from: try cameraFile())
        let date = try XCTUnwrap(metadata.captureDate)
        XCTAssertEqual(date.timeIntervalSince1970, 1_717_244_530, accuracy: 0.5, "14:22:10 at +02:00 is 12:22:10 UTC")
        let location = try XCTUnwrap(metadata.location)
        XCTAssertEqual(location.coordinate.latitude, 48.8584, accuracy: 1e-4)
        XCTAssertEqual(location.coordinate.longitude, 2.2945, accuracy: 1e-4)
        XCTAssertEqual(location.altitude, 35, accuracy: 0.01)
    }

    func testSouthAndWestAreNegative() {
        var metadata = PhotoMetadata()
        metadata.gps = [kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S",
                        kCGImagePropertyGPSLongitude: 151.21, kCGImagePropertyGPSLongitudeRef: "W"]
        XCTAssertEqual(metadata.location?.coordinate.latitude ?? 0, -33.86, accuracy: 1e-6)
        XCTAssertEqual(metadata.location?.coordinate.longitude ?? 0, -151.21, accuracy: 1e-6)
    }

    func testDateWithoutOffsetIsLocal() throws {
        let date = try XCTUnwrap(PhotoMetadata.date(exif: "2024:01:02 03:04:05", offset: nil))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2024, 1, 2, 3, 4, 5])
        XCTAssertNil(PhotoMetadata.date(exif: "not a date", offset: "+01:00"))
    }

    func testExportKeepsCameraDataAndDateUprightAndCanDropThePlace() throws {
        let metadata = PhotoMetadata.read(from: try cameraFile())
        let kept = directory.appendingPathComponent("kept.jpg")
        try ImageSupport.write(picture, to: kept, type: .jpeg, properties: metadata.properties(keepingLocation: true, generated: false, withGainMap: false))
        let keptProperties = try readProperties(kept)
        XCTAssertEqual(keptProperties[kCGImagePropertyOrientation] as? Int, 1, "pixels are written upright")
        let exif = try XCTUnwrap(keptProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:06:01 14:22:10")
        let tiff = try XCTUnwrap(keptProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "iPhone 16 Pro")
        XCTAssertNotNil(keptProperties[kCGImagePropertyGPSDictionary])

        let stripped = directory.appendingPathComponent("private.jpg")
        try ImageSupport.write(picture, to: stripped, type: .jpeg, properties: metadata.properties(keepingLocation: false, generated: false, withGainMap: false))
        let strippedProperties = try readProperties(stripped)
        XCTAssertNil(strippedProperties[kCGImagePropertyGPSDictionary], "'Retirer la position' leaves no GPS in the file")
        XCTAssertNotNil(strippedProperties[kCGImagePropertyExifDictionary], "the rest of the camera data stays")
    }

    func testGeneratedPicturesCarryTheIPTCMark() throws {
        let url = directory.appendingPathComponent("generated.jpg")
        try ImageSupport.write(picture, to: url, type: .jpeg, properties: PhotoMetadata().properties(keepingLocation: true, generated: true, withGainMap: false))
        // ImageIO writes it to XMP (Iptc4xmpExt:DigitalSourceType); read it back either way.
        let iptc = try readProperties(url)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap {
            CGImageMetadataCopyStringValueWithPath($0, nil, "\(kCGImageMetadataPrefixIPTCExtension):DigitalSourceType" as CFString) as String?
        }
        let fromIPTC = iptc?[kCGImagePropertyIPTCExtDigitalSourceType] as? String
        let mark = fromIPTC ?? xmp
        XCTAssertEqual(mark, PhotoMetadata.compositeWithTrainedAlgorithmicMedia)
    }

    func testGenerativeEditsAreDetected() {
        let asset = MediaAsset(kind: .image, relativePath: "media/original.jpg", pixelSize: PSSize(width: 100, height: 100))
        var document = PhotoDocument(title: "t", baseImage: asset)
        document.apply(.adjust(.exposure, value: 0.3))
        XCTAssertFalse(PhotoExporter.madeWithGenerativeAI(document))
        document.apply(.expand(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        XCTAssertTrue(PhotoExporter.madeWithGenerativeAI(document))
    }

    func testSRGBExportIsTaggedSRGB() throws {
        let url = directory.appendingPathComponent("web.png")
        try ImageSupport.write(picture, to: url, type: .png, colorSpace: ExportOptions.ColorSpaceChoice.sRGB.cgColorSpace)
        let profile = try readProperties(url)[kCGImagePropertyProfileName] as? String
        XCTAssertTrue(profile?.contains("sRGB") == true, "profile: \(profile ?? "none")")
        let p3 = directory.appendingPathComponent("p3.png")
        try ImageSupport.write(picture, to: p3, type: .png)
        XCTAssertTrue((try readProperties(p3)[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
    }
}
#endif
