import Foundation

// The single path for layer property, transform, mask and content edits (`applyLayerEdit`) and for structure edits
// (`applyStructureEdit`): UI rows, drags, handlers and the session all call these (D7, D8, D17), so locks, groups,
// clipping, bundles, ref numbers and the tree invariants hold whoever edits.

/// One edit of a layer's properties, placement, mask or content. The comment names the lock mutation it needs (D7).
public enum LayerEdit: Hashable, Sendable {
    /// 0…1, .properties.
    case opacity(Double)
    /// 0…1, .properties; refused (.notApplicable) on groups.
    case fillOpacity(Double)
    /// .properties.
    case blendMode(BlendMode)
    /// Never refused.
    case visible(Bool)
    /// Replaces lockOptions; never refused.
    case lock(LayerLockOptions)
    /// isLocked; never refused.
    case lockAll(Bool)
    /// .properties; refused on the base (.baseLayer); allowed inside groups and on groups.
    case clipped(Bool)
    /// Never refused; trimmed, ≤ 60 characters.
    case rename(String)
    /// .placement; refused on the base.
    case transform(LayerTransform)
    /// .mask; nil deletes; converts a legacy mask first (D8).
    case maskStack(MaskStack?)
    /// .mask; the W2 stack edits (addComponent … setStack); dial/curve/mixer cases → .notApplicable.
    case maskEdit(LocalAdjustmentEdit)
    /// .mask.
    case maskEnabled(Bool)
    /// .mask; re-expresses the stack in the other space (D8) so nothing moves.
    case maskLinked(Bool)
    /// .content; fill layers.
    case solidFill(PSColor)
    /// .content; gradient fill layers (also turns a solid fill into a gradient).
    case gradient(GradientFill)
    /// .content; adjustment layers' own dials.
    case adjustments(Adjustments)
    /// .properties; groups.
    case folder(LayerFolder)
    /// Never refused.
    case recipeKind(AdjustmentLayerKind?)
}

/// Where a structure edit puts a layer.
public enum LayerPlacementSpec: Hashable, Sendable {
    case top, aboveSelected, above(UUID), below(UUID), index(Int), into(groupID: UUID)
}

/// How an imported image layer is sized (D17): 80 % of the canvas's shorter side, covering the canvas, or one source
/// pixel per canvas pixel.
public enum ImageLayerFit: String, Hashable, Sendable, CaseIterable { case fit, fill, original }

/// Layer creation, removal, order, grouping, via copy/cut and merges (D17). Rasters come from
/// `PhotoAIServices.rasterizeLayers` (L2); Core only places them.
public enum LayerStructureEdit: Hashable, Sendable {
    case add(Layer, placement: LayerPlacementSpec)
    case remove(UUID)
    case duplicate(UUID)
    case move(UUID, to: LayerPlacementSpec)
    case group([UUID], name: String?)
    case ungroup(UUID)
    /// `region` in the SOURCE's content space (callers map, D8).
    case viaCopy(source: UUID, region: MaskStack, name: String?)
    case viaCut(source: UUID, region: MaskStack, name: String?)
    /// UUID = the upper layer X (D17).
    case mergeDown(UUID, raster: MediaAsset)
    case mergeVisible(raster: MediaAsset)
    case flatten(raster: MediaAsset)
    case stamp(raster: MediaAsset, name: String)
    case addImage(MediaAsset, name: String, fit: ImageLayerFit, placement: LayerPlacementSpec)
    /// The layer's content becomes the raster, its masks cleared.
    case applyMask(UUID, raster: MediaAsset)
    /// D17 merge selected: one layer at the topmost one's place.
    case mergeLayers([UUID], raster: MediaAsset)
}

public enum LayerEditRefusal: String, Hashable, Sendable, CaseIterable {
    case locked, notFound, baseLayer, nestedGroup, notAGroup, notAnImageLayer, notApplicable, noValidClipBase, tooManyLayers, emptyRegion
}

public enum LayerEditOutcome: Hashable, Sendable { case applied, unchanged, refused(LayerEditRefusal) }


// MARK: - Layer edits

public extension PhotoDocument {
    /// The single path for layer property, transform, mask and content edits (UI rows, drags, handlers). Calls touch().
    /// Locks refuse with `.refused(.locked)` per `LayerLockPolicy.mutation(for:)` (D7). Visibility, opacity and blend
    /// on a table-cell layer act on its whole bundle (D1: one row, one unit).
    @discardableResult
    mutating func applyLayerEdit(_ edit: LayerEdit, to layerID: UUID) -> LayerEditOutcome {
        applyLayerEdit(edit, to: layerID, contentSize: nil)
    }

