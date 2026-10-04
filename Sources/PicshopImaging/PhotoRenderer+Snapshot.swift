#if canImport(CoreImage)
import Foundation
import CoreImage
import PicshopCore

// D13: the interactive snapshot's capture. Built on the actor at interaction start (the session asks in
// beginInteraction, ≈ 10–30 ms), then every drag frame is graph construction on the main actor (`RenderSnapshot.frame`).
extension PhotoRenderer {
    /// Live nodes a snapshot may keep (members of the target's node and live nodes above).
    static let snapshotLiveNodeLimit = 16
    /// New bytes a snapshot may materialise.
    static let snapshotByteLimit = 64 * 1_048_576

    /// D13: captures what `scope` needs at interaction start. Throws when the flag is off, when the target is not drawn
    /// or does not fit the scope, past 16 live nodes or 64 MB: callers keep the actor path then.
    public func interactiveSnapshot(_ document: PhotoDocument, scope: InteractionScope, options: Options) async throws -> RenderSnapshot {
        guard FeatureFlags.isOn(.interactiveSnapshot) else { throw PicshopError.unsupportedOperation("Snapshot") }
        dropSnapshot()
        let signpost = PSSignpost.begin("snapshot.capture")
        defer { PSSignpost.end(signpost) }
        var options = options
        options.isDisplayed = false
        options.showOriginal = false
        options.regionOfInterest = nil
        options.isExportPass = false

        let targetID = scope.layerID
        guard let target = document.layer(id: targetID) else { throw PicshopError.unsupportedOperation("Snapshot") }
        switch scope {
        case .layerDevelop: guard target.isImage else { throw PicshopError.unsupportedOperation("Snapshot") }
        case .adjustmentLayer: guard target.isAdjustment else { throw PicshopError.unsupportedOperation("Snapshot") }
        case .fillLayer: guard target.isFill else { throw PicshopError.unsupportedOperation("Snapshot") }
        case .layerPlacement, .layerMask: break
        }
        let frame = try await prepareFrame(document, options: options, log: nil, capture: nil)
        // A superseded capture (a newer drag, a pinch) stops here, not after its readbacks (actor reentrancy).
        try Task.checkCancellation()
        let plan = frame.plan
        guard let targetIndex = plan.firstIndex(where: { $0.layerIDs.contains(targetID) }) else { throw PicshopError.unsupportedOperation("Snapshot") }
        let canvas = frame.canvas
        let lutURL = lutURLMaker()
        let inputs = frame.inputs(colorCube: colorCube, lutURL: lutURL)
        let opaqueBackdrop = document.backgroundColor.alpha >= 0.9995
        var bytes = 0
        func pixels(_ rect: CGRect) -> Int { Int(rect.width * rect.height) }

        // Below: everything under the target's top-level node, composited once.
        let belowGraph = CompositeExecutor.run(Array(plan[..<targetIndex]), onto: CompositeExecutor.background(inputs), inputs: inputs,
                                               backdropIsOpaque: opaqueBackdrop)
        guard let below = LayerContentCache.bitmap(belowGraph, rect: canvas) else { throw PicshopError.renderFailed("snapshot") }
        bytes += pixels(canvas) * 8

        // Materialised copies of what live nodes draw: image contents (expensive graphs) and masks.
        func materializedContent(_ image: CIImage?) -> CIImage? {
            guard let image else { return nil }
            let extent = image.extent.integral
            guard !extent.isEmpty, !extent.isInfinite, let bitmap = LayerContentCache.bitmap(image, rect: extent) else { return image }
            bytes += pixels(extent) * 8
            return bitmap
        }
        func materializedMask(_ mask: CIImage?) -> CIImage? {
            guard let mask else { return nil }
            let extent = mask.extent.isInfinite ? canvas : mask.extent.integral.intersection(canvas)
            guard !extent.isEmpty, let bitmap = LayerContentCache.maskBitmap(mask, rect: extent) else { return mask }
            bytes += pixels(extent) * 2
            return bitmap
        }
        func isImageLayer(_ id: UUID) -> Bool { document.layer(id: id)?.isImage == true }

        // Above: runs of normal-mode layers flattened, other nodes live.
        var above: [SnapshotPayload.Above] = []
        var frozen: [UUID: CIImage] = [:]
        var masks: [UUID: CIImage] = [:]
        var recipes: [UUID: DevelopRenderer.Recipe] = [:]
        var liveLayers = 0
        var run: [CompositeNode] = []
        func flush() throws {
            guard !run.isEmpty else { return }
            try Task.checkCancellation()
            let graph = CompositeExecutor.run(run, onto: CompositeExecutor.clear(canvas), inputs: inputs, backdropIsOpaque: false)
            guard let flat = LayerContentCache.bitmap(graph, rect: canvas) else { throw PicshopError.renderFailed("snapshot") }
            bytes += pixels(canvas) * 8
            above.append(.flat(flat))
            run.removeAll()
        }
        for index in plan.indices where index > targetIndex {
            let node = plan[index]
            if case .layer(let draw) = node, draw.blendMode == .normal {
                run.append(node)
                continue
            }
            try flush()
            above.append(.live(index))
            for id in node.layerIDs {
                liveLayers += 1
                let placed = frame.placed(id)
                frozen[id] = isImageLayer(id) ? materializedContent(placed) : placed
                masks[id] = materializedMask(frame.masks[id])
                if let recipe = frame.recipes[id] {
                    recipes[id] = recipe
                    DevelopRenderer.warm(recipe, colorCube: colorCube, lutURL: lutURL)
                }
            }
        }
        try flush()

        // The target's node: its other members as captured (their own maps kept for a moving group).
        let canvasSize = frame.canvasSize
        var members: [UUID: SnapshotPayload.Member] = [:]
        for id in plan[targetIndex].layerIDs where id != targetID {
            liveLayers += 1
            if var pieces = frame.pieces[id], let layer = document.layer(id: id) {
                if layer.isImage { pieces.content = materializedContent(pieces.content) }
                pieces.canvasMask = materializedMask(pieces.canvasMask)
                let ownMap = layer.isFill || layer.id == document.baseLayerID
                    ? PSHomography.identity
                    : LayerPlacement.map(for: layer, contentSize: pieces.contentSize, canvasSize: canvasSize, isBase: false)
                members[id] = SnapshotPayload.Member(pieces: pieces, ownMap: ownMap, placed: pieces.placed(on: canvas),
                                                     followsGroup: !layer.isFill && layer.id != document.baseLayerID)
            }
            masks[id] = materializedMask(frame.masks[id])
            if let recipe = frame.recipes[id] {
                recipes[id] = recipe
                DevelopRenderer.warm(recipe, colorCube: colorCube, lutURL: lutURL)
            }
        }
        guard liveLayers <= Self.snapshotLiveNodeLimit else { throw PicshopError.unsupportedOperation("Snapshot") }
        try Task.checkCancellation()

        var payload = SnapshotPayload(below: below, belowIsOpaque: opaqueBackdrop, above: above, frozen: frozen, members: members, masks: masks,
                                      recipes: recipes, targetPieces: nil, targetCanvasMask: nil, targetFillMask: nil, develop: nil,
                                      unmaskedContent: nil, legacyMask: nil, maskDrawer: nil, bytes: 0)
        let rasterMode: MaskRasterizer.Mode = .interactive(target: nil)
        switch scope {
        case .layerPlacement:
            if var pieces = frame.pieces[targetID] {
                if target.isImage { pieces.content = materializedContent(pieces.content) }
                pieces.canvasMask = materializedMask(pieces.canvasMask)
                if target.isFill {
                    payload.frozen[targetID] = pieces.placed(on: canvas)
                } else {
                    payload.targetPieces = pieces
                }
            }
            payload.targetCanvasMask = materializedMask(frame.masks[targetID])
            if let recipe = frame.recipes[targetID] { DevelopRenderer.warm(recipe, colorCube: colorCube, lutURL: lutURL) }

        case .layerDevelop:
            guard let asset = target.imageAsset, var pieces = frame.pieces[targetID] else { throw PicshopError.unsupportedOperation("Snapshot") }
            let density = targetID == document.baseLayerID ? frame.scale
                : contentDensity(of: target, asset: asset, map: pieces.map, contentSize: pieces.contentSize, canvas: canvas)
            let raw = try await preDevelopImage(target, asset: asset, scale: density, options: options)
            try Task.checkCancellation()
            let atOrigin = raw.transformed(by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY))
            guard let preDevelop = materializedContent(atOrigin) else { throw PicshopError.renderFailed("snapshot") }
            let extent = preDevelop.extent
            let effectiveScale = Double(extent.width) / max(1, asset.pixelSize.width)
            let recipe = developRecipe(for: target)
            DevelopRenderer.warm(recipe, colorCube: colorCube, lutURL: lutURL)
            // The local adjustments' masks, frozen at capture (D13), from the developed picture as the actor draws them.
            let developed = DevelopRenderer.apply(recipe, to: preDevelop, scale: effectiveScale, cubes: .interactive, colorCube: colorCube, lutURL: lutURL)
            var localMasks: [UUID: CIImage] = [:]
            if FeatureFlags.isOn(.masks), options.includesLocalAdjustments {
                for adjustment in target.edits.resolvedLocalAdjustments.prefix(LocalAdjustment.maxPerLayer) where adjustment.isVisible && !adjustment.isNeutral {
                    let mask = rasterizer.mask(adjustment.stack, extent: extent, preLocal: developed, mode: rasterMode, owner: adjustment.id)
                    localMasks[adjustment.id] = materializedMask(mask)
                    _ = LocalAdjustRenderer.adjusted(developed, by: adjustment, scale: effectiveScale, interactive: false)
                }
            }
            // The layer's own masks (legacy × a linked stack) in content space; an unlinked one stays on the pieces.
            var linked: CIImage?
            if let legacy = target.mask { linked = loadMask(legacy, fitting: extent) }
            if target.isMaskEnabled, let stack = target.maskStack, !stack.isEmpty, target.isMaskLinked {
                let drawn = rasterizer.mask(stack, extent: extent, preLocal: developed, mode: rasterMode, owner: target.id)
                linked = linked.map { Self.multiply($0, drawn) } ?? drawn
            }
            pieces.canvasMask = materializedMask(pieces.canvasMask)
            pieces.content = nil
            payload.targetPieces = pieces
            payload.develop = SnapshotPayload.Develop(preDevelop: preDevelop, effectiveScale: effectiveScale, localMasks: localMasks,
                                                      linkedMask: materializedMask(linked), includesLocalAdjustments: options.includesLocalAdjustments)

        case .adjustmentLayer:
            payload.targetCanvasMask = materializedMask(frame.masks[targetID])
            if let recipe = frame.recipes[targetID] { DevelopRenderer.warm(recipe, colorCube: colorCube, lutURL: lutURL) }

        case .fillLayer:
            var mask: CIImage?
            if let legacy = target.mask { mask = loadMask(legacy, fitting: canvas) }
            if target.isMaskEnabled, let stack = target.maskStack, !stack.isEmpty {
                let drawn = rasterizer.mask(stack, extent: canvas, preLocal: nil, mode: rasterMode, owner: target.id)
                mask = mask.map { Self.multiply($0, drawn) } ?? drawn
            }
            payload.targetFillMask = materializedMask(mask)

        case .layerMask:
            guard var pieces = frame.pieces[targetID] else { throw PicshopError.unsupportedOperation("Snapshot") }
            let unmasked: CIImage?
            switch target.content {
            case .image(let asset):
                let density = targetID == document.baseLayerID ? frame.scale
                    : contentDensity(of: target, asset: asset, map: pieces.map, contentSize: pieces.contentSize, canvas: canvas)
                let content = try await imageContent(target, asset: asset, density: density, options: options, log: nil, capture: nil, canMaterialize: false)
                try Task.checkCancellation()
                unmasked = materializedContent(content)
            case .text, .shape:
                unmasked = overlayContent(target, canvas: canvas)
            case .fill(let color):
                unmasked = CIImage(color: color.ciColor).cropped(to: canvas)
            case .gradientFill(let gradient):
                unmasked = GradientRenderer.image(gradient, canvas: canvas)
            case .adjustment, .group, .unsupported:
                unmasked = nil
            }
            guard let unmasked else { throw PicshopError.unsupportedOperation("Snapshot") }
            let drawer = SnapshotMaskDrawer(maskStore: maskStore)
            if target.isMaskEnabled, let stack = target.maskStack, !stack.isEmpty {
                // Warmed here: rasters decoded and strokes drawn, so a frame draws only a stroke's new dabs.
                let space = target.isMaskLinked || target.isFill ? unmasked.extent : canvas
                _ = drawer.mask(stack, extent: space, preLocal: target.isMaskLinked ? unmasked : nil, owner: target.id)
            }
            pieces.content = nil
            payload.targetPieces = pieces
            payload.unmaskedContent = unmasked
            payload.legacyMask = materializedMask(target.mask.flatMap { loadMask($0, fitting: unmasked.extent) })
            payload.maskDrawer = drawer
        }
        payload.bytes = bytes
        guard bytes <= Self.snapshotByteLimit else { throw PicshopError.unsupportedOperation("Snapshot") }
        // A cancelled capture never replaces the renderer's current store.
        try Task.checkCancellation()
        let store = SnapshotStore(payload)
        liveSnapshot = store
        PSSignpost.event("snapshot.ready", "\(bytes / 1_048_576) MB, \(liveLayers) live")
        return RenderSnapshot(scope: scope, documentKey: RenderKeys.documentKey(document), layers: document.layers, canvasSize: document.canvasSize,
                              background: document.backgroundColor, canvas: canvas, scale: frame.scale, space: frame.space, targetIndex: targetIndex,
                              planShape: plan.map(\.layerIDs), store: store, lutURL: lutURL, colorCube: colorCube)
    }

    /// Drops the live snapshot's bitmaps (a newer snapshot, a memory trim): its frames answer nil afterwards.
    func dropSnapshot() {
        liveSnapshot?.drop()
        liveSnapshot = nil
    }

    /// The density an image layer is decoded at for this canvas (as `prepareFrame` decodes it).
    func contentDensity(of layer: Layer, asset: MediaAsset, map: PSHomography, contentSize: PSSize, canvas: CGRect) -> Double {
        let need = ContentPlacement.density(map, contentPixels: contentSize, canvasPixels: PSSize(width: Double(canvas.width), height: Double(canvas.height)))
        return Self.quantizedDensity(need * contentSize.width / max(1, asset.pixelSize.width))
    }
}
#endif
