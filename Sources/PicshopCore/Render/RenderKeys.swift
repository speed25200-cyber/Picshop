import Foundation

// D12 content-hash cache keys: stable across launches (StableHash), so toggling, reordering or deleting an earlier
// step changes every later key and a dial drag changes none. L2 replaces every `operation.id@WxH` with them. They
// encode JSON, so the renderer memoises `operationKeys` on the operations that move pixels and never calls
// `layerContentKey` on the frame path (its content cache hashes the layer in process, `PhotoRenderer.contentKey`).

public enum RenderKeys {
    /// StableHash.hex of the kind's sorted-keys JSON (id, label and date are the operation's, not the kind's).
    public static func kindKey(_ kind: EditOperation.Kind) -> String {
        StableHash.hex(bytes: sortedJSON(kind))
    }

    /// D12: the chained key after each operation the operation loop transforms, by operation id:
    /// k₀ = hex("<asset path>|<pixel size>"), kᵢ₊₁ = hex(kᵢ + "|" + kindKey(opᵢ)). Tonal kinds, local adjustments and
    /// newer kinds (which the loop returns unchanged) get no key and change none, so a dial drag keeps every key; an
    /// expensive result is cached under "<key>@<W>x<H>".
    public static func operationKeys(source: MediaAsset, edits: EditStack) -> [UUID: String] {
        var keys: [UUID: String] = [:]
        var key = sourceKey(source)
        for operation in edits.operations where transformsPixels(operation.kind) {
            key = StableHash.hex(key + "|" + kindKey(operation.kind))
            keys[operation.id] = key
        }
        return keys
    }

    /// What the layer's pixels depend on before placement: the operation chain, the develop recipe, the local
    /// adjustments, the content (a text element without its centre and rotation, a shape, a fill, a gradient, a
    /// folder), the masks (legacy, the stack's `contentKey`, enabled, linked). Placement, opacity, fill, blend, clip,
    /// visibility, the name, the ref number and the baked mask are left out.
    public static func layerContentKey(_ layer: Layer) -> String {
        var parts: [String] = []
        let edits = layer.edits
        switch layer.content {
        case .image(let asset):
            let chain = operationKeys(source: asset, edits: edits)
            let last = edits.operations.last { chain[$0.id] != nil }.flatMap { chain[$0.id] }
            parts.append("image:" + (last ?? sourceKey(asset)))
        case .text(var element):
            element.center = PSPoint(x: 0.5, y: 0.5)
            element.rotation = 0
            parts.append("text:" + sortedText(element))
        case .shape(let shape):
            parts.append("shape:" + sortedText(shape))
        case .adjustment(let adjustments):
            parts.append("adjustment:" + sortedText(adjustments))
        case .fill(let color):
            parts.append("fill:" + sortedText(color))
        case .gradientFill(let gradient):
            parts.append("gradient:" + sortedText(gradient))
        case .group(let folder):
            parts.append("group:" + sortedText(folder))
        case .unsupported(let json):
            parts.append("unsupported:" + json)
        }
        parts.append("develop:" + developKey(edits))
        parts.append("local:" + sortedText(edits.resolvedLocalAdjustments))
        parts.append("mask:" + (layer.mask.map(sortedText) ?? "-"))
        parts.append("stack:" + (layer.maskStack?.contentKey ?? "-") + "|\(layer.isMaskEnabled)|\(layer.isMaskLinked)")
        return StableHash.hex(parts.joined(separator: "||"))
    }

    /// Content key + transform (a text layer's centre and rotation included) + opacity + fill + blend + clip +
    /// visibility + parent.
    public static func layerCompositeKey(_ layer: Layer) -> String {
        let placement = LayerPlacement.textPlacement(of: layer)
        let parts = [layerContentKey(layer), sortedText(layer.transform), StableHash.token(placement.center.x, decimals: 9),
                     StableHash.token(placement.center.y, decimals: 9), StableHash.token(placement.rotation, decimals: 9),
                     StableHash.token(layer.opacity, decimals: 9), StableHash.token(layer.fillOpacity, decimals: 9),
                     layer.blendMode.rawValue, "\(layer.isClipped)", "\(layer.isVisible)", layer.parentID?.uuidString ?? "-"]
        return StableHash.hex(parts.joined(separator: "|"))
    }

