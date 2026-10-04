#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import Observation
import PicshopCore

/// What a canvas gesture does in the photo editor's layer tools (W3, §7).
public enum LayerToolMode: String, Sendable, CaseIterable { case select, transform, maskPaint }

/// What the Layers column, the Layers inspector and the transform overlay read (W3): leaf state, like
/// PhotoMaskState. Views read it, never the history, so a transform drag re-evaluates the overlay and the HUD alone.
///
/// Per-frame values (`liveQuad`, `guides`) are read only by LayerTransformOverlay and SmartGuidesOverlay; the column
/// and the inspector read `rows`, which changes only when a step lands (§7.2).
@MainActor
@Observable
final class PhotoLayerState {
    var mode: LayerToolMode = .select
    var transformMode: TransformMode = .free
    /// The smart guides engaged this frame (D10).
    var guides: [SnapGuide] = []
    var showsColumn = true
    /// The layer whose mask the brush paints (D8); nil paints nothing.
    var editingMaskOf: UUID?
    /// Multi-selection (UI leaf state, never stored in the document).
    var multiSelection: Set<UUID> = []
    var isSelecting = false
    /// Coarse mirror for the column and the inspector (§7.2): updated only when structure, names, visibility, lock,
    /// clip, mask presence or a thumbnail key change, never per drag frame.
    var rows: [LayerRowState] = []
    let transform: TransformReadout
    /// The layer transform mode edits; nil outside transform mode.
    var transformTarget: UUID?
    /// The transformed layer's corners (TL, TR, BR, BL, canvas-normalised) as drawn now: written each drag frame,
    /// read by LayerTransformOverlay only.
    var liveQuad: [PSPoint] = []
    /// The column cell lifted by a long press and the row slot it hovers; nil at rest.
    var columnDrag: LayerColumnDrag?
    /// Bumped when a column drop is refused: that cell shakes back.
    var columnShake: [UUID: Int] = [:]
    /// A finger is on the picture with a brush, a crop handle or a transform handle: the column steps aside.
    var isCanvasGestureActive = false
    /// Smart guides and snapping (« Repères », view only).
    var guidesEnabled = true
    /// The transparency checkerboard under the canvas (« Transparence » in the zoom menu, view only).
    var showsTransparency = true
    /// A long press on the canvas: the layers under the finger, for the pick menu (top first).
    var pickChoices: [UUID] = []
    /// The question the layer tools ask before a destructive step.
    var confirmation: LayerConfirmation?
    /// Photo… in the ＋ menu, or the `pickImageLayer` effect: the photo picker is up.
    var showsImagePicker = false
    /// A raster step in flight (merge, stamp, flatten, apply mask): its working row in the inspector.
    var workingTitle: String?
    /// The mask controls are open for this layer (a tap on a row's mask thumbnail).
    var maskControlsOf: UUID?
    /// A height the inspector should take (a double tap on a column cell, a scenario); the inspector applies it to the
    /// studio's detent and clears it.
    var inspectorDetentRequest: InspectorDetent?
    /// The layer thumbnails and mask thumbnails, by row (cells and rows read them).
    let thumbnails: LayerThumbnailStore
    /// The transform drag in progress (handles, a pick-drag, a pinch or twist): its start, read at each frame; never drawn.
    @ObservationIgnored var drag: LayerTransformDrag?
    /// The snap lines of the transform session, computed once when it begins (D10).
    @ObservationIgnored var snapTargets = SnapTargets()
    /// The undo depth when transform mode began: « Annuler » undoes the drags made since.
    @ObservationIgnored var transformUndoDepth = 0
    /// The last snap haptic and readout update (system uptime): throttled to 16 ms and 15 Hz.
    @ObservationIgnored var lastSnapHaptic: TimeInterval = 0
    @ObservationIgnored var lastReadout: TimeInterval = 0
    /// The layer-mask brush hides (« Effacer ») rather than reveals (« Peindre »); X swaps them (D8).
    var maskPaintHides = false
    /// The layer-mask brush gesture in progress; never drawn.
    @ObservationIgnored var maskStroke: LayerMaskStroke?
    /// A layer-mask brush being flattened into a raster past `BrushSpec.maxStrokes`.
    @ObservationIgnored var maskFlattenTask: Task<Void, Never>?

    init() {
        transform = TransformReadout()
        thumbnails = LayerThumbnailStore()
    }
}

/// One transform drag: what it started from, so each frame is computed from the start (never accumulated).
struct LayerTransformDrag {
    var layerID: UUID
    var kind: TransformHandleKind
    /// The layer's effective transform at the start (a text layer's centre and rotation from its element).
    var start: LayerTransform
    /// The placed corners at the start, canvas-normalised (TL, TR, BR, BL).
    var startQuad: [PSPoint]
    var contentSize: PSSize
    var canvasSize: PSSize
    /// One screen point in canvas-normalised units, per axis (the 6 pt snap threshold, the nudges).
    var pointSize: PSSize
    /// The rotation and the scale were snapped on the last frame (one haptic per engagement).
    var rotationSnapped = false
    var scaleSnapped = false
}

/// One layer-mask brush gesture (D8): the stack it started from with the brush components it paints into, the
/// strokes those had, and how canvas points reach the mask's space. Each frame is rebuilt from the start.
struct LayerMaskStroke {
    var layerID: UUID
    var start: MaskStack
    /// The add-mode brush that reveals, and the subtract-mode brush (last in the stack) that hides; either may be
    /// absent when the other alone does both (a « Tout afficher » or « Tout masquer » mask).
    var revealIndex: Int?
    var hideIndex: Int?
    var revealStrokes: [BrushStroke]
    var hideStrokes: [BrushStroke]
    /// This gesture hides (after the stack's inversion is taken into account).
    var hides: Bool
    /// Canvas → the layer's content space when the mask is linked to an image, text or shape layer; nil on the canvas.
    var toMask: PSHomography?
    var canvasAspect: Double
    var maskAspect: Double
    /// The gesture's 2-point segments in the mask's space (mode `.add`; each component takes its own sign).
    var segments: [BrushStroke] = []
    /// The last canvas point.
    var last: PSPoint
}

