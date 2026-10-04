#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import PicshopCore

// W2 masks in the renderer (D2, D6, D17): local adjustments are drawn after the layer's develop recipe
// (`renderImageLayer` → `applyLocalAdjustments`), and the mask or selection overlay comes with the frame from one
// actor hop, the mask graph built once.

/// How the mask or selection overlay looks on the canvas.
public enum MaskOverlayStyle: String, Sendable, CaseIterable { case tint, rubylith, outline, onBlack, onWhite, blackAndWhite }

/// Which mask to show over a frame, and how.
public struct MaskOverlayRequest: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case localAdjustment(UUID), selection, stack(MaskStack)
        /// W3 (D8): a layer's own mask (legacy × stack), shown where the layer lies on the canvas.
        case layerMask(UUID)
    }

    public var target: Target
    public var style: MaskOverlayStyle
    public var color: PSColor
    public var opacity: Double

    public init(target: Target, style: MaskOverlayStyle = .tint, color: PSColor = PSColor(red: 1, green: 0.23, blue: 0.19), opacity: Double = 0.5) {
        self.target = target
        self.style = style
        self.color = color
        self.opacity = opacity
    }
}

/// What one render recorded for an overlay: the captured layer's pre-local image and its extent, the requested mask
/// in the layer's space, and how the layer lands on the canvas. W3: the layer is any image layer (local adjustments
/// on the active image layer), or any layer for its layer mask; the base when nil.
final class MaskCapture {
    let target: MaskOverlayRequest.Target?
    /// W3: the layer whose local adjustments (or layer mask) the render records; nil records the base's.
    var layerID: UUID?
    var preLocal: CIImage?
    var extent: CGRect = .null
    var mask: CIImage?
    var canvasOffset: CGAffineTransform = .identity
    var canvasRect: CGRect = .null
    /// W3 (D10): how the captured layer's content lands on the canvas (content unit square → canvas-normalised).
    var map: PSHomography = .identity
    /// W3: `mask` is already on the canvas (a layer mask's overlay).
    var maskOnCanvas = false

    init(target: MaskOverlayRequest.Target?, layerID: UUID? = nil) {
        self.target = target
        self.layerID = layerID
    }

    /// A mask of the captured layer's content extent placed on the canvas (W2's offset for the base, W3's map for a
    /// placed layer).
    func placed(_ mask: CIImage, canvas: CGRect) -> CIImage {
        if maskOnCanvas { return mask.cropped(to: canvas) }
        return ContentPlacement.placeMask(mask, map: map, canvas: canvas)
    }

    var wantedAdjustment: UUID? {
        if case .localAdjustment(let id)? = target { return id }
        return nil
    }

    var wantedStack: MaskStack? {
        if case .stack(let stack)? = target { return stack }
        return nil
    }
}

extension PhotoRenderer {
    // MARK: - Local adjustments (D2)

    /// The layer's local adjustments drawn over `image` (the layer after its develop recipe), each through its mask,
    /// in operation order (16 at most); the masks of the overlay's target are recorded in `capture`. Colour and
    /// luminance ranges read `image` as it was before the first local adjustment, so masks never depend on each
    /// other. With `includesLocalAdjustments` off (analysis, sampling, AI inputs) nothing is drawn.
    func applyLocalAdjustments(of layer: Layer, to image: CIImage, scale: Double, options: Options, capture: MaskCapture?) -> CIImage {
        capture?.preLocal = image
        capture?.extent = image.extent
        let wantedID = capture?.wantedAdjustment
        let wantedStack = capture?.wantedStack
        let adjustments = FeatureFlags.isOn(.masks)
            ? layer.edits.resolvedLocalAdjustments.prefix(LocalAdjustment.maxPerLayer).filter { adjustment in
                (options.includesLocalAdjustments && adjustment.isVisible && !adjustment.isNeutral) || adjustment.id == wantedID
            }
            : []
        guard !adjustments.isEmpty || wantedStack != nil else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        // A settled frame still carries the target while the finger rests (the pacer settles after 120 ms of
        // stillness): the other masks' freeze holds and the stack under the finger draws live.
        let mode: MaskRasterizer.Mode = options.allowExpensiveWork ? .settled(target: options.interactionTarget)
                                                                   : .interactive(target: options.interactionTarget)
        rasterizer.begin(mode)
        let signpost = PSSignpost.begin("mask.local", "\(adjustments.count) local")
        defer { PSSignpost.end(signpost) }
        let preLocal = image
        var result = image
        for adjustment in adjustments {
            let drawn = options.includesLocalAdjustments && adjustment.isVisible && !adjustment.isNeutral
            let wanted = adjustment.id == wantedID
            let mask = rasterizer.mask(adjustment.stack, extent: extent, preLocal: preLocal, mode: mode, owner: adjustment.id)
            if wanted { capture?.mask = mask }
            if drawn {
                result = LocalAdjustRenderer.apply(adjustment, mask: mask, to: result, scale: scale, interactive: !options.allowExpensiveWork)
            }
        }
        if let wantedStack {
            capture?.mask = rasterizer.mask(wantedStack, extent: extent, preLocal: preLocal, mode: mode, owner: nil)
        }
        return result
    }

