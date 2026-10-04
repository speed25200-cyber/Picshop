import Foundation

/// A complete, serialisable photo project.
public struct PhotoDocument: Hashable, Codable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var title: String
    /// Canvas size in pixels. Equals the base image size unless cropped/upscaled.
    public var canvasSize: PSSize
    public var backgroundColor: PSColor
    public var layers: [Layer]
    public var selectedLayerID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date
    /// The main table as it was before Picshop erased its values (D7), keyed by `tableGeometryKey`.
    /// Nil until a table's values are erased; older projects decode it as nil.
    public var tableMemory: TableMemory?
    /// The one selection (W2, D7): undoable, remapped by geometry like the masks. Older projects decode it as
    /// nil, older builds ignore the key, and a selection this build cannot read opens as nil.
    public var selection: PhotoSelection?

    public init(id: UUID = UUID(), title: String, canvasSize: PSSize, backgroundColor: PSColor = .clear,
                layers: [Layer] = [], selectedLayerID: UUID? = nil, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.formatVersion = Self.formatVersion
        self.title = title
        self.canvasSize = canvasSize
        self.backgroundColor = backgroundColor
        self.layers = layers
        self.selectedLayerID = selectedLayerID ?? layers.first?.id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.selection = nil
    }

    // MARK: Codable — the synthesized layout, with a selection that can never stop a document from opening.

    private enum CodingKeys: String, CodingKey {
        case id, formatVersion, title, canvasSize, backgroundColor, layers, selectedLayerID, createdAt, modifiedAt, tableMemory, selection
    }

    /// Exactly the synthesized decoder for every key a W1 build writes, then `selection` through `try?` (D7): a
    /// selection a newer build wrote (W3 plans layer masks and document v2) decodes as nil. The encoder stays
    /// synthesized, so a document without a selection writes the same bytes as W1.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        title = try c.decode(String.self, forKey: .title)
        canvasSize = try c.decode(PSSize.self, forKey: .canvasSize)
        backgroundColor = try c.decode(PSColor.self, forKey: .backgroundColor)
        layers = try c.decode([Layer].self, forKey: .layers)
        selectedLayerID = try c.decodeIfPresent(UUID.self, forKey: .selectedLayerID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        tableMemory = try c.decodeIfPresent(TableMemory.self, forKey: .tableMemory)
        selection = try? c.decodeIfPresent(PhotoSelection.self, forKey: .selection)
    }

    /// Convenience: a document with a single image layer.
    public init(title: String, baseImage: MediaAsset) {
        let layer = Layer(name: "Photo", content: .image(baseImage))
        self.init(title: title, canvasSize: baseImage.pixelSize, layers: [layer], selectedLayerID: layer.id)
    }

    // MARK: Layer access

    public var baseLayer: Layer? { layers.first(where: { $0.isImage }) }
    public var baseLayerID: UUID? { baseLayer?.id }

    public var selectedLayer: Layer? {
        guard let selectedLayerID else { return baseLayer }
        return layers.first(where: { $0.id == selectedLayerID }) ?? baseLayer
    }

    /// The layer voice commands and tools act on: the selection if it is an image
    /// layer, otherwise the base photo.
    public var activeImageLayerID: UUID? {
        if let selected = selectedLayer, selected.isImage { return selected.id }
        return baseLayerID
    }

    public func layer(id: UUID) -> Layer? {
        layers.first(where: { $0.id == id })
    }

    /// A LUT was imported on the active image layer, at any intensity (one taken off can come back).
    public var activeLayerHasLUT: Bool {
        guard let id = activeImageLayerID, let layer = layer(id: id) else { return false }
        return layer.edits.operations.contains { operation in
            if case .lut = operation.kind { return true }
            return false
        }
    }

    public func index(of layerID: UUID) -> Int? {
        layers.firstIndex(where: { $0.id == layerID })
    }

    public mutating func update(layerID: UUID, _ body: (inout Layer) -> Void) {
        guard let index = index(of: layerID) else { return }
        body(&layers[index])
        touch()
    }

    /// Appends an operation to the active image layer.
    /// A geometric kind on the base layer remaps the local adjustments and the selection (D3). A local adjustment
    /// keeps one operation per id (D2): one that exists is replaced in place.
    public mutating func apply(_ kind: EditOperation.Kind, label: String? = nil, to layerID: UUID? = nil) {
        guard let target = layerID ?? activeImageLayerID else { return }
        if case .localAdjust(let adjustment) = kind {
            if target == localAdjustmentsLayerID {
                setLocalAdjustment(adjustment, label: label)
            } else {
                update(layerID: target) { $0.edits.setLocalAdjustment(adjustment, label: label) }
            }
            return
        }
        append(EditOperation(kind: kind, label: label), to: target)
    }

    /// `apply` for an operation that already exists (the rebase replays a command's steps with their ids): the
    /// canvas follows a crop, expand, upscale or quarter turn of the base, and masks follow its geometry (D3).
    mutating func append(_ operation: EditOperation, to target: UUID) {
        guard layer(id: target) != nil else { return }
        let kind = operation.kind
        let previousBaseEdits = kind.isGeometric && target == baseLayerID ? layer(id: target)?.edits : nil
        update(layerID: target) { layer in
            layer.edits.operations.append(operation)
        }
        if case .crop(let rect) = kind, target == baseLayerID {
            canvasSize = PSSize(width: (canvasSize.width * rect.width).rounded(), height: (canvasSize.height * rect.height).rounded())
        }
        if case .expand(let placement) = kind, target == baseLayerID, placement.width > 0.05, placement.height > 0.05 {
            canvasSize = PSSize(width: (canvasSize.width / placement.width).rounded(), height: (canvasSize.height / placement.height).rounded())
        }
        if case .upscale(let factor) = kind, target == baseLayerID {
            canvasSize = PSSize(width: (canvasSize.width * factor).rounded(), height: (canvasSize.height * factor).rounded())
        }
        if case .rotate(let degrees) = kind, target == baseLayerID, degrees.isFinite, abs(degrees) < 1e9,
           Int(degrees.rounded()) % 180 == 90 || Int(degrees.rounded()) % 180 == -90 {
            canvasSize = PSSize(width: canvasSize.height, height: canvasSize.width)
        }
        if let previousBaseEdits {
            reconcileMasks(previousBaseEdits: previousBaseEdits)
        }
    }

    /// Which way up the photo shows after its flips and quarter turns.
    public var baseOrientation: EditStack.Orientation {
        baseLayer?.edits.netOrientation ?? .upright
    }

    /// Puts the photo back the right way up. The correction is added after the
    /// other edits, so crops and selections made on the turned picture stay put.
    /// Returns false when it already was.
    @discardableResult
    public mutating func resetOrientation(label: String? = nil) -> Bool {
        guard let baseID = baseLayerID else { return false }
        let correction = baseOrientation.correction
        guard !correction.isEmpty else { return false }
        for kind in correction { apply(kind, label: label, to: baseID) }
        return true
    }

    /// Takes the last flip away and keeps every turn made around it ("annule le
    /// miroir" after a quarter turn and a mirror leaves the quarter turn).
    /// Returns false when the photo is not mirrored.
    @discardableResult
    public mutating func removeMirror(label: String? = nil) -> Bool {
        guard let baseID = baseLayerID, let edits = baseLayer?.edits, edits.netOrientation.mirrored,
              let flip = edits.operations.lastIndex(where: { if case .flip = $0.kind { return true } else { return false } }) else { return false }
        var without = edits
        without.operations.remove(at: flip)
        let wanted = without.netOrientation
        let fixes: [[EditOperation.Kind]] = [[.flip(.horizontal)], [.flip(.vertical)], [.flip(.horizontal), .rotate(degrees: 90)], [.flip(.horizontal), .rotate(degrees: -90)]]
        guard let fix = fixes.first(where: { fix in
            var trial = edits
            for kind in fix { trial.append(kind) }
            return trial.netOrientation == wanted
        }) else { return false }
        for kind in fix { apply(kind, label: label, to: baseID) }
        return true
    }

    /// The photo as it was imported: every edit on it gone, the frame back to
    /// its own size. Added layers stay, except the cut-out laid over a title
    /// behind the subject: it copies the photo's edits and would no longer line up.
    public func restoredToImport() -> PhotoDocument {
        var document = self
        guard let baseID = baseLayerID, let base = baseLayer, let asset = base.imageAsset else { return document }
        if !base.edits.isEmpty || base.mask != nil {
            document.layers.removeAll { $0.name == Self.subjectLayerName && $0.id != baseID }
            if let selected = document.selectedLayerID, document.layer(id: selected) == nil { document.selectedLayerID = baseID }
        }
        document.update(layerID: baseID) { layer in
            layer.edits = EditStack()
            layer.mask = nil
        }
        document.canvasSize = asset.pixelSize
        // The selection was drawn on the edited picture (D3): it goes with the edits.
        document.selection = nil
        return document
    }

    public mutating func addLayer(_ layer: Layer, select: Bool = true) {
        layers.append(layer)
        if select { selectedLayerID = layer.id }
        touch()
    }

    @discardableResult
    public mutating func removeLayer(id: UUID) -> Layer? {
        guard let index = index(of: id), !(layers[index].isImage && index == 0) else { return nil }
        let removed = layers.remove(at: index)
        if selectedLayerID == id { selectedLayerID = baseLayerID }
        touch()
        return removed
    }

    public mutating func moveLayer(id: UUID, to newIndex: Int) {
        guard let index = index(of: id), newIndex >= 0, newIndex < layers.count, index != newIndex else { return }
        let layer = layers.remove(at: index)
        layers.insert(layer, at: newIndex)
        touch()
    }

    public mutating func touch() {
        modifiedAt = Date()
    }

    /// Sets or clears the selection (one history step for the caller).
    public mutating func setSelection(_ selection: PhotoSelection?) {
        self.selection = selection
        touch()
    }

    /// Effective adjustments of the active image layer (what the sliders show).
    public var activeAdjustments: Adjustments {
        guard let id = activeImageLayerID, let layer = layer(id: id) else { return .neutral }
        return layer.edits.resolvedAdjustments
    }

    public var textLayers: [Layer] { layers.filter(\.isText) }
    public var shapeLayers: [Layer] { layers.filter(\.isShape) }

    /// Aspect ratio of the current canvas.
    public var aspectRatio: Double { canvasSize.aspectRatio }
}

