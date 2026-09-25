import Foundation
import PicshopCore

// Text on the picture named by what it is — "le titre", "le prix", « SOLDES », "le texte en haut",
// "mon texte" — edited, replaced, restyled, moved or erased by its scene-map id, in its own style; new
// text written under, over or beside it, or "dans le même style". And the follow-ups that reuse the
// last step: "encore", "pareil pour le chien", "plus gros", "en rouge".

extension RuleBasedIntentEngine {
    static let sceneReplaceVerbs = ["remplace", "remplacer", "change", "changer", "modifie", "modifier", "corrige", "corriger", "renomme", "reecris",
                                    "replace", "edit", "rewrite", "rename", "correct", "fix"]
    static let sceneMoveVerbs = ["deplace", "deplacer", "bouge", "bouger", "decale", "decaler", "monte", "monter", "remonte", "descends", "descend",
                                 "baisse", "move", "shift", "raise", "lower", "nudge"]
    static let sceneBiggerWords = ["plus gros", "plus grand", "plus grande", "plus grosse", "agrandis", "agrandir", "grossis", "grossir", "bigger", "larger",
                                   "enlarge", "make it bigger", "en plus grand", "en plus gros"]
    static let sceneSmallerWords = ["plus petit", "plus petite", "reduis", "reduire", "rapetisse", "smaller", "shrink", "make it smaller", "en plus petit"]
    static let sceneBoldWords = ["en gras", "gras", "in bold", "bold", "plus epais"]
    static let sceneSameStyleWords = ["meme style", "meme police", "meme typo", "meme typographie", "same style", "same font", "matching style",
                                      "dans le style", "comme le reste", "like the rest", "assorti", "assortie"]

    // MARK: Text blocks by what they are

    static let belowPhrases = ["juste en dessous du", "juste en dessous de", "en dessous du", "en dessous de", "au dessous du", "au dessous de", "juste sous le",
                               "juste sous la", "sous le", "sous la", "sous les", "under the", "below the", "beneath the", "underneath the", "right under the",
                               "right below the"]
    static let abovePhrases = ["juste au dessus du", "juste au dessus de", "au dessus du", "au dessus de", "right above the", "above the"]

    /// "le texte sous le titre", "the text above the price": the block next to the one named, found before any
    /// role noun (which would name the anchor itself). `found` is true when a relation to a block was said,
    /// even if nothing sits there (then nothing is named, rather than the anchor).
    static func relatedBlock(_ u: NormalizedUtterance, original: String, scene: SceneMap) -> (found: Bool, block: SceneMap.TextBlock?) {
        for (phrases, below) in [(belowPhrases, true), (abovePhrases, false)] {
            guard let phrase = u.firstMatch(phrases), let index = u.tokenIndex(of: phrase) else { continue }
            let rest = NormalizedUtterance(u.tokens[(index + phrase.split(separator: " ").count)...].joined(separator: " "))
            guard !rest.tokens.isEmpty, let anchor = sceneBlock(rest, original: original, scene: scene, relations: false) else { continue }
            let overlapping = scene.texts.filter { $0.id != anchor.id && $0.box.maxX > anchor.box.minX && $0.box.minX < anchor.box.maxX }
            if below { return (true, overlapping.filter { $0.box.minY >= anchor.box.maxY - 0.01 }.min { $0.box.minY < $1.box.minY }) }
            return (true, overlapping.filter { $0.box.maxY <= anchor.box.minY + 0.01 }.max { $0.box.maxY < $1.box.maxY })
        }
        return (false, nil)
    }