    /// `applyLayerEdit(_:to:)` with the layer's content size when Core cannot measure it (a text layer's raster:
    /// L2's `contentSize(of:in:)`). Only `.maskLinked` reads it, to re-express the mask in the other space.
    @discardableResult
    mutating func applyLayerEdit(_ edit: LayerEdit, to layerID: UUID, contentSize: PSSize?) -> LayerEditOutcome {
        guard let index = index(of: layerID) else { return .refused(.notFound) }
        switch edit {
        case .visible, .opacity, .blendMode:
            if let bundle = bundle(containing: layerID), bundle.memberIDs.count > 1 { return applyToBundle(edit, members: bundle.memberIDs) }
        default:
            break
        }
        if let mutation = LayerLockPolicy.mutation(for: edit), !LayerLockPolicy.allows(mutation, on: layerID, in: self) { return .refused(.locked) }
        let current = layers[index]
        let isBase = layerID == baseLayerID
        var changed = current
        switch edit {
        case .opacity(let value):
            guard value.isFinite else { return .unchanged }
            changed.opacity = value.clamped(to: 0...1)
        case .fillOpacity(let value):
            guard !current.isGroup else { return .refused(.notApplicable) }
            guard value.isFinite else { return .unchanged }
            changed.fillOpacity = value.clamped(to: 0...1)
        case .blendMode(let mode):
            changed.blendMode = mode
        case .visible(let visible):
            changed.isVisible = visible
        case .lock(let options):
            changed.lockOptions = options
        case .lockAll(let locked):
            changed.isLocked = locked
        case .clipped(let clipped):
            guard !isBase else { return .refused(.baseLayer) }
            if clipped, !current.isClipped, clippingBase(below: index, parentID: current.parentID) == nil { return .refused(.noValidClipBase) }
            changed.isClipped = clipped
        case .rename(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .unchanged }
            changed.name = String(trimmed.prefix(60))
        case .transform(let transform):
            guard !isBase else { return .refused(.baseLayer) }
            switch current.content {
            case .image, .shape: changed.transform = Self.sanitized(transform)
            case .text(var element):
                // The element carries a text layer's centre and rotation (W1); the layer its scale, skew, flips and quad.
                let clean = Self.sanitized(transform)
                element.center = clean.center
                element.rotation = clean.rotation
                changed.content = .text(element)
                var stored = clean
                stored.center = current.transform.center
                stored.rotation = current.transform.rotation
                changed.transform = stored
            case .adjustment, .fill, .gradientFill, .group, .unsupported:
                return .refused(.notApplicable)
            }
        case .maskStack(let stack):
            changed.mask = nil
            changed.maskStack = stack
        case .maskEdit(let maskEdit):
            var stack = Self.convertingLegacyMask(&changed) ?? MaskStack()
            switch maskEdit {
            case .addComponent, .removeComponent, .setComponentMode, .invertComponent, .setComponentKind, .setStack:
                break
            case .setDial, .setCurve, .setMixer, .setGrade, .setAmount, .setVisible, .rename, .duplicate:
                return .refused(.notApplicable)
            }
            if case .addComponent = maskEdit {} else if changed.maskStack == nil { return .refused(.notFound) }
            guard let edited = LocalAdjustment(id: layerID, stack: stack).applying(maskEdit) else {
                if case .addComponent = maskEdit { return .refused(.notApplicable) }
                return .refused(.notFound)
            }
            stack = edited.stack
            changed.maskStack = stack
        case .maskEnabled(let enabled):
            guard Self.convertingLegacyMask(&changed) != nil else { return .refused(.notFound) }
            changed.isMaskEnabled = enabled
        case .maskLinked(let linked):
            guard current.isMaskLinked != linked else { return .unchanged }
            let stack = Self.convertingLegacyMask(&changed)
            if let stack, !isBase, !Self.contentSpaceIsCanvas(current) {
                guard let size = contentSize ?? LayerPlacement.contentSize(of: current, canvasSize: canvasSize), !size.isEmpty else {
                    return .refused(.notApplicable)
                }
                // Content space ↔ canvas space through the placement map, so the mask stays on the same pixels (D8).
                let toCanvas = LayerPlacement.map(for: current, contentSize: size, canvasSize: canvasSize, isBase: false)
                let contentAspect = size.width / size.height, canvasAspect = PSHomography.saneAspect(canvasSize.aspectRatio)
                if linked {
                    guard let toContent = toCanvas.inverse else { return .refused(.notApplicable) }
                    changed.maskStack = stack.remapped(by: toContent, aspectBefore: canvasAspect, aspectAfter: contentAspect)
                } else {
                    changed.maskStack = stack.remapped(by: toCanvas, aspectBefore: contentAspect, aspectAfter: canvasAspect)
                }
            }
            changed.isMaskLinked = linked
        case .solidFill(let color):
            guard current.isFill else { return .refused(.notApplicable) }
            changed.content = .fill(color)
        case .gradient(let gradient):
            guard current.isFill else { return .refused(.notApplicable) }
            changed.content = .gradientFill(gradient.normalized)
        case .adjustments(let adjustments):
            guard current.isAdjustment else { return .refused(.notApplicable) }
            changed.content = .adjustment(adjustments)
        case .folder(let folder):
            guard current.isGroup else { return .refused(.notAGroup) }
            changed.content = .group(folder)
        case .recipeKind(let kind):
            guard current.isAdjustment else { return .refused(.notApplicable) }
            changed.recipeKind = kind
        }
        guard changed != current else { return .unchanged }
        layers[index] = changed
        touch()
        return .applied
    }

