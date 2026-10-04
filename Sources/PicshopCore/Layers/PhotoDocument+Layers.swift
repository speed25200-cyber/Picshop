import Foundation

// The layer tree (D1, D4, D5), table bundles, tone targets (D9), stored ref numbers (D19) and the paths the
// document references (D17). The list stays flat and ordered bottom → top; a group is a layer whose content is
// `.group`, and its children are the layers whose `parentID` names it, directly below it. `normalizeLayerTree()`
// restores the invariants after every structure edit and on load.

public extension PhotoDocument {
    /// A group's children, bottom → top ([] when the id is not a group).
    func children(of groupID: UUID) -> [Layer] {
        guard layer(id: groupID)?.isGroup == true else { return [] }
        return layers.filter { $0.parentID == groupID && $0.id != groupID }
    }

    /// The group a layer belongs to; nil at the top level (or when its parent is not a group).
    func parent(of layerID: UUID) -> Layer? {
        guard let parentID = layer(id: layerID)?.parentID, parentID != layerID, let parent = layer(id: parentID), parent.isGroup else { return nil }
        return parent
    }

    /// The layer's own lock ∪ its parent group's (D7).
    func effectiveLock(of layerID: UUID) -> LayerLockOptions {
        guard let layer = layer(id: layerID) else { return [] }
        return layer.ownLock.union(parent(of: layerID)?.ownLock ?? [])
    }

    /// D5: the layer this clipped layer clips onto: the nearest layer below with the same parent that is not itself
    /// clipped. Nil when the layer is not clipped, or the base is invalid (an adjustment layer, a newer build's
    /// content, or none). A group's own clip flag is kept and ignored: a group is never clipped, only a base.
    func clippingBase(of layerID: UUID) -> Layer? {
        guard let index = index(of: layerID), Self.clips(layers[index]) else { return nil }
        return clippingBase(below: index, parentID: layers[index].parentID)
    }

    /// The clipped layers resting on `baseID`, bottom → top; [] when it cannot be a clipping base (D5).
    func clippedLayers(onto baseID: UUID) -> [Layer] {
        guard let index = index(of: baseID) else { return [] }
        let base = layers[index]
        guard !Self.clips(base), Self.canBeClipBase(base) else { return [] }
        var result: [Layer] = []
        // A group's children sit between a lower sibling and the group with another parent: skip them.
        for candidate in layers[(index + 1)...] where candidate.parentID == base.parentID && candidate.id != base.parentID {
            guard Self.clips(candidate) else { break }
            result.append(candidate)
        }
        return result
    }

    /// D1 invariants 1–4 hold (the base first, one level, children directly below their group, groups at fill 1).
    var isNormalizedLayerTree: Bool {
        Self.normalizedLayers(layers) == layers
    }

    /// D1 invariants 1–4, as a stable partition: the base photo goes first (never grouped, never clipped); a parent
    /// that names a missing layer, a non-group or the layer itself is cleared, and so is a group's own parent (one
    /// level: a nested group comes out to the top level with its children); every group's children are taken out,
    /// keeping their relative order, and put back directly below it; a group's fill is 1. Nothing else moves.
    /// Invariant 5 (64 units) is checked by the structure edits, never here. It does not touch `modifiedAt`.
    mutating func normalizeLayerTree() {
        let normalized = Self.normalizedLayers(layers)
        if normalized != layers { layers = normalized }
    }

    /// Image layers in document order, the base first (selection of the Masques target, refs).
    var imageLayers: [Layer] { layers.filter(\.isImage) }

    /// W1 table bundles (D1): layers sharing one LayerGroup.id, in the order their bottom member appears; members
    /// bottom → top. A bundle is one unit everywhere a person or the model sees layers.
    var bundles: [(id: UUID, kind: LayerGroup.Kind, memberIDs: [UUID])] {
        var order: [UUID] = []
        var kinds: [UUID: LayerGroup.Kind] = [:]
        var members: [UUID: [UUID]] = [:]
        for layer in layers {
            guard let group = layer.group else { continue }
            if members[group.id] == nil {
                order.append(group.id)
                kinds[group.id] = group.kind
                members[group.id] = []
            }
            members[group.id]?.append(layer.id)
        }
        return order.map { (id: $0, kind: kinds[$0] ?? .tableCells, memberIDs: members[$0] ?? []) }
    }

