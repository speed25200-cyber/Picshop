import Foundation
import PicshopCore

/// What an interaction moves, and so what the interactive snapshot captures (D13).
public enum InteractionScope: Hashable, Sendable {
    /// Transform, opacity, fill, blend, visibility of one layer.
    case layerPlacement(UUID)
    /// Global dials, curves, levels, colour of one image layer.
    case layerDevelop(UUID)
    /// An adjustment layer's recipe or dials.
    case adjustmentLayer(UUID)
    /// A fill or gradient layer's colour, gradient.
    case fillLayer(UUID)
    /// Layer-mask brush strokes and mask sliders (D13).
    case layerMask(UUID)

    /// The layer the interaction edits.
    public var layerID: UUID {
        switch self {
        case .layerPlacement(let id), .layerDevelop(let id), .adjustmentLayer(let id), .fillLayer(let id), .layerMask(let id): return id
        }
    }
}

#if canImport(CoreImage)
import CoreImage

/// D13: the nonisolated interactive snapshot. Built on the renderer actor at interaction start, immutable afterwards
/// (`let` properties of CIImage and value types only), so frames are graph construction on the calling thread with no
/// actor hop. The only `@unchecked Sendable` class W3 adds.
///
/// What it holds, at the interactive size:
/// - `below`: everything under the target's top-level node, composited once and materialised;
/// - the target's top-level node, drawn live each frame: the target from the current document (its placement,
///   develop recipe, fill or mask, by scope) and its group or clipping-group members as captured;
/// - above: contiguous runs of normal-mode layers flattened into one materialised image each (source-over is
///   associative, so the frame is unchanged), the other nodes live from their captured contents.
/// `covers` compares layer values (never keys), so it costs microseconds on the main actor; `frame` runs the same
/// `CompositeExecutor` as the actor.
public final class RenderSnapshot: @unchecked Sendable {
    public let scope: InteractionScope
    /// RenderKeys.documentKey at capture (logging, the caches); never recomputed per frame.
    public let documentKey: String
    /// The document as captured: its layers in order, the canvas and background.
    let layers: [Layer]
    let canvasSize: PSSize
    let background: PSColor
    /// The interactive canvas (Core Image coordinates) and its scale to the full-resolution canvas.
    let canvas: CGRect
    let scale: Double
    let space: CompositeSpace
    /// The target's top-level node index in the plan, and the plan's length and node layer lists at capture.
    let targetIndex: Int
    let planShape: [[UUID]]
    /// Emptied when the snapshot is dropped (a newer one, a memory trim): frames then answer nil.
    let store: SnapshotStore
    let lutURL: @Sendable (String) -> URL
    let colorCube: ColorCube

    init(scope: InteractionScope, documentKey: String, layers: [Layer], canvasSize: PSSize, background: PSColor, canvas: CGRect, scale: Double,
         space: CompositeSpace, targetIndex: Int, planShape: [[UUID]], store: SnapshotStore, lutURL: @escaping @Sendable (String) -> URL,
         colorCube: ColorCube) {
        self.scope = scope
        self.documentKey = documentKey
        self.layers = layers
        self.canvasSize = canvasSize
        self.background = background
        self.canvas = canvas
        self.scale = scale
        self.space = space
        self.targetIndex = targetIndex
        self.planShape = planShape
        self.store = store
        self.lutURL = lutURL
        self.colorCube = colorCube
    }

    /// The interactive canvas's pixel size.
    public var pixelSize: CGSize { canvas.size }

    /// Frees the bitmaps now (the drag ended, a newer capture, a capture nobody waits for): the renderer keeps the same
    /// store, so they would otherwise stay until the next capture or a memory warning (D13, D15). Frames answer nil.
    public nonisolated func discard() {
        store.drop()
    }

    /// Whether `frame` can draw this document (D13): the same layer ids in the same order, every non-target layer equal
    /// to its captured value, the target equal but for the scope's dynamic fields, the same canvas and background.
    public nonisolated func covers(_ document: PhotoDocument) -> Bool {
        guard store.isLive, document.layers.count == layers.count, document.canvasSize == canvasSize,
              document.backgroundColor == background else { return false }
        let target = scope.layerID
        for (index, layer) in document.layers.enumerated() {
            let captured = layers[index]
            guard layer.id == captured.id else { return false }
            if layer.id == target {
                guard Self.sameExceptDynamicFields(captured, layer, scope: scope) else { return false }
            } else if layer != captured {
                return false
            }
        }
        return true
    }

