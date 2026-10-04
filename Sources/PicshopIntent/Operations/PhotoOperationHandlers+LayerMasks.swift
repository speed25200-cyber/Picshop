import Foundation
import PicshopCore

// W3 layer masks (D8, §8.3): add from a region, a ref or the selection, edit (combine, feather, density, expand),
// invert, enable and disable, delete, apply (the layer's pixels through `rasterizeLayers`) and paint (the canvas brush).
// Every change goes through `applyLayerEdit(.maskStack / .maskEdit / .maskEnabled)` so the D7 locks hold.
//
// Spaces (D8): a linked layer mask lives in its layer's content space, an unlinked one (and the base's) in canvas
// space; the selection lives in the output space of the layer it was made on. A region resolved on the photo
// (canvas) or on an image layer's own pixels (its content space) is carried into the target's mask space through the
// placement maps (`LayerPlacement.map`), so the mask stays on the same pixels.

/// Where a mask's coordinates live: the map from that space to the canvas (normalised), and its aspect (w/h).
struct MaskSpace {
    var toCanvas: PSHomography
    var aspect: Double

    /// The canvas itself.
    static func canvas(_ document: PhotoDocument) -> MaskSpace {
        let aspect = document.canvasSize.aspectRatio
        return MaskSpace(toCanvas: .identity, aspect: aspect.isFinite && aspect > 0 ? aspect : 1)
    }
}

extension PhotoOperationHandlers {
    // MARK: Spaces

    /// A layer's mask space: its content space when linked and not the base, else the canvas. Nil when the layer's
    /// size is unknown or degenerate.
    static func maskSpace(of layer: Layer, in document: PhotoDocument, size: PSSize?, linked: Bool = true) -> MaskSpace? {
        if layer.id == document.baseLayerID || !linked { return .canvas(document) }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        let map = LayerPlacement.map(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        return MaskSpace(toCanvas: map, aspect: size.width / size.height)
    }

    /// A stack carried from one mask space to another (D8); nil when the target's placement cannot be inverted.
    static func remap(_ stack: MaskStack, from: MaskSpace, to: MaskSpace) -> MaskStack? {
        guard let back = to.toCanvas.inverse else { return nil }
        return stack.remapped(by: from.toCanvas.then(back), aspectBefore: from.aspect, aspectAfter: to.aspect)
    }

    /// The space of the image layer whose own pixels an area was resolved on (`resolveArea(layer:)`): its content
    /// space, the canvas for the base or nil.
    static func pixelSpace(_ layerID: UUID?, in document: PhotoDocument) -> MaskSpace? {
        guard let layerID, layerID != document.baseLayerID else { return .canvas(document) }
        guard let layer = document.layer(id: layerID) else { return nil }
        return maskSpace(of: layer, in: document, size: LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize))
    }

    /// The selection as a one-component stack in `space` (it lives in the output space of the layer it was made on).
    static func selectionStack(_ selection: PhotoSelection, in document: PhotoDocument, to space: MaskSpace) -> MaskStack? {
        let from = pixelSpace(selection.layerID, in: document) ?? .canvas(document)
        return remap(MaskStack.single(MaskComponent(.raster(selection.raster))), from: from, to: space)
    }

