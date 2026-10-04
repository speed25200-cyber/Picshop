import Foundation

// W2 masks (D1, D4): what a local adjustment's or a selection's mask is made of.
// A mask is an ordered stack of components (AI rasters, brush, gradients, colour,
// luminance and depth ranges) combined with add, subtract and intersect, then
// expanded, feathered, inverted and scaled by density. Values are 0…1; every
// coordinate is normalised, top-left origin, in the layer's output space (D3).
//
// The JSON layouts here were frozen by the W2 seam: lanes add fields with
// defaults, never rename a key. Every decoder is lenient (decodeIfPresent with
// defaults), and a component a newer build wrote decodes as `.unsupported` with
// its JSON kept and written back as read.

/// How a component (or a new selection) combines with what is already there (D1).
public enum CombineMode: String, Codable, Sendable, CaseIterable { case add, subtract, intersect }

/// CIE L*a*b* (D65) of a gamma-encoded sRGB colour: l 0…100, a and b about −128…127.
public struct LabColor: Hashable, Codable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}

/// What a mask or a selection is made from, as the UI and the LLM name it. Catalog enums are generated from allCases.
public enum MaskRegion: String, Codable, Sendable, CaseIterable {
    case subject, background, sky, people, person, object, vegetation, water
    /// People parts: landmark polygons per person (face … teeth); hair and bodySkin from portrait mattes ("should").
    case face, faceSkin, eyes, lips, teeth, hair, bodySkin
    case top, bottom, left, right, center, edges
    case color, shadows, midtones, highlights, skinTones
    case near, far
    case selection

    /// Needs a raster from PhotoAIServices.aiMask (or the selection); the others are parametric.
    public var isAI: Bool {
        switch self {
        case .subject, .background, .sky, .people, .person, .object, .vegetation, .water,
             .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin, .selection:
            return true
        case .top, .bottom, .left, .right, .center, .edges, .color, .shadows, .midtones, .highlights, .skinTones, .near, .far:
            return false
        }
    }
}

// MARK: - Rasters

