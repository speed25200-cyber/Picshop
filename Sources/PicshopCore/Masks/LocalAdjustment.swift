import Foundation

/// A Lightroom-style local adjustment (D2): dials, an optional curve, HSL subset and local colour, applied
/// through a mask after the layer's develop recipe. Stored as one `EditOperation.Kind.localAdjust` per id.
public struct LocalAdjustment: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// The person's own name; nil → display name from region/label.
    public var name: String?
    /// What it was made from (find-or-create identity, state lines).
    public var region: MaskRegion?
    /// Object noun (English) or person index.
    public var label: String?
    public var stack: MaskStack
    /// The existing dials; vignette is never set or shown locally.
    public var adjustments: Adjustments
    /// All four channels, rendered through ToneLUT.
    public var curve: ToneCurve?
    /// The HSL subset (8 bands).
    public var mixer: ColorMixer?
    /// Local colour (« Couleur »): one wheel, written to all three ColorGrade wheels.
    public var grade: ColorGrade?
    /// 0…1, default 1.
    public var amount: Double
    public var isVisible: Bool

    public init(id: UUID = UUID(), name: String? = nil, region: MaskRegion? = nil, label: String? = nil, stack: MaskStack,
                adjustments: Adjustments = .neutral, curve: ToneCurve? = nil, mixer: ColorMixer? = nil, grade: ColorGrade? = nil,
                amount: Double = 1, isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.region = region
        self.label = label
        self.stack = stack
        self.adjustments = adjustments
        self.curve = curve
        self.mixer = mixer
        self.grade = grade
        self.amount = amount
        self.isVisible = isVisible
    }

    public static let maxPerLayer = 16

    /// Nothing to draw: neutral dials (vignette never renders locally), no curve, neutral mixer and colour, or
    /// amount 0.
    public var isNeutral: Bool {
        if !(amount > 0) { return true }
        let dialsNeutral = adjustments.activeParameters.allSatisfy { $0 == .vignette }
        return dialsNeutral && (curve?.isIdentity ?? true) && (mixer?.isNeutral ?? true) && (grade?.isNeutral ?? true)
    }

    /// Find-or-create identity: a one-component stack made from this region (and label, for object and person).
    public func matches(region: MaskRegion, label: String?) -> Bool {
        guard self.region == region, stack.components.count == 1 else { return false }
        switch region {
        case .object, .person: return self.label == label
        default: return label == nil || self.label == label
        }
    }

    // MARK: Codable (keys frozen by the W2 seam)

    // `id` and `stack` are required, so a malformed payload (such as W1's test fixture
    // {"localAdjust":{"_0":{"invert":true}}}) still fails and EditOperation keeps it as `.unsupported`.
    // Every other field is decodeIfPresent with its default; an unknown `region` decodes as nil.
    private enum CodingKeys: String, CodingKey { case id, name, region, label, stack, adjustments, curve, mixer, grade, amount, visible }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        stack = try c.decode(MaskStack.self, forKey: .stack)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        region = (try c.decodeIfPresent(String.self, forKey: .region)).flatMap(MaskRegion.init(rawValue:))
        label = try c.decodeIfPresent(String.self, forKey: .label)
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? .neutral
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve)
        mixer = try c.decodeIfPresent(ColorMixer.self, forKey: .mixer)
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: .grade)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(region, forKey: .region)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(stack, forKey: .stack)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encodeIfPresent(curve, forKey: .curve)
        try c.encodeIfPresent(mixer, forKey: .mixer)
        try c.encodeIfPresent(grade, forKey: .grade)
        try c.encode(amount, forKey: .amount)
        try c.encode(isVisible, forKey: .visible)
    }
}

// MARK: - The edit stack's local adjustments

public extension EditStack {
    /// One per id (the last op of an id wins if a legacy file has two), in operation order.
    var resolvedLocalAdjustments: [LocalAdjustment] {
        var seen: Set<UUID> = []
        var result: [LocalAdjustment] = []
        for operation in operations.reversed() {
            guard case .localAdjust(let adjustment) = operation.kind, seen.insert(adjustment.id).inserted else { continue }
            result.append(adjustment)
        }
        return result.reversed()
    }

    func localAdjustment(id: UUID) -> LocalAdjustment? {
        for operation in operations.reversed() {
            if case .localAdjust(let adjustment) = operation.kind, adjustment.id == id { return adjustment }
        }
        return nil
    }