    /// The frame, graph construction only (≤ 1 ms for 10 layers on device), or nil (the caller renders through the
    /// actor): not covered, dropped, or the plan around the target changed shape.
    public nonisolated func frame(_ document: PhotoDocument) -> CIImage? {
        guard covers(document), let payload = store.current else { return nil }
        let plan = CompositePlan.make(document)
        guard plan.map(\.layerIDs) == planShape, targetIndex < plan.count else { return nil }
        let targetID = scope.layerID
        guard let target = document.layer(id: targetID) else { return nil }
        let canvas = self.canvas
        let groupMap = Self.groupMap(of: target, in: document, canvasSize: canvasSize)
        let targetContent = targetContent(target, document: document, payload: payload)
        let targetMask = targetMask(target, document: document, payload: payload)
        let recipe = targetRecipe(target)
        let inputs = CompositeInputs(
            canvas: canvas, background: background, space: space,
            content: { id in
                if id == targetID { return targetContent }
                if let member = payload.members[id] {
                    // A moving group's children follow its transform (placed with the group's map, D13).
                    if target.isGroup, member.followsGroup, case .layerPlacement = self.scope {
                        var pieces = member.pieces
                        pieces.map = groupMap.map { member.ownMap.then($0) } ?? member.ownMap
                        return pieces.placed(on: canvas)
                    }
                    return member.placed
                }
                return payload.frozen[id]
            },
            mask: { id in id == targetID ? targetMask : payload.masks[id] },
            adjust: { id, backdrop in
                let used = id == targetID ? recipe : payload.recipes[id]
                guard let used, !used.isNeutral else { return backdrop }
                return DevelopRenderer.apply(used, to: backdrop, scale: self.scale, cubes: .nonBlocking, colorCube: self.colorCube, lutURL: self.lutURL)
            })
        var result = CompositeExecutor.run([plan[targetIndex]], onto: payload.below, inputs: inputs, backdropIsOpaque: payload.belowIsOpaque)
        for item in payload.above {
            switch item {
            case .flat(let image):
                result = image.composited(over: result).cropped(to: canvas)
            case .live(let index):
                guard index < plan.count else { return nil }
                result = CompositeExecutor.run([plan[index]], onto: result, inputs: inputs, backdropIsOpaque: payload.belowIsOpaque)
            }
        }
        return CompositeExecutor.fromSpace(result, inputs: inputs)
    }

    /// The frame and the overlay it carries (D13, D17): none without a request; for a `.layerMask` snapshot, the mask
    /// being painted (legacy × stack, placed as the frame places the layer) drawn in the request's style, so the
    /// layer-mask brush's frames stay on the main actor. nil: not covered, or an overlay this snapshot cannot draw
    /// (the caller renders through the actor).
    public nonisolated func frameAndOverlay(_ document: PhotoDocument, overlay request: MaskOverlayRequest?) -> (image: CIImage, overlay: CIImage?)? {
        guard let request else {
            guard let image = frame(document) else { return nil }
            return (image: image, overlay: nil)
        }
        guard case .layerMask(let id) = scope, request.target == .layerMask(id) else { return nil }
        guard let image = frame(document), let payload = store.current, let target = document.layer(id: id) else { return nil }
        guard let mask = layerMaskOnCanvas(target, payload: payload) else { return (image: image, overlay: nil) }
        let overlay = MaskOverlayRenderer.overlay(mask: mask, frame: image, style: request.style, color: request.color, opacity: request.opacity,
                                                  extent: canvas)
        return (image: image, overlay: overlay)
    }