    // MARK: - Overlays (D17)

    /// The frame and its mask overlay from one actor hop, the mask graph built once (D17).
    public func render(_ document: PhotoDocument, options: Options, overlay: MaskOverlayRequest?) async throws -> (image: CIImage, overlay: CIImage?) {
        guard let overlay else { return (try await render(document, options: options), nil) }
        let capture = MaskCapture(target: overlay.target, layerID: captureLayer(for: overlay.target, in: document))
        let image = try await render(document, options: options, capture: capture)
        if case .layerMask(let id) = overlay.target, let layer = document.layer(id: id) {
            capture.mask = layerMaskOnCanvas(layer, capture: capture, options: options)
            capture.maskOnCanvas = true
        }
        return (image, overlayImage(overlay, capture: capture, document: document, frame: image))
    }

    /// The layer an overlay's render records (W3): the image layer owning a local adjustment, the Masques layer for a
    /// stack preview, the base for the selection, the layer itself for its layer mask.
    func captureLayer(for target: MaskOverlayRequest.Target, in document: PhotoDocument) -> UUID? {
        switch target {
        case .localAdjustment(let id):
            return document.layers.first { $0.isImage && $0.edits.localAdjustment(id: id) != nil }?.id ?? document.localAdjustmentsLayerID
        case .stack:
            return document.localAdjustmentsLayerID
        case .selection:
            return document.baseLayerID
        case .layerMask(let id):
            return id
        }
    }

    /// A layer's mask (legacy × stack) on the canvas of the recorded render: in its content space placed with the
    /// layer when linked, in canvas space when not; nil without a mask.
    func layerMaskOnCanvas(_ layer: Layer, capture: MaskCapture, options: Options) -> CIImage? {
        let canvas = capture.canvasRect
        guard !canvas.isNull, !canvas.isEmpty else { return nil }
        let contentSpace = layer.isFill || layer.isAdjustment || layer.isGroup || capture.extent.isNull ? canvas : capture.extent
        let mode: MaskRasterizer.Mode = options.allowExpensiveWork ? .settled(target: nil) : .interactive(target: nil)
        var content: CIImage?
        if let legacy = layer.mask { content = loadMask(legacy, fitting: contentSpace) }
        var onCanvas: CIImage?
        if layer.isMaskEnabled, let stack = layer.maskStack, !stack.isEmpty {
            if layer.isMaskLinked || layer.isFill {
                let drawn = rasterizer.mask(stack, extent: contentSpace, preLocal: nil, mode: mode, owner: layer.id)
                content = content.map { Self.multiply($0, drawn) } ?? drawn
            } else {
                onCanvas = rasterizer.mask(stack, extent: canvas, preLocal: nil, mode: mode, owner: layer.id)
            }
        }
        let placedContent = content.map { contentSpace == canvas ? $0.cropped(to: canvas) : ContentPlacement.placeMask($0, map: capture.map, canvas: canvas) }
        switch (placedContent, onCanvas) {
        case let (a?, b?): return Self.multiply(a, b).cropped(to: canvas)
        case let (a?, nil): return a
        case let (nil, b?): return b.cropped(to: canvas)
        case (nil, nil): return nil
        }
    }

