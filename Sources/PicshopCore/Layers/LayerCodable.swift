import Foundation

// D2 forward compatibility for layers: the W2 (synthesized) layout byte for byte under sorted keys, the W3 keys only
// when not default, unknown keys and unknown content kinds kept and written back as read.

/// A coding key made from any string: unknown keys (retainedFields) and the synthesized enum layout ("image", "_0").
struct DynamicCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Unknown keys as sorted-keys JSON text (D2), shared by Layer and PhotoDocument.
enum RetainedFields {
    /// Every key of `container` not in `known`, as compact sorted-keys JSON text. A value that cannot be read as JSON
    /// is skipped (it cannot be written back faithfully).
    static func read(from container: KeyedDecodingContainer<DynamicCodingKey>, known: Set<String>) -> [String: String] {
        var fields: [String: String] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            if let raw = try? container.decode(OpaqueJSON.self, forKey: key), let text = raw.text {
                fields[key.stringValue] = text
            }
        }
        return fields
    }

    /// Writes the retained keys back, never over a key this build owns.
    static func write(_ fields: [String: String], to container: inout KeyedEncodingContainer<DynamicCodingKey>, known: Set<String>) throws {
        for (key, text) in fields where !known.contains(key) {
            guard let raw = OpaqueJSON(text: text) else { continue }
            try container.encode(raw, forKey: DynamicCodingKey(key))
        }
    }
}

// MARK: - Layer

extension Layer {
    /// The W1/W2 keys, exactly as the synthesized Codable named them.
    static let v1Keys: [String] = ["id", "name", "content", "transform", "opacity", "blendMode", "isVisible", "isLocked", "mask", "edits", "group"]
    /// The W3 keys (D2), each written only when it differs from its default.
    static let v2Keys: [String] = ["fill", "maskStack", "maskEnabled", "maskLinked", "clipped", "lock", "parent", "recipeKind", "bakedMask", "ref"]
    static let knownKeys = Set(v1Keys + v2Keys)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ name: String) -> DynamicCodingKey { DynamicCodingKey(name) }
        // v1: as synthesized (optionals through decodeIfPresent, the rest required).
        id = try c.decode(UUID.self, forKey: key("id"))
        name = try c.decode(String.self, forKey: key("name"))
        content = try c.decode(Content.self, forKey: key("content"))
        transform = try c.decode(LayerTransform.self, forKey: key("transform"))
        opacity = try c.decode(Double.self, forKey: key("opacity"))
        blendMode = try c.decode(BlendMode.self, forKey: key("blendMode"))
        isVisible = try c.decode(Bool.self, forKey: key("isVisible"))
        isLocked = try c.decode(Bool.self, forKey: key("isLocked"))
        mask = try c.decodeIfPresent(MaskReference.self, forKey: key("mask"))
        edits = try c.decode(EditStack.self, forKey: key("edits"))
        group = try c.decodeIfPresent(LayerGroup.self, forKey: key("group"))
        // v2: every key optional, with its default; a malformed value takes the default too and never fails the layer
        // ("fill": "x" → 1).
        func lenient<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            (try? c.decodeIfPresent(type, forKey: key(name))) ?? nil
        }
        let fill = lenient(Double.self, "fill") ?? 1
        fillOpacity = fill.isFinite ? fill.clamped(to: 0...1) : 1
        maskStack = lenient(MaskStack.self, "maskStack")
        isMaskEnabled = lenient(Bool.self, "maskEnabled") ?? true
        isMaskLinked = lenient(Bool.self, "maskLinked") ?? true
        isClipped = lenient(Bool.self, "clipped") ?? false
        lockOptions = lenient(LayerLockOptions.self, "lock") ?? []
        parentID = lenient(UUID.self, "parent")
        recipeKind = lenient(String.self, "recipeKind").flatMap(AdjustmentLayerKind.init(rawValue:))
        bakedMask = lenient(MaskReference.self, "bakedMask")
        refNumber = lenient(Int.self, "ref")
        retainedFields = RetainedFields.read(from: c, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ name: String) -> DynamicCodingKey { DynamicCodingKey(name) }
        try c.encode(id, forKey: key("id"))
        try c.encode(name, forKey: key("name"))
        try c.encode(content, forKey: key("content"))
        try c.encode(transform, forKey: key("transform"))
        try c.encode(opacity, forKey: key("opacity"))
        try c.encode(blendMode, forKey: key("blendMode"))
        try c.encode(isVisible, forKey: key("isVisible"))
        try c.encode(isLocked, forKey: key("isLocked"))
        try c.encodeIfPresent(mask, forKey: key("mask"))
        try c.encode(edits, forKey: key("edits"))
        try c.encodeIfPresent(group, forKey: key("group"))
        if fillOpacity != 1 { try c.encode(fillOpacity, forKey: key("fill")) }
        try c.encodeIfPresent(maskStack, forKey: key("maskStack"))
        if !isMaskEnabled { try c.encode(isMaskEnabled, forKey: key("maskEnabled")) }
        if !isMaskLinked { try c.encode(isMaskLinked, forKey: key("maskLinked")) }
        if isClipped { try c.encode(isClipped, forKey: key("clipped")) }
        if !lockOptions.isEmpty { try c.encode(lockOptions, forKey: key("lock")) }
        try c.encodeIfPresent(parentID, forKey: key("parent"))
        try c.encodeIfPresent(recipeKind, forKey: key("recipeKind"))
        try c.encodeIfPresent(bakedMask, forKey: key("bakedMask"))
        try c.encodeIfPresent(refNumber, forKey: key("ref"))
        try RetainedFields.write(retainedFields, to: &c, known: Self.knownKeys)
    }
}

