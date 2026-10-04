#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import CoreVideo
import PicshopCore

/// Rasterises, stores and loads masks for a project. Masks are 8-bit
/// grayscale PNGs (255 = selected) at a working resolution that tracks the
/// base image's longest side, capped for memory.
public struct MaskStore: Sendable {
    public static let maximumSide = 2048

    public let store: ProjectStore
    public let projectID: UUID

    public init(store: ProjectStore, projectID: UUID) {
        self.store = store
        self.projectID = projectID
    }

    public func url(for mask: MaskReference) -> URL {
        store.url(for: mask.relativePath, in: projectID)
    }

    /// Loads the mask as a CIImage scaled to `extent` (bottom-left origin).
    public func load(_ mask: MaskReference, fitting extent: CGRect) -> CIImage? {
        guard let cg = try? ImageSupport.loadCGImage(at: url(for: mask)) else { return nil }
        var image = CIImage(cgImage: cg)
        let scaleX = extent.width / image.extent.width
        let scaleY = extent.height / image.extent.height
        image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        if mask.isInverted {
            image = image.applyingFilter("CIColorInvert")
        }
        if mask.feather > 0 {
            let radius = mask.feather * max(extent.width, extent.height) * 0.5
            image = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        }
        return image
    }

    /// Saves a gray CGImage as the mask's PNG.
    public func save(_ image: CGImage, as mask: MaskReference) throws {
        try store.createPackage(for: projectID)
        try ImageSupport.write(image, to: url(for: mask), type: .png)
    }

    /// Writes mask bytes and returns a reference with the computed bounding box.
    public func save(bytes: [UInt8], width: Int, height: Int, source: MaskSource, strokes: [BrushStroke] = [], feather: Double = 0.02) throws -> MaskReference {
        guard let image = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else {
            throw PicshopError.renderFailed("mask rasterisation")
        }
        let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
        let reference = MaskReference(source: source, boundingBox: box, strokes: strokes, feather: feather)
        try save(image, as: reference)
        return reference
    }

    /// Bounding box (normalised, top-left origin) of pixels above threshold.
    public static func boundingBox(of bytes: [UInt8], width: Int, height: Int, threshold: UInt8 = 32) -> PSRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        bytes.withUnsafeBufferPointer { buffer in
            for y in 0..<height {
                let row = y * width
                var rowHas = false
                for x in 0..<width where buffer[row + x] > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    rowHas = true
                }
                if rowHas {
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return .zero }
        return PSRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                      width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
    }