    /// A text block of the scene the words name, and the words that named it (so the rest can be read).
    /// `relations`: "sous le titre" names the block under the title (off when the words place new text).
    static func sceneBlock(_ u: NormalizedUtterance, original: String, scene: SceneMap, relations: Bool = true) -> SceneMap.TextBlock? {
        if relations {
            let related = relatedBlock(u, original: original, scene: scene)
            if related.found { return related.block }
        }
        // « SOLDES »: the block that reads it (the first quote when a replacement follows).
        if let quoted = quotedStrings(in: original).first, let block = scene.texts(matching: quoted).first { return block }
        if u.contains(["sous titre", "subtitle", "tagline", "slogan", "accroche"]) {
            if let title = scene.title {
                let below = scene.texts.filter { $0.id != title.id && $0.box.minY >= title.box.midY && $0.box.minY - title.box.maxY < 0.2 }
                if let subtitle = below.min(by: { $0.box.minY < $1.box.minY }) { return subtitle }
            }
        }
        if u.contains(["titre", "title", "gros titre", "heading", "headline", "l entete", "en tete"]), !u.contains(["sous titre"]) {
            if let title = scene.title { return title }
        }
        if u.contains(["prix", "price", "tarif", "montant"]) {
            if let price = scene.texts.first(where: { $0.text.contains("€") || $0.text.contains("$") || $0.text.contains("£") || SceneMap.folded($0.text).contains("prix") }) {
                return price
            }
        }
        if u.contains(["date", "la date", "the date"]) {
            let months = ["janv", "fevr", "mars", "avril", "mai", "juin", "juil", "aout", "sept", "oct", "nov", "dec", "jan", "feb", "mar", "apr", "may", "jun",
                          "jul", "aug", "sep"]
            if let date = scene.texts.first(where: { block in
                let folded = SceneMap.folded(block.text)
                guard block.text.contains(where: \.isNumber) else { return false }
                return block.text.contains("/") || months.contains { folded.contains($0) }
            }) { return date }
        }
        if u.contains(["mon texte", "le texte que j ai ajoute", "ton texte", "le texte ajoute", "my text", "the text i added", "the text you added", "le dernier texte",
                       "the last text", "ce texte", "this text", "le nouveau texte", "the new text"]) {
            if let layer = scene.texts.last(where: \.isLayer) { return layer }
        }
        if u.contains(["le texte en haut", "le texte du haut", "texte en haut", "the top text", "the text at the top", "le texte d en haut"]) {
            return scene.texts.min { $0.box.midY < $1.box.midY }
        }
        if u.contains(["le texte en bas", "le texte du bas", "texte en bas", "the bottom text", "the text at the bottom", "le texte d en bas"]) {
            return scene.texts.max { $0.box.midY < $1.box.midY }
        }
        // "t3", "l2": the id itself.
        for token in u.tokens {
            if let ref = SceneRef(token), ref.isText, let block = scene.block(ref) { return block }
        }
        return nil
    }

    static func sceneRef(_ block: SceneMap.TextBlock) -> SceneRef? { SceneRef(block.id) }