    /// The target's mask on the canvas as `PhotoRenderer.layerMaskOnCanvas` draws it for the actor's overlay: the
    /// legacy mask × a linked stack in content space, placed with the layer; an unlinked stack in canvas space; the
    /// legacy mask alone when the stack is off. The drawer's calls match `targetContent`'s, so they hit its cache.
    private func layerMaskOnCanvas(_ target: Layer, payload: SnapshotPayload) -> CIImage? {
        guard let unmasked = payload.unmaskedContent, let pieces = payload.targetPieces, let drawer = payload.maskDrawer else { return nil }
        let canvas = self.canvas
        var content: CIImage? = target.mask != nil ? payload.legacyMask : nil
        var onCanvas: CIImage?
        if target.isMaskEnabled, let stack = target.maskStack, !stack.isEmpty {
            if target.isMaskLinked || target.isFill {
                let drawn = drawer.mask(stack, extent: unmasked.extent, preLocal: unmasked, owner: target.id)
                content = content.map { PhotoRenderer.multiply($0, drawn) } ?? drawn
            } else {
                onCanvas = drawer.mask(stack, extent: canvas, preLocal: nil, owner: target.id)
            }
        }
        let placed = content.map { target.isFill ? $0.cropped(to: canvas) : ContentPlacement.placeMask($0, map: pieces.map, canvas: canvas) }
        switch (placed, onCanvas) {
        case let (a?, b?): return PhotoRenderer.multiply(a, b).cropped(to: canvas)
        case let (a?, nil): return a
        case let (nil, b?): return b.cropped(to: canvas)
        case (nil, nil): return nil
        }
    }

    // MARK: - The target, from the current document

    /// The target layer's placed pixels for this frame (nil for adjustment layers and groups, which have none).
    private func targetContent(_ target: Layer, document: PhotoDocument, payload: SnapshotPayload) -> CIImage? {
        let canvas = self.canvas
        switch scope {
        case .layerPlacement:
            guard let pieces = payload.targetPieces else { return payload.frozen[target.id] }
            var moved = pieces
            moved.map = placementMap(target, contentSize: pieces.contentSize, document: document)
            return moved.placed(on: canvas)
        case .layerDevelop:
            guard let develop = payload.develop, var pieces = payload.targetPieces else { return nil }
            let recipe = DevelopRenderer.Recipe(edits: target.edits)
            var image = DevelopRenderer.apply(recipe, to: develop.preDevelop, scale: develop.effectiveScale, cubes: .nonBlocking,
                                              colorCube: colorCube, lutURL: lutURL)
            // Every local mask reads the developed picture before any local adjustment (`applyLocalAdjustments`).
            let preLocal = image
            for adjustment in target.edits.resolvedLocalAdjustments.prefix(LocalAdjustment.maxPerLayer) {
                guard develop.includesLocalAdjustments, adjustment.isVisible, !adjustment.isNeutral else { continue }
                let mask: CIImage
                if let frozen = develop.localMasks[adjustment.id] {
                    mask = frozen
                } else if develop.liveLocalMasks.contains(adjustment.id), let drawer = develop.maskDrawer {
                    mask = drawer.mask(adjustment.stack, extent: preLocal.extent, preLocal: preLocal, owner: adjustment.id)
                } else {
                    continue
                }
                image = LocalAdjustRenderer.apply(adjustment, mask: mask, to: image, scale: develop.effectiveScale, interactive: true, nonBlocking: true)
            }
            // The layer's own linked masks on the finished content (`layerMasked`): a range reads that content.
            var linked = develop.linkedMask
            if develop.drawsLinkedStackLive, let drawer = develop.maskDrawer, let stack = target.maskStack {
                let drawn = drawer.mask(stack, extent: image.extent, preLocal: image, owner: target.id)
                linked = linked.map { PhotoRenderer.multiply($0, drawn) } ?? drawn
            }
            if let linked { image = AdjustmentPipeline.applyingAlpha(mask: linked, to: image) }
            pieces.content = image
            return pieces.placed(on: canvas)
        case .fillLayer:
            let fill: CIImage
            switch target.content {
            case .fill(let color): fill = CIImage(color: color.ciColor).cropped(to: canvas)
            case .gradientFill(let gradient): fill = GradientRenderer.image(gradient, canvas: canvas)
            default: return payload.frozen[target.id]
            }
            guard let mask = payload.targetFillMask else { return fill }
            return AdjustmentPipeline.applyingAlpha(mask: mask, to: fill).cropped(to: canvas)
        case .layerMask:
            guard let unmasked = payload.unmaskedContent, var pieces = payload.targetPieces, let drawer = payload.maskDrawer else { return nil }
            var image = unmasked
            let extent = unmasked.extent
            if target.mask != nil, let legacy = payload.legacyMask { image = AdjustmentPipeline.applyingAlpha(mask: legacy, to: image) }
            pieces.canvasMask = nil
            if target.isMaskEnabled, let stack = target.maskStack, !stack.isEmpty {
                if target.isMaskLinked || target.isFill {
                    let mask = drawer.mask(stack, extent: extent, preLocal: unmasked, owner: target.id)
                    image = AdjustmentPipeline.applyingAlpha(mask: mask, to: image)
                } else {
                    pieces.canvasMask = drawer.mask(stack, extent: canvas, preLocal: nil, owner: target.id)
                }
            }
            pieces.content = image
            return pieces.placed(on: canvas)
        case .adjustmentLayer:
            return nil
        }
    }

