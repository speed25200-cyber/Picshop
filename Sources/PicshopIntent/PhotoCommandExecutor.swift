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
        switch intent.action {
        case .removeObject:
            guard let target = intent.target else { return (document, .failed(PicshopError.objectNotFound("object").message)) }
            return await removeObject(target: target, intent: intent, document: document)

        case .chooseCandidate:
            guard let pending = context.pendingClarification else { return (document, ExecutionResult(outcome: .ignored)) }
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
                    let request = ClarificationRequest(question: CandidateSelector.question(for: target, options: candidates, language: language), candidates: candidates, pendingIntent: pending.pendingIntent)
                    return (document, .clarify(request))
                case .none: return (document, .failed(PicshopError.objectNotFound(target.originalPhrase).message))
                }
            } else {
                return (document, ExecutionResult(outcome: .ignored))
            }
            var resumed = pending.pendingIntent
            resumed.target?.matchesAll = chosen.count > 1
            return await apply(pendingIntent: resumed, candidates: chosen, document: document)

        case .removeBackground:
            do {
                let mask = try await services.subjectMask(in: document)
                document.apply(.removeBackground(mask))
                return (document, .applied("Remove Background"))
            } catch {
                return (document, .failed(errorMessage(error)))
            }

        case .replaceBackground:
            guard let background = intent.background else {
                return (document, .effect(.pickBackground, label: ""))
            }
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
                return (document, .failed(errorMessage(error)))
            }

        case .blurBackground:
            do {
                let mask = try await services.subjectMask(in: document)
                let current = currentBlurAmount(in: document)
                let amount = (intent.amount ?? .absolute(0.65)).resolve(current: current, range: 0...1)
                document.apply(.blurBackground(amount: amount, mask: mask))
                return (document, .applied("Blur Background"))
            } catch {
                return (document, .failed(errorMessage(error)))
            }

        case .adjust:
            guard let parameter = intent.parameter else { return (document, .failed("Unknown adjustment")) }
            let current = document.activeAdjustments[parameter]
            let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: current, range: parameter.range)
            document.apply(.adjust(parameter, value: value))
            return (document, .applied(EditOperation.Kind.adjust(parameter, value: value).defaultLabel))

        case .selectiveAdjust:
            guard let target = intent.target, let parameter = intent.parameter else { return (document, .failed("Missing target")) }
            do {
                let candidates = try await services.candidates(for: target, in: document)
                switch CandidateSelector.select(from: candidates, for: target) {
                case .single(let candidate):
                    let mask = try await services.mask(for: [candidate], target: target, in: document)
                    let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                    document.apply(.selectiveAdjust(mask, Adjustments([parameter: value])))
                    return (document, .applied("Selective \(parameter.englishName)"))
                case .multiple(let list):
                    let mask = try await services.mask(for: list, target: target, in: document)
                    let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                    document.apply(.selectiveAdjust(mask, Adjustments([parameter: value])))
                    return (document, .applied("Selective \(parameter.englishName)"))
                case .ambiguous(let options):
                    return (document, .clarify(ClarificationRequest(question: CandidateSelector.question(for: target, options: options, language: language), candidates: options, pendingIntent: intent)))
                case .none:
                    return (document, .failed(PicshopError.objectNotFound(target.originalPhrase).message))
                }
            } catch {
                return (document, .failed(errorMessage(error)))
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
                    guard let rect = framing else {
                        return (document, .failed(PicshopError.objectNotFound(target.originalPhrase).message))
                    }
                    document.apply(.crop(rect.clampedToUnit()))
                    return (document, .applied("Crop to \(target.originalPhrase)"))
                } catch {
                    return (document, .failed(errorMessage(error)))
                }
            }
            let aspect = intent.aspect ?? .free
            if aspect == .original {
                document.update(layerID: document.baseLayerID ?? UUID()) { layer in
                    layer.edits.operations.removeAll { if case .crop = $0.kind { return true } else { return false } }
                }
                if let base = document.baseLayer?.imageAsset { document.canvasSize = base.pixelSize }
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
                return (document, .failed(errorMessage(error)))
            }

        case .flip:
            let axis = intent.flipAxis ?? .horizontal
            document.apply(.flip(axis))
            return (document, .applied(axis == .horizontal ? "Flip Horizontal" : "Flip Vertical"))

        case .addText:
            guard let text = intent.text, !text.isEmpty else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Quel texte ?" : "What should it say?")))
            }
            var element = TextElement(text: text)
            element.center = (intent.placement ?? .bottom).center
            if let color = intent.color { element.color = color }
            if let amount = intent.amount, amount.mode == .absolute { element.relativeSize = amount.value }
            let layer = Layer(name: text, content: .text(element))
            document.addLayer(layer)
            return (document, .applied("Add Text", effects: [.selectLayer(layer.id)]))

        case .editText:
            guard let layerID = document.selectedLayer?.isText == true ? document.selectedLayerID : document.textLayers.last?.id else {
                return (document, .failed(fr ? "Aucun texte à modifier." : "There's no text to edit."))
            }
            document.update(layerID: layerID) { layer in
                guard var element = layer.textElement else { return }
                if let text = intent.text, !text.isEmpty { element.text = text; layer.name = text }
                if let placement = intent.placement { element.center = placement.center }
                if let color = intent.color { element.color = color }
                if let amount = intent.amount, amount.mode == .multiplier { element.relativeSize = (element.relativeSize * amount.value).clamped(to: 0.02...0.3) }
                layer.textElement = element
            }
            return (document, .applied("Edit Text"))

        case .removeText:
            guard let layerID = document.selectedLayer?.isText == true ? document.selectedLayerID : document.textLayers.last?.id else {
                return (document, .failed(fr ? "Aucun texte à supprimer." : "There's no text to remove."))
            }
            document.removeLayer(id: layerID)
            return (document, .applied("Remove Text"))

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
            guard let selected = document.selectedLayer else { return (document, .failed("No layer")) }
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
        case .export: return (document, .effect(.export, label: ""))
        case .share: return (document, .effect(.share, label: ""))
        case .help: return (document, .effect(.help, label: ""))
        case .confirm: return (document, .effect(.confirm, label: ""))
        case .cancel: return (document, .effect(.cancel, label: ""))
        case .unknown:
            return (document, ExecutionResult(outcome: .info(message: Replies.reply(for: intent, language: language))))
        default:
            return (document, .failed(PicshopError.unsupportedOperation(intent.summary).message))
        }
    }

    // MARK: - Object removal

    func removeObject(target: ObjectTarget, intent: EditIntent, document: PhotoDocument) async -> (PhotoDocument, ExecutionResult) {
        let fr = language == .french
        do {
            let candidates = try await services.candidates(for: target, in: document)
            switch CandidateSelector.select(from: candidates, for: target) {
            case .single(let candidate):
                return await apply(pendingIntent: intent, candidates: [candidate], document: document)
            case .multiple(let list):
                return await apply(pendingIntent: intent, candidates: list, document: document)
            case .ambiguous(let options):
                let request = ClarificationRequest(question: CandidateSelector.question(for: target, options: options, language: language), candidates: options, pendingIntent: intent)
                return (document, .clarify(request))
            case .none:
                if target.label == "object" || target.label == "blemish" {
                    let message = fr ? "Touche l'élément à effacer, ou décris-le (« le poteau à droite »)." : "Tap the thing to erase, or describe it (“the pole on the right”)."
                    return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("tapToErase")]))
                }
                return (document, .failed(PicshopError.objectNotFound(target.originalPhrase).message))
            }
        } catch {
            return (document, .failed(errorMessage(error)))
        }
    }

    func apply(pendingIntent intent: EditIntent, candidates: [ObjectCandidate], document input: PhotoDocument) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        guard let target = intent.target else { return (document, .failed("Missing target")) }
        do {
            let mask = try await services.mask(for: candidates, target: target, in: document)
            switch intent.action {
            case .selectiveAdjust:
                guard let parameter = intent.parameter else { return (document, .failed("Unknown adjustment")) }
                let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
                document.apply(.selectiveAdjust(mask, Adjustments([parameter: value])))
                return (document, .applied("Selective \(parameter.englishName)"))
            case .crop:
                let rect = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }.insetBy(dx: -0.05, dy: -0.05).clampedToUnit()
                document.apply(.crop(rect))
                return (document, .applied("Crop to \(target.originalPhrase)"))
            default:
                document.apply(.removeObject(mask))
                let label = candidates.count > 1 ? "Remove \(candidates.count) × \(target.label)" : "Remove \(target.originalPhrase)"
                return (document, .applied(label))
            }
        } catch {
            return (document, .failed(errorMessage(error)))
        }
    }

    func currentBlurAmount(in document: PhotoDocument) -> Double {
        guard let layer = document.baseLayer else { return 0 }
        for operation in layer.edits.operations.reversed() {
            if case .blurBackground(let amount, _) = operation.kind { return amount }
        }
        return 0
    }

    func errorMessage(_ error: Error) -> String {
        if let known = error as? PicshopError { return known.message }
        return error.localizedDescription
    }
}
