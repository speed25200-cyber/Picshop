#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore

// Layer and layer-mask thumbnails for the Layers column and inspector (§4.11), on the background context.
extension PhotoRenderer {
    /// Thumbnails kept (LRU).
    static let thumbnailLimit = 160

    /// The layer alone, placed on the canvas and fitted into side × side (canvas aspect, transparent elsewhere), on
    /// RenderContext.background, cached by layerContentKey + transform + side. Group: the isolated composite of its
    /// children; gradient fill: the gradient; adjustment layer and solid fill: nil (the row draws the kind glyph or a
    /// swatch). A bundle: its members together. The layer is drawn at full opacity, in normal mode, without its own
    /// mask (the mask has its own thumbnail); a group's children keep theirs.
    public func layerThumbnail(_ layerID: UUID, in document: PhotoDocument, side: Int) async throws -> CGImage? {
        guard let layer = document.layer(id: layerID), let base = document.baseLayer, let baseAsset = base.imageAsset else { return nil }
        switch layer.content {
        case .adjustment, .fill, .unsupported: return nil
        case .image, .text, .shape, .group, .gradientFill: break
        }
        let side = max(8, min(1024, side))
        // The layers drawn: the group's children, a table bundle's members, or the layer.
        var members: Set<UUID> = [layerID]
        if layer.isGroup {
            members.formUnion(document.children(of: layerID).map(\.id))
        } else if let bundle = layer.group {
            members.formUnion(document.layers.filter { $0.group?.id == bundle.id }.map(\.id))
        }
        let key = "layer|" + document.layers.filter { members.contains($0.id) }
            .map { "\(contentKey(of: $0))|\($0.transform.hashValue)|\($0.isVisible)|\($0.maskStack.hashValue)|\($0.mask.hashValue)|\($0.isMaskEnabled)|\($0.isMaskLinked)" }
            .joined(separator: ";") + "|\(side)|\(document.canvasSize.width)x\(document.canvasSize.height)"
        if let cached = thumbnail(for: key) { return cached }

        var alone = document
        alone.backgroundColor = .clear
        alone.selection = nil
        alone.layers = document.layers.compactMap { candidate -> Layer? in
            var drawn = candidate
            if candidate.id == base.id, !members.contains(candidate.id) {
                // The base still defines the canvas; it is not drawn.
                drawn.isVisible = false
                return drawn
            }
            guard members.contains(candidate.id) else { return nil }
            if candidate.id == layerID {
                drawn.isVisible = true
                drawn.opacity = 1
                drawn.fillOpacity = 1
                drawn.blendMode = .normal
                drawn.isClipped = false
                drawn.parentID = nil
                drawn.mask = nil
                drawn.maskStack = nil
                if case .group(var folder) = drawn.content {
                    folder.passThrough = false
                    drawn.content = .group(folder)
                    drawn.transform = .identity
                }
            } else if !layer.isGroup {
                drawn.parentID = nil
            }
            return drawn
        }
        let canvasSize = document.canvasSize.width > 0 && document.canvasSize.height > 0 ? document.canvasSize : baseAsset.pixelSize
        let canvasLongest = max(canvasSize.width, canvasSize.height)
        let sourceLongest = max(baseAsset.pixelSize.width, baseAsset.pixelSize.height)
        let options = Options(targetLongestSide: Double(side) * sourceLongest / max(1, canvasLongest), includeOverlays: true, allowExpensiveWork: false)
        let image = try await render(alone, options: options)
        let result = Self.fitted(image, side: side)
        if let result { storeThumbnail(result, for: key) }
        return result
    }