    /// Aligned with `render(document, options)`'s output (base-layer masks); nil when there is nothing to show.
    public func maskOverlay(_ request: MaskOverlayRequest, document: PhotoDocument, options: Options) async throws -> CIImage? {
        try await render(document, options: options, overlay: request).overlay
    }

    /// The overlay for a recorded render: the target's mask on the canvas, drawn in the request's style.
    func overlayImage(_ request: MaskOverlayRequest, capture: MaskCapture, document: PhotoDocument, frame: CIImage) -> CIImage? {
        guard let mask = overlayMask(request.target, capture: capture, document: document) else { return nil }
        let canvas = capture.canvasRect.isNull ? frame.extent : capture.canvasRect
        let placed = capture.placed(mask, canvas: canvas)
        return MaskOverlayRenderer.overlay(mask: placed, frame: frame, style: request.style, color: request.color, opacity: request.opacity, extent: canvas)
    }

    private func overlayMask(_ target: MaskOverlayRequest.Target, capture: MaskCapture, document: PhotoDocument) -> CIImage? {
        switch target {
        case .localAdjustment, .stack, .layerMask:
            return capture.mask
        case .selection:
            // The selection lives in canvas space (W2 D7), recorded with the base, whose content space is the canvas.
            guard let selection = document.selection, selection.layerID == document.baseLayerID, !capture.extent.isNull else { return nil }
            return selectionMask(selection, extent: capture.extent)
        }
    }

    /// The selection's raster placed by its corners (D7) at the base layer's output extent.
    func selectionMask(_ selection: PhotoSelection, extent: CGRect) -> CIImage? {
        guard let raw = rasterizer.rawRaster(selection.raster) else { return nil }
        return MaskComponentImages.placed(raw, corners: selection.corners, extent: extent.integral)
    }

    // MARK: - Masks as images

    /// The base layer rendered without local adjustments, with the target's mask recorded.
    func baseCapture(_ document: PhotoDocument, options: Options, target: MaskOverlayRequest.Target?) async throws -> MaskCapture {
        guard let base = document.baseLayer, let asset = base.imageAsset else { throw PicshopError.renderFailed("no photo") }
        let scale = Self.renderScale(document, options: options)
        var preLocalOnly = options
        preLocalOnly.includesLocalAdjustments = false
        let capture = MaskCapture(target: target, layerID: base.id)
        let image = try await renderImageLayer(base, asset: asset, scale: scale, options: preLocalOnly, capture: capture)
        capture.canvasOffset = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        capture.canvasRect = CGRect(origin: .zero, size: image.extent.size)
        return capture
    }

    /// W3: the Masques layer (`localAdjustmentsLayerID`) rendered without local adjustments in its content space, with
    /// the target's mask recorded, and how it lands on the canvas. The base's is `baseCapture`.
    func layerCapture(_ document: PhotoDocument, layerID: UUID?, options: Options, target: MaskOverlayRequest.Target?) async throws -> MaskCapture {
        guard let id = layerID, id != document.baseLayerID, let layer = document.layer(id: id), let asset = layer.imageAsset,
              let baseAsset = document.baseLayer?.imageAsset else {
            return try await baseCapture(document, options: options, target: target)
        }
        let scale = Self.renderScale(document, options: options)
        let canvasSize = document.canvasSize.width > 0 ? document.canvasSize : baseAsset.pixelSize
        let canvas = CGRect(x: 0, y: 0, width: (canvasSize.width * scale).rounded(), height: (canvasSize.height * scale).rounded())
        let contentSize = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
        var map = LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
        if let groupMap = groupPlacement(of: layer, in: document, canvasSize: canvasSize) { map = map.then(groupMap) }
        let need = ContentPlacement.density(map, contentPixels: contentSize, canvasPixels: PSSize(width: Double(canvas.width), height: Double(canvas.height)))
        let density = Self.quantizedDensity(need * contentSize.width / max(1, asset.pixelSize.width))
        var preLocalOnly = options
        preLocalOnly.includesLocalAdjustments = false
        let capture = MaskCapture(target: target, layerID: id)
        let image = try await renderImageLayer(layer, asset: asset, scale: density, options: preLocalOnly, capture: capture)
        capture.canvasOffset = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        capture.canvasRect = canvas
        capture.map = map
        return capture
    }

