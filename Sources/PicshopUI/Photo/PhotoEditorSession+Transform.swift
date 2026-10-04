#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
import PicshopIntent
import PicshopImaging

// Free transform (W3, D10): transform mode on one layer, its handle drags (`TransformHandles.drag`, every frame from
// the drag's start), smart guides and snapping (`SnapEngine`, the lines computed once per session), rotation snaps at
// 15°, the transform readout at ≤ 15 Hz, pinch and twist about the centre, nudges, alignment, Réinitialiser and fit or
// fill. A drag is one undo step on the `.layerPlacement` interactive snapshot (D13): per frame the session only builds
// the transform and the pump draws the snapshot's frame; the overlay and the guides are the only views that redraw.
extension PhotoEditorSession {
    static let transformLabel = "Transform"

    /// The rigid tick of a snap (`.impact(flexibility: .rigid, intensity: 0.6)`), throttled to 16 ms (design audit).
    private static let snapHaptic = UIImpactFeedbackGenerator(style: .rigid)

    private func snapTick() {
        guard Haptics.isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - layerState.lastSnapHaptic >= 0.016 else { return }
        layerState.lastSnapHaptic = now
        Self.snapHaptic.impactOccurred(intensity: 0.6)
    }

    // MARK: - Transform mode

    /// « Transformer »: handles on the layer (image, text or shape; never the base), the snap lines computed once.
    func beginTransformMode(_ id: UUID, mode: TransformMode? = nil) {
        guard FeatureFlags.isOn(.freeTransform), let layer = document.layer(id: id) else { return }
        guard id != document.baseLayerID else {
            refuseLayerEdit(.baseLayer, layerID: id)
            return
        }
        switch layer.content {
        case .image, .text, .shape: break
        case .group, .fill, .gradientFill, .adjustment, .unsupported:
            refuseLayerEdit(.notApplicable, layerID: id)
            return
        }
        guard layerAllows(.placement, on: id) else { return }
        if layerState.mode == .maskPaint { endLayerMaskPaint() }
        if activeTool != .layers { activeTool = .layers }
        if document.selectedLayerID != id { selectLayer(id) }
        layerState.mode = .transform
        layerState.transformTarget = id
        if let mode { layerState.transformMode = mode }
        layerState.transformUndoDepth = undoLabels.count
        layerState.snapTargets = snapTargets(excluding: id)
        refreshTransformOverlay()
        // D13: the snapshot is captured now, so the first drag of the handles starts on it (kept between drags).
        if interaction == nil { requestInteractionSnapshot(.layerPlacement(id)) }
        Haptics.tick()
    }

    /// OK, a tap outside the quad, or Calques closing: transform mode ends (the drags already committed stay).
    func endTransformMode() {
        if layerState.drag != nil { endTransformDrag() }
        guard layerState.mode == .transform || layerState.transformTarget != nil else { return }
        layerState.mode = .select
        layerState.transformTarget = nil
        if !layerState.liveQuad.isEmpty { layerState.liveQuad = [] }
        if !layerState.guides.isEmpty { layerState.guides = [] }
        layerState.transform.isVisible = false
        releaseKeptInteractionSnapshot()
    }

    /// « Annuler »: the drags made in this transform session are undone, then transform mode ends.
    func cancelTransformMode() {
        if layerState.drag != nil { cancelTransformDrag() }
        let made = undoLabels.count - layerState.transformUndoDepth
        if made > 0, undoLabels.suffix(made).allSatisfy({ $0 == Self.transformLabel || $0 == "Align Layers" }) {
            undo(steps: made)
        }
        endTransformMode()
    }

    /// The `transformLayer:<uuid>[:<mode>]` effect: transform mode on that layer, in that mode (« Tire les coins pour la
    /// perspective »).
    func handleTransformEffect(_ argument: String) {
        let parts = argument.split(separator: ":").map(String.init)
        guard let first = parts.first, let id = UUID(uuidString: first) else { return }
        let mode = parts.count > 1 ? TransformMode(rawValue: parts[1]) : nil
        beginTransformMode(id, mode: mode)
    }