    /// The layer's mask (legacy × stack) in the layer's content space (canvas space for an unlinked stack, a fill, an
    /// adjustment layer or a group), fitted so its longest side is `side`; nil without a mask.
    public func layerMaskThumbnail(_ layerID: UUID, in document: PhotoDocument, side: Int) async throws -> CGImage? {
        guard let layer = document.layer(id: layerID), let baseAsset = document.baseLayer?.imageAsset else { return nil }
        let hasStack = layer.maskStack.map { !$0.isEmpty } ?? false
        guard layer.mask != nil || hasStack else { return nil }
        let side = max(8, min(1024, side))
        // The content key leaves the masks out: the mask's own hash, the content (its ranges read it) and the switches.
        let key = "mask|\(contentKey(of: layer))|\(layer.maskStack.hashValue)|\(layer.mask.hashValue)|\(layer.isMaskEnabled)|\(layer.isMaskLinked)|\(side)"
        if let cached = thumbnail(for: key) { return cached }

        let canvasSize = document.canvasSize.width > 0 && document.canvasSize.height > 0 ? document.canvasSize : baseAsset.pixelSize
        let canvasSpace = layer.isFill || layer.isAdjustment || layer.isGroup || (hasStack && !layer.isMaskLinked && layer.mask == nil)
        var contentSize = canvasSize
        var preLocal: CIImage?
        let options = Options(targetLongestSide: Double(side), includeOverlays: false, allowExpensiveWork: false, includesLocalAdjustments: false)
        if !canvasSpace {
            switch layer.content {
            case .image(let asset):
                contentSize = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
                // The content at the thumbnail's size, for colour and luminance range components.
                let density = min(1, Double(side) / max(1, max(contentSize.width, contentSize.height))) * contentSize.width / max(1, asset.pixelSize.width)
                let content = try await imageContent(layer, asset: asset, density: density, options: options, log: nil, capture: nil, canMaterialize: false)
                preLocal = content
            case .text, .shape:
                let canvas = CGRect(origin: .zero, size: canvasSize.limited(toLongestSide: Double(side)).cgSize)
                if let raster = overlayContent(layer, canvas: canvas) {
                    let k = Double(canvas.width) / max(1, canvasSize.width)
                    contentSize = PSSize(width: Double(raster.extent.width) / k, height: Double(raster.extent.height) / k)
                }
            default:
                break
            }
        }
        let fitted = contentSize.limited(toLongestSide: Double(side))
        let extent = preLocal.map { $0.extent } ?? CGRect(x: 0, y: 0, width: max(1, fitted.width.rounded()), height: max(1, fitted.height.rounded()))
        var mask: CIImage?
        if let legacy = layer.mask { mask = loadMask(legacy, fitting: extent) }
        if let stack = layer.maskStack, !stack.isEmpty {
            let drawn = rasterizer.mask(stack, extent: extent, preLocal: preLocal, mode: .interactive(target: nil), owner: layer.id)
            mask = mask.map { Self.multiply($0, drawn) } ?? drawn
        }
        guard let mask else { return nil }
        let rect = extent.integral
        guard !rect.isEmpty, let cg = RenderContext.background.createCGImage(mask, from: rect, format: .L8, colorSpace: RenderContext.maskColorSpace, deferred: false) else {
            return nil
        }
        storeThumbnail(cg, for: key)
        return cg
    }

    /// A layer thumbnail read back as top-down RGBA8 (premultiplied, Display P3), side × side; nil when the layer has
    /// none (tests).
    func layerThumbnailRGBA(_ layerID: UUID, in document: PhotoDocument, side: Int) async throws -> [UInt8]? {
        guard let image = try await layerThumbnail(layerID, in: document, side: side) else { return nil }
        return ImageSupport.rgbaBytes(from: image, colorSpace: RenderContext.colorSpace)
    }

    /// A layer-mask thumbnail read back as top-down raw 8-bit values with its size (tests).
    func layerMaskThumbnailBytes(_ layerID: UUID, in document: PhotoDocument, side: Int) async throws -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let image = try await layerMaskThumbnail(layerID, in: document, side: side) else { return nil }
        return (ImageSupport.grayBytes(from: image, colorSpace: RenderContext.maskColorSpace), image.width, image.height)
    }

    /// `image` (a canvas) fitted into a side × side square, centred, transparent elsewhere, as RGBA8 Display P3.
    static func fitted(_ image: CIImage, side: Int) -> CGImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let scale = min(CGFloat(side) / extent.width, CGFloat(side) / extent.height)
        let width = extent.width * scale, height = extent.height * scale
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: ((CGFloat(side) - width) / 2).rounded(), y: ((CGFloat(side) - height) / 2).rounded()))
        let placed = (scale < 0.5 ? image.transformed(by: transform, highQualityDownsample: true) : image.transformed(by: transform))
            .composited(over: CIImage(color: .clear).cropped(to: square)).cropped(to: square)
        return RenderContext.background.createCGImage(placed, from: square, format: .RGBA8, colorSpace: RenderContext.colorSpace, deferred: false)
    }

    func thumbnail(for key: String) -> CGImage? {
        guard let image = thumbnails[key] else { return nil }
        thumbnailOrder.removeAll { $0 == key }
        thumbnailOrder.append(key)
        return image
    }

    func storeThumbnail(_ image: CGImage, for key: String) {
        if thumbnails[key] == nil { thumbnailOrder.append(key) }
        thumbnails[key] = image
        while thumbnailOrder.count > Self.thumbnailLimit {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
    }
}
#endif