    /// The bundle a layer belongs to, nil for a layer on its own.
    func bundle(containing layerID: UUID) -> (id: UUID, kind: LayerGroup.Kind, memberIDs: [UUID])? {
        guard let group = layer(id: layerID)?.group else { return nil }
        return (id: group.id, kind: group.kind, memberIDs: layers.filter { $0.group?.id == group.id }.map(\.id))
    }

    /// Layer units for maxLayers: layers outside bundles plus one per bundle.
    var layerUnitCount: Int {
        var bundleIDs: Set<UUID> = []
        var count = 0
        for layer in layers {
            if let group = layer.group {
                if bundleIDs.insert(group.id).inserted { count += 1 }
            } else {
                count += 1
            }
        }
        return count
    }

    /// D9: where a tone or colour op lands without an explicit layer: the selected adjustment layer when its kind
    /// belongs to the op's family (`toneTargetKinds(for:)`), else the active image layer. The tool rail's panels, the
    /// generated rows and the handlers all use this rule; an explicit `layer` ref wins.
    func toneTarget(for op: OpID) -> UUID? {
        let kinds = Self.toneTargetKinds(for: op)
        if !kinds.isEmpty, let selected = selectedLayer, selected.isAdjustment, kinds.contains(selected.recipeKind ?? .light) {
            return selected.id
        }
        return activeImageLayerID
    }

    /// D9 families: the adjustment-layer kinds a tone or colour op may edit ([] for an op that only edits image layers,
    /// matchColor, or that is not a tone op). An adjustment layer without a kind (a W2 one, its dials in `content`)
    /// counts as « Lumière ».
    static func toneTargetKinds(for op: OpID) -> Set<AdjustmentLayerKind> {
        switch op.raw {
        case "adjust": return [.light]
        case "autoTone": return [.light, .curves, .levels]
        case "curves": return [.curves]
        case "levels": return [.levels]
        case "hsl": return [.hsl]
        case "colorGrade": return [.colorGrade]
        case "lutIntensity", "removeLUT": return [.lut]
        case "applyLook": return [.look]
        default: return []
        }
    }

    /// D19: the next stored ref number for a prefix ("i", "j", "s", "g", "l"): 1 + the highest number of that prefix
    /// (the base photo is i0), so a deleted number is not reused while a higher one exists.
    func nextRefNumber(prefix: Character) -> Int {
        var highest = 0
        for layer in layers where layer.refPrefix == prefix {
            if let number = layer.refNumber { highest = max(highest, number) }
        }
        return highest + 1
    }

    /// D19: gives every layer without a stored ref number the next free number of its prefix, bottom → top (the base
    /// photo i0; a bundle member its bundle's number). Structure edits, `addLayer`, `migrated` and the merge call it;
    /// plain decoding never does. Numbers already stored never change.
    mutating func assignMissingRefNumbers() {
        guard layers.contains(where: { $0.refNumber == nil && $0.refPrefix != nil }) else { return }
        var next: [Character: Int] = [:]
        var bundleNumbers: [UUID: Int] = [:]
        for layer in layers {
            if let group = layer.group, let number = layer.refNumber, bundleNumbers[group.id] == nil { bundleNumbers[group.id] = number }
        }
        let baseID = baseLayerID
        for index in layers.indices where layers[index].refNumber == nil {
            guard let prefix = layers[index].refPrefix else { continue }
            if layers[index].id == baseID {
                layers[index].refNumber = 0
                continue
            }
            if let group = layers[index].group, let number = bundleNumbers[group.id] {
                layers[index].refNumber = number
                continue
            }
            let number = next[prefix] ?? nextRefNumber(prefix: prefix)
            layers[index].refNumber = number
            next[prefix] = number + 1
            if let group = layers[index].group { bundleNumbers[group.id] = number }
        }
    }

    /// D19: the numbers `migrated` gives a document whose layers have none, which is the W2 positional numbering:
    /// per prefix, bottom → top, from 1 (the base photo i0, a bundle by its bottom member).
    var positionalRefNumbers: [UUID: Int] {
        var copy = self
        for index in copy.layers.indices { copy.layers[index].refNumber = nil }
        copy.assignMissingRefNumbers()
        var numbers: [UUID: Int] = [:]
        for layer in copy.layers { if let number = layer.refNumber { numbers[layer.id] = number } }
        return numbers
    }