    /// Fraction of selected pixels.
    public static func coverage(of bytes: [UInt8]) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var count = 0
        for byte in bytes where byte > 127 { count += 1 }
        return Double(count) / Double(bytes.count)
    }

    // MARK: - W2 rasters (D4)

    /// The file of a raster (a mask component's, a selection's or a depth map).
    public func url(for raster: RasterRef) -> URL {
        store.url(for: raster.path, in: projectID)
    }

    public func exists(_ raster: RasterRef) -> Bool {
        FileManager.default.fileExists(atPath: url(for: raster).path)
    }

    /// Writes 8-bit bytes (top-down, 255 = in) as a new immutable raster, `masks/<uuid>.png` in DeviceGray like every
    /// mask so far, and returns its reference: unit corners, the bounding box of the pixels above 32.
    public func saveRaster(bytes: [UInt8], width: Int, height: Int, origin: RasterRef.Origin, label: String? = nil,
                           stateKey: String? = nil) throws -> RasterRef {
        guard width > 0, height > 0, let image = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else {
            throw PicshopError.renderFailed("mask rasterisation")
        }
        let path = "masks/\(UUID().uuidString).png"
        try store.createPackage(for: projectID)
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        return RasterRef(path: path, origin: origin, pixelWidth: width, pixelHeight: height, bitDepth: 8,
                         boundingBox: MaskStore.boundingBox(of: bytes, width: width, height: height), label: label, stateKey: stateKey)
    }

    /// The path of a depth map for a base state: `masks/depth-<baseStateKey>.png` (16 hex; any other key is hashed).
    public static func depthPath(forStateKey key: String) -> String {
        let isHex = key.count == 16 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return "masks/depth-\(isHex ? key : StableHash.hex(key)).png"
    }

    /// Writes a depth map (0 far … 1 near) as a 16-bit gray PNG at its own size and returns its reference
    /// (origin .depth, bitDepth 16). The same base state always lands on the same file.
    public func saveDepth(values: [Float], width: Int, height: Int, stateKey: String) throws -> RasterRef {
        guard width > 0, height > 0, values.count >= width * height,
              let image = ImageSupport.gray16Image(width: width, height: height, bigEndianSamples: DepthMath.pack16(Array(values.prefix(width * height)))) else {
            throw PicshopError.renderFailed("depth map")
        }
        let path = MaskStore.depthPath(forStateKey: stateKey)
        try store.createPackage(for: projectID)
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        return RasterRef(path: path, origin: .depth, pixelWidth: width, pixelHeight: height, bitDepth: 16, stateKey: stateKey)
    }

    /// The depth map already written for a base state, if any.
    public func existingDepth(stateKey: String) -> RasterRef? {
        let path = MaskStore.depthPath(forStateKey: stateKey)
        let url = store.url(for: path, in: projectID)
        guard FileManager.default.fileExists(atPath: url.path), let size = ImageSupport.pixelSize(at: url) else { return nil }
        return RasterRef(path: path, origin: .depth, pixelWidth: Int(size.width), pixelHeight: Int(size.height), bitDepth: 16, stateKey: stateKey)
    }

    /// The raster as raw values (D5) at its own pixel size, origin at zero; nil when the file is missing.
    public func loadRaw(_ raster: RasterRef) -> CIImage? {
        ImageSupport.rawMaskImage(at: url(for: raster))
    }

    /// The raster's 8-bit values at its own size (row 0 at the top).
    public func rawBytes(_ raster: RasterRef) -> (bytes: [UInt8], width: Int, height: Int)? {
        ImageSupport.rawGrayBytes(at: url(for: raster))
    }

    // MARK: - Rasterisation helpers

    /// Reads a one-component pixel buffer (Vision masks) into top-down bytes at the given size,
    /// in linear gray like the values Core Image blends with.
    public static func bytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // Clamped so resampling does not blend the border rows with the clear outside the extent.
        let scaled = ciImage.clampedToExtent().transformed(by: CGAffineTransform(scaleX: CGFloat(width) / ciImage.extent.width, y: CGFloat(height) / ciImage.extent.height))
        // The value is in red whether Core Image maps the buffer to gray or to red only; spread it before the gray read.
        let spread = CIFilter.colorMatrix()
        spread.inputImage = scaled
        spread.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        spread.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        return ImageSupport.grayBytes(of: spread.outputImage ?? scaled, rect: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: RenderContext.maskColorSpace)
            ?? [UInt8](repeating: 0, count: width * height)
    }

    /// Draws brush strokes into a mask (top-down bytes, 255 = selected). Hardness is honoured:
    /// full inside `hardness × radius`, a smoothstep falloff to the radius (BrushRaster, in Core).
    public static func rasterize(strokes: [BrushStroke], width: Int, height: Int, into bytes: inout [UInt8]) {
        BrushRaster.draw(strokes, width: width, height: height, into: &bytes)
    }

    /// Grows the selection by `radius` pixels (max filter) and optionally softens the edge.
    public static func dilated(_ bytes: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return bytes }
        var horizontal = bytes
        var out = bytes
        // Separable max filter.
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var maxValue: UInt8 = 0
                let lo = max(0, x - radius)
                let hi = min(width - 1, x + radius)
                for k in lo...hi { maxValue = max(maxValue, bytes[row + k]) }
                horizontal[row + x] = maxValue
            }
        }
        for x in 0..<width {
            for y in 0..<height {
                var maxValue: UInt8 = 0
                let lo = max(0, y - radius)
                let hi = min(height - 1, y + radius)
                for k in lo...hi { maxValue = max(maxValue, horizontal[k * width + x]) }
                out[y * width + x] = maxValue
            }
        }
        return out
    }

    /// Union of several masks.
    public static func union(_ masks: [[UInt8]]) -> [UInt8] {
        guard var result = masks.first else { return [] }
        for mask in masks.dropFirst() {
            for index in result.indices where index < mask.count {
                result[index] = max(result[index], mask[index])
            }
        }
        return result
    }

    /// Bytes for a mask covering a normalised rectangle.
    public static func rectangleMask(_ rect: PSRect, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let x0 = max(0, Int(rect.minX * Double(width)))
        let x1 = min(width, Int(rect.maxX * Double(width)))
        let y0 = max(0, Int(rect.minY * Double(height)))
        let y1 = min(height, Int(rect.maxY * Double(height)))
        guard x1 > x0, y1 > y0 else { return bytes }
        for y in y0..<y1 {
            for x in x0..<x1 { bytes[y * width + x] = 255 }
        }
        return bytes
    }

    /// Bytes for a mask covering the union of normalised rectangles (every pixel they touch).
    public static func rectanglesMask(_ rects: [PSRect], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for rect in rects {
            let x0 = max(0, Int((rect.minX * Double(width)).rounded(.down)))
            let x1 = min(width, Int((rect.maxX * Double(width)).rounded(.up)))
            let y0 = max(0, Int((rect.minY * Double(height)).rounded(.down)))
            let y1 = min(height, Int((rect.maxY * Double(height)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 { bytes[row + x] = 255 }
            }
        }
        return bytes
    }

    /// Soft circular mask centred on a point (used for tap-to-heal).
    public static func circleMask(center: PSPoint, radius: Double, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let cx = center.x * Double(width)
        let cy = center.y * Double(height)
        let r = radius * Double(max(width, height))
        let x0 = max(0, Int(cx - r) - 1), x1 = min(width - 1, Int(cx + r) + 1)
        let y0 = max(0, Int(cy - r) - 1), y1 = min(height - 1, Int(cy + r) + 1)
        guard x1 >= x0, y1 >= y0 else { return bytes }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let d = (dx * dx + dy * dy).squareRoot()
                if d <= r { bytes[y * width + x] = 255 }
            }
        }
        return bytes
    }
}
#endif
