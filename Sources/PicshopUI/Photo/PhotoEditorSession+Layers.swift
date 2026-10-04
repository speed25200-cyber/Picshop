#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

// Calques (W3, L3): every layer change the column, the inspector, the menus and the canvas make goes through
// `PhotoDocument.applyLayerEdit` or `applyStructureEdit` (D7, D8, D17), on the W1 hooks: `commit` for one step, or
// beginInteraction → interactiveEdit → endInteraction for a drag (one undo step per drag). Locks and the tree rules are
// Core's, so a refusal reads the same here as in Live (`PhotoDocument.refusalMessage`), with a light haptic.
//
// The views read `layerState.rows`, a coarse mirror rebuilt by `layersDidChange` when a step lands (never per drag
// frame), and the thumbnails rendered off the main actor once an interaction settles.
extension PhotoEditorSession {
    /// The interface's language for layer names and VoiceOver.
    var layerLanguage: OpLanguage { psPrefersFrench ? .fr : .en }

    /// The history labels the layer tools write: English keys, read through `LD()` by the History menu and the undo
    /// toast. Listed here so the strings catalog carries their French.
    static let layerHistoryLabels: [String] = [
        L("Show Layer"), L("Hide Layer"), L("Opacity"), L("Fill"), L("Blend"), L("Lock"), L("Clipping Mask"), L("Rename Layer"),
        L("Pass Through"), L("Duplicate Layer"), L("Delete Layer"), L("Group Layers"), L("Ungroup"), L("Reorder Layers"), L("Align Layers"),
        L("Fill Layer"), L("Adjustment Layer"), L("Add Photo Layer"), L("Layer via Copy"), L("Layer via Cut"), L("Merge Down"),
        L("Merge Layers"), L("Merge Visible"), L("Flatten Image"), L("Stamp Visible"), L("Apply Mask"), L("Layer Mask"), L("Transform"),
        L("Look"), L("Look Intensity"), L("LUT Intensity"), L("Colour Mixer"), L("Colour Grading"), L("Layers"),
    ]

    /// Pro layers on: groups, clipping, fill, partial locks, gradient fills, layer masks, via copy and cut, merges
    /// (D24). Off, documents that already have such state keep rendering and saving it.
    var proLayersEnabled: Bool { FeatureFlags.isOn(.proLayers) }

    // MARK: - The mirror (§7.2)

    /// After every document change, outside a text drag: the rows, the multi-selection, the transform and mask-paint
    /// targets, the thumbnails.
    func layersDidChange(_ document: PhotoDocument) {
        let rows = Self.layerRows(for: document, language: layerLanguage)
        if rows != layerState.rows { layerState.rows = rows }
        let ids = Set(document.layers.map(\.id))
        let kept = layerState.multiSelection.filter { ids.contains($0) }
        if kept != layerState.multiSelection { layerState.multiSelection = kept }
        if let target = layerState.transformTarget, !ids.contains(target) { endTransformMode() }
        if let editing = layerState.editingMaskOf, !ids.contains(editing) { endLayerMaskPaint() }
        if let open = layerState.maskControlsOf, !ids.contains(open) { layerState.maskControlsOf = nil }
        refreshLayerThumbnails()
    }

    /// The rows top first, as `LayerReorder.rows` lists them, with what each row draws.
    static func layerRows(for document: PhotoDocument, language: OpLanguage) -> [LayerRowState] {
        let selectedID = document.selectedLayerID ?? document.baseLayerID
        let selectedBundle = document.selectedLayer?.group?.id
        return LayerReorder.rows(for: document).compactMap { model -> LayerRowState? in
            guard let layer = document.layer(id: model.id) else { return nil }
            let isBase = layer.id == document.baseLayerID
            let bundle: (kind: LayerGroup.Kind, count: Int)? = model.bundleCount.flatMap { count in layer.group.map { (kind: $0.kind, count: count) } }
            let members = bundle != nil ? document.layers.filter { $0.group?.id == layer.group?.id } : [layer]
            let isSelected = selectedID == layer.id || (bundle != nil && selectedBundle != nil && selectedBundle == layer.group?.id)
            let hasMask = layer.maskStack != nil || layer.mask != nil
            var row = LayerRowState(model: model,
                                    name: LayerAccessibility.displayName(layer, isBase: isBase, bundle: bundle, language: language),
                                    blendLabel: layer.blendMode == .normal ? "" : BlendModeMenu.name(layer.blendMode),
                                    opacityPercent: Int((layer.opacity * 100).rounded()),
                                    isVisible: members.contains(where: \.isVisible),
                                    lock: document.effectiveLock(of: layer.id),
                                    hasMask: hasMask,
                                    isSelected: isSelected,
                                    thumbnailKey: thumbnailKey(layer, members: members, in: document))
            row.isBase = isBase
            row.symbol = symbol(for: layer, bundle: bundle?.kind)
            switch layer.content {
            case .fill(let color): row.look = .swatch(color)
            case .adjustment: row.look = .glyph
            default: row.look = .rendered
            }
            row.isMaskEnabled = layer.isMaskEnabled
            row.isClipIgnored = layer.isClipped && !layer.isGroup && document.clippingBase(of: layer.id) == nil
            row.isCollapsed = layer.folder?.isCollapsed ?? false
            row.fillPercent = Int((layer.fillOpacity * 100).rounded())
            row.ref = layerRef(layer, in: document)
            row.accessibilityLabel = LayerAccessibility.label(for: layer, in: document, isSelected: isSelected, language: language)
            if hasMask {
                var hasher = Hasher()
                hasher.combine(layer.maskStack)
                hasher.combine(layer.mask)
                hasher.combine(layer.isMaskEnabled)
                hasher.combine(layer.isMaskLinked)
                hasher.combine(layer.transform)
                row.maskThumbnailKey = String(hasher.finalize(), radix: 36)
            }
            return row
        }
    }

    /// The thumbnail's key: what the layer draws and where (content, recipe, masks, transform, the canvas), its
    /// children for a group, its members for a table. Hashed in memory only; it never changes during a drag because
    /// the rows are rebuilt only when a step lands.
    static func thumbnailKey(_ layer: Layer, members: [Layer], in document: PhotoDocument) -> String {
        var hasher = Hasher()
        hasher.combine(document.canvasSize)
        let drawn = layer.isGroup ? document.children(of: layer.id) + [layer] : members
        for member in drawn {
            hasher.combine(member.content)
            hasher.combine(member.edits)
            hasher.combine(member.transform)
            hasher.combine(member.maskStack)
            hasher.combine(member.mask)
            hasher.combine(member.isMaskEnabled)
            hasher.combine(member.isVisible)
            hasher.combine(member.blendMode)
            hasher.combine(member.opacity)
            hasher.combine(member.fillOpacity)
        }
        return String(hasher.finalize(), radix: 36)
    }

