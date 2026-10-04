#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreImage
import MetalKit
import PicshopCore
import PicshopIntent
import PicshopImaging

// Masques (W2, M3): local adjustments through masks on the base layer, Lightroom-style.
//
// Every change to a local adjustment goes through `PhotoDocument.applyLocalEdit(_:to:)` (M1), the function the voice
// handlers use too, so the panel and the voice make the same document; creation goes through
// `setLocalAdjustment`. Drags (a dial, a handle, the brush, a range thumb) use the W1 drag hooks:
// beginInteraction → interactiveEdit → endInteraction, one undo step per drag. History labels are the English key
// "Masks" (« Masques »).
//
// The overlay (D17) is never baked into the preview: the frame and its overlay come from one render
// (`renderFrameAndOverlay`), interactive frames hand it to the canvas with the same generation, settled ones publish
// it in `maskState.overlayImage`.
extension PhotoEditorSession {
    static let masksLabel = "Masks"

    // MARK: - State

    var masksEnabled: Bool { FeatureFlags.isOn(.masks) }

    /// The local adjustment under the finger: the renderer freezes the other masks for the drag (D6).
    var maskInteractionTarget: UUID? {
        get { maskState.interactionTarget }
        set { maskState.interactionTarget = newValue }
    }

    /// The interface's language for mask names.
    var maskNameLanguage: OpLanguage { psPrefersFrench ? .fr : .en }

    func mask(_ id: UUID) -> LocalAdjustment? {
        document.localAdjustments.first { $0.id == id }
    }

    var selectedMask: LocalAdjustment? { maskState.selected(in: document) }

    /// The name the list shows (« Ciel », « Ciel 2 »).
    func maskName(_ adjustment: LocalAdjustment) -> String {
        let all = document.localAdjustments
        let names = MaskAccessibility.displayNames(for: all, language: maskNameLanguage)
        if let index = all.firstIndex(where: { $0.id == adjustment.id }) { return names[index] }
        return MaskAccessibility.displayName(for: adjustment, language: maskNameLanguage)
    }

    /// W3: masks act on the active image layer (`localAdjustmentsLayerID`), the selected one when it is an image
    /// layer. The panel names it when it is not the background photo (« Sur : Tasse »); nil on the base.
    var masksTargetName: String? {
        guard let id = document.localAdjustmentsLayerID, id != document.baseLayerID, let layer = document.layer(id: id) else { return nil }
        return LayerAccessibility.displayName(layer, isBase: false, language: maskNameLanguage)
    }

    /// The aspect (w/h) mask coordinates live in: the target layer's output after its geometry, from its asset (D3).
    var maskAspect: Double { document.localAdjustmentsAspect }