// MARK: - Text behind the subject

extension PhotoDocument {
    /// Name of the cut-out copy of the subject laid over the title.
    public static let subjectLayerName = "Subject"

    /// The Lock Screen depth effect: a big title, with the subject cut out and
    /// laid on top of it so the words pass behind the person. A given `text`
    /// makes a new title; without one the latest title is reused, or a
    /// `placeholder` is written. Returns the title layer's id.
    @discardableResult
    public mutating func placeTextBehindSubject(_ text: String?, subjectMask: MaskReference, placeholder: String) -> UUID? {
        guard let base = baseLayer, let asset = base.imageAsset else { return nil }
        layers.removeAll { $0.name == Self.subjectLayerName }
        var titleID = text == nil ? textLayers.last?.id : nil
        if titleID == nil {
            let words = (text?.isEmpty == false ? text : nil) ?? placeholder
            let element = TextElement(text: words, relativeSize: words.count > 8 ? 0.14 : 0.2, color: .white, style: .plain,
                                      center: PSPoint(x: 0.5, y: 0.32), letterSpacing: -0.03, lineSpacing: 0.9, maxRelativeWidth: 0.96)
            let layer = Layer(name: element.text, content: .text(element))
            addLayer(layer, select: false)
            titleID = layer.id
        }
        var subject = Layer(name: Self.subjectLayerName, content: .image(asset), isLocked: true, edits: base.edits)
        subject.edits.append(.removeBackground(subjectMask))
        addLayer(subject, select: false)
        selectedLayerID = titleID
        return titleID
    }
}

