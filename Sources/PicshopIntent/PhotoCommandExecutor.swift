import Foundation
import PicshopCore

/// Applies intents to a `PhotoDocument`. Pure document mutations happen here;
/// vision work is delegated to `PhotoAIServices`.
public struct PhotoCommandExecutor: Sendable {
    public let services: PhotoAIServices
    /// Locale used for clarification questions.
    public var language: NormalizedUtterance.Language

    public init(services: PhotoAIServices, language: NormalizedUtterance.Language = .english) {
        self.services = services
        self.language = language
    }

    public func execute(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let language = self.language
        let fr = language == .french
        // Primitives on a scene block ("t3", "l1") and text laid out in a box or a style.
        if let ref = intent.ref, ref.isText, intent.action == .editText { return await editTextBlock(ref, intent: intent, on: document, context: context) }
        if let ref = intent.ref, ref.isText, intent.action == .removeText { return await removeTextBlock(ref, intent: intent, on: document, context: context) }
        if intent.action == .addText, intent.region != nil || intent.textStyle != nil || intent.ref != nil { return await placeText(intent, on: document, context: context) }
        if let ref = intent.ref, ref.isText, intent.action == .removeObject { return await removeTextBlock(ref, intent: intent, on: document, context: context) }
        switch intent.action {
        case .fillCells: return await fillCells(intent, on: document, context: context)
        case .clearCells: return await clearCells(intent, on: document, context: context)
        case .highlightCells: return await highlightCells(intent, on: document, context: context)
        case .eraseRegion: return await eraseRegion(intent, on: document, context: context)
        case .moveText: return await moveText(intent, on: document, context: context)

        case .autoCrop:
            do {
                guard let rect = try await services.bestCrop(in: document) else {
                    return (document, ExecutionResult(outcome: .info(message: fr ? "Le cadrage est déjà très bon." : "The framing is already good.")))
                }
                document.apply(.crop(rect.clampedToUnit()))
                return (document, .applied("Best crop"))
            } catch {
                return (document, failure(error))
            }

        case .cleanUp:
            let people = (try? await services.candidates(for: ObjectTarget(label: "person"), in: document)) ?? []
            let distractions = DistractionFinder.distractions(among: people)
            guard !distractions.isEmpty else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Personne ne dérange sur cette photo." : "No one is in the way in this photo.")))
            }
            let target = ObjectTarget(label: "person", originalPhrase: fr ? "les passants" : "the passers-by", matchesAll: true)
            return await apply(pendingIntent: EditIntent(action: .removeObject, target: target, scope: .all), candidates: distractions, document: document)

        case .matchColor:
            // The reference is a picture the user chooses.
            return (document, .effect(.pickColorReference, label: ""))

        case .textBehind:
            // A table screenshot has no one to put a title behind: say so without asking Vision.
            if context.table?.coversPicture == true { return (document, failure(PicshopError.noSubject)) }
            do {
                let mask = try await services.subjectMask(in: document)
                guard document.placeTextBehindSubject(intent.text, subjectMask: mask, placeholder: fr ? "TITRE" : "TITLE") != nil else {
                    return (document, .failed(fr ? "Il faut une photo." : "This needs a photo."))
                }
                return (document, .applied("Text behind subject"))
            } catch {
                return (document, failure(error))
            }

        case .removeObject, .moveObject, .blurObject:
            if case .object? = intent.ref { return await actOnSceneObject(intent, on: document, context: context) }
            guard let target = intent.target else {
                let verb: String
                switch intent.action {
                case .moveObject: verb = fr ? "déplacer" : "move"
                case .blurObject: verb = fr ? "flouter" : "blur"
                default: verb = fr ? "retirer" : "remove"
                }
                let message = fr ? "Je ne sais pas quoi \(verb) : touche-le ou nomme-le." : "I don't know what to \(verb): tap it or name it."
                return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("tapToErase"), ExecutionReason.needsSelection.effect]))
            }
            // D7: the table as it is, kept before its values go, so a later fill writes in its typography.
            if intent.action == .removeObject, context.table != nil || TableVocabulary.namesTableText(target),
               let (raw, _) = await tables(in: document) {
                var remembered = document
                rememberTable(raw, in: &remembered)
                let (erased, result) = await removeObject(target: target, intent: intent, document: remembered, selection: context.selectionMask)
                // The memory lands in the same commit as the erase, and only with it.
                return result.outcome.isSuccess ? (erased, result) : (document, result)
            }
            return await removeObject(target: target, intent: intent, document: document, selection: context.selectionMask)

        case .chooseCandidate:
            guard let pending = context.pendingClarification else { return (document, ExecutionResult(outcome: .ignored)) }
            if IntentNormalizer.tableActions.contains(pending.pendingIntent.action) { return await chooseTableCandidate(intent, pending: pending, on: document, context: context) }
            let chosen: [ObjectCandidate]
            if intent.scope == .all {
                chosen = pending.candidates
            } else if let index = intent.index, index >= 1, index <= pending.candidates.count {
                chosen = [pending.candidates[index - 1]]
            } else if let target = intent.target {
                switch CandidateSelector.select(from: pending.candidates, for: target) {
                case .single(let candidate): chosen = [candidate]
                case .multiple(let candidates): chosen = candidates
                case .ambiguous(let candidates):
                    let request = ClarificationRequest(question: CandidateSelector.question(for: spoken(target), options: candidates, language: language), candidates: candidates, pendingIntent: pending.pendingIntent)
                    return (document, .clarify(request))
                case .none: return (document, notFound(target))
                }
            } else {
                return (document, ExecutionResult(outcome: .ignored))
            }
            var resumed = pending.pendingIntent
            resumed.target?.matchesAll = chosen.count > 1
            return await apply(pendingIntent: resumed, candidates: chosen, document: document, context: context)

        case .removeBackground:
            if context.table?.coversPicture == true { return (document, failure(PicshopError.noSubject)) }
            do {
                let mask = try await services.subjectMask(in: document)
                document.apply(.removeBackground(mask))
                return (document, .applied("Remove Background"))
            } catch {
                return (document, failure(error))
            }

        case .replaceBackground:
            guard let background = intent.background else {
                return (document, .effect(.pickBackground, label: ""))
            }
            if context.table?.coversPicture == true { return (document, failure(PicshopError.noSubject)) }
            do {
                let mask = try await services.subjectMask(in: document)
                let resolved: Background
                switch background {
                case .transparent: resolved = .transparent
                case .white: resolved = .solid(.white)
                case .black: resolved = .solid(.black)
                case .color(let color): resolved = .solid(color)
                case .blur(let amount): resolved = .blurredOriginal(amount: amount)
                case .gradient(let a, let b): resolved = .gradient(a, b)
                }
                document.apply(.replaceBackground(resolved, mask: mask))
                return (document, .applied("Replace Background"))
            } catch {
                return (document, failure(error))
            }

        case .blurBackground:
            if context.table?.coversPicture == true { return (document, failure(PicshopError.noSubject)) }
            do {
                let mask = try await services.subjectMask(in: document)
                let current = currentBlurAmount(in: document)
                let amount = (intent.amount ?? .absolute(0.65)).resolve(current: current, range: 0...1)
                document.apply(.blurBackground(amount: amount, mask: mask))
                return (document, .applied("Blur Background"))
            } catch {
                return (document, failure(error))
            }

        case .adjust:
            guard let parameter = intent.parameter else { return (document, .failed(fr ? "Je ne sais pas quel réglage changer." : "I don't know which setting to change.")) }
            let current = document.activeAdjustments[parameter]
            let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: current, range: parameter.range)
            document.apply(.adjust(parameter, value: value))
            return (document, .applied(EditOperation.Kind.adjust(parameter, value: value).defaultLabel))

        case .generativeFill, .recolor:
            guard let target = intent.target else {
                let message = fr ? "Touche ou entoure la zone à modifier, puis redis la commande." : "Tap or lasso the area to change, then repeat the command."
                return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("selectRegion")]))
            }
            do {
                let candidates = try await services.candidates(for: target, in: document)
                switch CandidateSelector.select(from: candidates, for: target) {
                case .single(let candidate): return await apply(pendingIntent: intent, candidates: [candidate], document: document)
                case .multiple(let list): return await apply(pendingIntent: intent, candidates: list, document: document)
                case .ambiguous(let options):
                    return (document, .clarify(ClarificationRequest(question: CandidateSelector.question(for: spoken(target), options: options, language: language), candidates: options, pendingIntent: intent)))
                case .none:
                    let message = fr ? "Je ne trouve pas « \(spoken(target).originalPhrase) ». Touche ou entoure la zone." : "I can't find “\(target.originalPhrase)”. Tap or lasso the area."
                    return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("selectRegion")]))
                }
            } catch {
                return (document, failure(error))
            }

        case .selectiveAdjust:
            guard let target = intent.target, let parameter = intent.parameter else {
                return (document, .failed(fr ? "Dis-moi quoi retoucher, ou touche-le." : "Tell me what to change, or tap it."))
            }
            // W2 (D2): an AI region (sky, subject, background…) lowers onto a local adjustment without the candidates.
            if PhotoOperationHandlers.isAIRegion(target),
               let lowered = await PhotoOperationHandlers.lowerSelective(intent, target: target, parameter: parameter, candidates: nil, document: document,
                                                                         context: OperationRunContext(intent: context, language: language, services: services)) {
                return await checkedSelective(lowered, intent: intent, before: document)
            }
            do {
                let candidates = try await services.candidates(for: target, in: document)
                // W2: objects and face parts keep the legacy resolution (the question, not found, the exact landmark masks),
                // then lower onto a local adjustment; a host without mask rasters keeps the legacy op below.
                if FeatureFlags.isOn(.masks) {
                    var chosen: [ObjectCandidate]?
                    switch CandidateSelector.select(from: candidates, for: target) {
                    case .single(let candidate): chosen = [candidate]
                    case .multiple(let list): chosen = list
                    case .ambiguous, .none: chosen = nil
                    }
                    if let chosen, let lowered = await PhotoOperationHandlers.lowerSelective(intent, target: target, parameter: parameter, candidates: chosen,
                                                                                            document: document,
                                                                                            context: OperationRunContext(intent: context, language: language, services: services)) {
                        return await checkedSelective(lowered, intent: intent, before: document)
                    }
                }
                switch CandidateSelector.select(from: candidates, for: target) {
                case .single(let candidate):
                    let mask = try await services.mask(for: [candidate], target: target, in: document)
                    let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                    document.apply(.selectiveAdjust(mask, Self.selectiveAdjustments(parameter, value, on: target)))
                    return (document, .applied("Selective \(parameter.englishName)"))
                case .multiple(let list):
                    let mask = try await services.mask(for: list, target: target, in: document)
                    let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                    document.apply(.selectiveAdjust(mask, Self.selectiveAdjustments(parameter, value, on: target)))
                    return (document, .applied("Selective \(parameter.englishName)"))
                case .ambiguous(let options):
                    return (document, .clarify(ClarificationRequest(question: CandidateSelector.question(for: spoken(target), options: options, language: language), candidates: options, pendingIntent: intent)))
                case .none:
                    return (document, notFound(target))
                }
            } catch {
                return (document, failure(error))
            }

        case .applyLook:
            guard let look = intent.look else { return (document, ExecutionResult(outcome: .info(message: fr ? "Quel filtre ?" : "Which look?"))) }
            let intensity = intent.amount?.value ?? 1
            document.apply(.look(look, intensity: intensity.clamped(to: 0...1)))
            return (document, .applied(look.englishName))

        case .autoEnhance:
            let strength = (intent.amount ?? .absolute(0.8)).value.clamped(to: 0...1)
            document.apply(.autoEnhance(strength: strength))
            return (document, .applied("Auto Enhance"))

        case .crop, .setAspect:
            if let target = intent.target {
                do {
                    let framing = try await services.framingRect(for: target, in: document)
                    guard let rect = framing else { return (document, notFound(target)) }
                    document.apply(.crop(rect.clampedToUnit()))
                    return (document, .applied("Crop to \(target.originalPhrase)"))
                } catch {
                    return (document, failure(error))
                }
            }
            let aspect = intent.aspect ?? .free
            if aspect == .original {
                let previousBaseEdits = document.baseLayer?.edits
                document.update(layerID: document.baseLayerID ?? UUID()) { layer in
                    layer.edits.operations.removeAll { if case .crop = $0.kind { return true } else { return false } }
                }
                if let base = document.baseLayer?.imageAsset { document.canvasSize = base.pixelSize }
                // Removing the crops bypasses `apply`: masks and the selection follow the frame back here (D3).
                if let previousBaseEdits { document.reconcileMasks(previousBaseEdits: previousBaseEdits) }
                return (document, .applied("Reset Crop"))
            }
            if aspect == .free {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Ajuste le cadre avec les poignées." : "Adjust the frame with the handles."), effects: [.message("crop")]))
            }
            let rect = aspect.cropRect(in: document.canvasSize)
            document.apply(.crop(rect))
            return (document, .applied("Crop \(aspect.displayName)"))

        case .rotate:
            let degrees = intent.degrees ?? 90
            document.apply(.rotate(degrees: degrees))
            return (document, .applied("Rotate \(Int(degrees))°"))

        case .straighten:
            if let degrees = intent.degrees {
                document.apply(.straighten(degrees: degrees))
                return (document, .applied("Straighten"))
            }
            do {
                let detected = try await services.horizonAngle(in: document)
                if let angle = detected, abs(angle) > 0.05 {
                    document.apply(.straighten(degrees: -angle))
                    return (document, .applied("Straighten"))
                }
                return (document, ExecutionResult(outcome: .info(message: fr ? "L'horizon est déjà droit." : "The horizon already looks level.")))
            } catch {
                return (document, failure(error))
            }

        case .flip:
            let axis = intent.flipAxis ?? .horizontal
            document.apply(.flip(axis))
            return (document, .applied(axis == .horizontal ? "Flip Horizontal" : "Flip Vertical"))

        case .resetOrientation:
            if intent.flipAxis != nil {
                // "Annule le miroir": the mirror goes, the turns stay.
                if document.removeMirror(label: "Remove Mirror") { return (document, .applied("Remove Mirror")) }
                return (document, ExecutionResult(outcome: .info(message: fr ? "La photo n'est pas en miroir." : "The photo isn't mirrored.")))
            }
            // Flips and quarter turns undone at once.
            if document.resetOrientation(label: "Right Way Up") { return (document, .applied("Right Way Up")) }
            // Said to be upside down with nothing to undo: it was shot that way, so it is turned over.
            if intent.degrees == 180 {
                document.apply(.rotate(degrees: 180))
                return (document, .applied("Rotate 180°"))
            }
            return (document, ExecutionResult(outcome: .info(message: fr ? "La photo est déjà à l'endroit." : "The photo is already the right way up.")))

        case .addText:
            guard let text = intent.text, !text.isEmpty else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Quel texte ?" : "What should it say?")))
            }
            var element = TextElement(text: text)
            // RC2: a point said or shown wins over the anchor.
            element.center = intent.target?.point.map { PSPoint(x: $0.x.clamped(to: 0...1), y: $0.y.clamped(to: 0...1)) } ?? (intent.placement ?? .bottom).center
            if let color = intent.color { element.color = color }
            if let amount = intent.amount, amount.mode == .absolute { element.relativeSize = amount.value.clamped(to: TextStyleSpec.relativeSizeRange) }
            // At a placement (not a point the user showed), new text never lands on the text already there or on
            // the table: it moves the shortest way to a clear spot of its own size (down from the top, up from the bottom).
            // The map the step was planned on (never a new text pass for this).
            if intent.target?.point == nil, let scene = context.scene?.overlaying(document.layers) {
                let box = element.estimatedBox(canvasSize: document.canvasSize)
                if let clear = RuleBasedIntentEngine.clearBox(for: intent.placement ?? .bottom, in: scene, size: box.size, anchor: element.center) {
                    element.center = clear.center
                }
            }
            let layer = Layer(name: text, content: .text(element), transform: LayerTransform(center: element.center))
            document.addLayer(layer)
            return (document, .applied("Add Text", effects: [.selectLayer(layer.id)]))

        case .editText:
            guard let layerID = document.selectedLayer?.isText == true ? document.selectedLayerID : document.textLayers.last?.id else {
                return (document, ExecutionResult(outcome: .failed(message: fr ? "Aucun texte à modifier." : "There's no text to edit."), effects: [ExecutionReason.noText.effect]))
            }
            // A table cell layer: a change of size, colour or weight is for the whole fill ("plus gros", "en rouge").
            if let group = document.layer(id: layerID)?.group, group.kind == .tableCells, intent.text == nil, intent.placement == nil, intent.target?.point == nil {
                for member in document.layers(inGroup: group.id) {
                    document.update(layerID: member.id) { layer in
                        guard var element = layer.textElement else { return }
                        Self.restyle(&element, with: intent)
                        layer.textElement = element
                    }
                }
                return (document, .applied("Edit Text"))
            }
            document.update(layerID: layerID) { layer in
                guard var element = layer.textElement else { return }
                if let text = intent.text, !text.isEmpty { element.text = text; layer.name = text }
                if let point = intent.target?.point { element.center = PSPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1)) }
                else if let placement = intent.placement { element.center = placement.center }
                Self.restyle(&element, with: intent)
                layer.textElement = element
                layer.transform.center = element.center
            }
            return (document, .applied("Edit Text"))

        case .removeText:
            guard let layerID = document.selectedLayer?.isText == true ? document.selectedLayerID : document.textLayers.last?.id else {
                return (document, ExecutionResult(outcome: .failed(message: fr ? "Aucun texte à supprimer." : "There's no text to remove."), effects: [ExecutionReason.noText.effect]))
            }
            document.removeLayer(id: layerID)
            return (document, .applied("Remove Text"))

        case .expandCanvas:
            let current = max(0.01, document.canvasSize.aspectRatio)
            var width = 0.8, height = 0.8
            if let aspect = intent.aspect?.value {
                if aspect > current { width = current / aspect; height = 1 } else { height = aspect / current; width = 1 }
                guard width < 0.97 || height < 0.97 else {
                    return (document, .failed(fr ? "La photo a déjà ce format." : "The photo already has that shape."))
                }
            } else if let factor = intent.amount?.value, factor > 1 {
                width = 1 / min(factor, 2)
                height = width
            }
            document.apply(.expand(PSRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)))
            return (document, .applied(intent.aspect.map { "Expand \($0.displayName)" } ?? "Expand"))

        case .upscale:
            let factor = (intent.amount?.value ?? 2).clamped(to: 2...4)
            document.apply(.upscale(factor: factor))
            return (document, .applied("Upscale \(Int(factor))×"))

        case .denoise:
            let amount = (intent.amount ?? .absolute(0.5)).resolve(current: document.activeAdjustments[.noiseReduction], range: 0...1)
            document.apply(.adjust(.noiseReduction, value: amount))
            return (document, .applied("Denoise"))

        case .sharpen:
            let amount = (intent.amount ?? .relative(0.25)).resolve(current: document.activeAdjustments[.sharpness], range: 0...1)
            document.apply(.adjust(.sharpness, value: amount))
            return (document, .applied("Sharpen"))

        case .relight:
            document.apply(.relight(direction: intent.degrees ?? 0, intensity: intent.amount?.value ?? 0.6))
            return (document, .applied("Relight"))

        case .selectLayer:
            if intent.text == "text", let layer = document.textLayers.last { document.selectedLayerID = layer.id; return (document, .effect(.selectLayer(layer.id), label: "Select Layer")) }
            if intent.text == "image", let base = document.baseLayerID { document.selectedLayerID = base; return (document, .effect(.selectLayer(base), label: "Select Layer")) }
            if let index = intent.index {
                let resolved = index == -1 ? document.layers.count : index
                if resolved >= 1, resolved <= document.layers.count {
                    let layer = document.layers[resolved - 1]
                    document.selectedLayerID = layer.id
                    return (document, .effect(.selectLayer(layer.id), label: "Select Layer"))
                }
            }
            return (document, .failed(fr ? "Calque introuvable." : "Layer not found."))

        case .duplicateLayer:
            guard let selected = document.selectedLayer else { return (document, .failed(fr ? "Aucun calque n'est sélectionné." : "No layer is selected.")) }
            var copy = selected
            copy.id = UUID()
            copy.name += " copy"
            document.addLayer(copy)
            return (document, .applied("Duplicate Layer", effects: [.selectLayer(copy.id)]))

        case .deleteLayer:
            guard let selected = document.selectedLayerID, document.removeLayer(id: selected) != nil else {
                return (document, .failed(fr ? "Impossible de supprimer ce calque." : "This layer can't be deleted."))
            }
            return (document, .applied("Delete Layer"))

        case .undo: return (document, .effect(.undo, label: ""))
        case .redo: return (document, .effect(.redo, label: ""))
        case .revert: return (document, .effect(.revert, label: ""))
        case .compare: return (document, .effect(.compare, label: ""))
        case .zoom: return (document, .effect(.zoom(intent.amount, intent.target), label: ""))
        case .describe:
            do {
                let scene = try await services.describe(document)
                let sentence = Replies.describe(scene, language: language)
                return (document, ExecutionResult(outcome: .info(message: sentence), effects: [.message("speak:" + sentence)]))
            } catch {
                return (document, failure(error))
            }
        case .saveVersion: return (document, .effect(.message("version:save:" + (intent.text ?? "")), label: ""))
        case .saveStyle: return (document, .effect(.message("style:save:" + (intent.text ?? "")), label: ""))
        case .applyStyle: return (document, .effect(.message("style:apply:" + (intent.text ?? "")), label: ""))
        case .summarizeEdits: return (document, .effect(.message("summary"), label: ""))
        case .restoreVersion: return (document, .effect(.message("version:restore:" + (intent.text ?? "")), label: ""))
        case .export: return (document, .effect(.export, label: ""))
        case .share: return (document, .effect(.share, label: ""))
        case .help: return (document, .effect(.help, label: ""))
        case .confirm:
            // « oui » to a model offer (W2): the session downloads the model and runs the pending call once it is installed.
            if let pending = context.pendingClarification, pending.candidates.isEmpty, let id = ModelOfferText.modelID(in: pending.question) {
                return (document, ExecutionResult(outcome: .info(message: ModelOfferText.installing(id, french: fr)), effects: [.message(ModelOfferText.installPrefix + id)]))
            }
            return (document, .effect(.confirm, label: ""))
        case .cancel: return (document, .effect(.cancel, label: ""))
        case .unknown:
            return (document, ExecutionResult(outcome: .info(message: Replies.reply(for: intent, language: language))))
        case .operation:
            guard let call = intent.operation, FeatureFlags.isOn(.catalogOps) else { return (document, unsupported(intent.summary)) }
            return await runOperation(call, on: document, context: context)
        default:
            return (document, unsupported(intent.summary))
        }
    }

    /// "Not on a photo": the failure of an action with no photo executor.
    func unsupported(_ summary: String) -> ExecutionResult {
        // In French the English action name never goes inside « ».
        let message = language == .french ? "Ça, je ne peux pas le faire sur une photo." : PicshopError.unsupportedOperation(summary).message(french: false)
        return ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.unsupported.effect])
    }

    // MARK: - Object removal

    /// - Parameter selection: the area circled after an earlier "circle it, then say it again";
    ///   a blur or a move of something not found there acts on it.
    func removeObject(target: ObjectTarget, intent: EditIntent, document: PhotoDocument, selection: MaskReference? = nil) async -> (PhotoDocument, ExecutionResult) {
        let fr = language == .french
        do {
            let candidates = try await services.candidates(for: target, in: document)
            switch CandidateSelector.select(from: candidates, for: target) {
            case .single(let candidate):
                return await apply(pendingIntent: intent, candidates: [candidate], document: document)
            case .multiple(let list):
                return await apply(pendingIntent: intent, candidates: list, document: document)
            case .ambiguous(let options):
                let request = ClarificationRequest(question: CandidateSelector.question(for: spoken(target), options: options, language: language), candidates: options, pendingIntent: intent)
                return (document, .clarify(request))
            case .none:
                // Nothing named that was seen: hand over to the finger instead of stopping at an error.
                if target.label == "object" || target.label == "blemish" {
                    let message = fr ? "Touche l'élément à effacer, ou décris-le (« le poteau à droite »)." : "Tap the thing to erase, or describe it (“the pole on the right”)."
                    return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("tapToErase")]))
                }
                let phrase = spoken(target).originalPhrase
                if intent.action == .removeObject {
                    let message = fr ? "Je ne trouve pas « \(phrase) ». Touche ou entoure ce qu'il faut effacer." : "I can't find “\(phrase)”. Tap or circle what to erase."
                    return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("tapToErase")]))
                }
                if let selection {
                    return applyOnSelection(intent, target: target, selection: selection, document: document)
                }
                let message = fr ? "Je ne trouve pas « \(phrase) ». Entoure la zone, puis redis la commande." : "I can't find “\(phrase)”. Circle the area, then say it again."
                return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("selectRegion")]))
            }
        } catch {
            return (document, failure(error))
        }
    }

    func apply(pendingIntent intent: EditIntent, candidates: [ObjectCandidate], document input: PhotoDocument,
               context: IntentContext = IntentContext(mode: .photo)) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let fr = language == .french
        // A mask or selection call that asked which one (W2): it runs again on the pick.
        if intent.action == .operation, let call = intent.operation {
            return await runOperation(call, on: input, context: context, chosen: candidates)
        }
        guard let target = intent.target else { return (document, .failed(fr ? "Dis-moi sur quoi agir, ou touche-le." : "Tell me what to act on, or tap it.")) }
        if intent.action == .selectiveAdjust, let parameter = intent.parameter,
           let lowered = await PhotoOperationHandlers.lowerSelective(intent, target: target, parameter: parameter, candidates: candidates, document: input,
                                                                     context: OperationRunContext(intent: context, language: language, services: services)) {
            return await checkedSelective(lowered, intent: intent, before: input)
        }
        do {
            let mask = try await services.mask(for: candidates, target: target, in: document)
            switch intent.action {
            case .selectiveAdjust:
                guard let parameter = intent.parameter else { return (document, .failed(fr ? "Je ne sais pas quel réglage changer." : "I don't know which setting to change.")) }
                let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                document.apply(.selectiveAdjust(mask, Self.selectiveAdjustments(parameter, value, on: target)))
                return (document, .applied("Selective \(parameter.englishName)"))
            case .crop:
                let rect = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }.insetBy(dx: -0.05, dy: -0.05).clampedToUnit()
                document.apply(.crop(rect))
                return (document, .applied("Crop to \(target.originalPhrase)"))
            case .generativeFill:
                guard let prompt = intent.text, !prompt.isEmpty else { return (document, .failed(fr ? "Dis-moi quoi mettre à la place." : "Tell me what to put there.")) }
                document.apply(.generativeFill(mask, prompt: prompt))
                return (document, .applied("Generate “\(prompt)”"))
            case .blurObject:
                document.apply(.blurRegion(mask, amount: (intent.amount?.value ?? 1).clamped(to: 0.2...1)))
                return (document, .applied(candidates.count > 1 ? "Blur \(candidates.count) × \(target.label)" : "Blur \(target.originalPhrase)"))
            case .moveObject:
                let box = candidates.map(\.boundingBox).reduce(candidates.first?.boundingBox ?? .zero) { $0.union($1) }
                return move(mask, box: box, intent: intent, target: target, document: document)
            case .recolor:
                guard let color = intent.color else { return (document, .failed(fr ? "Quelle couleur ?" : "Which colour?")) }
                document.apply(.recolor(mask, color, strength: (intent.amount?.value ?? 0.9).clamped(to: 0...1)))
                return (document, .applied("Recolor \(target.originalPhrase)"))
            default:
                document.apply(.removeObject(mask))
                let label = candidates.count > 1 ? "Remove \(candidates.count) × \(target.label)" : "Remove \(target.originalPhrase)"
                return (document, .applied(label))
            }
        } catch {
            return (document, failure(error))
        }
    }

    /// A blur or a move on an area the person circled.
    func applyOnSelection(_ intent: EditIntent, target: ObjectTarget, selection: MaskReference, document input: PhotoDocument) -> (PhotoDocument, ExecutionResult) {
        var document = input
        if intent.action == .moveObject {
            return move(selection, box: selection.boundingBox, intent: intent, target: target, document: document, circled: true)
        }
        document.apply(.blurRegion(selection, amount: (intent.amount?.value ?? 1).clamped(to: 0.2...1)))
        let said = language == .french ? "Je floute dans la sélection." : "Blurring in the selection."
        return (document, ExecutionResult(outcome: .applied(label: "Blur \(target.originalPhrase)"), effects: [.message("selectionUsed"), .message("speak:" + said)],
                                          label: "Blur \(target.originalPhrase)"))
    }

    /// Moves what `mask` covers (inside `box`) where the intent says, keeping it in the picture.
    /// `circled`: the mask is the person's selection, which is used up.
    func move(_ mask: MaskReference, box: PSRect, intent: EditIntent, target: ObjectTarget, document input: PhotoDocument, circled: Bool = false) -> (PhotoDocument, ExecutionResult) {
        var document = input
        var offset: PSPoint
        if intent.placement == .center {
            offset = PSPoint(x: 0.5 - box.midX, y: 0.5 - box.midY)
        } else {
            let distance = intent.amount?.value ?? 0.15
            let angle = (intent.degrees ?? 0) * .pi / 180
            offset = PSPoint(x: cos(angle) * distance, y: -sin(angle) * distance)
        }
        // It stays in the picture.
        offset.x = offset.x.clamped(to: -box.minX...max(-box.minX, 1 - box.maxX))
        offset.y = offset.y.clamped(to: -box.minY...max(-box.minY, 1 - box.maxY))
        guard abs(offset.x) + abs(offset.y) > 0.005 else {
            return (document, .failed(language == .french ? "Il touche déjà le bord." : "It's already against the edge."))
        }
        document.apply(.moveObject(mask, offset: offset))
        let label = "Move \(target.originalPhrase)"
        let said = language == .french ? "Je déplace ce qui est dans la sélection." : "Moving what is in the selection."
        return (document, ExecutionResult(outcome: .applied(label: label), effects: circled ? [.message("selectionUsed"), .message("speak:" + said)] : [], label: label))
    }

    // MARK: - Catalog operations (W2: pixel postconditions)

    /// A catalog operation through its handler, then its postconditions: the structural ones read off the two
    /// documents, and the pixel ones (D14) when the spec has them and `pixelPostconditions` is on, measured on
    /// 256 px proxies within 2 s. Live's verify step reads the merged report.
    func runOperation(_ call: OperationCall, on document: PhotoDocument, context: IntentContext, chosen: [ObjectCandidate]? = nil) async -> (PhotoDocument, ExecutionResult) {
        let run = OperationRunContext(intent: context, language: language, services: services, chosen: chosen)
        var (updated, result) = await PhotoOperationHandlers.run(call, on: document, context: run)
        guard result.outcome.isSuccess else { return (updated, result) }
        var report = OperationPostconditions.check(call, before: document, after: updated)
        if let spec = OperationCatalog.shared.spec(call.id), FeatureFlags.isOn(.pixelPostconditions) {
            let pixelConditions = spec.verify.filter { if case .pixels = $0 { return true } else { return false } }.count
            if pixelConditions > 0 {
                let verdict = await pixelVerdict(PixelPostconditions.plan(for: call, before: document, after: updated), before: document, after: updated)
                report = report.merged(with: verdict.report, replacing: pixelConditions)
                for note in verdict.notes { result.effects.append(.message("speak:" + PixelPostconditions.Note.text(note, french: language == .french))) }
            }
        }
        if !report.isEmpty { result.effects.append(OperationPostconditions.effect(report)) }
        return (updated, result)
    }

    /// selectiveAdjust lowered onto a local adjustment, with its pixel check (its parameter inside that mask).
    func checkedSelective(_ lowered: (PhotoDocument, ExecutionResult), intent: EditIntent, before: PhotoDocument) async -> (PhotoDocument, ExecutionResult) {
        var (updated, result) = lowered
        guard result.outcome.isSuccess, FeatureFlags.isOn(.pixelPostconditions) else { return (updated, result) }
        let verdict = await pixelVerdict(PixelPostconditions.plan(forSelective: intent, before: before, after: updated), before: before, after: updated)
        if !verdict.report.isEmpty { result.effects.append(OperationPostconditions.effect(verdict.report)) }
        return (updated, result)
    }

    /// The probes of a plan, all within one 2 s deadline (D14): a timeout or a host without probes is unverifiable.
    func pixelVerdict(_ plan: PixelPostconditions.Plan, before: PhotoDocument, after: PhotoDocument) async -> PixelPostconditions.Verdict {
        guard !plan.checks.isEmpty else { return PixelPostconditions.evaluate(plan, results: []) }
        let services = self.services
        let requests = plan.requests
        var others: [(PixelPostconditions.Baseline, PhotoDocument, [PixelProbeRequest])] = []
        for baseline in plan.otherBaselines {
            guard case .withoutAdjustment(let id) = baseline else { continue }
            var without = after
            without.removeLocalAdjustment(id: id)
            others.append((baseline, without, plan.checks.filter { $0.baseline == baseline }.map(\.request)))
        }
        let baselines = others
        let measured = await Deadline.race(.seconds(2)) { () -> ProbeRun? in
            let main = requests.isEmpty ? [] : await services.pixelProbes(requests, before: before, after: after)
            var extra: [PixelPostconditions.Baseline: [PixelProbeResult]] = [:]
            for (baseline, document, list) in baselines { extra[baseline] = await services.pixelProbes(list, before: document, after: after) }
            return ProbeRun(main: main, others: extra)
        }
        return PixelPostconditions.evaluate(plan, results: measured?.main, others: measured?.others ?? [:])
    }
}

