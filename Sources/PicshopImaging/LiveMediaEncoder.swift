#if canImport(CoreImage) && canImport(ImageIO)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The picture Picshop Live shows Claude: a JPEG in sRGB, its longest side at
/// most `maxPixel`, carrying the pixels and nothing else (no EXIF, GPS, TIFF or
/// IPTC). Synchronous and thread-safe: call it off the main thread.
public enum LiveMediaEncoder {
    public static let defaultQuality = 0.75

    /// Scales the image down (Lanczos) and encodes it.
    public static func jpeg(from image: CIImage, maxPixel: Int, quality: Double = defaultQuality) -> (data: Data, width: Int, height: Int)? {
        let extent = image.extent
        guard maxPixel > 0, !extent.isEmpty, !extent.isInfinite, extent.width.isFinite, extent.height.isFinite else { return nil }
        let size = fittedSize(width: extent.width, height: extent.height, maxPixel: maxPixel)
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var scaled = origin
        let scale = CGFloat(size.height) / extent.height
        if abs(scale - 1) > 0.0001 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = origin
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = Float((CGFloat(size.width) / extent.width) / scale)
            scaled = lanczos.outputImage ?? origin.transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / extent.width, y: scale))
        }
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let cg = RenderContext.export.createCGImage(scaled.clampedToExtent().cropped(to: bounds), from: bounds, format: .RGBA8,
                                                          colorSpace: sRGB, deferred: false) else { return nil }
        return encode(cg, quality: quality)
    }

    /// Redraws the image in sRGB at most `maxPixel` on its longest side, and encodes it.
    public static func jpeg(from image: CGImage, maxPixel: Int, quality: Double = defaultQuality) -> (data: Data, width: Int, height: Int)? {
        guard maxPixel > 0, image.width > 0, image.height > 0 else { return nil }
        let size = fittedSize(width: CGFloat(image.width), height: CGFloat(image.height), maxPixel: maxPixel)
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let redrawn = context.makeImage() else { return nil }
        return encode(redrawn, quality: quality)
    }

    /// Longest side at most `maxPixel`, never upscaled, at least one pixel.
    static func fittedSize(width: CGFloat, height: CGFloat, maxPixel: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        let factor = min(1, CGFloat(maxPixel) / max(1, longest))
        let w = min(maxPixel, max(1, Int((width * factor).rounded())))
        let h = min(maxPixel, max(1, Int((height * factor).rounded())))
        return (w, h)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// JPEG with the compression quality as the only property: nothing about the
    /// device, the place or the time is written.
    private static func encode(_ image: CGImage, quality: Double) -> (data: Data, width: Int, height: Int)? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, image.width, image.height)
    }
}
#endif