    /// French and English messages for a refusal (handlers and toasts share them).
    static func refusalMessage(_ refusal: LayerEditRefusal, layerName: String?, french: Bool) -> String {
        let name = layerName.map { french ? "« \($0) »" : "“\($0)”" }
        switch refusal {
        case .locked:
            if let name { return french ? "Le calque \(name) est verrouillé : déverrouille-le d'abord." : "The layer \(name) is locked: unlock it first." }
            return french ? "Ce calque est verrouillé : déverrouille-le d'abord." : "This layer is locked: unlock it first."
        case .notFound:
            return french ? "Calque introuvable." : "Layer not found."
        case .baseLayer:
            return french ? "La photo de base ne peut pas faire ça." : "The base photo can't do that."
        case .nestedGroup:
            return french ? "Un groupe ne peut pas contenir un autre groupe." : "A group can't contain another group."
        case .notAGroup:
            return french ? "Ce calque n'est pas un groupe." : "This layer isn't a group."
        case .notAnImageLayer:
            return french ? "Ça marche seulement sur un calque photo." : "That only works on an image layer."
        case .notApplicable:
            return french ? "Ce n'est pas possible sur ce calque." : "That isn't possible on this layer."
        case .noValidClipBase:
            return french ? "Il n'y a pas de calque en dessous sur lequel l'écrêter." : "There's no layer below to clip it to."
        case .tooManyLayers:
            return french ? "Trop de calques : \(PhotoDocument.maxLayers) au maximum." : "Too many layers: \(PhotoDocument.maxLayers) at most."
        case .emptyRegion:
            return french ? "La zone choisie est vide." : "The chosen area is empty."
        }
    }
}

// MARK: - Structure edits

public extension PhotoDocument {
    /// Structure edits (D17); returns the id of the layer created or changed (new layer, group, merged layer; nil for a
    /// removal). Every edit is one history step for the caller, selects its result, assigns the ref numbers of the
    /// layers it creates (D19) and ends with `normalizeLayerTree()`. A refused edit changes nothing.
    ///
    /// A cropped raster (merge down, merge selected, stamp, apply mask) is placed at the centre of the canvas at its
    /// natural size here, which is exact for a canvas-sized raster; pass its `opaqueBounds` to
    /// `applyStructureEdit(_:rasterBounds:)` to place a cropped one.
    @discardableResult
    mutating func applyStructureEdit(_ edit: LayerStructureEdit) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        applyStructureEdit(edit, rasterBounds: nil)
    }

    /// `applyStructureEdit(_:)` with where a cropped raster sits on the canvas (`LayerRasterResult.opaqueBounds`,
    /// canvas-normalised): the result layer is placed exactly there, centre = the bounds' centre, scale 1 (D17). The
    /// base replacements (merge visible, flatten) are canvas-sized and ignore it.
    @discardableResult
    mutating func applyStructureEdit(_ edit: LayerStructureEdit, rasterBounds: PSRect?) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        var working = self
        let result = working.performStructureEdit(edit, rasterBounds: rasterBounds)
        guard case .applied = result.outcome else { return result }
        working.assignMissingRefNumbers()
        working.normalizeLayerTree()
        if let id = result.layerID, working.layer(id: id) != nil {
            working.selectedLayerID = id
        } else if let selected = working.selectedLayerID, working.layer(id: selected) == nil {
            working.selectedLayerID = working.baseLayerID ?? working.layers.last?.id
        }
        working.touch()
        self = working
        return result
    }
}

extension PhotoDocument {
    // MARK: Units, blocks and places

    /// What one row stands for: a table bundle's members, else the layer; bottom → top.
    func unitMembers(of id: UUID) -> [UUID] {
        if let bundle = bundle(containing: id) { return bundle.memberIDs }
        return [id]
    }

    /// A unit with a group's children: the layers that move, duplicate or delete together; bottom → top.
    func block(of id: UUID) -> [UUID] {
        let members = Set(unitMembers(of: id))
        let groups = Set(layers.filter { members.contains($0.id) && $0.isGroup }.map(\.id))
        return layers.filter { members.contains($0.id) || ($0.parentID.map(groups.contains) ?? false) }.map(\.id)
    }

    /// The unit's head: the topmost layer of its block (a group, a bundle's top member, the layer).
    func head(ofBlock ids: [UUID]) -> UUID? {
        let set = Set(ids)
        return layers.last { set.contains($0.id) }?.id
    }

    /// Whether adding `units` would pass the 64-unit cap (D1 invariant 5).
    func exceedsUnits(adding units: Int) -> Bool {
        units > 0 && layerUnitCount + units > Self.maxLayers
    }

    /// Where a placement puts new layers in `list` (the layers without the ones being moved): the insertion index and
    /// the parent they join. Nil when it cannot be resolved (a missing or moving reference, below the base, into a
    /// non-group).
    static func resolve(_ placement: LayerPlacementSpec, in list: [Layer], selectedLayerID: UUID?, baseID: UUID?) -> (index: Int, parentID: UUID?)? {
        let minimum = list.first.map { $0.id == baseID } == true ? 1 : 0
        func index(of id: UUID) -> Int? { list.firstIndex { $0.id == id } }
        func isChild(_ layer: Layer) -> Bool {
            guard let parentID = layer.parentID else { return false }
            return list.contains { $0.id == parentID && $0.isGroup }
        }
        func above(_ id: UUID) -> (index: Int, parentID: UUID?)? {
            guard let found = index(of: id) else { return nil }
            let layer = list[found]
            return (max(minimum, found + 1), isChild(layer) ? layer.parentID : nil)
        }
        switch placement {
        case .top:
            return (list.count, nil)
        case .aboveSelected:
            guard let selected = selectedLayerID, index(of: selected) != nil else { return (list.count, nil) }
            return above(selected)
        case .above(let id):
            return above(id)
        case .below(let id):
            guard let found = index(of: id) else { return nil }
            let layer = list[found]
            if layer.isGroup {
                // Below the whole group: under its bottom child.
                let first = list.firstIndex { $0.parentID == layer.id } ?? found
                return first < minimum ? nil : (first, nil)
            }
            return found < minimum ? nil : (found, isChild(layer) ? layer.parentID : nil)
        case .index(let wanted):
            let slot = min(max(wanted, minimum), list.count)
            let below = slot > 0 ? list[slot - 1] : nil
            let above = slot < list.count ? list[slot] : nil
            if let below, isChild(below) { return (slot, below.parentID) }
            if let above, above.isGroup { return (slot, above.id) }
            return (slot, nil)
        case .into(let groupID):
            guard let found = index(of: groupID), list[found].isGroup else { return nil }
            return (found, groupID)
        }
    }