    /// A mode chip (Libre, Proportionnel, Incliner, Déformer, Perspective).
    func setTransformMode(_ mode: TransformMode) {
        guard layerState.transformMode != mode else { return }
        layerState.transformMode = mode
        Haptics.tick()
    }

    /// The overlay's corners and the readout from the document as it is (after a step, an undo).
    func refreshTransformOverlay() {
        guard let id = layerState.transformTarget, let layer = (interactiveDocument ?? document).layer(id: id),
              let size = layerContentSize(id) else { return }
        let canvas = document.canvasSize
        let quad = LayerPlacement.quad(for: layer, contentSize: size, canvasSize: canvas, isBase: false)
        if quad != layerState.liveQuad { layerState.liveQuad = quad }
        layerState.transform.update(LayerTransformFigures.of(layer, contentSize: size, canvasSize: canvas, isBase: false))
    }

    /// The snap lines (D10): canvas edges, centre and thirds, the other visible layers' bounds.
    func snapTargets(excluding id: UUID) -> SnapTargets {
        guard layerState.guidesEnabled else { return SnapTargets() }
        var sizes: [UUID: PSSize] = [:]
        for layer in document.layers where layer.isText {
            if let size = Self.contentSize(of: layer, canvasSize: document.canvasSize) { sizes[layer.id] = size }
        }
        return SnapEngine.targets(in: document, excluding: [id], contentSizes: sizes, includeThirds: true)
    }

    // MARK: - Drags (handles, pick-drags, pinch and twist)

    /// The handle under a view point, given the picture's frame on screen (corner > edge > rotate > inside).
    func transformHandle(at viewPoint: CGPoint, frame: CGRect) -> TransformHandleKind? {
        guard layerState.mode == .transform, layerState.liveQuad.count == 4 else { return nil }
        let viewQuad = layerState.liveQuad.map { PSPoint(x: Double(frame.minX) + $0.x * Double(frame.width), y: Double(frame.minY) + $0.y * Double(frame.height)) }
        return TransformHandles.hit(PSPoint(x: Double(viewPoint.x), y: Double(viewPoint.y)), viewQuad: viewQuad)
    }

    /// A drag begins on a handle (transform mode) or on the selected layer (a pick-drag, `.inside`): one undo step
    /// on the `.layerPlacement` snapshot. False when a lock refuses it.
    @discardableResult
    func beginTransformDrag(_ kind: TransformHandleKind, layerID: UUID? = nil, frame: CGRect) -> Bool {
        guard let id = layerID ?? layerState.transformTarget, let layer = document.layer(id: id), id != document.baseLayerID,
              let size = layerContentSize(id), frame.width > 0, frame.height > 0 else { return false }
        guard layerAllows(.placement, on: id) else { return false }
        let canvas = document.canvasSize
        if layerState.mode != .transform {
            // A pick-drag moves the layer without handles: its own snap lines.
            layerState.snapTargets = snapTargets(excluding: id)
        }
        let start = LayerPlacement.effectiveTransform(of: layer)
        layerState.drag = LayerTransformDrag(layerID: id, kind: kind, start: start,
                                             startQuad: LayerPlacement.quad(for: layer, contentSize: size, canvasSize: canvas, isBase: false),
                                             contentSize: size, canvasSize: canvas,
                                             pointSize: PSSize(width: 1 / Double(frame.width), height: 1 / Double(frame.height)))
        layerState.isCanvasGestureActive = true
        layerState.transform.showsPosition = kind == .inside
        layerState.transform.isVisible = true
        beginInteraction(label: Self.transformLabel, scope: .layerPlacement(id))
        return true
    }