/// A column cell under a long-press drag: the dragged row and the slot it would land in (`LayerReorder.drop`).
struct LayerColumnDrag: Equatable {
    var id: UUID
    var slot: Int
    /// The finger's vertical offset from where the cell was lifted (points), so the cell follows it.
    var offset: Double
}

/// A question asked before a destructive layer step (« Supprimer le groupe et son contenu ? »).
enum LayerConfirmation: Equatable, Identifiable {
    /// Deleting a group deletes its children.
    case deleteGroup(UUID)
    /// Flatten discards the hidden layers.
    case flatten
    /// Delete several layers from the multi-selection, groups among them.
    case deleteSelection(Set<UUID>)

    var id: String {
        switch self {
        case .deleteGroup(let id): return "group-\(id.uuidString)"
        case .flatten: return "flatten"
        case .deleteSelection: return "selection"
        }
    }
}

/// One row as the column and the inspector draw it (Equatable, so unchanged rows do not re-render).
struct LayerRowState: Hashable, Identifiable {
    var model: LayerRowModel
    var name: String
    var blendLabel: String
    var opacityPercent: Int
    var isVisible: Bool
    var lock: LayerLockOptions
    var hasMask: Bool
    var isSelected: Bool
    var thumbnailKey: String
    var id: UUID { model.id }
    /// The kind's SF Symbol (an adjustment layer's kind glyph, a group's folder, a table's grid).
    var symbol: String = "photo"
    /// What the thumbnail shows: the rendered layer, a colour swatch (solid fill), or the kind glyph (adjustment).
    var look: LayerRowLook = .rendered
    /// The base photo: never grouped, clipped, moved or deleted.
    var isBase: Bool = false
    /// The layer mask is on (the row dims a disabled mask's thumbnail).
    var isMaskEnabled: Bool = true
    /// Clipped onto nothing valid: the ↳ notch is drawn dimmed (D5).
    var isClipIgnored: Bool = false
    /// The group's chevron: collapsed (D4).
    var isCollapsed: Bool = false
    /// The fill opacity (inspector rows show it when not 100 %).
    var fillPercent: Int = 100
    /// The stored ref (« i2 », « j1 »), when the layer has one.
    var ref: String?
    /// VoiceOver: « Tasse, calque d'image, 80 %, produit, écrêté, masque, verrouillé, sélectionné ».
    var accessibilityLabel: String = ""
    /// The mask thumbnail's key (empty without a mask).
    var maskThumbnailKey: String = ""
}

/// How a row draws its 40 or 44 pt thumbnail.
enum LayerRowLook: Hashable {
    /// The layer rendered alone (renderer.layerThumbnail).
    case rendered
    /// A solid fill's colour.
    case swatch(PSColor)
    /// An adjustment layer: its kind's glyph (over its mask when it has one).
    case glyph
}

/// The thumbnails the rows draw, keyed by layer and checked against the row's key: rendered off the main actor after
/// an interaction settles, never during one.
@MainActor
@Observable
final class LayerThumbnailStore {
    /// Layer thumbnails (88 px), by layer id.
    var images: [UUID: UIImage] = [:]
    /// Mask thumbnails (56 px), by layer id.
    var masks: [UUID: UIImage] = [:]
    /// The key each image was rendered for.
    @ObservationIgnored var imageKeys: [UUID: String] = [:]
    @ObservationIgnored var maskKeys: [UUID: String] = [:]
    @ObservationIgnored var task: Task<Void, Never>?

    func trim() {
        task?.cancel()
        images = [:]
        masks = [:]
        imageKeys = [:]
        maskKeys = [:]
    }
}

/// The transform HUD and the transform rows' values, updated at ≤ 15 Hz during a drag and exactly at its end.
@MainActor
@Observable
final class TransformReadout {
    var widthPercent = 100.0
    var heightPercent = 100.0
    var rotation = 0.0
    var x = 0.0
    var y = 0.0
    var snapDistance: Double?
    /// Skews (shown in the HUD in skew mode).
    var skewX = 0.0
    var skewY = 0.0
    /// The HUD shows while a transform or pick drag runs.
    var isVisible = false
    /// Position (« X 412 · Y 96 px ») rather than size (« L 120 % · H 80 % · 15° »): a move shows where it goes.
    var showsPosition = false

    /// Assigns each figure only when it changed, so the HUD redraws only what moved.
    func update(_ figures: LayerTransformFigures, snap: Double? = nil) {
        if widthPercent != figures.widthPercent { widthPercent = figures.widthPercent }
        if heightPercent != figures.heightPercent { heightPercent = figures.heightPercent }
        if rotation != figures.rotation { rotation = figures.rotation }
        if x != figures.x { x = figures.x }
        if y != figures.y { y = figures.y }
        if skewX != figures.skewX { skewX = figures.skewX }
        if skewY != figures.skewY { skewY = figures.skewY }
        if snapDistance != snap { snapDistance = snap }
    }

    var figures: LayerTransformFigures {
        LayerTransformFigures(widthPercent: widthPercent, heightPercent: heightPercent, rotation: rotation, skewX: skewX, skewY: skewY, x: x, y: y)
    }
}
#endif
