import Foundation
import PicshopCore

// W2 masks (§8.3): maskAdjust, maskEdit, maskDelete, the area resolution they share with the selection handlers,
// and selectiveAdjust lowered onto a local adjustment. Every change to a local adjustment goes through
// `PhotoDocument.applyLocalEdit(_:to:)` (creation through `setLocalAdjustment`), the same path as the Masques panel,
// so a voice edit and a tap give the same document. The honest paths come before any change: a region that is not
// in the picture (coverage under 0.2 %), a model that is not installed (an offer, the call kept pending), a flag
// that is off.

/// What a mask or a selection call names, read from its arguments (0…1000 values made 0…1).
struct MaskAreaArgs: Sendable {
    var region: MaskRegion?
    var isAll = false
    var isWand = false
    var ref: String?
    var target: String?
    var attributes: [String] = []
    var index: Int?
    var box: PSRect?
    var point: PSPoint?
    var color: String?
    var fuzziness: Double?
    var tolerance: Double?
    var contiguous: Bool?
    var sampleSize: Int?
    /// Where the thing is (« la personne à droite »): the call's `spatialHint`, else read from the target's words.
    var spatialHint: SpatialHint?

    /// `key` is "where" (masks) or "what" (select); `includesRef` is false for maskEdit, whose ref names the mask edited.
    init(_ args: [String: OpValue], key: String, includesRef: Bool = true) {
        switch args[key]?.string {
        case "all"?: isAll = true
        case "wand"?: isWand = true
        case let raw?: region = MaskRegion(rawValue: raw)
        case nil: break
        }
        if includesRef { ref = args["ref"]?.string?.lowercased().trimmingCharacters(in: .whitespaces) }
        target = args["target"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if case .list(let items)? = args["attributes"] { attributes = items.compactMap(\.string).filter { !$0.isEmpty } }
        index = args["index"]?.double.map { Int($0.rounded()) }
        box = args["box"].flatMap(MaskAreaArgs.normalizedBox)
        point = args["point"].flatMap(PhotoOperationHandlers.normalizedPoint)
        color = args["color"]?.string?.nonEmpty
        fuzziness = args["fuzziness"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        tolerance = args["tolerance"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        contiguous = args["contiguous"]?.bool
        sampleSize = args["sampleSize"]?.double.map { Int($0.rounded()) }
        spatialHint = args["spatialHint"]?.string.flatMap { SpatialHint(rawValue: $0) } ?? target.flatMap(PhotoOperationHandlers.spatialHint(in:))
    }

    /// Whether the call names an area at all.
    var namesSomething: Bool {
        region != nil || isAll || isWand || ref != nil || target != nil || box != nil || point != nil || (color != nil && region == nil)
    }

    /// [x1, y1, x2, y2] in 0…1000 → a normalised rect.
    static func normalizedBox(_ value: OpValue) -> PSRect? {
        var corners: [Double]?
        switch value {
        case .box(let rect): corners = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        case .list(let items) where items.count == 4: corners = items.compactMap(\.double)
        default: break
        }
        guard let corners, corners.count == 4, corners[2] > corners[0], corners[3] > corners[1] else { return nil }
        let unit = corners.map { ($0 / 1000).clamped(to: 0...1) }
        return PSRect(x: unit[0], y: unit[1], width: unit[2] - unit[0], height: unit[3] - unit[1])
    }
}

/// An area resolved to a mask component, with what it was made from.
struct MaskArea: Sendable {
    var kind: MaskComponent.Kind
    /// The component's own invert (the edges are the centre's radial, inverted).
    var isInverted = false
    var region: MaskRegion?
    /// An object noun (English), a person number, "teeth:1", a colour name.
    var label: String?
    /// Known coverage (an AI raster, a rasterised range); nil for gradients, which always cover part of the photo.
    var coverage: Double?
    var isApproximate = false
    var source: SelectionStep.Source
    /// The area found again by its region and label (find-or-create) rather than always made anew.
    var isFindable = true
}

/// A handler step's value, or the answer that ends the call.
enum Answered<Value> {
    case value(Value)
    case answer(ExecutionResult)
}

enum AreaOutcome: Sendable {
    case area(MaskArea)
    case answer(ExecutionResult)
}

extension String {
    /// nil for an empty string.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension PhotoOperationHandlers {
    /// A region covering less than this share of the picture is not there (D13).
    static let coverageFloor = 0.002
    /// The near and far depth ranges (0 far … 1 near).
    static let nearRange = 0.6...1.0
    static let farRange = 0.0...0.35

    // MARK: Gates and answers

    /// « Pas encore activé sur cet iPhone. »: a W2 flag is off.
    static func notEnabled(_ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        unavailable(context.french ? "Pas encore activé sur cet iPhone." : "That isn't turned on on this iPhone yet.", document)
    }

    static func answer(_ message: String, reason: ExecutionReason, effects: [EditorEffect] = []) -> ExecutionResult {
        ExecutionResult(outcome: .failed(message: message), effects: effects + [reason.effect])
    }

    static func info(_ message: String, effects: [EditorEffect] = []) -> ExecutionResult {
        ExecutionResult(outcome: .info(message: message), effects: effects)
    }

    /// « Je ne vois pas de ciel ici. » / "I can't see any sky here." (not_found), before any change.
    static func notSeen(_ area: (region: MaskRegion?, label: String?, phrase: String?), french: Bool) -> ExecutionResult {
        if area.region == .color, area.phrase == nil {
            return answer(french ? "Je ne vois pas cette couleur ici." : "I can't see that colour here.", reason: .notFound)
        }
        let english = area.phrase ?? spokenName(area.region, label: area.label, french: false)
        guard french else { return answer("I can't see any \(english) here.", reason: .notFound) }
        // A colour by its French name (« violet »), an object by its French label (« tasse »).
        let colour = area.region == .color ? area.phrase.flatMap(LiveMaskLines.frenchColour) : nil
        let noun = colour ?? area.phrase.map { PicshopError.frenchLabel(for: $0) ?? $0 } ?? spokenName(area.region, label: area.label, french: true)
        let elided = ["a", "e", "i", "o", "u", "y", "é", "è", "â", "h"].contains { noun.lowercased().hasPrefix($0) }
        return answer("Je ne vois pas \(elided ? "d'" : "de ")\(noun) ici.", reason: .notFound)
    }

    /// A region as said in a sentence: "ciel", "peau du visage", "tasse", "personne 2".
    static func spokenName(_ region: MaskRegion?, label: String?, french: Bool) -> String {
        guard let region else {
            guard let label else { return french ? "zone" : "area" }
            return french ? (PicshopError.frenchLabel(for: label) ?? label) : label
        }
        let name = MaskAccessibility.regionName(region, label: label, language: french ? .fr : .en)
        // Keep capitals only where a name is one ("Personne 2" → "personne 2").
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    /// The mask's name in the history: "Mask: Sky" (English titles, as the other labels).
    static func maskLabel(_ adjustment: LocalAdjustment) -> String {
        "Mask: " + MaskAccessibility.displayName(for: adjustment, language: .en)
    }

    /// What a service error means for the person, before any change.
    static func failure(_ error: Error, area: (region: MaskRegion?, label: String?, phrase: String?), call: OperationCall,
                        document: PhotoDocument, context: OperationRunContext) -> ExecutionResult {
        switch error as? PicshopError {
        case .modelUnavailable(let id)?:
            return modelOffer(id, call: call, context: context)
        case .objectNotFound?, .noSubject?:
            return notSeen(area, french: context.french)
        case .unsupportedOperation?:
            return answer(context.french ? "Les masques ne sont pas disponibles ici." : "Masks aren't available here.", reason: .unsupported)
        default:
            let message = (error as? PicshopError)?.message(french: context.french) ?? error.localizedDescription
            return ExecutionResult(outcome: .failed(message: message))
        }
    }

    /// A missing mask model (D13): the offer to download it, the call kept pending (`pendingClarification`) for « oui ».
    /// An installed model whose flag is off answers « Pas encore activé sur cet iPhone. ».
    static func modelOffer(_ id: String, call: OperationCall, context: OperationRunContext) -> ExecutionResult {
        let flagOn = id == ModelOfferText.depthID ? FeatureFlags.isOn(.depthModel) : FeatureFlags.isOn(.samModel)
        guard flagOn else {
            return answer(context.french ? "Pas encore activé sur cet iPhone." : "That isn't turned on on this iPhone yet.", reason: .unsupported)
        }
        let question = ModelOfferText.question(for: id, french: context.french)
        let request = ClarificationRequest(question: question, candidates: [], pendingIntent: EditIntent(action: .operation, confidence: 0.85, operation: call))
        return ExecutionResult(outcome: .needsClarification(request), effects: [.message(ModelOfferText.offerPrefix + id)])
    }

    // MARK: Area resolution

    /// The area a call names, in the order of §8.3: a ref, a box, a point, then `where` / `what` (AI regions,
    /// people parts, objects through the legacy candidates, parametric regions, depth, the selection), then a
    /// target alone. `context.chosen` (the person's pick after a question) resolves an object without asking again.
    static func resolveArea(_ area: MaskAreaArgs, call: OperationCall, document: PhotoDocument, context: OperationRunContext) async -> AreaOutcome {
        let services = context.services
        let french = context.french
        let noun = area.target.map(canonicalNoun)
        func ai(_ request: AIMaskRequest, region: MaskRegion?, label: String?, source: SelectionStep.Source, phrase: String? = nil,
                findable: Bool = true) async -> AreaOutcome {
            do {
                let result = try await services.aiMask(request, in: document)
                let rasterLabel = result.raster.label ?? label
                return .area(MaskArea(kind: .raster(result.raster), region: region, label: label ?? rasterLabel, coverage: result.coverage,
                                      isApproximate: result.isApproximate, source: source, isFindable: findable))
            } catch {
                return .answer(failure(error, area: (region, label, phrase), call: call, document: document, context: context))
            }
        }

        // The person picked among the candidates a question offered.
        if let chosen = context.chosen, !chosen.isEmpty {
            let label = noun ?? chosen.first?.label ?? "object"
            let region = area.region ?? regionFor(noun: label) ?? .object
            let target = ObjectTarget(label: legacyLabel(region) ?? label, originalPhrase: area.target, attributes: area.attributes)
            return await ai(.candidates(chosen, target: target), region: region, label: region == .object ? label : nil, source: source(of: region),
                            phrase: area.target)
        }
        // 1–2. A ref: another mask (rasterised) or a scene object.
        if let ref = area.ref, let letter = ref.first, let number = Int(ref.dropFirst()), number >= 1 {
            switch letter {
            case "a":
                let masks = document.localAdjustments
                guard number <= masks.count else { return .answer(unknownMask(ref, document: document, french: french)) }
                do {
                    let result = try await services.rasterize(masks[number - 1].stack, in: document)
                    return .area(MaskArea(kind: .raster(result.raster), region: nil, label: ref, coverage: result.coverage, source: .mask, isFindable: false))
                } catch {
                    return .answer(failure(error, area: (nil, nil, ref), call: call, document: document, context: context))
                }
            case "o":
                let object = context.intent.scene?.objects.first { $0.id == ref }
                let label = object?.label ?? noun ?? "object"
                return await ai(.sceneObject(number), region: .object, label: label, source: .object, phrase: object?.label, findable: false)
            default:
                return .answer(answer(french ? "\(ref) n'est pas un masque ni un objet de la photo." : "\(ref) is not a mask or an object of the photo.",
                                      reason: .unknownRef))
            }
        }
        // 3. A box (the model's 0–1000 box): SAM on it.
        if let box = area.box {
            let region = area.region.flatMap { $0.isAI ? $0 : nil } ?? .object
            return await ai(.box(box, label: noun), region: region, label: noun, source: source(of: region), phrase: area.target, findable: noun != nil)
        }
        // 4. A point: a colour sampled there, the wand there, else SAM on it (never SAM for colour or wand).
        if let point = area.point {
            if area.region == .color || (area.isWand == false && area.region == nil && area.color != nil) {
                return await sampledColor(at: point, area: area, call: call, document: document, context: context)
            }
            if area.isWand { return await wand(at: point, area: area, call: call, document: document, context: context) }
            return await ai(.points([MaskPrompt(point)], label: noun), region: .object, label: noun, source: .object, phrase: area.target,
                            findable: noun != nil)
        }
        if area.isAll {
            let everything = MaskComponent.Kind.radial(RadialGradientSpec(center: PSPoint(x: 0.5, y: 0.5), radiusX: 2, radiusY: 2, rotation: 0, feather: 0))
            return .area(MaskArea(kind: everything, region: nil, label: nil, coverage: 1, source: .all, isFindable: false))
        }
        if area.isWand {
            return .answer(answer(french ? "Touche l'endroit à sélectionner à la baguette magique." : "Tap where the magic wand should start.",
                                  reason: .needsSelection, effects: [.message("selectRegion")]))
        }
        // 5. A region.
        guard let region = area.region ?? noun.flatMap(regionFor(noun:)) else {
            if let color = area.color { return colorArea(color, area: area, document: document, context: context) }
            return .answer(answer(french ? "Sur quelle zone ? Nomme-la (« le ciel », « le bas ») ou touche-la." : "Which area? Name it (“the sky”, “the bottom”) or tap it.",
                                  reason: .needsSelection, effects: [.message("selectRegion")]))
        }
        switch region {
        case .subject: return await ai(.subject, region: .subject, label: nil, source: .subject)
        case .background: return await ai(.background, region: .background, label: nil, source: .background)
        case .people: return await ai(.people, region: .people, label: nil, source: .people)
        case .sky: return await ai(.sky, region: .sky, label: nil, source: .sky)
        case .vegetation: return await ai(.vegetation, region: .vegetation, label: nil, source: .region)
        case .water: return await ai(.water, region: .water, label: nil, source: .region)
        case .person:
            // « la personne de droite » with no number: the candidates ranked by where they are, as an object.
            if area.index == nil, let hint = area.spatialHint {
                let target = ObjectTarget(label: "person", originalPhrase: area.target, spatialHint: hint, attributes: area.attributes)
                return await legacyArea(target, region: .object, call: call, document: document, context: context)
            }
            let index = max(1, area.index ?? 1)
            return await ai(.person(index: index), region: .person, label: String(index), source: .person)
        case .face, .faceSkin, .eyes, .lips, .teeth:
            if let index = area.index {
                return await ai(.personPart(region, person: index), region: region, label: "\(region.rawValue):\(index)", source: .facePart)
            }
            let target = ObjectTarget(label: legacyLabel(region) ?? region.rawValue, originalPhrase: area.target, attributes: area.attributes)
            return await legacyArea(target, region: region, call: call, document: document, context: context)
        case .hair, .bodySkin:
            return await ai(.personPart(region, person: nil), region: region, label: nil, source: .facePart)
        case .object:
            guard let noun else {
                return .answer(answer(french ? "Quel objet ? Nomme-le ou touche-le." : "Which object? Name it or tap it.", reason: .needsSelection,
                                      effects: [.message("selectRegion")]))
            }
            let target = ObjectTarget(label: noun, originalPhrase: area.target, spatialHint: area.spatialHint, attributes: area.attributes)
            return await legacyArea(target, region: .object, call: call, document: document, context: context)
        case .color:
            guard let color = area.color else {
                return .answer(answer(french ? "Quelle couleur ? Nomme-la ou touche-la sur la photo." : "Which colour? Name it or tap it on the photo.",
                                      reason: .needsSelection, effects: [.message("selectRegion")]))
            }
            return colorArea(color, area: area, document: document, context: context)
        case .near, .far:
            do {
                let depth = try await services.depthMap(in: document)
                let range = region == .near ? nearRange : farRange
                return .area(MaskArea(kind: .depthRange(DepthRangeSpec(depth: depth, low: range.lowerBound, high: range.upperBound, feather: 0.15)),
                                      region: region, label: nil, coverage: nil, source: .region))
            } catch {
                return .answer(failure(error, area: (region, nil, nil), call: call, document: document, context: context))
            }
        case .selection:
            guard let selection = document.selection else {
                return .answer(answer(french ? "Il n'y a pas de sélection : sélectionne d'abord quelque chose." : "There's no selection: select something first.",
                                      reason: .needsSelection))
            }
            return .area(MaskArea(kind: .raster(selection.raster), region: .selection, label: nil, coverage: selection.coverage, source: .mask, isFindable: false))
        case .top, .bottom, .left, .right, .center, .edges, .shadows, .midtones, .highlights, .skinTones:
            guard let component = MaskStack.defaultComponent(for: region, aspect: document.localAdjustmentsAspect) else {
                return .answer(answer(french ? "Je ne sais pas faire ce masque." : "I can't make that mask.", reason: .unsupported))
            }
            let source: SelectionStep.Source
            switch region {
            case .shadows, .midtones, .highlights: source = .luminanceRange
            case .skinTones: source = .colorRange
            default: source = .region
            }
            return .area(MaskArea(kind: component.kind, isInverted: component.isInverted, region: region, label: nil, coverage: nil, source: source))
        }
    }

    /// An object or a face part without an index, exactly as selectiveAdjust resolves it (W1): the candidates, a
    /// question when several fit, the exact landmark and instance masks of `mask(for:target:in:)` through
    /// `.candidates`; nothing found → the VLM box (`groundBox`), and still nothing → « Touche-la ou entoure-la ».
    static func legacyArea(_ target: ObjectTarget, region: MaskRegion, call: OperationCall, document: PhotoDocument,
                           context: OperationRunContext) async -> AreaOutcome {
        let services = context.services
        let executor = PhotoCommandExecutor(services: services, language: context.language)
        let label = region == .object ? target.label : nil
        let phrase = target.originalPhrase
        let candidates: [ObjectCandidate]
        do {
            candidates = try await services.candidates(for: target, in: document)
        } catch {
            return .answer(failure(error, area: (region, label, phrase), call: call, document: document, context: context))
        }
        var chosen: [ObjectCandidate] = []
        switch CandidateSelector.select(from: candidates, for: target) {
        case .single(let candidate): chosen = [candidate]
        case .multiple(let list): chosen = list
        case .ambiguous(let options):
            let request = ClarificationRequest(question: CandidateSelector.question(for: executor.spoken(target), options: options, language: context.language),
                                               candidates: options, pendingIntent: EditIntent(action: .operation, confidence: 0.85, operation: call))
            return .answer(.clarify(request))
        case .none:
            break
        }
        if chosen.isEmpty {
            let words = (target.attributes + [target.label]).joined(separator: " ")
            if let box = await services.groundBox(words, in: document) {
                do {
                    let result = try await services.aiMask(.box(box, label: target.label), in: document)
                    return .area(MaskArea(kind: .raster(result.raster), region: region, label: label, coverage: result.coverage,
                                          isApproximate: result.isApproximate, source: source(of: region)))
                } catch {
                    return .answer(failure(error, area: (region, label, phrase), call: call, document: document, context: context))
                }
            }
            let said = executor.spoken(target).originalPhrase
            let message = context.french ? "Je ne trouve pas « \(said) ». Touche-la ou entoure-la." : "I can't find “\(said)”. Tap it or circle it."
            return .answer(answer(message, reason: .needsSelection, effects: [.message("selectRegion")]))
        }
        do {
            let result = try await services.aiMask(.candidates(chosen, target: target), in: document)
            let rasterLabel = region == .object ? label : (result.raster.label ?? nil)
            return .area(MaskArea(kind: .raster(result.raster), region: region, label: rasterLabel, coverage: result.coverage,
                                  isApproximate: result.isApproximate, source: source(of: region)))
        } catch {
            return .answer(failure(error, area: (region, label, phrase), call: call, document: document, context: context))
        }
    }

    /// A colour range from a colour name: a hue family is its preset (« les rouges »), any other colour a Lab sample.
    static func colorArea(_ name: String, area: MaskAreaArgs, document: PhotoDocument, context: OperationRunContext) -> AreaOutcome {
        let fuzziness = area.fuzziness ?? 0.4
        if let preset = colorPreset(named: name) {
            return .area(MaskArea(kind: .colorRange(ColorRangeSpec(samples: [], fuzziness: fuzziness, preset: preset)), region: .color, label: preset.rawValue,
                                  coverage: nil, source: .colorRange))
        }
        guard let color = PSColor.named(name) ?? PSColor(hex: name) else {
            return .answer(answer(context.french ? "Je ne connais pas cette couleur." : "I don't know that colour.", reason: .badRegion))
        }
        return .area(MaskArea(kind: .colorRange(ColorRangeSpec(samples: [MaskMath.lab(color)], fuzziness: fuzziness)), region: .color,
                              label: name.lowercased(), coverage: nil, source: .colorRange))
    }

    /// The hue families a colour name stands for (the Color Range presets).
    static func colorPreset(named name: String) -> ColorRangeSpec.Preset? {
        let key = name.lowercased().folding(options: [.diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
        let table: [String: ColorRangeSpec.Preset] = [
            "red": .reds, "reds": .reds, "rouge": .reds, "rouges": .reds, "orange": .oranges, "oranges": .oranges,
            "yellow": .yellows, "yellows": .yellows, "jaune": .yellows, "jaunes": .yellows, "green": .greens, "greens": .greens, "vert": .greens,
            "verts": .greens, "verte": .greens, "cyan": .cyans, "cyans": .cyans, "turquoise": .cyans, "teal": .cyans, "blue": .blues, "blues": .blues,
            "bleu": .blues, "bleus": .blues, "bleue": .blues, "magenta": .magentas, "magentas": .magentas, "purple": .magentas, "violet": .magentas,
            "violets": .magentas, "pink": .magentas, "rose": .magentas, "skin": .skinTones, "skin tones": .skinTones, "tons chair": .skinTones,
        ]
        return table[key]
    }

    /// The colour under a point (a 7×7 sample of the pre-local base) as a colour range.
    static func sampledColor(at point: PSPoint, area: MaskAreaArgs, call: OperationCall, document: PhotoDocument, context: OperationRunContext) async -> AreaOutcome {
        do {
            let samples = try await context.services.sampleColors(at: [point], radius: 3, in: document)
            guard let sample = samples.first else { return .answer(notSeen((.color, nil, nil), french: context.french)) }
            return .area(MaskArea(kind: .colorRange(ColorRangeSpec(samples: [sample], fuzziness: area.fuzziness ?? 0.4)), region: .color, label: nil,
                                  coverage: nil, source: .colorRange, isFindable: false))
        } catch {
            return .answer(failure(error, area: (.color, nil, nil), call: call, document: document, context: context))
        }
    }

    /// The Lab magic wand at a point; a host without it samples the colour there (a colour range, not contiguous).
    static func wand(at point: PSPoint, area: MaskAreaArgs, call: OperationCall, document: PhotoDocument, context: OperationRunContext) async -> AreaOutcome {
        let size = [1, 3, 5].min { abs($0 - (area.sampleSize ?? 3)) < abs($1 - (area.sampleSize ?? 3)) } ?? 3
        do {
            let result = try await context.services.wandMask(at: point, tolerance: area.tolerance ?? 0.32, contiguous: area.contiguous ?? true,
                                                             sampleSize: size, in: document)
            return .area(MaskArea(kind: .raster(result.raster), region: nil, label: nil, coverage: result.coverage, isApproximate: result.isApproximate,
                                  source: .wand, isFindable: false))
        } catch PicshopError.unsupportedOperation(_) {
            var sampled = area
            sampled.fuzziness = area.tolerance ?? area.fuzziness
            let outcome = await sampledColor(at: point, area: sampled, call: call, document: document, context: context)
            guard case .area(var made) = outcome else { return outcome }
            made.source = .wand
            return .area(made)
        } catch {
            return .answer(failure(error, area: (nil, nil, nil), call: call, document: document, context: context))
        }
    }

    /// The parametric component's handles from the call (start/end; centre, radius, rotation, roundness), in place.
    static func shaped(_ kind: MaskComponent.Kind, _ args: [String: OpValue]) -> MaskComponent.Kind {
        switch kind {
        case .linear(var spec):
            if let start = args["start"].flatMap(normalizedPoint) { spec.start = start }
            if let end = args["end"].flatMap(normalizedPoint) { spec.end = end }
            return .linear(spec)
        case .radial(var spec):
            if let center = args["center"].flatMap(normalizedPoint) { spec.center = center }
            let ratio = spec.radiusX > 0 ? spec.radiusY / spec.radiusX : 1
            if let radius = args["radius"]?.double {
                spec.radiusX = (radius / 100).clamped(to: 0.01...1)
                spec.radiusY = spec.radiusX * ratio
            }
            if let roundness = args["roundness"]?.double {
                spec.radiusY = spec.radiusX * (roundness / 100).clamped(to: 0.1...1)
            }
            if let rotation = args["rotation"]?.double { spec.rotation = rotation.clamped(to: -180...180) }
            return .radial(spec)
        default:
            return kind
        }
    }

    static func hasShape(_ args: [String: OpValue]) -> Bool {
        ["start", "end", "center", "radius", "rotation", "roundness"].contains { args[$0] != nil }
    }

    /// The position or size `phrase` says (« personne à droite » → right, "left person" → left, « grande tasse » →
    /// largest), and the words that said it; the longest alias wins (« tout à droite » is rightmost, not right).
    static func spatialMatch(in phrase: String) -> (hint: SpatialHint, alias: String)? {
        let words = NormalizedUtterance(phrase)
        var best: (hint: SpatialHint, alias: String)?
        for hint in SpatialHint.allCases {
            for alias in hint.aliases where alias.count > (best?.alias.count ?? 0) && words.containsPhrase(alias) {
                best = (hint, alias)
            }
        }
        return best
    }

    static func spatialHint(in phrase: String) -> SpatialHint? {
        spatialMatch(in: phrase)?.hint
    }

    /// A noun the model or the person wrote (French or English) as the canonical English label ("tasse" → cup).
    static func canonicalNoun(_ text: String) -> String {
        if let match = ObjectVocabulary.match(text) { return match.entry.label }
        return text.lowercased()
    }

    /// The mask region a noun stands for when the call names no `where`: sky, teeth, a face… else an object.
    static func regionFor(noun: String) -> MaskRegion? {
        switch canonicalNoun(noun) {
        case "sky", "cloud": return .sky
        case "background": return .background
        case "subject": return .subject
        case "people": return .people
        case "person": return .person
        case "face": return .face
        case "skin": return .faceSkin
        case "eyes": return .eyes
        case "lips": return .lips
        case "teeth": return .teeth
        case "hair": return .hair
        case "grass", "tree", "plant", "vegetation": return .vegetation
        case "water": return .water
        default: return .object
        }
    }

    /// The legacy candidates' label of a people part (W1's selectiveAdjust targets).
    static func legacyLabel(_ region: MaskRegion) -> String? {
        switch region {
        case .face: return "face"
        case .faceSkin: return "skin"
        case .eyes: return "eyes"
        case .lips: return "lips"
        case .teeth: return "teeth"
        case .hair: return "hair"
        default: return nil
        }
    }

    /// How a selection step names the region it came from.
    static func source(of region: MaskRegion) -> SelectionStep.Source {
        switch region {
        case .subject: return .subject
        case .background: return .background
        case .sky: return .sky
        case .people: return .people
        case .person: return .person
        case .face, .faceSkin, .eyes, .lips, .teeth, .hair, .bodySkin: return .facePart
        case .object: return .object
        case .color, .skinTones: return .colorRange
        case .shadows, .midtones, .highlights: return .luminanceRange
        case .selection: return .mask
        case .vegetation, .water, .top, .bottom, .left, .right, .center, .edges, .near, .far: return .region
        }
    }

    /// The pixel-dependent and depth parts have no coverage until rendered: a host that can rasterise measures them.
    static func measuredCoverage(_ area: MaskArea, document: PhotoDocument, context: OperationRunContext) async -> Double? {
        if let coverage = area.coverage { return coverage }
        switch area.kind {
        case .colorRange, .luminanceRange, .depthRange:
            return try? await context.services.rasterize(MaskStack.single(MaskComponent(area.kind)), in: document).coverage
        default:
            return nil
        }
    }

    // MARK: Refs

    /// "a3" that is not there: the masks that are, so the model corrects itself in one round.
    static func unknownMask(_ ref: String, document: PhotoDocument, french: Bool) -> ExecutionResult {
        let names = MaskAccessibility.displayNames(for: document.localAdjustments, language: french ? .fr : .en)
        let list = names.enumerated().map { "a\($0.offset + 1) \($0.element)" }.joined(separator: ", ")
        if names.isEmpty {
            return answer(french ? "Il n'y a pas encore de masque." : "There's no mask yet.", reason: .unknownRef)
        }
        return answer(french ? "Il n'y a pas de masque \(ref). Masques : \(list)." : "There's no mask \(ref). Masks: \(list).", reason: .unknownRef)
    }

    /// The local adjustment a call edits: its `ref`, else the one the last step made or changed, else the newest.
    static func targetMask(_ call: OperationCall, document: PhotoDocument, context: OperationRunContext) -> Answered<LocalAdjustment> {
        let masks = document.localAdjustments
        guard !masks.isEmpty else {
            return .answer(answer(context.french ? "Il n'y a pas encore de masque. Dis par exemple « assombris le bas »."
                                                  : "There's no mask yet. Say for example “darken the bottom”.", reason: .nothingToDo))
        }
        if let ref = call.args["ref"]?.string?.lowercased() {
            guard ref.first == "a", let number = Int(ref.dropFirst()), number >= 1, number <= masks.count else {
                return .answer(unknownMask(ref, document: document, french: context.french))
            }
            return .value(masks[number - 1])
        }
        if let last = context.intent.lastIntent, last.action == .operation, let previous = last.operation,
           ["maskAdjust", "maskEdit"].contains(previous.id.raw) {
            if let ref = previous.args["ref"]?.string?.lowercased(), ref.first == "a", let number = Int(ref.dropFirst()), number >= 1, number <= masks.count {
                return .value(masks[number - 1])
            }
            if let raw = previous.args["where"]?.string, let region = MaskRegion(rawValue: raw),
               let match = masks.last(where: { $0.region == region }) {
                return .value(match)
            }
        }
        return .value(masks[masks.count - 1])
    }

    // MARK: maskAdjust

    /// A local adjustment on an area: find-or-create (the same region and label, or the `ref`), then its dials,
    /// curve, HSL subset or local colour, each through `applyLocalEdit`.
    static func maskAdjust(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.masks) else { return notEnabled(document, context) }
        guard document.localAdjustmentsLayerID != nil else { return unavailable(context.french ? "Il faut une photo." : "This needs a photo.", document) }
        if call.args["parameter"]?.string == AdjustmentParameter.vignette.rawValue {
            return unavailable(context.french ? "Le vignettage se règle sur toute la photo, pas dans un masque." : "Vignette applies to the whole photo, not inside a mask.",
                               document, reason: .unsupported)
        }
        var adjustment: LocalAdjustment
        var created = false
        var approximate = false
        let args = MaskAreaArgs(call.args, key: "where")
        // A follow-up that names no area (« encore », « plus sombre » after « éclaircis la sélection ») adjusts the
        // mask the step before worked on; `targetMask` ends on the newest, the one selectionApply made.
        let previous = context.intent.lastIntent?.operation
        let followsAMask = ["maskAdjust", "maskEdit"].contains(previous?.id.raw ?? "")
            || (previous?.id.raw == "selectionApply" && previous?.args["use"]?.string == "adjust")
        if let ref = args.ref, ref.first == "a" {
            switch targetMask(call, document: document, context: context) {
            case .value(let found): adjustment = found
            case .answer(let result): return (document, result)
            }
        } else if !args.namesSomething, !hasShape(call.args), followsAMask, !document.localAdjustments.isEmpty {
            switch targetMask(call, document: document, context: context) {
            case .value(let found): adjustment = found
            case .answer(let result): return (document, result)
            }
        } else {
            let outcome = await resolveArea(args, call: call, document: document, context: context)
            guard case .area(var area) = outcome else {
                if case .answer(let result) = outcome { return (document, result) }
                return (document, .failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
            }
            if hasShape(call.args) { area.kind = shaped(area.kind, call.args) }
            if let coverage = await measuredCoverage(area, document: document, context: context), coverage < coverageFloor {
                return (document, notSeen((area.region, area.label, args.target ?? (area.region == .color ? args.color : nil)), french: context.french))
            }
            approximate = area.isApproximate
            let existing = area.isFindable && area.region != nil
                ? document.localAdjustments.last { $0.matches(region: area.region ?? .object, label: area.label) && sameKind($0, area) }
                : nil
            if let existing {
                adjustment = existing
            } else {
                guard document.canAddLocalAdjustment else {
                    return (document, answer(context.french ? "Il y a déjà 16 masques : supprime-en un." : "There are already 16 masks: delete one.",
                                             reason: .tooMany))
                }
                let component = MaskComponent(area.kind, isInverted: area.isInverted)
                adjustment = LocalAdjustment(region: area.region, label: area.label, stack: MaskStack.single(component))
                created = true
            }
        }
        var updated = document
        if created { updated.setLocalAdjustment(adjustment, label: maskLabel(adjustment)) }
        let edits: [LocalAdjustmentEdit]
        switch effectEdits(call, on: adjustment, context: context) {
        case .value(let list): edits = list
        case .answer(let result): return (document, result)
        }
        var changed = created
        for edit in edits where updated.applyLocalEdit(edit, to: adjustment.id) { changed = true }
        guard changed else {
            return (document, info(context.french ? "Ce masque est déjà réglé ainsi." : "That mask is already set that way."))
        }
        let final = updated.localAdjustment(id: adjustment.id) ?? adjustment
        var result = ExecutionResult.applied(maskLabel(final))
        if approximate {
            let caption = context.french ? "\(spokenName(final.region, label: final.label, french: true).capitalizedFirst) approximatif : affine-le au pinceau."
                                         : "\(spokenName(final.region, label: final.label, french: false).capitalizedFirst) is approximate: refine it with the brush."
            result.effects.append(.message("speak:" + caption))
        }
        return (updated, result)
    }

    /// An existing adjustment made from the same kind of component (a colour mask is not a sky mask of the same name).
    static func sameKind(_ adjustment: LocalAdjustment, _ area: MaskArea) -> Bool {
        guard let first = adjustment.stack.components.first else { return false }
        switch (first.kind, area.kind) {
        case (.raster, .raster), (.linear, .linear), (.radial, .radial), (.colorRange, .colorRange), (.luminanceRange, .luminanceRange),
             (.depthRange, .depthRange), (.brush, .brush):
            return true
        default:
            return false
        }
    }

    /// The effect of a maskAdjust (or a selectionApply adjust) call on an adjustment, as LocalAdjustmentEdits:
    /// a dial (relative adds amount/100 × its range, absolute sets; the teeth rule), a curve preset, a band of the
    /// HSL subset, a local colour, the mask's feather.
    static func effectEdits(_ call: OperationCall, on adjustment: LocalAdjustment, context: OperationRunContext) -> Answered<[LocalAdjustmentEdit]> {
        var edits: [LocalAdjustmentEdit] = []
        let absolute = call.args["amountMode"]?.string == "absolute"
        let amount = call.args["amount"]?.double
        if let name = call.args["parameter"]?.string, let parameter = AdjustmentParameter(rawValue: name) {
            guard parameter != .vignette else {
                return .answer(answer(context.french ? "Le vignettage se règle sur toute la photo, pas dans un masque." : "Vignette applies to the whole photo, not inside a mask.",
                                       reason: .unsupported))
            }
            let range = parameter.range
            let current = adjustment.adjustments[parameter]
            let value: Double
            if let amount {
                value = (absolute ? amount / 100 * range.upperBound : current + amount / 100 * range.upperBound).clamped(to: range)
            } else {
                value = (current + parameter.defaultStep).clamped(to: range)
            }
            edits.append(.setDial(parameter, value))
            // Whiter teeth are also less yellow (W1's rule, on the new value).
            if adjustment.region == .teeth || adjustment.label?.hasPrefix("teeth") == true, parameter == .brightness || parameter == .exposure, value > current {
                let rule = PhotoCommandExecutor.selectiveAdjustments(parameter, value, on: ObjectTarget(label: "teeth"))[.saturation]
                if rule < adjustment.adjustments[.saturation] { edits.append(.setDial(.saturation, rule)) }
            }
        }
        if let preset = call.args["curve"]?.string {
            let strength = ((amount.map(abs) ?? 50) / 100).clamped(to: 0...1)
            guard let points = presetPoints(preset, strength: strength) else {
                return .answer(answer(context.french ? "Je ne connais pas cette courbe." : "I don't know that curve.", reason: .badRegion))
            }
            var curve = adjustment.curve ?? .identity
            curve.setPoints(points, for: .rgb)
            edits.append(.setCurve(curve))
        }
        if let name = call.args["band"]?.string {
            guard let band = ColorMixer.Band.allCases.first(where: { $0.englishName.lowercased() == name.lowercased() }) ?? ColorMixer.Band.matching(name) else {
                return .answer(answer(context.french ? "Quelle couleur ? Rouges, oranges, jaunes, verts, cyans, bleus, violets ou magentas." : "Which colour band?",
                                       reason: .badRegion))
            }
            var mixer = adjustment.mixer ?? .neutral
            var any = false
            for (key, channel) in [("hue", ColorMixer.Channel.hue), ("saturation", .saturation), ("luminance", .luminance)] {
                guard let value = call.args[key]?.double else { continue }
                let delta = (value / 100).clamped(to: -1...1)
                mixer[band, channel] = absolute ? delta : mixer[band, channel] + delta
                any = true
            }
            if !any, let amount {
                mixer[band, .saturation] = absolute ? (amount / 100).clamped(to: -1...1) : mixer[band, .saturation] + (amount / 100).clamped(to: -1...1)
                any = true
            }
            guard any else {
                return .answer(answer(context.french ? "Teinte, saturation ou luminance ?" : "Hue, saturation or luminance?", reason: .badRegion))
            }
            edits.append(.setMixer(mixer))
        }
        if let name = call.args["localColor"]?.string {
            guard let color = PSColor.named(name) ?? PSColor(hex: name) else {
                return .answer(answer(context.french ? "Je ne connais pas cette couleur." : "I don't know that colour.", reason: .badRegion))
            }
            let hue = ColorEngine.hsl(fromRGB: (color.red, color.green, color.blue)).0
            let strength = ((call.args["localColorAmount"]?.double ?? 30) / 100).clamped(to: 0...1)
            let wheel = ColorWheel(hue: hue, amount: strength, luminance: 0)
            edits.append(.setGrade(ColorGrade(shadows: wheel, midtones: wheel, highlights: wheel)))
        }
        if let feather = call.args["feather"]?.double {
            edits.append(.setStack(feather: (feather / 100).clamped(to: 0...1), expand: nil, density: nil, isInverted: nil))
        }
        return .value(edits)
    }

    // MARK: maskEdit

    /// Changes one mask (its `ref`, else the last one edited): its area (`combine`), stack, strength, visibility,
    /// parts, ranges and handles, name; a copy; a fresh AI raster; or shows it (no document change).
    static func maskEdit(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) async -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.masks) else { return notEnabled(document, context) }
        let adjustment: LocalAdjustment
        switch targetMask(call, document: document, context: context) {
        case .value(let found): adjustment = found
        case .answer(let result): return (document, result)
        }
        let args = call.args
        if args["show"]?.bool == true, args.keys.allSatisfy({ ["show", "ref"].contains($0) }) {
            let name = MaskAccessibility.displayName(for: adjustment, language: context.french ? .fr : .en)
            return (document, info(context.french ? "Voici le masque « \(name) »." : "Here is the “\(name)” mask.", effects: [.message("showMask:\(adjustment.id.uuidString)")]))
        }
        var edits: [LocalAdjustmentEdit] = []
        // The area a `combine` adds, subtracts or intersects.
        if let rawMode = args["combine"]?.string, let mode = CombineMode(rawValue: rawMode) {
            let area = MaskAreaArgs(args, key: "where", includesRef: false)
            guard area.namesSomething else {
                return (document, answer(context.french ? "Quelle zone ajouter ou retirer ? Nomme-la ou touche-la." : "Which area? Name it or tap it.",
                                         reason: .needsSelection, effects: [.message("selectRegion")]))
            }
            let outcome = await resolveArea(area, call: call, document: document, context: context)
            guard case .area(var resolved) = outcome else {
                if case .answer(let result) = outcome { return (document, result) }
                return (document, .failed(context.french ? "Je ne trouve pas cette zone." : "I can't find that area."))
            }
            if hasShape(args) { resolved.kind = shaped(resolved.kind, args) }
            if let coverage = await measuredCoverage(resolved, document: document, context: context), coverage < coverageFloor {
                return (document, notSeen((resolved.region, resolved.label, area.target), french: context.french))
            }
            guard adjustment.stack.components.count < MaskStack.maxComponents else {
                return (document, answer(context.french ? "Ce masque a déjà 12 parties." : "That mask already has 12 parts.", reason: .tooMany))
            }
            edits.append(.addComponent(MaskComponent(resolved.kind, mode: mode, isInverted: resolved.isInverted)))
        }
        let stack = adjustment.stack
        if let invert = args["invert"]?.bool {
            edits.append(.setStack(feather: nil, expand: nil, density: nil, isInverted: invert ? !stack.isInverted : false))
        }
        let feather = args["feather"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        let expand = args["expand"]?.double.map { ($0 / 100).clamped(to: -1...1) }
        let density = args["density"]?.double.map { ($0 / 100).clamped(to: 0...1) }
        if feather != nil || expand != nil || density != nil {
            edits.append(.setStack(feather: feather, expand: expand, density: density, isInverted: nil))
        }
        if let amount = args["amount"]?.double { edits.append(.setAmount((amount / 100).clamped(to: 0...1))) }
        if let visible = args["visible"]?.bool { edits.append(.setVisible(visible)) }
        if let name = args["name"]?.string { edits.append(.rename(name)) }
        // One part of the mask (1-based, stack order).
        let parts = stack.components
        var part: MaskComponent?
        if let number = args["component"]?.double.map({ Int($0.rounded()) }) {
            guard number >= 1, number <= parts.count else {
                return (document, answer(context.french ? "Ce masque a \(parts.count) partie\(parts.count > 1 ? "s" : "")." : "That mask has \(parts.count) part\(parts.count == 1 ? "" : "s").",
                                         reason: .badRegion))
            }
            part = parts[number - 1]
        }
        if let rawMode = args["componentMode"]?.string, let mode = CombineMode(rawValue: rawMode) {
            guard let target = part ?? parts.last else { return (document, answer(context.french ? "Quelle partie ?" : "Which part?", reason: .badRegion)) }
            edits.append(.setComponentMode(target.id, mode))
        }
        if let invert = args["componentInvert"]?.bool {
            guard let target = part ?? parts.last else { return (document, answer(context.french ? "Quelle partie ?" : "Which part?", reason: .badRegion)) }
            edits.append(.invertComponent(target.id, invert))
        }
        if args["componentDelete"]?.bool == true {
            guard let target = part ?? parts.last else { return (document, answer(context.french ? "Quelle partie ?" : "Which part?", reason: .badRegion)) }
            guard parts.count > 1 else {
                return (document, answer(context.french ? "C'est la seule partie du masque : supprime plutôt le masque." : "That is the mask's only part: delete the mask instead.",
                                         reason: .nothingToDo))
            }
            edits.append(.removeComponent(target.id))
        }
        // A luminance or depth range's ends.
        if ["low", "high", "smoothness"].contains(where: { args[$0] != nil }) {
            let low = args["low"]?.double.map { ($0 / 100).clamped(to: 0...1) }
            let high = args["high"]?.double.map { ($0 / 100).clamped(to: 0...1) }
            let smooth = args["smoothness"]?.double.map { ($0 / 100).clamped(to: 0...1) }
            guard let range = part.map({ [$0] }).map({ $0.filter(isRange) }).flatMap(\.first) ?? parts.first(where: isRange) else {
                return (document, answer(context.french ? "Ce masque n'a pas de plage de luminance ni de profondeur." : "That mask has no luminance or depth range.",
                                         reason: .badRegion))
            }
            switch range.kind {
            case .luminanceRange(var spec):
                spec.low = low ?? spec.low
                spec.high = high ?? spec.high
                spec.feather = smooth ?? spec.feather
                if spec.high < spec.low { swap(&spec.low, &spec.high) }
                edits.append(.setComponentKind(range.id, .luminanceRange(spec)))
            case .depthRange(var spec):
                spec.low = low ?? spec.low
                spec.high = high ?? spec.high
                spec.feather = smooth ?? spec.feather
                if spec.high < spec.low { swap(&spec.low, &spec.high) }
                edits.append(.setComponentKind(range.id, .depthRange(spec)))
            default:
                break
            }
        }
        // A colour range's width (with `combine` the new part already carries it).
        if let fuzziness = args["fuzziness"]?.double, args["combine"] == nil {
            guard let colour = (part.flatMap { isColorRange($0) ? $0 : nil }) ?? parts.first(where: isColorRange), case .colorRange(var spec) = colour.kind else {
                return (document, answer(context.french ? "Ce masque n'a pas de plage de couleurs." : "That mask has no colour range.", reason: .badRegion))
            }
            spec.fuzziness = (fuzziness / 100).clamped(to: 0...1)
            edits.append(.setComponentKind(colour.id, .colorRange(spec)))
        }
        // A gradient's handles (with `combine` the new part already has them).
        if hasShape(args), args["combine"] == nil {
            guard let gradient = (part.flatMap { isGradient($0) ? $0 : nil }) ?? parts.first(where: isGradient) else {
                return (document, answer(context.french ? "Ce masque n'a pas de dégradé." : "That mask has no gradient.", reason: .badRegion))
            }
            edits.append(.setComponentKind(gradient.id, shaped(gradient.kind, args)))
        }
        if let name = args["localColor"]?.string {
            guard let color = PSColor.named(name) ?? PSColor(hex: name) else {
                return (document, answer(context.french ? "Je ne connais pas cette couleur." : "I don't know that colour.", reason: .badRegion))
            }
            let hue = ColorEngine.hsl(fromRGB: (color.red, color.green, color.blue)).0
            let wheel = ColorWheel(hue: hue, amount: ((args["localColorAmount"]?.double ?? 30) / 100).clamped(to: 0...1), luminance: 0)
            edits.append(.setGrade(ColorGrade(shadows: wheel, midtones: wheel, highlights: wheel)))
        }
        if args["refresh"]?.bool == true {
            let refreshed = await refreshedRasters(adjustment, document: document, context: context)
            switch refreshed {
            case .value(let list): edits += list
            case .answer(let result): return (document, result)
            }
        }
        if args["duplicate"]?.bool == true {
            guard document.canAddLocalAdjustment else {
                return (document, answer(context.french ? "Il y a déjà 16 masques : supprime-en un." : "There are already 16 masks: delete one.", reason: .tooMany))
            }
            edits.append(.duplicate)
        }
        guard !edits.isEmpty else {
            if args["refresh"]?.bool == true {
                return (document, info(context.french ? "Le masque est déjà à jour." : "The mask is already up to date."))
            }
            return (document, answer(context.french ? "Que changer dans le masque ?" : "What should change in the mask?", reason: .nothingToDo))
        }
        var updated = document
        var changed = false
        for edit in edits where updated.applyLocalEdit(edit, to: adjustment.id) { changed = true }
        guard changed else {
            return (document, info(context.french ? "Le masque est déjà ainsi." : "The mask is already like that."))
        }
        var result = ExecutionResult.applied(maskLabel(updated.localAdjustment(id: adjustment.id) ?? adjustment))
        if args["show"]?.bool == true { result.effects.append(.message("showMask:\(adjustment.id.uuidString)")) }
        return (updated, result)
    }

    static func isRange(_ component: MaskComponent) -> Bool {
        switch component.kind {
        case .luminanceRange, .depthRange: return true
        default: return false
        }
    }

    static func isColorRange(_ component: MaskComponent) -> Bool {
        if case .colorRange = component.kind { return true }
        return false
    }

    static func isGradient(_ component: MaskComponent) -> Bool {
        switch component.kind {
        case .linear, .radial: return true
        default: return false
        }
    }

    /// « Mettre à jour »: every AI raster made on another base state, made again on this one.
    static func refreshedRasters(_ adjustment: LocalAdjustment, document: PhotoDocument, context: OperationRunContext) async -> Answered<[LocalAdjustmentEdit]> {
        var edits: [LocalAdjustmentEdit] = []
        let key = document.baseStateKey
        for component in adjustment.stack.components {
            guard case .raster(let raster) = component.kind, let stale = raster.stateKey, stale != key, let request = refreshRequest(raster) else { continue }
            do {
                let result = try await context.services.aiMask(request, in: document)
                edits.append(.setComponentKind(component.id, .raster(result.raster)))
            } catch {
                let region = adjustment.region
                return .answer(failure(error, area: (region, adjustment.label, nil), call: OperationCall("maskEdit"), document: document, context: context))
            }
        }
        return .value(edits)
    }

    /// The request that made an AI raster, from its origin and label; nil for brush, selection and imported rasters.
    static func refreshRequest(_ raster: RasterRef) -> AIMaskRequest? {
        switch raster.origin {
        case .subject: return .subject
        case .background: return .background
        case .people: return .people
        case .sky: return .sky
        case .vegetation: return .vegetation
        case .water: return .water
        case .person: return .person(index: Int(raster.label ?? "1") ?? 1)
        case .object: return raster.label.map { .object(ObjectTarget(label: $0)) }
        case .facePart, .matte:
            let parts = (raster.label ?? "").split(separator: ":").map(String.init)
            guard let first = parts.first, let region = MaskRegion(rawValue: first) else { return nil }
            return .personPart(region, person: parts.count > 1 ? Int(parts[1]) : nil)
        case .depth, .selection, .brush, .imported:
            return nil
        }
    }

    // MARK: maskDelete

    static func maskDelete(_ call: OperationCall, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        guard FeatureFlags.isOn(.masks) else { return notEnabled(document, context) }
        var updated = document
        if call.args["all"]?.bool == true {
            let masks = document.localAdjustments
            guard !masks.isEmpty else {
                return (document, answer(context.french ? "Il n'y a aucun masque." : "There's no mask.", reason: .nothingToDo))
            }
            for mask in masks { updated.removeLocalAdjustment(id: mask.id) }
            return (updated, .applied("Delete Masks"))
        }
        switch targetMask(call, document: document, context: context) {
        case .value(let mask):
            updated.removeLocalAdjustment(id: mask.id)
            return (updated, .applied("Delete " + maskLabel(mask)))
        case .answer(let result):
            return (document, result)
        }
    }

    // MARK: selectiveAdjust, lowered (D2, §8.1)

    /// The selectiveAdjust targets an AI mask covers without the candidates: sky, subject, background, people,
    /// vegetation (grass, trees, plants), water.
    static let selectiveAIRegions: [String: (AIMaskRequest, MaskRegion)] = [
        "sky": (.sky, .sky), "cloud": (.sky, .sky), "subject": (.subject, .subject), "background": (.background, .background),
        "people": (.people, .people), "grass": (.vegetation, .vegetation), "tree": (.vegetation, .vegetation), "plant": (.vegetation, .vegetation),
        "vegetation": (.vegetation, .vegetation), "water": (.water, .water),
    ]

    static func isAIRegion(_ target: ObjectTarget) -> Bool {
        selectiveAIRegions[canonicalNoun(target.label)] != nil
    }

    /// selectiveAdjust as one local adjustment when `masks` is on: an AI region (sky, subject, background, people,
    /// vegetation, water) through `aiMask`; anything else through the legacy candidates (`candidates` decided
    /// by the caller: the W1 question, not found, the exact landmark masks) and `.candidates`. Nil when the host makes
    /// no mask rasters (`unsupportedOperation`): the caller applies the legacy op exactly as before.
    static func lowerSelective(_ intent: EditIntent, target: ObjectTarget, parameter: AdjustmentParameter, candidates: [ObjectCandidate]?,
                               document: PhotoDocument, context: OperationRunContext) async -> (PhotoDocument, ExecutionResult)? {
        guard FeatureFlags.isOn(.masks), document.localAdjustmentsLayerID != nil else { return nil }
        let label = canonicalNoun(target.label)
        let request: AIMaskRequest
        let region: MaskRegion
        if let (ai, made) = selectiveAIRegions[label] {
            request = ai
            region = made
        } else {
            guard let candidates, !candidates.isEmpty else { return nil }
            region = regionFor(noun: label) ?? .object
            request = .candidates(candidates, target: target)
        }
        let result: AIMaskResult
        do {
            result = try await context.services.aiMask(request, in: document)
        } catch PicshopError.unsupportedOperation(_) {
            return nil
        } catch {
            return (document, failure(error, area: (region, region == .object ? label : nil, target.originalPhrase), call: OperationCall("selectiveAdjust"),
                                      document: document, context: context))
        }
        guard result.coverage >= coverageFloor else {
            return (document, notSeen((region, region == .object ? label : nil, target.originalPhrase), french: context.french))
        }
        let rasterLabel: String? = region == .object ? label : (region == .person ? result.raster.label : result.raster.label)
        var updated = document
        var adjustment: LocalAdjustment
        if let existing = document.localAdjustments.last(where: { $0.matches(region: region, label: region == .object || region == .person ? rasterLabel : nil) }) {
            adjustment = existing
        } else {
            guard document.canAddLocalAdjustment else {
                return (document, answer(context.french ? "Il y a déjà 16 masques : supprime-en un." : "There are already 16 masks: delete one.", reason: .tooMany))
            }
            adjustment = LocalAdjustment(region: region, label: rasterLabel, stack: MaskStack.single(MaskComponent(.raster(result.raster))))
            updated.setLocalAdjustment(adjustment, label: maskLabel(adjustment))
        }
        // The dials of W1's selectiveAdjust (the teeth rule), added to what the adjustment already has.
        let value = (intent.amount ?? .relative(parameter.defaultStep)).resolve(current: 0, range: parameter.range)
        let dials = PhotoCommandExecutor.selectiveAdjustments(parameter, value, on: target)
        for dial in dials.activeParameters where dial != .vignette {
            let current = adjustment.adjustments[dial]
            let next = dial == parameter ? (current + dials[dial]).clamped(to: dial.range) : min(current, dials[dial])
            _ = updated.applyLocalEdit(.setDial(dial, next), to: adjustment.id)
        }
        adjustment = updated.localAdjustment(id: adjustment.id) ?? adjustment
        var applied = ExecutionResult.applied("Selective \(parameter.englishName)")
        applied.label = "Selective \(parameter.englishName)"
        if result.isApproximate {
            let caption = context.french ? "\(spokenName(region, label: rasterLabel, french: true).capitalizedFirst) approximatif : affine-le au pinceau."
                                         : "\(spokenName(region, label: rasterLabel, french: false).capitalizedFirst) is approximate: refine it with the brush."
            applied.effects.append(.message("speak:" + caption))
        }
        return (updated, applied)
    }
}

/// The download offers of the two mask models (D13): what Live says, what the session reads back on « oui ».
public enum ModelOfferText {
    public static let samID = MaskModelCatalog.samTiny.id
    public static let depthID = MaskModelCatalog.depthSmall.id
    /// `.message("offerModel:<id>")`: the session shows the model's download card.
    public static let offerPrefix = "offerModel:"
    /// `.message("installModel:<id>")`: the person said yes; the session starts the download and re-runs the call.
    public static let installPrefix = "installModel:"

    public static func question(for id: String, french: Bool) -> String {
        if id == depthID {
            return french ? "Il faut Profondeur IA (50 Mo, Wi‑Fi). Je le télécharge ?" : "This needs Depth AI (50 MB, Wi‑Fi). Shall I download it?"
        }
        return french ? "Il faut Sélection d'objets IA (80 Mo, Wi‑Fi). Je le télécharge ?" : "This needs AI object selection (80 MB, Wi‑Fi). Shall I download it?"
    }

    /// The model a pending offer is about, read back from its question; nil for any other question.
    public static func modelID(in question: String) -> String? {
        for id in [samID, depthID] where question == self.question(for: id, french: true) || question == self.question(for: id, french: false) {
            return id
        }
        return nil
    }

    public static func installing(_ id: String, french: Bool) -> String {
        let name = id == depthID ? (french ? "Profondeur IA" : "Depth AI") : (french ? "Sélection d'objets IA" : "AI object selection")
        return french ? "Je télécharge \(name) en Wi‑Fi. Je reprends dès qu'il est prêt." : "Downloading \(name) over Wi‑Fi. I'll carry on as soon as it's ready."
    }
}

