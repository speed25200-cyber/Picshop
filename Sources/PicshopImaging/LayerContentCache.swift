#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

/// Materialised layer contents (W3, D12, D15): an image layer's pixels after its operations, develop recipe and local
/// adjustments, in its own content space, before placement and before its own masks, drawn once into a half-float
/// bitmap and kept by `PhotoRenderer.contentKey(of:)` (a process-local hash of the layer without its placement and
/// masks) and decode density. A settled render reuses them for every layer that did
/// not change (an opacity drag on one layer re-runs nobody else's develop), an interactive frame reuses another
/// density's scaled, and a snapshot captures them instead of drawing again (D13). Least recently used out first past
/// `byteLimit`; owned by the renderer actor.
final class LayerContentCache {
    struct Entry {
        let image: CIImage
        let density: Double
        let width: Int
        let height: Int
        let bytes: Int
        var tick: Int
    }

    /// D15: 160 MB.
    static let defaultByteLimit = 160 * 1_048_576
    /// Bytes per pixel of a materialised content (RGBAh).
    static let bytesPerPixel = 8

    private(set) var entries: [String: Entry] = [:]
    private(set) var bytes = 0
    private var tick = 0
    var byteLimit: Int
    /// Contents drawn into bitmaps since the cache was made (tests).
    private(set) var materializations = 0
    /// Lookups answered from the cache, exactly or scaled (tests).
    private(set) var hits = 0

    init(byteLimit: Int = LayerContentCache.defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    static func key(content: String, density: Double) -> String {
        "\(content)@\(String(format: "%.5f", density))"
    }

    /// The content decoded at exactly `density` (its extent at the origin), nil when not kept.
    func image(content: String, density: Double) -> CIImage? {
        let key = Self.key(content: content, density: density)
        guard var entry = entries[key] else { return nil }
        tick += 1
        entry.tick = tick
        entries[key] = entry
        hits += 1
        return entry.image
    }

    /// The same content kept at another density, scaled to `density` (an interactive frame reusing the settled
    /// preview's: GPU per frame and no new bytes, D13). The densest kept one wins.
    func scaled(content: String, density: Double) -> CIImage? {
        if let exact = image(content: content, density: density) { return exact }
        let prefix = content + "@"
        var best: (key: String, entry: Entry)?
        for (key, entry) in entries where key.hasPrefix(prefix) {
            if best.map({ entry.density > $0.entry.density }) ?? true { best = (key, entry) }
        }
        guard let best, best.entry.density > 0 else { return nil }
        tick += 1
        entries[best.key]?.tick = tick
        hits += 1
        let factor = density / best.entry.density
        let width = max(1, (Double(best.entry.width) * factor).rounded()), height = max(1, (Double(best.entry.height) * factor).rounded())
        let transform = CGAffineTransform(scaleX: CGFloat(width) / CGFloat(best.entry.width), y: CGFloat(height) / CGFloat(best.entry.height))
        let scaled = factor < 0.5 ? best.entry.image.transformed(by: transform, highQualityDownsample: true) : best.entry.image.transformed(by: transform)
        return scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Draws `image` (its extent moved to the origin) into a half-float bitmap in the working space and keeps it;
    /// returns the bitmap, or nil when it could not be drawn or would take more than half the budget on its own.
    @discardableResult
    func materialize(_ image: CIImage, content: String, density: Double, context: CIContext = RenderContext.shared) -> CIImage? {
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        guard width * height * Self.bytesPerPixel <= byteLimit / 2 else { return nil }
        let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard let bitmap = Self.bitmap(atOrigin, rect: CGRect(x: 0, y: 0, width: width, height: height), context: context) else { return nil }
        materializations += 1
        store(bitmap, content: content, density: density, width: width, height: height)
        return bitmap
    }

    func store(_ image: CIImage, content: String, density: Double, width: Int, height: Int) {
        let key = Self.key(content: content, density: density)
        let cost = width * height * Self.bytesPerPixel
        if let old = entries[key] { bytes -= old.bytes }
        tick += 1
        entries[key] = Entry(image: image, density: density, width: width, height: height, bytes: cost, tick: tick)
        bytes += cost
        trim(to: byteLimit)
    }

    /// Least recently used out first until at most `limit` bytes remain.
    func trim(to limit: Int) {
        guard bytes > limit else { return }
        for (key, entry) in entries.sorted(by: { $0.value.tick < $1.value.tick }) {
            guard bytes > limit else { break }
            entries[key] = nil
            bytes -= entry.bytes
        }
    }

    func removeAll() {
        entries.removeAll()
        bytes = 0
    }

    /// `image` over `rect` drawn now into an RGBAh bitmap tagged with the working space (so its values come back as
    /// they went in, whatever they encode), placed back at `rect`'s origin.
    static func bitmap(_ image: CIImage, rect: CGRect, context: CIContext = RenderContext.shared) -> CIImage? {
        let bounds = rect.integral
        guard !bounds.isEmpty, !bounds.isInfinite else { return nil }
        guard let cg = context.createCGImage(image, from: bounds, format: .RGBAh, colorSpace: RenderContext.workingColorSpace, deferred: false) else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }

    /// A gray mask drawn now into a 16-bit linear gray bitmap (raw values, W2 D5), placed back at `rect`'s origin.
    static func maskBitmap(_ mask: CIImage, rect: CGRect, context: CIContext = RenderContext.shared) -> CIImage? {
        let bounds = rect.integral
        guard !bounds.isEmpty, !bounds.isInfinite else { return nil }
        guard let cg = context.createCGImage(mask, from: bounds, format: .L16, colorSpace: RenderContext.maskColorSpace, deferred: false) else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
    }
}
#endif