    /// The target's own mask on the canvas (adjustment layers, groups); nil for the others.
    private func targetMask(_ target: Layer, document: PhotoDocument, payload: SnapshotPayload) -> CIImage? {
        guard let mask = payload.targetCanvasMask else { return nil }
        if target.isGroup, target.isMaskLinked, case .layerPlacement = scope, target.transform != .identity {
            let map = LayerPlacement.map(for: target, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
            return ContentPlacement.placeMask(mask, map: map, canvas: canvas)
        }
        return mask
    }

    /// An adjustment layer's recipe from the current document (`.adjustmentLayer`); captured otherwise.
    private func targetRecipe(_ target: Layer) -> DevelopRenderer.Recipe? {
        guard case .adjustment(let adjustments) = target.content else { return nil }
        return DevelopRenderer.Recipe(edits: target.edits, extra: adjustments)
    }

    /// The target's placement map from the current document (its transform, or its text element's centre).
    private func placementMap(_ layer: Layer, contentSize: PSSize, document: PhotoDocument) -> PSHomography {
        let isBase = layer.id == document.baseLayerID
        var map = isBase ? .identity : LayerPlacement.map(for: layer, contentSize: contentSize, canvasSize: canvasSize, isBase: false)
        if !isBase, let group = Self.groupMap(of: layer, in: document, canvasSize: canvasSize) { map = map.then(group) }
        return map
    }

    static func groupMap(of layer: Layer, in document: PhotoDocument, canvasSize: PSSize) -> PSHomography? {
        if layer.isGroup {
            guard layer.transform != .identity else { return nil }
            return LayerPlacement.map(for: layer, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
        }
        guard let parentID = layer.parentID, let group = document.layer(id: parentID), group.isGroup, group.transform != .identity else { return nil }
        return LayerPlacement.map(for: group, contentSize: canvasSize, canvasSize: canvasSize, isBase: false)
    }

    // MARK: - Dynamic fields (D13)

    /// The target is equal to its captured value except for what the scope moves.
    static func sameExceptDynamicFields(_ captured: Layer, _ current: Layer, scope: InteractionScope) -> Bool {
        var moved = current
        switch scope {
        case .layerPlacement:
            moved.transform = captured.transform
            moved.opacity = captured.opacity
            moved.fillOpacity = captured.fillOpacity
            moved.blendMode = captured.blendMode
            if case .text(let before) = captured.content, case .text(var element) = current.content {
                element.center = before.center
                element.rotation = before.rotation
                moved.content = .text(element)
            }
        case .layerDevelop:
            guard placedOperations(captured.edits) == placedOperations(current.edits) else { return false }
            let before = captured.edits.resolvedLocalAdjustments, after = current.edits.resolvedLocalAdjustments
            guard before.count == after.count, zip(before, after).allSatisfy({ $0.id == $1.id && $0.stack == $1.stack }) else { return false }
            moved.edits = captured.edits
        case .adjustmentLayer:
            moved.content = captured.content
            moved.edits = captured.edits
            moved.opacity = captured.opacity
            moved.fillOpacity = captured.fillOpacity
            moved.blendMode = captured.blendMode
            moved.recipeKind = captured.recipeKind
        case .fillLayer:
            guard captured.isFill, current.isFill else { return false }
            moved.content = captured.content
            moved.opacity = captured.opacity
            moved.fillOpacity = captured.fillOpacity
            moved.blendMode = captured.blendMode
        case .layerMask:
            moved.maskStack = captured.maskStack
            moved.isMaskEnabled = captured.isMaskEnabled
            // The first stroke converts a legacy mask into the stack and clears it (D8).
            if current.mask == nil { moved.mask = captured.mask }
        }
        return moved == captured
    }

    /// The operations the develop step does not draw (the loop's: geometry, retouch, expensive): equal, the
    /// captured pre-develop picture still holds. Local adjustments are compared apart (their stacks are captured).
    static func placedOperations(_ edits: EditStack) -> [EditOperation] {
        edits.operations.filter { !isDevelop($0.kind) }
    }

    static func isDevelop(_ kind: EditOperation.Kind) -> Bool {
        switch kind {
        case .adjust, .adjustments, .toneCurve, .levels, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut, .localAdjust:
            return true
        default:
            return false
        }
    }
}

/// The heavy part of a snapshot, emptied when it is dropped (a newer snapshot, a memory trim): the bitmaps go, and
/// frames answer nil.
final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: SnapshotPayload?

    init(_ payload: SnapshotPayload) {
        self.payload = payload
    }

    var current: SnapshotPayload? { lock.withLock { payload } }
    var isLive: Bool { lock.withLock { payload != nil } }

    func drop() {
        lock.withLock { payload = nil }
    }
}

/// What a snapshot captured (D13), all at the interactive size.
struct SnapshotPayload {
    enum Above {
        /// A run of normal-mode layers flattened onto transparent (in the compositor's space).
        case flat(CIImage)
        /// A node drawn live (its index in the plan) from the captured contents.
        case live(Int)
    }