    /// A local adjustment's stack drawn for the Masques layer: in its content space at the origin (`placed: false`,
    /// thumbnails) or placed on the canvas (`placed: true`, probes). The base's content space is the canvas.
    func adjustmentMask(_ stack: MaskStack, document: PhotoDocument, options: Options, placed: Bool) async throws -> CIImage? {
        let capture = try await layerCapture(document, layerID: document.localAdjustmentsLayerID, options: options, target: .stack(stack))
        guard let mask = capture.mask else { return nil }
        if placed, capture.layerID != nil, capture.layerID != document.baseLayerID {
            return capture.placed(mask, canvas: capture.canvasRect)
        }
        return mask.transformed(by: capture.canvasOffset)
    }

    /// The stack as gray 0…1 at the base layer's output extent at this scale.
    public func maskImage(_ stack: MaskStack, document: PhotoDocument, options: Options) async throws -> CIImage? {
        let capture = try await baseCapture(document, options: options, target: .stack(stack))
        return capture.mask.map { $0.transformed(by: capture.canvasOffset) }
    }

    /// A 64 px (or `side`) thumbnail of the stack, rendered on the background context. W3: a stack of the Masques layer
    /// (`localAdjustmentsLayerID`, any image layer) is drawn in that layer's content space.
    public func maskThumbnail(_ stack: MaskStack, document: PhotoDocument, side: Int) async throws -> CGImage? {
        let options = Options(targetLongestSide: Double(max(8, side)), includeOverlays: false, allowExpensiveWork: false, includesLocalAdjustments: false)
        guard let mask = try await adjustmentMask(stack, document: document, options: options, placed: false) else { return nil }
        let rect = mask.extent.integral
        guard !rect.isEmpty, !rect.isInfinite else { return nil }
        return RenderContext.background.createCGImage(mask, from: rect, format: .L8, colorSpace: RenderContext.maskColorSpace, deferred: false)
    }

    /// Select & Mask live preview (lazy GPU, interactive): the refined selection mask on the canvas.
    public func refinePreview(_ selection: PhotoSelection, _ refinement: SelectionRefinement, document: PhotoDocument, options: Options) async throws -> CIImage? {
        let capture = try await baseCapture(document, options: options, target: nil)
        guard selection.layerID == document.baseLayerID, let guide = capture.preLocal, let mask = selectionMask(selection, extent: capture.extent) else { return nil }
        return EdgeRefine.refine(mask, guide: guide.cropped(to: mask.extent), refinement: refinement).transformed(by: capture.canvasOffset)
    }

    /// Test counter: static masks materialised since init.
    public var maskMaterializations: Int { rasterizer.materializations }

    /// Bytes held by settled mask bitmaps (tests: a memory trim empties them).
    var settledMaskBytes: Int { rasterizer.settledBytesHeld }

    /// Test counter: colour and luminance cubes built since init.
    var maskCubeBuilds: Int { rasterizer.cubeBuilds }

    /// A brush gesture ended: its per-frame segments (`drawn`) became one polyline (`coalesced`) with the same
    /// pixels. The stroke rasters drawn so far are kept under the merged list, so the next touch-down extends them
    /// instead of redrawing every stroke of the brush on the CPU.
    public func noteBrushCoalesced(_ drawn: [BrushStroke], as coalesced: [BrushStroke]) {
        rasterizer.alias(drawn, as: coalesced)
    }

    // MARK: - Working-size rasters (selections, AI masks, probes)