    /// In place when an op with this id exists (same EditOperation id and position: a drag is one undo step), else appended.
    mutating func setLocalAdjustment(_ adjustment: LocalAdjustment, label: String? = nil) {
        let index = operations.lastIndex { operation in
            if case .localAdjust(let existing) = operation.kind { return existing.id == adjustment.id }
            return false
        }
        if let index {
            let old = operations[index]
            operations[index] = EditOperation(id: old.id, kind: .localAdjust(adjustment), createdAt: old.createdAt, label: label ?? old.label)
        } else {
            append(.localAdjust(adjustment), label: label)
        }
    }

    /// Removes every op of that id; false when there was none.
    @discardableResult
    mutating func removeLocalAdjustment(id: UUID) -> Bool {
        let before = operations.count
        operations.removeAll { operation in
            if case .localAdjust(let existing) = operation.kind { return existing.id == id }
            return false
        }
        return operations.count != before
    }

    /// The layer's aspect (w/h) after its geometric operations, from its source's aspect.
    func outputAspect(sourceAspect: Double) -> Double {
        geometryChain(sourceAspect: sourceAspect).aspect
    }

    /// Every geometric op composed in order (identity when none), and the output aspect.
    /// Each op's map is taken at the aspect the layer has just before it, as the renderer applies them.
    func geometryChain(sourceAspect: Double) -> (map: PSHomography, aspect: Double) {
        var map = PSHomography.identity
        var aspect = PSHomography.saneAspect(sourceAspect)
        for operation in operations where operation.kind.isGeometric {
            if let step = operation.kind.geometryMap(aspectBefore: aspect) {
                map = map.then(step)
            }
            aspect = operation.kind.aspect(after: aspect)
        }
        return (map, aspect)
    }
}

// MARK: - The document's local adjustments (W2: the base layer's)

public extension PhotoDocument {
    /// W2: the base layer (D2). Local adjustments on other image layers come in W3.
    var localAdjustmentsLayerID: UUID? { baseLayerID }

    /// The local adjustments of `localAdjustmentsLayerID`, in operation order ("a1" is the first).
    var localAdjustments: [LocalAdjustment] {
        guard let id = localAdjustmentsLayerID, let layer = layer(id: id) else { return [] }
        return layer.edits.resolvedLocalAdjustments
    }

    /// The local adjustment with that id, nil when there is none.
    func localAdjustment(id: UUID) -> LocalAdjustment? {
        guard let layerID = localAdjustmentsLayerID else { return nil }
        return layer(id: layerID)?.edits.localAdjustment(id: id)
    }

    /// Room for one more local adjustment (fewer than `LocalAdjustment.maxPerLayer`).
    var canAddLocalAdjustment: Bool { localAdjustments.count < LocalAdjustment.maxPerLayer }

    /// The aspect (w/h) of the space mask coordinates live in: the local-adjustment layer's output after its
    /// geometric operations, from its asset's pixel size (D3: never from `canvasSize`, which `apply` does not
    /// update for straighten or perspective). Parametric masks (`MaskStack.defaultComponent`) take it.
    var localAdjustmentsAspect: Double {
        guard let id = localAdjustmentsLayerID, let layer = layer(id: id) else { return PSHomography.saneAspect(canvasSize.aspectRatio) }
        return layer.edits.outputAspect(sourceAspect: sourceAspect(of: layer))
    }

    /// In place when it exists (one op per id), else appended; touches the document. A new one past
    /// `LocalAdjustment.maxPerLayer` is refused (nothing changes): callers check `canAddLocalAdjustment` first.
    mutating func setLocalAdjustment(_ adjustment: LocalAdjustment, label: String? = nil) {
        guard let id = localAdjustmentsLayerID, let layer = layer(id: id) else { return }
        guard layer.edits.localAdjustment(id: adjustment.id) != nil || layer.edits.resolvedLocalAdjustments.count < LocalAdjustment.maxPerLayer else { return }
        update(layerID: id) { $0.edits.setLocalAdjustment(adjustment, label: label) }
    }

    @discardableResult
    mutating func removeLocalAdjustment(id: UUID) -> Bool {
        guard let layerID = localAdjustmentsLayerID, layer(id: layerID)?.edits.localAdjustment(id: id) != nil else { return false }
        var removed = false
        update(layerID: layerID) { removed = $0.edits.removeLocalAdjustment(id: id) }
        return removed
    }
}

extension PhotoDocument {
    /// A layer's source aspect (w/h): its asset's pixel size, else the canvas, else square.
    func sourceAspect(of layer: Layer) -> Double {
        if let size = layer.imageAsset?.pixelSize, !size.isEmpty { return size.aspectRatio }
        return PSHomography.saneAspect(canvasSize.aspectRatio)
    }
}
