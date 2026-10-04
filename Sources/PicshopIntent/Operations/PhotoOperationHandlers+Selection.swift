import Foundation
import PicshopCore

// W2 selections (§8.3, D7): select, selectionModify, selectionApply. The selection is document state (one per
// document, undoable, remapped by geometry like the masks); every change is one history step, "Selection". The
// Sélection panel calls the same handlers (`useSelection` → selectionApply), so a tap and a voice give the same
// document.

extension PhotoOperationHandlers {
    /// The history label of every selection change.
    static let selectionLabel = "Selection"

    static func noSelection(_ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        (document, answer(context.french ? "Il n'y a pas de sélection : sélectionne d'abord quelque chose." : "There's no selection: select something first.",
                          reason: .needsSelection))
    }

    // MARK: select

    /// A region → a raster (AI, the wand at a point, a colour sampled there, a parametric region rasterised), then
    /// combined into the selection (new, add, subtract, intersect) and one step appended.
    static func select(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.aiSelection) else { return notEnabled(document, context) }
        guard let layerID = document.localAdjustmentsLayerID else { return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document) }
        let rawMode = call.args["mode"]?.string ?? "new"
        var mode: CombineMode? = rawMode == "new" ? nil : CombineMode(rawValue: rawMode)
        if document.selection == nil, let wanted = mode {
            switch wanted {
            case .add: mode = nil
            case .subtract, .intersect:
                return (document, answer(context.french ? "Il n'y a pas encore de sélection à réduire : sélectionne d'abord quelque chose."
                                                        : "There's no selection to cut down yet: select something first.", reason: .nothingToDo))
            }
        }
        let area = MaskAreaArgs(call.args, key: "what")
        let outcome = await resolveArea(area, call: call, document: document, context: context)
        guard case .area(let resolved) = outcome else {
            if case .answer(let result) = outcome { return (document, result) }
            return (document, .failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
        }
        // A raster to combine: AI and wand results are one already; parametric regions are rasterised at the working size.
        let raster: RasterRef
        var coverage = resolved.coverage
        if case .raster(let made) = resolved.kind, !resolved.isInverted {
            raster = made
        } else {
            do {
                var shapedKind = resolved.kind
                if hasShape(call.args) { shapedKind = shaped(shapedKind, call.args) }
                let result = try await context.services.rasterize(MaskStack.single(MaskComponent(shapedKind, isInverted: resolved.isInverted)), in: document)
                raster = result.raster
                coverage = result.coverage
            } catch {
                return (document, failure(error, area: (resolved.region, resolved.label, area.target), call: call, document: document, context: context))
            }
        }
        if let coverage, coverage < coverageFloor {
            return (document, notSeen((resolved.region, resolved.label, area.target ?? (resolved.region == .color ? area.color : nil)), french: context.french))
        }
        var selection: PhotoSelection
        do {
            selection = try await context.services.combineSelection(document.selection, with: raster, mode: mode, in: document)
        } catch {
            return (document, failure(error, area: (resolved.region, resolved.label, area.target), call: call, document: document, context: context))
        }
        selection.layerID = layerID
        let label = stepLabel(resolved, area: area)
        // The service carries the current steps over; a new selection starts its own list.
        let earlier = mode == nil ? [] : selection.steps
        selection.steps = Array((earlier + [SelectionStep(resolved.source, mode: mode, label: label)]).suffix(PhotoSelection.maxSteps))
        var updated = document
        updated.setSelection(selection)
        var result = ExecutionResult.applied(selectionLabel)
        if resolved.isApproximate {
            result.effects.append(.message("speak:" + (context.french ? "Sélection approximative : affine-la au pinceau." : "The selection is approximate: refine it with the brush.")))
        }
        return (updated, result)
    }

    /// The label a step keeps: the object noun, the person, the colour, the mask ref.
    static func stepLabel(_ area: MaskArea, area args: MaskAreaArgs) -> String? {
        switch area.source {
        case .object: return area.label ?? args.target.map(canonicalNoun)
        case .person: return area.label
        case .facePart: return area.label ?? area.region?.rawValue
        case .colorRange: return area.label ?? args.color
        case .luminanceRange, .region: return area.region?.rawValue
        case .mask: return args.ref ?? area.label
        default: return nil
        }
    }

    // MARK: selectionModify

    /// Deselect; invert, grow, shrink, feather, smooth (Select › Modify); or Select & Mask (`refine` and its
    /// fields, merged with the stored refinement; `smooth` and `feather` are refinement fields then).
    static func selectionModify(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.aiSelection) else { return notEnabled(document, context) }
        let args = call.args
        if args["deselect"]?.bool == true {
            guard document.selection != nil else {
                return (document, info(context.french ? "Il n'y a déjà rien de sélectionné." : "Nothing is selected already."))
            }
            var updated = document
            updated.setSelection(nil)
            return (updated, .applied(selectionLabel))
        }
        guard var selection = document.selection else { return noSelection(document, context) }
        let refining = ["refine", "radius", "shiftEdge", "contrast", "decontaminate"].contains { args[$0] != nil && args[$0] != .bool(false) }
        let longest = longestSide(document)
        do {
            if args["invert"]?.bool == true {
                selection = try await context.services.modifySelection(selection, .invert, in: document)
                selection.steps.append(SelectionStep(.invert))
            }
            if let pixels = args["grow"]?.double {
                selection = try await context.services.modifySelection(selection, .grow(pixels: pixels), in: document)
                selection.steps.append(SelectionStep(.modify, label: "grow"))
            }
            if let pixels = args["shrink"]?.double {
                selection = try await context.services.modifySelection(selection, .shrink(pixels: pixels), in: document)
                selection.steps.append(SelectionStep(.modify, label: "shrink"))
            }
            if refining {
                var refinement = args["refine"]?.bool == true ? (selection.refinement ?? .automatic) : (selection.refinement ?? SelectionRefinement())
                if let radius = args["radius"]?.double { refinement.radius = (radius / 100).clamped(to: 0...1) }
                if let smooth = args["smooth"]?.double { refinement.smooth = (smooth / 100).clamped(to: 0...1) }
                // Pixels at full resolution → σ = feather × 0.01 × longest side.
                if let feather = args["feather"]?.double { refinement.feather = (feather / max(1, 0.01 * longest)).clamped(to: 0...1) }
                if let contrast = args["contrast"]?.double { refinement.contrast = (contrast / 100).clamped(to: 0...1) }
                if let shift = args["shiftEdge"]?.double { refinement.shiftEdge = (shift / 100).clamped(to: -1...1) }
                if let decontaminate = args["decontaminate"]?.double { refinement.decontaminate = (decontaminate / 100).clamped(to: 0...1) }
                selection = try await context.services.refineSelection(selection, refinement, in: document)
                selection.refinement = refinement
                selection.steps.append(SelectionStep(.refine))
            } else {
                if let smooth = args["smooth"]?.double {
                    selection = try await context.services.modifySelection(selection, .smooth((smooth / 100).clamped(to: 0...1)), in: document)
                    selection.steps.append(SelectionStep(.modify, label: "smooth"))
                }
                if let pixels = args["feather"]?.double, pixels > 0 {
                    selection = try await context.services.modifySelection(selection, .feather(pixels: pixels), in: document)
                    selection.steps.append(SelectionStep(.modify, label: "feather"))
                }
            }
        } catch {
            return (document, failure(error, area: (.selection, nil, nil), call: call, document: document, context: context))
        }
        guard selection != document.selection else {
            return (document, info(context.french ? "La sélection est déjà ainsi." : "The selection is already like that."))
        }
        selection.steps = Array(selection.steps.suffix(PhotoSelection.maxSteps))
        var updated = document
        updated.setSelection(selection)
        return (updated, .applied(selectionLabel))
    }

    /// The base photo's longest side in pixels (the selection's full-resolution unit).
    static func longestSide(_ document: PhotoDocument) -> Double {
        let size = document.baseLayer?.imageAsset?.pixelSize ?? document.canvasSize
        return max(1, max(size.width, size.height))
    }

    // MARK: selectionApply

    /// « Utiliser la sélection pour »: a local adjustment (or a mask with neutral dials), erase, fill (a new layer
    /// through the selection), recolour, blur, cut out (with the decontamination), generate. A moved selection is
    /// baked first (D7); the selection is cleared afterwards unless `keep` (kept by default for adjust, mask,
    /// recolour and blur).
    static func selectionApply(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.aiSelection) else { return notEnabled(document, context) }
        guard let selection = document.selection else { return noSelection(document, context) }
        guard let use = call.args["use"]?.string else {
            return (document, answer(context.french ? "Que faire de la sélection ?" : "What should the selection be used for?", reason: .nothingToDo))
        }
        let keep = call.args["keep"]?.bool ?? !["erase", "fill", "cutout", "generate"].contains(use)
        var updated = document
        var label: String
        switch use {
        case "adjust", "mask":
            guard FeatureFlags.isOn(.masks) else { return notEnabled(document, context) }
            guard document.canAddLocalAdjustment else {
                return (document, answer(context.french ? "Il y a déjà 16 masques : supprime-en un." : "There are already 16 masks: delete one.", reason: .tooMany))
            }
            let adjustment = LocalAdjustment(region: .selection, stack: MaskStack.single(MaskComponent(.raster(selection.raster))))
            updated.setLocalAdjustment(adjustment, label: maskLabel(adjustment))
            if use == "adjust" {
                var effect = call
                if effect.args["parameter"] == nil { effect.args["parameter"] = .string(AdjustmentParameter.exposure.rawValue) }
                switch effectEdits(effect, on: adjustment, context: context) {
                case .value(let edits): for edit in edits { _ = updated.applyLocalEdit(edit, to: adjustment.id) }
                case .answer(let result): return (document, result)
                }
            }
            label = maskLabel(updated.localAdjustment(id: adjustment.id) ?? adjustment)
        default:
            // The legacy executors take an aligned mask: a selection a crop moved is baked first.
            var mask = selection.mask
            if !selection.isAligned {
                do {
                    mask = try await context.services.rasterize(MaskStack.single(MaskComponent(.raster(selection.raster))), in: document).raster.maskReference
                } catch {
                    return (document, failure(error, area: (.selection, nil, nil), call: call, document: document, context: context))
                }
            }
            guard let baseID = document.baseLayerID else { return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document) }
            switch use {
            case "erase":
                updated.apply(.removeObject(mask), to: baseID)
                label = "Erase Selection"
            case "fill":
                guard let name = call.args["color"]?.string, let color = PSColor.named(name) ?? PSColor(hex: name) else {
                    return (document, answer(context.french ? "Remplir de quelle couleur ?" : "Fill with which colour?", reason: .nothingToDo))
                }
                let layer = Layer(name: "Remplissage", content: .fill(color), mask: mask)
                updated.addLayer(layer)
                if let base = updated.index(of: baseID) { updated.moveLayer(id: layer.id, to: base + 1) }
                updated.selectedLayerID = layer.id
                label = "Fill Selection"
            case "recolor":
                guard let name = call.args["color"]?.string, let color = PSColor.named(name) ?? PSColor(hex: name) else {
                    return (document, answer(context.french ? "Quelle couleur ?" : "Which colour?", reason: .nothingToDo))
                }
                updated.apply(.recolor(mask, color, strength: 0.9), to: baseID)
                label = "Recolor Selection"
            case "blur":
                let amount = ((call.args["amount"]?.double).map { abs($0) / 100 } ?? 0.6).clamped(to: 0.05...1)
                updated.apply(.blurRegion(mask, amount: amount), to: baseID)
                label = "Blur Selection"
            case "cutout":
                var cut = mask
                if let decontaminate = selection.refinement?.decontaminate, decontaminate > 0 { cut.decontaminate = decontaminate }
                updated.apply(.removeBackground(cut), to: baseID)
                label = "Cut Out Selection"
            case "generate":
                guard let prompt = call.args["prompt"]?.string, !prompt.isEmpty else {
                    return (document, answer(context.french ? "Que mettre à la place ?" : "What should go there?", reason: .nothingToDo))
                }
                updated.apply(.generativeFill(mask, prompt: prompt), to: baseID)
                label = "Generate “\(prompt)”"
            default:
                return (document, answer(context.french ? "Je ne sais pas faire ça avec la sélection." : "I can't do that with the selection.", reason: .unsupported))
            }
        }
        if !keep { updated.setSelection(nil) }
        return (updated, .applied(label))
    }
}