    /// "remplace le titre par « Promo »", "mets le prix en rouge", "déplace le titre en bas", "efface le sous-titre",
    /// "écris « Nouveau » sous le titre dans le même style".
    func parseSceneText(_ u: NormalizedUtterance, original: String, context: IntentContext) -> EditIntent? {
        guard context.mode == .photo, let scene = context.scene, !Self.namesTableCells(u) else { return nil }
        let quotes = Self.quotedStrings(in: original)
        let tokens = u.tokens

        // Writing new text next to a block: "écris « X » sous le titre", "add “Sale” above the price".
        let writes = u.contains(["ecris", "ecrire", "ajoute", "ajouter", "mets", "rajoute", "write", "add", "put", "insere", "place"])
        let relation: String? = {
            if u.contains(["sous le", "sous la", "en dessous du", "en dessous de", "au dessous du", "under the", "below the", "beneath the", "underneath the"]) { return "below" }
            if u.contains(["au dessus du", "au dessus de", "sur le haut du", "above the", "over the", "on top of the"]) { return "above" }
            if u.contains(["a cote du", "a cote de", "a droite du", "a droite de", "next to the", "right of the", "beside the"]) { return "right" }
            if u.contains(["a gauche du", "a gauche de", "left of the"]) { return "left" }
            return nil
        }()
        // "mets « -70% » à la place du sous-titre", "write “X” instead of the price": that block, rewritten.
        if let text = quotes.last, let phrase = u.firstMatch(Self.insteadOfPhrases), let index = u.tokenIndex(of: phrase) {
            let rest = NormalizedUtterance(u.tokens[(index + phrase.split(separator: " ").count)...].joined(separator: " "))
            if !rest.tokens.isEmpty, let block = Self.sceneBlock(rest, original: "", scene: scene), let ref = Self.sceneRef(block),
               SceneMap.folded(block.text) != SceneMap.folded(text) {
                return EditIntent(action: .editText, text: text, confidence: 0.9, ref: ref)
            }
        }
        if writes, let text = quotes.last {
            let sameStyle = u.contains(Self.sceneSameStyleWords) || u.contains(["comme le", "comme la", "like the", "same as the"])
            // "écris « X » dans la zone f7", "write “X” in f1": the id as said; the executor checks it (unknown_ref).
            if relation == nil, !sameStyle, let ref = Self.explicitRef(u) {
                var intent = EditIntent(action: .addText, text: text, confidence: 0.9, ref: ref)
                if let color = colorMention(in: u) { intent.color = color }
                return intent
            }
            let anchorQuote = quotes.count >= 2 ? quotes.first : nil
            var anchor: SceneMap.TextBlock?
            if let anchorQuote { anchor = scene.texts(matching: anchorQuote).first }
            if anchor == nil, relation != nil || sameStyle {
                // The block named without quotes ("sous le titre"): read the words without the new text.
                let rest = NormalizedUtterance(original.replacingOccurrences(of: text, with: " "))
                anchor = Self.sceneBlock(rest, original: "", scene: scene, relations: false)
            }
            // Next to a person or an object: "au-dessus de la personne", "add a caption under the person".
            if anchor == nil, relation == "below" || relation == "above", let object = Self.sceneObject(u, scene: scene) {
                var intent = EditIntent(action: .addText, text: text, confidence: 0.9)
                if relation == "below" {
                    intent.ref = SceneRef(object.id)
                } else {
                    // Right above it, and under any text that sits there already (never over the subtitle).
                    var region = PSRect(x: object.box.minX, y: max(0, object.box.minY - 0.05), width: max(0.2, object.box.width), height: 0.045).clampedToUnit()
                    if let blocker = scene.texts.filter({ $0.box.intersection(region).area > 0 }).max(by: { $0.box.maxY < $1.box.maxY }),
                       blocker.box.maxY + 0.003 < object.box.minY {
                        region.origin.y = blocker.box.maxY + 0.003
                    }
                    intent.region = region
                }
                if let color = colorMention(in: u) { intent.color = color }
                return intent
            }
            guard relation != nil || sameStyle, anchor != nil || sameStyle else { return nil }
            var intent = EditIntent(action: .addText, text: text, confidence: 0.9)
            if let anchor, let ref = Self.sceneRef(anchor) {
                if sameStyle { intent.textStyle = TextStyleSpec(match: .ref(ref)) }
                switch relation {
                case "below"?: intent.ref = ref
                case "above"?:
                    let height = anchor.box.height / Double(max(1, anchor.lineCount))
                    intent.region = PSRect(x: anchor.box.minX, y: max(0, anchor.box.minY - 1.3 * height), width: max(anchor.box.width, 0.2), height: height).clampedToUnit()
                case "right"?:
                    intent.region = PSRect(x: min(0.95, anchor.box.maxX + 0.02), y: anchor.box.minY, width: max(0.05, min(0.4, 0.98 - anchor.box.maxX)), height: anchor.box.height).clampedToUnit()
                case "left"?:
                    intent.region = PSRect(x: max(0, anchor.box.minX - 0.42), y: anchor.box.minY, width: max(0.05, min(0.4, anchor.box.minX - 0.02)), height: anchor.box.height).clampedToUnit()
                default:
                    intent.placement = placement(in: u)
                    if intent.placement == nil { intent.ref = ref }
                }
            } else {
                intent.textStyle = TextStyleSpec(match: .nearby)
                intent.placement = placement(in: u) ?? .bottom
            }
            if let color = colorMention(in: u) { intent.color = color }
            return intent
        }

        // "efface le texte t9" with no t9 on the map: the id as said, so the executor answers unknown_ref (and
        // asks), never a search for the words "le texte t9".
        if let said = Self.explicitRef(u), said.isText, scene.block(said) == nil {
            if u.contains(Self.removeVerbs) { return EditIntent(action: .removeText, confidence: 0.9, ref: said) }
            if u.contains(Self.sceneMoveVerbs) { return EditIntent(action: .moveText, placement: placement(in: u), confidence: 0.88, ref: said) }
            if u.contains(Self.sceneReplaceVerbs) { return EditIntent(action: .editText, text: quotes.last, confidence: 0.9, ref: said) }
        }
        guard let block = Self.sceneBlock(u, original: original, scene: scene), let ref = Self.sceneRef(block) else { return nil }

        // Erase it.
        if u.contains(Self.removeVerbs), !u.contains(["par", "with", "by", "et remplace", "and replace"]) {
            return EditIntent(action: .removeText, confidence: 0.9, ref: ref)
        }
        // Replace its words: "remplace le titre par « Promo »", "change le prix en 19,99 €", « SOLDES » → « PROMO ».
        if u.contains(Self.sceneReplaceVerbs) || (quotes.count >= 2 && u.contains(["par", "en", "to", "with", "by"])) {
            var text: String?
            if quotes.count >= 2 { text = quotes.last }
            else if let quoted = quotes.first, SceneMap.folded(quoted) != SceneMap.folded(block.text) { text = quoted }
            else if let after = Self.originalWords(after: ["par", "by", "with", "to", "into"], in: original) { text = after }
            else if let after = Self.originalWords(after: ["en"], in: original), colorMention(in: NormalizedUtterance(after)) == nil,
                    !NormalizedUtterance(after).contains(Self.sceneBoldWords + Self.sceneBiggerWords + Self.sceneSmallerWords + ["haut", "bas", "centre", "noir et blanc"]) {
                text = after
            }
            if let text, !text.isEmpty {
                var intent = EditIntent(action: .editText, text: text, confidence: 0.9, ref: ref)
                if u.contains(Self.sceneSameStyleWords) { intent.textStyle = TextStyleSpec(match: .ref(ref)) }
                return intent
            }
        }
        // Move it: "déplace le titre en bas", "mets le prix en haut à droite".
        let placedSomewhere = u.contains(["mets", "met", "place", "put", "positionne", "position"]) && placement(in: u) != nil && quotes.isEmpty
        if u.contains(Self.sceneMoveVerbs) || placedSomewhere {
            var intent = EditIntent(action: .moveText, confidence: 0.88, ref: ref)
            if let placement = placement(in: u) { intent.placement = placement }
            else if u.contains(["monte", "remonte", "raise", "vers le haut", "plus haut", "up", "higher"]) { intent.degrees = 90; intent.amount = .absolute(0.08) }
            else if u.contains(["descends", "descend", "baisse", "lower", "vers le bas", "plus bas", "down"]) { intent.degrees = 270; intent.amount = .absolute(0.08) }
            else if u.contains(["a gauche", "vers la gauche", "left"]) { intent.degrees = 180; intent.amount = .absolute(0.08) }
            else if u.contains(["a droite", "vers la droite", "right"]) { intent.degrees = 0; intent.amount = .absolute(0.08) }
            else { return EditIntent(action: .moveText, confidence: 0.5, ref: ref) }
            if u.contains(["un peu", "a bit", "slightly", "legerement"]) { intent.amount = .absolute(0.04) }
            return intent
        }
        // Restyle it: colour, weight, size, alignment.
        var style = TextStyleSpec()
        if u.contains(Self.sceneBiggerWords) { style.size = .scale(1.35) }
        if u.contains(Self.sceneSmallerWords) { style.size = .scale(0.75) }
        if u.contains(Self.sceneBoldWords) { style.weight = .bold }
        if u.contains(["plus fin", "moins gras", "not bold", "regular", "normal weight", "en normal"]) { style.weight = .regular }
        if u.contains(["aligne a gauche", "align left", "left aligned", "cale a gauche"]) { style.alignment = .leading }
        if u.contains(["aligne a droite", "align right", "right aligned", "cale a droite"]) { style.alignment = .trailing }
        if u.contains(["centre le", "centre la", "center the", "centered"]) { style.alignment = .center }
        // "aligne le prix à droite", "align the title left".
        if tokens.contains(where: { ["aligne", "aligner", "align", "cale", "caler"].contains($0) }) {
            if u.contains(["droite", "right"]) { style.alignment = .trailing }
            else if u.contains(["gauche", "left"]) { style.alignment = .leading }
            else if u.contains(["centre", "center", "milieu", "middle"]) { style.alignment = .center }
        }
        let color = colorMention(in: u)
        guard !style.isEmpty || color != nil else { return nil }
        // "le prix en jaune" (after "mets le titre en rouge et"): a short clause naming a block and a colour.
        let shortColour = color != nil && tokens.count <= 5
        guard tokens.contains(where: { ["mets", "passe", "rends", "fais", "make", "turn", "colore", "change", "agrandis", "grossis", "reduis", "rapetisse", "enlarge",
                                        "shrink", "aligne", "align", "centre", "center", "ecris", "write", "set"].contains($0) }) || !style.isEmpty || shortColour else { return nil }
        return EditIntent(action: .editText, color: color, confidence: 0.88, ref: ref, textStyle: style.isEmpty ? nil : style)
    }