    /// Canvas → the target layer's mask space (W3): the base's masks live on the canvas, another image layer's in its
    /// content space, reached through the inverse placement map (D8). Nil on the base, or when the placement is
    /// degenerate.
    func maskSpaceMap() -> PSHomography? {
        guard let id = document.localAdjustmentsLayerID, id != document.baseLayerID, let layer = document.layer(id: id),
              let size = layerContentSize(id), size.width > 0, size.height > 0 else { return nil }
        return LayerPlacement.inverseMap(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
    }

    /// A canvas point in the target layer's mask space (identity on the base).
    func maskSpacePoint(_ point: PSPoint) -> PSPoint {
        maskSpaceMap()?.apply(point) ?? point
    }

    /// Where the target layer's mask space lies on screen, for the handles: the picture's frame on the base, the
    /// layer's placed bounds on another layer (exact for an upright layer; a turned one is drawn on its bounds).
    func maskPlacementFrame(in imageFrame: CGRect) -> CGRect {
        guard let id = document.localAdjustmentsLayerID, id != document.baseLayerID, let layer = document.layer(id: id),
              let size = layerContentSize(id) else { return imageFrame }
        let bounds = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        guard bounds.width > 0, bounds.height > 0 else { return imageFrame }
        return CGRect(x: imageFrame.minX + bounds.minX * imageFrame.width, y: imageFrame.minY + bounds.minY * imageFrame.height,
                      width: bounds.width * imageFrame.width, height: bounds.height * imageFrame.height)
    }

    var canAddMask: Bool { document.localAdjustments.count < LocalAdjustment.maxPerLayer }

    /// An AI raster made for another state of the picture (an erase, a crop): « Mettre à jour » redoes it.
    func isStale(_ adjustment: LocalAdjustment) -> Bool {
        // W3: a layer's masks were made on its own pixels (its content space): its own state, not the photo's.
        let key = document.maskStateKey(on: document.localAdjustmentOwner(of: adjustment.id) ?? document.localAdjustmentsLayerID)
        return adjustment.stack.components.contains { component in
            guard case .raster(let raster) = component.kind, let stateKey = raster.stateKey, Self.request(for: raster) != nil else { return false }
            return stateKey != key
        }
    }

    // MARK: - Creating masks

    /// « Nouveau masque » and the empty state's tiles. AI regions run through the services with the progress row;
    /// parametric ones (gradients, ranges) are made at once, the same component the voice makes for that region;
    /// near and far read the depth map; « Depuis la sélection » takes the selection's raster.
    func addMask(_ region: MaskRegion, person: Int? = nil) {
        guard masksEnabled, document.localAdjustmentsLayerID != nil else { return }
        guard canAddMask else {
            tellMaskProblem(L("There are already 16 masks: delete one first."))
            return
        }
        switch region {
        case .object:
            beginObjectPick(mode: nil)
            return
        case .selection:
            addSelectionComponent(to: nil, mode: .add)
            return
        case .near, .far:
            addDepthRange(region, to: nil, mode: .add)
            return
        case .color:
            openColorRange(for: .newMask)
            return
        default:
            break
        }
        if let component = MaskStack.defaultComponent(for: region, aspect: maskAspect) {
            createMask(LocalAdjustment(region: region, stack: .single(component)), editing: Self.editing(for: component))
            Haptics.tick()
            return
        }
        guard let request = Self.request(for: region, person: person) else { return }
        runAIMask(region, request: request, label: Self.label(for: region, person: person), into: nil)
    }

    /// « Pinceau »: the next strokes paint a new mask (made by the first one).
    func beginBrushMask() {
        guard masksEnabled else { return }
        maskState.brushTarget = .newMask
        maskState.editing = .brush(nil)
        maskState.selectedID = nil
        Haptics.tick()
    }

    /// « Objet (toucher ou cadrer) »: the next tap or frame on the canvas picks the object.
    func beginObjectPick(mode: CombineMode?) {
        maskState.editing = .object(mode)
        maskState.caption = L("Tap the object, or draw a frame around it.")
        Haptics.tick()
    }

    /// One new local adjustment, one undo step; it becomes the selected mask and its tint flashes.
    func createMask(_ adjustment: LocalAdjustment, editing: PhotoMaskState.EditingComponent?) {
        guard canAddMask else {
            tellMaskProblem(L("There are already 16 masks: delete one first."))
            return
        }
        var updated = document
        updated.setLocalAdjustment(adjustment, label: Self.masksLabel)
        guard updated != document else { return }
        commit(updated, label: Self.masksLabel)
        maskState.selectedID = adjustment.id
        maskState.editing = editing
        flashMask(adjustment.id)
    }

    /// The editing mode a new component opens in: handles for gradients, the range editor for ranges.
    static func editing(for component: MaskComponent) -> PhotoMaskState.EditingComponent? {
        switch component.kind {
        case .linear, .radial: return .handles(component.id)
        case .luminanceRange, .depthRange: return .range(component.id)
        case .brush: return .brush(component.id)
        case .raster, .colorRange, .unsupported: return nil
        }
    }

    /// The AI request for a region (person i and people parts with their person number).
    static func request(for region: MaskRegion, person: Int? = nil) -> AIMaskRequest? {
        switch region {
        case .subject: return .subject
        case .background: return .background
        case .sky: return .sky
        case .people: return .people
        case .vegetation: return .vegetation
        case .water: return .water
        case .person: return .person(index: max(1, person ?? 1))
        case .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin: return .personPart(region, person: person)
        default: return nil
        }
    }

    /// The label a region's adjustment carries: the person number, or "teeth:2" for a person's part.
    static func label(for region: MaskRegion, person: Int?) -> String? {
        switch region {
        case .person: return "\(max(1, person ?? 1))"
        case .face, .faceSkin, .eyes, .lips, .teeth: return person.map { "\(region.rawValue):\($0)" }
        default: return nil
        }
    }

    /// The request that makes a raster again for the picture as it is now (« Mettre à jour »); nil for rasters
    /// that are not AI masks (brush, selection, imported).
    static func request(for raster: RasterRef) -> AIMaskRequest? {
        switch raster.origin {
        case .subject: return .subject
        case .background: return .background
        case .people: return .people
        case .sky: return .sky
        case .vegetation: return .vegetation
        case .water: return .water
        case .person: return .person(index: Int(raster.label ?? "") ?? 1)
        case .object:
            guard let label = raster.label, !label.isEmpty else { return nil }
            return .object(ObjectTarget(label: label, originalPhrase: label))
        case .facePart, .matte:
            let parts = (raster.label ?? "").split(separator: ":").map(String.init)
            guard let first = parts.first, let region = MaskRegion(rawValue: first) else { return nil }
            return .personPart(region, person: parts.count > 1 ? Int(parts[1]) : nil)
        case .depth, .selection, .brush, .imported:
            return nil
        }
    }

    /// Runs an AI mask with the placeholder row (shown at once, cancellable), then makes a new mask of it or adds it
    /// to `target` as a component. Coverage under 0.2 % changes nothing and says so; a missing model offers it.
    func runAIMask(_ region: MaskRegion, request: AIMaskRequest, label: String?, into target: (adjustmentID: UUID, mode: CombineMode)?) {
        guard let services else { return }
        maskState.aiTask?.cancel()
        let working = PhotoMaskState.Working(region: region)
        maskState.aiWorking = working
        maskState.caption = nil
        let document = self.document
        // W3: on a non-base image layer the providers read that layer's own pixels, in its content space.
        let owner = document.localAdjustmentsLayerID
        maskState.aiTask = Task { [weak self] in
            do {
                let result = try await services.aiMask(request, in: document, layer: owner)
                guard let self, !Task.isCancelled, self.maskState.aiWorking == working else { return }
                self.maskState.aiWorking = nil
                guard result.coverage >= 0.002 else {
                    self.tellMaskProblem(Self.notFoundMessage(region))
                    return
                }
                let component = MaskComponent(.raster(result.raster), mode: target?.mode ?? .add)
                if let target {
                    self.editMask(.addComponent(component), on: target.adjustmentID)
                    self.flashMask(target.adjustmentID)
                } else {
                    self.createMask(LocalAdjustment(region: region, label: label ?? result.raster.label, stack: .single(component)), editing: nil)
                }
                if result.isApproximate || (!result.usedModel && (region == .object)) {
                    self.maskState.caption = region == .sky ? L("Approximate sky: refine it with the brush.") : L("Approximate mask: refine it with the brush.")
                }
                Haptics.magic()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.maskState.aiWorking == working else { return }
                self.maskState.aiWorking = nil
                self.handleMaskError(error, region: region)
            }
        }
    }

    /// The ✕ of the placeholder row.
    func cancelAIMask() {
        maskState.aiTask?.cancel()
        maskState.aiTask = nil
        maskState.aiWorking = nil
    }

    /// An object picked on the canvas: a tap (SAM point, or the Vision fallback) or a frame (SAM box).
    func pickObject(at point: PSPoint? = nil, in box: PSRect? = nil) {
        guard case .object(let mode)? = maskState.editing else { return }
        maskState.editing = nil
        maskState.caption = nil
        // The prompts are on the canvas; a non-base layer's mask is found in its own content space (W3).
        let map = maskSpaceMap()
        let request: AIMaskRequest
        if let box, box.width > 0.01, box.height > 0.01 {
            request = .box(map.map { Self.mappedBox(box, by: $0) } ?? box.clampedToUnit(), label: nil)
        } else if let point {
            let placed = map.map { m -> PSPoint in
                let p = m.apply(point)
                return PSPoint(x: p.x.clamped(to: 0...1), y: p.y.clamped(to: 0...1))
            } ?? point
            request = .points([MaskPrompt(placed)], label: nil)
        } else {
            return
        }
        let target = mode.flatMap { mode in maskState.selectedID.map { (adjustmentID: $0, mode: mode) } }
        runAIMask(.object, request: request, label: nil, into: target)
    }

    /// A canvas box in another space: the bounding box of its four mapped corners, clamped to the unit square.
    static func mappedBox(_ box: PSRect, by map: PSHomography) -> PSRect {
        let corners = [PSPoint(x: box.minX, y: box.minY), PSPoint(x: box.maxX, y: box.minY), PSPoint(x: box.maxX, y: box.maxY),
                       PSPoint(x: box.minX, y: box.maxY)].map(map.apply)
        let minX = corners.map(\.x).min()!.clamped(to: 0...1), maxX = corners.map(\.x).max()!.clamped(to: 0...1)
        let minY = corners.map(\.y).min()!.clamped(to: 0...1), maxY = corners.map(\.y).max()!.clamped(to: 0...1)
        return PSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Near or far from the depth map (camera disparity, else the depth model): a depth range of 0.6…1 or 0…0.35.
    func addDepthRange(_ region: MaskRegion, to adjustmentID: UUID?, mode: CombineMode) {
        guard let services else { return }
        maskState.aiTask?.cancel()
        let working = PhotoMaskState.Working(region: region)
        maskState.aiWorking = working
        let document = self.document
        maskState.aiTask = Task { [weak self] in
            do {
                let depth = try await services.depthMap(in: document)
                guard let self, !Task.isCancelled, self.maskState.aiWorking == working else { return }
                self.maskState.aiWorking = nil
                let spec = region == .far ? DepthRangeSpec(depth: depth, low: 0, high: 0.35) : DepthRangeSpec(depth: depth, low: 0.6, high: 1)
                let component = MaskComponent(.depthRange(spec), mode: mode)
                if let adjustmentID {
                    self.editMask(.addComponent(component), on: adjustmentID)
                    self.maskState.editing = .range(component.id)
                } else {
                    self.createMask(LocalAdjustment(region: region, stack: .single(component)), editing: .range(component.id))
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.maskState.aiWorking == working else { return }
                self.maskState.aiWorking = nil
                self.handleMaskError(error, region: region)
            }
        }
    }

    /// « Depuis la sélection »: the selection's raster (with its corners) as a component.
    func addSelectionComponent(to adjustmentID: UUID?, mode: CombineMode) {
        guard let selection = document.selection else {
            tellMaskProblem(L("Make a selection first, in Selection."))
            return
        }
        let component = MaskComponent(.raster(selection.raster), mode: mode)
        if let adjustmentID {
            editMask(.addComponent(component), on: adjustmentID)
        } else {
            createMask(LocalAdjustment(region: .selection, stack: .single(component)), editing: nil)
        }
    }

    /// A people part from a menu: with several people the face picker asks which (left to right); with one, it is
    /// made at once. `mode` nil makes a new mask, else a part of the selected one.
    func choosePart(_ region: MaskRegion, mode: CombineMode?) {
        let count = max(maskState.suggestions.personCount, maskState.personThumbnails.count)
        if count > 1 {
            maskState.personPickerMode = mode
            maskState.personPickerRegion = region
            return
        }
        makePart(region, person: region == .person ? 1 : nil, mode: mode)
    }

    /// The face picker's choice (1-based, left to right).
    func choosePerson(_ index: Int) {
        guard let region = maskState.personPickerRegion else { return }
        let mode = maskState.personPickerMode
        maskState.personPickerRegion = nil
        maskState.personPickerMode = nil
        makePart(region, person: index, mode: mode)
    }

    private func makePart(_ region: MaskRegion, person: Int?, mode: CombineMode?) {
        if let mode, maskState.selectedID != nil {
            addComponent(region, mode: mode, person: person)
        } else {
            addMask(region, person: person)
        }
    }

    // MARK: - Components

    /// « + Ajouter / − Soustraire / ∩ Intersecter » with a source, on the selected mask.
    func addComponent(_ region: MaskRegion, mode: CombineMode, person: Int? = nil) {
        guard let id = maskState.selectedID, let adjustment = mask(id) else {
            addMask(region, person: person)
            return
        }
        guard adjustment.stack.components.count < MaskStack.maxComponents else {
            tellMaskProblem(L("A mask holds 12 parts at most."))
            return
        }
        switch region {
        case .object:
            beginObjectPick(mode: mode)
        case .selection:
            addSelectionComponent(to: id, mode: mode)
        case .near, .far:
            addDepthRange(region, to: id, mode: mode)
        case .color:
            openColorRange(for: .addToMask(adjustmentID: id, mode: mode))
        default:
            if var component = MaskStack.defaultComponent(for: region, aspect: maskAspect) {
                component.mode = mode
                editMask(.addComponent(component), on: id)
                maskState.editing = Self.editing(for: component)
                flashMask(id)
            } else if let request = Self.request(for: region, person: person) {
                runAIMask(region, request: request, label: Self.label(for: region, person: person), into: (id, mode))
            }
        }
    }

    /// « Pinceau » in the add menus: the next strokes paint a new brush component of the selected mask.
    func addBrushComponent(mode: CombineMode) {
        guard let id = maskState.selectedID else {
            beginBrushMask()
            return
        }
        maskState.brushTarget = .component(adjustmentID: id, componentID: UUID(), mode: mode)
        maskState.brush.erase = false
        maskState.editing = .brush(nil)
        Haptics.tick()
    }

    func removeComponent(_ componentID: UUID) {
        guard let id = maskState.selectedID, let adjustment = mask(id) else { return }
        // The last part goes with its mask, as in Lightroom.
        if adjustment.stack.components.count <= 1 {
            deleteMask(id)
            return
        }
        editMask(.removeComponent(componentID), on: id)
        if maskState.editing.map({ Self.editedComponent($0) == componentID }) == true { maskState.editing = nil }
        Haptics.warning()
    }

    func setComponentMode(_ componentID: UUID, _ mode: CombineMode) {
        guard let id = maskState.selectedID else { return }
        editMask(.setComponentMode(componentID, mode), on: id)
    }

    func invertComponent(_ componentID: UUID, _ inverted: Bool) {
        guard let id = maskState.selectedID else { return }
        editMask(.invertComponent(componentID, inverted), on: id)
    }

    /// Opens a component for editing on the canvas or in the range editor.
    func editComponent(_ component: MaskComponent) {
        switch component.kind {
        case .brush:
            if let id = maskState.selectedID { maskState.brushTarget = .component(adjustmentID: id, componentID: component.id, mode: component.mode) }
            maskState.editing = .brush(component.id)
        case .colorRange(let spec):
            guard let id = maskState.selectedID else { return }
            openColorRange(for: .component(adjustmentID: id, componentID: component.id), spec: spec)
        default:
            maskState.editing = Self.editing(for: component)
        }
        Haptics.tick()
    }

    static func editedComponent(_ editing: PhotoMaskState.EditingComponent) -> UUID? {
        switch editing {
        case .handles(let id), .range(let id): return id
        case .brush(let id): return id
        case .object: return nil
        }
    }

    // MARK: - Edits (one path: applyLocalEdit)

    /// One edit of a local adjustment: during a drag on the dragged copy, else one undo step.
    func editMask(_ edit: LocalAdjustmentEdit, on id: UUID) {
        interactiveEdit(label: Self.masksLabel) { document in
            document.applyLocalEdit(edit, to: id)
        }
    }

    /// A drag on one of the selected mask's controls begins (a dial, the amount, a stack row): one undo step.
    func beginMaskInteraction() {
        guard let id = maskState.selectedID else { return }
        beginInteraction(label: Self.masksLabel)
        maskInteractionTarget = id
    }

    func endMaskInteraction() {
        endInteraction()
    }

    /// A mask dial's drag begins: its ring reads the value under the finger through `dial` (group "mask").
    func beginMaskDial(_ parameter: AdjustmentParameter) {
        beginMaskInteraction()
        setDial(parameter: parameter, group: "mask", value: selectedMask?.adjustments[parameter] ?? 0)
    }

    func setMaskDial(_ parameter: AdjustmentParameter, value: Double) {
        guard let id = maskState.selectedID, parameter != .vignette else { return }
        let clamped = value.clamped(to: parameter.range)
        if interaction != nil { setDial(parameter: parameter, group: "mask", value: clamped) }
        editMask(.setDial(parameter, clamped), on: id)
    }

    func setMaskCurve(_ curve: ToneCurve?) {
        guard let id = maskState.selectedID else { return }
        editMask(.setCurve(curve.flatMap { $0.isIdentity ? nil : $0 }), on: id)
    }

    func setMaskMixer(_ mixer: ColorMixer?) {
        guard let id = maskState.selectedID else { return }
        editMask(.setMixer(mixer.flatMap { $0.isNeutral ? nil : $0 }), on: id)
    }

    /// « Couleur »: one wheel, written to the three ColorGrade wheels.
    func setMaskColor(hue: Double, amount: Double) {
        guard let id = maskState.selectedID else { return }
        let wheel = ColorWheel(hue: hue, amount: amount)
        let grade = wheel.amount > 0.0005 ? ColorGrade(shadows: wheel, midtones: wheel, highlights: wheel) : nil
        editMask(.setGrade(grade), on: id)
    }

    func setMaskAmount(_ amount: Double) {
        guard let id = maskState.selectedID else { return }
        editMask(.setAmount(amount), on: id)
    }

    func setMaskFeather(_ value: Double) {
        guard let id = maskState.selectedID else { return }
        editMask(.setStack(feather: value, expand: nil, density: nil, isInverted: nil), on: id)
    }

    func setMaskExpand(_ value: Double) {
        guard let id = maskState.selectedID else { return }
        editMask(.setStack(feather: nil, expand: value, density: nil, isInverted: nil), on: id)
    }

    func setMaskDensity(_ value: Double) {
        guard let id = maskState.selectedID else { return }
        editMask(.setStack(feather: nil, expand: nil, density: value, isInverted: nil), on: id)
    }

    func toggleMaskVisibility(_ id: UUID) {
        guard let adjustment = mask(id) else { return }
        editMask(.setVisible(!adjustment.isVisible), on: id)
        Haptics.tick()
    }

    func renameMask(_ id: UUID, to name: String) {
        editMask(.rename(name), on: id)
    }

    func duplicateMask(_ id: UUID) {
        guard canAddMask else {
            tellMaskProblem(L("There are already 16 masks: delete one first."))
            return
        }
        var updated = document
        guard updated.applyLocalEdit(.duplicate, to: id) else { return }
        commit(updated, label: Self.masksLabel)
        maskState.selectedID = document.localAdjustments.last?.id
        Haptics.confirm()
    }

    func invertMask(_ id: UUID) {
        guard let adjustment = mask(id) else { return }
        editMask(.setStack(feather: nil, expand: nil, density: nil, isInverted: !adjustment.stack.isInverted), on: id)
        flashMask(id)
    }

    func deleteMask(_ id: UUID) {
        var updated = document
        guard updated.removeLocalAdjustment(id: id) else { return }
        commit(updated, label: Self.masksLabel)
        if maskState.selectedID == id {
            maskState.selectedID = document.localAdjustments.last?.id
            maskState.editing = nil
        }
        maskState.thumbnails[id] = nil
        maskState.thumbnailKeys[id] = nil
        Haptics.warning()
    }

    func selectMask(_ id: UUID?) {
        guard maskState.selectedID != id else { return }
        maskState.selectedID = id
        maskState.editing = nil
        maskState.rangeEyedropper = false
        if let id {
            // A gradient opens with its handles, a range with its editor.
            if let first = mask(id)?.stack.components.first(where: { if case .linear = $0.kind { return true }; if case .radial = $0.kind { return true }; return false }) {
                maskState.editing = Self.editing(for: first)
            }
            flashMask(id)
        } else {
            requestPreview()
        }
        Haptics.tick()
    }

    /// `showMask:<id>` (maskEdit show): the mask selected in Masques, its tint flashed.
    func showMask(_ id: UUID) {
        guard mask(id) != nil else { return }
        if activeTool != .masks { activeTool = .masks }
        maskState.selectedID = id
        flashMask(id)
    }

    /// « Mettre à jour »: every AI raster of the mask made for another state of the picture is made again.
    func refreshAIMask(_ id: UUID) {
        guard let services, let adjustment = mask(id) else { return }
        // W3: a layer's masks are made again on its own pixels, against its own state.
        let owner = document.localAdjustmentOwner(of: id) ?? document.localAdjustmentsLayerID
        let key = document.maskStateKey(on: owner)
        let stale = adjustment.stack.components.compactMap { component -> (UUID, AIMaskRequest)? in
            guard case .raster(let raster) = component.kind, let stateKey = raster.stateKey, stateKey != key,
                  let request = Self.request(for: raster) else { return nil }
            return (component.id, request)
        }
        guard !stale.isEmpty else { return }
        let working = PhotoMaskState.Working(region: adjustment.region ?? .subject)
        maskState.aiWorking = working
        let document = self.document
        maskState.aiTask?.cancel()
        maskState.aiTask = Task { [weak self] in
            var kinds: [(UUID, MaskComponent.Kind)] = []
            for (componentID, request) in stale {
                guard let result = try? await services.aiMask(request, in: document, layer: owner) else { continue }
                kinds.append((componentID, .raster(result.raster)))
            }
            guard let self, !Task.isCancelled, self.maskState.aiWorking == working else { return }
            self.maskState.aiWorking = nil
            guard !kinds.isEmpty else {
                self.tellMaskProblem(L("The mask couldn't be updated."))
                return
            }
            var updated = self.document
            for (componentID, kind) in kinds { updated.applyLocalEdit(.setComponentKind(componentID, kind), to: id) }
            guard updated != self.document else { return }
            self.commit(updated, label: Self.masksLabel)
            self.flashMask(id)
            Haptics.magic()
        }
    }

    // MARK: - Overlay (D17)

    /// The overlay the next frame carries, nil when none shows: the colour range sheet's preview, the range map,
    /// the selected mask (pinned, while a finger drags, or flashing after it lands), the selection inside Sélection.
    var overlayRequest: MaskOverlayRequest? {
        guard !showsOriginal else { return nil }
        if let editing = selectionState.colorRange, let kind = editing.component, let style = editing.preview.style {
            return MaskOverlayRequest(target: .stack(.single(MaskComponent(kind))), style: style, color: maskState.overlayColor, opacity: 0.6)
        }
        guard selectionState.refine == nil else { return nil }
        switch activeTool {
        case .masks?:
            guard masksEnabled, let id = maskState.selectedID, let adjustment = mask(id) else { return nil }
            if maskState.showsRangeMap, case .range(let componentID)? = maskState.editing,
               let map = rangeMap(for: adjustment, componentID: componentID) {
                return MaskOverlayRequest(target: .stack(map), style: .blackAndWhite, opacity: 1)
            }
            // Painting on a mask with no adjustment yet shows its overlay, or nothing would show.
            let dragging = maskState.isDragging && (maskState.showsOverlayWhileDragging || adjustment.isNeutral)
            guard maskState.isOverlayPinned || dragging || maskState.flashingID == id else { return nil }
            return MaskOverlayRequest(target: .localAdjustment(id), style: maskState.overlay, color: maskState.overlayColor, opacity: 0.5)
        case .layers?:
            // W3 (D8): the layer mask being painted, rubylith by default (the overlay menu's style when pinned).
            guard layerState.mode == .maskPaint, let id = layerState.editingMaskOf, document.layer(id: id) != nil else { return nil }
            return MaskOverlayRequest(target: .layerMask(id), style: maskState.isOverlayPinned ? maskState.overlay : .rubylith,
                                      color: maskState.overlayColor, opacity: 0.5)
        case .select?:
            guard FeatureFlags.isOn(.aiSelection), document.selection != nil else { return nil }
            // Outline: the ants and a 20 % tint; any other style replaces the tint.
            if selectionState.overlay == .outline {
                return MaskOverlayRequest(target: .selection, style: .tint, color: selectionState.overlayColor, opacity: 0.2)
            }
            return MaskOverlayRequest(target: .selection, style: selectionState.overlay, color: selectionState.overlayColor, opacity: 0.5)
        default:
            return nil
        }
    }

    /// The range editor's « Afficher la carte »: the luminance or depth map itself, as a mask.
    func rangeMap(for adjustment: LocalAdjustment, componentID: UUID) -> MaskStack? {
        guard let component = adjustment.stack.components.first(where: { $0.id == componentID }) else { return nil }
        switch component.kind {
        case .luminanceRange:
            return .single(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 1, high: 1, feather: 1))))
        case .depthRange(let spec):
            return .single(MaskComponent(.depthRange(DepthRangeSpec(depth: spec.depth, low: 1, high: 1, feather: 1))))
        default:
            return nil
        }
    }

