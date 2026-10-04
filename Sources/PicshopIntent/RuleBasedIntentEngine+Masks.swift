import Foundation
import PicshopCore

/// The grammar's W2 rules (§8.4): the four signature phrases of masks and selections, and nothing looser.
/// Every rule is anchored on the whole clause (a tone verb then a region, « sélectionne » then a noun, a verb on
/// « la sélection »), never a substring, so « sélectionne le calque 2 », « supprime le fond », « floute le fond »
/// and « remplace le ciel par… » keep their own rules. What the rules do not read goes on to the model, and the
/// catalog's triggers of the six operations cap a confident wrong answer (OperationAbstention).
extension RuleBasedIntentEngine {
    /// The grammar's confidence for these anchored rules.
    static let maskRuleConfidence = 0.9

    func parseMasks(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        guard context.mode == .photo else { return nil }
        let words = Self.trimmedCommand(u.tokens)
        guard !words.isEmpty else { return nil }
        let english = u.language == .english
        // Off, the W1 rules answer as before (« assombris le bas » darkens the photo).
        let masks = FeatureFlags.isOn(.masks), selections = FeatureFlags.isOn(.aiSelection)
        if masks, let again = Self.againRule(u, context: context) { return again }
        if let gesture = Self.gestureRule(words), let op = gesture.operation?.id,
           OperationGate.isEnabled(op) { return gesture }
        if selections, let apply = Self.selectionApplyRule(words) { return apply }
        if selections, let modify = Self.selectionModifyRule(words) { return modify }
        if selections, let select = Self.selectRule(words, english: english) { return select }
        return masks ? Self.maskToneRule(words) : nil
    }

    // MARK: Follow-ups

    /// « encore », « pareil », « c'est trop » right after a local adjustment (a maskAdjust, or the selectiveAdjust the
    /// executor lowers onto a mask): the same step again on the same mask, or half of it back. Without this the
    /// W1 follow-up would move the whole photo's dial.
    static func againRule(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        // W3 (D20): « continue » resumes the Live brain's pending outline.
        if context.hasPendingOutline, GoalOutline.isContinue(u.original) { return nil }
        guard let last = context.lastIntent else { return nil }
        let isMask = last.action == .operation && last.operation?.id == "maskAdjust"
        // « éclaircis la sélection » made a mask (selectionApply use=adjust): its follow-ups move that mask's dial,
        // never the whole photo's, and never make a second « Sélection » mask.
        let isSelectionMask = last.action == .operation && last.operation?.id == "selectionApply" && last.operation?.args["use"]?.string == "adjust"
        guard isMask || isSelectionMask || last.action == .selectiveAdjust else { return nil }
        let tokens = u.tokens
        if isSelectionMask, let previous = last.operation {
            // A maskAdjust that names nothing: the handler takes the mask the selection just made (the newest).
            let unnamed = EditIntent(action: .operation, operation: OperationCall("maskAdjust", args: [:], source: .grammar))
            if let tone = scopedTone(tokens, last: unnamed, isMask: true) { return tone }
            guard !tokens.isEmpty, tokens.allSatisfy({ followUpFunctionWords.contains($0) || ObjectVocabulary.fillerWords.contains($0) }) else { return nil }
            let tooMuch = u.contains(followUpTooWords)
            guard tooMuch || u.contains(followUpNotEnoughWords) || u.contains(followUpAgainWords) else { return nil }
            var args: [String: OpValue] = ["parameter": previous.args["parameter"] ?? .string(AdjustmentParameter.exposure.rawValue)]
            if case .number(let amount)? = previous.args["amount"] { args["amount"] = .number(tooMuch ? -amount / 2 : amount) }
            return call("maskAdjust", args)
        }
        if let tone = scopedTone(tokens, last: last, isMask: isMask) { return tone }
        guard !tokens.isEmpty, tokens.allSatisfy({ followUpFunctionWords.contains($0) || ObjectVocabulary.fillerWords.contains($0) }) else { return nil }
        let tooMuch = u.contains(followUpTooWords)
        guard tooMuch || u.contains(followUpNotEnoughWords) || u.contains(followUpAgainWords) else { return nil }
        if isMask, var repeated = last.operation {
            repeated.args["amountMode"] = nil
            if case .number(let amount)? = repeated.args["amount"] { repeated.args["amount"] = .number(tooMuch ? -amount / 2 : amount) }
            return call("maskAdjust", repeated.args)
        }
        var repeated = last
        repeated.confidence = maskRuleConfidence
        if let amount = last.amount {
            repeated.amount = .relative(tooMuch ? -amount.value / 2 : (amount.mode == .relative ? amount.value : (last.parameter?.defaultStep ?? 0.15)))
        }
        return repeated
    }