    /// The kind's glyph: an image, text, a shape, a fill, a gradient, an adjustment's kind, a folder, a table.
    static func symbol(for layer: Layer, bundle: LayerGroup.Kind?) -> String {
        if let bundle { return bundle == .tableCells ? "tablecells" : "highlighter" }
        if layer.isAdjustment { return adjustmentSymbol(layer.recipeKind ?? .light) }
        return layer.symbolName
    }

    static func adjustmentSymbol(_ kind: AdjustmentLayerKind) -> String {
        switch kind {
        case .light: return "sun.max"
        case .curves: return "chart.xyaxis.line"
        case .levels: return "chart.bar.xaxis"
        case .hsl: return "paintpalette"
        case .colorGrade: return "circle.circle"
        case .lut: return "cube.transparent"
        case .look: return "camera.filters"
        }
    }

    /// « i2 », « j1 », « g1 » (D19): the resolver's ref when L4's lines know the layer, else the stored number.
    static func layerRef(_ layer: Layer, in document: PhotoDocument) -> String? {
        if let ref = LiveLayerLines.ref(of: layer.id, in: document, scene: nil) { return ref }
        guard let prefix = layer.refPrefix, let number = layer.refNumber else { return nil }
        return "\(prefix)\(number)"
    }

    /// The rows the column and the list show: collapsed groups' children left out.
    var visibleLayerRows: [LayerRowState] {
        layerState.rows.filter { !$0.model.isCollapsedChild }
    }

    /// Whether the column shows (§7.1): more than the base, or the Calques tool open; never while cropping or under
    /// a brush or transform drag.
    var showsLayersColumn: Bool {
        guard FeatureFlags.isOn(.layersColumn), layerState.showsColumn, !isCropping, !layerState.isCanvasGestureActive else { return false }
        return layerState.rows.count > 1 || activeTool == .layers
    }

    // MARK: - Thumbnails (off the main actor, after a settle)

    /// Renders the thumbnails whose key changed, one after the other, never while a drag runs. A solid fill draws its
    /// swatch and an adjustment layer its kind's glyph: neither needs one (§4.11).
    func refreshLayerThumbnails() {
        guard let renderer, activeTool == .layers || showsLayersColumn else { return }
        let store = layerState.thumbnails
        let rows = layerState.rows
        let ids = Set(rows.map(\.id))
        for id in Array(store.images.keys) where !ids.contains(id) {
            store.images[id] = nil
            store.imageKeys[id] = nil
        }
        for id in Array(store.masks.keys) where !ids.contains(id) {
            store.masks[id] = nil
            store.maskKeys[id] = nil
        }
        let images = rows.filter { $0.look == .rendered && store.imageKeys[$0.id] != $0.thumbnailKey }
        let masks = rows.filter { $0.hasMask && store.maskKeys[$0.id] != $0.maskThumbnailKey }
        guard !images.isEmpty || !masks.isEmpty else { return }
        let document = self.document
        store.task?.cancel()
        store.task = Task { [weak self] in
            for row in images {
                guard await self?.waitForSettle() == true else { return }
                let image = try? await renderer.layerThumbnail(row.id, in: document, side: 88)
                guard !Task.isCancelled else { return }
                store.imageKeys[row.id] = row.thumbnailKey
                store.images[row.id] = image.map { UIImage(cgImage: $0) }
            }
            for row in masks {
                guard await self?.waitForSettle() == true else { return }
                let image = try? await renderer.layerMaskThumbnail(row.id, in: document, side: 56)
                guard !Task.isCancelled else { return }
                store.maskKeys[row.id] = row.maskThumbnailKey
                store.masks[row.id] = image.map { UIImage(cgImage: $0) }
            }
        }
    }