    /// The frame and its overlay: from one render (D17), or, while Select & Mask is open, its live refine preview.
    func renderFrameAndOverlay(_ document: PhotoDocument, options: PhotoRenderer.Options, renderer: PhotoRenderer) async throws -> (image: CIImage, overlay: CIImage?) {
        guard FeatureFlags.isOn(.masks) || FeatureFlags.isOn(.aiSelection) else {
            return (try await renderer.render(document, options: options), nil)
        }
        if let refine = selectionState.refine, let selection = document.selection {
            let image = try await renderer.render(document, options: options)
            let mask = try? await renderer.refinePreview(selection, refine.refinement, document: document, options: options)
            let overlay = mask.map { MaskOverlayRenderer.overlay(mask: $0, frame: image, style: refine.view.style, color: selectionState.overlayColor,
                                                                 opacity: 0.6, extent: image.extent) }
            return (image, overlay)
        }
        let request = overlayRequest
        return try await renderer.render(document, options: options, overlay: request)
    }

    /// A settled frame's overlay: kept at full strength, published scaled by the flash.
    func publishOverlay(_ overlay: CIImage?, generation: Int) {
        maskState.overlayBase = overlay
        let shown = levelledOverlay(overlay)
        if shown == nil, maskState.overlayImage == nil { return }
        maskState.overlayImage = shown
    }

