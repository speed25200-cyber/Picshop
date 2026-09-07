import Foundation

/// One stroke painted by the user on a mask. Points are normalised to the
/// layer's image space so masks survive resolution changes.
public struct BrushStroke: Hashable, Codable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case add
        case subtract
    }

    public var id: UUID
    public var points: [PSPoint]
    /// Radius as a fraction of the image's longest side.
    public var radius: Double
    /// 0 = fully soft edge, 1 = hard edge.
    public var hardness: Double
    public var mode: Mode

    public init(id: UUID = UUID(), points: [PSPoint], radius: Double, hardness: Double = 0.6, mode: Mode = .add) {
        self.id = id
        self.points = points
        self.radius = radius
        self.hardness = hardness
        self.mode = mode
    }
}

/// Describes how a mask was produced. Kept alongside the rasterised mask so the
/// app can re-generate it at a different resolution or explain it in the UI.
public enum MaskSource: Hashable, Codable, Sendable {
    /// Segmented from a natural-language target ("the dog on the left").
    case object(label: String, boundingBox: PSRect)
    /// Salient subject/foreground.
    case subject
    /// Inverse of the subject.
    case background
    /// People (person segmentation).
    case people
    /// Sky region.
    case sky
    /// Hand-painted.
    case brush
    /// Rectangular region in normalised coordinates.
    case rectangle(PSRect)
    /// Tapped point seed in normalised coordinates.
    case point(PSPoint)
}

/// Reference to a rasterised mask stored in the project bundle.
public struct MaskReference: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Path relative to the project bundle, e.g. `masks/<uuid>.png`.
    public var relativePath: String
    public var source: MaskSource
    /// Bounding box of the non-zero region, normalised (0...1). Lets the
    /// renderer restrict expensive work (inpainting) to a crop.
    public var boundingBox: PSRect
    /// Brush strokes that produced or refined the mask, if any.
    public var strokes: [BrushStroke]
    public var feather: Double
    public var isInverted: Bool

    public init(id: UUID = UUID(), relativePath: String? = nil, source: MaskSource, boundingBox: PSRect = .unit,
                strokes: [BrushStroke] = [], feather: Double = 0.02, isInverted: Bool = false) {
        self.id = id
        self.relativePath = relativePath ?? "masks/\(id.uuidString).png"
        self.source = source
        self.boundingBox = boundingBox
        self.strokes = strokes
        self.feather = feather
        self.isInverted = isInverted
    }

    public var displayName: String {
        switch source {
        case .object(let label, _): return label.capitalized
        case .subject: return "Subject"
        case .background: return "Background"
        case .people: return "People"
        case .sky: return "Sky"
        case .brush: return "Brush"
        case .rectangle: return "Rectangle"
        case .point: return "Selection"
        }
    }
}