/// An immutable raster in the project bundle, placed in the layer's current output space by its four corners.
public struct RasterRef: Hashable, Codable, Sendable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case subject, background, people, person, object, sky, vegetation, water, depth, selection, brush, imported
        /// Landmark face parts (label "teeth:2") and portrait semantic mattes (label "hair").
        case facePart, matte
    }

    /// "masks/<uuid>.png" (8-bit gray) or "masks/depth-<16 hex>.png" (16-bit gray); row 0 is the top.
    public var path: String
    public var origin: Origin
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 8 or 16.
    public var bitDepth: Int
    /// Where the raster's top-left, top-right, bottom-right, bottom-left corners land, normalised, top-left origin.
    public var corners: [PSPoint]
    /// Of the pixels above 32/255, normalised in raster space.
    public var boundingBox: PSRect
    /// Canonical English noun for an object ("cup"), "2" for person 2; nil otherwise.
    public var label: String?
    /// PhotoDocument.baseStateKey when made (AI rasters): a different key offers « Mettre à jour ».
    public var stateKey: String?

    /// (0,0), (1,0), (1,1), (0,1): the raster covers the layer exactly.
    public static let unitCorners: [PSPoint] = [PSPoint(x: 0, y: 0), PSPoint(x: 1, y: 0), PSPoint(x: 1, y: 1), PSPoint(x: 0, y: 1)]

    public init(path: String, origin: Origin, pixelWidth: Int, pixelHeight: Int, bitDepth: Int = 8,
                corners: [PSPoint] = RasterRef.unitCorners, boundingBox: PSRect = .unit, label: String? = nil, stateKey: String? = nil) {
        self.path = path
        self.origin = origin
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitDepth = bitDepth
        self.corners = corners
        self.boundingBox = boundingBox
        self.label = label
        self.stateKey = stateKey
    }

    /// The raster as a legacy mask for the executors that take one (erase, recolor, blur, cutout): same path, no
    /// feather, source from the origin (.subject, .object(label:boundingBox:), .region(rawValue)).
    public var maskReference: MaskReference {
        let source: MaskSource
        switch origin {
        case .subject: source = .subject
        case .object: source = .object(label: label ?? "object", boundingBox: boundingBox)
        default: source = .region(origin.rawValue)
        }
        return MaskReference(id: Self.stableID(for: path), relativePath: path, source: source, boundingBox: boundingBox, feather: 0)
    }

    /// The UUID in "masks/<uuid>.png", else one derived from the path (the same on every call).
    static func stableID(for path: String) -> UUID {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let id = UUID(uuidString: name) { return id }
        let hex = StableHash.hex(path) + StableHash.hex("raster:" + path)
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, bytes.count < 16 {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // Keys path, origin, w, h, bits, corners, box, label, stateKey. Lenient: an unknown origin is .imported,
    // missing corners are the unit square.
    private enum CodingKeys: String, CodingKey { case path, origin, w, h, bits, corners, box, label, stateKey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        origin = (try c.decodeIfPresent(String.self, forKey: .origin)).flatMap(Origin.init(rawValue:)) ?? .imported
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .w) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .h) ?? 0
        bitDepth = try c.decodeIfPresent(Int.self, forKey: .bits) ?? 8
        let decodedCorners = try c.decodeIfPresent([PSPoint].self, forKey: .corners) ?? Self.unitCorners
        corners = decodedCorners.count == 4 ? decodedCorners : Self.unitCorners
        boundingBox = try c.decodeIfPresent(PSRect.self, forKey: .box) ?? .unit
        label = try c.decodeIfPresent(String.self, forKey: .label)
        stateKey = try c.decodeIfPresent(String.self, forKey: .stateKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(origin.rawValue, forKey: .origin)
        try c.encode(pixelWidth, forKey: .w)
        try c.encode(pixelHeight, forKey: .h)
        try c.encode(bitDepth, forKey: .bits)
        try c.encode(corners, forKey: .corners)
        try c.encode(boundingBox, forKey: .box)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(stateKey, forKey: .stateKey)
    }
}

// MARK: - Component specs

/// Painted strokes (BrushStroke: radius = fraction of the longest side, hardness, add/subtract, flow per stroke).
public struct BrushSpec: Hashable, Codable, Sendable {
    public var strokes: [BrushStroke]
    /// Key "autoMask", reserved now. When true the brush component is guided-filtered against the image ("should" in
    /// W2; otherwise the toggle stays hidden).
    public var autoMask: Bool

    public init(strokes: [BrushStroke] = [], autoMask: Bool = false) {
        self.strokes = strokes
        self.autoMask = autoMask
    }

    /// Counts gestures (one coalesced polyline per gesture, §7.4). Beyond, the session flattens the brush into a
    /// raster (origin .brush) at endInteraction, never during a drag.
    public static let maxStrokes = 400
    /// Points across every gesture: a full redraw of the brush (a size its stroke cache never drew, after a purge)
    /// costs per segment, so it is bounded by points as well as by gestures.
    public static let maxPoints = 4_000

    public var needsFlatten: Bool {
        strokes.count > Self.maxStrokes || strokes.reduce(0) { $0 + $1.points.count } > Self.maxPoints
    }

    private enum CodingKeys: String, CodingKey { case strokes, autoMask }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        autoMask = try c.decodeIfPresent(Bool.self, forKey: .autoMask) ?? false
    }
}

/// A graduated filter: full effect at and beyond `start`, none at and beyond `end`, smoothstep between (pixel space).
public struct LinearGradientSpec: Hashable, Codable, Sendable {
    public var start: PSPoint
    public var end: PSPoint

    public init(start: PSPoint, end: PSPoint) {
        self.start = start
        self.end = end
    }
}

/// A radial filter: full inside (1 − feather) of the ellipse, smoothstep to its edge.
public struct RadialGradientSpec: Hashable, Codable, Sendable {
    public var center: PSPoint
    /// Fraction of the longest side.
    public var radiusX: Double
    public var radiusY: Double
    /// Degrees, clockwise.
    public var rotation: Double
    /// 0…1.
    public var feather: Double