    /// The words the person said after the first of `markers`, in their own spelling ("par Promo d'été" -> "Promo d'été").
    static func originalWords(after markers: [String], in original: String) -> String? {
        let words = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, word) in words.enumerated() where markers.contains(NormalizedUtterance.normalize(word)) {
            let rest = words[(index + 1)...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;"))
            if !rest.isEmpty { return rest }
        }
        return nil
    }

    // MARK: Follow-ups on the last step

    static let repeatWords = ["encore", "again", "refais", "refais le", "recommence", "une fois de plus", "one more time", "once more", "same again",
                              "encore une fois", "rebelote", "do it again", "fais le encore", "encore un"]
    static let sameForMarkers = ["pareil pour", "la meme chose pour", "meme chose pour", "idem pour", "same for", "the same for", "do the same for",
                                 "do the same with", "pareil avec", "same with", "fais pareil pour", "fais la meme chose pour", "et pour", "and for"]

    /// "encore", "pareil pour le chien", "plus gros", "en rouge" after a step that was not an adjustment
    /// (those are `parseFollowUp`'s): the last step again, on something else, or restyled.
    func parseLastFollowUp(_ u: NormalizedUtterance, original: String, context: IntentContext) -> EditIntent? {
        guard let last = context.lastIntent, last.action != .adjust else { return nil }
        let skipped: Set<IntentAction> = [.undo, .redo, .revert, .export, .share, .unknown, .help, .describe, .summarizeEdits, .saveVersion,
                                          .restoreVersion, .saveStyle, .applyStyle, .compare, .zoom, .confirm, .cancel, .chooseCandidate]
        guard !skipped.contains(last.action) else { return nil }
        let textActions: Set<IntentAction> = [.addText, .editText, .moveText, .fillCells, .textBehind]

        // Restyle what was just written: "plus gros", "en rouge", "en gras".
        let leftovers = u.tokens.filter { !Self.followUpFunctionWords.contains($0) && !ObjectVocabulary.fillerWords.contains($0) }
        let styleOnly = leftovers.allSatisfy { ["gros", "grand", "grande", "grosse", "petit", "petite", "gras", "bold", "bigger", "larger", "smaller", "rouge", "bleu", "vert",
                                                "jaune", "blanc", "noir", "orange", "rose", "violet", "gris", "red", "blue", "green", "yellow", "white", "black", "pink",
                                                "purple", "gray", "grey", "en", "in", "met", "mets", "le", "la", "les", "fais", "fait", "rends", "make", "it", "plus"].contains($0) }
        let looksLikeALook = u.contains(["noir et blanc", "black and white", "monochrome", "n b", "sepia", "en couleur", "in colour", "in color"])
        if textActions.contains(last.action), styleOnly, !leftovers.isEmpty, !looksLikeALook {
            var style = TextStyleSpec()
            var intent = EditIntent(action: .editText, confidence: 0.88)
            if u.contains(Self.sceneBiggerWords + ["plus gros", "bigger"]) { intent.amount = .multiplier(1.35) }
            if u.contains(Self.sceneSmallerWords) { intent.amount = .multiplier(0.75) }
            if u.contains(Self.sceneBoldWords) { style.weight = .bold }
            intent.color = colorMention(in: u)
            if !style.isEmpty { intent.textStyle = style }
            guard intent.amount != nil || intent.color != nil || intent.textStyle != nil else { return nil }
            // A layer last edited keeps being the one; a printed block was rewritten as a new layer, which the
            // step selected, so the plain editText (the selected layer) is the one ("le titre" then "plus gros").
            if last.action == .editText || last.action == .moveText, case .layer? = last.ref { intent.ref = last.ref }
            return intent
        }

        // "déplace-le en haut", "non, en bas", "move it to the top": where the text just written goes.
        if [.addText, .editText, .moveText].contains(last.action), let place = placement(in: u),
           u.contains(Self.sceneMoveVerbs + ["mets le", "mets la", "put it", "place le", "place la"])
            || u.tokens.allSatisfy({ Self.placementOnlyWords.contains($0) }) {
            var intent = EditIntent(action: .moveText, placement: place, confidence: 0.88)
            if case .layer? = last.ref { intent.ref = last.ref }
            return intent
        }

        // "pareil en bas", "same at the bottom": the text again, somewhere else.
        if last.action == .addText, u.contains(["pareil", "idem", "same", "la meme chose", "meme chose", "encore", "again"]), let place = placement(in: u),
           !u.containsPhrase("pareil pour"), !u.containsPhrase("same for") {
            var again = last
            again.id = UUID()
            again.placement = place
            again.region = nil
            again.ref = nil
            again.confidence = 0.85
            if let scene = context.scene { Self.placeOnScene(&again, u: u, scene: scene) }
            return again
        }

        // "le sous-titre aussi", "the price too": the last text step on another block of the picture.
        if let scene = context.scene, [.removeText, .editText, .moveText].contains(last.action),
           u.contains(["aussi", "egalement", "too", "also", "as well", "pareil", "idem"]),
           let block = Self.sceneBlock(u, original: original, scene: scene), let ref = Self.sceneRef(block), ref != last.ref {
            var again = last
            again.id = UUID()
            again.confidence = 0.85
            again.ref = ref
            // A restyle is copied, never the words of a rewrite.
            if last.action == .editText { again.text = nil }
            return again
        }

        // "pareil pour le chien", "same for the subtitle": the last step on something else.
        if let marker = Self.sameForMarkers.first(where: { u.containsPhrase($0) }), let rest = u.remainder(after: [marker]), !rest.isEmpty {
            var again = last
            again.id = UUID()
            again.confidence = 0.85
            if let scene = context.scene, last.ref?.isText == true, let block = Self.sceneBlock(NormalizedUtterance(rest), original: rest, scene: scene),
               let ref = Self.sceneRef(block) {
                again.ref = ref
                return again
            }
            guard last.target != nil, let target = makeTarget(from: rest, context: context) else { return nil }
            again.target = target
            again.ref = nil
            return again
        }

        // "encore": the same step once more (a table fill is the table grammar's).
        let onlyRepeat = u.tokens.allSatisfy { Self.followUpFunctionWords.contains($0) || ["refais", "recommence", "rebelote", "do", "fais", "le", "la"].contains($0) }
        if u.contains(Self.repeatWords), onlyRepeat, !IntentNormalizer.tableActions.contains(last.action) {
            var again = last
            again.id = UUID()
            again.confidence = 0.85
            return again
        }
        return nil
    }

