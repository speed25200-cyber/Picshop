#if canImport(SwiftUI) && canImport(UIKit) && canImport(CoreImage)
import Foundation
import CoreImage
import Observation
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopImaging

/// What the Sélection panel, its sheets and the marching ants read (W2): the mode, how a new selection combines,
/// the overlay, the outline, and the two sheets' working values. Leaf state: views never read the history.
@MainActor
@Observable
final class PhotoSelectionState {
    enum SelectMode: String, CaseIterable, Identifiable {
        case subject, sky, object, quick, wand, lasso, colorRange
        var id: String { rawValue }

        var title: String {
            switch self {
            case .subject: return L("Subject")
            case .sky: return L("Sky")
            case .object: return L("Object")
            case .quick: return L("Quick selection")
            case .wand: return L("Magic wand")
            case .lasso: return L("Lasso")
            case .colorRange: return L("Colour range")
            }
        }

        var symbol: String {
            switch self {
            case .subject: return "person.crop.circle"
            case .sky: return "cloud.sun"
            case .object: return "cube"
            case .quick: return "paintbrush.pointed"
            case .wand: return "wand.and.rays"
            case .lasso: return "lasso"
            case .colorRange: return "eyedropper.halffull"
            }
        }

        /// MaskPanelInventory's id for the mode's button.
        var controlID: String { "select.mode.\(rawValue)" }
    }

    /// A value asked for before a Modify step (« Étendre… »): pixels at full resolution, or smoothness 0…100.
    struct ModifyRequest: Identifiable, Equatable {
        enum Kind: String { case grow, shrink, feather, smooth }
        var kind: Kind
        var value: Double
        var id: String { kind.rawValue }
    }

    var mode: SelectMode = .subject
    /// nil: a new selection. It becomes `.add` after the first selection of the session unless the person picks.
    var combine: CombineMode?
    @ObservationIgnored var combinePicked = false
    /// The overlay inside Sélection: `.outline` is the ants with a 20 % tint; another style replaces the tint.
    var overlay: MaskOverlayStyle = .outline
    var overlayColor = PSColor(red: 0.36, green: 0.55, blue: 1)
    /// Quick Selection: the SAM point prompts of the strokes so far (shown as dots), the brush and its mode.
    var quickPrompts: [MaskPrompt] = []
    var quickRadius = 0.035
    var quickErase = false
    /// The wand's sample: 1, 3 or 5 pixels.
    var wandSampleSize = 1
    var isWorking = false
    /// The selection step running now (the next one replaces it).
    @ObservationIgnored var task: Task<Void, Never>?
    /// The wand's pixels for one picture state (lookThumbnailKey), read once.
    @ObservationIgnored var wandCache: (key: String, analysis: VisionGrounding.WandAnalysis)?
    /// The selection's outline for the ants, canvas-normalised, closed paths (the raster placed by its corners),
    /// bounded to `contourPointBudget` points.
    var contour: [[PSPoint]] = []
    /// The same outline as a path in unit space (0…1), built once per outline: the ants scale it to the frame.
    var contourPath = Path()
    static let contourPointBudget = 6_000
    @ObservationIgnored var contourKey: String?
    @ObservationIgnored var contourTask: Task<Void, Never>?
    /// Under the panel after an approximate result (« Sélection approximative (modèle non installé) »).
    var caption: String?
    /// The frame being drawn in object mode (normalised), shown dashed.
    var boxDrag: PSRect?
    var modify: ModifyRequest?
    /// ColorRangeSheet, non-nil while it is open.
    var colorRange: ColorRangeEditing?
    /// SelectAndMaskSheet, non-nil while it is open.
    var refine: RefineEditing?
    /// The Generate prompt of « Utiliser la sélection pour → Générer… ».
    var generatePrompt = ""
    var asksGeneratePrompt = false

    init() {}
}

/// ColorRangeSheet's working values: its samples, tolerance, preset and preview, and where the result goes.
struct ColorRangeEditing: Equatable {
    enum Output: String, CaseIterable, Identifiable {
        case selection, mask
        var id: String { rawValue }
        var title: String { self == .selection ? L("Selection") : L("Local mask") }
    }