    /// An area resolved for a target layer's mask: on the target's own pixels when it is an image layer above the
    /// photo, else on the photo; then carried into the target's mask space.
    static func layerMaskComponent(_ args: MaskAreaArgs, call: OperationCall, target: Layer, targetSpace: MaskSpace, mode: CombineMode,
                                   document: PhotoDocument, context: OperationRunContext) async -> Answered<MaskComponent> {
        let ownPixels = target.isImage && target.id != document.baseLayerID ? target.id : nil
        let outcome = await resolveArea(args, call: call, document: document, context: context, layer: ownPixels)
        guard case .area(let area) = outcome else {
            if case .answer(let result) = outcome { return .answer(result) }
            return .answer(.failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
        }
        if let coverage = await measuredCoverage(area, document: document, context: context), coverage < coverageFloor {
            return .answer(notSeen((area.region, area.label, args.target), french: context.french))
        }
        guard let from = pixelSpace(ownPixels, in: document),
              let mapped = remap(MaskStack.single(MaskComponent(area.kind, mode: mode, isInverted: area.isInverted)), from: from, to: targetSpace),
              let component = mapped.components.first else {
            return .answer(answer(context.french ? "Je ne peux pas placer ce masque sur ce calque." : "I can't place that mask on this layer.", reason: .nothingToDo))
        }
        return .value(component)
    }

    // MARK: layerMask

    static func hasLayerMask(_ layer: Layer) -> Bool { layer.maskStack != nil || layer.mask != nil }

    /// add / edit / invert / enable / disable / delete / apply / paint a layer mask.
    static func layerMask(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let action = call.args["do"]?.string ?? "add"
        let needsMask = !["add", "paint"].contains(action)
        let noMask: (Layer) -> String? = { candidate in
            guard needsMask, !hasLayerMask(candidate) else { return nil }
            let name = displayName(candidate, in: document, french: context.french)
            return context.french ? "« \(name) » n'a pas de masque de fusion : dis « ajoute un masque au calque »." : "“\(name)” has no layer mask: say “add a layer mask”."
        }
        let target: Layer
        switch pickLayer(call.args["layer"]?.string, in: document, context: context, allowBase: true, misfit: noMask) {
        case .value(let found): target = found
        case .answer(let result): return (document, result)
        }
        let name = displayName(target, in: document, french: context.french)
        let ref = layerRef(target.id, document, context)
        let size = await placementSize(of: target, in: document, context: context)
        var updated = document
        func applied(_ edits: [LayerEdit], label: String, said: String? = nil, extra: [EditorEffect] = []) -> (PhotoDocument, ExecutionResult) {
            var changed = false
            for edit in edits {
                switch updated.applyLayerEdit(edit, to: target.id, contentSize: size) {
                case .refused(let reason): return (document, refusal(reason, layer: target, document: document, context: context))
                case .unchanged: continue
                case .applied: changed = true
                }
            }
            guard changed else { return (document, info(context.french ? "Le masque est déjà ainsi." : "The mask is already like that.")) }
            var result = ExecutionResult.applied(label, effects: extra)
            if let said { result.effects.append(.message("speak:" + said)) }
            return (updated, result)
        }
        switch action {
        case "paint":
            let said = context.french ? "Peins sur la photo : blanc révèle, noir masque." : "Paint on the photo: white reveals, black hides."
            return (document, info(said, effects: [.message("paintLayerMask:\(target.id.uuidString)"), .message("speak:" + said)]))
        case "enable", "disable":
            return applied([.maskEnabled(action == "enable")], label: action == "enable" ? "Enable Layer Mask" : "Disable Layer Mask")
        case "delete":
            return applied([.maskStack(nil)], label: "Delete Layer Mask")
        case "invert":
            let inverted = !(target.maskStack?.isInverted ?? false)
            return applied([.maskEdit(.setStack(feather: nil, expand: nil, density: nil, isInverted: inverted))], label: "Invert Layer Mask")
        case "apply":
            guard target.isImage else { return (document, refusal(.notAnImageLayer, layer: target, document: document, context: context)) }
            guard LayerLockPolicy.allows(.alpha, on: target.id, in: document) else { return (document, refusal(.locked, layer: target, document: document, context: context)) }
            let raster: LayerRasterResult
            do {
                raster = try await context.services.rasterizeLayers(.layers([target.id]), in: document)
            } catch {
                if case .unsupportedOperation? = error as? PicshopError {
                    return (document, answer(context.french ? "Appliquer un masque n'est pas disponible ici." : "Applying a mask isn't available here.", reason: .unsupported))
                }
                return (document, .failed((error as? PicshopError)?.message(french: context.french) ?? error.localizedDescription))
            }
            let result = updated.applyStructureEdit(.applyMask(target.id, raster: raster.asset), rasterBounds: raster.opaqueBounds)
            switch result.outcome {
            case .refused(let reason): return (document, refusal(reason, layer: target, document: document, context: context))
            case .unchanged: return (document, info(context.french ? "Le masque est déjà appliqué." : "The mask is already applied."))
            case .applied: return (updated, .applied("Apply Layer Mask", effects: [.selectLayer(target.id)]))
            }
        default:
            break
        }
        // add and edit: the area, carried into the layer's mask space.
        guard let space = maskSpace(of: target, in: document, size: size, linked: target.isMaskLinked) else {
            return (document, answer(context.french ? "Je ne connais pas encore la taille de ce calque : peins le masque à la main." : "I don't know that layer's size yet: paint the mask by hand.",
                                     reason: .nothingToDo, effects: [.message("paintLayerMask:\(target.id.uuidString)")]))
        }
        var args = MaskAreaArgs(call.args, key: "where")
        if call.args["useSelection"]?.bool == true {
            args.region = .selection
            args.ref = nil
        }
        let feather = call.args["feather"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        let expand = call.args["expand"]?.double.map { ($0 / 100).clamped(to: -1...1) }
        let density = call.args["density"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        let shapesStack = feather != nil || expand != nil || density != nil
        if action == "edit" {
            var edits: [LayerEdit] = []
            if args.namesSomething {
                let mode = call.args["combine"]?.string.flatMap(CombineMode.init(rawValue:)) ?? .add
                switch await layerMaskComponent(args, call: call, target: target, targetSpace: space, mode: mode, document: document, context: context) {
                case .value(let component): edits.append(.maskEdit(.addComponent(component)))
                case .answer(let result): return (document, result)
                }
            }
            if shapesStack { edits.append(.maskEdit(.setStack(feather: feather, expand: expand, density: density, isInverted: nil))) }
            guard !edits.isEmpty else {
                return (document, answer(context.french ? "Que changer dans le masque ? Une zone à ajouter ou retirer, le contour progressif, la densité."
                                                        : "What should change in the mask? An area to add or remove, the feather, the density.", reason: .nothingToDo))
            }
            return applied(edits, label: "Edit Layer Mask")
        }
        // add.
        if hasLayerMask(target) {
            return (document, answer(context.french ? "« \(name) » a déjà un masque : dis « modifie le masque » ou « supprime le masque »."
                                                    : "“\(name)” already has a mask: say “edit the mask” or “delete the mask”.", reason: .nothingToDo))
        }
        var stack: MaskStack
        var usedSelection = false
        if args.namesSomething {
            switch await layerMaskComponent(args, call: call, target: target, targetSpace: space, mode: .add, document: document, context: context) {
            case .value(let component): stack = MaskStack.single(component)
            case .answer(let result): return (document, result)
            }
            usedSelection = args.region == .selection
        } else if let selection = document.selection, let carried = selectionStack(selection, in: document, to: space) {
            stack = carried
            usedSelection = true
        } else {
            // Reveal all: a mask that shows the whole layer, to paint on.
            stack = MaskStack.single(MaskComponent(.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 2, radiusY: 2, rotation: 0, feather: 0))))
        }
        if call.args["reveal"]?.bool == false { stack.isInverted = true }
        if let feather { stack.feather = feather }
        if let expand { stack.expand = expand }
        if let density { stack.density = density }
        let said = context.french ? "Masque de fusion ajouté sur « \(name) »\(ref.isEmpty ? "" : " (\(ref))")." : "Layer mask added to \(ref.isEmpty ? "“\(name)”" : ref)."
        return applied([.maskStack(stack)], label: "Add Layer Mask", said: said, extra: usedSelection ? [.message("selectionUsed")] : [])
    }
}