    // MARK: Clauses with no verb

    /// Words that only decorate a clause ("ok", "merci", "s'il te plaît"): no command is missing there.
    static let clauseFiller: Set<String> = [
        "ok", "okay", "oui", "yes", "merci", "thanks", "thank", "you", "stp", "svp", "please", "alors", "bon", "voila", "super", "parfait", "genial", "cool",
        "d", "accord", "daccord", "euh", "hmm", "et", "and", "puis", "then", "maintenant", "now", "s", "il", "te", "plait", "vous", "hey", "dis", "tu", "sais",
        "bien", "tres", "c", "est", "ca", "top", "nickel", "great", "perfect", "good", "nice", "allez", "vas", "y", "go", "non", "no", "ah", "oh",
    ]

    /// A clause with no verb after a step it continues: "… et « B » en bas" (the text again, other words and
    /// place), "enlève le prix, le sous-titre et le titre" (the same step on another block).
    func parseElidedClause(_ u: NormalizedUtterance, original: String, after previous: EditIntent, context: IntentContext) -> EditIntent? {
        guard context.mode == .photo else { return nil }
        if previous.action == .addText, let text = quote(for: u, in: original) {
            var again = previous
            again.id = UUID()
            again.text = text
            again.region = nil
            again.ref = nil
            again.placement = placement(in: u) ?? previous.placement
            again.color = colorMention(in: u) ?? previous.color
            if let scene = context.scene { Self.placeOnScene(&again, u: u, scene: scene) }
            return again
        }
        if [.removeText, .editText, .moveText].contains(previous.action), let scene = context.scene,
           let block = Self.sceneBlock(u, original: "", scene: scene), let ref = Self.sceneRef(block), ref != previous.ref {
            var again = previous
            again.id = UUID()
            again.ref = ref
            if previous.action == .editText {
                again.text = quote(for: u, in: original)
                if let color = colorMention(in: u) { again.color = color }
            }
            if previous.action == .moveText, let place = placement(in: u) { again.placement = place }
            return again
        }
        return nil
    }

