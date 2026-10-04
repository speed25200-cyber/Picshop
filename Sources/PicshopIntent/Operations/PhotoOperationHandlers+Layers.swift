import Foundation
import PicshopCore

// W3 layer operations (§8.3): layer via copy and cut, fill and adjustment layers, fill edits, clipping, groups, merges,
// transform, properties, photo layers and the export sheet. Every change goes through `applyLayerEdit` and
// `applyStructureEdit` (D7, D8, D17), the same path as the Layers column, so a voice edit and a tap give the same
// document, the locks refuse with the D7 message and the structure edits number the layers they create (D19).
//
// Layer resolution (§8.3): a `ref` → `LiveLayerLines.layer`; no ref → the selected layer when it fits the operation,
// else the only candidate, else « Quel calque ? Dis i1, j1… ou touche-le dans la colonne. ». An unknown ref lists the
// refs that exist, so the model corrects itself in one round. History labels are English (the other labels' rule);
// the strings catalog shows them in French.

extension PhotoOperationHandlers {
    // MARK: Shared: gates, layers, answers

    /// The flags of a W3 operation (OperationGate): « Pas encore activé sur cet iPhone. » when one is off.
    static func layerGate(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult)? {
        OperationGate.isEnabled(call.id) ? nil : notEnabled(document, context)
    }

    /// A layer's name as said in a reply: its name, « Photo base » for the base.
    static func displayName(_ layer: Layer, in document: PhotoDocument, french: Bool) -> String {
        if layer.id == document.baseLayerID { return french ? "Photo base" : "Base photo" }
        let trimmed = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LiveLayerLines.defaultName(layer, fr: french) : trimmed
    }

    /// The ref the layers line prints for a layer ("i2"), "" when it has none.
    static func layerRef(_ id: UUID, _ document: PhotoDocument, _ context: OperationRunContext) -> String {
        LiveLayerLines.ref(of: id, in: document, scene: context.intent.scene) ?? ""
    }

    /// « Il n'y a pas de calque i7. Calques : i1, i2, j1. » (unknown_ref), so one round repairs it.
    static func unknownLayer(_ raw: String, _ document: PhotoDocument, _ context: OperationRunContext, kinds: Set<RefKind>? = nil) -> ExecutionResult {
        let list = LiveLayerLines.existingRefs(in: document, scene: context.intent.scene, kinds: kinds)
        let said = raw.trimmingCharacters(in: .whitespaces)
        if list.isEmpty {
            return answer(context.french ? "Il n'y a pas de calque \(said) : la photo n'a pas d'autre calque." : "There is no layer \(said): the photo has no other layer.",
                          reason: .unknownRef)
        }
        return answer(context.french ? "Il n'y a pas de calque \(said). Calques : \(list)." : "There is no layer \(said). Layers: \(list).", reason: .unknownRef)
    }

    /// « Quel calque ? » (needs_selection).
    static func whichLayer(_ context: OperationRunContext) -> ExecutionResult {
        answer(context.french ? "Quel calque ? Dis i1, j1… ou touche-le dans la colonne." : "Which layer? Say i1, j1… or tap it in the column.",
               reason: .needsSelection)
    }