    /// Inserts `newLayers` (bottom → top) at a placement. Their top-level members join the placement's parent; a
    /// group never goes inside a group. The caller has checked locks and units.
    mutating func insert(_ newLayers: [Layer], at placement: LayerPlacementSpec) -> LayerEditRefusal? {
        let movingIDs = Set(newLayers.map(\.id))
        let list = layers.filter { !movingIDs.contains($0.id) }
        if case .into(let groupID) = placement, list.first(where: { $0.id == groupID })?.isGroup != true {
            return list.contains { $0.id == groupID } ? .notAGroup : .notFound
        }
        guard let place = Self.resolve(placement, in: list, selectedLayerID: selectedLayerID, baseID: baseLayerID) else {
            if case .below(let id) = placement, id == baseLayerID { return .baseLayer }
            return .notFound
        }
        let groupIDs = Set(newLayers.filter(\.isGroup).map(\.id))
        if place.parentID != nil, !groupIDs.isEmpty { return .nestedGroup }
        var placed = newLayers
        for index in placed.indices where !(placed[index].parentID.map(groupIDs.contains) ?? false) {
            placed[index].parentID = place.parentID
        }
        var result = list
        result.insert(contentsOf: placed, at: place.index)
        layers = result
        return nil
    }

    /// Whether every layer in `ids` allows `mutation` (effective locks, D7).
    func allAllow(_ mutation: LayerMutation, _ ids: [UUID]) -> Bool {
        ids.allSatisfy { LayerLockPolicy.allows(mutation, on: $0, in: self) }
    }

    /// Visibility, opacity or blend on every member of a table bundle, one step (D1).
    mutating func applyToBundle(_ edit: LayerEdit, members: [UUID]) -> LayerEditOutcome {
        if let mutation = LayerLockPolicy.mutation(for: edit), !allAllow(mutation, members) { return .refused(.locked) }
        var changedAny = false
        for id in members {
            guard let index = index(of: id) else { continue }
            var layer = layers[index]
            switch edit {
            case .visible(let visible): layer.isVisible = visible
            case .opacity(let value): if value.isFinite { layer.opacity = value.clamped(to: 0...1) }
            case .blendMode(let mode): layer.blendMode = mode
            default: continue
            }
            if layer != layers[index] {
                layers[index] = layer
                changedAny = true
            }
        }
        guard changedAny else { return .unchanged }
        touch()
        return .applied
    }

    // MARK: The edits