// MARK: - Layer.Content

extension Layer.Content {
    /// The synthesized layout: `{"<case>":{"_0":<payload>}}`. An object whose single key is not a case this build
    /// knows (or with several keys) decodes as `.unsupported(json)` and is written back as read (D2).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let keys = c.allKeys
        let payload = DynamicCodingKey("_0")
        if keys.count == 1, let key = keys.first {
            switch key.stringValue {
            case "image":
                self = .image(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(MediaAsset.self, forKey: payload))
                return
            case "text":
                self = .text(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(TextElement.self, forKey: payload))
                return
            case "shape":
                self = .shape(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(ShapeElement.self, forKey: payload))
                return
            case "adjustment":
                self = .adjustment(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(Adjustments.self, forKey: payload))
                return
            case "fill":
                self = .fill(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(PSColor.self, forKey: payload))
                return
            case "group":
                self = .group(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(LayerFolder.self, forKey: payload))
                return
            case "gradientFill":
                self = .gradientFill(try c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: key).decode(GradientFill.self, forKey: payload))
                return
            default:
                break
            }
        }
        guard let raw = try? OpaqueJSON(from: decoder), case .object = raw, let text = raw.text else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A layer content is not an object"))
        }
        self = .unsupported(text)
    }

    public func encode(to encoder: Encoder) throws {
        if case .unsupported(let text) = self, let raw = OpaqueJSON(text: text) {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        let payload = DynamicCodingKey("_0")
        func nested(_ name: String) -> KeyedEncodingContainer<DynamicCodingKey> {
            c.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: DynamicCodingKey(name))
        }
        switch self {
        case .image(let asset):
            var n = nested("image")
            try n.encode(asset, forKey: payload)
        case .text(let element):
            var n = nested("text")
            try n.encode(element, forKey: payload)
        case .shape(let shape):
            var n = nested("shape")
            try n.encode(shape, forKey: payload)
        case .adjustment(let adjustments):
            var n = nested("adjustment")
            try n.encode(adjustments, forKey: payload)
        case .fill(let color):
            var n = nested("fill")
            try n.encode(color, forKey: payload)
        case .group(let folder):
            var n = nested("group")
            try n.encode(folder, forKey: payload)
        case .gradientFill(let gradient):
            var n = nested("gradientFill")
            try n.encode(gradient, forKey: payload)
        case .unsupported(let text):
            // Text that is not JSON (never produced by the decoder): kept as a string so nothing is lost.
            var n = nested("unsupported")
            try n.encode(text, forKey: payload)
        }
    }
}

// MARK: - LayerTransform

extension LayerTransform {
    /// The W1 keys and the W3 keys; anything else is kept in `retainedFields`.
    static let knownKeys: Set<String> = ["center", "scale", "rotation", "isFlippedHorizontally", "isFlippedVertically",
                                         "scaleX", "scaleY", "skewX", "skewY", "quad"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ name: String) -> DynamicCodingKey { DynamicCodingKey(name) }
        center = try c.decode(PSPoint.self, forKey: key("center"))
        scale = try c.decode(Double.self, forKey: key("scale"))
        rotation = try c.decode(Double.self, forKey: key("rotation"))
        isFlippedHorizontally = try c.decode(Bool.self, forKey: key("isFlippedHorizontally"))
        isFlippedVertically = try c.decode(Bool.self, forKey: key("isFlippedVertically"))
        // W3: lenient, with their defaults (a malformed value never fails the layer).
        func lenient(_ name: String, _ fallback: Double) -> Double {
            let value = ((try? c.decodeIfPresent(Double.self, forKey: key(name))) ?? nil) ?? fallback
            return value.isFinite ? value : fallback
        }
        scaleX = lenient("scaleX", 1)
        scaleY = lenient("scaleY", 1)
        skewX = lenient("skewX", 0)
        skewY = lenient("skewY", 0)
        let points = (try? c.decodeIfPresent([PSPoint].self, forKey: key("quad"))) ?? nil
        quad = points?.count == 4 && points?.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) == true ? points : nil
        retainedFields = RetainedFields.read(from: c, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        func key(_ name: String) -> DynamicCodingKey { DynamicCodingKey(name) }
        try c.encode(center, forKey: key("center"))
        try c.encode(scale, forKey: key("scale"))
        try c.encode(rotation, forKey: key("rotation"))
        try c.encode(isFlippedHorizontally, forKey: key("isFlippedHorizontally"))
        try c.encode(isFlippedVertically, forKey: key("isFlippedVertically"))
        if scaleX != 1 { try c.encode(scaleX, forKey: key("scaleX")) }
        if scaleY != 1 { try c.encode(scaleY, forKey: key("scaleY")) }
        if skewX != 0 { try c.encode(skewX, forKey: key("skewX")) }
        if skewY != 0 { try c.encode(skewY, forKey: key("skewY")) }
        if let quad, quad.count == 4 { try c.encode(quad, forKey: key("quad")) }
        try RetainedFields.write(retainedFields, to: &c, known: Self.knownKeys)
    }
}