    public init(center: PSPoint, radiusX: Double, radiusY: Double, rotation: Double = 0, feather: Double = 0.5) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.rotation = rotation
        self.feather = feather
    }

    private enum CodingKeys: String, CodingKey { case center, radiusX, radiusY, rotation, feather }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        center = try c.decode(PSPoint.self, forKey: .center)
        radiusX = try c.decode(Double.self, forKey: .radiusX)
        radiusY = try c.decode(Double.self, forKey: .radiusY)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.5
    }
}

/// Colours near the samples (ΔE76) or in a preset's hue sector.
public struct ColorRangeSpec: Hashable, Codable, Sendable {
    public enum Preset: String, Codable, Sendable, CaseIterable { case reds, oranges, yellows, greens, cyans, blues, magentas, skinTones }

    /// At most 8.
    public var samples: [LabColor]
    /// 0…1.
    public var fuzziness: Double
    public var preset: Preset?

    public init(samples: [LabColor] = [], fuzziness: Double = 0.4, preset: Preset? = nil) {
        self.samples = samples
        self.fuzziness = fuzziness
        self.preset = preset
    }

    private enum CodingKeys: String, CodingKey { case samples, fuzziness, preset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([LabColor].self, forKey: .samples) ?? []
        fuzziness = try c.decodeIfPresent(Double.self, forKey: .fuzziness) ?? 0.4
        // A preset a newer build added is left out rather than failing the component.
        preset = (try c.decodeIfPresent(String.self, forKey: .preset)).flatMap(Preset.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(samples, forKey: .samples)
        try c.encode(fuzziness, forKey: .fuzziness)
        try c.encodeIfPresent(preset, forKey: .preset)
    }
}

/// Rec.709 luma of gamma values, 0…1: a trapezoid from low to high, softened by feather.
public struct LuminanceRangeSpec: Hashable, Codable, Sendable {
    public var low: Double
    public var high: Double
    public var feather: Double

    public init(low: Double, high: Double, feather: Double = 0.15) {
        self.low = low
        self.high = high
        self.feather = feather
    }

    private enum CodingKeys: String, CodingKey { case low, high, feather }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        low = try c.decode(Double.self, forKey: .low)
        high = try c.decode(Double.self, forKey: .high)
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.15
    }
}

/// A depth raster (origin .depth, 16-bit, 0 far … 1 near) through a trapezoid.
public struct DepthRangeSpec: Hashable, Codable, Sendable {
    public var depth: RasterRef
    public var low: Double
    public var high: Double
    public var feather: Double

    public init(depth: RasterRef, low: Double, high: Double, feather: Double = 0.15) {
        self.depth = depth
        self.low = low
        self.high = high
        self.feather = feather
    }

    private enum CodingKeys: String, CodingKey { case depth, low, high, feather }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depth = try c.decode(RasterRef.self, forKey: .depth)
        low = try c.decode(Double.self, forKey: .low)
        high = try c.decode(Double.self, forKey: .high)
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.15
    }
}

// MARK: - Component