    /// A tone said without a place right after a local adjustment (« un peu plus sombre aussi », "darken it a
    /// little", « plus de clarté dessus »): the same mask, that dial.
    static let scopedTones: [(phrase: String, parameter: AdjustmentParameter, direction: Double)] = [
        ("plus sombre", .exposure, -1), ("plus fonce", .exposure, -1), ("plus clair", .exposure, 1), ("plus lumineux", .exposure, 1),
        ("plus de contraste", .contrast, 1), ("moins de contraste", .contrast, -1), ("plus de clarte", .clarity, 1), ("plus chaud", .temperature, 1),
        ("plus froid", .temperature, -1), ("plus sature", .saturation, 1), ("moins sature", .saturation, -1), ("assombris le", .exposure, -1),
        ("assombris la", .exposure, -1), ("eclaircis le", .exposure, 1), ("eclaircis la", .exposure, 1),
        ("darker", .exposure, -1), ("brighter", .exposure, 1), ("lighter", .exposure, 1), ("more contrast", .contrast, 1), ("less contrast", .contrast, -1),
        ("more clarity", .clarity, 1), ("warmer", .temperature, 1), ("cooler", .temperature, -1), ("darken it", .exposure, -1), ("brighten it", .exposure, 1),
    ]
    static let scopedFillers: Set<String> = ["un", "peu", "aussi", "dessus", "encore", "it", "a", "little", "bit", "too", "also", "more", "le", "la",
                                             "legerement", "slightly", "beaucoup", "lot", "much", "stp", "please", "merci", "thanks"]

    static func scopedTone(_ tokens: [String], last: EditIntent, isMask: Bool) -> EditIntent? {
        let phrase = tokens.joined(separator: " ")
        guard let tone = scopedTones.first(where: { " \(phrase) ".contains(" \($0.phrase) ") }) else { return nil }
        let toneWords = Set(tone.phrase.split(separator: " ").map(String.init))
        guard tokens.allSatisfy({ toneWords.contains($0) || scopedFillers.contains($0) }) else { return nil }
        let slight = tokens.contains("peu") || tokens.contains("little") || tokens.contains("bit") || tokens.contains("legerement") || tokens.contains("slightly")
        let strong = tokens.contains("beaucoup") || tokens.contains("lot") || tokens.contains("much")
        let amount = tone.direction * (slight ? 10 : strong ? 40 : 20)
        if isMask, let previous = last.operation {
            var args: [String: OpValue] = [:]
            for key in ["ref", "where", "target", "attributes", "index", "box", "point", "color"] { args[key] = previous.args[key] }
            args["parameter"] = .string(tone.parameter.rawValue)
            args["amount"] = .number(amount)
            return call("maskAdjust", args)
        }
        guard last.action == .selectiveAdjust, let target = last.target else { return nil }
        return EditIntent(action: .selectiveAdjust, target: target, parameter: tone.parameter, amount: .relative(amount / 100),
                          confidence: maskRuleConfidence)
    }

    // MARK: Clause

    /// Politeness at either end ("stp", "s'il te plaît", "please", "peux-tu") never changes the command.
    static func trimmedCommand(_ tokens: [String]) -> [String] {
        var words = tokens
        let leading: [[String]] = [["est", "ce", "que", "tu", "peux"], ["tu", "peux"], ["peux", "tu"], ["pourrais", "tu"], ["can", "you"], ["could", "you"],
                                   ["please"], ["s", "il", "te", "plait"], ["stp"], ["svp"], ["alors"], ["ok"], ["maintenant"], ["now"]]
        let trailing: [[String]] = [["s", "il", "te", "plait"], ["s", "il", "vous", "plait"], ["stp"], ["svp"], ["please"], ["merci"], ["thanks"]]
        var changed = true
        while changed {
            changed = false
            for phrase in leading where words.count > phrase.count && Array(words.prefix(phrase.count)) == phrase {
                words.removeFirst(phrase.count)
                changed = true
            }
            for phrase in trailing where words.count > phrase.count && Array(words.suffix(phrase.count)) == phrase {
                words.removeLast(phrase.count)
                changed = true
            }
        }
        return words
    }