    /// One drag frame: `translation` (since the drag began) and `location` are canvas-normalised. The handle's
    /// result, then snapping (a move snaps its box's edges and centre, an edge its own line, the scale to 100 % of the
    /// fit, a rotation to 15°), then the edit on the dragged copy.
    func transformDrag(translation: PSPoint, location: PSPoint, anchorAtCenter: Bool) {
        guard var drag = layerState.drag else { return }
        let mode = layerState.transformMode
        var transform = TransformHandles.drag(drag.kind, mode: mode, start: drag.start, startQuad: drag.startQuad, translation: translation,
                                              location: location, anchorAtCenter: anchorAtCenter, contentSize: drag.contentSize,
                                              canvasSize: drag.canvasSize)
        var guides: [SnapGuide] = []
        var snapDistance: Double?
        let threshold = PSSize(width: SnapEngine.thresholdPoints * drag.pointSize.width, height: SnapEngine.thresholdPoints * drag.pointSize.height)
        let snapping = layerState.guidesEnabled
        switch drag.kind {
        case .inside where snapping:
            let box = bounds(of: transform, drag: drag)
            let snap = SnapEngine.snapMove(box, targets: layerState.snapTargets, threshold: threshold, previous: layerState.guides)
            transform = Self.translated(transform, by: snap.offset)
            guides = snap.guides
            if snap.didSnapNewly { snapTick() }
            if !guides.isEmpty { snapDistance = 0 }
        case .edge(let index) where snapping && Self.isAxisAligned(transform):
            let box = bounds(of: transform, drag: drag)
            let axis: SnapGuide.Axis = index == 1 || index == 3 ? .vertical : .horizontal
            let value: Double
            switch index {
            case 0: value = box.minY
            case 1: value = box.maxX
            case 2: value = box.maxY
            default: value = box.minX
            }
            let snapped = SnapEngine.snapEdge(value, axis: axis, targets: layerState.snapTargets, threshold: axis == .vertical ? threshold.width : threshold.height,
                                              previous: layerState.guides)
            if let guide = snapped.guide, abs(snapped.value - value) > 1e-12 {
                // Re-run the handle with the translation corrected along the snapped axis.
                var corrected = translation
                if axis == .vertical { corrected.x += snapped.value - value } else { corrected.y += snapped.value - value }
                transform = TransformHandles.drag(drag.kind, mode: mode, start: drag.start, startQuad: drag.startQuad, translation: corrected,
                                                  location: location, anchorAtCenter: anchorAtCenter, contentSize: drag.contentSize,
                                                  canvasSize: drag.canvasSize)
                guides = [guide]
            } else if let guide = snapped.guide {
                guides = [guide]
            }
            if !guides.isEmpty, !layerState.guides.contains(where: { $0.axis == axis }) { snapTick() }
        case .corner(let index) where transform.quad == nil && (mode == .free || mode == .uniform):
            // Scale snaps to 100 % of the natural fit (within 1.5 %), the opposite corner held.
            let snapped = SnapEngine.snapScale(transform.scale)
            if snapped.snapped, abs(transform.scale - snapped.scale) > 1e-12 {
                transform = rescaled(transform, to: snapped.scale, holding: (index + 2) % 4, anchorAtCenter: anchorAtCenter, drag: drag)
            }
            if snapped.snapped, !drag.scaleSnapped { snapTick() }
            drag.scaleSnapped = snapped.snapped
        case .rotate:
            let snap = TransformHandles.rotationSnap(transform.rotation)
            if snap.snapped, transform.quad == nil {
                transform.rotation = snap.degrees
                if !drag.rotationSnapped { snapTick() }
            }
            drag.rotationSnapped = snap.snapped
        default:
            break
        }
        layerState.drag = drag
        applyDragFrame(transform, drag: drag, guides: guides, snap: snapDistance)
    }

