#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PicshopCore

/// D16's raster writers: PNG and TIFF at 8 or 16 bits and JPEG through a CGImage that pulls its rows from the strip
/// renderer (`CGDataProvider(sequentialInfo:callbacks:)`), so the bitmap is never whole in memory; HEIC at 10 bits
/// through `CIContext.writeHEIF10Representation`, which renders internally. Alpha stays premultiplied in the strips;
/// ImageIO writes straight alpha from the CGImage's alpha info (PNG and TIFF keep alpha; JPEG and HEIC are flattened
/// on white before they get here). Metadata from W0's `PhotoMetadata.properties`.
public enum ExportWriters {
    /// TIFF's LZW compression code (kCGImagePropertyTIFFCompression).
    static let tiffLZW = 5

    /// Writes `renderer`'s strips as `type` (PNG, TIFF or JPEG) with `properties` (EXIF, GPS, IPTC…). `quality` for
    /// JPEG; `resolution` (ppi) when given; TIFF is LZW-compressed. Throws on a failed write, rethrows a strip's error
    /// or the task's cancellation.
    static func writeStreamed(_ renderer: StripRenderer, to url: URL, type: UTType, quality: Double?, resolution: Double?,
                              properties: [CFString: Any], progress: ((Double) -> Void)? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PicshopError.exportFailed("cannot create \(url.lastPathComponent)")
        }
        try addStreamed(renderer, to: destination, type: type, quality: quality, resolution: resolution, properties: properties, progress: progress)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw CancellationError() }
            throw PicshopError.exportFailed("cannot write \(url.lastPathComponent)")
        }
    }

    /// Adds the streamed image to an open destination (the PDF writer encodes its JPEG in memory this way).
    static func addStreamed(_ renderer: StripRenderer, to destination: CGImageDestination, type: UTType, quality: Double?, resolution: Double?,
                            properties: [CFString: Any], progress: ((Double) -> Void)? = nil) throws {
        let stream = StripStream(renderer: renderer, progress: progress)
        let image = try stream.makeImage()
        let options = imageProperties(type: type, bitsPerComponent: renderer.bitsPerComponent, quality: quality, resolution: resolution, base: properties)
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        if let error = stream.error { throw error }
    }

    /// The destination properties: the metadata, plus depth, quality, resolution and TIFF's LZW.
    static func imageProperties(type: UTType, bitsPerComponent: Int, quality: Double?, resolution: Double?, base: [CFString: Any]) -> [CFString: Any] {
        var options = base
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        options[kCGImagePropertyDepth] = bitsPerComponent
        if let resolution, resolution > 0 {
            options[kCGImagePropertyDPIWidth] = resolution
            options[kCGImagePropertyDPIHeight] = resolution
        }
        if type == .tiff {
            var tiff = (options[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = tiffLZW
            if let resolution, resolution > 0 {
                tiff[kCGImagePropertyTIFFXResolution] = resolution
                tiff[kCGImagePropertyTIFFYResolution] = resolution
                tiff[kCGImagePropertyTIFFResolutionUnit] = 2
            }
            options[kCGImagePropertyTIFFDictionary] = tiff
        }
        return options
    }

    /// HEIC at 10 bits per component (no gain map in W3), the metadata attached to the image.
    static func writeHEIC10(_ image: CIImage, to url: URL, quality: Double, colorSpace: CGColorSpace, properties: [CFString: Any],
                            context: CIContext = RenderContext.export) throws {
        let metadata = ((properties as NSDictionary) as? [AnyHashable: Any]) ?? [:]
        let tagged = image.settingProperties(metadata)
        var options: [CIImageRepresentationOption: Any] = [:]
        options[CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)] = quality
        try context.writeHEIF10Representation(of: tagged, to: url, colorSpace: colorSpace, options: options)
    }

    /// Whether this machine can encode HEIC (virtualised runners often lack the HEVC encoder): a one-time probe that
    /// writes a 16 × 16 HEIC.
    public static let canEncodeHEIC: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-heic-probe-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = [UInt8](repeating: 128, count: 16 * 16 * 4)
        guard let image = ImageSupport.rgbaImage(width: 16, height: 16, bytes: bytes, colorSpace: RenderContext.colorSpace),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0
    }()
}
#endif