// MARK: - Masks through geometry, and the session's rebase (D3)

public extension PhotoDocument {
    /// The share of the canvas a remapped selection's box must keep, else the selection is dropped (D3, D7).
    static let selectionKeepThreshold = 0.002

    /// D3: remaps local adjustments and the selection when the base layer's geometry chain changed since
    /// `previousBaseEdits`; drops the selection when its remapped box keeps < 0.2 % of the canvas.
    ///
    /// Mask points live in the base's output space, so they go back through the old chain to the photo and
    /// forward through the new one: inverse(chain(old)).then(chain(new)). Aspects come from the asset's pixel
    /// size through each chain, never from `canvasSize`. Every path that changes the base geometry calls it:
    /// `apply` (here), the in-place perspective handler and the aspect « original » path (M4).
    mutating func reconcileMasks(previousBaseEdits: EditStack) {
        guard let baseID = baseLayerID, let base = layer(id: baseID) else { return }
        let source = sourceAspect(of: base)
        let old = previousBaseEdits.geometryChain(sourceAspect: source)
        let new = base.edits.geometryChain(sourceAspect: source)
        guard !old.map.isApproximatelyEqual(to: new.map) || abs(old.aspect - new.aspect) > 1e-12 else { return }
        guard let back = old.map.inverse else { return }
        let map = back.then(new.map)
        if base.edits.operations.contains(where: { if case .localAdjust = $0.kind { return true } else { return false } }) {
            update(layerID: baseID) { layer in
                for index in layer.edits.operations.indices {
                    guard case .localAdjust(var adjustment) = layer.edits.operations[index].kind else { continue }
                    adjustment.stack = adjustment.stack.remapped(by: map, aspectBefore: old.aspect, aspectAfter: new.aspect)
                    let operation = layer.edits.operations[index]
                    layer.edits.operations[index] = EditOperation(id: operation.id, kind: .localAdjust(adjustment), createdAt: operation.createdAt, label: operation.label)
                }
            }
        }
        if let selection, selection.layerID == baseID {
            self.selection = selection.remapped(by: map)
        }
    }

