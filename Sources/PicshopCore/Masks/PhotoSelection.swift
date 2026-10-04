import Foundation

// The document's one selection (D7): a raster with the steps that made it, undoable, remapped by geometry
// like the masks. Every selection change is one history step (« Sélection »).

/// Select & Mask v1 settings.
public struct SelectionRefinement: Hashable, Codable, Sendable {
    /// 0…1 → guided-filter radius = radius × 0.02 × longest side (« Rayon »).
    public var radius: Double
    /// 0…1 (« Lisser »).
    public var smooth: Double
    /// 0…1 → σ = feather × 0.01 × longest side (« Contour progressif »).
    public var feather: Double
    /// 0…1 (« Contraste »).
    public var contrast: Double
    /// −1…1 (« Décaler le contour »).
    public var shiftEdge: Double
    /// 0…1, 0 = off (« Décontaminer les couleurs »).
    public var decontaminate: Double

    public init(radius: Double = 0.25, smooth: Double = 0, feather: Double = 0, contrast: Double = 0, shiftEdge: Double = 0, decontaminate: Double = 0) {
        self.radius = radius
        self.smooth = smooth
        self.feather = feather
        self.contrast = contrast
        self.shiftEdge = shiftEdge
        self.decontaminate = decontaminate
    }

    /// What « affine les bords » applies: radius 0.3, smooth 0.15.
    public static let automatic = SelectionRefinement(radius: 0.3, smooth: 0.15)

    private enum CodingKeys: String, CodingKey { case radius, smooth, feather, contrast, shiftEdge, decontaminate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.25
        smooth = try c.decodeIfPresent(Double.self, forKey: .smooth) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        shiftEdge = try c.decodeIfPresent(Double.self, forKey: .shiftEdge) ?? 0
        decontaminate = try c.decodeIfPresent(Double.self, forKey: .decontaminate) ?? 0
    }
}

/// How the selection was built, step by step (labels and Live lines).
public struct SelectionStep: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case subject, background, sky, people, person, facePart, object, quick, wand, lasso, colorRange, luminanceRange, region, all, invert, modify, refine, mask
    }

    public var source: Source
    /// nil: a new selection.
    public var mode: CombineMode?
    /// "cup", "2", a colour name.
    public var label: String?

    public init(_ source: Source, mode: CombineMode? = nil, label: String? = nil) {
        self.source = source
        self.mode = mode
        self.label = label
    }

    // Keys source, mode, label (synthesized layout). An unknown source or mode throws, and
    // PhotoSelection drops that step.
}

/// The document's selection.
public struct PhotoSelection: Hashable, Codable, Sendable {
    /// 8-bit, ≤1536 px, in the space its `corners` place it.
    public var mask: MaskReference
    public var layerID: UUID
    /// The last 12.
    public var steps: [SelectionStep]
    public var refinement: SelectionRefinement?
    /// 0…1 of pixels > 127 (an estimate after a remap).
    public var coverage: Double
    /// The raster's size (≤ workingLongestSide).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Where the raster's corners land in the layer's current output space (decodeIfPresent, default unit).
    public var corners: [PSPoint]

    public init(mask: MaskReference, layerID: UUID, steps: [SelectionStep] = [], refinement: SelectionRefinement? = nil,
                coverage: Double, pixelWidth: Int, pixelHeight: Int, corners: [PSPoint] = RasterRef.unitCorners) {
        self.mask = mask
        self.layerID = layerID
        self.steps = steps
        self.refinement = refinement
        self.coverage = coverage
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.corners = corners
    }

    public static let workingLongestSide = 1536
    /// Steps kept for labels and Live lines.
    public static let maxSteps = 12

    /// corners == unit: legacy consumers may use `mask` as it is; otherwise they bake it first (D7).
    public var isAligned: Bool { corners == RasterRef.unitCorners }

    /// The selection as a mask component's raster (origin .selection, with `corners`): « Utiliser la sélection pour → réglage ».
    public var raster: RasterRef {
        RasterRef(path: mask.relativePath, origin: .selection, pixelWidth: pixelWidth, pixelHeight: pixelHeight, bitDepth: 8,
                  corners: corners, boundingBox: mask.boundingBox)
    }

    // MARK: Codable (lenient, D7)

    // Keys mask, layerID, steps, refinement, coverage, pixelWidth, pixelHeight, corners. A step with an unknown
    // source or mode is dropped; a `mask` that fails to decode throws (the document then opens with no selection).
    private enum CodingKeys: String, CodingKey { case mask, layerID, steps, refinement, coverage, pixelWidth, pixelHeight, corners }

    /// Decodes one step, or nothing when this build cannot read it.
    private struct LenientStep: Decodable {
        let step: SelectionStep?
        init(from decoder: Decoder) throws { step = try? SelectionStep(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mask = try c.decode(MaskReference.self, forKey: .mask)
        layerID = try c.decode(UUID.self, forKey: .layerID)
        steps = (try? c.decodeIfPresent([LenientStep].self, forKey: .steps))?.compactMap(\.step) ?? []
        refinement = try? c.decodeIfPresent(SelectionRefinement.self, forKey: .refinement)
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage) ?? 0
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        let decodedCorners = (try? c.decodeIfPresent([PSPoint].self, forKey: .corners)) ?? RasterRef.unitCorners
        corners = decodedCorners.count == 4 ? decodedCorners : RasterRef.unitCorners
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mask, forKey: .mask)
        try c.encode(layerID, forKey: .layerID)
        try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(refinement, forKey: .refinement)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encode(corners, forKey: .corners)
    }
}