    /// The overlay as shown now: faded by the flash when only the flash shows it.
    func levelledOverlay(_ overlay: CIImage?) -> CIImage? {
        guard let overlay else { return nil }
        guard let id = maskState.flashingID, activeTool == .masks, maskState.selectedID == id,
              !maskState.isOverlayPinned, !maskState.isDragging else { return overlay }
        let level = maskState.flashLevel
        if level >= 0.999 { return overlay }
        if level <= 0.001 { return nil }
        // A dissolve from clear scales the premultiplied overlay evenly.
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: overlay.extent)
        return overlay.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: overlay, kCIInputImageKey: clear, kCIInputTimeKey: level])
            .cropped(to: overlay.extent)
    }

    /// When a mask lands: its tint fades in, holds a second and fades out (instant under Reduce Motion).
    func flashMask(_ id: UUID) {
        maskState.flashTask?.cancel()
        guard activeTool == .masks else { return }
        maskState.flashingID = id
        let reduce = UIAccessibility.isReduceMotionEnabled
        maskState.flashLevel = reduce ? 1 : 0
        requestPreview()
        maskState.flashTask = Task { [weak self] in
            if !reduce {
                for step in 1...8 {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard let self, !Task.isCancelled else { return }
                    self.setFlashLevel(Double(step) / 8)
                }
            }
            try? await Task.sleep(for: .seconds(1))
            if !reduce {
                for step in stride(from: 7, through: 0, by: -1) {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard let self, !Task.isCancelled else { return }
                    self.setFlashLevel(Double(step) / 8)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.maskState.flashingID = nil
            self.maskState.flashLevel = 0
            if self.overlayRequest == nil {
                self.publishOverlay(nil, generation: self.previewGeneration)
            } else {
                self.requestPreview()
            }
        }
    }

    private func setFlashLevel(_ level: Double) {
        maskState.flashLevel = level
        let shown = levelledOverlay(maskState.overlayBase)
        maskState.overlayImage = shown
        canvasSink?.presentOverlay(shown, generation: previewGeneration)
    }

    /// The overlay menu: a style keeps the overlay on; nil (« Aucune ») shows it only while dragging and on landing.
    func setMaskOverlay(_ style: MaskOverlayStyle?) {
        if let style {
            maskState.overlay = style
            maskState.isOverlayPinned = true
        } else {
            maskState.isOverlayPinned = false
        }
        requestPreview()
    }

    func setMaskOverlayColor(_ color: PSColor) {
        maskState.overlayColor = color
        requestPreview()
    }

    // MARK: - Graphite surround (D18)

    /// While a tone, colour or mask panel is open, the canvas surround is graphite (#1E1E21), else black.
    var usesGraphiteSurround: Bool {
        guard FeatureFlags.isOn(.graphiteSurround) else { return false }
        switch activeTool {
        case .adjust?, .color?, .looks?, .curves?, .levels?, .masks?: return true
        default: return false
        }
    }

    func applySurround() {
        guard let view = canvasSink as? MetalCanvasView else { return }
        let graphite = usesGraphiteSurround
        let value = graphite ? 30.0 / 255 : 0
        let blue = graphite ? 33.0 / 255 : 0
        let current = view.backgroundClearColor
        guard current.red != value || current.green != value || current.blue != blue else { return }
        view.backgroundClearColor = MTLClearColor(red: value, green: value, blue: blue, alpha: 1)
    }

    // MARK: - Handles (linear and radial)

    /// The component whose handles the canvas shows: the one being edited, else the selected mask's first gradient.
    var handleComponent: (adjustmentID: UUID, component: MaskComponent)? {
        guard activeTool == .masks, let adjustment = selectedMask else { return nil }
        let isGradient: (MaskComponent) -> Bool = { component in
            switch component.kind {
            case .linear, .radial: return true
            default: return false
            }
        }
        if case .handles(let componentID)? = maskState.editing,
           let component = adjustment.stack.components.first(where: { $0.id == componentID }), isGradient(component) {
            return (adjustment.id, component)
        }
        if maskState.editing == nil, let component = adjustment.stack.components.first(where: isGradient) {
            return (adjustment.id, component)
        }
        return nil
    }

    /// A touch at `point` (view points) grabs a handle of the shown gradient: the drag begins (one undo step).
    func beginHandleDrag(at point: PSPoint, placement: MaskHandleGeometry.Placement) -> Bool {
        guard let (adjustmentID, component) = handleComponent else { return false }
        let handle: MaskHandleGeometry.Handle?
        switch component.kind {
        case .linear(let spec): handle = MaskHandleGeometry.hit(point, linear: spec, in: placement)
        case .radial(let spec): handle = MaskHandleGeometry.hit(point, radial: spec, in: placement)
        default: handle = nil
        }
        guard let handle else { return false }
        maskState.handleDrag = (handle, adjustmentID, component.id, component.kind)
        beginInteraction(label: Self.masksLabel)
        maskInteractionTarget = adjustmentID
        maskState.isDragging = true
        maskState.editing = .handles(component.id)
        Haptics.tick()
        return true
    }

    func updateHandleDrag(from start: PSPoint, to current: PSPoint, placement: MaskHandleGeometry.Placement) {
        guard let drag = maskState.handleDrag else { return }
        let kind: MaskComponent.Kind
        switch drag.start {
        case .linear(let spec): kind = .linear(MaskHandleGeometry.dragged(spec, handle: drag.handle, from: start, to: current, in: placement))
        case .radial(let spec): kind = .radial(MaskHandleGeometry.dragged(spec, handle: drag.handle, from: start, to: current, in: placement))
        default: return
        }
        maskState.liveComponent = (drag.componentID, kind)
        editMask(.setComponentKind(drag.componentID, kind), on: drag.adjustmentID)
    }

    func endHandleDrag() {
        guard maskState.handleDrag != nil else { return }
        maskState.handleDrag = nil
        maskState.liveComponent = nil
        maskState.isDragging = false
        endInteraction()
    }

    /// A second finger came down on a handle (a two-finger pan): the handle goes back, nothing committed.
    func cancelHandleDrag() {
        guard maskState.handleDrag != nil else { return }
        maskState.handleDrag = nil
        maskState.liveComponent = nil
        maskState.isDragging = false
        cancelInteraction()
    }

    /// A second finger came down on a brush stroke (a two-finger pan): the stroke is dropped, nothing committed.
    func cancelMaskStroke() {
        guard activeBrush != nil else { return }
        maskState.pendingDrag = []
        activeBrush = nil
        lastBrushPoint = nil
        maskState.isDragging = false
        cancelInteraction()
    }

    /// VoiceOver's adjust on the handles: a radial grows or shrinks by 5 % of the longest side, a linear moves 5 %
    /// along its axis; one step each.
    func nudgeHandles(by direction: Double) {
        guard let (adjustmentID, component) = handleComponent else { return }
        let kind: MaskComponent.Kind
        switch component.kind {
        case .radial(var spec):
            spec.radiusX = (spec.radiusX * (1 + 0.1 * direction)).clamped(to: MaskHandleGeometry.minimumLength...2)
            spec.radiusY = (spec.radiusY * (1 + 0.1 * direction)).clamped(to: MaskHandleGeometry.minimumLength...2)
            kind = .radial(spec)
        case .linear(var spec):
            let dx = spec.end.x - spec.start.x, dy = spec.end.y - spec.start.y
            let length = max(1e-6, (dx * dx + dy * dy).squareRoot())
            let step = PSPoint(x: dx / length * 0.05 * direction, y: dy / length * 0.05 * direction)
            spec.start = spec.start + step
            spec.end = spec.end + step
            kind = .linear(spec)
        default:
            return
        }
        editMask(.setComponentKind(component.id, kind), on: adjustmentID)
    }

    // MARK: - Brush (§7.4)

    /// Whether a drag on the canvas paints the mask now.
    var paintsMask: Bool {
        guard activeTool == .masks, case .brush? = maskState.editing else { return false }
        return true
    }

    /// The first touch of a brush gesture: the target mask and component are made inside the drag (one undo step).
    func beginMaskStroke(at point: PSPoint) {
        guard paintsMask else { return }
        maskState.pendingDrag = [segment(from: point, to: point)]
        lastBrushPoint = point
        // Where the strokes go: the edited brush, a new component of the selected mask, or a new mask.
        let adjustmentID: UUID, componentID: UUID, mode: CombineMode, creates: Bool
        switch (maskState.editing, maskState.brushTarget) {
        case (.brush(let id?)?, _):
            guard let selected = maskState.selectedID else { return }
            adjustmentID = selected
            componentID = id
            mode = .add
            creates = false
        case (_, .component(let target, let component, let targetMode)):
            adjustmentID = target
            componentID = component
            mode = targetMode
            creates = false
        default:
            guard canAddMask else {
                tellMaskProblem(L("There are already 16 masks: delete one first."))
                return
            }
            adjustmentID = UUID()
            componentID = UUID()
            mode = .add
            creates = true
        }
        let existing = mask(adjustmentID)?.stack.components.first { $0.id == componentID }
        if case .brush(let spec)? = existing?.kind {
            maskState.committedStrokes = spec.strokes
        } else {
            maskState.committedStrokes = []
        }
        activeBrush = (adjustmentID, componentID, mode, creates)
        beginInteraction(label: Self.masksLabel)
        maskInteractionTarget = adjustmentID
        maskState.isDragging = true
        maskState.selectedID = adjustmentID
        maskState.editing = .brush(componentID)
        applyBrushStrokes(maskState.pendingDrag)
    }

    /// Each touch batch adds one 2-point segment, so the stroke cache appends instead of redrawing (D6).
    func continueMaskStroke(to point: PSPoint) {
        guard activeBrush != nil, let last = lastBrushPoint else { return }
        maskState.pendingDrag.append(segment(from: last, to: point))
        lastBrushPoint = point
        applyBrushStrokes(maskState.pendingDrag)
    }

    /// The gesture's segments coalesce into one polyline stroke (the same raster), then the drag commits once.
    /// Past `BrushSpec.maxStrokes` gestures the brush is flattened into a raster, never during a drag.
    func endMaskStroke() {
        guard let brush = activeBrush else { return }
        let segments = maskState.pendingDrag
        if let first = segments.first {
            var points = first.points
            for segment in segments.dropFirst() { if let end = segment.points.last { points.append(end) } }
            let stroke = BrushStroke(points: points, radius: first.radius, hardness: first.hardness, mode: first.mode, flow: first.flow)
            // The polyline draws the segments' pixels: the renderer keeps their raster under the merged list, so the
            // next touch-down extends it rather than redrawing the brush's whole history on the CPU.
            if let renderer {
                let drawn = maskState.committedStrokes + segments, merged = maskState.committedStrokes + [stroke]
                Task { await renderer.noteBrushCoalesced(drawn, as: merged) }
            }
            applyBrushStrokes([stroke])
        }
        maskState.pendingDrag = []
        activeBrush = nil
        lastBrushPoint = nil
        maskState.isDragging = false
        endInteraction()
        maskState.brushTarget = .component(adjustmentID: brush.adjustmentID, componentID: brush.componentID, mode: brush.mode)
        flattenBrushIfNeeded(adjustmentID: brush.adjustmentID, componentID: brush.componentID)
    }

    /// One touch batch as a 2-point stroke in the mask's space: canvas points on the base; on another image layer
    /// (W3) its content space (D8). The size stays a fraction of the mask space's longest side, which is what the
    /// cursor draws on the layer's placed frame (`maskPlacementFrame`).
    private func segment(from a: PSPoint, to b: PSPoint) -> BrushStroke {
        let settings = maskState.brush
        var points = [a, b]
        if let map = maskSpaceMap() { points = points.map(map.apply) }
        return BrushStroke(points: points, radius: settings.size, hardness: settings.hardness, mode: settings.erase ? .subtract : .add,
                           flow: settings.flow < 0.999 ? settings.flow : nil)
    }

    /// The brush component's strokes = the committed ones + `strokes`, applied to the dragged copy.
    private func applyBrushStrokes(_ strokes: [BrushStroke]) {
        guard let brush = activeBrush else { return }
        let all = maskState.committedStrokes + strokes
        let componentID = brush.componentID, adjustmentID = brush.adjustmentID, mode = brush.mode, creates = brush.creates
        interactiveEdit(label: Self.masksLabel) { document in
            if creates, !document.localAdjustments.contains(where: { $0.id == adjustmentID }) {
                document.setLocalAdjustment(LocalAdjustment(id: adjustmentID, stack: MaskStack()), label: Self.masksLabel)
            }
            if document.localAdjustments.first(where: { $0.id == adjustmentID })?.stack.components.contains(where: { $0.id == componentID }) != true {
                document.applyLocalEdit(.addComponent(MaskComponent(id: componentID, .brush(BrushSpec()), mode: mode)), to: adjustmentID)
            }
            document.applyLocalEdit(.setComponentKind(componentID, .brush(BrushSpec(strokes: all))), to: adjustmentID)
        }
    }

    private func flattenBrushIfNeeded(adjustmentID: UUID, componentID: UUID) {
        guard let component = mask(adjustmentID)?.stack.components.first(where: { $0.id == componentID }),
              case .brush(let spec) = component.kind, spec.needsFlatten else { return }
        let document = self.document
        // Off every actor, with Core's rasteriser, at the working size in the mask's aspect (D3): on the renderer it
        // would redraw every stroke at a size its cache never drew, and the canvas would stop for seconds.
        let side = Double(VisionPhotoServices.analysisLongestSide)
        let aspect = maskAspect
        let width = max(1, Int((aspect >= 1 ? side : side * aspect).rounded()))
        let height = max(1, Int((aspect >= 1 ? side / aspect : side).rounded()))
        let store = MaskStore(store: app.store, projectID: projectID)
        let stateKey = document.baseStateKey
        maskState.flattenTask?.cancel()
        maskState.flattenTask = Task { [weak self] in
            let flattened = try? await Task.detached(priority: .utility) { () throws -> RasterRef in
                var bytes = [UInt8](repeating: 0, count: width * height)
                BrushRaster.draw(spec.strokes, width: width, height: height, into: &bytes)
                return try store.saveRaster(bytes: bytes, width: width, height: height, origin: .brush, stateKey: stateKey)
            }.value
            guard let self, !Task.isCancelled, let raster = flattened else { return }
            // Only over the strokes it drew: a stroke painted or undone meanwhile stays (the next stroke flattens again).
            guard case .brush(let current)? = self.mask(adjustmentID)?.stack.components.first(where: { $0.id == componentID })?.kind,
                  current == spec else { return }
            var updated = self.document
            guard updated.applyLocalEdit(.setComponentKind(componentID, .raster(raster)), to: adjustmentID) else { return }
            // The same undo step as the stroke that crossed the limit, when nothing changed since.
            if self.document == document {
                self.amendPresent(updated)
            } else {
                self.commit(updated, label: Self.masksLabel)
            }
            if case .brush(componentID)? = self.maskState.editing { self.maskState.editing = nil }
        }
    }

    // MARK: - Ranges

    /// A range thumb or « Adoucir » moved: low, high and feather of a luminance or depth component.
    func setRange(_ componentID: UUID, low: Double, high: Double, feather: Double) {
        guard let id = maskState.selectedID, let component = mask(id)?.stack.components.first(where: { $0.id == componentID }) else { return }
        let kind: MaskComponent.Kind
        switch component.kind {
        case .luminanceRange: kind = .luminanceRange(LuminanceRangeSpec(low: low, high: high, feather: feather))
        case .depthRange(let spec): kind = .depthRange(DepthRangeSpec(depth: spec.depth, low: low, high: high, feather: feather))
        default: return
        }
        editMask(.setComponentKind(componentID, kind), on: id)
    }

    func beginRangeDrag() {
        beginMaskInteraction()
        maskState.isDragging = true
    }

    func endRangeDrag() {
        maskState.isDragging = false
        endMaskInteraction()
    }

    /// The range editor's eyedropper: the tapped point's luminance (or depth) ± 0.1.
    func sampleRange(at point: PSPoint) {
        maskState.rangeEyedropper = false
        guard let services, case .range(let componentID)? = maskState.editing, let id = maskState.selectedID,
              let component = mask(id)?.stack.components.first(where: { $0.id == componentID }) else { return }
        let document = self.document
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        Task { [weak self] in
            var value: Double?
            switch component.kind {
            case .luminanceRange:
                let samples = try? await services.sampleColors(at: [point], radius: 2, in: document)
                value = samples?.first.map { Self.luma(of: $0) }
            case .depthRange(let spec):
                value = await Task.detached(priority: .userInitiated) { () -> Double? in
                    guard let raw = maskStore.rawBytes(spec.depth), raw.width > 0, raw.height > 0 else { return nil }
                    let x = min(raw.width - 1, max(0, Int(point.x * Double(raw.width))))
                    let y = min(raw.height - 1, max(0, Int(point.y * Double(raw.height))))
                    return Double(raw.bytes[y * raw.width + x]) / 255
                }.value
            default:
                value = nil
            }
            guard let self, let value else { return }
            let range = MaskHandleGeometry.sampledRange(at: value)
            let feather: Double
            switch component.kind {
            case .luminanceRange(let spec): feather = spec.feather
            case .depthRange(let spec): feather = spec.feather
            default: feather = 0.15
            }
            self.setRange(componentID, low: range.low, high: range.high, feather: feather)
            Haptics.confirm()
        }
    }

    /// Rec.709 luma of the gamma sRGB colour a Lab colour is (the inverse of MaskMath.lab).
    static func luma(of lab: LabColor) -> Double {
        let rgb = sRGB(of: lab)
        return MaskMath.luma(r: rgb.r, g: rgb.g, b: rgb.b)
    }

    /// The gamma sRGB colour (0…1, clipped) of a Lab colour (D65): the inverse of MaskMath.lab, for the swatches.
    nonisolated static func sRGB(of lab: LabColor) -> (r: Double, g: Double, b: Double) {
        let fy = (lab.l + 16) / 116, fx = fy + lab.a / 500, fz = fy - lab.b / 200
        func inverse(_ t: Double) -> Double {
            let cube = t * t * t
            return cube > 216.0 / 24389.0 ? cube : (116 * t - 16) / (24389.0 / 27.0)
        }
        let x = 0.95047 * inverse(fx), y = inverse(fy), z = 1.08883 * inverse(fz)
        func gamma(_ value: Double) -> Double {
            let c = min(1, max(0, value))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (gamma(3.2404542 * x - 1.5371385 * y - 0.4985314 * z),
                gamma(-0.9692660 * x + 1.8760108 * y + 0.0415560 * z),
                gamma(0.0556434 * x - 0.2040259 * y + 1.0572252 * z))
    }

    /// The range editor's histogram: 64 bins of the pre-local luminance (256 px proxy) or of the depth map.
    func loadRangeHistogram() {
        guard case .range(let componentID)? = maskState.editing, let adjustment = selectedMask,
              let component = adjustment.stack.components.first(where: { $0.id == componentID }), let renderer else { return }
        let key: String
        switch component.kind {
        case .luminanceRange: key = "luma|\(document.baseStateKey)"
        case .depthRange(let spec): key = "depth|\(spec.depth.path)"
        default: return
        }
        guard maskState.rangeHistogramKey != key else { return }
        maskState.rangeHistogramKey = key
        let document = self.document
        let maskStore = MaskStore(store: app.store, projectID: projectID)
        Task { [weak self] in
            var bins: [Double] = []
            switch component.kind {
            case .luminanceRange:
                let options = PhotoRenderer.Options(targetLongestSide: 256, includeOverlays: false, allowExpensiveWork: false, includesLocalAdjustments: false)
                guard let image = try? await renderer.render(document, options: options) else { return }
                bins = await Task.detached(priority: .utility) { () -> [Double] in
                    guard let cg = ImageSupport.cgImage(from: image) else { return [] }
                    let rgba = ImageSupport.rgbaBytes(from: cg)
                    var counts = [Double](repeating: 0, count: 64)
                    var index = 0
                    while index + 3 < rgba.count {
                        let luma = MaskMath.luma(r: Double(rgba[index]) / 255, g: Double(rgba[index + 1]) / 255, b: Double(rgba[index + 2]) / 255)
                        counts[min(63, max(0, Int(luma * 64)))] += 1
                        index += 4
                    }
                    return Self.normalizedBins(counts)
                }.value
            case .depthRange(let spec):
                bins = await Task.detached(priority: .utility) { () -> [Double] in
                    guard let raw = maskStore.rawBytes(spec.depth) else { return [] }
                    var counts = [Double](repeating: 0, count: 64)
                    for byte in raw.bytes { counts[min(63, Int(byte) / 4)] += 1 }
                    return Self.normalizedBins(counts)
                }.value
            default:
                return
            }
            guard let self, self.maskState.rangeHistogramKey == key else { return }
            self.maskState.rangeHistogram = bins
        }
    }

    /// Bin heights 0…1 on a square-root scale, so a few large bins do not flatten the rest.
    nonisolated static func normalizedBins(_ counts: [Double]) -> [Double] {
        let scaled = counts.map { $0.squareRoot() }
        guard let top = scaled.max(), top > 0 else { return counts.map { _ in 0 } }
        return scaled.map { $0 / top }
    }

    // MARK: - Canvas taps

    /// A tap in Masques: an object pick, or the range eyedropper. True when it was used.
    func handleMaskTap(at point: PSPoint) -> Bool {
        if case .object? = maskState.editing {
            pickObject(at: point)
            return true
        }
        if maskState.rangeEyedropper {
            sampleRange(at: point)
            return true
        }
        return false
    }

    // MARK: - Tool lifecycle

    /// Masques or Sélection opened or closed: their state, the overlay, the surround, the model preload.
    func masksToolDidChange(from previous: Tool?) {
        applySurround()
        if previous == .masks {
            if activeBrush != nil { endMaskStroke() }
            if maskState.handleDrag != nil { endHandleDrag() }
            maskState.editing = nil
            maskState.rangeEyedropper = false
            maskState.showsRangeMap = false
            maskState.flashTask?.cancel()
            maskState.flashingID = nil
        }
        if previous == .select { selectToolDidClose() }
        if activeTool == .masks {
            if maskState.selectedID == nil || selectedMask == nil { maskState.selectedID = document.localAdjustments.last?.id }
            loadMaskSuggestions()
            refreshMaskThumbnails()
        }
        if activeTool == .select { selectToolDidOpen() }
        if previous == .masks || previous == .select || activeTool == .masks || activeTool == .select {
            if overlayRequest == nil, maskState.overlayImage != nil { publishOverlay(nil, generation: previewGeneration) }
            requestPreview()
        }
        scheduleMaskModelPreload()
    }

    /// Opening Masques or Sélection preloads SAM 300 ms later (cancelled if the tool closes), when it is installed
    /// and its flag is on.
    func scheduleMaskModelPreload() {
        maskState.preloadTask?.cancel()
        maskState.preloadTask = nil
        guard activeTool == .masks || activeTool == .select, FeatureFlags.isOn(.samModel), let services,
              app.modelStates[MaskModelCatalog.samTiny.id] == .installed else { return }
        let document = self.document
        maskState.preloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.activeTool == .masks || self.activeTool == .select else { return }
            await services.prepareMaskModels([.sam], for: document)
        }
    }

    /// The empty state's « Détectés » row and the faces of « Personne… », once per base state.
    func loadMaskSuggestions() {
        guard let services else { return }
        let key = document.baseStateKey
        guard maskState.suggestionsKey != key else { return }
        maskState.suggestionsKey = key
        let document = self.document
        maskState.suggestionsTask?.cancel()
        maskState.suggestionsTask = Task { [weak self] in
            let suggestions = await services.maskSuggestions(in: document)
            let faces = suggestions.personCount > 0 ? await services.personThumbnails(in: document, side: 96) : []
            guard let self, !Task.isCancelled, self.maskState.suggestionsKey == key else { return }
            withAnimation(PSMotion.standard) {
                self.maskState.suggestions = suggestions
                self.maskState.personThumbnails = faces
            }
        }
    }

    /// 64-point thumbnails of the masks whose stack or picture changed, one after the other, off the main thread.
    func refreshMaskThumbnails() {
        guard let renderer, activeTool == .masks else { return }
        let document = self.document
        let state = document.baseStateKey
        let wanted = document.localAdjustments.compactMap { adjustment -> (UUID, MaskStack, String)? in
            let key = adjustment.stack.contentKey + "|" + state
            return maskState.thumbnailKeys[adjustment.id] == key ? nil : (adjustment.id, adjustment.stack, key)
        }
        guard !wanted.isEmpty else { return }
        maskState.thumbnailTask?.cancel()
        maskState.thumbnailTask = Task { [weak self] in
            for (id, stack, key) in wanted {
                guard !Task.isCancelled else { return }
                let image = try? await renderer.maskThumbnail(stack, document: document, side: 96)
                guard let self, !Task.isCancelled else { return }
                self.maskState.thumbnailKeys[id] = key
                if let image { self.maskState.thumbnails[id] = image }
            }
        }
    }

    /// After every document change (an edit, an undo): the selected mask still exists, the editing component too,
    /// the thumbnails follow, the selection's outline and its baked copy follow.
    func masksDidChange(_ document: PhotoDocument) {
        let masks = document.localAdjustments
        if let id = maskState.selectedID, !masks.contains(where: { $0.id == id }) {
            maskState.selectedID = activeTool == .masks ? masks.last?.id : nil
            maskState.editing = nil
        }
        if let editing = maskState.editing, let componentID = Self.editedComponent(editing),
           activeBrush == nil, maskState.handleDrag == nil,
           maskState.selected(in: document)?.stack.components.contains(where: { $0.id == componentID }) != true {
            maskState.editing = nil
        }
        let ids = Set(masks.map(\.id))
        for id in maskState.thumbnails.keys where !ids.contains(id) { maskState.thumbnails[id] = nil }
        refreshMaskThumbnails()
        selectionDidChange(document)
    }

    func masksTeardown() {
        maskState.aiTask?.cancel()
        maskState.flashTask?.cancel()
        maskState.preloadTask?.cancel()
        maskState.thumbnailTask?.cancel()
        maskState.suggestionsTask?.cancel()
        maskState.installWatch?.cancel()
        maskState.flattenTask?.cancel()
        selectionState.contourTask?.cancel()
    }

    // MARK: - Model offers (SAM, Depth)

    /// `offerModel:<id>`: the download card shows; the call that needed the model waits for it.
    func offerMaskModel(_ id: String, for intent: EditIntent) {
        maskState.modelOffer = id
        maskState.pendingModel = (id, intent)
    }

    /// Télécharger, or « oui » to the offer (`installModel:<id>`): the download starts; once installed while the
    /// editor is open, the waiting call runs again once.
    func installMaskModel(_ id: String) {
        guard let descriptor = ModelCatalog.descriptor(id: id) else {
            tellMaskProblem(L("This model can't be installed on this iPhone yet."))
            return
        }
        maskState.modelOffer = id
        guard app.modelStates[id] != .installed else {
            modelDidInstall(id)
            return
        }
        guard app.install(descriptor) else {
            tellMaskProblem(L("This model can't be installed on this iPhone yet."))
            return
        }
        Haptics.confirm()
        maskState.installWatch?.cancel()
        maskState.installWatch = Task { [weak self] in
            // Half a second at a time, for half an hour at most.
            for _ in 0..<3600 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                switch self.app.modelStates[id] {
                case .installed?:
                    self.modelDidInstall(id)
                    return
                case .failed(let message)?:
                    self.showToast(message, isError: true)
                    return
                default:
                    continue
                }
            }
        }
    }

    func dismissModelOffer() {
        maskState.modelOffer = nil
        maskState.pendingModel = nil
    }

    private func modelDidInstall(_ id: String) {
        if maskState.modelOffer == id { maskState.modelOffer = nil }
        scheduleMaskModelPreload()
        guard let pending = maskState.pendingModel, pending.id == id else {
            showToast(L("Model installed."))
            return
        }
        maskState.pendingModel = nil
        showToast(L("Model installed: picking up where we left off."))
        Task { [weak self] in await self?.run(pending.intent) }
    }

    // MARK: - Opening a control (openTool:<id>, the palette)

    /// Opens the tool of a MaskPanelInventory control in the mode its gesture needs (« peins sur le masque »,
    /// « sélection rapide », « pipette »…); a Tool raw value opens that tool.
    func openControl(_ id: String) {
        // W3: the photo panels' gesture controls (layers.*, canvas.*, export.*, erase.*, crop.*…).
        if MaskPanelInventory.control(id) == nil, let control = PhotoPanelInventory.control(id) {
            openPhotoPanelControl(id, control)
            return
        }
        guard let control = MaskPanelInventory.control(id), let tool = Tool(rawValue: control.uiTool) else {
            if let tool = Tool(rawValue: id) { activeTool = tool }
            return
        }
        switch tool {
        case .masks: guard masksEnabled else { return }
        case .select: guard FeatureFlags.isOn(.aiSelection) else { return }
        default: break
        }
        if activeTool != tool { activeTool = tool }
        if id.hasPrefix("masks.brush.") || id == "masks.new.brush" || id == "masks.component.source.brush" {
            maskState.brush.erase = id == "masks.brush.erase"
            if id == "masks.new.brush" || selectedMask == nil { beginBrushMask() } else { addBrushComponent(mode: .add) }
        } else if id == "masks.handles.linear" || id == "masks.handles.radial" {
            let wantsLinear = id == "masks.handles.linear"
            if let adjustment = document.localAdjustments.last(where: { adjustment in
                adjustment.stack.components.contains { component in
                    if case .linear = component.kind { return wantsLinear }
                    if case .radial = component.kind { return !wantsLinear }
                    return false
                }
            }) {
                maskState.selectedID = adjustment.id
                maskState.editing = nil
            } else {
                addMask(wantsLinear ? .top : .center)
            }
        } else if id.hasPrefix("masks.object.") {
            beginObjectPick(mode: nil)
        } else if id == "masks.range.eyedropper" {
            if let component = selectedMask?.stack.components.first(where: { component in
                if case .luminanceRange = component.kind { return true }
                if case .depthRange = component.kind { return true }
                return false
            }) {
                maskState.editing = .range(component.id)
                maskState.rangeEyedropper = true
            }
        } else if id == "masks.curve.points" {
            maskState.expanded.insert("curve")
        } else if id.hasPrefix("masks.colorRange.") {
            openColorRange(for: .newMask)
        } else if id.hasPrefix("select.") {
            openSelectControl(id)
        }
    }

    // MARK: - Messages

    /// « Je ne vois pas de ciel ici » / "I can't see any sky here".
    static func notFoundMessage(_ region: MaskRegion) -> String {
        let french = psPrefersFrench
        let noun = MaskAccessibility.regionName(region, language: french ? .fr : .en).lowercased()
        guard french else { return "I can't see any \(noun) here." }
        let elided = noun.first.map { "aeiouyhéèêàâîïôû".contains($0) } ?? false
        return "Je ne vois pas \(elided ? "d'" : "de ")\(noun) ici."
    }

    /// A mask service's failure, in words: the model offer, nothing found, not on this iPhone yet.
    func handleMaskError(_ error: Error, region: MaskRegion) {
        guard let error = error as? PicshopError else {
            tellMaskProblem(error.localizedDescription)
            return
        }
        switch error {
        case .modelUnavailable(let id):
            maskState.modelOffer = id
        case .objectNotFound, .noSubject:
            tellMaskProblem(Self.notFoundMessage(region))
        case .unsupportedOperation:
            tellMaskProblem(L("Not on this iPhone yet."))
        default:
            tellMaskProblem(error.message)
        }
    }

    func tellMaskProblem(_ message: String) {
        Haptics.warning()
        showToast(message, isError: true)
    }

    // MARK: - Drag bookkeeping (the brush)

    /// The brush gesture in progress: where it paints, and whether it makes the mask or the component.
    var activeBrush: (adjustmentID: UUID, componentID: UUID, mode: CombineMode, creates: Bool)? {
        get { maskState.activeBrush }
        set { maskState.activeBrush = newValue }
    }

    var lastBrushPoint: PSPoint? {
        get { maskState.lastBrushPoint }
        set { maskState.lastBrushPoint = newValue }
    }
}