    /// `phrase` at the start of `words`: what follows it, or nil.
    static func after(_ phrase: String, in words: [String]) -> [String]? {
        let tokens = phrase.split(separator: " ").map(String.init)
        guard words.count >= tokens.count, Array(words.prefix(tokens.count)) == tokens else { return nil }
        return Array(words.dropFirst(tokens.count))
    }

    /// The first of `phrases` that starts `words` (longest first), and what follows it.
    static func leading(_ phrases: [String], in words: [String]) -> (phrase: String, rest: [String])? {
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            if let rest = after(phrase, in: words) { return (phrase, rest) }
        }
        return nil
    }

    static func call(_ id: OpID, _ args: [String: OpValue]) -> EditIntent {
        EditIntent(action: .operation, confidence: maskRuleConfidence, operation: OperationCall(id, args: args, source: .grammar))
    }

    // MARK: Tone on a region (maskAdjust)

    /// The tone verbs and what they set: the parameter and its direction.
    static let toneVerbs: [(phrase: String, parameter: AdjustmentParameter, direction: Double)] = [
        ("eclaircis", .exposure, 1), ("eclaircir", .exposure, 1), ("eclaire", .exposure, 1), ("illumine", .exposure, 1),
        ("assombris", .exposure, -1), ("assombri", .exposure, -1), ("assombrir", .exposure, -1), ("fonce", .exposure, -1),
        ("plus de contraste sur", .contrast, 1), ("plus de contraste dans", .contrast, 1), ("moins de contraste sur", .contrast, -1),
        ("plus de clarte sur", .clarity, 1), ("rechauffe", .temperature, 1), ("refroidis", .temperature, -1), ("refroidi", .temperature, -1),
        ("sature", .saturation, 1), ("desature", .saturation, -1),
        ("brighten", .exposure, 1), ("lighten", .exposure, 1), ("darken", .exposure, -1), ("more contrast on", .contrast, 1),
        ("less contrast on", .contrast, -1), ("more clarity on", .clarity, 1), ("warm up", .temperature, 1), ("warm", .temperature, 1),
        ("cool down", .temperature, -1), ("cool", .temperature, -1), ("saturate", .saturation, 1), ("desaturate", .saturation, -1),
    ]

    /// The regions the grammar owns after a tone verb. The sky is not one: « éclaircis le ciel » stays on the
    /// selectiveAdjust rule, which the executor lowers onto a mask.
    static let toneRegions: [(phrase: String, region: MaskRegion)] = [
        ("le haut", .top), ("la partie haute", .top), ("le bas", .bottom), ("le ba", .bottom), ("la partie basse", .bottom),
        ("le cote gauche", .left), ("la gauche", .left), ("le cote droit", .right), ("la droite", .right), ("les bords", .edges),
        ("les coins", .edges), ("le centre", .center), ("le milieu", .center), ("le sujet", .subject), ("l arriere plan", .background),
        ("le fond", .background),
        ("the top", .top), ("the bottom", .bottom), ("the left side", .left), ("the left", .left), ("the right side", .right), ("the right", .right),
        ("the edges", .edges), ("the corners", .edges), ("the centre", .center), ("the center", .center), ("the middle", .center),
        ("the subject", .subject), ("the background", .background),
    ]

    /// What may follow the region: « de la photo », a qualifier, an amount.
    static let toneTails: Set<String> = ["de", "la", "l", "photo", "image", "of", "the", "picture", "un", "peu", "legerement", "beaucoup", "encore",
                                         "plus", "a", "bit", "little", "slightly", "lot", "much", "more", "tres", "fort", "pourcent", "percent", "by", "seulement",
                                         "only", "doucement", "gently", "subtly", "subtilement"]

    static func maskToneRule(_ words: [String]) -> EditIntent? {
        guard let verb = leading(toneVerbs.map(\.phrase), in: words), let tone = toneVerbs.first(where: { $0.phrase == verb.phrase }) else { return nil }
        var rest = verb.rest
        // « éclaircis un peu le bas »: a qualifier before the region.
        var before: [String] = []
        while let first = rest.first, ["un", "peu", "legerement", "beaucoup", "a", "bit", "little", "slightly", "lot", "encore", "doucement"].contains(first) {
            before.append(first)
            rest.removeFirst()
        }
        guard let place = leading(toneRegions.map(\.phrase), in: rest), let region = toneRegions.first(where: { $0.phrase == place.phrase })?.region else { return nil }
        let tail = place.rest
        guard tail.allSatisfy({ toneTails.contains($0) || Double($0) != nil || NumberWords.parse([$0], at: 0) != nil }) else { return nil }
        let qualifiers = NormalizedUtterance((before + tail).joined(separator: " "))
        let magnitude = AmountParser.magnitude(in: qualifiers)
        var amount = 20.0
        switch magnitude.qualifier {
        case .slight?: amount = 10
        case .strong?: amount = 40
        case nil: break
        }
        if let number = magnitude.explicitNumber { amount = abs(number) * 100 }
        return call("maskAdjust", ["where": .string(region.rawValue), "parameter": .string(tone.parameter.rawValue), "amount": .number(tone.direction * amount)])
    }

    // MARK: select

    static let selectVerbs = ["selectionne", "selectionner", "selectione", "select", "choisis", "prends en selection"]
    static let selectWhats: [(phrase: String, what: String)] = [
        ("le sujet", "subject"), ("le ciel", "sky"), ("l arriere plan", "background"), ("le fond", "background"), ("les personnes", "people"),
        ("les gens", "people"), ("tout le monde", "people"), ("toute la photo", "all"), ("toute l image", "all"), ("tout", "all"),
        ("the subject", "subject"), ("the sky", "sky"), ("the background", "background"), ("the people", "people"), ("everyone", "people"),
        ("everything", "all"), ("all", "all"), ("the whole photo", "all"), ("subject", "subject"), ("sky", "sky"),
    ]
    /// Nouns « sélectionne » leaves to other rules: layers and text are selectLayer's.
    static let selectNotObjects: Set<String> = ["calque", "calques", "couche", "texte", "photo", "image", "layer", "layers", "text", "picture", "titre", "title"]
    static let articles: Set<String> = ["la", "le", "les", "l", "un", "une", "the", "a", "an", "cette", "ce", "cet", "this", "that", "mon", "ma", "my"]

    /// Colour words said after (French) or before (English) a noun, as an English attribute.
    static let colourWords: [String: String] = [
        "rouge": "red", "rouges": "red", "red": "red", "bleu": "blue", "bleue": "blue", "bleus": "blue", "bleues": "blue", "blue": "blue",
        "vert": "green", "verte": "green", "verts": "green", "green": "green", "jaune": "yellow", "jaunes": "yellow", "yellow": "yellow",
        "blanc": "white", "blanche": "white", "blancs": "white", "white": "white", "noir": "black", "noire": "black", "noirs": "black", "black": "black",
        "rose": "pink", "pink": "pink", "orange": "orange", "violet": "purple", "violette": "purple", "purple": "purple", "gris": "gray", "grise": "gray",
        "gray": "gray", "grey": "gray", "marron": "brown", "brun": "brown", "brown": "brown",
    ]

    /// The words that place or size the thing (« à droite », « de gauche », "left", « grande »), taken out of
    /// `nouns` with the little words left around them (« la plus », "the most").
    static func spatialQualifier(_ nouns: [String]) -> (hint: SpatialHint, rest: [String])? {
        guard let found = PhotoOperationHandlers.spatialMatch(in: nouns.joined(separator: " ")) else { return nil }
        let alias = found.alias.split(separator: " ").map(String.init)
        guard !alias.isEmpty, nouns.count >= alias.count,
              let start = (0...(nouns.count - alias.count)).first(where: { Array(nouns[$0..<($0 + alias.count)]) == alias }) else { return nil }
        var rest = nouns
        rest.removeSubrange(start..<(start + alias.count))
        let connectors: Set<String> = ["de", "du", "des", "a", "la", "le", "les", "l", "sur", "plus", "qui", "est", "on", "the", "most", "in", "at", "to", "of"]
        while let last = rest.last, connectors.contains(last) { rest.removeLast() }
        while let head = rest.first, connectors.contains(head) { rest.removeFirst() }
        return (found.hint, rest)
    }

    static func selectRule(_ words: [String], english: Bool) -> EditIntent? {
        var mode: String?
        var body: [String]
        if let verb = leading(selectVerbs, in: words) {
            body = verb.rest
        } else if let add = leading(["ajoute", "add"], in: words), let index = add.rest.firstIndex(where: { ["a", "to"].contains($0) }),
                  Array(add.rest[index...]) == ["a", "la", "selection"] || Array(add.rest[index...]) == ["to", "the", "selection"] {
            mode = "add"
            body = Array(add.rest[..<index])
        } else if let remove = leading(["retire", "enleve", "soustrais", "remove", "subtract"], in: words),
                  let index = remove.rest.firstIndex(where: { ["de", "from"].contains($0) }),
                  Array(remove.rest[index...]) == ["de", "la", "selection"] || Array(remove.rest[index...]) == ["from", "the", "selection"] {
            mode = "subtract"
            body = Array(remove.rest[..<index])
        } else {
            return nil
        }
        guard !body.isEmpty, !body.contains(where: selectNotObjects.contains) else { return nil }
        var args: [String: OpValue] = [:]
        if let mode { args["mode"] = .string(mode) }
        let phrase = body.joined(separator: " ")
        if let match = selectWhats.first(where: { $0.phrase == phrase }) {
            args["what"] = .string(match.what)
            return call("select", args)
        }
        // « la deuxième personne », "the second person".
        if body.count >= 2, let ordinal = body.lazy.compactMap({ NumberWords.ordinal($0) }).first,
           ["personne", "person"].contains(body.last ?? "") {
            args["what"] = .string("person")
            args["index"] = .number(Double(ordinal))
            return call("select", args)
        }
        // « cette couleur », "this colour": the colour under a tap.
        if ["cette couleur", "this colour", "this color", "la couleur"].contains(phrase) {
            args["what"] = .string("color")
            return call("select", args)
        }
        // « la tasse bleue », "the blue cup": an object, its colour as an attribute.
        guard let first = body.first, articles.contains(first) else { return nil }
        var nouns = Array(body.dropFirst())
        // « la personne à droite », « … de gauche », "the left person", « la grande tasse »: where it is goes in
        // `spatialHint` (the handler ranks the candidates by it), never dropped. A place with no thing left (« le
        // bas »), or a region with a place (« le ciel à gauche »), is the model's to read.
        var hint: SpatialHint?
        if let qualifier = Self.spatialQualifier(nouns) {
            // Two places at once (« en haut à droite ») are the model's too.
            guard !qualifier.rest.isEmpty, Self.spatialQualifier(qualifier.rest) == nil else { return nil }
            hint = qualifier.hint
            nouns = qualifier.rest
        }
        var attributes: [String] = []
        if english, nouns.count >= 2, let colour = colourWords[nouns[0]] {
            attributes.append(colour)
            nouns.removeFirst()
        }
        if nouns.count >= 2, let colour = colourWords[nouns[nouns.count - 1]] {
            attributes.append(colour)
            nouns.removeLast()
        }
        guard !nouns.isEmpty, nouns.count <= 3 else { return nil }
        let noun = nouns.joined(separator: " ")
        // « tout ce qui est rouge » and colours alone are a colour range.
        if nouns.count == 1, let colour = colourWords[noun] {
            guard hint == nil else { return nil }
            args["what"] = .string("color")
            args["color"] = .string(colour)
            return call("select", args)
        }
        let known = ObjectVocabulary.match(noun)
        var intent: EditIntent
        if let known, let region = PhotoOperationHandlers.regionFor(noun: known.entry.label), region != .object, region != .person {
            guard hint == nil else { return nil }
            args["what"] = .string(region.rawValue)
            intent = call("select", args)
        } else {
            args["what"] = .string("object")
            args["target"] = .string(known?.entry.label ?? noun)
            if !attributes.isEmpty { args["attributes"] = .list(attributes.map { .string($0) }) }
            if let hint { args["spatialHint"] = .string(hint.rawValue) }
            intent = call("select", args)
            // A word the vocabulary does not know (a slip of the speech recogniser) is the model's to read.
            if known == nil { intent.confidence = 0.7 }
        }
        return intent
    }

    // MARK: selectionModify

    static func selectionModifyRule(_ words: [String]) -> EditIntent? {
        let selection = [["la", "selection"], ["the", "selection"]]
        func endsOnSelection(_ rest: [String]) -> (pixels: Double?, ok: Bool) {
            for phrase in selection where rest.count >= 2 && Array(rest.prefix(2)) == phrase {
                let tail = Array(rest.dropFirst(2))
                guard tail.allSatisfy({ ["de", "by", "pixels", "pixel", "px", "un", "peu", "a", "bit", "little"].contains($0) || Double($0) != nil || NumberWords.parse([$0], at: 0) != nil }) else {
                    return (nil, false)
                }
                return (NumberWords.firstNumber(in: tail).map(\.value), true)
            }
            return (nil, false)
        }
        if ["deselectionne", "deselectionner", "deselect", "unselect"].contains(words.first ?? ""),
           words.dropFirst().allSatisfy({ ["tout", "all", "everything", "la", "selection", "the"].contains($0) }) {
            return call("selectionModify", ["deselect": .bool(true)])
        }
        if words == ["select", "none"] || words == ["tout", "deselectionner"] { return call("selectionModify", ["deselect": .bool(true)]) }
        let verbs: [(String, String)] = [
            ("inverse", "invert"), ("inverser", "invert"), ("invert", "invert"), ("agrandis", "grow"), ("etends", "grow"), ("grow", "grow"),
            ("expand", "grow"), ("reduis", "shrink"), ("retrecis", "shrink"), ("shrink", "shrink"), ("contract", "shrink"), ("adoucis", "feather"),
            ("adoucis les bords de", "feather"), ("soften", "feather"), ("soften the edges of", "feather"),
        ]
        guard let verb = leading(verbs.map(\.0), in: words), let change = verbs.first(where: { $0.0 == verb.phrase })?.1 else { return nil }
        let (pixels, ok) = endsOnSelection(verb.rest)
        guard ok else { return nil }
        switch change {
        case "invert": return call("selectionModify", ["invert": .bool(true)])
        default: return call("selectionModify", [change: .number(max(1, min(500, pixels ?? 10)))])
        }
    }

    // MARK: selectionApply

    static func selectionApplyRule(_ words: [String]) -> EditIntent? {
        let selection: Set<[String]> = [["la", "selection"], ["the", "selection"]]
        func on(_ rest: [String]) -> [String]? {
            guard rest.count >= 2, selection.contains(Array(rest.prefix(2))) else { return nil }
            return Array(rest.dropFirst(2))
        }
        func colour(_ rest: [String], intro: Set<String>) -> String? {
            let tail = rest.filter { !intro.contains($0) }
            guard tail.count == 1 || (tail.count == 2 && ["clair", "fonce", "light", "dark"].contains(tail[1])) || (tail.count == 2 && ["light", "dark"].contains(tail[0])) else { return nil }
            let name = tail.joined(separator: " ")
            guard PSColor.named(name) != nil else { return nil }
            return colourWords[tail[0]] != nil && tail.count == 1 ? colourWords[tail[0]] : name
        }
        // « éclaircis la sélection », "darken the selection": a local adjustment through the selection.
        if let verb = leading(toneVerbs.map(\.phrase), in: words), let tone = toneVerbs.first(where: { $0.phrase == verb.phrase }),
           let rest = on(verb.rest), rest.allSatisfy({ toneTails.contains($0) }) {
            let slight = rest.contains("peu") || rest.contains("little") || rest.contains("bit")
            return call("selectionApply", ["use": .string("adjust"), "parameter": .string(tone.parameter.rawValue),
                                           "amount": .number(tone.direction * (slight ? 10 : 20))])
        }
        if let verb = leading(["efface", "erase"], in: words), let rest = on(verb.rest), rest.isEmpty {
            return call("selectionApply", ["use": .string("erase")])
        }
        if let verb = leading(["floute", "blur"], in: words), let rest = on(verb.rest), rest.isEmpty {
            return call("selectionApply", ["use": .string("blur"), "amount": .number(60)])
        }
        if let verb = leading(["remplis", "fill"], in: words), let rest = on(verb.rest), let name = colour(rest, intro: ["de", "en", "avec", "with", "in"]) {
            return call("selectionApply", ["use": .string("fill"), "color": .string(name)])
        }
        if let verb = leading(["recolore", "recolor", "recolour"], in: words), let rest = on(verb.rest), let name = colour(rest, intro: ["en", "in", "to"]) {
            return call("selectionApply", ["use": .string("recolor"), "color": .string(name)])
        }
        return nil
    }

    // MARK: Gestures

    /// The controls only a gesture reaches (MaskPanelInventory `.gestureOnly`): the phrase opens the tool on that
    /// control and says what to do with a finger. `openTool:<control id>` is the session's.
    static let gestureRules: [(phrases: [String], control: String, op: OpID)] = [
        (["peins le masque", "peins un masque", "dessine le masque", "dessine un masque", "pinceau de masque", "masque au pinceau", "peins sur la photo",
          "paint the mask", "paint a mask", "mask brush", "brush a mask"], "masks.brush.paint", "maskAdjust"),
        (["efface le masque au pinceau", "gomme le masque", "gomme du masque", "erase the mask with the brush"], "masks.brush.erase", "maskEdit"),
        (["taille du pinceau", "pinceau plus gros", "pinceau plus petit", "brush size", "bigger brush", "smaller brush"], "masks.brush.size", "maskAdjust"),
        (["pinceau plus doux", "contour du pinceau", "softer brush", "brush feather"], "masks.brush.feather", "maskAdjust"),
        (["flux du pinceau", "brush flow"], "masks.brush.flow", "maskAdjust"),
        (["nouveau masque au pinceau", "new brush mask"], "masks.new.brush", "maskAdjust"),
        (["ajoute au pinceau", "add with the brush"], "masks.component.source.brush", "maskEdit"),
        (["trace le degrade", "dessine un degrade", "degrade a la main", "draw a gradient", "drag a gradient"], "masks.handles.linear", "maskAdjust"),
        (["trace le filtre radial", "dessine un filtre radial", "draw a radial filter"], "masks.handles.radial", "maskAdjust"),
        (["touche l objet a masquer", "masque ce que je touche", "mask what i tap"], "masks.object.tap", "maskAdjust"),
        (["encadre l objet a masquer", "mask what i frame"], "masks.object.box", "maskAdjust"),
        (["modifie la courbe du masque a la main", "draw the mask curve"], "masks.curve.points", "maskAdjust"),
        (["pipette de luminance", "pipette de profondeur", "range eyedropper"], "masks.range.eyedropper", "maskEdit"),
        (["pipette", "prends la couleur", "eyedropper", "compte gouttes", "pick the colour", "pick the color"], "masks.colorRange.sample.add", "maskAdjust"),
        (["retire cette couleur du masque", "remove this colour from the mask"], "masks.colorRange.sample.subtract", "maskAdjust"),
        (["ajoute cette couleur a la selection", "add this colour to the selection"], "select.colorRange.sample.add", "select"),
        (["retire cette couleur de la selection", "remove this colour from the selection"], "select.colorRange.sample.subtract", "select"),
        (["selection rapide", "quick selection", "quick select"], "select.mode.quick", "select"),
        (["peins la selection", "paint the selection"], "select.quick.stroke", "select"),
        (["gomme la selection", "erase from the selection with the brush"], "select.quick.erase", "select"),
        (["taille du pinceau de selection", "selection brush size"], "select.quick.size", "select"),
        (["lasso", "au lasso", "selection au lasso", "lasso tool", "entoure a la main"], "select.mode.lasso", "select"),
        (["dessine au lasso", "draw with the lasso"], "select.lasso.draw", "select"),
        (["touche ce qu il faut selectionner", "select what i tap"], "select.object.tap", "select"),
        (["encadre ce qu il faut selectionner", "select what i frame"], "select.object.box", "select"),
        (["touche avec la baguette", "tap with the wand"], "select.wand.tap", "select"),
    ]

    static func gestureRule(_ words: [String]) -> EditIntent? {
        let phrase = words.joined(separator: " ")
        guard let rule = gestureRules.first(where: { $0.phrases.contains(phrase) }) else { return nil }
        return call(rule.op, ["openTool": .string(rule.control)])
    }
}