    /// Pinch (transform mode): a uniform scale about the centre; twist: a rotation about the centre, snapped at 15°.
    func transformPinch(magnification: Double, rotation degrees: Double) {
        guard let drag = layerState.drag, magnification.isFinite, magnification > 0.01 else { return }
        var transform = drag.start
        if let quad = drag.start.quad {
            let center = LayerAccessibility.centroidOf(quad)
            let angle = degrees * .pi / 180
            transform.quad = quad.map { point in
                let dx = (point.x - center.x) * drag.canvasSize.width * magnification
                let dy = (point.y - center.y) * drag.canvasSize.height * magnification
                return PSPoint(x: center.x + (dx * cos(angle) - dy * sin(angle)) / drag.canvasSize.width,
                               y: center.y + (dx * sin(angle) + dy * cos(angle)) / drag.canvasSize.height)
            }
        } else {
            transform.scale = max(0.01, drag.start.scale * magnification)
            let turned = drag.start.rotation + degrees
            let snap = TransformHandles.rotationSnap(turned)
            transform.rotation = snap.degrees
            if snap.snapped, !(layerState.drag?.rotationSnapped ?? false) { snapTick() }
            layerState.drag?.rotationSnapped = snap.snapped
        }
        applyDragFrame(transform, drag: drag, guides: [], snap: nil)
    }

    /// The drag ends: one commit, the readout exact, the guides gone.
    func endTransformDrag() {
        guard layerState.drag != nil else { return }
        layerState.drag = nil
        layerState.isCanvasGestureActive = false
        if !layerState.guides.isEmpty { layerState.guides = [] }
        endInteraction()
        if layerState.mode == .transform {
            refreshTransformOverlay()
        } else {
            layerState.transform.isVisible = false
        }
    }

    /// A second finger or the system took the drag: it goes back, nothing committed.
    func cancelTransformDrag() {
        guard layerState.drag != nil else { return }
        layerState.drag = nil
        layerState.isCanvasGestureActive = false
        if !layerState.guides.isEmpty { layerState.guides = [] }
        cancelInteraction()
        refreshTransformOverlay()
        if layerState.mode != .transform { layerState.transform.isVisible = false }
    }

    /// One frame on the dragged copy: the edit, the overlay's corners, the guides, the readout at ≤ 15 Hz.
    private func applyDragFrame(_ transform: LayerTransform, drag: LayerTransformDrag, guides: [SnapGuide], snap: Double?) {
        let id = drag.layerID
        let edited = transform
        interactiveEdit(label: Self.transformLabel) { document in
            document.applyLayerEdit(.transform(edited), to: id)
        }
        if guides != layerState.guides { layerState.guides = guides }
        guard let layer = interactiveDocument?.layer(id: id) else { return }
        layerState.liveQuad = LayerPlacement.quad(for: layer, contentSize: drag.contentSize, canvasSize: drag.canvasSize, isBase: false)
        let now = ProcessInfo.processInfo.systemUptime
        if now - layerState.lastReadout >= 1.0 / 15 {
            layerState.lastReadout = now
            layerState.transform.update(LayerTransformFigures.of(layer, contentSize: drag.contentSize, canvasSize: drag.canvasSize, isBase: false), snap: snap)
        }
    }

    /// The placed bounds of the dragged layer under `transform`.
    private func bounds(of transform: LayerTransform, drag: LayerTransformDrag) -> PSRect {
        guard let layer = document.layer(id: drag.layerID) else { return PSRect(x: 0, y: 0, width: 0, height: 0) }
        var moved = layer
        Self.write(transform, into: &moved)
        return LayerPlacement.bounds(for: moved, contentSize: drag.contentSize, canvasSize: drag.canvasSize, isBase: false)
    }

    /// `transform` (an effective one) written the way `applyLayerEdit(.transform)` stores it, on a copy of the layer.
    static func write(_ transform: LayerTransform, into layer: inout Layer) {
        if case .text(var element) = layer.content {
            element.center = transform.center
            element.rotation = transform.rotation
            layer.content = .text(element)
            var stored = transform
            stored.center = layer.transform.center
            stored.rotation = layer.transform.rotation
            layer.transform = stored
        } else {
            layer.transform = transform
        }
    }