/// The measured probes of one plan.
struct ProbeRun: Sendable {
    var main: [PixelProbeResult]
    var others: [PixelPostconditions.Baseline: [PixelProbeResult]]
}

extension PhotoCommandExecutor {

    /// The adjustment for a region, with what a retoucher would add: whiter
    /// teeth are brighter and less yellow, not only brighter.
    static func selectiveAdjustments(_ parameter: AdjustmentParameter, _ value: Double, on target: ObjectTarget) -> Adjustments {
        var adjustments = Adjustments([parameter: value])
        if target.label == "teeth", parameter == .brightness || parameter == .exposure, value > 0 {
            let strength = value / max(1e-6, parameter.range.upperBound)
            adjustments[.saturation] = -min(0.6, strength * 2.5) * AdjustmentParameter.saturation.range.upperBound
        }
        return adjustments
    }

    func currentBlurAmount(in document: PhotoDocument) -> Double {
        guard let layer = document.baseLayer else { return 0 }
        for operation in layer.edits.operations.reversed() {
            if case .blurBackground(let amount, _) = operation.kind { return amount }
        }
        return 0
    }

    func errorMessage(_ error: Error) -> String {
        if let known = error as? PicshopError { return known.message(french: language == .french) }
        return error.localizedDescription
    }

    /// A failure as the user reads it, with the reason code the model and Live read (D10): no subject on
    /// the picture, something not found.
    func failure(_ error: Error) -> ExecutionResult {
        var result = ExecutionResult.failed(errorMessage(error))
        switch error as? PicshopError {
        case .noSubject?: result.effects = [ExecutionReason.noSubject.effect]
        case .objectNotFound?: result.effects = [ExecutionReason.notFound.effect]
        default: break
        }
        return result
    }

