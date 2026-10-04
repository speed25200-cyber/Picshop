#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

// D14: detail tiles at deep zoom. When settled and zoomed past 1.25 device pixels per preview pixel, the session asks
// for the visible region (expanded by 25 % and snapped to a 512-px grid in full-resolution canvas pixels) at one
// source pixel per device pixel, at most 2048 px across; `MetalCanvasView.presentDetail` draws it over the preview.
extension PhotoRenderer {
    /// Tiles kept (LRU); any document change drops them.
    static let detailTileLimit = 4
    /// The widest tile.
    static let detailMaxPixelsAcross = 2048

    /// D14: the visible region at native density for deep zoom. `region` is canvas-normalised (top-left origin),
    /// `pixelsAcross` ≤ 2048 is the tile's width in pixels. The tile comes back materialised, its extent at the origin
    /// (pixelsAcross × the region's aspect); the caller draws it at the region's rect in the preview's extent
    /// coordinates. Rendered without expensive work (expensive results only from the cache, scaled when needed) and
    /// without pinning keys; only the layers whose placed bounds meet the region are decoded, a source above 24 MP
    /// lazily (ROI-driven), the rest at the tile's density, within the 200 MB detail budget.
    public func renderDetail(_ document: PhotoDocument, region: PSRect, pixelsAcross: Int) async throws -> CIImage {
        guard FeatureFlags.isOn(.tiledRendering) else { throw PicshopError.unsupportedOperation("Detail") }
        guard let asset = document.baseLayer?.imageAsset else { throw PicshopError.renderFailed("document has no photo") }
        let region = region.clampedToUnit()
        guard region.width > 1e-4, region.height > 1e-4 else { throw PicshopError.renderFailed("empty region") }
        let across = min(Self.detailMaxPixelsAcross, max(16, pixelsAcross))
        let canvasSize = document.canvasSize.width > 0 && document.canvasSize.height > 0 ? document.canvasSize : asset.pixelSize

        // The tiles of another document state go first.
        var hasher = Hasher()
        hasher.combine(document.layers)
        hasher.combine(document.canvasSize)
        hasher.combine(document.backgroundColor)
        let state = String(hasher.finalize(), radix: 16)
        detailTiles.removeAll { !$0.key.hasPrefix(state + "|") }
        let key = "\(state)|\(region.minX),\(region.minY),\(region.width),\(region.height)|\(across)"
        if let index = detailTiles.firstIndex(where: { $0.key == key }) {
            let tile = detailTiles.remove(at: index)
            detailTiles.append(tile)
            return tile.image
        }

        let signpost = PSSignpost.begin("render.detail", "\(across) px")
        defer { PSSignpost.end(signpost) }
        // The canvas scale that gives `across` pixels over the region (never above full resolution), as a longest side
        // of the base's source (the renderer's scale is relative to it).
        let canvasScale = min(1, Double(across) / (region.width * canvasSize.width))
        let sourceLongest = max(asset.pixelSize.width, asset.pixelSize.height)
        let options = Options(targetLongestSide: canvasScale * sourceLongest, includeOverlays: true, allowExpensiveWork: false,
                              isDisplayed: false, regionOfInterest: region)
        let image = try await render(document, options: options)
        let extent = image.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { throw PicshopError.renderFailed("detail") }
        let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        // Materialised, so a pan or a zoom over the tile replays nothing.
        let tile = LayerContentCache.bitmap(atOrigin, rect: CGRect(origin: .zero, size: extent.size), context: RenderContext.background) ?? atOrigin
        detailTiles.append((key, tile))
        while detailTiles.count > Self.detailTileLimit { detailTiles.removeFirst() }
        return tile
    }

    /// A detail tile read back as top-down RGBA8 in Display P3 (tests).
    func detailRGBA(_ document: PhotoDocument, region: PSRect, pixelsAcross: Int) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let tile = try await renderDetail(document, region: region, pixelsAcross: pixelsAcross)
        let extent = tile.extent.integral
        guard let bytes = ImageSupport.rgbaBytes(of: tile, rect: extent) else { throw PicshopError.renderFailed("readback") }
        return (bytes, Int(extent.width), Int(extent.height))
    }

    /// Drops the detail tiles (the session calls it on any document change; a memory trim does too).
    public func dropDetailTiles() {
        detailTiles.removeAll()
    }
}
#endif