extension PhotoOperationHandlers {
    /// A gesture-only control said aloud (the grammar's `openTool` call): its tool opens on it, with what to do.
    static func openTool(_ control: String, _ document: PhotoDocument, _ context: OperationRunContext) -> (PhotoDocument, ExecutionResult) {
        if let flag = toolFlag(of: control), !FeatureFlags.isOn(flag) { return notEnabled(document, context) }
        let fr = context.french
        let hint: String
        switch control {
        case "masks.brush.paint", "masks.new.brush", "masks.component.source.brush":
            hint = fr ? "Peins sur la photo avec le pinceau." : "Paint on the photo with the brush."
        case "masks.brush.erase": hint = fr ? "Passe le pinceau en Effacer et peins ce qu'il faut retirer." : "Switch the brush to Erase and paint what to take out."
        case "masks.brush.size", "masks.brush.feather", "masks.brush.flow", "select.quick.size":
            hint = fr ? "Règle le pinceau sous la photo." : "Set the brush under the photo."
        case "masks.handles.linear": hint = fr ? "Fais glisser le dégradé sur la photo." : "Drag the gradient on the photo."
        case "masks.handles.radial": hint = fr ? "Fais glisser le filtre radial sur la photo." : "Drag the radial filter on the photo."
        case "masks.object.tap", "select.object.tap", "select.wand.tap": hint = fr ? "Touche ce qu'il faut prendre." : "Tap what to take."
        case "masks.object.box", "select.object.box": hint = fr ? "Encadre-le sur la photo." : "Frame it on the photo."
        case "masks.curve.points": hint = fr ? "Fais glisser les points de la courbe." : "Drag the curve's points."
        case "masks.range.eyedropper", "masks.colorRange.sample.add", "select.colorRange.sample.add":
            hint = fr ? "Touche la couleur à prendre." : "Tap the colour to take."
        case "masks.colorRange.sample.subtract", "select.colorRange.sample.subtract": hint = fr ? "Touche la couleur à retirer." : "Tap the colour to take out."
        case "select.mode.quick", "select.quick.stroke": hint = fr ? "Peins sur ce que tu veux sélectionner." : "Paint over what you want to select."
        case "select.quick.erase": hint = fr ? "Peins sur ce qu'il faut retirer de la sélection." : "Paint over what to take out of the selection."
        case "select.mode.lasso", "select.lasso.draw": hint = fr ? "Entoure la zone au doigt." : "Draw around the area with your finger."
        default: hint = photoToolHint(control, french: fr)
        }
        return (document, ExecutionResult(outcome: .info(message: hint), effects: [.message("openTool:" + control)]))
    }