    /// D17 storage: every string in the document's JSON that starts with "media/" or "masks/": the layer assets,
    /// masks, LUTs, baked masks, retained fields and newer builds' contents alike, without a list to keep up to date.
    var referencedPaths: Set<String> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Set(layers.compactMap { $0.imageAsset?.relativePath })
        }
        var paths: Set<String> = []
        Self.collectPaths(in: object, into: &paths)
        return paths
    }
}

public extension Layer {
    /// D19: the ref letter the `layers:` line prints for this layer: i image, j adjustment and fill, s shape, l text,
    /// g group and table bundle (a bundle member, whatever its content); nil for a newer build's content.
    var refPrefix: Character? {
        if group != nil { return "g" }
        switch content {
        case .image: return "i"
        case .adjustment, .fill, .gradientFill: return "j"
        case .shape: return "s"
        case .text: return "l"
        case .group: return "g"
        case .unsupported: return nil
        }
    }
}

extension Layer.Content {
    /// A content kind a newer build wrote (D2).
    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

extension PhotoDocument {
    /// D5: a clipping base may be an image, text, shape, fill or gradient layer, or a group; never an adjustment layer
    /// or a content this build cannot draw.
    static func canBeClipBase(_ layer: Layer) -> Bool {
        !layer.isAdjustment && !layer.content.isUnsupported
    }

    /// The clipping base for a clipped layer at `index` with `parentID`: the nearest unclipped sibling below.
    func clippingBase(below index: Int, parentID: UUID?) -> Layer? {
        var below = index - 1
        while below >= 0 {
            let candidate = layers[below]
            // Siblings only: a group's children (another parent) and the group itself for its own children are skipped.
            if candidate.parentID == parentID, candidate.id != parentID, !Self.clips(candidate) {
                return Self.canBeClipBase(candidate) ? candidate : nil
            }
            below -= 1
        }
        return nil
    }

    /// Whether a layer's clip flag takes effect: a group's is kept and ignored (a clipping group's clipped members are
    /// layers and adjustment layers, D5), so a group always acts as a possible base.
    static func clips(_ layer: Layer) -> Bool {
        layer.isClipped && !layer.isGroup
    }

    /// The normalised order (see `normalizeLayerTree`).
    static func normalizedLayers(_ input: [Layer]) -> [Layer] {
        guard !input.isEmpty else { return input }
        var list = input
        // 1. The base photo (the first image layer) first.
        if let baseIndex = list.firstIndex(where: \.isImage), baseIndex != 0 {
            let base = list.remove(at: baseIndex)
            list.insert(base, at: 0)
        }
        let baseID = list[0].isImage ? list[0].id : nil
        // 2. Parents: one level, groups only.
        let groupIDs = Set(list.filter(\.isGroup).map(\.id))
        for index in list.indices {
            var layer = list[index]
            if layer.id == baseID {
                layer.parentID = nil
                layer.isClipped = false
            }
            if layer.isGroup {
                layer.parentID = nil
                layer.fillOpacity = 1
            }
            if let parentID = layer.parentID, parentID == layer.id || !groupIDs.contains(parentID) {
                layer.parentID = nil
            }
            if layer != list[index] { list[index] = layer }
        }
        // 3. Every group's children directly below it, in their relative order; top-level layers keep their order.
        guard !groupIDs.isEmpty else { return list }
        var children: [UUID: [Layer]] = [:]
        for layer in list { if let parentID = layer.parentID { children[parentID, default: []].append(layer) } }
        var ordered: [Layer] = []
        ordered.reserveCapacity(list.count)
        for layer in list where layer.parentID == nil {
            if layer.isGroup { ordered.append(contentsOf: children[layer.id] ?? []) }
            ordered.append(layer)
        }
        return ordered
    }

    static func collectPaths(in object: Any, into paths: inout Set<String>) {
        switch object {
        case let string as String:
            if string.hasPrefix("\(Project.mediaDirectory)/") || string.hasPrefix("\(Project.masksDirectory)/") { paths.insert(string) }
        case let array as [Any]:
            for element in array { collectPaths(in: element, into: &paths) }
        case let dictionary as [String: Any]:
            for value in dictionary.values { collectPaths(in: value, into: &paths) }
        default:
            break
        }
    }
}