    // MARK: Where new text goes

    /// "à la place du sous-titre", "instead of the price".
    static let insteadOfPhrases = ["a la place du", "a la place de la", "a la place de l", "a la place des", "a la place de", "au lieu du", "au lieu de la",
                                   "au lieu de", "instead of the", "instead of", "in place of the", "in place of"]

    /// Nouns for a text block of the picture: a replace verb with one of them edits text, never adds it.
    static let textBlockNouns = ["texte", "titre", "sous titre", "legende", "prix", "slogan", "date", "text", "title", "subtitle", "caption", "price",
                                 "heading", "headline", "tagline"]

    /// Words a bare "move it there" may hold besides the place ("non, en bas", "plutôt en haut à droite").
    static let placementOnlyWords: Set<String> = {
        var words: Set<String> = ["non", "no", "plutot", "rather", "pas", "ici", "la", "le", "l", "it", "mets", "put", "et", "and", "alors", "then", "stp", "svp",
                                  "please", "ok", "mieux", "better", "a", "the", "at", "to", "on", "dans", "vers"]
        for phrase in placementPhrases.keys { for word in phrase.split(separator: " ") { words.insert(String(word)) } }
        return words
    }()

    /// The words in quotes that this clause holds (normalised match), for a sentence with several quotes.
    func quote(for u: NormalizedUtterance, in original: String) -> String? {
        var quotes = Self.quotedStrings(in: original)
        if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-zÀ-ÿ])'([^']{2,})'") {
            for match in regex.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
                if let range = Range(match.range(at: 1), in: original) { quotes.append(String(original[range]).trimmingCharacters(in: .whitespaces)) }
            }
        }
        return quotes.first { quote in
            let normalized = NormalizedUtterance.normalize(quote)
            return !normalized.isEmpty && u.containsPhrase(normalized)
        }
    }

    /// "t3", "f7", "o1", "l2" said as such (a scene id), else nil.
    static func explicitRef(_ u: NormalizedUtterance) -> SceneRef? {
        for token in u.tokens {
            guard token.count >= 2, token.count <= 4, let letter = token.first, "tlof".contains(letter), Int(token.dropFirst()) != nil else { continue }
            if let ref = SceneRef(token) { return ref }
        }
        return nil
    }

    /// The person or object the words name on the scene map ("la personne", "the dog").
    static func sceneObject(_ u: NormalizedUtterance, scene: SceneMap) -> SceneMap.Object? {
        let people = ["personne", "personnes", "person", "people", "femme", "homme", "fille", "garcon", "enfant", "man", "woman", "girl", "boy", "kid", "gens",
                      "sujet", "subject", "visage", "face", "modele", "model"]
        if u.contains(people), let person = scene.objects.first(where: { $0.kind == .person || $0.kind == .face }) { return person }
        return scene.objects.first { object in
            u.contains([object.label.lowercased()]) || ObjectVocabulary.frenchName(forLabel: object.label).map { u.contains([NormalizedUtterance.normalize($0)]) } == true
        }
    }

    /// New text on a picture the scene map describes (F13): a corner or an edge goes to the free area in
    /// that part of the picture, else to a spot clear of its text and table; size words become its size
    /// classes; on screenshots, tables and documents the text takes the page's own typography.
    static func placeOnScene(_ intent: inout EditIntent, u: NormalizedUtterance, scene: SceneMap) {
        var style = intent.textStyle ?? TextStyleSpec()
        if u.contains(["small", "petit", "petite", "tiny", "discret", "discrete", "en petit"]) { style.size = .preset(.small); intent.amount = nil }
        else if u.contains(["big", "large", "grand", "gros", "huge", "enorme", "en grand", "en gros", "bigger"]) { style.size = .preset(.large); intent.amount = nil }
        if u.contains(["serif", "empattement", "empattements"]) { style.design = .serif }
        if u.contains(["en gras", "in bold", "bold"]) { style.weight = .bold }
        if scene.kind != .photo, style.match == nil { style.match = .nearby }
        intent.textStyle = style.isEmpty ? nil : style
        guard intent.ref == nil, intent.region == nil, intent.target?.point == nil else { return }
        let place = intent.placement ?? .bottom
        if let area = freeArea(for: place, in: scene), let ref = SceneRef(area.id) {
            intent.ref = ref
        } else if let box = clearBox(for: place, in: scene) {
            intent.region = box
        }
    }

    /// The free area whose centre lies in that part of the picture, nearest its anchor; none for the centre.
    static func freeArea(for placement: TextElement.Placement, in scene: SceneMap) -> SceneMap.FreeArea? {
        let usable = scene.freeAreas.filter { $0.box.width >= 0.12 && $0.box.height >= 0.03 }
        let fits: (SceneMap.FreeArea) -> Bool
        switch placement {
        case .topLeading: fits = { $0.box.center.x < 0.5 && $0.box.center.y < 0.5 }
        case .topTrailing: fits = { $0.box.center.x > 0.5 && $0.box.center.y < 0.5 }
        case .bottomLeading: fits = { $0.box.center.x < 0.5 && $0.box.center.y > 0.5 }
        case .bottomTrailing: fits = { $0.box.center.x > 0.5 && $0.box.center.y > 0.5 }
        case .top: fits = { $0.box.center.y < 0.3 && $0.box.minX <= 0.55 && $0.box.maxX >= 0.45 }
        case .bottom: fits = { $0.box.center.y > 0.7 && $0.box.minX <= 0.55 && $0.box.maxX >= 0.45 }
        case .center: return nil
        }
        let anchor = placement.center
        return usable.filter(fits).min { $0.box.center.distance(to: anchor) < $1.box.center.distance(to: anchor) }
    }

    /// A box of `size` (0.3 × 0.07 by default) at the placement's anchor (or `anchor`), moved (down from the top,
    /// up from the bottom, then the other way) off every text block and the table; nil when the anchor is
    /// already clear or no clear spot is near. `ignoring` is a layer already on the map (the text being placed).
    static func clearBox(for placement: TextElement.Placement, in scene: SceneMap, size: PSSize = PSSize(width: 0.3, height: 0.07),
                         anchor: PSPoint? = nil, ignoring: UUID? = nil) -> PSRect? {
        let center = anchor ?? placement.center
        var obstacles = scene.texts.filter { ignoring == nil || $0.layerID != ignoring }.map(\.box)
        if let table = scene.table?.bounds { obstacles.append(table) }
        let width = min(0.98, size.width), height = min(0.5, size.height)
        let x = (center.x - width / 2).clamped(to: 0.01...max(0.01, 0.99 - width))
        func box(_ y: Double) -> PSRect { PSRect(x: x, y: y, width: width, height: height) }
        func clear(_ candidate: PSRect) -> Bool { !obstacles.contains { $0.intersection(candidate).area > 0.0001 } }
        let top = max(0.01, 0.99 - height)
        let start = (center.y - height / 2).clamped(to: 0.01...top)
        guard !clear(box(start)) else { return nil }
        let natural: Double = [.bottom, .bottomLeading, .bottomTrailing].contains(placement) ? -1 : 1
        for step in 1...40 {
            for sign in [natural, -natural] {
                let y = start + sign * Double(step) * 0.01
                guard y >= 0.01, y <= top else { continue }
                if clear(box(y)) { return box(y) }
            }
        }
        return nil
    }
}