    /// A member of the target's top-level node, as captured: its pieces and its own map (before a group's transform).
    struct Member {
        var pieces: PhotoRenderer.LayerPieces
        var ownMap: PSHomography
        var placed: CIImage?
        /// Placed through its group's transform (image, text and shape layers; fills cover the canvas).
        var followsGroup: Bool
    }

    /// `.layerDevelop`: the pre-develop picture and the local masks, in content space: static stacks frozen, colour
    /// and luminance ranges drawn by `maskDrawer` from each frame's own pixels, as the actor draws them.
    struct Develop {
        var preDevelop: CIImage
        var effectiveScale: Double
        /// Static local masks, frozen at capture.
        var localMasks: [UUID: CIImage]
        /// Local adjustments whose range mask reads the developed picture: drawn each frame.
        var liveLocalMasks: Set<UUID>
        /// The legacy mask × a static linked stack (or the legacy mask alone when the stack is drawn live).
        var linkedMask: CIImage?
        /// The linked stack reads the finished content (a range): drawn each frame.
        var drawsLinkedStackLive: Bool
        var maskDrawer: SnapshotMaskDrawer?
        var includesLocalAdjustments: Bool
    }

    /// Everything under the target's top-level node, materialised, in the compositor's space.
    var below: CIImage
    var belowIsOpaque: Bool
    var above: [Above]
    /// Placed contents (linear) of the layers of live nodes above.
    var frozen: [UUID: CIImage]
    /// The target node's other layers.
    var members: [UUID: Member]
    /// Adjustment and group masks on the canvas (non-target), and their recipes.
    var masks: [UUID: CIImage]
    var recipes: [UUID: DevelopRenderer.Recipe]
    /// The target's pieces before placement (content with its linked masks, map, canvas mask, content size).
    var targetPieces: PhotoRenderer.LayerPieces?
    /// The target's own canvas mask (adjustment layer, group).
    var targetCanvasMask: CIImage?
    /// `.fillLayer`: the fill's combined mask on the canvas.
    var targetFillMask: CIImage?
    var develop: Develop?
    /// `.layerMask`: the content without any mask, its legacy mask (content space), and the brush drawer.
    var unmaskedContent: CIImage?
    var legacyMask: CIImage?
    var maskDrawer: SnapshotMaskDrawer?
    /// Bytes materialised at capture (D13 budget).
    var bytes: Int
}

/// The layer-mask brush for snapshot frames (D13): its own rasterizer (decoded rasters, the stroke cache's append
/// path), behind a lock, so a frame on the main actor draws only the new dabs of a stroke.
final class SnapshotMaskDrawer: @unchecked Sendable {
    private let lock = NSLock()
    private let rasterizer: MaskRasterizer

    init(maskStore: MaskStore) {
        rasterizer = MaskRasterizer(maskStore: maskStore)
    }

    func mask(_ stack: MaskStack, extent: CGRect, preLocal: CIImage?, owner: UUID) -> CIImage {
        lock.withLock { rasterizer.mask(stack, extent: extent, preLocal: preLocal, mode: .interactive(target: nil), owner: owner) }
    }
}
#endif