// MARK: - The layer-mask brush (W3, D8)

// Calques › masque › « Peindre »: W2's brush (pending segments, the stroke cache appending, one coalesced polyline per
// gesture, flattened past `BrushSpec.maxStrokes`) on a layer's own mask, through `LayerEdit.maskStack` on the dragged
// copy: one undo step per gesture on the `.layerMask` snapshot (D13). A mask is revealed by an add-mode brush and
// hidden by a subtract-mode brush at the end of the stack; « Tout afficher » and « Tout masquer » masks are one brush
// that does both (a first subtract component starts from everything). Linked masks of image, text and shape layers
// live in the content space: canvas points go through the inverse placement map, the radius with them.
extension PhotoEditorSession {
    static let layerMaskLabel = "Layer Mask"

    /// A drag on the canvas paints a layer mask now.
    var paintsLayerMask: Bool {
        activeTool == .layers && layerState.mode == .maskPaint && layerState.editingMaskOf != nil
    }

    /// `openTool:<PhotoPanelInventory id>` (W3): the control's tool, in the mode its gesture needs. The Intent
    /// handler has already refused a control whose flag is off; the layer-mask brush and the transform handles check
    /// their own flags, locks and the base layer (with the toast).
    private func openPhotoPanelControl(_ id: String, _ control: PhotoPanelInventory.Control) {
        if control.uiTool == "export" {
            presentExport(preset: nil)
            return
        }
        let selected = document.selectedLayerID
        if id == "layers.mask.paint" || id == "layers.mask.paint.erase" || id.hasPrefix("layers.mask.brush.") {
            guard let layerID = selected else {
                if activeTool != .layers { activeTool = .layers }
                return
            }
            beginLayerMaskPaint(layerID)
            if id == "layers.mask.paint" { setLayerMaskHides(false) }
            if id == "layers.mask.paint.erase" { setLayerMaskHides(true) }
            return
        }
        let modePrefix = "layers.transform.mode."
        if id == "layers.transform.handles" || id.hasPrefix(modePrefix) || id == "canvas.layer.drag" {
            guard let layerID = selected else {
                if activeTool != .layers { activeTool = .layers }
                return
            }
            let mode = id.hasPrefix(modePrefix) ? TransformMode(rawValue: String(id.dropFirst(modePrefix.count))) : nil
            beginTransformMode(layerID, mode: mode)
            return
        }
        let tool = control.uiTool == "canvas" ? Tool.layers : Tool(rawValue: control.uiTool)
        if let tool, activeTool != tool { activeTool = tool }
    }

