#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore

/// D14: a finished image rendered in horizontal strips of `ExportBudget.stripRows` rows on `RenderContext.export`, so
/// a 48 MP or 16-bit export never holds its whole bitmap: PNG, TIFF, JPEG and PDF pull the strips in order through a
/// sequential data provider, PSD through its row sources. Each strip is drawn into an upright bitmap (row 0 at the
/// strip's top) and copied into tight rows; nothing upstream is recomputed per strip (the export pass pinned its
/// expensive results and decoded its sources once, D14). An `export.strip` signpost per strip.
///
/// Samples are premultiplied, as Core Image writes them: `.RGBA8`, or `.RGBA16` with Core Image's own byte order
/// (`bitmapInfo` reports it, little-endian on Apple GPUs).
final class StripRenderer {
    let image: CIImage
    /// The rect drawn, in the image's Core Image coordinates; rows count down from its top.
    let rect: CGRect
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let colorSpace: CGColorSpace
    let context: CIContext
    let rowsPerStrip: Int
    /// The layout Core Image wrote (byte order, alpha), known after the first strip.
    private(set) var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    /// `rect` defaults to the image's extent (integral).
    init(image: CIImage, rect: CGRect? = nil, bitsPerComponent: Int, colorSpace: CGColorSpace, rowsPerStrip: Int = ExportBudget.stripRows,
         context: CIContext = RenderContext.export) {
        let bounds = (rect ?? image.extent).integral
        self.image = image
        self.rect = bounds
        width = max(0, Int(bounds.width))
        height = max(0, Int(bounds.height))
        self.bitsPerComponent = bitsPerComponent == 16 ? 16 : 8
        self.colorSpace = colorSpace
        self.context = context
        self.rowsPerStrip = max(1, rowsPerStrip)
    }

    var bytesPerPixel: Int { bitsPerComponent == 16 ? 8 : 4 }
    var rowBytes: Int { width * bytesPerPixel }
    var stripCount: Int { height == 0 ? 0 : (height + rowsPerStrip - 1) / rowsPerStrip }
    var totalBytes: Int { rowBytes * height }

    /// Rows `top ..< top + rowsPerStrip` (clamped), top-down, tightly packed.
    func strip(top: Int) throws -> [UInt8] {
        let count = min(rowsPerStrip, height - top)
        guard top >= 0, count > 0 else { return [] }
        let signpost = PSSignpost.begin("export.strip", "rows \(top)…\(top + count - 1)")
        defer { PSSignpost.end(signpost) }
        // Core Image's y goes up: the strip's top rows are at the rect's maxY.
        let bounds = CGRect(x: rect.minX, y: rect.maxY - CGFloat(top + count), width: CGFloat(width), height: CGFloat(count))
        let format: CIFormat = bitsPerComponent == 16 ? .RGBA16 : .RGBA8
        guard let cg = context.createCGImage(image, from: bounds, format: format, colorSpace: colorSpace, deferred: false),
              let data = cg.dataProvider?.data as Data? else {
            throw PicshopError.exportFailed("strip \(top)")
        }
        bitmapInfo = cg.bitmapInfo
        let sourceRow = cg.bytesPerRow, tight = rowBytes
        guard cg.width == width, cg.height == count, data.count >= (count - 1) * sourceRow + tight else { throw PicshopError.exportFailed("strip \(top) layout") }
        if sourceRow == tight { return [UInt8](data.prefix(tight * count)) }
        var rows = [UInt8](repeating: 0, count: tight * count)
        data.withUnsafeBytes { raw in
            rows.withUnsafeMutableBytes { out in
                for y in 0..<count {
                    memcpy(out.baseAddress! + y * tight, raw.baseAddress! + y * sourceRow, tight)
                }
            }
        }
        return rows
    }

    /// Whether 16-bit samples come big-endian (`.byteOrder16Big`); little otherwise.
    var isBigEndian16: Bool {
        bitmapInfo.contains(.byteOrder16Big)
    }
}

/// Pulls a `StripRenderer`'s bytes in order for a sequential `CGDataProvider` (ImageIO reads PNG, TIFF and JPEG rows
/// this way): one strip in memory at a time. A rewind starts over (each strip is drawn again); an error or a
/// cancelled task ends the stream, and the writer's finalize fails.
final class StripStream {
    let renderer: StripRenderer
    private var position = 0
    private var buffer: [UInt8] = []
    private var bufferStart = 0
    private(set) var error: Error?
    private(set) var stripsDrawn = 0
    let progress: ((Double) -> Void)?