    /// The plan's tree with each layer's composite key, + canvas + background.
    public static func documentKey(_ document: PhotoDocument) -> String {
        let plan = CompositePlan.make(document)
        return key(of: plan, in: document)
    }

    /// The same over the top-level nodes strictly below that layer's top-level node (all of them when the layer is not
    /// drawn).
    public static func belowKey(_ document: PhotoDocument, layerID: UUID) -> String {
        let plan = CompositePlan.make(document)
        let below = plan.prefix { !$0.layerIDs.contains(layerID) }
        return key(of: Array(below), in: document)
    }

    // MARK: Helpers

    /// The kinds the operation loop transforms (PhotoRenderer.apply returns its input for the others).
    static func transformsPixels(_ kind: EditOperation.Kind) -> Bool {
        switch kind {
        case .adjust, .adjustments, .toneCurve, .levels, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut, .localAdjust, .unsupported:
            return false
        default:
            return true
        }
    }

    static func sourceKey(_ asset: MediaAsset) -> String {
        StableHash.hex("\(asset.relativePath)|\(asset.pixelSize)")
    }

    /// The develop recipe's inputs (D9): resolved adjustments, look, tone table inputs, match, mixer, grade, LUT.
    static func developKey(_ edits: EditStack) -> String {
        var parts = [sortedText(edits.resolvedAdjustments)]
        if let look = edits.resolvedLook { parts.append("look:\(look.preset.rawValue):" + StableHash.token(look.intensity, decimals: 9)) }
        parts.append("levels:" + sortedText(edits.resolvedLevels))
        parts.append("curve:" + (edits.resolvedUserToneCurve.map(sortedText) ?? "-"))
        parts.append("match:" + (edits.resolvedColorMatch.map(sortedText) ?? "-"))
        parts.append("mixer:" + (edits.resolvedColorMixer.map(sortedText) ?? "-"))
        parts.append("grade:" + (edits.resolvedColorGrade.map(sortedText) ?? "-"))
        parts.append("lut:" + (edits.resolvedLUT.map(sortedText) ?? "-"))
        return StableHash.hex(parts.joined(separator: "|"))
    }

    /// A plan's structure and keys: L layer, A adjustment, C[base; clipped], G[group; pass-through; children].
    static func key(of nodes: [CompositeNode], in document: PhotoDocument) -> String {
        func describe(_ node: CompositeNode) -> String {
            func layerKey(_ draw: LayerDraw) -> String { document.layer(id: draw.layerID).map(layerCompositeKey) ?? "?" }
            switch node {
            case .layer(let draw): return "L" + layerKey(draw)
            case .adjustment(let draw): return "A" + layerKey(draw)
            case .clippingGroup(let base, let clipped):
                return "C[" + base.groupChildren.map(describe).joined(separator: ",") + ";" + layerKey(base) + ";"
                    + clipped.map(describe).joined(separator: ",") + "]"
            case .group(let draw, let passThrough, let children):
                return "G[" + layerKey(draw) + ";\(passThrough);" + children.map(describe).joined(separator: ",") + "]"
            }
        }
        let parts = nodes.map(describe) + [sortedText(document.canvasSize), sortedText(document.backgroundColor)]
        return StableHash.hex(parts.joined(separator: "|"))
    }

    static func sortedJSON<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data(String(describing: value).utf8)
    }

    static func sortedText<T: Encodable>(_ value: T) -> String {
        String(decoding: sortedJSON(value), as: UTF8.self)
    }
}