    /// « Peindre » on a layer's mask (LayerMaskControls, the `paintLayerMask:` effect): a layer without a mask gets
    /// a « Tout afficher » one first (its own step), then the brush paints it.
    func beginLayerMaskPaint(_ layerID: UUID) {
        guard proLayersEnabled, let layer = document.layer(id: layerID), layerAllows(.mask, on: layerID) else { return }
        if layerState.mode == .transform { endTransformMode() }
        if activeTool != .layers { activeTool = .layers }
        if document.selectedLayerID != layerID { selectLayer(layerID) }
        if layer.maskStack == nil, layer.mask == nil {
            addLayerMask(.revealAll, to: layerID)
            guard document.layer(id: layerID)?.maskStack != nil else { return }
        }
        layerState.editingMaskOf = layerID
        layerState.mode = .maskPaint
        layerState.maskControlsOf = layerID
        // D13: the brush's snapshot is captured now and kept between strokes, so the first dab never waits for it.
        if interaction == nil { requestInteractionSnapshot(.layerMask(layerID)) }
        Haptics.tick()
        requestPreview()
    }

    /// « Terminé », Calques closing or the layer gone: the brush goes down.
    func endLayerMaskPaint() {
        if layerState.maskStroke != nil { endLayerMaskStroke() }
        guard layerState.mode == .maskPaint || layerState.editingMaskOf != nil else { return }
        layerState.editingMaskOf = nil
        if layerState.mode == .maskPaint { layerState.mode = .select }
        releaseKeptInteractionSnapshot()
        requestPreview()
    }