    enum PreviewMode: String, CaseIterable, Identifiable {
        case none, grayscale, black, white, tint
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return L("No preview")
            case .grayscale: return L("Grayscale")
            case .black: return L("On black")
            case .white: return L("On white")
            case .tint: return L("Overlay view")
            }
        }

        /// The overlay style that draws it; nil for none.
        var style: MaskOverlayStyle? {
            switch self {
            case .none: return nil
            case .grayscale: return .blackAndWhite
            case .black: return .onBlack
            case .white: return .onWhite
            case .tint: return .rubylith
            }
        }

        var controlID: String { "colorRange.preview.\(rawValue)" }
    }

    /// The presets: the eight colour families and skin tones (a colour range), and the three tonal bands (a
    /// luminance range).
    enum Preset: String, CaseIterable, Identifiable {
        case skinTones, reds, oranges, yellows, greens, cyans, blues, magentas, shadows, midtones, highlights
        var id: String { rawValue }

        var title: String {
            switch self {
            case .skinTones: return L("Skin tones")
            case .reds: return L("Reds")
            case .oranges: return L("Oranges")
            case .yellows: return L("Yellows")
            case .greens: return L("Greens")
            case .cyans: return L("Cyans")
            case .blues: return L("Blues")
            case .magentas: return L("Magentas")
            case .shadows: return L("Shadows")
            case .midtones: return L("Midtones")
            case .highlights: return L("Highlights")
            }
        }

        /// The colour range preset, nil for the tonal bands.
        var colorPreset: ColorRangeSpec.Preset? { ColorRangeSpec.Preset(rawValue: rawValue) }

        /// The tonal bands' luminance range (MaskStack.defaultComponent's), nil for colours.
        var luminance: LuminanceRangeSpec? {
            switch self {
            case .shadows: return LuminanceRangeSpec(low: 0, high: 0.25)
            case .midtones: return LuminanceRangeSpec(low: 0.33, high: 0.66)
            case .highlights: return LuminanceRangeSpec(low: 0.75, high: 1)
            default: return nil
            }
        }
    }

    /// Where the sheet was opened from: a selection, a new mask, a new component of a mask (in a mode), or an
    /// existing colour range component.
    enum Target: Equatable {
        case selection
        case newMask
        case addToMask(adjustmentID: UUID, mode: CombineMode)
        case component(adjustmentID: UUID, componentID: UUID)
    }

    var target: Target
    var output: Output
    var samples: [LabColor] = []
    var fuzziness = 0.4
    var preset: Preset?
    var preview: PreviewMode = .tint
    /// The eyedropper adds (true) or removes (false) the colour it taps.
    var addsSamples = true

    static let maxSamples = 8
    /// The UI's lowest tolerance (§12: the cube's trilinear parity near 0).
    static let minimumFuzziness = 0.05

    /// The component the sheet's values make.
    var component: MaskComponent.Kind? {
        if let luminance = preset?.luminance { return .luminanceRange(luminance) }
        guard !samples.isEmpty || preset?.colorPreset != nil else { return nil }
        return .colorRange(ColorRangeSpec(samples: Array(samples.prefix(Self.maxSamples)), fuzziness: fuzziness, preset: preset?.colorPreset))
    }
}

/// SelectAndMaskSheet's working values.
struct RefineEditing: Equatable {
    enum ViewMode: String, CaseIterable, Identifiable {
        case overlay, onBlack, onWhite, blackAndWhite, outline
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overlay: return L("Overlay view")
            case .onBlack: return L("On black")
            case .onWhite: return L("On white")
            case .blackAndWhite: return L("Black & white")
            case .outline: return L("Outline")
            }
        }

        var style: MaskOverlayStyle {
            switch self {
            case .overlay: return .rubylith
            case .onBlack: return .onBlack
            case .onWhite: return .onWhite
            case .blackAndWhite: return .blackAndWhite
            case .outline: return .outline
            }
        }
    }

    enum Output: String, CaseIterable, Identifiable {
        case selection, mask
        var id: String { rawValue }
        var title: String { self == .selection ? L("Selection") : L("Local mask") }
    }

    var refinement: SelectionRefinement
    var view: ViewMode = .overlay
    var output: Output = .selection
}
#endif