    /// Waits while a drag is under way (thumbnails are drawn after the settle, §7.2); false when cancelled.
    private func waitForSettle() async -> Bool {
        while interaction != nil {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return false }
        }
        return !Task.isCancelled
    }

    // MARK: - One path for every edit

    /// A layer edit as one undo step; a refusal says why (D7). True when the document allows it (applied or
    /// unchanged).
    @discardableResult
    func applyLayerEdit(_ edit: LayerEdit, to layerID: UUID, label: String) -> Bool {
        var updated = document
        switch updated.applyLayerEdit(edit, to: layerID, contentSize: layerContentSize(layerID)) {
        case .applied:
            commit(updated, label: label)
            return true
        case .unchanged:
            return true
        case .refused(let refusal):
            refuseLayerEdit(refusal, layerID: layerID)
            return false
        }
    }

    /// Several layer edits as one undo step (the multi-selection, a lock that clears `isLocked`); the first refusal
    /// stops them all.
    @discardableResult
    func applyLayerEdits(_ edits: [(LayerEdit, UUID)], label: String) -> Bool {
        var updated = document
        for (edit, layerID) in edits {
            if case .refused(let refusal) = updated.applyLayerEdit(edit, to: layerID, contentSize: layerContentSize(layerID)) {
                refuseLayerEdit(refusal, layerID: layerID)
                return false
            }
        }
        if updated != document { commit(updated, label: label) }
        return true
    }

    /// A structure edit as one undo step; returns the id of the layer it made or changed (the selected one for a
    /// removal), nil when refused.
    @discardableResult
    /// `rasterBounds` places a raster cropped to its opaque bounds where it was rendered (merge, apply mask).
    func applyStructureEdit(_ edit: LayerStructureEdit, label: String, refusalLayer: UUID? = nil,
                            rasterBounds: PSRect? = nil) -> UUID? {
        var updated = document
        let (outcome, layerID) = updated.applyStructureEdit(edit, rasterBounds: rasterBounds)
        switch outcome {
        case .applied:
            commit(updated, label: label)
            return layerID ?? updated.selectedLayerID
        case .unchanged:
            return layerID ?? updated.selectedLayerID
        case .refused(let refusal):
            refuseLayerEdit(refusal, layerID: refusalLayer ?? Self.subject(of: edit))
            return nil
        }
    }

    /// The layer a structure edit is about, for its refusal message.
    static func subject(of edit: LayerStructureEdit) -> UUID? {
        switch edit {
        case .remove(let id), .duplicate(let id), .move(let id, _), .ungroup(let id), .mergeDown(let id, _), .applyMask(let id, _): return id
        case .viaCopy(let source, _, _), .viaCut(let source, _, _): return source
        case .group(let ids, _), .mergeLayers(let ids, _): return ids.last
        case .add, .mergeVisible, .flatten, .stamp, .addImage: return nil
        }
    }

    /// « Le calque « Tasse » est verrouillé : déverrouille-le d'abord. », with a light haptic; the same message is not
    /// shown (nor felt) again while it is on screen (a drag refused at every frame).
    func refuseLayerEdit(_ refusal: LayerEditRefusal, layerID: UUID?) {
        let name = layerID.flatMap { document.layer(id: $0) }.map {
            LayerAccessibility.displayName($0, isBase: $0.id == document.baseLayerID, language: layerLanguage)
        }
        let message = PhotoDocument.refusalMessage(refusal, layerName: name, french: psPrefersFrench)
        guard toast?.text != message else { return }
        Haptics.tap()
        showToast(message, isError: true)
    }

    /// Whether the locks allow `mutation` on the layer now (D7); a refusal is said.
    func layerAllows(_ mutation: LayerMutation, on layerID: UUID) -> Bool {
        guard LayerLockPolicy.allows(mutation, on: layerID, in: document) else {
            refuseLayerEdit(.locked, layerID: layerID)
            return false
        }
        return true
    }

    /// The content size the placement maths need (D10): Core's (images, shapes, fills, groups), the text raster's.
    func layerContentSize(_ layerID: UUID) -> PSSize? {
        guard let layer = document.layer(id: layerID) else { return nil }
        return Self.contentSize(of: layer, canvasSize: document.canvasSize)
    }

    static func contentSize(of layer: Layer, canvasSize: PSSize) -> PSSize? {
        if let size = LayerPlacement.contentSize(of: layer, canvasSize: canvasSize) { return size }
        guard let element = layer.textElement else { return nil }
        let canvas = CGSize(width: canvasSize.width, height: canvasSize.height)
        guard canvas.width > 0, canvas.height > 0, let size = TextRasterizer.boundingSize(for: element, canvasSize: canvas) else { return nil }
        return PSSize(width: Double(size.width), height: Double(size.height))
    }

    // MARK: - Selection

    /// A tap on a row or a cell: in « Sélectionner » mode it toggles the layer in the multi-selection, else it selects.
    func tapLayer(_ id: UUID) {
        Haptics.tick()
        if layerState.isSelecting {
            toggleMultiSelection(id)
            return
        }
        guard document.selectedLayerID != id else { return }
        selectLayer(id)
    }

    func toggleMultiSelection(_ id: UUID) {
        if layerState.multiSelection.contains(id) {
            layerState.multiSelection.remove(id)
        } else {
            layerState.multiSelection.insert(id)
        }
    }

    /// « Sélectionner »: check circles on (the selected layer starts the set); off again clears the set.
    func setSelecting(_ on: Bool) {
        guard layerState.isSelecting != on else { return }
        layerState.isSelecting = on
        if on, let selected = document.selectedLayerID, selected != document.baseLayerID {
            layerState.multiSelection = [selected]
        } else if !on {
            layerState.multiSelection = []
        }
        Haptics.tick()
    }

    /// « Transparence » in the zoom menu: the checkerboard under transparent areas on or off (view only, never exported).
    func setShowsTransparency(_ shows: Bool) {
        guard layerState.showsTransparency != shows else { return }
        layerState.showsTransparency = shows
        canvasSink?.setShowsTransparencyGrid(shows)
        Haptics.tick()
    }

    /// A double tap on a column cell: the layer selected and the Layers inspector open at medium height.
    func openLayersInspector(selecting id: UUID? = nil) {
        if let id, document.selectedLayerID != id, !layerState.isSelecting { selectLayer(id) }
        if activeTool != .layers { activeTool = .layers }
        layerState.inspectorDetentRequest = .medium
        Haptics.tick()
    }

    /// The layers an action from the bar or a menu acts on: the multi-selection in « Sélectionner » mode, in
    /// document order (bottom → top, so a merge or a group keeps the stacking), else the selected one.
    var actedLayers: [UUID] {
        if layerState.isSelecting, !layerState.multiSelection.isEmpty {
            return document.layers.map(\.id).filter { layerState.multiSelection.contains($0) }
        }
        return document.selectedLayerID.map { [$0] } ?? []
    }

    // MARK: - Properties

    /// Visibility, never refused (D7): one step, a whole table at once.
    func toggleVisibility(_ id: UUID) {
        guard let layer = document.layer(id: id) else { return }
        let shown = document.bundle(containing: id).map { bundle in bundle.memberIDs.contains { document.layer(id: $0)?.isVisible == true } } ?? layer.isVisible
        applyLayerEdit(.visible(!shown), to: id, label: shown ? "Hide Layer" : "Show Layer")
        Haptics.tick()
    }

    /// A property drag begins on one layer (opacity, fill, the blend preview): one undo step, the `.layerPlacement`
    /// snapshot (D13). False when a lock refuses it.
    @discardableResult
    func beginLayerPropertyDrag(_ id: UUID, label: String) -> Bool {
        guard layerAllows(.properties, on: id) else { return false }
        beginInteraction(label: label, scope: .layerPlacement(id))
        return true
    }

    /// Opacity 0…1, on the dragged copy during a drag, else one step.
    func setLayerOpacityValue(_ value: Double, layerID: UUID) {
        let opacity = value.clamped(to: 0...1)
        guard document.layer(id: layerID) != nil else { return }
        if interaction == nil, !layerAllows(.properties, on: layerID) { return }
        interactiveEdit(label: "Opacity") { document in
            document.applyLayerEdit(.opacity(opacity), to: layerID)
        }
    }

    /// Fill opacity 0…1 (D6); groups have none.
    func setLayerFill(_ value: Double, layerID: UUID) {
        let fill = value.clamped(to: 0...1)
        guard let layer = document.layer(id: layerID), !layer.isGroup else { return }
        if interaction == nil, !layerAllows(.properties, on: layerID) { return }
        interactiveEdit(label: "Fill") { document in
            document.applyLayerEdit(.fillOpacity(fill), to: layerID)
        }
    }

    /// The blend picker opens: each mode it centres is a live preview (an interactive edit), committed on choose,
    /// dropped on dismiss (§7.3).
    @discardableResult
    func beginBlendPreview(_ id: UUID) -> Bool {
        beginLayerPropertyDrag(id, label: "Blend")
    }

    func previewBlend(_ mode: PicshopCore.BlendMode, layerID: UUID) {
        guard interaction != nil else { return }
        interactiveEdit(label: "Blend") { document in
            document.applyLayerEdit(.blendMode(mode), to: layerID)
        }
    }

    func commitBlendPreview() {
        guard interaction != nil else { return }
        endInteraction()
        Haptics.tick()
    }

    func cancelBlendPreview() {
        guard interaction != nil else { return }
        cancelInteraction()
    }

    /// A blend mode chosen straight away (a menu, VoiceOver): one step.
    func setBlend(_ mode: PicshopCore.BlendMode, layerID: UUID) {
        applyLayerEdit(.blendMode(mode), to: layerID, label: "Blend")
        Haptics.tick()
    }

    /// The lock segmented control: « Tout » is the v1 lock (`isLocked`), the others the partial ones (D7).
    func setLock(_ value: String, layerID: UUID) {
        guard let choice = PhotoPanelInventory.lockChoices.first(where: { $0.value == value }) else { return }
        guard value == "all" || value == "none" || proLayersEnabled else { return }
        if value == "all" {
            applyLayerEdits([(.lockAll(true), layerID), (.lock([]), layerID)], label: "Lock")
        } else {
            applyLayerEdits([(.lockAll(false), layerID), (.lock(choice.lock), layerID)], label: "Lock")
        }
        Haptics.tick()
    }

    /// The row's padlock: lock all on or off.
    func toggleLock(_ id: UUID) {
        let locked = !(document.layer(id: id)?.ownLock.isEmpty ?? true)
        setLock(locked ? "none" : "all", layerID: id)
    }

    /// « Écrêtage » (D5).
    func setClipped(_ clipped: Bool, layerID: UUID) {
        guard proLayersEnabled || !clipped else { return }
        applyLayerEdit(.clipped(clipped), to: layerID, label: "Clipping Mask")
        Haptics.tick()
    }

    func renameLayer(_ id: UUID, to name: String) {
        applyLayerEdit(.rename(name), to: id, label: "Rename Layer")
    }

    /// « Transfert » on a group (D4).
    func setPassThrough(_ passThrough: Bool, groupID: UUID) {
        guard var folder = document.layer(id: groupID)?.folder else { return }
        folder.passThrough = passThrough
        applyLayerEdit(.folder(folder), to: groupID, label: "Pass Through")
    }

    /// A group's chevron: view state stored in the document, amended without a new step (a locked group folds too).
    func setCollapsed(_ collapsed: Bool, groupID: UUID) {
        guard var folder = document.layer(id: groupID)?.folder, folder.isCollapsed != collapsed else { return }
        folder.isCollapsed = collapsed
        var updated = document
        let content = Layer.Content.group(folder)
        updated.update(layerID: groupID) { $0.content = content }
        amendPresent(updated)
        Haptics.tick()
    }

    // MARK: - Structure

    /// Dupliquer: each acted layer copied above itself (a group with its children), one step.
    func duplicateLayers(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var updated = document
        for id in ids {
            if case .refused(let refusal) = updated.applyStructureEdit(.duplicate(id)).outcome {
                refuseLayerEdit(refusal, layerID: id)
                return
            }
        }
        guard updated != document else { return }
        commit(updated, label: "Duplicate Layer")
        Haptics.confirm()
    }

    /// Supprimer: a group asks first (« Supprimer le groupe et son contenu ? »).
    func requestDeleteLayers(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.contains(where: { document.layer(id: $0)?.isGroup == true }) {
            layerState.confirmation = ids.count == 1 ? .deleteGroup(ids[0]) : .deleteSelection(Set(ids))
            return
        }
        deleteLayers(ids)
    }

    /// Deletes in one step (a group with its contents, D4); the base and locked layers refuse.
    func deleteLayers(_ ids: [UUID]) {
        var updated = document
        for id in ids where updated.layer(id: id) != nil {
            if case .refused(let refusal) = updated.applyStructureEdit(.remove(id)).outcome {
                refuseLayerEdit(refusal, layerID: id)
                return
            }
        }
        guard updated != document else { return }
        commit(updated, label: "Delete Layer")
        layerState.multiSelection = []
        Haptics.warning()
    }

    /// Grouper: the acted layers in one new group (« Groupe <n> »), where the topmost was (D4).
    func groupLayers(_ ids: [UUID]) {
        guard proLayersEnabled, !ids.isEmpty else { return }
        guard applyStructureEdit(.group(ids, name: nil), label: "Group Layers") != nil else { return }
        layerState.multiSelection = []
        Haptics.confirm()
    }

    /// Dissocier: the children stay in place, an isolated group's opacity is folded in, a group mask is dropped with
    /// a toast (D4).
    func ungroup(_ id: UUID) {
        guard let group = document.layer(id: id), group.isGroup else { return }
        let hadMask = group.maskStack != nil || group.mask != nil
        guard applyStructureEdit(.ungroup(id), label: "Ungroup") != nil else { return }
        Haptics.confirm()
        if hadMask { showToast(L("The group's mask was removed.")) }
    }

    /// A drag reorder dropped at a row slot (the column and the inspector share `LayerReorder.drop`). False when
    /// the slot refuses (the base, a group into a group, an order lock): the cell shakes back.
    @discardableResult
    func moveLayer(_ id: UUID, toSlot slot: Int) -> Bool {
        guard let placement = LayerReorder.drop(id, atRowSlot: slot, in: document) else {
            Haptics.warning()
            return false
        }
        guard applyStructureEdit(.move(id, to: placement), label: "Reorder Layers") != nil else { return false }
        Haptics.confirm()
        return true
    }

    /// VoiceOver's « Monter » / « Descendre »: one row up or down.
    func moveLayerStep(_ id: UUID, up: Bool) {
        let rows = visibleLayerRows
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let slot = up ? index - 1 : index + 2
        guard slot >= 0, slot <= rows.count else { return }
        moveLayer(id, toSlot: slot)
    }

    /// Masquer from the multi-selection bar: every chosen layer hidden in one step.
    func hideLayers(_ ids: [UUID]) {
        applyLayerEdits(ids.map { (LayerEdit.visible(false), $0) }, label: "Hide Layer")
    }

    /// Aligner ▸ (D10): one layer to the canvas, several to their union box; distribute keeps the outer two;
    /// position-locked layers are skipped and named in a toast.
    func alignLayers(_ ids: [UUID], _ alignment: LayerAlignment) {
        let canvas = document.canvasSize
        var boxes: [UUID: PSRect] = [:]
        var skipped: [String] = []
        for id in ids {
            guard let layer = document.layer(id: id), id != document.baseLayerID, let size = layerContentSize(id) else { continue }
            guard LayerLockPolicy.allows(.placement, on: id, in: document) else {
                skipped.append(LayerAccessibility.displayName(layer, language: layerLanguage))
                continue
            }
            boxes[id] = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: canvas, isBase: false)
        }
        let moves = LayerPlacement.alignment(alignment, boxes: boxes, canvas: boxes.count == 1)
        var updated = document
        for (id, delta) in moves where abs(delta.x) > 1e-9 || abs(delta.y) > 1e-9 {
            guard let layer = updated.layer(id: id) else { continue }
            updated.applyLayerEdit(.transform(Self.translated(LayerPlacement.effectiveTransform(of: layer), by: delta)), to: id)
        }
        if updated != document {
            commit(updated, label: "Align Layers")
            Haptics.confirm()
        }
        if !skipped.isEmpty {
            showToast(String(format: L("Not moved (position locked): %@"), skipped.joined(separator: ", ")))
        }
    }

    /// A transform moved by a canvas-normalised delta (the quad's corners too).
    static func translated(_ transform: LayerTransform, by delta: PSPoint) -> LayerTransform {
        var moved = transform
        moved.center = PSPoint(x: transform.center.x + delta.x, y: transform.center.y + delta.y)
        if let quad = transform.quad { moved.quad = quad.map { PSPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
        return moved
    }

    // MARK: - New layers

    /// Calque de remplissage ▸ Couleur unie or Dégradé, above the selected layer, selected (its panel opens).
    func addFillLayer(gradient: Bool) {
        guard !gradient || proLayersEnabled else { return }
        let french = psPrefersFrench
        let count = document.layers.filter(\.isFill).count + 1
        let name = gradient ? (french ? "Dégradé \(count)" : "Gradient \(count)") : (french ? "Couleur unie \(count)" : "Colour fill \(count)")
        let content: Layer.Content = gradient ? .gradientFill(.blackToTransparent) : .fill(.white)
        guard applyStructureEdit(.add(Layer(name: name, content: content), placement: .aboveSelected), label: "Fill Layer") != nil else { return }
        Haptics.confirm()
    }

    /// Calque de réglage ▸ <kind>: an empty recipe of that kind above the selected layer, selected (D9). A LUT layer
    /// starts from the LUT imported on the active image layer.
    func addAdjustmentLayer(_ kind: AdjustmentLayerKind) {
        let french = psPrefersFrench
        let count = document.layers.filter { $0.isAdjustment && ($0.recipeKind ?? .light) == kind }.count + 1
        let name = "\(french ? kind.frenchName : kind.englishName) \(count)"
        var edits = EditStack()
        if kind == .lut {
            let imported = document.activeImageLayerID.flatMap { document.layer(id: $0)?.edits.resolvedLUT }
            guard var reference = imported else {
                showToast(L("Import a LUT in Colour first."), isError: true)
                return
            }
            reference.intensity = 1
            edits.setColor(.lut(reference))
        }
        let layer = Layer(name: name, content: .adjustment(.neutral), edits: edits, recipeKind: kind)
        guard applyStructureEdit(.add(layer, placement: .aboveSelected), label: "Adjustment Layer") != nil else { return }
        Haptics.confirm()
    }

    /// Whether a LUT layer can start (an imported LUT on the active image layer).
    var canAddLUTLayer: Bool { document.activeLayerHasLUT }

    /// Photo… in the ＋ menu, and the `pickImageLayer` effect.
    func openImageLayerPicker() {
        if activeTool != .layers { activeTool = .layers }
        layerState.showsImagePicker = true
    }

    /// A photo picked for a new layer: decoded, downsized and written off the main actor, then added above the selected
    /// layer at 80 % of the canvas's shorter side, selected, transform mode on it (§7.8).
    func addImageLayer(data: Data, localIdentifier: String?) async {
        guard !isProcessing else { return }
        let store = app.store
        let projectID = projectID
        isProcessing = true
        processingTitle = L("Adding the photo…")
        defer { isProcessing = false }
        do {
            let asset = try await Task.detached(priority: .userInitiated) {
                try ImageLayerImporter.importImage(data, store: store, projectID: projectID, localIdentifier: localIdentifier)
            }.value
            let name = "Photo \(document.imageLayers.count + 1)"
            guard let id = applyStructureEdit(.addImage(asset, name: name, fit: .fit, placement: .aboveSelected), label: "Add Photo Layer") else { return }
            Haptics.success()
            if FeatureFlags.isOn(.freeTransform) { beginTransformMode(id) }
        } catch {
            Haptics.error()
            showToast((error as? PicshopError)?.message ?? L("That picture couldn't be read."), isError: true)
        }
    }

    // MARK: - Layer via copy and via cut (D8, D17)

    /// Where a layer via copy or cut takes its region.
    enum ViaSource: Equatable {
        case selection
        case subject
        /// A local adjustment's mask (« Masque a1 »).
        case mask(UUID)
    }

    /// « Calque par copier » / « Calque par couper » from the selection, the subject or a mask, on the active image
    /// layer: the region mapped into that layer's content space, then one structure edit (one step).
    func layerVia(cut: Bool, from source: ViaSource) {
        guard proLayersEnabled, let sourceID = document.activeImageLayerID, let layer = document.layer(id: sourceID) else { return }
        if cut, !layerAllows(.mask, on: sourceID) { return }
        let label = cut ? "Layer via Cut" : "Layer via Copy"
        switch source {
        case .selection:
            guard let selection = document.selection else {
                showToast(L("Make a selection first, in Selection."), isError: true)
                return
            }
            let region = MaskStack.single(MaskComponent(.raster(selection.raster)))
            guard let mapped = contentSpace(region, of: layer) else { return }
            finishVia(cut: cut, source: sourceID, region: mapped, name: viaName(layer, region: psPrefersFrench ? "Sélection" : "Selection"), label: label)
        case .mask(let adjustmentID):
            guard let found = localAdjustmentOwner(adjustmentID) else { return }
            let stack = found.adjustment.stack
            var mapped: MaskStack?
            if found.ownerID == sourceID {
                mapped = stack
            } else if let owner = document.layer(id: found.ownerID), let canvas = canvasSpace(stack, of: owner) {
                mapped = contentSpace(canvas, of: layer)
            }
            guard let mapped else { return }
            let regionName = MaskAccessibility.displayName(for: found.adjustment, language: layerLanguage)
            finishVia(cut: cut, source: sourceID, region: mapped, name: viaName(layer, region: regionName), label: label)
        case .subject:
            guard let services, !isProcessing else { return }
            isProcessing = true
            processingTitle = L("Finding the subject…")
            let base = document
            Task { [weak self] in
                do {
                    let result = try await services.aiMask(.subject, in: base, layer: sourceID)
                    guard let self else { return }
                    self.isProcessing = false
                    let region = MaskStack.single(MaskComponent(.raster(result.raster)))
                    let name = self.viaName(layer, region: psPrefersFrench ? "Sujet" : "Subject")
                    self.finishVia(cut: cut, source: sourceID, region: region, name: name, label: label)
                } catch {
                    guard let self else { return }
                    self.isProcessing = false
                    self.handleMaskError(error, region: .subject)
                }
            }
        }
    }

    private func finishVia(cut: Bool, source: UUID, region: MaskStack, name: String, label: String) {
        let edit: LayerStructureEdit = cut ? .viaCut(source: source, region: region, name: name) : .viaCopy(source: source, region: region, name: name)
        guard applyStructureEdit(edit, label: label, refusalLayer: source) != nil else { return }
        Haptics.success()
    }

    /// « Tasse · Sélection » (D17).
    private func viaName(_ layer: Layer, region: String) -> String {
        let source = LayerAccessibility.displayName(layer, isBase: layer.id == document.baseLayerID, language: layerLanguage)
        return "\(source) · \(region)"
    }

    /// The local adjustment with that id and the image layer it belongs to.
    func localAdjustmentOwner(_ id: UUID) -> (ownerID: UUID, adjustment: LocalAdjustment)? {
        for layer in document.imageLayers {
            if let adjustment = document.localAdjustments(on: layer.id).first(where: { $0.id == id }) { return (layer.id, adjustment) }
        }
        return nil
    }

    /// A canvas-space stack in a layer's content space (D8): the base's content space is the canvas; another layer's
    /// is reached through its inverse placement map. Nil (and said) when the placement is degenerate.
    func contentSpace(_ stack: MaskStack, of layer: Layer) -> MaskStack? {
        guard layer.id != document.baseLayerID else { return stack }
        guard let size = layerContentSize(layer.id), size.width > 0, size.height > 0,
              let inverse = LayerPlacement.inverseMap(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false) else {
            refuseLayerEdit(.notApplicable, layerID: layer.id)
            return nil
        }
        return stack.remapped(by: inverse, aspectBefore: Self.aspect(document.canvasSize), aspectAfter: Self.aspect(size))
    }

    /// A stack in a layer's content space, in canvas space.
    func canvasSpace(_ stack: MaskStack, of layer: Layer) -> MaskStack? {
        guard layer.id != document.baseLayerID else { return stack }
        guard let size = layerContentSize(layer.id), size.width > 0, size.height > 0 else { return nil }
        let map = LayerPlacement.map(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        return stack.remapped(by: map, aspectBefore: Self.aspect(size), aspectAfter: Self.aspect(document.canvasSize))
    }

    /// w/h, square when degenerate.
    static func aspect(_ size: PSSize) -> Double {
        let ratio = size.width / max(1e-9, size.height)
        return ratio.isFinite && ratio > 0 ? ratio : 1
    }

    // MARK: - Merges, stamp, flatten, apply mask (rasterised by the services, D17)

    /// Fusionner avec le calque inférieur (X onto the layer below it, same parent).
    func mergeDown(_ id: UUID) {
        guard proLayersEnabled else { return }
        guard let below = Self.layerBelow(id, in: document) else {
            refuseLayerEdit(.notApplicable, layerID: id)
            return
        }
        rasterizeThenEdit(title: L("Merging the layers…"), label: "Merge Down", request: .layers([below, id]), involved: [below, id]) { result in
            .mergeDown(id, raster: result.asset)
        }
    }

    /// The layer a merge down lands on: the nearest one below with the same parent (D17).
    static func layerBelow(_ id: UUID, in document: PhotoDocument) -> UUID? {
        guard let index = document.index(of: id) else { return nil }
        let parent = document.layers[index].parentID
        var below = index - 1
        while below >= 0 {
            let candidate = document.layers[below]
            if candidate.parentID == parent, candidate.id != parent { return candidate.id }
            below -= 1
        }
        return nil
    }

    /// Fusionner from the multi-selection: one layer at the topmost one's place.
    func mergeSelectedLayers(_ ids: [UUID]) {
        guard proLayersEnabled, ids.count >= 2 else { return }
        rasterizeThenEdit(title: L("Merging the layers…"), label: "Merge Layers", request: .merged(ids), involved: ids) { result in
            .mergeLayers(ids, raster: result.asset)
        }
    }

    /// Fusionner les calques visibles: into the base, hidden layers kept.
    func mergeVisible() {
        guard proLayersEnabled else { return }
        rasterizeThenEdit(title: L("Merging the layers…"), label: "Merge Visible", request: .visible, involved: document.layers.map(\.id)) { result in
            .mergeVisible(raster: result.asset)
        }
    }

    /// Aplatir l'image: asks first when hidden layers would go.
    func requestFlatten() {
        guard proLayersEnabled else { return }
        if document.layers.contains(where: { !$0.isVisible }) {
            layerState.confirmation = .flatten
        } else {
            flatten()
        }
    }

    func flatten() {
        rasterizeThenEdit(title: L("Flattening…"), label: "Flatten Image", request: .visible, involved: document.layers.map(\.id)) { result in
            .flatten(raster: result.asset)
        }
    }

    /// Tampon des calques visibles: a new layer on top with the visible composite.
    func stampVisible() {
        guard proLayersEnabled else { return }
        let name = psPrefersFrench ? "Tampon" : "Stamp"
        rasterizeThenEdit(title: L("Merging the layers…"), label: "Stamp Visible", request: .visible, involved: document.layers.map(\.id)) { result in
            .stamp(raster: result.asset, name: name)
        }
    }

    /// « Appliquer » le masque: the layer rasterised with its mask becomes its content (image layers only, D8).
    func applyLayerMask(_ id: UUID) {
        guard let layer = document.layer(id: id), layer.isImage, layerAllows(.alpha, on: id) else { return }
        rasterizeThenEdit(title: L("Applying the mask…"), label: "Apply Mask", request: .layers([id]), involved: [id]) { result in
            .applyMask(id, raster: result.asset)
        }
    }

    /// The services render the request (strips, the broker first), then the structure edit lands as one step on the
    /// document as it is now, as long as the layers it involves did not change meanwhile. A trial with a stand-in
    /// asset refuses first what the edit would refuse, so nothing is rendered for a refused merge.
    private func rasterizeThenEdit(title: String, label: String, request: LayerRasterRequest, involved: [UUID],
                                   edit: @escaping (LayerRasterResult) -> LayerStructureEdit) {
        guard let services else { return }
        guard !isProcessing else {
            showToast(L("One moment…"))
            return
        }
        if interaction != nil { endInteraction() }
        let stand = LayerRasterResult(asset: MediaAsset(kind: .image, relativePath: "media/trial.png", pixelSize: document.canvasSize),
                                      opaqueBounds: PSRect(x: 0, y: 0, width: 1, height: 1))
        var trial = document
        if case .refused(let refusal) = trial.applyStructureEdit(edit(stand)).outcome {
            refuseLayerEdit(refusal, layerID: involved.last)
            return
        }
        let base = document
        isProcessing = true
        processingTitle = title
        layerState.workingTitle = title
        Task { [weak self] in
            let result: Result<LayerRasterResult, Error>
            do {
                result = .success(try await services.rasterizeLayers(request, in: base))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.isProcessing = false
            self.layerState.workingTitle = nil
            switch result {
            case .failure(let error):
                Haptics.error()
                self.showToast((error as? PicshopError)?.message ?? error.localizedDescription, isError: true)
            case .success(let raster):
                // The layers it merged must still be the ones it rendered.
                guard involved.allSatisfy({ base.layer(id: $0) == self.document.layer(id: $0) }) else {
                    Haptics.warning()
                    self.showToast(L("The photo changed in the meantime. Try again."), isError: true)
                    return
                }
                guard self.applyStructureEdit(edit(raster), label: label, rasterBounds: raster.opaqueBounds) != nil else { return }
                Haptics.success()
            }
        }
    }

    // MARK: - Layer masks (LayerMaskControls; the brush is in +Masks)

    /// How « Ajouter un masque » starts.
    enum LayerMaskStart: Equatable { case revealAll, hideAll, selection, subject }

    /// Ajouter (Tout afficher / Tout masquer / Depuis la sélection / Depuis le sujet): one step. « Tout afficher » is an
    /// empty brush that hides (a first subtract component starts from everything), « Tout masquer » an empty brush
    /// that reveals: the layer-mask brush paints into them.
    func addLayerMask(_ start: LayerMaskStart, to id: UUID) {
        guard proLayersEnabled, let layer = document.layer(id: id), layerAllows(.mask, on: id) else { return }
        switch start {
        case .revealAll:
            setLayerMask(MaskStack(components: [MaskComponent(.brush(BrushSpec()), mode: .subtract)]), on: id)
        case .hideAll:
            setLayerMask(MaskStack(components: [MaskComponent(.brush(BrushSpec()), mode: .add)]), on: id)
        case .selection:
            guard let selection = document.selection else {
                showToast(L("Make a selection first, in Selection."), isError: true)
                return
            }
            let region = MaskStack.single(MaskComponent(.raster(selection.raster)))
            let mapped = layer.isMaskLinked ? contentSpace(region, of: layer) : region
            guard let mapped else { return }
            setLayerMask(mapped, on: id)
        case .subject:
            guard let services, !isProcessing else { return }
            isProcessing = true
            processingTitle = L("Finding the subject…")
            let base = document
            Task { [weak self] in
                do {
                    let result = try await services.aiMask(.subject, in: base, layer: id)
                    guard let self else { return }
                    self.isProcessing = false
                    var stack = MaskStack.single(MaskComponent(.raster(result.raster)))
                    // An unlinked mask lives on the canvas (D8).
                    if let owner = self.document.layer(id: id), !owner.isMaskLinked, let canvas = self.canvasSpace(stack, of: owner) {
                        stack = canvas
                    }
                    self.setLayerMask(stack, on: id)
                } catch {
                    guard let self else { return }
                    self.isProcessing = false
                    self.handleMaskError(error, region: .subject)
                }
            }
        }
    }

    private func setLayerMask(_ stack: MaskStack, on id: UUID) {
        guard applyLayerEdit(.maskStack(stack), to: id, label: "Layer Mask") else { return }
        layerState.maskControlsOf = id
        Haptics.confirm()
    }

    /// Inverser: the whole stack inverted (one step).
    func invertLayerMask(_ id: UUID) {
        guard var stack = layerMaskStack(id) else { return }
        stack.isInverted.toggle()
        applyLayerEdit(.maskStack(stack), to: id, label: "Layer Mask")
    }

    /// Désactiver / Activer.
    func setLayerMaskEnabled(_ enabled: Bool, layerID: UUID) {
        applyLayerEdit(.maskEnabled(enabled), to: layerID, label: "Layer Mask")
        Haptics.tick()
    }

    /// Lié: the stack re-expressed in the other space so nothing moves (D8).
    func setLayerMaskLinked(_ linked: Bool, layerID: UUID) {
        applyLayerEdit(.maskLinked(linked), to: layerID, label: "Layer Mask")
        Haptics.tick()
    }

    func deleteLayerMask(_ id: UUID) {
        guard applyLayerEdit(.maskStack(nil), to: id, label: "Layer Mask") else { return }
        if layerState.maskControlsOf == id { layerState.maskControlsOf = nil }
        if layerState.editingMaskOf == id { endLayerMaskPaint() }
        Haptics.warning()
    }

    /// The layer's stack, the legacy mask converted (D8): what the sliders edit.
    func layerMaskStack(_ id: UUID) -> MaskStack? {
        guard let layer = document.layer(id: id) else { return nil }
        if let stack = layer.maskStack { return stack }
        return layer.mask.map { MaskStack(legacy: $0) }
    }

    /// Contour progressif, Densité, Étendre: a slider drag on the mask (the `.layerMask` snapshot), one step.
    @discardableResult
    func beginLayerMaskSlider(_ id: UUID) -> Bool {
        guard layerAllows(.mask, on: id) else { return false }
        beginInteraction(label: "Layer Mask", scope: .layerMask(id))
        return true
    }

    func setLayerMaskStack(feather: Double? = nil, density: Double? = nil, expand: Double? = nil, layerID: UUID) {
        guard var stack = layerMaskStack(layerID) else { return }
        if let feather { stack.feather = feather.clamped(to: 0...1) }
        if let density { stack.density = density.clamped(to: 0...1) }
        if let expand { stack.expand = expand.clamped(to: -1...1) }
        let edited = stack
        interactiveEdit(label: "Layer Mask") { document in
            document.applyLayerEdit(.maskStack(edited), to: layerID)
        }
    }

    // MARK: - Canvas taps (tap-to-pick, §7.4)

    /// A tap with Calques open: in transform mode outside the quad, transform mode ends; in select mode, the topmost
    /// visible layer whose placed alpha is above 0.1 there is selected. True when the tap was used.
    func handleLayerTap(at point: PSPoint) -> Bool {
        switch layerState.mode {
        case .transform:
            let quad = layerState.liveQuad
            if !quad.isEmpty, !Self.contains(quad, point) {
                endTransformMode()
                return true
            }
            return false
        case .maskPaint:
            return true
        case .select:
            Task { [weak self] in
                guard let self, let id = await self.layer(at: point) else { return }
                if self.layerState.isSelecting {
                    self.toggleMultiSelection(id)
                } else if self.document.selectedLayerID != id {
                    Haptics.tick()
                    self.selectLayer(id)
                }
            }
            return true
        }
    }

    /// A long press with Calques open: every layer under the finger, top first, for the pick menu.
    func pickMenu(at point: PSPoint) {
        Task { [weak self] in
            guard let self else { return }
            let ids = await self.layers(at: point, all: true)
            guard !ids.isEmpty else { return }
            Haptics.soft()
            self.layerState.pickChoices = ids
        }
    }

    /// The topmost visible layer under `point` whose placed alpha is above 0.1.
    func layer(at point: PSPoint) async -> UUID? {
        await layers(at: point, all: false).first
    }

    /// Visible layers under `point`, top first: a bounds pre-check, then the alpha of each candidate's thumbnail (the
    /// layer alone on the canvas, cached by the renderer), read off the main actor. Groups are seen through their
    /// children, adjustment layers have no pixels of their own, the base takes what is left.
    func layers(at point: PSPoint, all: Bool) async -> [UUID] {
        let document = self.document
        let canvas = document.canvasSize
        var candidates: [UUID] = []
        for id in CompositePlan.make(document).flatMap(\.layerIDs).reversed() {
            guard let layer = document.layer(id: id), !layer.isGroup, !layer.isAdjustment, layer.id != document.baseLayerID else { continue }
            if let size = Self.contentSize(of: layer, canvasSize: canvas) {
                let bounds = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: canvas, isBase: false)
                guard bounds.insetBy(dx: -0.01, dy: -0.01).contains(point) else { continue }
            }
            candidates.append(layer.id)
        }
        var hits: [UUID] = []
        if let renderer {
            for id in candidates {
                guard let image = try? await renderer.layerThumbnail(id, in: document, side: 88) else { continue }
                let alpha = await Task.detached(priority: .userInitiated) { Self.alpha(of: image, at: point) }.value
                if alpha > 0.1 {
                    hits.append(id)
                    if !all { return hits }
                }
            }
        }
        if let base = document.baseLayerID, all || hits.isEmpty { hits.append(base) }
        return hits
    }

    /// The alpha (0…1) of a thumbnail at a canvas-normalised point: the thumbnail is the canvas fitted in the image.
    nonisolated static func alpha(of image: CGImage, at point: PSPoint) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        let x = min(width - 1, max(0, Int(point.x * Double(width))))
        let y = min(height - 1, max(0, Int(point.y * Double(height))))
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Core Graphics is bottom-up: the wanted pixel lands on the 1 × 1 context's only pixel.
            context.draw(image, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
            return true
        }
        return drawn ? Double(pixel[3]) / 255 : 0
    }

    /// A point in a quad (even-odd).
    static func contains(_ quad: [PSPoint], _ point: PSPoint) -> Bool {
        guard quad.count >= 3 else { return false }
        var inside = false
        var j = quad.count - 1
        for i in 0..<quad.count {
            let a = quad[i], b = quad[j]
            if (a.y > point.y) != (b.y > point.y) {
                let crossing = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Lifecycle

    /// Calques opened or closed: its modes end with it, and the mirrors catch up when it opens.
    func layersToolDidChange(from previous: Tool?) {
        if previous == .layers, activeTool != .layers {
            if layerState.mode == .transform { endTransformMode() }
            if layerState.mode == .maskPaint { endLayerMaskPaint() }
            if layerState.isSelecting { setSelecting(false) }
            layerState.maskControlsOf = nil
            releaseKeptInteractionSnapshot()
        }
        if activeTool == .layers { refreshLayerThumbnails() }
    }

    /// The editor closes: unreferenced media and masks older than 24 h go (D17), off the main actor, with the current
    /// document and every undo and redo state as the references.
    func layersTeardown() {
        layerState.thumbnails.task?.cancel()
        layerState.maskFlattenTask?.cancel()
        dropInteractionSnapshot()
        clearDetail()
        // The last export's temporary file (a PDF or PSD not taken by Files) goes with the editor (D16).
        discardExportedFile()
        var keeping = document.referencedPaths
        for entry in history.past + history.future { keeping.formUnion(entry.state.referencedPaths) }
        let store = app.store
        let projectID = projectID
        let paths = keeping
        Task.detached(priority: .utility) {
            do {
                let removed = try store.collectGarbage(projectID: projectID, keeping: paths)
                if removed.files > 0 { PSLog.info("project storage: \(removed.files) files, \(removed.bytes) bytes freed", category: .ui) }
            } catch {
                PSLog.error("project storage sweep failed: \(error)", category: .ui)
            }
        }
    }

    /// Where the document came from (D2): a newer build's file shows its toast; an older build's save, merged back,
    /// is saved at once so both files are rewritten.
    func documentDidLoad(from source: DocumentCodec.LoadSource?) {
        switch source {
        case .newerFormat?:
            showToast(L("Project from a newer version: some edits are not shown."), isError: true)
        case .merged?:
            Diagnostics.shared.note("document merged from an older build's save")
            forceAutosave()
        case .v1?, .v2?, nil:
            break
        }
    }

    /// The baked layer masks (D8, "should"): after an autosave, each changed stack is baked off the main actor and
    /// stored in `Layer.bakedMask` without a new step, when the layer's stack is still the one baked.
    func bakeLayerMasksAfterSave(_ saved: PhotoDocument) {
        guard saved.layers.contains(where: { $0.maskStack != nil && !LayerMaskBaker.isFresh($0) }) else { return }
        let store = app.store
        let projectID = projectID
        Task { [weak self] in
            let baked = await LayerMaskBaker.bake(saved, store: store, projectID: projectID)
            guard let self, !baked.isEmpty else { return }
            var updated = self.document
            var changed = false
            for (id, reference) in baked {
                guard let layer = updated.layer(id: id), layer.maskStack == saved.layer(id: id)?.maskStack, layer.bakedMask != reference else { continue }
                updated.update(layerID: id) { $0.bakedMask = reference }
                changed = true
            }
            if changed { self.amendPresent(updated) }
        }
    }
}
#endif