    /// No rotation off a quarter turn, no skew, no quad: edges are horizontal and vertical lines.
    static func isAxisAligned(_ transform: LayerTransform) -> Bool {
        guard transform.quad == nil, abs(transform.skewX) < 0.01, abs(transform.skewY) < 0.01 else { return false }
        let turn = transform.rotation.truncatingRemainder(dividingBy: 90)
        return abs(turn) < 0.01 || abs(abs(turn) - 90) < 0.01
    }

    /// `transform` at another uniform scale with one start corner (or the centre) held in place.
    private func rescaled(_ transform: LayerTransform, to scale: Double, holding corner: Int, anchorAtCenter: Bool, drag: LayerTransformDrag) -> LayerTransform {
        guard let layer = document.layer(id: drag.layerID) else { return transform }
        var result = transform
        result.scale = scale
        guard !anchorAtCenter else { return result }
        var moved = layer
        Self.write(result, into: &moved)
        let quad = LayerPlacement.quad(for: moved, contentSize: drag.contentSize, canvasSize: drag.canvasSize, isBase: false)
        guard quad.count == 4, drag.startQuad.count == 4 else { return result }
        let anchor = drag.startQuad[corner]
        return Self.translated(result, by: PSPoint(x: anchor.x - quad[corner].x, y: anchor.y - quad[corner].y))
    }

    // MARK: - Numeric edits (the transform rows, VoiceOver, nudges)

    /// A transform field from the inspector's rows (`layerTransform` params): x and y move the bounds' centre
    /// (0…1000), scale is % of the natural fit, scaleX and scaleY % of the natural size, rotation and skews in degrees.
    func transformField(_ param: String, of layerID: UUID) -> Double? {
        guard let layer = document.layer(id: layerID) else { return nil }
        let transform = LayerPlacement.effectiveTransform(of: layer)
        let figures = LayerTransformFigures.of(layer, contentSize: layerContentSize(layerID), canvasSize: document.canvasSize,
                                               isBase: layerID == document.baseLayerID)
        switch param {
        case "x": return document.canvasSize.width > 0 ? figures.x / document.canvasSize.width * 1000 : nil
        case "y": return document.canvasSize.height > 0 ? figures.y / document.canvasSize.height * 1000 : nil
        case "scale": return 100 * transform.scale
        case "scaleX": return figures.widthPercent
        case "scaleY": return figures.heightPercent
        case "rotation": return figures.rotation
        case "skewX": return transform.skewX
        case "skewY": return transform.skewY
        default: return nil
        }
    }

    /// The transform with one field set (see `transformField`); nil when the field does not apply.
    func transform(_ layerID: UUID, setting param: String, to value: Double, in document: PhotoDocument) -> LayerTransform? {
        guard let layer = document.layer(id: layerID), value.isFinite else { return nil }
        var transform = LayerPlacement.effectiveTransform(of: layer)
        let canvas = document.canvasSize
        switch param {
        case "x", "y":
            guard let current = transformField(param, of: layerID) else { return nil }
            let delta = (value - current) / 1000
            transform = Self.translated(transform, by: param == "x" ? PSPoint(x: delta, y: 0) : PSPoint(x: 0, y: delta))
        case "scale":
            guard transform.quad == nil else { return nil }
            transform.scale = max(0.01, value / 100)
        case "scaleX":
            guard transform.quad == nil, transform.scale > 0 else { return nil }
            transform.scaleX = (transform.scaleX < 0 ? -1 : 1) * max(0.01, value / 100 / transform.scale)
        case "scaleY":
            guard transform.quad == nil, transform.scale > 0 else { return nil }
            transform.scaleY = (transform.scaleY < 0 ? -1 : 1) * max(0.01, value / 100 / transform.scale)
        case "rotation":
            guard transform.quad == nil else { return nil }
            transform.rotation = value
        case "skewX":
            guard transform.quad == nil else { return nil }
            transform.skewX = value.clamped(to: -80...80)
        case "skewY":
            guard transform.quad == nil else { return nil }
            transform.skewY = value.clamped(to: -80...80)
        default:
            return nil
        }
        _ = canvas
        return transform
    }

