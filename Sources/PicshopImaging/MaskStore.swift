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

    // MARK: - Rasterisation helpers

    /// Reads a one-component pixel buffer (Vision masks) into bytes at the given size.
    public static func bytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / ciImage.extent.width, y: CGFloat(height) / ciImage.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            RenderContext.shared.render(scaled, toBitmap: buffer.baseAddress!, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                        format: .R8, colorSpace: nil)
        }
        return RenderContext.bitmapIsTopDown ? bytes : flippedVertically(bytes, width: width, height: height)
    }

    static func flippedVertically(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            let src = y * width
            let dst = (height - 1 - y) * width
            out.replaceSubrange(dst..<(dst + width), with: bytes[src..<(src + width)])
        }
        return out
    }

    /// Draws brush strokes into a mask.
    public static func rasterize(strokes: [BrushStroke], width: Int, height: Int, into bytes: inout [UInt8]) {
        guard width > 0, height > 0 else { return }
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // CoreGraphics draws bottom-up; flip so normalised (top-left) coordinates map correctly.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let longest = CGFloat(max(width, height))
            for stroke in strokes {
                let radius = CGFloat(stroke.radius) * longest
                let gray: CGFloat = stroke.mode == .add ? 1 : 0
                context.setStrokeColor(gray: gray, alpha: 1)
                context.setFillColor(gray: gray, alpha: 1)
                context.setLineWidth(radius * 2)
                guard let first = stroke.points.first else { continue }
                if stroke.points.count == 1 {
                    let center = CGPoint(x: first.x * Double(width), y: first.y * Double(height))
                    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    continue
                }
                context.beginPath()
                context.move(to: CGPoint(x: first.x * Double(width), y: first.y * Double(height)))
                for point in stroke.points.dropFirst() {
                    context.addLine(to: CGPoint(x: point.x * Double(width), y: point.y * Double(height)))
                }
                context.strokePath()
            }
        }
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
