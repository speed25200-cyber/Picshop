import Foundation
import PicshopCore
import PicshopIntent

// W3 layers (D17, D10): `rasterizeLayers`, `aiMask(_:in:layer:)` and `contentSize(of:in:)` for VisionPhotoServices.
#if canImport(Vision) && canImport(CoreImage)
import CoreImage
import UniformTypeIdentifiers

extension VisionPhotoServices {
    // MARK: - PhotoAIServices: layers

    /// D17: the listed layers composited onto transparent in plan order, isolated (merge down: [lower, upper]; apply
    /// mask: [id]; merge selected), or the visible composite (merge visible, flatten, stamp), at full canvas
    /// resolution through the strip renderer into an 8-bit RGBA PNG under media/. A result that replaces the base
    /// (the visible composite, or a list holding the base) stays canvas-sized; any other is cropped to the listed
    /// layers' placed bounds. `opaqueBounds` is where the asset lies on the canvas (canvas-normalised).
    public func rasterizeLayers(_ request: LayerRasterRequest, in document: PhotoDocument) async throws -> LayerRasterResult {
        try await maskRenderer.rasterize(request, in: document)
    }

    /// W2's aiMask for a layer other than the base: the providers read that layer's own pre-local pixels in its
    /// content space (its source through its operations and develop recipe, at the analysis size), so Vision, SAM and
    /// Depth run on it unchanged; the raster comes back in that layer's content space.
    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument, layer: UUID?) async throws -> AIMaskResult {
        guard let layer, layer != document.baseLayerID else { return try await aiMask(request, in: document) }
        // The analysis image, the caches (keyed by its own base state, `maskStateKey(on:)`) and every provider read
        // that layer as they read a base.
        guard let proxy = document.contentSpaceDocument(of: layer) else { throw PicshopError.unsupportedOperation("Masks") }
        return try await aiMask(request, in: proxy)
    }

    /// Text and shape content sizes at the document's canvas size (placement maths); image layers their output size;
    /// fills, adjustment layers and groups the canvas; nil when unknown.
    public func contentSize(of layerID: UUID, in document: PhotoDocument) async -> PSSize? {
        guard let layer = document.layer(id: layerID) else { return nil }
        let canvas = document.canvasSize
        switch layer.content {
        case .image:
            return LayerPlacement.contentSize(of: layer)
        case .text(let element):
            #if canImport(UIKit)
            return TextRasterizer.boundingSize(for: element, canvasSize: canvas.cgSize).map { PSSize($0) }
            #else
            _ = element
            return nil
            #endif
        case .shape(let shape):
            // TextRasterizer's shape raster: its relative size of the canvas, at least 2 px.
            return PSSize(width: max(2, shape.relativeSize.width * canvas.width), height: max(2, shape.relativeSize.height * canvas.height))
        case .fill, .gradientFill, .adjustment, .group:
            return canvas
        case .unsupported:
            return nil
        }
    }
}
#endif

#if canImport(CoreImage) && canImport(Photos)
import CoreImage
import UniformTypeIdentifiers