    /// « Peindre » reveals, « Effacer » hides.
    func setLayerMaskHides(_ hides: Bool) {
        guard layerState.maskPaintHides != hides else { return }
        layerState.maskPaintHides = hides
        Haptics.tick()
    }

    /// X on a hardware keyboard.
    func swapLayerMaskPaint() {
        setLayerMaskHides(!layerState.maskPaintHides)
    }

    /// Where a layer's mask lives (D8): the canvas (the base, unlinked masks, fill, gradient, adjustment and group
    /// layers), or the content space of a linked image, text or shape layer, reached through the inverse placement.
    /// Nil when that placement is degenerate.
    func layerMaskSpace(of layer: Layer) -> (toMask: PSHomography?, aspect: Double)? {
        let canvasAspect = Self.aspect(document.canvasSize)
        guard layer.id != document.baseLayerID, layer.isMaskLinked else { return (nil, canvasAspect) }
        switch layer.content {
        case .image, .text, .shape: break
        case .fill, .gradientFill, .adjustment, .group, .unsupported: return (nil, canvasAspect)
        }
        guard let size = layerContentSize(layer.id), size.width > 0, size.height > 0,
              let inverse = LayerPlacement.inverseMap(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false) else { return nil }
        return (inverse, Self.aspect(size))
    }