    init(renderer: StripRenderer, progress: ((Double) -> Void)? = nil) {
        self.renderer = renderer
        self.progress = progress
    }

    /// Draws the first strip now, so its layout (`renderer.bitmapInfo`) is known before the CGImage is made.
    func prime() throws {
        try load(stripAt: 0)
    }

    func read(into destination: UnsafeMutableRawPointer, count: Int) -> Int {
        guard error == nil else { return 0 }
        var written = 0
        let total = renderer.totalBytes
        while written < count, position < total {
            if position < bufferStart || position >= bufferStart + buffer.count {
                do {
                    try load(stripAt: position / max(1, renderer.rowBytes * renderer.rowsPerStrip))
                } catch {
                    self.error = error
                    return written
                }
            }
            let offset = position - bufferStart
            let chunk = min(count - written, buffer.count - offset)
            guard chunk > 0 else { break }
            buffer.withUnsafeBytes { raw in
                memcpy(destination + written, raw.baseAddress! + offset, chunk)
            }
            written += chunk
            position += chunk
        }
        return written
    }

    func skip(_ count: Int) -> Int {
        let skipped = max(0, min(count, renderer.totalBytes - position))
        position += skipped
        return skipped
    }

    func rewind() {
        position = 0
    }

    private func load(stripAt index: Int) throws {
        if Task.isCancelled { throw CancellationError() }
        let top = index * renderer.rowsPerStrip
        buffer = try renderer.strip(top: top)
        bufferStart = top * renderer.rowBytes
        stripsDrawn += 1
        progress?(Double(min(renderer.stripCount, index + 1)) / Double(max(1, renderer.stripCount)))
    }

    /// A CGImage whose pixels are pulled from this stream, strip by strip (`CGDataProvider(sequentialInfo:callbacks:)`).
    func makeImage() throws -> CGImage {
        try prime()
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                guard let info else { return 0 }
                return Unmanaged<StripStream>.fromOpaque(info).takeUnretainedValue().read(into: buffer, count: count)
            },
            skipForward: { info, count in
                guard let info else { return 0 }
                return off_t(Unmanaged<StripStream>.fromOpaque(info).takeUnretainedValue().skip(Int(count)))
            },
            rewind: { info in
                guard let info else { return }
                Unmanaged<StripStream>.fromOpaque(info).takeUnretainedValue().rewind()
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<StripStream>.fromOpaque(info).release()
            })
        let info = Unmanaged.passRetained(self).toOpaque()
        guard let provider = CGDataProvider(sequentialInfo: info, callbacks: &callbacks) else {
            Unmanaged<StripStream>.fromOpaque(info).release()
            throw PicshopError.exportFailed("data provider")
        }
        let bits = renderer.bitsPerComponent
        guard let image = CGImage(width: renderer.width, height: renderer.height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
                                  bytesPerRow: renderer.rowBytes, space: renderer.colorSpace, bitmapInfo: renderer.bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PicshopError.exportFailed("streamed image")
        }
        return image
    }
}
extension PhotoRenderer {
    /// The render as a `StripRenderer` draws it, rows top-down and tightly packed: in strips of `rowsPerStrip` rows, or
    /// whole (one strip) when nil. For tests, which never hold the actor's CIImage.
    func stripRendered(_ document: PhotoDocument, options: Options, bitsPerComponent: Int = 8, colorSpace: CGColorSpace = RenderContext.colorSpace,
                       rowsPerStrip: Int? = ExportBudget.stripRows) async throws -> (bytes: [UInt8], width: Int, height: Int, strips: Int, isBigEndian16: Bool) {
        let image = try await render(document, options: options)
        let extent = image.extent.integral
        let rows = rowsPerStrip ?? max(1, Int(extent.height))
        let renderer = StripRenderer(image: image, rect: extent, bitsPerComponent: bitsPerComponent, colorSpace: colorSpace, rowsPerStrip: rows)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(renderer.totalBytes)
        var top = 0
        while top < renderer.height {
            bytes += try renderer.strip(top: top)
            top += renderer.rowsPerStrip
        }
        return (bytes, renderer.width, renderer.height, renderer.stripCount, renderer.isBigEndian16)
    }
}
#endif