    mutating func performStructureEdit(_ edit: LayerStructureEdit, rasterBounds: PSRect?) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        switch edit {
        case .add(let layer, let placement):
            guard self.layer(id: layer.id) == nil else { return (.refused(.notApplicable), nil) }
            guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
            if let refusal = insert([layer], at: placement) { return (.refused(refusal), nil) }
            return (.applied, layer.id)

        case .addImage(let asset, let name, let fit, let placement):
            guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
            var layer = Layer(name: name, content: .image(asset))
            layer.transform = Self.imageTransform(fit: fit, contentSize: asset.pixelSize, canvasSize: canvasSize)
            if let refusal = insert([layer], at: placement) { return (.refused(refusal), nil) }
            return (.applied, layer.id)

        case .remove(let id):
            guard layer(id: id) != nil else { return (.refused(.notFound), nil) }
            guard id != baseLayerID else { return (.refused(.baseLayer), nil) }
            let doomed = block(of: id)
            guard !doomed.contains(where: { $0 == baseLayerID }) else { return (.refused(.baseLayer), nil) }
            guard allAllow(.delete, doomed) else { return (.refused(.locked), nil) }
            let set = Set(doomed)
            layers.removeAll { set.contains($0.id) }
            if let selected = selectedLayerID, set.contains(selected) { selectedLayerID = baseLayerID }
            return (.applied, nil)

        case .duplicate(let id):
            return duplicate(id)

        case .move(let id, let placement):
            return move(id, to: placement)

        case .group(let ids, let name):
            return group(ids, name: name)

        case .ungroup(let id):
            return ungroup(id)

        case .viaCopy(let source, let region, let name):
            return layerVia(source: source, region: region, name: name, cut: false)

        case .viaCut(let source, let region, let name):
            return layerVia(source: source, region: region, name: name, cut: true)

        case .mergeDown(let id, let raster):
            return mergeDown(id, raster: raster, bounds: rasterBounds)

        case .mergeLayers(let ids, let raster):
            return mergeLayers(ids, raster: raster, bounds: rasterBounds)

        case .mergeVisible(let raster):
            return replaceBase(with: raster, discardingHidden: false)

        case .flatten(let raster):
            return replaceBase(with: raster, discardingHidden: true)

        case .stamp(let raster, let name):
            guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
            var layer = Layer(name: name, content: .image(raster))
            layer.transform = Self.rasterTransform(asset: raster, bounds: rasterBounds, canvasSize: canvasSize)
            if let refusal = insert([layer], at: .top) { return (.refused(refusal), nil) }
            return (.applied, layer.id)

        case .applyMask(let id, let raster):
            guard let index = index(of: id) else { return (.refused(.notFound), nil) }
            guard layers[index].isImage else { return (.refused(.notAnImageLayer), nil) }
            guard LayerLockPolicy.allows(.alpha, on: id, in: self) else { return (.refused(.locked), nil) }
            // The raster holds the layer drawn with its masks and fill (as merge down's lower layer); its opacity and
            // blend stay on the layer.
            var layer = layers[index]
            layer.content = .image(raster)
            layer.edits = EditStack()
            layer.mask = nil
            layer.maskStack = nil
            layer.isMaskEnabled = true
            layer.isMaskLinked = true
            layer.fillOpacity = 1
            layer.bakedMask = nil
            layer.transform = id == baseLayerID ? .identity : Self.rasterTransform(asset: raster, bounds: rasterBounds, canvasSize: canvasSize)
            layers[index] = layer
            return (.applied, id)
        }
    }

    // MARK: Duplicate, move, group

    mutating func duplicate(_ id: UUID) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard let original = layer(id: id) else { return (.refused(.notFound), nil) }
        guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
        let source = block(of: id)
        guard !source.isEmpty else { return (.refused(.notFound), nil) }
        // Fresh ids everywhere: layers (a group's children re-parented), a bundle's tag, local adjustments and their
        // components, operations. Rasters are shared (immutable files).
        var ids: [UUID: UUID] = [:]
        for old in source { ids[old] = UUID() }
        let freshBundle = original.group.map { _ in UUID() }
        let headID = head(ofBlock: source)
        var copies: [Layer] = []
        for old in source {
            guard var copy = layer(id: old) else { continue }
            copy.id = ids[old] ?? UUID()
            copy.refNumber = nil
            if let parentID = copy.parentID, let mapped = ids[parentID] { copy.parentID = mapped }
            if let group = copy.group, let fresh = freshBundle { copy.group = LayerGroup(id: fresh, kind: group.kind, row: group.row, column: group.column) }
            copy.edits = Self.freshened(copy.edits)
            if old == headID && original.group == nil { copy.name = Self.copyName(copy.name) }
            copies.append(copy)
        }
        guard let head = headID, let newHead = ids[head] else { return (.refused(.notFound), nil) }
        if let refusal = insert(copies, at: .above(head)) { return (.refused(refusal), nil) }
        return (.applied, newHead)
    }

    mutating func move(_ id: UUID, to placement: LayerPlacementSpec) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard layer(id: id) != nil else { return (.refused(.notFound), nil) }
        guard id != baseLayerID else { return (.refused(.baseLayer), nil) }
        var moving = block(of: id)
        // A clip base moves with its clipped run (D5, D17).
        if let head = head(ofBlock: moving) {
            for clipped in clippedLayers(onto: head) { moving += block(of: clipped.id) }
        }
        let movingSet = Set(moving)
        guard !movingSet.contains(where: { $0 == baseLayerID }) else { return (.refused(.baseLayer), nil) }
        // A reference inside what moves is no place to go.
        switch placement {
        case .above(let reference), .below(let reference), .into(let reference):
            guard !movingSet.contains(reference) else { return (.refused(.notApplicable), nil) }
        case .top, .aboveSelected, .index:
            break
        }
        guard allAllow(.order, moving) else { return (.refused(.locked), nil) }
        let before = layers
        let block = layers.filter { movingSet.contains($0.id) }
        if let refusal = insert(block, at: placement) {
            layers = before
            return (.refused(refusal), nil)
        }
        normalizeLayerTree()
        if layers == before {
            return (.unchanged, id)
        }
        return (.applied, id)
    }

    mutating func group(_ ids: [UUID], name: String?) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard !ids.isEmpty else { return (.refused(.notFound), nil) }
        guard ids.allSatisfy({ layer(id: $0) != nil }) else { return (.refused(.notFound), nil) }
        guard !ids.contains(where: { $0 == baseLayerID }) else { return (.refused(.baseLayer), nil) }
        var members: [UUID] = []
        for id in ids { members += unitMembers(of: id) }
        let memberSet = Set(members)
        let chosen = layers.filter { memberSet.contains($0.id) }
        guard !chosen.contains(where: { $0.isGroup || parent(of: $0.id) != nil }) else { return (.refused(.nestedGroup), nil) }
        guard allAllow(.order, chosen.map(\.id)) else { return (.refused(.locked), nil) }
        guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
        let groupCount = layers.filter(\.isGroup).count
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = trimmed?.isEmpty == false ? String(trimmed!.prefix(60)) : "Groupe \(groupCount + 1)"
        let folder = Layer(name: groupName, content: .group(LayerFolder()))
        // The group goes where the topmost chosen layer was; the members keep their order and sit below it.
        guard let topIndex = layers.lastIndex(where: { memberSet.contains($0.id) }) else { return (.refused(.notFound), nil) }
        var result: [Layer] = []
        for (index, layer) in layers.enumerated() {
            if index == topIndex {
                result += chosen.map { member in
                    var joined = member
                    joined.parentID = folder.id
                    return joined
                }
                result.append(folder)
            } else if !memberSet.contains(layer.id) {
                result.append(layer)
            }
        }
        layers = result
        return (.applied, folder.id)
    }

    mutating func ungroup(_ id: UUID) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard let group = layer(id: id) else { return (.refused(.notFound), nil) }
        guard group.isGroup else { return (.refused(.notAGroup), nil) }
        guard LayerLockPolicy.allows(.order, on: id, in: self) else { return (.refused(.locked), nil) }
        // The children keep their place; the group's opacity is folded into theirs and a hidden group hides them, so
        // the picture does not change for normal children. The group's mask, blend and lock go with it.
        let children = children(of: id).map(\.id)
        for child in children {
            guard let index = index(of: child) else { continue }
            layers[index].parentID = nil
            layers[index].opacity = (layers[index].opacity * group.opacity).clamped(to: 0...1)
            if !group.isVisible { layers[index].isVisible = false }
        }
        layers.removeAll { $0.id == id }
        return (.applied, children.last)
    }

    // MARK: Layer via copy and cut

    mutating func layerVia(source id: UUID, region: MaskStack, name: String?, cut: Bool) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard let index = index(of: id) else { return (.refused(.notFound), nil) }
        let source = layers[index]
        guard source.isImage else { return (.refused(.notAnImageLayer), nil) }
        guard !region.isEmpty else { return (.refused(.emptyRegion), nil) }
        if cut { guard LayerLockPolicy.allows(.mask, on: id, in: self) else { return (.refused(.locked), nil) } }
        guard !exceedsUnits(adding: 1) else { return (.refused(.tooManyLayers), nil) }
        var sourceCopy = source
        let sourceStack = Self.convertingLegacyMask(&sourceCopy)
        var layer = Layer(name: Self.viaName(source: source.name, region: region, name: name), content: source.content,
                          transform: source.transform, edits: Self.freshened(source.edits), isMaskLinked: source.isMaskLinked)
        layer.maskStack = Self.intersecting(sourceStack, with: region)
        layer.parentID = source.parentID
        if cut {
            sourceCopy.maskStack = Self.subtracting(region, from: sourceStack)
            sourceCopy.isMaskEnabled = true
            layers[index] = sourceCopy
        }
        if let refusal = insert([layer], at: .above(id)) { return (.refused(refusal), nil) }
        return (.applied, layer.id)
    }

    // MARK: Merges

    mutating func mergeDown(_ upperID: UUID, raster: MediaAsset, bounds: PSRect?) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard let upperIndex = index(of: upperID) else { return (.refused(.notFound), nil) }
        guard upperID != baseLayerID else { return (.refused(.baseLayer), nil) }
        let upper = layers[upperIndex]
        guard !upper.isGroup, !upper.isAdjustment else { return (.refused(.notApplicable), nil) }
        // Y: the nearest layer below with the same parent.
        guard let lowerIndex = layers[..<upperIndex].lastIndex(where: { $0.parentID == upper.parentID && $0.id != upper.parentID }) else {
            return (.refused(.notApplicable), nil)
        }
        let lower = layers[lowerIndex]
        guard !lower.isGroup, !lower.isAdjustment, !lower.content.isUnsupported else { return (.refused(.notApplicable), nil) }
        guard LayerLockPolicy.allows(.content, on: lower.id, in: self), LayerLockPolicy.allows(.delete, on: upperID, in: self) else {
            return (.refused(.locked), nil)
        }
        var merged = lower
        let wasImage = lower.isImage
        merged.content = .image(raster)
        merged.edits = EditStack()
        merged.mask = nil
        merged.maskStack = nil
        merged.isMaskEnabled = true
        merged.isMaskLinked = true
        merged.bakedMask = nil
        merged.fillOpacity = 1
        merged.isClipped = false
        merged.group = nil
        merged.recipeKind = nil
        // It keeps Y's id, name, blend, opacity, parent and ref number; a non-image Y takes a number of its new kind.
        if !wasImage { merged.refNumber = nil }
        merged.transform = lower.id == baseLayerID ? .identity : Self.rasterTransform(asset: raster, bounds: bounds, canvasSize: canvasSize)
        layers[lowerIndex] = merged
        layers.removeAll { $0.id == upperID }
        return (.applied, lower.id)
    }

    mutating func mergeLayers(_ ids: [UUID], raster: MediaAsset, bounds: PSRect?) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard !ids.isEmpty, ids.allSatisfy({ layer(id: $0) != nil }) else { return (.refused(.notFound), nil) }
        var chosen: [UUID] = []
        for id in ids { chosen += block(of: id) }
        let chosenSet = Set(chosen)
        guard chosenSet.count >= 2 else { return (.refused(.notApplicable), nil) }
        guard let topIndex = layers.lastIndex(where: { chosenSet.contains($0.id) }) else { return (.refused(.notFound), nil) }
        let top = layers[topIndex]
        let others = layers.filter { chosenSet.contains($0.id) && $0.id != top.id }.map(\.id)
        if let baseID = baseLayerID, chosenSet.contains(baseID) {
            // With the base: only when nothing else sits between (use merge visible otherwise); the result replaces it.
            guard layers[0...topIndex].allSatisfy({ chosenSet.contains($0.id) }) else { return (.refused(.baseLayer), nil) }
            guard LayerLockPolicy.allows(.content, on: baseID, in: self), allAllow(.delete, chosen.filter { $0 != baseID }) else {
                return (.refused(.locked), nil)
            }
            var base = layers[0]
            Self.becomeRaster(&base, raster)
            base.name = top.name
            base.transform = .identity
            layers[0] = base
            layers.removeAll { chosenSet.contains($0.id) && $0.id != baseID }
            return (.applied, baseID)
        }
        guard LayerLockPolicy.allows(.content, on: top.id, in: self), allAllow(.delete, others) else { return (.refused(.locked), nil) }
        let parents = Set(layers.filter { chosenSet.contains($0.id) && !($0.parentID.map(chosenSet.contains) ?? false) }.map { $0.parentID?.uuidString ?? "-" })
        var merged = top
        let wasImage = top.isImage
        Self.becomeRaster(&merged, raster)
        merged.blendMode = .normal
        merged.opacity = 1
        merged.isClipped = false
        merged.parentID = parents.count == 1 ? layers.first(where: { chosenSet.contains($0.id) && !($0.parentID.map(chosenSet.contains) ?? false) })?.parentID : nil
        if !wasImage { merged.refNumber = nil }
        merged.transform = Self.rasterTransform(asset: raster, bounds: bounds, canvasSize: canvasSize)
        layers[topIndex] = merged
        layers.removeAll { chosenSet.contains($0.id) && $0.id != top.id }
        return (.applied, top.id)
    }

    /// Merge visible (`discardingHidden` false: hidden layers stay) and flatten (they go): the visible picture
    /// becomes the base, canvas-sized, in place.
    mutating func replaceBase(with raster: MediaAsset, discardingHidden: Bool) -> (outcome: LayerEditOutcome, layerID: UUID?) {
        guard let baseID = baseLayerID, let baseIndex = index(of: baseID) else { return (.refused(.notFound), nil) }
        // What goes: every layer drawn (visible, in a visible group), or every layer when flattening.
        let doomed = layers.filter { layer in
            guard layer.id != baseID else { return false }
            if discardingHidden { return true }
            return layer.isVisible && (parent(of: layer.id)?.isVisible ?? true)
        }.map(\.id)
        guard LayerLockPolicy.allows(.content, on: baseID, in: self), allAllow(.delete, doomed) else { return (.refused(.locked), nil) }
        var base = layers[baseIndex]
        Self.becomeRaster(&base, raster)
        base.blendMode = .normal
        base.opacity = 1
        base.isVisible = true
        base.transform = .identity
        layers[baseIndex] = base
        let set = Set(doomed)
        layers.removeAll { set.contains($0.id) }
        return (.applied, baseID)
    }

    // MARK: Helpers

    /// A layer turned into a raster image layer: its develop recipe, local adjustments and masks are in the pixels.
    static func becomeRaster(_ layer: inout Layer, _ raster: MediaAsset) {
        layer.content = .image(raster)
        layer.edits = EditStack()
        layer.mask = nil
        layer.maskStack = nil
        layer.isMaskEnabled = true
        layer.isMaskLinked = true
        layer.bakedMask = nil
        layer.fillOpacity = 1
        layer.group = nil
        layer.recipeKind = nil
    }

    /// D17: a raster placed at its bounds (canvas-normalised): centre = the bounds' centre, scale 1 (its fit is 1 when it
    /// is no larger than the canvas); a size that is off by rounding is absorbed by scaleX/Y. Without bounds, at the
    /// centre at its natural size.
    static func rasterTransform(asset: MediaAsset, bounds: PSRect?, canvasSize: PSSize) -> LayerTransform {
        guard let bounds, bounds.width > 0, bounds.height > 0, !asset.pixelSize.isEmpty, !canvasSize.isEmpty else { return .identity }
        let fit = LayerPlacement.fitScale(contentSize: asset.pixelSize, canvasSize: canvasSize)
        var transform = LayerTransform(center: bounds.center)
        let scaleX = bounds.width * canvasSize.width / (asset.pixelSize.width * fit)
        let scaleY = bounds.height * canvasSize.height / (asset.pixelSize.height * fit)
        if abs(scaleX - 1) > 1e-6 || abs(scaleY - 1) > 1e-6 {
            transform.scaleX = scaleX
            transform.scaleY = scaleY
        }
        return transform
    }

    /// D17 add image: `fit` puts the longer side at 80 % of the canvas's shorter side, `fill` covers the canvas,
    /// `original` is one source pixel per canvas pixel; centred.
    static func imageTransform(fit: ImageLayerFit, contentSize: PSSize, canvasSize: PSSize) -> LayerTransform {
        guard !contentSize.isEmpty, !canvasSize.isEmpty else { return .identity }
        let natural = LayerPlacement.fitScale(contentSize: contentSize, canvasSize: canvasSize)
        let pixels: Double
        switch fit {
        case .fit: pixels = 0.8 * min(canvasSize.width, canvasSize.height) / max(contentSize.width, contentSize.height)
        case .fill: pixels = max(canvasSize.width / contentSize.width, canvasSize.height / contentSize.height)
        case .original: pixels = 1
        }
        let scale = pixels / natural
        return LayerTransform(scale: scale.isFinite && scale > 0 ? scale : 1)
    }

    /// Fresh operation and local-adjustment ids (component ids too) for a copied stack; rasters are shared.
    static func freshened(_ edits: EditStack) -> EditStack {
        EditStack(operations: edits.operations.map { operation in
            if case .localAdjust(let adjustment) = operation.kind {
                return EditOperation(kind: .localAdjust(adjustment.duplicated()), createdAt: operation.createdAt, label: operation.label)
            }
            return EditOperation(kind: operation.kind, createdAt: operation.createdAt, label: operation.label)
        })
    }

    static func copyName(_ name: String) -> String {
        String("\(name) copie".prefix(60))
    }

    /// « <source> · <région> », or the given name.
    static func viaName(source: String, region: MaskStack, name: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return String(name.prefix(60)) }
        return String("\(source) · \(regionLabel(region))".prefix(60))
    }

    /// The French name of what a region was made from (its first component).
    static func regionLabel(_ region: MaskStack) -> String {
        guard let first = region.components.first else { return "Zone" }
        switch first.kind {
        case .raster(let raster):
            switch raster.origin {
            case .subject: return "Sujet"
            case .background: return "Arrière-plan"
            case .people: return "Personnes"
            case .person: return "Personne"
            case .object: return raster.label.flatMap(PicshopError.frenchLabel(for:))?.capitalized ?? "Objet"
            case .sky: return "Ciel"
            case .vegetation: return "Végétation"
            case .water: return "Eau"
            case .depth: return "Profondeur"
            case .selection: return "Sélection"
            case .brush: return "Pinceau"
            case .imported: return "Masque"
            case .facePart: return "Visage"
            case .matte: return "Détourage"
            }
        case .brush: return "Pinceau"
        case .linear: return "Dégradé"
        case .radial: return "Radial"
        case .colorRange: return "Couleur"
        case .luminanceRange: return "Luminance"
        case .depthRange: return "Profondeur"
        case .unsupported: return "Zone"
        }
    }

    /// D8: the first mask edit converts a legacy mask into the stack (and clears it); returns the layer's stack.
    static func convertingLegacyMask(_ layer: inout Layer) -> MaskStack? {
        if layer.maskStack == nil, let legacy = layer.mask {
            layer.maskStack = MaskStack(legacy: legacy)
            layer.mask = nil
        }
        return layer.maskStack
    }

    /// Whether a layer's content space is the canvas (D8): fill, adjustment, group and newer layers cover it.
    static func contentSpaceIsCanvas(_ layer: Layer) -> Bool {
        switch layer.content {
        case .image, .text, .shape: return false
        case .fill, .gradientFill, .adjustment, .group, .unsupported: return true
        }
    }

    /// D17 via copy: the source's stack ∩ the region, or the region alone. Exact when the source's stack has one
    /// component (the usual case): the region's components, then the source's first one intersected; the stack-level
    /// feather, expand and density are the region's.
    static func intersecting(_ source: MaskStack?, with region: MaskStack) -> MaskStack {
        guard let source, !source.isEmpty else { return region }
        var result = pushedDownInversion(region)
        for (offset, component) in source.components.enumerated() {
            var copy = component
            copy.id = UUID()
            if offset == 0 { copy.mode = .intersect }
            result.components.append(copy)
        }
        if result.components.count > MaskStack.maxComponents { result.components = Array(result.components.prefix(MaskStack.maxComponents)) }
        return result
    }

    /// D17 via cut: the source keeps everything but the region: its stack with the region's components subtracted, or,
    /// without a stack, the region inverted (1 − region).
    static func subtracting(_ region: MaskStack, from source: MaskStack?) -> MaskStack {
        guard let source, !source.isEmpty else {
            var inverted = region
            inverted.isInverted.toggle()
            return inverted
        }
        var result = source
        for component in pushedDownInversion(region).components {
            var copy = component
            copy.id = UUID()
            switch component.mode {
            case .add: copy.mode = .subtract
            case .subtract: copy.mode = .add
            case .intersect: copy.mode = .subtract
            }
            result.components.append(copy)
        }
        if result.components.count > MaskStack.maxComponents { result.components = Array(result.components.prefix(MaskStack.maxComponents)) }
        return result
    }

    /// A one-component stack's inversion moved onto its component, so the stack can be combined with others.
    static func pushedDownInversion(_ stack: MaskStack) -> MaskStack {
        guard stack.isInverted, stack.components.count == 1 else { return stack }
        var result = stack
        result.isInverted = false
        result.components[0].isInverted.toggle()
        return result
    }

    /// Non-finite values back to their defaults, skews within ±80°, a quad of 4 finite corners or none.
    static func sanitized(_ transform: LayerTransform) -> LayerTransform {
        var clean = transform
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        clean.center = PSPoint(x: finite(transform.center.x, 0.5), y: finite(transform.center.y, 0.5))
        clean.scale = finite(transform.scale, 1)
        clean.rotation = finite(transform.rotation, 0)
        clean.scaleX = finite(transform.scaleX, 1)
        clean.scaleY = finite(transform.scaleY, 1)
        clean.skewX = LayerPlacement.clampedSkew(transform.skewX)
        clean.skewY = LayerPlacement.clampedSkew(transform.skewY)
        if let quad = transform.quad, quad.count != 4 || !quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) { clean.quad = nil }
        return clean
    }
}

public extension MaskStack {
    /// A legacy MaskReference as one raster component (D8): origin .imported, covering the layer, its invert and
    /// feather on the stack. MaskStore blurs a legacy mask with σ = feather × ½ × the longest side; the stack's σ is
    /// feather × `featherSigmaFraction` × the longest side, so the value is carried over through that ratio (at most
    /// 1, a 3 % σ). The raster's pixel size is unknown in Core and stays 0 × 0: the rasteriser reads the file's own.
    init(legacy: MaskReference) {
        let raster = RasterRef(path: legacy.relativePath, origin: .imported, pixelWidth: 0, pixelHeight: 0, boundingBox: legacy.boundingBox)
        let feather = legacy.feather.isFinite ? (legacy.feather * 0.5 / MaskStack.featherSigmaFraction).clamped(to: 0...1) : 0
        self.init(components: [MaskComponent(.raster(raster))], isInverted: legacy.isInverted, feather: feather)
    }
}