/// One layer of a mask stack: a kind, how it combines, whether it is inverted, and its opacity (D1).
public struct MaskComponent: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case raster(RasterRef)
        case brush(BrushSpec)
        case linear(LinearGradientSpec)
        case radial(RadialGradientSpec)
        case colorRange(ColorRangeSpec)
        case luminanceRange(LuminanceRangeSpec)
        case depthRange(DepthRangeSpec)
        /// A kind written by a newer build: the component's whole JSON (sorted keys), written back as read; skipped when rendering.
        case unsupported(String)
    }

    public var id: UUID
    public var kind: Kind
    public var mode: CombineMode
    public var isInverted: Bool
    public var opacity: Double

    public init(id: UUID = UUID(), _ kind: Kind, mode: CombineMode = .add, isInverted: Bool = false, opacity: Double = 1) {
        self.id = id
        self.kind = kind
        self.mode = mode
        self.isInverted = isInverted
        self.opacity = opacity
    }

    /// colorRange, luminanceRange: they read the image's pixels.
    public var isPixelDependent: Bool {
        switch kind {
        case .colorRange, .luminanceRange: return true
        case .raster, .brush, .linear, .radial, .depthRange, .unsupported: return false
        }
    }

    // JSON: {"id","type":"raster|brush|linear|radial|colorRange|luminanceRange|depthRange","mode","inverted","opacity","spec":{…}}.
    // An unknown "type" or "mode", or a spec this build cannot read → .unsupported(the object's JSON).
    private enum CodingKeys: String, CodingKey { case id, type, mode, inverted, opacity, spec }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isInverted = (try? c.decodeIfPresent(Bool.self, forKey: .inverted)) ?? false
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1
        // A missing mode is add; a mode this build does not know makes the component unsupported.
        let knownMode: CombineMode?
        if let modeName = try? c.decodeIfPresent(String.self, forKey: .mode) {
            knownMode = CombineMode(rawValue: modeName)
        } else {
            knownMode = .add
        }
        let type = try? c.decodeIfPresent(String.self, forKey: .type)
        var decoded: Kind?
        if knownMode != nil, let type {
            switch type {
            case "raster": decoded = (try? c.decode(RasterRef.self, forKey: .spec)).map(Kind.raster)
            case "brush": decoded = (try? c.decode(BrushSpec.self, forKey: .spec)).map(Kind.brush)
            case "linear": decoded = (try? c.decode(LinearGradientSpec.self, forKey: .spec)).map(Kind.linear)
            case "radial": decoded = (try? c.decode(RadialGradientSpec.self, forKey: .spec)).map(Kind.radial)
            case "colorRange": decoded = (try? c.decode(ColorRangeSpec.self, forKey: .spec)).map(Kind.colorRange)
            case "luminanceRange": decoded = (try? c.decode(LuminanceRangeSpec.self, forKey: .spec)).map(Kind.luminanceRange)
            case "depthRange": decoded = (try? c.decode(DepthRangeSpec.self, forKey: .spec)).map(Kind.depthRange)
            default: decoded = nil
            }
        }
        mode = knownMode ?? .add
        if let decoded {
            kind = decoded
        } else {
            guard let raw = try? OpaqueJSON(from: decoder), case .object = raw, let text = raw.text else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A mask component is not an object"))
            }
            kind = .unsupported(text)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unsupported(let text) = kind, let raw = OpaqueJSON(text: text) {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(mode, forKey: .mode)
        try c.encode(isInverted, forKey: .inverted)
        try c.encode(opacity, forKey: .opacity)
        switch kind {
        case .raster(let spec):
            try c.encode("raster", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .brush(let spec):
            try c.encode("brush", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .linear(let spec):
            try c.encode("linear", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .radial(let spec):
            try c.encode("radial", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .colorRange(let spec):
            try c.encode("colorRange", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .luminanceRange(let spec):
            try c.encode("luminanceRange", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .depthRange(let spec):
            try c.encode("depthRange", forKey: .type)
            try c.encode(spec, forKey: .spec)
        case .unsupported:
            // Not valid JSON any more: written as an empty component of an unknown type, skipped by every build.
            try c.encode("unsupported", forKey: .type)
        }
    }
}

// MARK: - Stack

/// The mask of a local adjustment: components combined in order (D1), then expand/contract, feather, invert, density.
public struct MaskStack: Hashable, Codable, Sendable {
    public var components: [MaskComponent]
    public var isInverted: Bool
    /// 0…1 → σ = feather × featherSigmaFraction × longest side.
    public var feather: Double
    /// −1…1 → disk radius = |expand| × expandRadiusFraction × longest side (negative contracts).
    public var expand: Double
    /// 0…1.
    public var density: Double

    public init(components: [MaskComponent] = [], isInverted: Bool = false, feather: Double = 0, expand: Double = 0, density: Double = 1) {
        self.components = components
        self.isInverted = isInverted
        self.feather = feather
        self.expand = expand
        self.density = density
    }

    public static let maxComponents = 12
    public static let featherSigmaFraction = 0.03
    public static let expandRadiusFraction = 0.02

    public var isEmpty: Bool { components.isEmpty }

    /// StableHash.hex of the sorted-keys JSON: the rasterizer's cache key (process-local, never persisted).
    public var contentKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? String(describing: self)
        return StableHash.hex(json)
    }

    public var hasPixelDependentComponents: Bool { components.contains { $0.isPixelDependent } }

    /// Every raster the stack reads (raster components and depth ranges' depth maps), in order.
    public var rasterRefs: [RasterRef] {
        components.compactMap { component in
            switch component.kind {
            case .raster(let raster): return raster
            case .depthRange(let spec): return spec.depth
            case .brush, .linear, .radial, .colorRange, .luminanceRange, .unsupported: return nil
            }
        }
    }

    /// One component made from a region (parametric regions use MaskStack.defaultComponent).
    public static func single(_ component: MaskComponent) -> MaskStack {
        MaskStack(components: [component])
    }

    /// The parametric component for top/bottom/left/right/center/edges/shadows/midtones/highlights/skinTones/color
    /// (color uses `color`), for a layer of aspect w/h; nil for AI regions, near/far (need a depth raster) and selection.
    public static func defaultComponent(for region: MaskRegion, aspect: Double, color: LabColor? = nil) -> MaskComponent? {
        let ratio = aspect > 0 && aspect.isFinite ? aspect : 1
        // Fractions of the longest side: W/L and H/L.
        let widthShare = ratio >= 1 ? 1 : ratio, heightShare = ratio >= 1 ? 1 / ratio : 1
        func linear(_ start: PSPoint, _ end: PSPoint) -> MaskComponent { MaskComponent(.linear(LinearGradientSpec(start: start, end: end))) }
        func centre(inverted: Bool) -> MaskComponent {
            MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 0.4 * widthShare, radiusY: 0.4 * heightShare, feather: 0.5)),
                          isInverted: inverted)
        }
        func luminance(_ low: Double, _ high: Double) -> MaskComponent { MaskComponent(.luminanceRange(LuminanceRangeSpec(low: low, high: high, feather: 0.15))) }
        switch region {
        case .top: return linear(PSPoint(x: 0.5, y: 0), PSPoint(x: 0.5, y: 0.5))
        case .bottom: return linear(PSPoint(x: 0.5, y: 1), PSPoint(x: 0.5, y: 0.5))
        case .left: return linear(PSPoint(x: 0, y: 0.5), PSPoint(x: 0.5, y: 0.5))
        case .right: return linear(PSPoint(x: 1, y: 0.5), PSPoint(x: 0.5, y: 0.5))
        case .center: return centre(inverted: false)
        case .edges: return centre(inverted: true)
        case .shadows: return luminance(0, 0.25)
        case .midtones: return luminance(0.33, 0.66)
        case .highlights: return luminance(0.75, 1)
        case .skinTones: return MaskComponent(.colorRange(ColorRangeSpec(preset: .skinTones)))
        case .color:
            guard let color else { return nil }
            return MaskComponent(.colorRange(ColorRangeSpec(samples: [color], fuzziness: 0.4)))
        case .subject, .background, .sky, .people, .person, .object, .vegetation, .water,
             .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin, .near, .far, .selection:
            return nil
        }
    }

    // Keys components, inverted, feather, expand, density; decodeIfPresent with defaults.
    private enum CodingKeys: String, CodingKey { case components, inverted, feather, expand, density }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        isInverted = try c.decodeIfPresent(Bool.self, forKey: .inverted) ?? false
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        expand = try c.decodeIfPresent(Double.self, forKey: .expand) ?? 0
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(components, forKey: .components)
        try c.encode(isInverted, forKey: .inverted)
        try c.encode(feather, forKey: .feather)
        try c.encode(expand, forKey: .expand)
        try c.encode(density, forKey: .density)
    }
}