    /// The flag a control's tool needs (nil: none): the W2 masks and selections, the W3 layers and export.
    static func toolFlag(of control: String) -> FeatureFlag? {
        if control.hasPrefix("select.") { return .aiSelection }
        if control.hasPrefix("masks.") { return .masks }
        if control.hasPrefix("layers.") || control.hasPrefix("canvas.layer") { return .layerOps }
        if control.hasPrefix("export.") { return .proExport }
        return nil
    }

    /// What to do with a finger once a photo panel's gesture control is open (W3, PhotoPanelInventory).
    static func photoToolHint(_ control: String, french fr: Bool) -> String {
        switch control {
        case "layers.row.reorder", "layers.column.reorder":
            return fr ? "Fais glisser le calque à sa place dans la liste." : "Drag the layer to its place in the list."
        case "layers.transform.handles", "layers.transform.mode.uniform", "canvas.layer.drag":
            return fr ? "Fais glisser les poignées du calque sur la photo." : "Drag the layer's handles on the photo."
        case "layers.mask.paint": return fr ? "Peins sur la photo : blanc révèle, noir masque." : "Paint on the photo: white reveals, black hides."
        case "layers.mask.paint.erase": return fr ? "Peins en noir ce qu'il faut cacher." : "Paint in black what to hide."
        case "layers.mask.brush.size", "layers.mask.brush.hardness", "layers.mask.brush.flow", "erase.brush.size", "precise.brush.size",
             "precise.hardness", "precise.paintColor":
            return fr ? "Règle le pinceau sous la photo." : "Set the brush under the photo."
        case "layers.fill.handles": return fr ? "Fais glisser les poignées du dégradé." : "Drag the gradient's handles."
        case "layers.adjustment.curves.points", "curves.points": return fr ? "Fais glisser les points de la courbe." : "Drag the curve's points."
        case "color.lut.import": return fr ? "Choisis un fichier .cube." : "Pick a .cube file."
        case "erase.tap", "magic.object.tap", "canvas.layer.pick": return fr ? "Touche-le sur la photo." : "Tap it on the photo."
        case "erase.brush", "precise.pixelBrush", "precise.clone": return fr ? "Peins sur la photo." : "Paint on the photo."
        case "precise.wand": return fr ? "Touche la zone à prendre." : "Tap the area to take."
        case "precise.lasso": return fr ? "Entoure la zone au doigt." : "Draw around the area with your finger."
        case "focus.tap": return fr ? "Touche ce qui doit être net." : "Tap what should be sharp."
        case "crop.frame": return fr ? "Fais glisser les bords du cadre." : "Drag the frame's edges."
        case "text.move", "shapes.move": return fr ? "Fais-le glisser sur la photo." : "Drag it on the photo."
        case "layers.add.shape", "shapes.place": return fr ? "Touche la photo pour poser la forme." : "Tap the photo to place the shape."
        case "shapes.kind", "shapes.color", "shapes.outline": return fr ? "Choisis-la sous la photo." : "Pick it under the photo."
        case "canvas.layer.menu": return fr ? "Appuie longuement sur le calque." : "Press and hold the layer."
        case "export.quality", "export.location", "export.cancel": return fr ? "C'est dans la feuille d'export." : "It's in the export sheet."
        default: return fr ? "C'est à faire au doigt sur la photo." : "That one is done with a finger on the photo."
        }
    }
}