    /// The layer a call names (§8.3). `misfit` says why a layer does not fit the operation (nil: it fits); a ref that
    /// does not fit answers with it, no ref skips the layers that do not fit. The base photo is never picked unless
    /// `allowBase`; a newer build's content never is.
    static func pickLayer(_ raw: String?, in document: PhotoDocument, context: OperationRunContext, allowBase: Bool = false,
                          misfit: ((Layer) -> String?)? = nil) -> Answered<Layer> {
        let baseID = document.baseLayerID
        if let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let layer = LiveLayerLines.layer(ref: raw, in: document, scene: context.intent.scene) else {
                return .answer(unknownLayer(raw, document, context))
            }
            if !allowBase, layer.id == baseID {
                return .answer(answer(PhotoDocument.refusalMessage(.baseLayer, layerName: nil, french: context.french), reason: .nothingToDo))
            }
            if let message = misfit?(layer) { return .answer(answer(message, reason: .nothingToDo)) }
            return .value(layer)
        }
        func fits(_ layer: Layer) -> Bool {
            if case .unsupported = layer.content { return false }
            if layer.id == baseID, !allowBase { return false }
            return misfit?(layer) == nil
        }
        if let selected = document.selectedLayer, fits(selected) { return .value(selected) }
        // One row per table bundle (D1).
        var seenBundles: Set<UUID> = []
        let candidates = document.layers.filter { layer in
            guard fits(layer) else { return false }
            if let bundle = layer.group?.id { return seenBundles.insert(bundle).inserted }
            return true
        }
        if candidates.count == 1 { return .value(candidates[0]) }
        if candidates.isEmpty, document.layers.allSatisfy({ $0.id == baseID }) {
            return .answer(answer(context.french ? "La photo n'a pas encore d'autre calque : ajoute un texte, une forme, une image ou un calque de remplissage."
                                                 : "The photo has no other layer yet: add a text, a shape, a picture or a fill layer.", reason: .nothingToDo))
        }
        if candidates.isEmpty, let selected = document.selectedLayer, let message = misfit?(selected) {
            return .answer(answer(message, reason: .nothingToDo))
        }
        return .answer(whichLayer(context))
    }

    /// A refused layer edit, said with the D7 message and coded for the model (never `unsupported`).
    static func refusal(_ refusal: LayerEditRefusal, layer: Layer?, document: PhotoDocument, context: OperationRunContext) -> ExecutionResult {
        let name = layer.map { displayName($0, in: document, french: context.french) }
        let message = PhotoDocument.refusalMessage(refusal, layerName: name, french: context.french)
        let reason: ExecutionReason
        switch refusal {
        case .locked: reason = .locked
        case .notFound: reason = .unknownRef
        case .tooManyLayers: reason = .tooMany
        case .emptyRegion: reason = .notFound
        case .baseLayer, .nestedGroup, .notAGroup, .notAnImageLayer, .notApplicable, .noValidClipBase: reason = .nothingToDo
        }
        return answer(message, reason: reason)
    }

    /// A new layer: its history label, its selection and « Calque « Sujet » créé (i2). » / "Made layer i2.".
    static func madeLayer(_ id: UUID, label: String, in document: PhotoDocument, context: OperationRunContext) -> ExecutionResult {
        let ref = layerRef(id, document, context)
        let name = document.layer(id: id).map { displayName($0, in: document, french: context.french) } ?? ""
        let said = context.french ? "Calque « \(name) » créé\(ref.isEmpty ? "" : " (\(ref))")." : "Made layer \(ref.isEmpty ? "“\(name)”" : ref)."
        return .applied(label, effects: [.selectLayer(id), .message("speak:" + said)])
    }

    /// « Le calque est déjà ainsi. » (info, nothing changed).
    static func alreadySo(_ context: OperationRunContext) -> ExecutionResult {
        info(context.french ? "Le calque est déjà ainsi." : "The layer is already like that.")
    }

    /// A layer's content size where it is known (Core for images, shapes, fills, adjustments and groups; L2 for text;
    /// else an estimate from the text's size), for placement maths.
    static func placementSize(of layer: Layer, in document: PhotoDocument, context: OperationRunContext) async -> PSSize? {
        if let size = LayerPlacement.contentSize(of: layer, canvasSize: document.canvasSize), !size.isEmpty { return size }
        if let measured = await context.services.contentSize(of: layer.id, in: document), !measured.isEmpty { return measured }
        return estimatedTextSize(layer, canvas: document.canvasSize)
    }

    /// A text layer's size without font metrics: its font size (relativeSize of the canvas height), about 0.55 em per
    /// character, wrapped at its maximum width.
    static func estimatedTextSize(_ layer: Layer, canvas: PSSize) -> PSSize? {
        guard let element = layer.textElement, canvas.width > 0, canvas.height > 0 else { return nil }
        let em = max(2, element.relativeSize * canvas.height)
        let natural = Double(max(1, element.text.count)) * 0.55 * em
        let limit = max(em, element.maxRelativeWidth * canvas.width)
        let lines = max(1, (natural / limit).rounded(.up))
        return PSSize(width: min(natural, limit), height: em * 1.25 * lines)
    }

    /// A colour argument (a name or #RRGGBB).
    static func colorValue(_ value: OpValue?) -> PSColor? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return PSColor.named(text) ?? PSColor(hex: text)
    }

    /// The same colour, fully transparent (a gradient's « vers transparent » end).
    static func clear(_ color: PSColor) -> PSColor {
        PSColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
    }

    /// The layers a `refs` list names, in document order (a bundle ref stands for its top member), and the refs that
    /// name nothing.
    static func layers(named refs: OpValue?, in document: PhotoDocument, context: OperationRunContext) -> (layers: [Layer], unknown: [String]) {
        guard case .list(let items)? = refs else { return ([], []) }
        var ids: Set<UUID> = []
        var unknown: [String] = []
        for item in items {
            guard let raw = item.string else { continue }
            if let layer = LiveLayerLines.layer(ref: raw, in: document, scene: context.intent.scene) { ids.insert(layer.id) } else { unknown.append(raw) }
        }
        return (document.layers.filter { ids.contains($0.id) }, unknown)
    }

    // MARK: addImageLayer

    /// The photo picker opens (`pickImageLayer`); the fit and the position the person said ride along
    /// (`pickImageLayerOptions:{"fit":…}`), and the session adds the layer with `addImage` (D17).
    static func addImageLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        guard document.layerUnitCount < PhotoDocument.maxLayers else { return (document, refusal(.tooManyLayers, layer: nil, document: document, context: context)) }
        var effects: [EditorEffect] = [.message("pickImageLayer")]
        var options: [String: JSONValue] = [:]
        if let fit = call.args["fit"]?.string, ImageLayerFit(rawValue: fit) != nil { options["fit"] = .string(fit) }
        if let position = call.args["position"]?.string { options["position"] = .string(position) }
        if !options.isEmpty { effects.append(.message("pickImageLayerOptions:" + JSONValue.object(options).serialized())) }
        let said = context.french ? "Choisis la photo à ajouter en calque." : "Pick the photo to add as a layer."
        return (document, ExecutionResult(outcome: .info(message: said), effects: effects + [.message("speak:" + said)]))
    }

    // MARK: layerVia

    /// Layer via copy or cut (D17): the area, resolved in the source's content space (D8), on a new layer above it.
    static func layerVia(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let cut = call.args["mode"]?.string == "cut"
        let source: Layer
        if let raw = call.args["layer"]?.string {
            switch pickLayer(raw, in: document, context: context, allowBase: true, misfit: { $0.isImage ? nil : notAnImage($0, document, context) }) {
            case .value(let layer): source = layer
            case .answer(let result): return (document, result)
            }
        } else {
            guard let id = document.activeImageLayerID, let layer = document.layer(id: id) else {
                return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document, reason: .nothingToDo)
            }
            source = layer
        }
        var args = MaskAreaArgs(call.args, key: "where")
        if call.args["useSelection"]?.bool == true || (!args.namesSomething && document.selection != nil) {
            args.region = .selection
            args.ref = nil
        }
        guard args.namesSomething else {
            return (document, answer(context.french ? "Quelle zone ? Nomme-la (« le sujet », « le ciel ») ou sélectionne-la." : "Which area? Name it (“the subject”, “the sky”) or select it.",
                                     reason: .needsSelection, effects: [.message("selectRegion")]))
        }
        let ownPixels = source.id == document.baseLayerID ? nil : source.id
        let outcome = await resolveArea(args, call: call, document: document, context: context, layer: ownPixels)
        guard case .area(let area) = outcome else {
            if case .answer(let result) = outcome { return (document, result) }
            return (document, .failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
        }
        if let coverage = await measuredCoverage(area, document: document, context: context), coverage < coverageFloor {
            return (document, notSeen((area.region, area.label, args.target), french: context.french))
        }
        let region = MaskStack.single(MaskComponent(area.kind, isInverted: area.isInverted))
        let name = call.args["name"]?.string
        var updated = document
        let edit: LayerStructureEdit = cut ? .viaCut(source: source.id, region: region, name: name) : .viaCopy(source: source.id, region: region, name: name)
        let result = updated.applyStructureEdit(edit)
        switch result.outcome {
        case .refused(let reason): return (document, refusal(reason, layer: source, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: break
        }
        let label = cut ? "Layer via Cut" : "Layer via Copy"
        var made = result.layerID.map { madeLayer($0, label: label, in: updated, context: context) } ?? .applied(label)
        if area.region == .selection { made.effects.append(.message("selectionUsed")) }
        return (updated, made)
    }

    /// « Ça marche seulement sur un calque photo. » with the layer's name.
    static func notAnImage(_ layer: Layer, _ document: PhotoDocument, _ context: OperationRunContext) -> String {
        PhotoDocument.refusalMessage(.notAnImageLayer, layerName: displayName(layer, in: document, french: context.french), french: context.french)
    }

    // MARK: Fill layers

    /// A solid colour or a two-colour gradient layer (D9), above the selected layer, on top, or below/above a ref;
    /// masked by the selection when asked (or when there is one and no position). One step.
    static func addFillLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let gradient = call.args["fill"]?.string == "gradient"
        let color = colorValue(call.args["color"]) ?? (gradient ? .black : .white)
        let content: Layer.Content
        if gradient {
            let style = call.args["style"]?.string.flatMap(GradientFill.Style.init(rawValue:)) ?? .linear
            let end = colorValue(call.args["color2"]) ?? clear(color)
            content = .gradientFill(GradientFill.twoColor(color, end, style: style, angle: call.args["angle"]?.double ?? 90).normalized)
        } else {
            content = .fill(color)
        }
        var layer = Layer(name: gradient ? (context.french ? "Dégradé" : "Gradient") : (context.french ? "Couleur unie" : "Solid Color"), content: content)
        if let opacity = call.args["opacity"]?.double { layer.opacity = (opacity / 100).clamped(to: 0...1) }
        if let blend = call.args["blend"]?.string.flatMap(BlendMode.init(rawValue:)) { layer.blendMode = blend }
        // The placement: a position (with a ref, else the selected layer), else above the ref or the selected layer.
        let position = call.args["position"]?.string
        var anchor: Layer?
        if let raw = call.args["ref"]?.string {
            guard let found = LiveLayerLines.layer(ref: raw, in: document, scene: context.intent.scene) else { return (document, unknownLayer(raw, document, context)) }
            anchor = found
        }
        let placement: LayerPlacementSpec
        switch position {
        case "top"?:
            placement = .top
        case "below"?:
            guard let id = anchor?.id ?? document.selectedLayer?.id else { return (document, whichLayer(context)) }
            if id == document.baseLayerID {
                return (document, answer(context.french ? "Rien ne peut aller sous la photo de base : dis « au-dessus » pour le poser juste dessus."
                                                        : "Nothing can go below the base photo: say “above” to put it just over it.", reason: .nothingToDo))
            }
            placement = .below(id)
        case "above"?:
            guard let id = anchor?.id ?? document.selectedLayer?.id else { return (document, whichLayer(context)) }
            placement = .above(id)
        default:
            placement = anchor.map { .above($0.id) } ?? .aboveSelected
        }
        // The selection as the layer's mask (a fill's content space is the canvas).
        let useSelection = call.args["useSelection"]?.bool ?? (position == nil && anchor == nil && document.selection != nil)
        if useSelection {
            guard let selection = document.selection else {
                return (document, answer(context.french ? "Il n'y a pas de sélection : sélectionne d'abord la zone." : "There's no selection: select the area first.",
                                         reason: .needsSelection))
            }
            guard let stack = selectionStack(selection, in: document, to: .canvas(document)) else {
                return (document, answer(context.french ? "Je ne peux pas reporter la sélection sur ce calque." : "I can't carry the selection onto that layer.", reason: .nothingToDo))
            }
            layer.maskStack = stack
        }
        var updated = document
        let result = updated.applyStructureEdit(.add(layer, placement: placement))
        switch result.outcome {
        case .refused(let reason): return (document, refusal(reason, layer: anchor, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: break
        }
        var made = madeLayer(result.layerID ?? layer.id, label: gradient ? "Gradient Fill Layer" : "Fill Layer", in: updated, context: context)
        if case .below(let kept) = placement {
            // A backdrop slid under a layer (D21 productPhoto: « fond blanc sous le produit »): that layer stays the one
            // being worked on, so the next step (autoTone on the product) lands on it.
            updated.selectedLayerID = kept
            made.effects = made.effects.map { effect in
                if case .selectLayer = effect { return .selectLayer(kept) }
                return effect
            }
        }
        if useSelection { made.effects.append(.message("selectionUsed")) }
        return (updated, made)
    }

    /// The fill layer's colour or gradient (D9): a colour on a gradient replaces its first stop and `color2` its last;
    /// a gradient field on a solid fill turns it into a two-stop gradient from its colour to clear.
    static func fillLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let layer: Layer
        switch pickLayer(call.args["ref"]?.string, in: document, context: context, misfit: { candidate in
            candidate.isFill ? nil : (context.french ? "« \(displayName(candidate, in: document, french: true)) » n'est pas un calque de remplissage."
                                                     : "“\(displayName(candidate, in: document, french: false))” is not a fill layer.")
        }) {
        case .value(let found): layer = found
        case .answer(let result): return (document, result)
        }
        let args = call.args
        let gradientKeys = ["color2", "stops", "style", "angle", "scale", "center", "reverse", "dither"]
        let edit: LayerEdit
        switch layer.content {
        case .fill(let current) where !gradientKeys.contains(where: { args[$0] != nil }):
            guard let color = colorValue(args["color"]) else {
                return (document, answer(context.french ? "Quelle couleur ?" : "Which colour?", reason: .nothingToDo))
            }
            if color == current { return (document, alreadySo(context)) }
            edit = .solidFill(color)
        case .fill(let current):
            let start = colorValue(args["color"]) ?? current
            var gradient = GradientFill.twoColor(start, colorValue(args["color2"]) ?? clear(start))
            guard edited(&gradient, args) else { return (document, badStops(context)) }
            edit = .gradient(gradient)
        case .gradientFill(var gradient):
            if let color = colorValue(args["color"]), !gradient.stops.isEmpty { gradient.stops[0].color = color }
            if let color = colorValue(args["color2"]), !gradient.stops.isEmpty { gradient.stops[gradient.stops.count - 1].color = color }
            guard edited(&gradient, args) else { return (document, badStops(context)) }
            edit = .gradient(gradient)
        case .image, .text, .shape, .adjustment, .group, .unsupported:
            return (document, answer(context.french ? "Ce n'est pas un calque de remplissage." : "That is not a fill layer.", reason: .nothingToDo))
        }
        var updated = document
        switch updated.applyLayerEdit(edit, to: layer.id) {
        case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: return (updated, .applied("Edit Fill Layer"))
        }
    }

    /// The gradient fields of a call (style, angle, scale, centre, reverse, dither, stops); false when `stops` cannot
    /// be read.
    static func edited(_ gradient: inout GradientFill, _ args: [String: OpValue]) -> Bool {
        if let style = args["style"]?.string.flatMap(GradientFill.Style.init(rawValue:)) { gradient.style = style }
        if let angle = args["angle"]?.double { gradient.angle = angle }
        if let scale = args["scale"]?.double { gradient.scale = scale.clamped(to: 10...150) }
        if let center = args["center"].flatMap(normalizedPoint) { gradient.center = center }
        if let reverse = args["reverse"]?.bool { gradient.reverse = reverse }
        if let dither = args["dither"]?.bool { gradient.dither = dither }
        if case .list(let items)? = args["stops"] {
            guard let stops = gradientStops(items.compactMap(\.string)) else { return false }
            gradient.stops = stops
        }
        gradient = gradient.normalized
        return true
    }

    /// ["red@0", "blue@100"] (or colours alone, spread evenly) → 2…8 stops; nil when a colour or a place is unreadable.
    static func gradientStops(_ texts: [String]) -> [GradientStop]? {
        guard (2...8).contains(texts.count) else { return nil }
        var stops: [GradientStop] = []
        for (index, text) in texts.enumerated() {
            let parts = text.split(separator: "@", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, let color = PSColor.named(name) ?? PSColor(hex: name) else { return nil }
            var location = Double(index) / Double(texts.count - 1)
            if parts.count == 2 {
                guard let percent = Double(parts[1].replacingOccurrences(of: "%", with: "")), percent.isFinite else { return nil }
                location = (percent / 100).clamped(to: 0...1)
            }
            stops.append(GradientStop(location: location, color: color))
        }
        return stops
    }

    static func badStops(_ context: OperationRunContext) -> ExecutionResult {
        answer(context.french ? "Je n'ai pas compris les couleurs du dégradé : donne 2 à 8 couleurs, par exemple « rouge@0, bleu@100 »."
                              : "I couldn't read the gradient's colours: give 2 to 8, such as “red@0, blue@100”.", reason: .nothingToDo)
    }

    // MARK: Adjustment layers

    /// A tone or colour edit on its own layer (D9): the layer is created neutral with its kind and name, the matching
    /// W1/W2 handler writes into it (`targetLayerID`), then its clip, opacity, blend and mask. One document result,
    /// one undo step « Calque de réglage : Courbes ».
    static func addAdjustmentLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        if call.args["parameter"]?.string == AdjustmentParameter.vignette.rawValue {
            return (document, answer(context.french ? "Le vignettage se règle sur la photo, pas dans un calque de réglage : dis « ajoute un vignettage »."
                                                    : "Vignette is set on the photo, not in an adjustment layer: say “add a vignette”.", reason: .nothingToDo))
        }
        guard let kind = call.args["kind"]?.string.flatMap(AdjustmentLayerKind.init(rawValue:)) else {
            return (document, answer(context.french ? "Quel réglage ? Lumière, courbes, niveaux, TSL, étalonnage, LUT ou look." : "Which adjustment? Light, curves, levels, HSL, color grade, LUT or look.",
                                     reason: .nothingToDo))
        }
        // A LUT layer needs an imported LUT (the requirement « importedLUT »).
        let lut = kind == .lut ? document.layers.lazy.compactMap({ lastLUT($0.edits) }).first : nil
        if kind == .lut, lut == nil {
            return (document, answer(context.french ? "Il n'y a pas de LUT importé : importe-en un dans Couleur › LUT." : "There is no imported LUT: import one in Color › LUT.",
                                     reason: .nothingToDo))
        }
        var layer = Layer(name: context.french ? kind.frenchName : kind.englishName, content: .adjustment(.neutral), recipeKind: kind)
        if let opacity = call.args["opacity"]?.double { layer.opacity = (opacity / 100).clamped(to: 0...1) }
        if let blend = call.args["blend"]?.string.flatMap(BlendMode.init(rawValue:)) { layer.blendMode = blend }
        var updated = document
        let created = updated.applyStructureEdit(.add(layer, placement: .aboveSelected))
        switch created.outcome {
        case .refused(let reason): return (document, refusal(reason, layer: nil, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: break
        }
        let id = created.layerID ?? layer.id
        var inner = context
        inner.targetLayerID = id
        let args = call.args
        // 2. The recipe, through the W1 and W2 handlers writing into the new layer.
        switch kind {
        case .light:
            if let raw = args["parameter"]?.string, let parameter = AdjustmentParameter(rawValue: raw), parameter != .vignette {
                let amount = ((args["amount"]?.double ?? 30) / 100).clamped(to: -1...1)
                let value = amount >= 0 ? amount * parameter.range.upperBound : -amount * parameter.range.lowerBound
                _ = updated.applyLayerEdit(.adjustments(Adjustments([parameter: value.clamped(to: parameter.range)])), to: id)
            }
        case .curves:
            if let preset = args["preset"] {
                let strength = args["amount"]?.double.map { abs($0) } ?? 50
                let step = curves(OperationCall("curves", args: ["preset": preset, "amount": .number(strength)]), updated, inner)
                if step.1.outcome.isSuccess { updated = step.0 }
            }
        case .levels:
            if args["auto"]?.bool == true {
                let step = await autoTone(OperationCall("autoTone", args: ["amount": .number(100)]), updated, inner)
                if step.1.outcome.isSuccess { updated = step.0 }
            }
        case .hsl:
            if let band = args["band"] {
                var hslArgs: [String: OpValue] = ["band": band, "amountMode": .string("absolute")]
                for key in ["hue", "saturation", "luminance"] { if let value = args[key] { hslArgs[key] = value } }
                let step = hsl(OperationCall("hsl", args: hslArgs), updated, inner)
                if step.1.outcome.isSuccess { updated = step.0 }
            }
        case .colorGrade:
            for range in ["shadows", "midtones", "highlights"] {
                guard let color = args[range] else { continue }
                var gradeArgs: [String: OpValue] = ["range": .string(range), "color": color]
                if let amount = args["amount"]?.double { gradeArgs["amount"] = .number(abs(amount)) }
                let step = colorGrade(OperationCall("colorGrade", args: gradeArgs), updated, inner)
                if step.1.outcome.isSuccess { updated = step.0 }
            }
        case .lut:
            if let lut {
                let intensity = ((args["intensity"]?.double ?? 100) / 100).clamped(to: 0...1)
                updated.update(layerID: id) { $0.edits.setColor(.lut(LUTReference(relativePath: lut.relativePath, title: lut.title, intensity: intensity))) }
            }
        case .look:
            if let raw = args["look"]?.string, let look = FilterPreset(rawValue: raw) {
                let intensity = ((args["intensity"]?.double ?? 100) / 100).clamped(to: 0...1)
                updated.apply(.look(look, intensity: intensity), to: id)
            }
        }
        // 3. Clip, mask.
        if args["clip"]?.bool == true {
            if case .refused(let reason) = updated.applyLayerEdit(.clipped(true), to: id) {
                return (document, refusal(reason, layer: updated.layer(id: id), document: updated, context: context))
            }
        }
        var maskArgs = MaskAreaArgs(args, key: "where")
        if args["useSelection"]?.bool == true {
            maskArgs.region = .selection
            maskArgs.ref = nil
        }
        if maskArgs.namesSomething {
            let outcome = await resolveArea(maskArgs, call: call, document: document, context: context, layer: nil)
            guard case .area(let area) = outcome else {
                if case .answer(let result) = outcome { return (document, result) }
                return (document, .failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
            }
            if let coverage = await measuredCoverage(area, document: document, context: context), coverage < coverageFloor {
                return (document, notSeen((area.region, area.label, maskArgs.target), french: context.french))
            }
            // An adjustment layer's content space is the canvas: the area (canvas) is its mask as it is.
            _ = updated.applyLayerEdit(.maskStack(MaskStack.single(MaskComponent(area.kind, isInverted: area.isInverted))), to: id)
        }
        updated.selectedLayerID = id
        var made = madeLayer(id, label: "Adjustment Layer: " + kind.englishName, in: updated, context: context)
        if updated.layer(id: id).map(isNeutralAdjustment) == true {
            let ref = layerRef(id, updated, context)
            let hint = context.french ? "Règle-le dans l'inspecteur, ou dis par exemple « plus de contraste sur \(ref) »."
                                      : "Set it in the inspector, or say for example “more contrast on \(ref)”."
            made.effects.append(.message("speak:" + hint))
        }
        return (updated, made)
    }

    /// An adjustment layer that changes nothing yet (neutral dials, no recipe).
    static func isNeutralAdjustment(_ layer: Layer) -> Bool {
        guard case .adjustment(let adjustments) = layer.content else { return false }
        return adjustments == .neutral && layer.edits.operations.isEmpty
    }

    // MARK: Clipping

    /// Clips a layer to the one below (D5), or releases it.
    static func layerClip(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let layer: Layer
        switch pickLayer(call.args["ref"]?.string, in: document, context: context) {
        case .value(let found): layer = found
        case .answer(let result): return (document, result)
        }
        let clip = call.args["clip"]?.bool ?? true
        var updated = document
        switch updated.applyLayerEdit(.clipped(clip), to: layer.id) {
        case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
        case .unchanged:
            return (document, info(clip ? (context.french ? "Ce calque est déjà écrêté." : "That layer is already clipped.")
                                        : (context.french ? "Ce calque n'est pas écrêté." : "That layer is not clipped.")))
        case .applied:
            return (updated, .applied(clip ? "Clipping Mask" : "Release Clipping Mask"))
        }
    }

    // MARK: Groups

    /// Groups layers (D4, one level), ungroups a group, names or folds it.
    static func groupLayers(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let args = call.args
        let notAGroup: (Layer) -> String? = { candidate in
            candidate.isGroup ? nil : PhotoDocument.refusalMessage(.notAGroup, layerName: displayName(candidate, in: document, french: context.french), french: context.french)
        }
        // Ungroup, or fold a group.
        if args["ungroup"]?.bool == true || (args["refs"] == nil && args["all"] == nil && args["collapse"] != nil) {
            let group: Layer
            switch pickLayer(args["ref"]?.string, in: document, context: context, misfit: notAGroup) {
            case .value(let found): group = found
            case .answer(let result): return (document, result)
            }
            var updated = document
            if args["ungroup"]?.bool == true {
                let result = updated.applyStructureEdit(.ungroup(group.id))
                switch result.outcome {
                case .refused(let reason): return (document, refusal(reason, layer: group, document: document, context: context))
                case .unchanged: return (document, alreadySo(context))
                case .applied: return (updated, .applied("Ungroup Layers"))
                }
            }
            var folder = group.folder ?? LayerFolder()
            folder.isCollapsed = args["collapse"]?.bool ?? folder.isCollapsed
            switch updated.applyLayerEdit(.folder(folder), to: group.id) {
            case .refused(let reason): return (document, refusal(reason, layer: group, document: document, context: context))
            case .unchanged: return (document, alreadySo(context))
            case .applied: return (updated, .applied("Group Options"))
            }
        }
        // The layers: `refs`, `all` (every top-level layer above the photo), else the selected one.
        var chosen: [Layer]
        if args["all"]?.bool == true {
            chosen = document.layers.filter { $0.id != document.baseLayerID && $0.parentID == nil && !$0.isGroup }
            guard !chosen.isEmpty else { return (document, refusal(.notFound, layer: nil, document: document, context: context)) }
        } else if args["refs"] != nil {
            let named = layers(named: args["refs"], in: document, context: context)
            if let first = named.unknown.first { return (document, unknownLayer(first, document, context)) }
            chosen = named.layers
            guard !chosen.isEmpty else {
                return (document, answer(context.french ? "Nomme au moins un calque (l1, s1…), ou dis « tous les calques »." : "Name at least one layer (l1, s1…), or say “all layers”.",
                                         reason: .nothingToDo))
            }
        } else {
            switch pickLayer(nil, in: document, context: context) {
            case .value(let found): chosen = [found]
            case .answer(let result): return (document, result)
            }
        }
        if chosen.contains(where: { $0.id == document.baseLayerID }) {
            return (document, refusal(.baseLayer, layer: nil, document: document, context: context))
        }
        var updated = document
        let result = updated.applyStructureEdit(.group(chosen.map(\.id), name: args["name"]?.string))
        switch result.outcome {
        case .refused(let reason): return (document, refusal(reason, layer: chosen.first, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: break
        }
        guard let id = result.layerID else { return (updated, .applied("Group Layers")) }
        if args["collapse"]?.bool == true, var folder = updated.layer(id: id)?.folder {
            folder.isCollapsed = true
            _ = updated.applyLayerEdit(.folder(folder), to: id)
        }
        return (updated, madeLayer(id, label: "Group Layers", in: updated, context: context))
    }

    // MARK: Merges

    /// Merge down, visible, flatten, stamp and selected (D17): the pixels from `rasterizeLayers` (heavy: the session
    /// shows progress), then the structure edit. Flatten with hidden layers asks first; « oui » re-runs it with
    /// `confirm`.
    static func mergeLayers(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let mode = call.args["mode"]?.string ?? "down"
        let request: LayerRasterRequest
        let makeEdit: @Sendable (MediaAsset) -> LayerStructureEdit
        let label: String
        var subject: Layer?
        switch mode {
        case "down":
            let raw = call.args["ref"]?.string
            if raw == nil, document.selectedLayer?.id == document.baseLayerID {
                return (document, answer(context.french ? "Le fond n'a rien en dessous." : "The base photo has nothing below it.", reason: .nothingToDo))
            }
            let upper: Layer
            switch pickLayer(raw, in: document, context: context) {
            case .value(let found): upper = found
            case .answer(let result): return (document, result)
            }
            guard let upperIndex = document.index(of: upper.id),
                  let lower = document.layers[..<upperIndex].last(where: { $0.parentID == upper.parentID && $0.id != upper.parentID }) else {
                return (document, answer(context.french ? "Ce calque n'a rien en dessous avec quoi fusionner." : "That layer has nothing below it to merge with.", reason: .nothingToDo))
            }
            if upper.isGroup || upper.isAdjustment || lower.isGroup || lower.isAdjustment {
                return (document, answer(context.french ? "Un groupe ou un calque de réglage ne fusionne pas vers le bas : fusionne les calques visibles, ou nomme les calques à fusionner."
                                                        : "A group or an adjustment layer can't merge down: merge visible, or name the layers to merge.",
                                         reason: .nothingToDo))
            }
            let upperID = upper.id
            request = .layers([lower.id, upperID])
            makeEdit = { .mergeDown(upperID, raster: $0) }
            label = "Merge Down"
            subject = upper
        case "visible":
            request = .visible
            makeEdit = { .mergeVisible(raster: $0) }
            label = "Merge Visible"
        case "flatten":
            let hidden = document.layers.contains { layer in
                layer.id != document.baseLayerID && (!layer.isVisible || document.parent(of: layer.id)?.isVisible == false)
            }
            if hidden, call.args["confirm"]?.bool != true {
                var confirmed = call
                confirmed.args["confirm"] = .bool(true)
                let question = context.french ? "Les calques masqués seront supprimés. On aplatit ?" : "The hidden layers will be deleted. Flatten anyway?"
                let pending = ClarificationRequest(question: question, candidates: [], pendingIntent: EditIntent(action: .operation, confidence: 0.85, operation: confirmed))
                return (document, ExecutionResult(outcome: .needsClarification(pending), effects: [.clarify(pending)]))
            }
            request = .visible
            makeEdit = { .flatten(raster: $0) }
            label = "Flatten Image"
        case "stamp":
            request = .visible
            let name = context.french ? "Tampon" : "Stamp"
            makeEdit = { .stamp(raster: $0, name: name) }
            label = "Stamp Visible"
        default:
            let named = layers(named: call.args["refs"], in: document, context: context)
            if let first = named.unknown.first { return (document, unknownLayer(first, document, context)) }
            guard Set(named.layers.map { $0.group?.id ?? $0.id }).count >= 2 else {
                return (document, answer(context.french ? "Quels calques fusionner ? Nomme-en au moins deux (i1, i2…)." : "Which layers? Name at least two (i1, i2…).",
                                         reason: .needsSelection))
            }
            let ids = named.layers.map(\.id)
            request = .merged(ids)
            makeEdit = { .mergeLayers(ids, raster: $0) }
            label = "Merge Layers"
        }
        // The locks and the tree first: nothing is rendered for an edit the document would refuse.
        var trial = document
        let probe = trial.applyStructureEdit(makeEdit(MediaAsset(kind: .image, relativePath: "media/merge-check.png", pixelSize: document.canvasSize)))
        if case .refused(let reason) = probe.outcome { return (document, refusal(reason, layer: subject, document: document, context: context)) }
        let raster: LayerRasterResult
        do {
            raster = try await context.services.rasterizeLayers(request, in: document)
        } catch {
            if case .unsupportedOperation? = error as? PicshopError {
                return (document, answer(context.french ? "La fusion des calques n'est pas disponible ici." : "Merging layers isn't available here.", reason: .unsupported))
            }
            let message = (error as? PicshopError)?.message(french: context.french) ?? error.localizedDescription
            return (document, .failed(message))
        }
        var updated = document
        let result = updated.applyStructureEdit(makeEdit(raster.asset), rasterBounds: raster.opaqueBounds)
        switch result.outcome {
        case .refused(let reason): return (document, refusal(reason, layer: subject, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: break
        }
        guard let id = result.layerID else { return (updated, .applied(label)) }
        if mode == "stamp" { return (updated, madeLayer(id, label: label, in: updated, context: context)) }
        return (updated, .applied(label, effects: [.selectLayer(id)]))
    }

    // MARK: Transform

    /// The fields of layerTransform that change something (`mode` alone opens the handles instead).
    static let transformFields = ["center", "x", "y", "dx", "dy", "scale", "scaleBy", "scaleX", "scaleY", "rotation", "skewX", "skewY", "corners", "flip", "fit", "align"]

    /// Moves, scales, rotates, skews, flips, fits or aligns a layer (D10); `refs` aligns or distributes several in one
    /// step; `mode` alone opens transform mode on the canvas.
    static func layerTransform(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let args = call.args
        if let align = args["align"]?.string, case .list(let items)? = args["refs"], items.count >= 2 {
            return await alignLayers(align, call: call, document, context)
        }
        let movable: (Layer) -> String? = { candidate in
            switch candidate.content {
            case .image, .text, .shape: return nil
            case .adjustment, .fill, .gradientFill, .group, .unsupported:
                return context.french ? "« \(displayName(candidate, in: document, french: true)) » couvre toute la photo : il ne se déplace pas. Transforme un calque photo, texte ou forme."
                                      : "“\(displayName(candidate, in: document, french: false))” covers the whole photo and doesn't move. Transform an image, text or shape layer."
            }
        }
        let layer: Layer
        switch pickLayer(args["ref"]?.string, in: document, context: context, misfit: movable) {
        case .value(let found): layer = found
        case .answer(let result): return (document, result)
        }
        guard LayerLockPolicy.allows(.placement, on: layer.id, in: document) else {
            return (document, refusal(.locked, layer: layer, document: document, context: context))
        }
        if !transformFields.contains(where: { args[$0] != nil }) {
            // Transform mode on the canvas, in the mode asked (free by default).
            let mode = args["mode"]?.string ?? "free"
            let said: String
            switch mode {
            case "perspective": said = context.french ? "Tire les coins pour la perspective." : "Drag the corners for perspective."
            case "distort": said = context.french ? "Tire les coins pour déformer." : "Drag the corners to distort."
            case "skew": said = context.french ? "Tire les bords pour incliner." : "Drag the edges to skew."
            default: said = context.french ? "Tire les poignées pour transformer le calque." : "Drag the handles to transform the layer."
            }
            return (document, info(said, effects: [.message("transformLayer:\(layer.id.uuidString):\(mode)"), .message("speak:" + said)]))
        }
        guard let size = await placementSize(of: layer, in: document, context: context) else {
            return (document, answer(context.french ? "Je ne connais pas encore la taille de ce calque : transforme-le avec les poignées." : "I don't know that layer's size yet: use the handles.",
                                     reason: .nothingToDo, effects: [.message("transformLayer:\(layer.id.uuidString):free")]))
        }
        let canvas = document.canvasSize
        let placed = LayerPlacement.textPlacement(of: layer)
        var transform = layer.transform
        transform.center = placed.center
        transform.rotation = placed.rotation
        let start = transform
        let relative = args["relative"]?.bool == true
        if let fit = args["fit"]?.string {
            transform = .identity
            if fit != "reset" {
                let natural = LayerPlacement.fitScale(contentSize: size, canvasSize: canvas)
                let ratios = (canvas.width / size.width, canvas.height / size.height)
                transform.scale = (fit == "fill" ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)) / natural
            }
        }
        if let rotation = args["rotation"]?.double { transform.rotation = relative ? transform.rotation + rotation : rotation }
        if let scale = args["scale"]?.double { transform.scale = max(0.01, relative ? transform.scale + scale / 100 : scale / 100) }
        if let factor = args["scaleBy"]?.double { transform.scale = max(0.01, transform.scale * factor / 100) }
        if let width = args["scaleX"]?.double { transform.scaleX = max(0.01, relative ? transform.scaleX + width / 100 : width / 100) }
        if let height = args["scaleY"]?.double { transform.scaleY = max(0.01, relative ? transform.scaleY + height / 100 : height / 100) }
        if let skew = args["skewX"]?.double { transform.skewX = skew.clamped(to: -60...60) }
        if let skew = args["skewY"]?.double { transform.skewY = skew.clamped(to: -60...60) }
        switch args["flip"]?.string {
        case "horizontal"?: transform.isFlippedHorizontally.toggle()
        case "vertical"?: transform.isFlippedVertically.toggle()
        default: break
        }
        if let quad = layer.transform.quad, ["fit", "rotation", "scale", "scaleBy", "scaleX", "scaleY", "skewX", "skewY", "flip"].contains(where: { args[$0] != nil }) {
            // A four-corner layer: a scale or a relative turn reshapes the quad about its centre; an absolute field
            // starts again from the fields (the quad is dropped).
            let reshapes = args["scaleBy"] != nil || (relative && (args["rotation"] != nil || args["scale"] != nil))
            let absolute = ["fit", "scaleX", "scaleY", "skewX", "skewY", "flip"].contains { args[$0] != nil } || (!relative && (args["rotation"] != nil || args["scale"] != nil))
            transform.quad = reshapes && !absolute ? reshapedQuad(quad, old: start, new: transform, canvas: canvas) : nil
        }
        // Moves: the centre, the bounds' centre (x, y), alignment on the canvas, offsets (dx, dy).
        var shift = PSPoint(x: 0, y: 0)
        if let center = args["center"].flatMap(normalizedPoint) { shift = PSPoint(x: center.x - transform.center.x, y: center.y - transform.center.y) }
        if args["x"] != nil || args["y"] != nil || args["align"] != nil {
            var probe = layer
            probe.transform = transform
            if case .text(var element) = probe.content {
                element.center = transform.center
                element.rotation = transform.rotation
                probe.content = .text(element)
            }
            let bounds = LayerPlacement.bounds(for: probe, contentSize: size, canvasSize: canvas, isBase: false)
            if let x = args["x"]?.double { shift.x = x / 1000 - bounds.midX }
            if let y = args["y"]?.double { shift.y = y / 1000 - bounds.midY }
            if let align = args["align"]?.string {
                for alignment in alignments(align) {
                    let delta = LayerPlacement.alignment(alignment, boxes: [layer.id: bounds], canvas: true)[layer.id] ?? .zero
                    shift.x += delta.x
                    shift.y += delta.y
                }
            }
        }
        if let dx = args["dx"]?.double { shift.x += dx / 1000 }
        if let dy = args["dy"]?.double { shift.y += dy / 1000 }
        transform.center = PSPoint(x: transform.center.x + shift.x, y: transform.center.y + shift.y)
        if let quad = transform.quad, shift.x != 0 || shift.y != 0 {
            transform.quad = quad.map { PSPoint(x: $0.x + shift.x, y: $0.y + shift.y) }
        }
        if case .list(let items)? = args["corners"] {
            let quad = items.compactMap(normalizedPoint)
            guard quad.count == 4, TransformHandles.isValidQuad(quad, aspect: canvas.aspectRatio) else {
                return (document, answer(context.french ? "Ces quatre coins ne forment pas un quadrilatère : donne-les dans l'ordre haut-gauche, haut-droite, bas-droite, bas-gauche."
                                                        : "Those four corners don't make a quadrilateral: give them top-left, top-right, bottom-right, bottom-left.",
                                         reason: .badRegion))
            }
            transform.quad = quad
        }
        var updated = document
        switch updated.applyLayerEdit(.transform(transform), to: layer.id) {
        case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
        case .unchanged: return (document, alreadySo(context))
        case .applied: return (updated, .applied("Transform Layer"))
        }
    }

    /// "center" is both centres; the other values are LayerAlignment's.
    static func alignments(_ raw: String) -> [LayerAlignment] {
        if raw == "center" { return [.centerH, .centerV] }
        return LayerAlignment(rawValue: raw).map { [$0] } ?? []
    }

    /// A quad scaled and turned about its centroid by the change from `old` to `new` (scale and rotation), in pixels so a
    /// turn keeps its angles on a non-square canvas.
    static func reshapedQuad(_ quad: [PSPoint], old: LayerTransform, new: LayerTransform, canvas: PSSize) -> [PSPoint] {
        let factor = old.scale > 0 ? new.scale / old.scale : 1
        let radians = (new.rotation - old.rotation) * .pi / 180
        let width = max(canvas.width, 1), height = max(canvas.height, 1)
        let centroid = PSPoint(x: quad.map(\.x).reduce(0, +) / 4 * width, y: quad.map(\.y).reduce(0, +) / 4 * height)
        return quad.map { point in
            let x = point.x * width - centroid.x, y = point.y * height - centroid.y
            let turnedX = (x * cos(radians) - y * sin(radians)) * factor, turnedY = (x * sin(radians) + y * cos(radians)) * factor
            return PSPoint(x: (centroid.x + turnedX) / width, y: (centroid.y + turnedY) / height)
        }
    }

    /// Align or distribute several layers (D10) in one step; position-locked ones are skipped and named.
    static func alignLayers(_ raw: String, call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        let named = layers(named: call.args["refs"], in: document, context: context)
        if let first = named.unknown.first { return (document, unknownLayer(first, document, context)) }
        var boxes: [UUID: PSRect] = [:]
        var skipped: [String] = []
        for layer in named.layers {
            switch layer.content {
            case .image, .text, .shape: break
            case .adjustment, .fill, .gradientFill, .group, .unsupported: continue
            }
            guard LayerLockPolicy.allows(.placement, on: layer.id, in: document) else {
                skipped.append(layerRef(layer.id, document, context))
                continue
            }
            guard let size = await placementSize(of: layer, in: document, context: context) else { continue }
            boxes[layer.id] = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: document.canvasSize, isBase: false)
        }
        guard !boxes.isEmpty, boxes.count >= 2 || !skipped.isEmpty else {
            if !skipped.isEmpty { return (document, refusal(.locked, layer: nil, document: document, context: context)) }
            return (document, answer(context.french ? "Il faut au moins deux calques photo, texte ou forme à aligner." : "Aligning needs at least two image, text or shape layers.",
                                     reason: .nothingToDo))
        }
        var moves: [UUID: PSPoint] = [:]
        // With one movable layer left (the others locked), it aligns on the canvas.
        for alignment in alignments(raw) {
            for (id, delta) in LayerPlacement.alignment(alignment, boxes: boxes, canvas: boxes.count == 1) {
                let current = moves[id] ?? .zero
                moves[id] = PSPoint(x: current.x + delta.x, y: current.y + delta.y)
            }
        }
        var updated = document
        var changed = false
        for layer in named.layers {
            guard let delta = moves[layer.id], abs(delta.x) + abs(delta.y) > 1e-9, let current = updated.layer(id: layer.id) else { continue }
            var transform = current.transform
            let placed = LayerPlacement.textPlacement(of: current)
            transform.center = PSPoint(x: placed.center.x + delta.x, y: placed.center.y + delta.y)
            transform.rotation = placed.rotation
            if let quad = transform.quad { transform.quad = quad.map { PSPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
            if case .applied = updated.applyLayerEdit(.transform(transform), to: layer.id) { changed = true }
        }
        guard changed else { return (document, info(context.french ? "Les calques sont déjà alignés." : "The layers are already aligned.")) }
        var result = ExecutionResult.applied(raw.hasPrefix("distribute") ? "Distribute Layers" : "Align Layers")
        if !skipped.isEmpty {
            let list = skipped.joined(separator: ", ")
            result.effects.append(.message("speak:" + (context.french ? "\(list) : position verrouillée, je n'y ai pas touché." : "\(list): position locked, left as it was.")))
        }
        return (updated, result)
    }

    // MARK: Properties

    /// Fill opacity, locks, name, pass through, mask link: each through `applyLayerEdit`, one step.
    static func layerProperties(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let args = call.args
        let allowBase = args["fill"] == nil && args["passThrough"] == nil
        let layer: Layer
        switch pickLayer(args["ref"]?.string, in: document, context: context, allowBase: allowBase) {
        case .value(let found): layer = found
        case .answer(let result): return (document, result)
        }
        var edits: [(LayerEdit, String)] = []
        if let fill = args["fill"]?.double { edits.append((.fillOpacity((fill / 100).clamped(to: 0...1)), "Fill Opacity")) }
        switch args["lock"]?.string {
        case "all"?: edits.append((.lockAll(true), "Lock Layer"))
        case "position"?: edits += [(.lockAll(false), "Lock Position"), (.lock([.position]), "Lock Position")]
        case "pixels"?: edits += [(.lockAll(false), "Lock Pixels"), (.lock([.pixels]), "Lock Pixels")]
        case "transparency"?: edits += [(.lockAll(false), "Lock Transparency"), (.lock([.transparency]), "Lock Transparency")]
        case "none"?: edits += [(.lockAll(false), "Unlock Layer"), (.lock([]), "Unlock Layer")]
        default: break
        }
        if let name = args["name"]?.string { edits.append((.rename(name), "Rename Layer")) }
        if let passThrough = args["passThrough"]?.bool {
            guard var folder = layer.folder else { return (document, refusal(.notAGroup, layer: layer, document: document, context: context)) }
            folder.passThrough = passThrough
            edits.append((.folder(folder), "Group Blending"))
        }
        var contentSize: PSSize?
        if let linked = args["maskLinked"]?.bool {
            contentSize = await placementSize(of: layer, in: document, context: context)
            edits.append((.maskLinked(linked), linked ? "Link Mask" : "Unlink Mask"))
        }
        guard !edits.isEmpty else {
            return (document, answer(context.french ? "Que changer : le fond, le verrou ou le nom ?" : "What should change: fill, lock or name?", reason: .nothingToDo))
        }
        var updated = document
        var labels: [String] = []
        for (edit, label) in edits {
            switch updated.applyLayerEdit(edit, to: layer.id, contentSize: contentSize) {
            case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
            case .unchanged: continue
            case .applied: if !labels.contains(label) { labels.append(label) }
            }
        }
        guard !labels.isEmpty else { return (document, alreadySo(context)) }
        return (updated, .applied(labels.count == 1 ? labels[0] : "Layer Properties"))
    }

    // MARK: Export

    /// The export sheet on a format or a preset (D16): `.message("exportPreset:<JSON of ExportPreset>")`, and a reply
    /// that names where the file goes (Files for PSD and PDF, Photos otherwise).
    static func exportPhoto(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let gate = layerGate(call, document, context) { return gate }
        let preset = exportPreset(call.args)
        if preset.format == .psd, !FeatureFlags.isOn(.psdExport) { return notEnabled(document, context) }
        guard let json = exportJSON(preset) else {
            return (document, .failed(context.french ? "Je n'arrive pas à préparer l'export." : "I couldn't prepare the export."))
        }
        let format = preset.format.rawValue.uppercased()
        let said: String
        if preset.format.canSaveToPhotos {
            said = context.french ? "J'ouvre l'export en \(format) : touche Enregistrer dans Photos." : "Export sheet ready (\(format)): tap Save to Photos."
        } else {
            said = context.french ? "J'ouvre l'export en \(format) : touche Enregistrer dans Fichiers." : "Export sheet ready (\(format)): tap Save to Files."
        }
        return (document, ExecutionResult(outcome: .info(message: said), effects: [.message(exportPrefix + json), .message("speak:" + said)]))
    }

    /// The effect prefix the photo session opens the export sheet on.
    public static let exportPrefix = "exportPreset:"

    /// The preset's JSON (sorted keys), as the effect carries it.
    static func exportJSON(_ preset: ExportPreset) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preset) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The Core preset a call asks for: a named preset, else the format with its depth, colour space, size and layers.
    static func exportPreset(_ args: [String: OpValue]) -> ExportPreset {
        var preset: ExportPreset
        switch args["preset"]?.string {
        case "instagram"?: preset = .instagram
        case "print"?: preset = .print
        case "web"?: preset = .web
        default: preset = ExportPreset(format: args["format"]?.string.flatMap(ExportFileFormat.init(rawValue:)) ?? .jpeg)
        }
        if args["preset"] != nil, let format = args["format"]?.string.flatMap(ExportFileFormat.init(rawValue:)) { preset.format = format }
        if let depth = args["bitDepth"]?.string.flatMap({ Int($0) }) { preset.bitDepth = depth }
        if let space = args["colorSpace"]?.string { preset.colorSpace = space }
        if let size = args["size"]?.string {
            if size == "full" { preset.size = .full } else if let pixels = Int(size) { preset.size = .longSide(pixels) }
        }
        if let layers = args["layers"]?.bool { preset.layered = layers }
        // The depths a format can hold: JPEG and PDF 8, HEIC 8 or 10, PNG, TIFF and PSD 8 or 16.
        switch preset.format {
        case .jpeg, .pdf: preset.bitDepth = 8
        case .heic: preset.bitDepth = preset.bitDepth >= 10 ? 10 : 8
        case .png, .tiff, .psd: preset.bitDepth = preset.bitDepth >= 16 ? 16 : 8
        }
        return preset
    }

    // MARK: Legacy layer actions with a W3 ref (selectLayer, duplicateLayer, deleteLayer)

    /// selectLayer, duplicateLayer and deleteLayer with a stored ref (i2, j1, g1…), lowered onto the operation path by
    /// the validator: the layer by its ref, then the D17 structure edit (fresh ids and ref numbers for a duplicate, a
    /// group with its children).
    static func layerAction(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        let layer: Layer
        switch pickLayer(call.args["ref"]?.string, in: document, context: context, allowBase: call.id.raw == "selectLayer") {
        case .value(let found): layer = found
        case .answer(let result): return (document, result)
        }
        var updated = document
        switch call.id.raw {
        case "selectLayer":
            updated.selectedLayerID = layer.id
            return (updated, .effect(.selectLayer(layer.id), label: "Select Layer"))
        case "duplicateLayer":
            let result = updated.applyStructureEdit(.duplicate(layer.id))
            switch result.outcome {
            case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
            case .unchanged: return (document, alreadySo(context))
            case .applied: break
            }
            guard let id = result.layerID else { return (updated, .applied("Duplicate Layer")) }
            return (updated, madeLayer(id, label: "Duplicate Layer", in: updated, context: context))
        default:
            let wholeGroup = layer.isGroup && !document.children(of: layer.id).isEmpty
            let result = updated.applyStructureEdit(.remove(layer.id))
            switch result.outcome {
            case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
            case .unchanged: return (document, alreadySo(context))
            case .applied: break
            }
            var done = ExecutionResult.applied("Delete Layer")
            if wholeGroup {
                done.effects.append(.message("speak:" + (context.french ? "J'ai supprimé le groupe et ses calques." : "Deleted the group and its layers.")))
            }
            return (updated, done)
        }
    }

    // MARK: Tone and colour targets (D9)

    /// Where a tone or colour op writes: the run's `targetLayerID` (a new adjustment layer, an inspector row), the
    /// call's `layer` ref, else `toneTarget(for:)` (the selected adjustment layer of the op's family, else the active
    /// image layer). A ref of another family answers « j1 est un calque Courbes ».
    static func toneLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> Answered<UUID> {
        if let id = context.targetLayerID, document.layer(id: id) != nil { return .value(id) }
        if let raw = call.args["layer"]?.string {
            guard let layer = LiveLayerLines.layer(ref: raw, in: document, scene: context.intent.scene) else {
                return .answer(unknownLayer(raw, document, context, kinds: [.imageLayer, .adjustmentLayer]))
            }
            if layer.isAdjustment {
                let kind = layer.recipeKind ?? .light
                guard PhotoDocument.toneTargetKinds(for: call.id).contains(kind) else {
                    let ref = layerRef(layer.id, document, context)
                    return .answer(answer(context.french ? "\(ref) est un calque \(kind.frenchName) : choisis un calque photo ou un calque de ce réglage."
                                                         : "\(ref) is a \(kind.englishName) layer: pick an image layer or a layer of this adjustment.",
                                          reason: .nothingToDo))
                }
                return .value(layer.id)
            }
            guard layer.isImage else { return .answer(answer(notAnImage(layer, document, context), reason: .nothingToDo)) }
            return .value(layer.id)
        }
        guard let id = document.toneTarget(for: call.id) else {
            return .answer(answer(context.french ? "Il faut une photo." : "This needs a photo.", reason: .nothingToDo))
        }
        return .value(id)
    }

    /// adjust with a `layer`: a « Lumière » adjustment layer's own dials (LayerEdit.adjustments, D9: never `.adjust`
    /// operations in its edits) or an image layer's edits.
    static func adjustLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        let id: UUID
        switch toneLayer(call, document, context) {
        case .value(let found): id = found
        case .answer(let result): return (document, result)
        }
        guard let raw = call.args["parameter"]?.string, let parameter = AdjustmentParameter(rawValue: raw) ?? ParameterVocabulary.parameter(named: raw) else {
            return (document, answer(context.french ? "Je ne sais pas quel réglage changer." : "I don't know which setting to change.", reason: .nothingToDo))
        }
        guard let layer = document.layer(id: id) else { return (document, refusal(.notFound, layer: nil, document: document, context: context)) }
        let mode: AmountSpec.Mode
        switch call.args["amountMode"]?.string {
        case "absolute"?: mode = .absolute
        case "multiplier"?: mode = .multiplier
        default: mode = .relative
        }
        let spec = call.args["amount"]?.double.flatMap { amount in AmountUnit.for(.adjust)?.spec(amount, mode: mode) } ?? .relative(parameter.defaultStep)
        var updated = document
        if case .adjustment(let current) = layer.content {
            var next = current
            let value = spec.resolve(current: current[parameter], range: parameter.range)
            next[parameter] = value
            switch updated.applyLayerEdit(.adjustments(next), to: id) {
            case .refused(let reason): return (document, refusal(reason, layer: layer, document: document, context: context))
            case .unchanged: return (document, alreadySo(context))
            case .applied: return (updated, .applied(EditOperation.Kind.adjust(parameter, value: value).defaultLabel))
            }
        }
        let value = spec.resolve(current: layer.edits.resolvedAdjustments[parameter], range: parameter.range)
        guard updated.apply(.adjust(parameter, value: value), to: id) else {
            return (document, refusal(.locked, layer: layer, document: document, context: context))
        }
        return (updated, .applied(EditOperation.Kind.adjust(parameter, value: value).defaultLabel))
    }

    /// applyLook with a `layer`: the look on that image layer, or in a « Look » adjustment layer's recipe.
    static func lookOnLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        let id: UUID
        switch toneLayer(call, document, context) {
        case .value(let found): id = found
        case .answer(let result): return (document, result)
        }
        guard let raw = call.args["look"]?.string, let look = FilterPreset(rawValue: raw) ?? FilterPreset.matching(raw) else {
            return (document, info(context.french ? "Quel filtre ?" : "Which look?"))
        }
        let intensity = ((call.args["amount"]?.double).map { $0 > 1 ? $0 / 100 : $0 } ?? 1).clamped(to: 0...1)
        var updated = document
        guard updated.apply(.look(look, intensity: intensity), to: id) else {
            return (document, refusal(.locked, layer: document.layer(id: id), document: document, context: context))
        }
        return (updated, .applied(look.englishName))
    }

    /// matchColor with a `layer`: that image layer is selected and the reference picker opens.
    static func matchColorOnLayer(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        let id: UUID
        switch toneLayer(call, document, context) {
        case .value(let found): id = found
        case .answer(let result): return (document, result)
        }
        var updated = document
        updated.selectedLayerID = id
        return (updated, ExecutionResult(outcome: .applied(label: ""), effects: [.selectLayer(id), .pickColorReference], label: ""))
    }
}
