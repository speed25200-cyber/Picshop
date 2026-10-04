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

    /// Gray space masks are read in: linear like the working space, so a soft edge
    /// reads the value Core Image blends with.
    public static let maskColorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()

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

    /// The canvas's context, and nothing else draws through it: its cached
    /// intermediates (the settled picture) survive whatever runs in the background,
    /// so a pan or a zoom replays nothing.
    public static let interactive: CIContext = make(name: "Picshop.canvas", cacheIntermediates: true, lowPriority: false)

    /// Readbacks and analysis off the canvas (masks, thumbnails, Vision inputs, the
    /// ambient wash, the histogram): low GPU priority, so a canvas frame goes first,
    /// and no intermediate cache, so they never evict the canvas's.
    public static let background: CIContext = make(name: "Picshop.background", cacheIntermediates: false, lowPriority: true)

    /// The options a context is made with, kept so tests can check them.
    public static func options(name: String, cacheIntermediates: Bool, lowPriority: Bool) -> [CIContextOption: Any] {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: cacheIntermediates,
            .highQualityDownsample: true,
            .name: name,
        ]
        if lowPriority { options[.priorityRequestLow] = true }
        return options
    }

    private static func make(name: String, cacheIntermediates: Bool, lowPriority: Bool) -> CIContext {
        let settings = Self.options(name: name, cacheIntermediates: cacheIntermediates, lowPriority: lowPriority)
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: settings)
        }
        return CIContext(options: settings)
    }

    /// Drops every context's caches (memory warning, model load).
    public static func clearAllCaches() {
        shared.clearCaches()
        interactive.clearCaches()
        background.clearCaches()
        export.clearCaches()
    }
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

    /// W3 (D14): whether an export pass decodes this source once, eagerly, into an 8-bit bitmap: an 8-bit JPEG or
    /// PNG, which Core Image would otherwise decode whole for every strip. HEIC (tiled decode), RAW and deeper files
    /// stay lazy, at their full precision.
    public static func decodesEagerly(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? else { return false }
        guard type == UTType.jpeg.identifier || type == UTType.png.identifier else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let depth = (properties?[kCGImagePropertyDepth] as? Int) ?? 8
        return depth <= 8
    }

    /// Whether the file carries a depth or disparity map (Portrait photos).
    public static func hasDepthData(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth) != nil
    }

    /// Whether the file carries Apple's HDR gain map (iPhone HDR photos): exported as
    /// HEIC, the edit keeps it and stays as bright as the original.
    public static func hasHDRGainMap(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
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

    /// Rasterises `rect` of a `CIImage` (default: its extent) into a `CGImage`.
    ///
    /// Always `createCGImage`, rendered eagerly: upright by contract (the first row
    /// is the rect's top edge, maxY) at every size, with no runtime probe.
    public static func cgImage(from image: CIImage, rect: CGRect? = nil, colorSpace: CGColorSpace = RenderContext.colorSpace, context: CIContext = RenderContext.background) -> CGImage? {
        guard let bounds = pixelBounds(rect ?? image.extent) else { return nil }
        return context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace, deferred: false)
    }

    /// Top-down RGBA8 bytes (premultiplied) of `rect` (default: the extent): row 0 is the
    /// top edge. Read in `colorSpace`; `ciImage(rgba:…)` in the same space gives the image back.
    public static func rgbaBytes(of image: CIImage, rect: CGRect? = nil, colorSpace: CGColorSpace = RenderContext.colorSpace, context: CIContext = RenderContext.background) -> [UInt8]? {
        cgImage(from: image, rect: rect, colorSpace: colorSpace, context: context).map { rgbaBytes(from: $0, colorSpace: colorSpace) }
    }

    /// Top-down 8-bit gray bytes of `rect` (default: the extent): row 0 is the top edge.
    /// Read in `colorSpace`; `ciImage(gray:…)` in the same space gives the image back.
    public static func grayBytes(of image: CIImage, rect: CGRect? = nil, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceGray(), context: CIContext = RenderContext.background) -> [UInt8]? {
        guard let bounds = pixelBounds(rect ?? image.extent),
              let cg = context.createCGImage(image, from: bounds, format: .L8, colorSpace: colorSpace, deferred: false) else { return nil }
        return grayBytes(from: cg, colorSpace: colorSpace)
    }

    /// Top-down RGBA8 bytes as a `CIImage` at the origin, in `colorSpace`.
    public static func ciImage(rgba bytes: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace = RenderContext.colorSpace) -> CIImage? {
        rgbaImage(width: width, height: height, bytes: bytes, colorSpace: colorSpace).map { CIImage(cgImage: $0) }
    }

    /// Top-down 8-bit gray bytes as a `CIImage` at the origin, in `colorSpace`.
    public static func ciImage(gray bytes: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceGray()) -> CIImage? {
        grayImage(width: width, height: height, bytes: bytes, colorSpace: colorSpace).map { CIImage(cgImage: $0) }
    }

    private static func pixelBounds(_ rect: CGRect) -> CGRect? {
        let bounds = rect.integral
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        return bounds
    }

    /// Writes a CGImage as JPEG/PNG/HEIC, with `properties` (EXIF, GPS, IPTC…) as its metadata.
    public static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.92, properties: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PicshopError.exportFailed("cannot create \(url.lastPathComponent)")
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PicshopError.exportFailed("cannot write \(url.lastPathComponent)")
        }
    }

    /// Writes a CIImage, rasterised upright through `cgImage(from:)` in `colorSpace` (Display P3 by default).
    public static func write(_ image: CIImage, to url: URL, type: UTType = .jpeg, quality: Double = 0.92, context: CIContext = RenderContext.export,
                             colorSpace: CGColorSpace = RenderContext.colorSpace, properties: [CFString: Any] = [:]) throws {
        guard let cg = cgImage(from: image, colorSpace: colorSpace, context: context) else {
            throw PicshopError.exportFailed("cannot rasterise \(url.lastPathComponent)")
        }
        try write(cg, to: url, type: type, quality: quality, properties: properties)
    }

    /// Writes a HEIC whose HDR gain map is `gainMap` (Apple's format), so an HDR photo
    /// stays as bright as the original in Photos. `properties` become its metadata.
    public static func writeHEIC(_ image: CIImage, gainMap: CIImage, to url: URL, quality: Double, colorSpace: CGColorSpace,
                                 properties: [CFString: Any], context: CIContext = RenderContext.export) throws {
        let metadata = ((properties as NSDictionary) as? [AnyHashable: Any]) ?? [:]
        let tagged = image.settingProperties(metadata)
        var options: [CIImageRepresentationOption: Any] = [.hdrGainMapImage: gainMap]
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        options[qualityKey] = quality
        try context.writeHEIFRepresentation(of: tagged, to: url, format: .RGBA8, colorSpace: colorSpace, options: options)
    }

    /// Creates a single-channel 8-bit grayscale CGImage from top-down bytes.
    public static func grayImage(width: Int, height: Int, bytes: [UInt8], colorSpace: CGColorSpace = CGColorSpaceCreateDeviceGray()) -> CGImage? {
        guard bytes.count >= width * height else { return nil }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Top-down 8-bit gray bytes of any CGImage, converted to `colorSpace` if it differs.
    public static func grayBytes(from image: CGImage, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceGray()) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Top-down interleaved RGBA8 bytes (premultiplied) of a CGImage, converted to `colorSpace` if it differs.
    public static func rgbaBytes(from image: CGImage, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    /// Builds an RGBA8 CGImage from top-down interleaved bytes (premultiplied).
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

// MARK: - Raw masks (W2, D5)

/// Mask values are raw numbers, never colour-matched (D5): an 8- or 16-bit gray raster is read with no colour space
/// (`[.colorSpace: NSNull()]`), so Core Image takes its samples as working-space values, and read back through a
/// linear gray space, so they come back as they went in.
public extension ImageSupport {
    /// A raster file (8- or 16-bit gray PNG) as raw values at its own pixel size, row 0 at the top; decoded now.
    static func rawMaskImage(at url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else { return nil }
        return rawMaskImage(cg)
    }

    /// A gray CGImage as raw values.
    static func rawMaskImage(_ cg: CGImage) -> CIImage {
        CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    /// A 16-bit gray CGImage from big-endian samples (`DepthMath.pack16`), tagged linear gray.
    static func gray16Image(width: Int, height: Int, bigEndianSamples bytes: [UInt8], colorSpace: CGColorSpace = RenderContext.maskColorSpace) -> CGImage? {
        guard width > 0, height > 0, bytes.count >= width * height * 2, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2, space: colorSpace,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Top-down 8-bit raw values of a mask image's `rect` (read through linear gray, so 0.5 stays 128).
    static func rawGrayBytes(of image: CIImage, rect: CGRect, context: CIContext = RenderContext.background) -> [UInt8]? {
        grayBytes(of: image, rect: rect, colorSpace: RenderContext.maskColorSpace, context: context)
    }

    /// Top-down raw values 0…1 of a mask image's `rect`, as 32-bit floats when Core Image gives them, else from
    /// 8-bit samples.
    static func rawGrayValues(of image: CIImage, rect: CGRect, context: CIContext = RenderContext.background) -> [Float]? {
        let bounds = rect.integral
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        if let cg = context.createCGImage(image, from: bounds, format: .Lf, colorSpace: RenderContext.maskColorSpace, deferred: false),
           let values = floatGrayValues(of: cg) {
            return values
        }
        return rawGrayBytes(of: image, rect: bounds, context: context)?.map { Float($0) / 255 }
    }

    /// The samples of a 32-bit float gray CGImage, row 0 at the top; nil for any other layout.
    static func floatGrayValues(of cg: CGImage) -> [Float]? {
        guard cg.bitsPerComponent == 32, cg.bitsPerPixel == 32, cg.bitmapInfo.contains(.floatComponents),
              let data = cg.dataProvider?.data as Data? else { return nil }
        let width = cg.width, height = cg.height, rowBytes = cg.bytesPerRow
        guard data.count >= (height - 1) * rowBytes + width * 4 else { return nil }
        let bigEndian = cg.bitmapInfo.contains(.byteOrder32Big)
        var values = [Float](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    let bits = raw.loadUnaligned(fromByteOffset: y * rowBytes + x * 4, as: UInt32.self)
                    values[y * width + x] = Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
                }
            }
        }
        return values
    }

    /// Top-down 8-bit raw values of a gray raster file at its own size (16-bit files are reduced).
    static func rawGrayBytes(at url: URL) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let image = rawMaskImage(at: url) else { return nil }
        let extent = image.extent.integral
        guard let bytes = rawGrayBytes(of: image, rect: extent) else { return nil }
        return (bytes, Int(extent.width), Int(extent.height))
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