    /// A transform row's value: during a slider drag on the dragged copy, else one step.
    func setTransformField(_ param: String, value: Double, layerID: UUID) {
        if interaction == nil, !layerAllows(.placement, on: layerID) { return }
        let session = self
        interactiveEdit(label: Self.transformLabel) { document in
            guard let transform = session.transform(layerID, setting: param, to: value, in: document) else { return }
            document.applyLayerEdit(.transform(transform), to: layerID)
        }
        refreshTransformOverlay()
    }

    /// Arrow nudges (hardware keyboard, VoiceOver): `dx`, `dy` in screen points at the current zoom, one step.
    func nudgeLayer(_ id: UUID, dx: Double, dy: Double, pointSize: PSSize) {
        guard let layer = document.layer(id: id), id != document.baseLayerID else { return }
        let moved = Self.translated(LayerPlacement.effectiveTransform(of: layer), by: PSPoint(x: dx * pointSize.width, y: dy * pointSize.height))
        applyLayerEdit(.transform(moved), to: id, label: Self.transformLabel)
        refreshTransformOverlay()
    }

    /// A handle adjusted by VoiceOver (±5 % or ±5°), one step.
    func adjustHandle(_ kind: TransformHandleKind, increment: Bool) {
        guard let id = layerState.transformTarget, let layer = document.layer(id: id),
              let adjusted = LayerAccessibility.adjusted(kind, transform: LayerPlacement.effectiveTransform(of: layer), increment: increment) else { return }
        applyLayerEdit(.transform(adjusted), to: id, label: Self.transformLabel)
        refreshTransformOverlay()
    }

    /// « Réinitialiser »: the natural fit, centred, no rotation, skew or corners (the quad cleared, D10).
    func resetTransform(_ id: UUID) {
        guard document.layer(id: id) != nil else { return }
        applyLayerEdit(.transform(.identity), to: id, label: Self.transformLabel)
        refreshTransformOverlay()
        Haptics.confirm()
    }

    /// « Ajuster » / « Remplir »: the whole content inside the canvas, or the canvas covered; centred, upright.
    func fitLayer(_ id: UUID, fill: Bool) {
        guard let size = layerContentSize(id), size.width > 0, size.height > 0 else { return }
        let canvas = document.canvasSize
        let natural = LayerPlacement.fitScale(contentSize: size, canvasSize: canvas)
        let target = fill ? max(canvas.width / size.width, canvas.height / size.height) : min(canvas.width / size.width, canvas.height / size.height)
        let transform = LayerTransform(center: PSPoint(x: 0.5, y: 0.5), scale: target / max(1e-9, natural))
        applyLayerEdit(.transform(transform), to: id, label: Self.transformLabel)
        refreshTransformOverlay()
        Haptics.confirm()
    }

    /// Flip horizontal or vertical (the `layerTransform.flip` values).
    func flipLayer(_ id: UUID, horizontal: Bool) {
        guard let layer = document.layer(id: id) else { return }
        var transform = LayerPlacement.effectiveTransform(of: layer)
        if let quad = transform.quad, quad.count == 4 {
            transform.quad = horizontal ? [quad[1], quad[0], quad[3], quad[2]] : [quad[3], quad[2], quad[1], quad[0]]
        } else if horizontal {
            transform.isFlippedHorizontally.toggle()
        } else {
            transform.isFlippedVertically.toggle()
        }
        applyLayerEdit(.transform(transform), to: id, label: Self.transformLabel)
        refreshTransformOverlay()
    }
}

extension LayerAccessibility {
    /// The centroid of a quad (pinch and twist turn and scale about it).
    static func centroidOf(_ points: [PSPoint]) -> PSPoint {
        guard !points.isEmpty else { return PSPoint(x: 0.5, y: 0.5) }
        var x = 0.0, y = 0.0
        for point in points {
            x += point.x
            y += point.y
        }
        return PSPoint(x: x / Double(points.count), y: y / Double(points.count))
    }
}
#endif