    /// The finger goes down with the layer-mask brush: the components it paints into are found or made, and the drag
    /// begins (one undo step).
    func beginLayerMaskStroke(at point: PSPoint) {
        guard paintsLayerMask, let id = layerState.editingMaskOf, let layer = document.layer(id: id) else { return }
        guard layerAllows(.mask, on: id), var stack = layerMaskStack(id) else { return }
        guard let space = layerMaskSpace(of: layer) else {
            refuseLayerEdit(.notApplicable, layerID: id)
            return
        }
        let hides = layerState.maskPaintHides != stack.isInverted
        let components = stack.components
        var hideIndex: Int? = components.indices.last.flatMap { Self.isBrush(components[$0], mode: .subtract) ? $0 : nil }
        let below = (hideIndex ?? components.count) - 1
        var revealIndex: Int? = below >= 0 && Self.isBrush(components[below], mode: .add) ? below : nil
        if hides {
            // A hide needs the subtract brush, unless the reveal brush is the whole mask (« Tout masquer »).
            if hideIndex == nil, !(components.count == 1 && revealIndex == 0) {
                stack.components.append(MaskComponent(.brush(BrushSpec()), mode: .subtract))
                hideIndex = stack.components.count - 1
            }
        } else if revealIndex == nil, !(components.count == 1 && hideIndex == 0) {
            // A reveal needs the add brush under the hide brush, unless the hide brush is the whole mask (« Tout afficher »).
            let index = hideIndex ?? stack.components.count
            stack.components.insert(MaskComponent(.brush(BrushSpec()), mode: .add), at: index)
            revealIndex = index
            if let hide = hideIndex { hideIndex = hide + 1 }
        }
        layerState.maskStroke = LayerMaskStroke(layerID: id, start: stack, revealIndex: revealIndex, hideIndex: hideIndex,
                                                revealStrokes: Self.brushStrokes(in: stack, at: revealIndex),
                                                hideStrokes: Self.brushStrokes(in: stack, at: hideIndex),
                                                hides: hides, toMask: space.toMask, canvasAspect: Self.aspect(document.canvasSize),
                                                maskAspect: space.aspect, last: point)
        layerState.isCanvasGestureActive = true
        beginInteraction(label: Self.layerMaskLabel, scope: .layerMask(id))
        appendLayerMaskSegment(to: point)
    }

    /// Each touch batch adds one 2-point segment (the stroke cache appends).
    func continueLayerMaskStroke(to point: PSPoint) {
        guard layerState.maskStroke != nil else { return }
        appendLayerMaskSegment(to: point)
    }

    /// The gesture's segments coalesce into one polyline per component, then the drag commits once; past the stroke
    /// limit the brush is flattened, never during a drag.
    func endLayerMaskStroke() {
        guard let stroke = layerState.maskStroke else { return }
        if let first = stroke.segments.first {
            var points = first.points
            for segment in stroke.segments.dropFirst() { if let end = segment.points.last { points.append(end) } }
            let polyline = BrushStroke(points: points, radius: first.radius, hardness: first.hardness, mode: .add, flow: first.flow)
            if let renderer {
                let revealMode: BrushStroke.Mode = stroke.hides ? .subtract : .add
                let hideMode: BrushStroke.Mode = stroke.hides ? .add : .subtract
                let revealDrawn = stroke.revealStrokes + stroke.segments.map { Self.stroke($0, mode: revealMode) }
                let revealMerged = stroke.revealStrokes + [Self.stroke(polyline, mode: revealMode)]
                let hideDrawn = stroke.hideStrokes + stroke.segments.map { Self.stroke($0, mode: hideMode) }
                let hideMerged = stroke.hideStrokes + [Self.stroke(polyline, mode: hideMode)]
                let hasReveal = stroke.revealIndex != nil, hasHide = stroke.hideIndex != nil
                Task {
                    if hasReveal { await renderer.noteBrushCoalesced(revealDrawn, as: revealMerged) }
                    if hasHide { await renderer.noteBrushCoalesced(hideDrawn, as: hideMerged) }
                }
            }
            applyLayerMaskStrokes([polyline], stroke: stroke)
        }
        layerState.maskStroke = nil
        layerState.isCanvasGestureActive = false
        endInteraction()
        flattenLayerMaskIfNeeded(stroke.layerID)
    }

    /// A second finger (a two-finger pan) or the system took the stroke: nothing committed.
    func cancelLayerMaskStroke() {
        guard layerState.maskStroke != nil else { return }
        layerState.maskStroke = nil
        layerState.isCanvasGestureActive = false
        cancelInteraction()
    }

    private func appendLayerMaskSegment(to point: PSPoint) {
        guard var stroke = layerState.maskStroke else { return }
        let settings = maskState.brush
        var points = [stroke.last, point]
        // The cursor's radius is a fraction of the canvas's longest side; in the content space it scales with it.
        var radius = settings.size
        if let map = stroke.toMask {
            points = points.map(map.apply)
            radius *= map.localScale(at: point, aspectBefore: stroke.canvasAspect, aspectAfter: stroke.maskAspect)
        }
        stroke.segments.append(BrushStroke(points: points, radius: radius, hardness: settings.hardness, mode: .add,
                                           flow: settings.flow < 0.999 ? settings.flow : nil))
        stroke.last = point
        layerState.maskStroke = stroke
        applyLayerMaskStrokes(stroke.segments, stroke: stroke)
    }

    /// The start stack with `strokes` painted: revealing adds to the reveal brush and erases the hide brush; hiding
    /// does the opposite. Applied to the dragged copy.
    private func applyLayerMaskStrokes(_ strokes: [BrushStroke], stroke: LayerMaskStroke) {
        var stack = stroke.start
        if let index = stroke.revealIndex, case .brush(var spec) = stack.components[index].kind {
            spec.strokes = stroke.revealStrokes + strokes.map { Self.stroke($0, mode: stroke.hides ? .subtract : .add) }
            stack.components[index].kind = .brush(spec)
        }
        if let index = stroke.hideIndex, case .brush(var spec) = stack.components[index].kind {
            spec.strokes = stroke.hideStrokes + strokes.map { Self.stroke($0, mode: stroke.hides ? .add : .subtract) }
            stack.components[index].kind = .brush(spec)
        }
        let id = stroke.layerID
        let edited = stack
        interactiveEdit(label: Self.layerMaskLabel) { document in
            document.applyLayerEdit(.maskStack(edited), to: id)
        }
    }

    static func isBrush(_ component: MaskComponent, mode: CombineMode) -> Bool {
        guard component.mode == mode, case .brush = component.kind else { return false }
        return true
    }

    static func brushStrokes(in stack: MaskStack, at index: Int?) -> [BrushStroke] {
        guard let index, stack.components.indices.contains(index), case .brush(let spec) = stack.components[index].kind else { return [] }
        return spec.strokes
    }

    /// The same stroke (same id) in another mode.
    static func stroke(_ stroke: BrushStroke, mode: BrushStroke.Mode) -> BrushStroke {
        var copy = stroke
        copy.mode = mode
        return copy
    }

    /// Past `BrushSpec.maxStrokes` gestures a brush becomes a raster in the mask's space, off every actor; stored
    /// with the stroke's step when nothing changed since, else as its own.
    private func flattenLayerMaskIfNeeded(_ layerID: UUID) {
        guard let layer = document.layer(id: layerID), let stack = layer.maskStack, let space = layerMaskSpace(of: layer) else { return }
        guard let index = stack.components.firstIndex(where: { component in
            if case .brush(let spec) = component.kind { return spec.needsFlatten }
            return false
        }), case .brush(let spec) = stack.components[index].kind else { return }
        let componentID = stack.components[index].id
        let side = Double(VisionPhotoServices.analysisLongestSide)
        let aspect = space.aspect
        let width = max(1, Int((aspect >= 1 ? side : side * aspect).rounded()))
        let height = max(1, Int((aspect >= 1 ? side / aspect : side).rounded()))
        let store = MaskStore(store: app.store, projectID: projectID)
        let before = document
        layerState.maskFlattenTask?.cancel()
        layerState.maskFlattenTask = Task { [weak self] in
            let flattened = try? await Task.detached(priority: .utility) { () throws -> RasterRef in
                var bytes = [UInt8](repeating: 0, count: width * height)
                BrushRaster.draw(spec.strokes, width: width, height: height, into: &bytes)
                return try store.saveRaster(bytes: bytes, width: width, height: height, origin: .brush)
            }.value
            guard let self, !Task.isCancelled, let raster = flattened else { return }
            guard var current = self.document.layer(id: layerID)?.maskStack,
                  let at = current.components.firstIndex(where: { $0.id == componentID }),
                  case .brush(let now) = current.components[at].kind, now == spec else { return }
            current.components[at].kind = .raster(raster)
            var updated = self.document
            guard case .applied = updated.applyLayerEdit(.maskStack(current), to: layerID) else { return }
            if self.document == before {
                self.amendPresent(updated)
            } else {
                self.commit(updated, label: Self.layerMaskLabel)
            }
        }
    }
}
#endif