    /// The pre-local base (no local adjustment) at `longestSide` (the source's longest side at that size, as the
    /// analysis image), with its extent at the origin.
    func preLocalBase(_ document: PhotoDocument, longestSide: Int, allowExpensiveWork: Bool = true) async throws -> CIImage {
        let options = Options(targetLongestSide: Double(longestSide), includeOverlays: false, allowExpensiveWork: allowExpensiveWork,
                              includesLocalAdjustments: false)
        let capture = try await baseCapture(document, options: options, target: nil)
        guard let image = capture.preLocal else { throw PicshopError.renderFailed("pre-local base") }
        return image.transformed(by: capture.canvasOffset)
    }

    /// A raster placed by its corners in a `width` × `height` frame, as 8-bit raw values (row 0 at the top).
    func rasterBytes(_ raster: RasterRef, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let raw = rasterizer.rawRaster(raster) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        return ImageSupport.rawGrayBytes(of: MaskComponentImages.placed(raw, corners: raster.corners, extent: rect), rect: rect)
    }

    /// A stack drawn at the base's output size for `longestSide`, as 8-bit raw values.
    func stackBytes(_ stack: MaskStack, document: PhotoDocument, longestSide: Int) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let options = Options(targetLongestSide: Double(longestSide), includeOverlays: false, allowExpensiveWork: true, includesLocalAdjustments: false)
        guard let mask = try await maskImage(stack, document: document, options: options) else { throw PicshopError.renderFailed("mask") }
        let rect = mask.extent.integral
        guard let bytes = ImageSupport.rawGrayBytes(of: mask, rect: rect) else { throw PicshopError.renderFailed("mask readback") }
        return (bytes, Int(rect.width), Int(rect.height))
    }

    /// Raw mask values 0…1 (row 0 at the top) of a local adjustment's stack on the canvas at the base output size of
    /// `options` (probes, tests). W3: a stack of a non-base Masques layer is drawn in its content space and placed.
    func maskValues(_ stack: MaskStack, document: PhotoDocument, options: Options) async throws -> (values: [Float], width: Int, height: Int) {
        guard let mask = try await adjustmentMask(stack, document: document, options: options, placed: true) else { throw PicshopError.renderFailed("mask") }
        let rect = mask.extent.integral
        guard let values = ImageSupport.rawGrayValues(of: mask, rect: rect) else { throw PicshopError.renderFailed("mask readback") }
        return (values, Int(rect.width), Int(rect.height))
    }

    /// Raw mask values of the selection at the base output size of `options`.
    func selectionValues(_ selection: PhotoSelection, document: PhotoDocument, options: Options) async throws -> (values: [Float], width: Int, height: Int)? {
        let capture = try await baseCapture(document, options: options, target: nil)
        guard selection.layerID == document.baseLayerID, let mask = selectionMask(selection, extent: capture.extent) else { return nil }
        let placed = mask.transformed(by: capture.canvasOffset)
        let rect = placed.extent.integral
        guard let values = ImageSupport.rawGrayValues(of: placed, rect: rect) else { return nil }
        return (values, Int(rect.width), Int(rect.height))
    }

    /// The rendered frame and its overlay read back as top-down RGBA8 in Display P3 (tests).
    func renderedRGBA(_ document: PhotoDocument, options: Options, overlay request: MaskOverlayRequest)
        async throws -> (frame: [UInt8], overlay: [UInt8]?, width: Int, height: Int) {
        let rendered = try await render(document, options: options, overlay: request)
        let extent = rendered.image.extent.integral
        guard let frame = ImageSupport.rgbaBytes(of: rendered.image, rect: extent) else { throw PicshopError.renderFailed("readback") }
        let overlay = rendered.overlay.flatMap { ImageSupport.rgbaBytes(of: $0.composited(over: CIImage(color: .clear).cropped(to: extent)), rect: extent) }
        return (frame, overlay, Int(extent.width), Int(extent.height))
    }

    /// The rendered document read back as top-down RGBA8 in gamma sRGB, what Lab statistics read (pixel probes).
    func renderedSRGB(_ document: PhotoDocument, options: Options) async throws -> (bytes: [UInt8], width: Int, height: Int) {
        let image = try await render(document, options: options)
        let extent = image.extent.integral
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let bytes = ImageSupport.rgbaBytes(of: image, rect: extent, colorSpace: sRGB) else { throw PicshopError.renderFailed("readback") }
        return (bytes, Int(extent.width), Int(extent.height))
    }

    // MARK: - Layer masks (W3)

    /// W3 probe (`layerMaskCoverageInRange`): a layer's pixels (without its masks) and its mask (legacy × stack) in
    /// its content space at `side` on the longest side, as gamma sRGB RGBA8 and raw values; the canvas for fills,
    /// adjustment layers, groups and unlinked stacks. Nil without a mask.
    func layerMaskProbe(_ document: PhotoDocument, layerID: UUID, side: Int) async throws -> (bytes: [UInt8], values: [Float], width: Int, height: Int)? {
        guard let layer = document.layer(id: layerID), let baseAsset = document.baseLayer?.imageAsset else { return nil }
        let hasStack = layer.maskStack.map { !$0.isEmpty } ?? false
        guard layer.mask != nil || hasStack else { return nil }
        let canvasSize = document.canvasSize.width > 0 && document.canvasSize.height > 0 ? document.canvasSize : baseAsset.pixelSize
        let options = Options(targetLongestSide: Double(side), includeOverlays: true, allowExpensiveWork: false)
        let canvasSpace = layer.isFill || layer.isAdjustment || layer.isGroup || (hasStack && !layer.isMaskLinked) || layer.id == document.baseLayerID
        var content: CIImage
        if canvasSpace {
            let fitted = canvasSize.limited(toLongestSide: Double(side))
            let sourceLongest = max(baseAsset.pixelSize.width, baseAsset.pixelSize.height)
            var probeOptions = options
            probeOptions.targetLongestSide = fitted.width / canvasSize.width * sourceLongest
            content = try await render(document, options: probeOptions)
        } else {
            switch layer.content {
            case .image(let asset):
                let size = LayerPlacement.contentSize(of: layer) ?? asset.pixelSize
                let density = min(1, Double(side) / max(1, max(size.width, size.height))) * size.width / max(1, asset.pixelSize.width)
                content = try await imageContent(layer, asset: asset, density: density, options: options, log: nil, capture: nil, canMaterialize: false)
            case .text, .shape:
                let canvas = CGRect(origin: .zero, size: canvasSize.limited(toLongestSide: Double(side)).cgSize)
                guard let raster = overlayContent(layer, canvas: canvas) else { return nil }
                content = raster
            default:
                return nil
            }
        }
        let extent = content.extent.integral
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        content = content.cropped(to: extent)
        var mask: CIImage?
        if let legacy = layer.mask { mask = loadMask(legacy, fitting: extent) }
        if let stack = layer.maskStack, !stack.isEmpty, layer.isMaskEnabled {
            let drawn = rasterizer.mask(stack, extent: extent, preLocal: canvasSpace ? nil : content, mode: .interactive(target: nil), owner: layer.id)
            mask = mask.map { Self.multiply($0, drawn) } ?? drawn
        }
        guard let mask else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let bytes = ImageSupport.rgbaBytes(of: content, rect: extent, colorSpace: sRGB),
              let values = ImageSupport.rawGrayValues(of: mask, rect: extent) else { return nil }
        return (bytes, values, Int(extent.width), Int(extent.height))
    }

    // MARK: - Depth from the camera

    /// The capture's disparity (Portrait photos) as raw values at its own size, oriented like the picture; nil
    /// without one. Larger is nearer.
    func disparityValues(for document: PhotoDocument) -> (values: [Float], width: Int, height: Int)? {
        guard let asset = document.baseLayer?.imageAsset else { return nil }
        let url = store.url(for: asset.relativePath, in: projectID)
        guard let disparity = CIImage(contentsOf: url, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true]) else { return nil }
        let extent = disparity.extent.integral
        guard extent.width >= 2, extent.height >= 2, !extent.isInfinite else { return nil }
        let atOrigin = disparity.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let rect = CGRect(x: 0, y: 0, width: extent.width, height: extent.height)
        guard let values = ImageSupport.rawGrayValues(of: atOrigin, rect: rect) else { return nil }
        return (values, Int(rect.width), Int(rect.height))
    }
}
#endif