    /// The target as it is said to the person: in French, an internal English label ("person", "the sign",
    /// a model's own word) becomes its French noun; the person's own words stay as they were.
    func spoken(_ target: ObjectTarget) -> ObjectTarget {
        guard language == .french else { return target }
        var said = target
        let phrase = target.originalPhrase.trimmingCharacters(in: .whitespaces)
        if let noun = PicshopError.frenchLabel(for: phrase.isEmpty ? target.label : phrase) {
            let feminine: Set<String> = ["personne", "personnes", "voiture", "main", "zone", "sélection", "lampe", "chaise", "bouteille", "tasse", "fenêtre",
                                         "ombre", "plaque", "vache", "moto", "peau", "case", "cases", "imperfection"]
            let plural = noun.hasSuffix("s") || noun.hasSuffix("x")
            let elided = ["a", "e", "i", "o", "u", "é", "â", "h"].contains { noun.hasPrefix($0) }
            said.originalPhrase = plural ? "les \(noun)" : elided ? "l'\(noun)" : feminine.contains(noun) ? "la \(noun)" : "le \(noun)"
        }
        return said
    }

    /// "Je ne trouve pas « la lampe » sur la photo.", in the person's words (never an internal English label), not_found.
    func notFound(_ target: ObjectTarget) -> ExecutionResult {
        let phrase = target.originalPhrase.trimmingCharacters(in: .whitespaces).isEmpty ? target.label : target.originalPhrase
        return failure(PicshopError.objectNotFound(phrase))
    }

    /// Size, colour, weight and design of an edit laid over a text element (editText, a whole table fill).
    static func restyle(_ element: inout TextElement, with intent: EditIntent) {
        if let color = intent.color { element.color = color }
        if let amount = intent.amount, amount.mode == .multiplier { element.relativeSize = (element.relativeSize * amount.value).clamped(to: 0.004...0.3) }
        if let amount = intent.amount, amount.mode == .absolute, amount.value > 0, amount.value < 0.3 { element.relativeSize = amount.value.clamped(to: 0.004...0.3) }
        guard let style = intent.textStyle else { return }
        let current = TableGrid.Style(relativeSize: element.relativeSize, color: element.color, weight: SceneMap.weight(ofFontNamed: element.fontName),
                                      design: SceneMap.design(ofFontNamed: element.fontName), alignment: element.alignment)
        let next = style.applied(to: current)
        element.relativeSize = next.relativeSize
        element.alignment = next.alignment
        // Table values keep their digit-aligned face; other text is plain SF Pro in the new weight.
        if style.weight != nil || style.design != nil { element.fontName = element.fontName.hasPrefix("SFProDigits") && next.design == .sans ? next.fontName : textFontName(next) }
    }
}
