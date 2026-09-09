#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import Metal
import ImageIO
import UniformTypeIdentifiers
import PicshopCore
#if canImport(UIKit)
import UIKit
#endif

/// Shared Core Image context bound to the system Metal device. Creating
/// contexts is expensive; every renderer in the app goes through this one.
public enum RenderContext {
    public static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? CGColorSpaceCreateDeviceRGB()

    public static let shared: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: true,
            .highQualityDownsample: true,
            .name: "Picshop",
        ]
        if #available(iOS 17.0, macOS 14.0, *) {
            options[.allowLowPower] = false
        }
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Whether `CIContext.render(_:toBitmap:…)` writes the top image row first.
    /// Probed once at runtime so mask/bitmap code never relies on an assumption.
    public static let bitmapIsTopDown: Bool = {
        // 1×2 image: top pixel white, bottom pixel black.
        var pixels: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255]
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent) else { return true }
        let image = CIImage(cgImage: cg)
        var out = [UInt8](repeating: 0, count: 8)
        out.withUnsafeMutableBytes { buffer in
            shared.render(image, toBitmap: buffer.baseAddress!, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 2), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        pixels = out
        return pixels[0] > 127
    }()

    /// A context tuned for offline exports (no intermediate caching).
    public static let export: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
}

public enum ImageSupport {
    /// Loads an image with EXIF orientation baked in.
    public static func loadCIImage(at url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw PicshopError.mediaUnavailable(url.lastPathComponent)
        }
        return image
    }

    /// Loads a CGImage, optionally downsampled so its longest side is at most `maxPixelSize`.
    public static func loadCGImage(at url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PicshopError.mediaUnavailable(url.lastPathComponent)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PicshopError.mediaUnavailable(url.lastPathComponent)
        }
        return image
    }

    /// Reads pixel dimensions without decoding the image.
    public static func pixelSize(at url: URL) -> PSSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return PSSize(width: height, height: width)
        default:
            return PSSize(width: width, height: height)
        }
    }

    /// Rasterises a `CIImage` into a `CGImage`.
    ///
    /// Goes through `render(toBitmap:)` plus the `bitmapIsTopDown` probe — the one
    /// path whose orientation is verified on device by the inpainting composite —
    /// so thumbnails, exports, the Vision analysis image and model outputs all share
    /// the canvas's orientation. Very large images fall back to `createCGImage`
    /// to avoid a second full-size copy in memory.
    public static func cgImage(from image: CIImage, context: CIContext = RenderContext.shared) -> CGImage? {
        let extent = image.extent.integral
        guard !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        if width * height <= 24_000_000 {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: RenderContext.colorSpace)
            }
            if !RenderContext.bitmapIsTopDown { bytes = MaskStore.flippedVertically(bytes, width: width * 4, height: height) }
            return rgbaImage(width: width, height: height, bytes: bytes, colorSpace: RenderContext.colorSpace)
        }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: RenderContext.colorSpace)
    }

    /// Writes a CGImage as JPEG/PNG/HEIC.
    public static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.92) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PicshopError.exportFailed("cannot create \(url.lastPathComponent)")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PicshopError.exportFailed("cannot write \(url.lastPathComponent)")
        }
    }

    /// Writes a CIImage. The image is rasterised through `createCGImage` — the same
    /// path the canvas uses — so files and previews are guaranteed to match
    /// (orientation, colour space, alpha).
    public static func write(_ image: CIImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.92, context: CIContext = RenderContext.export) throws {
        guard let cg = cgImage(from: image, context: context) else {
            throw PicshopError.exportFailed("cannot rasterise \(url.lastPathComponent)")
        }
        try write(cg, to: url, type: type, quality: quality)
    }

    /// Creates a single-channel 8-bit grayscale CGImage from raw bytes.
    public static func grayImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage? {
        guard bytes.count >= width * height else { return nil }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Extracts 8-bit gray bytes from any CGImage (converted to gray if needed).
    public static func grayBytes(from image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Extracts interleaved RGBA8 bytes (premultiplied) from a CGImage.
    public static func rgbaBytes(from image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Builds an RGBA8 CGImage from interleaved bytes.
    public static func rgbaImage(width: Int, height: Int, bytes: [UInt8], colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) -> CGImage? {
        guard bytes.count >= width * height * 4 else { return nil }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Resamples a CGImage to the given pixel size with high quality.
    public static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast
        let space = image.colorSpace?.model == .monochrome ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.colorSpace?.model == .monochrome ? CGImageAlphaInfo.none.rawValue : (hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Geometry bridging

public extension PSRect {
    /// Converts a normalised top-left-origin rect into a pixel rect in Core Image's bottom-left space.
    func ciRect(in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + minX * extent.width,
               y: extent.minY + (1 - maxY) * extent.height,
               width: width * extent.width,
               height: height * extent.height)
    }

    /// Converts from a Vision/Core Image bottom-left normalised rect.
    static func fromVision(_ rect: CGRect) -> PSRect {
        PSRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height).clampedToUnit()
    }

    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

public extension PSPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
}

public extension PSSize {
    var cgSize: CGSize { CGSize(width: width, height: height) }
    init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
}

public extension PSColor {
    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: RenderContext.colorSpace) ?? CIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { CGColor(colorSpace: RenderContext.colorSpace, components: [red, green, blue, alpha]) ?? CGColor(red: red, green: green, blue: blue, alpha: alpha) }
}
#endif