extension PhotoRenderer {
    /// D17's rasterisation (see `VisionPhotoServices.rasterizeLayers`). Memory: strips, and the model broker asked
    /// first. The lowest listed layer is drawn at full opacity in normal mode, with its masks and fill: it keeps its
    /// opacity and blend mode as layer properties (merge down, apply mask); every other listed layer is drawn with
    /// its own blend, opacity, fill and masks (a clipped upper layer as a clipping group onto the lower one).
    /// `.merged` (merge selected) draws the lowest one with its own opacity and blend too, unless it is the base.
    public func rasterize(_ request: LayerRasterRequest, in document: PhotoDocument) async throws -> LayerRasterResult {
        guard let base = document.baseLayer, base.imageAsset != nil else { throw PicshopError.renderFailed("document has no photo") }
        let signpost = PSSignpost.begin("layers.rasterize")
        defer { PSSignpost.end(signpost) }
        var target = document
        var listed: Set<UUID> = []
        let canvasSized: Bool
        switch request {
        case .visible:
            canvasSized = true
        case .layers(let ids), .merged(let ids):
            // Merge selected keeps the lowest layer's own opacity and blend in the pixels (its result is at 1, normal).
            let keepsOwn: Bool
            if case .merged = request { keepsOwn = true } else { keepsOwn = false }
            var wanted = Set(ids.filter { document.layer(id: $0) != nil })
            for id in ids where document.layer(id: id)?.isGroup == true {
                wanted.formUnion(document.children(of: id).map(\.id))
            }
            guard !wanted.isEmpty else { throw PicshopError.objectNotFound("layer") }
            listed = wanted
            let lowest = document.layers.first { wanted.contains($0.id) }?.id
            canvasSized = wanted.contains(base.id)
            target.backgroundColor = .clear
            target.layers = document.layers.compactMap { layer in
                if wanted.contains(layer.id) {
                    var drawn = layer
                    if layer.id == lowest, !keepsOwn || layer.id == base.id {
                        drawn.opacity = 1
                        drawn.blendMode = .normal
                    }
                    return drawn
                }
                // The base still defines the canvas; it is not drawn.
                guard layer.id == base.id else { return nil }
                var hidden = layer
                hidden.isVisible = false
                return hidden
            }
        }
        let canvasSize = PhotoExporter.canvasSize(of: document)
        let megapixels = canvasSize.width * canvasSize.height / 1_000_000
        let peak = ExportBudget.peakBytes(format: .png, bitDepth: 8, width: Int(canvasSize.width), height: Int(canvasSize.height),
                                          layers: target.layers.count, streaming: megapixels >= ExportBudget.streamingThresholdMegapixels,
                                          pinnedBytes: PhotoExporter.pinnedEstimate(target, scale: 1))
        await ModelResidency.prepareForExport(megapixels: megapixels, peakBytes: peak)

        var options = Options.full
        options.isExportPass = true
        do {
            let image = try await render(target, options: options)
            let extent = image.extent.integral
            let canvas = CGRect(origin: .zero, size: extent.size)
            let atOrigin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).cropped(to: canvas)
            var rect = canvas
            if !canvasSized {
                rect = placedBounds(of: listed, in: target, canvas: canvas)
                if rect.isNull || rect.isEmpty { rect = canvas }
            }
            let path = "media/\(UUID().uuidString).png"
            try store.createPackage(for: projectID)
            let url = store.url(for: path, in: projectID)
            let strips = StripRenderer(image: atOrigin, rect: rect, bitsPerComponent: 8, colorSpace: RenderContext.colorSpace)
            try ExportWriters.writeStreamed(strips, to: url, type: .png, quality: nil, resolution: nil, properties: [:])
            endExportPass()
            let asset = MediaAsset(kind: .image, relativePath: path, pixelSize: PSSize(width: Double(rect.width), height: Double(rect.height)), origin: .file)
            let bounds = PSRect(x: Double(rect.minX / canvas.width), y: Double((canvas.height - rect.maxY) / canvas.height),
                                width: Double(rect.width / canvas.width), height: Double(rect.height / canvas.height))
            return LayerRasterResult(asset: asset, opaqueBounds: bounds)
        } catch {
            endExportPass()
            throw error
        }
    }

    /// The listed layers' placed bounds on `canvas` (Core Image pixels, integral): fills and adjustment layers cover
    /// the canvas; text and shapes by their raster at this size.
    func placedBounds(of ids: Set<UUID>, in document: PhotoDocument, canvas: CGRect) -> CGRect {
        let canvasSize = PhotoExporter.canvasSize(of: document)
        var union = CGRect.null
        for layer in document.layers where ids.contains(layer.id) {
            switch layer.content {
            case .image(let asset):
                if layer.id == document.baseLayerID { return canvas }
                let contentSize = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
                var map = LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
                if let group = groupPlacement(of: layer, in: document, canvasSize: canvasSize) { map = map.then(group) }
                union = union.union(ContentPlacement.bounds(map, canvas: canvas))
            case .text, .shape:
                guard let raster = overlayContent(layer, canvas: canvas) else { continue }
                let k = Double(canvas.width) / max(1, canvasSize.width)
                let contentSize = PSSize(width: Double(raster.extent.width) / k, height: Double(raster.extent.height) / k)
                var map = LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
                if let group = groupPlacement(of: layer, in: document, canvasSize: canvasSize) { map = map.then(group) }
                union = union.union(ContentPlacement.bounds(map, canvas: canvas))
            case .fill, .gradientFill, .adjustment:
                return canvas
            case .group, .unsupported:
                continue
            }
        }
        return union.isNull ? union : union.integral.intersection(canvas)
    }
}
#endif
