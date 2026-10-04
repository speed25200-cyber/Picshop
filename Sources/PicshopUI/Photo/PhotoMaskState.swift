#if canImport(SwiftUI) && canImport(UIKit) && canImport(CoreImage)
import Foundation
import CoreImage
import CoreGraphics
import Observation
import PicshopCore
import PicshopIntent
import PicshopImaging

/// What the Masques panel and the canvas's mask layer read (W2): the selected mask, the overlay, the handle or brush
/// in use, the thumbnails, the AI mask being computed. Leaf state, like PhotoToneState: views read it, never the
/// history, so a brush stroke or a handle drag re-evaluates the overlay alone.
@MainActor
@Observable
final class PhotoMaskState {
    /// What the canvas edits for the selected mask.
    enum EditingComponent: Equatable {
        /// A linear or radial component's handles.
        case handles(UUID)
        /// Painting into a brush component; nil until the first stroke makes one.
        case brush(UUID?)
        /// A luminance or depth range in the range editor.
        case range(UUID)
        /// Waiting for a tap or a frame on the canvas (« Objet »): a new mask (nil) or a component in that mode.
        case object(CombineMode?)
    }

    /// The mask brush (§7.4): size as a fraction of the longest side, feather 0 hard … 1 soft, flow per stroke.
    struct BrushSettings: Equatable {
        var size = 0.04
        var feather = 0.5
        var flow = 1.0
        /// « Effacer »: strokes subtract.
        var erase = false
        var hardness: Double { (1 - feather).clamped(to: 0...1) }
    }

    /// The AI mask being computed, for the placeholder row.
    struct Working: Equatable {
        var region: MaskRegion
        var id = UUID()
    }

    var selectedID: UUID?
    /// The overlay's style, colour and opacity (default: a red tint at 50 %).
    var overlay: MaskOverlayStyle = .tint
    var overlayColor = PSColor(red: 1, green: 0.23, blue: 0.19)
    /// A style picked from the overlay menu keeps the overlay on; « Aucune » shows it only while dragging and when a
    /// mask lands.
    var isOverlayPinned = false
    var showsOverlayWhileDragging = true
    /// The settled frame's overlay (D17), passed by the canvas as the representable's `maskOverlay`.
    var overlayImage: CIImage?
    var editing: EditingComponent?
    /// 64-point mask thumbnails by adjustment id, rendered off the main thread once per mask state.
    var thumbnails: [UUID: CGImage] = [:]
    @ObservationIgnored var thumbnailKeys: [UUID: String] = [:]
    var brush = BrushSettings()
    /// The current brush gesture as 2-point segments, one per touch batch (§7.4), so the stroke cache appends.
    @ObservationIgnored var pendingDrag: [BrushStroke] = []
    /// The brush component's strokes when the gesture began.
    @ObservationIgnored var committedStrokes: [BrushStroke] = []
    /// The AI mask being computed (the placeholder row and its ✕).
    var aiWorking: Working?
    @ObservationIgnored var aiTask: Task<Void, Never>?
    /// What « Détectés » offers, for the current base state.
    var suggestions: MaskSuggestions = .none
    @ObservationIgnored var suggestionsKey: String?
    /// Faces left to right, for « Personne… ».
    var personThumbnails: [CGImage] = []
    /// « Personne… »: the people part waiting for a face to be picked (left to right); nil when no picker shows.
    var personPickerRegion: MaskRegion?
    /// The add mode of the part being picked (nil: a new mask).
    @ObservationIgnored var personPickerMode: CombineMode?
    /// Under the list after an AI mask the provider doubted (« Ciel approximatif : affine-le au pinceau »).
    var caption: String?
    /// The mask whose tint fades in, holds a second and fades out after it lands.
    @ObservationIgnored var flashingID: UUID?
    /// 0…1 along the flash.
    @ObservationIgnored var flashLevel: Double = 0
    @ObservationIgnored var flashTask: Task<Void, Never>?
    /// The overlay before the flash or drag level scales it.
    @ObservationIgnored var overlayBase: CIImage?
    /// A finger is on a handle, the brush or a range thumb.
    var isDragging = false
    /// The local adjustment under the finger (a local dial, its handles, its brush): the other masks freeze (D6).
    @ObservationIgnored var interactionTarget: UUID?
    /// The dragged gradient as it is under the finger, for the handles (the document moves once, at the end).
    var liveComponent: (id: UUID, kind: MaskComponent.Kind)?
    /// The handle being dragged and the spec it started from.
    @ObservationIgnored var handleDrag: (handle: MaskHandleGeometry.Handle, adjustmentID: UUID, componentID: UUID, start: MaskComponent.Kind)?
    /// The range editor shows the luminance or depth map itself (blackAndWhite).
    var showsRangeMap = false
    /// The open sections of the adjustment controls.
    var expanded: Set<String> = ["light"]
    /// The model the panel offers to download (a descriptor id).
    var modelOffer: String?
    /// The call that waits for that model: run again once it is installed (one undo step), then forgotten.
    @ObservationIgnored var pendingModel: (id: String, intent: EditIntent)?
    @ObservationIgnored var installWatch: Task<Void, Never>?
    /// The range editor's eyedropper is armed: the next canvas tap sets the range around the tapped value.
    var rangeEyedropper = false
    /// The range editor's 64-bin histogram (heights 0…1) of luminance or depth, and what it was counted for.
    var rangeHistogram: [Double] = []
    @ObservationIgnored var rangeHistogramKey: String?
    /// Where the next brush stroke paints: a new mask, or a new component of the selected one in that mode.
    @ObservationIgnored var brushTarget: BrushTarget = .newMask
    @ObservationIgnored var preloadTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored var suggestionsTask: Task<Void, Never>?
    @ObservationIgnored var flattenTask: Task<Void, Never>?
    /// The brush gesture in progress: its mask, its component, the component's mode, and whether the drag makes them.
    @ObservationIgnored var activeBrush: (adjustmentID: UUID, componentID: UUID, mode: CombineMode, creates: Bool)?
    @ObservationIgnored var lastBrushPoint: PSPoint?

    enum BrushTarget: Equatable {
        case newMask
        case component(adjustmentID: UUID, componentID: UUID, mode: CombineMode)
    }

    init() {}

    /// The selected mask in `document`, nil when none (or it went with an undo).
    func selected(in document: PhotoDocument) -> LocalAdjustment? {
        guard let id = selectedID else { return nil }
        return document.localAdjustments.first { $0.id == id }
    }
}
#endif