    /// The session's rebase (D3), on Core so Linux tests it: `self` is the current document; nil when `updated`
    /// cannot be replayed onto it.
    ///
    /// A command's result replayed onto what was committed while it ran. Only the operations it appended carry
    /// over, and only when the photo meanwhile got nothing but tonal steps (a slider, a look, a mask's dials):
    /// a crop or an undo in between would put its mask in the wrong place, so then nil. Tone is applied after
    /// every other step, so tonal steps are left out of the comparison: a dial nudged again rewrites its last
    /// step in place. W2 adds three rules:
    /// 1. local adjustments merge by id: the command's version wins for the ids it changed (an in-place
    ///    `setLocalAdjustment` is no longer a broken prefix); the ones it did not touch keep the current version.
    ///    A mask the command edited but that was deleted meanwhile gives nil.
    /// 2. the selection carries over when only the command changed it; both changing it gives nil.
    /// 3. geometric steps are re-appended through the document, so current masks are remapped and the canvas
    ///    follows; the canvas guard therefore compares only the current document with the base.
    /// What the command changed is measured against the base with the command's own steps replayed, so a mask
    /// that only moved with the command's crop does not count as changed by it.
    func rebased(_ updated: PhotoDocument, from base: PhotoDocument) -> PhotoDocument? {
        let current = self
        guard current.canvasSize == base.canvasSize, updated.layers.map(\.id) == base.layers.map(\.id) else { return nil }
        var result = current
        // The base with the command's appended steps replayed: the reference for what the command changed.
        var projected = base
        var replays: [(layerID: UUID, operations: [EditOperation])] = []
        for (before, after) in zip(base.layers, updated.layers) {
            var untouched = after
            untouched.edits = before.edits
            guard untouched == before else { return nil }
            let old = before.edits.operations.filter { !Self.isLocal($0.kind) }
            let new = after.edits.operations.filter { !Self.isLocal($0.kind) }
            guard new.count >= old.count, Array(new.prefix(old.count)) == old else { return nil }
            let added = Array(new.dropFirst(old.count))
            let localsChanged = before.edits.resolvedLocalAdjustments != after.edits.resolvedLocalAdjustments
            guard !added.isEmpty || localsChanged else { continue }
            guard let index = result.index(of: after.id) else { return nil }
            let now = result.layers[index].edits.operations
            guard now.filter({ !Self.isRebaseTonal($0.kind) }) == before.edits.operations.filter({ !Self.isRebaseTonal($0.kind) }) else { return nil }
            if !added.isEmpty { replays.append((after.id, added)) }
        }
        for replay in replays {
            for operation in replay.operations {
                projected.append(operation, to: replay.layerID)
                result.append(operation, to: replay.layerID)
            }
        }
        // The command changed the canvas some other way than by the steps it appended: it cannot be replayed.
        guard projected.canvasSize == updated.canvasSize else { return nil }
        // Local adjustments, by id (rule 1).
        for (target, after) in zip(projected.layers, updated.layers) {
            let reference = target.edits.resolvedLocalAdjustments
            let wanted = after.edits.resolvedLocalAdjustments
            guard reference != wanted else { continue }
            let referenceByID = Dictionary(reference.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            let wantedIDs = Set(wanted.map(\.id))
            guard let index = result.index(of: after.id) else { return nil }
            var edits = result.layers[index].edits
            for adjustment in wanted where referenceByID[adjustment.id] != adjustment {
                if referenceByID[adjustment.id] != nil, edits.localAdjustment(id: adjustment.id) == nil { return nil }
                let label = after.edits.operations.last { operation in
                    if case .localAdjust(let candidate) = operation.kind { return candidate.id == adjustment.id }
                    return false
                }?.label
                edits.setLocalAdjustment(adjustment, label: label)
            }
            for adjustment in reference where !wantedIDs.contains(adjustment.id) {
                edits.removeLocalAdjustment(id: adjustment.id)
            }
            guard edits.resolvedLocalAdjustments.count <= LocalAdjustment.maxPerLayer else { return nil }
            result.update(layerID: after.id) { $0.edits = edits }
        }
        // The selection (rule 2). It lives in the base's output space: a turn or flip committed meanwhile would
        // misplace the command's selection.
        if updated.selection != projected.selection {
            guard current.selection == base.selection, current.baseGeometry == base.baseGeometry else { return nil }
            result.selection = updated.selection
            result.touch()
        }
        return result
    }

    /// The steps a rebase lets through underneath a command (moved verbatim from the session at the W2 seam):
    /// tone and colour, and local adjustments (W2), which render after them.
    internal static func isRebaseTonal(_ kind: EditOperation.Kind) -> Bool {
        switch kind {
        case .adjust, .adjustments, .toneCurve, .levels, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut, .localAdjust: return true
        default: return false
        }
    }

    private static func isLocal(_ kind: EditOperation.Kind) -> Bool {
        if case .localAdjust = kind { return true }
        return false
    }

    /// The base layer's geometric operations, in order.
    private var baseGeometry: [EditOperation] {
        baseLayer?.edits.operations.filter { $0.kind.isGeometric } ?? []
    }
}

extension PhotoSelection {
    /// The selection after `map` (D3): its corners move, its coverage is re-estimated from the area its quad
    /// gains or loses and the share of its box still on the canvas, and nil when that box keeps less than
    /// `PhotoDocument.selectionKeepThreshold` of the canvas.
    func remapped(by map: PSHomography) -> PhotoSelection? {
        let toOld = PSHomography.quad(from: RasterRef.unitCorners, to: corners) ?? .identity
        let toNew = toOld.then(map)
        let box = mask.boundingBox
        let boxCorners = [PSPoint(x: box.minX, y: box.minY), PSPoint(x: box.maxX, y: box.minY),
                          PSPoint(x: box.maxX, y: box.maxY), PSPoint(x: box.minX, y: box.maxY)].map(toNew.apply)
        let xs = boxCorners.map(\.x), ys = boxCorners.map(\.y)
        let moved = PSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let kept = moved.intersection(.unit).area
        guard kept.isFinite, kept >= PhotoDocument.selectionKeepThreshold else { return nil }
        var result = self
        result.corners = corners.map(map.apply)
        let oldArea = Self.quadArea(corners), newArea = Self.quadArea(result.corners)
        let keptShare = moved.area > 0 ? kept / moved.area : 0
        if oldArea > 1e-12, newArea.isFinite {
            result.coverage = (coverage * newArea / oldArea * keptShare).clamped(to: 0...1)
        }
        return result
    }

    /// The shoelace area of four corners (in normalised units).
    static func quadArea(_ points: [PSPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var twice = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }
}
