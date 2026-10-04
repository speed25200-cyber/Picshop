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
    public enum Target: Sendable, Equatable { case localAdjustment(UUID), selection, stack(MaskStack) }

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

/// What one render recorded for an overlay: the base layer's pre-local image and its extent, the requested mask in
/// the layer's space, and how the layer lands on the canvas.
final class MaskCapture {
    let target: MaskOverlayRequest.Target?
    var preLocal: CIImage?
    var extent: CGRect = .null
    var mask: CIImage?
    var canvasOffset: CGAffineTransform = .identity
    var canvasRect: CGRect = .null

    init(target: MaskOverlayRequest.Target?) {
        self.target = target
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
        let capture = MaskCapture(target: overlay.target)
        let image = try await render(document, options: options, capture: capture)
        return (image, overlayImage(overlay, capture: capture, document: document, frame: image))
    }

    /// Aligned with `render(document, options)`'s output (base-layer masks); nil when there is nothing to show.
    public func maskOverlay(_ request: MaskOverlayRequest, document: PhotoDocument, options: Options) async throws -> CIImage? {
        try await render(document, options: options, overlay: request).overlay
    }

    /// The overlay for a recorded render: the target's mask on the canvas, drawn in the request's style.
    func overlayImage(_ request: MaskOverlayRequest, capture: MaskCapture, document: PhotoDocument, frame: CIImage) -> CIImage? {
        guard let mask = overlayMask(request.target, capture: capture, document: document) else { return nil }
        let canvas = capture.canvasRect.isNull ? frame.extent : capture.canvasRect
        let placed = mask.transformed(by: capture.canvasOffset).cropped(to: canvas)
        return MaskOverlayRenderer.overlay(mask: placed, frame: frame, style: request.style, color: request.color, opacity: request.opacity, extent: canvas)
    }

    private func overlayMask(_ target: MaskOverlayRequest.Target, capture: MaskCapture, document: PhotoDocument) -> CIImage? {
        switch target {
        case .localAdjustment, .stack:
            return capture.mask
        case .selection:
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
        let fullLongest = max(asset.pixelSize.width, asset.pixelSize.height)
        let scale = options.targetLongestSide.map { min(1, $0 / max(1, fullLongest)) } ?? 1
        var preLocalOnly = options
        preLocalOnly.includesLocalAdjustments = false
        let capture = MaskCapture(target: target)
        let image = try await renderImageLayer(base, asset: asset, scale: scale, options: preLocalOnly, capture: capture)
        capture.canvasOffset = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        capture.canvasRect = CGRect(origin: .zero, size: image.extent.size)
        return capture
    }

    /// The stack as gray 0…1 at the base layer's output extent at this scale.
    public func maskImage(_ stack: MaskStack, document: PhotoDocument, options: Options) async throws -> CIImage? {
        let capture = try await baseCapture(document, options: options, target: .stack(stack))
        return capture.mask.map { $0.transformed(by: capture.canvasOffset) }
    }

    /// A 64 px (or `side`) thumbnail of the stack, rendered on the background context.
    public func maskThumbnail(_ stack: MaskStack, document: PhotoDocument, side: Int) async throws -> CGImage? {
        let options = Options(targetLongestSide: Double(max(8, side)), includeOverlays: false, allowExpensiveWork: false, includesLocalAdjustments: false)
        guard let mask = try await maskImage(stack, document: document, options: options) else { return nil }
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

    /// Raw mask values 0…1 (row 0 at the top) of a stack at the base output size of `options` (probes, tests).
    func maskValues(_ stack: MaskStack, document: PhotoDocument, options: Options) async throws -> (values: [Float], width: Int, height: Int) {
        guard let mask = try await maskImage(stack, document: document, options: options) else { throw PicshopError.renderFailed("mask") }
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
