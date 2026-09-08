import Foundation
import PicshopCore

/// Deterministic grammar-based parser for French and English editing commands.
///
/// It is the always-available fast path: it runs in well under a millisecond,
/// needs no model, and its output doubles as the "hint" handed to the on-device
/// LLM for ambiguous utterances. Parsing is organised as an ordered list of
/// matchers from most to least specific.
public struct RuleBasedIntentEngine: IntentEngine {
    public let kind: IntentEngineKind = .rules

    public init() {}

    public func isAvailable() async -> Bool { true }

    public func plan(_ utterance: String, context: IntentContext) async throws -> EditPlan {
        parse(utterance, context: context)
    }

    /// Synchronous entry point (also used directly by tests and the hybrid router).
    public func parse(_ utterance: String, context: IntentContext) -> EditPlan {
        let normalized = NormalizedUtterance(utterance)
        let language: NormalizedUtterance.Language = {
            if let preferred = context.preferredLanguage?.lowercased() {
                if preferred.hasPrefix("fr") { return .french }
                if preferred.hasPrefix("en") { return .english }
            }
            return normalized.language
        }()
        guard !normalized.tokens.isEmpty else {
            return EditPlan.unknown(utterance)
        }

        if let pending = context.pendingClarification, let choice = parseCandidateChoice(normalized, pending: pending, context: context) {
            return EditPlan(utterance: utterance, intents: [choice], confidence: choice.confidence, language: language.rawValue,
                            reply: Replies.reply(for: choice, language: language), engine: .rules)
        }

        var intents: [EditIntent] = []
        for segment in UtteranceSegmenter.segments(of: normalized.text) {
            let piece = NormalizedUtterance(segment)
            let parsed = parseSegment(piece, original: utterance, context: context)
            intents.append(contentsOf: parsed)
        }

        // Drop unknowns if at least one segment was understood.
        let understood = intents.filter { $0.action != .unknown }
        let final = understood.isEmpty ? intents : understood
        let confidence = final.map(\.confidence).min() ?? 0
        return EditPlan(utterance: utterance, intents: final, confidence: confidence, language: language.rawValue,
                        reply: Replies.combined(for: final, language: language), engine: .rules)
    }

    // MARK: - Segment dispatch

    func parseSegment(_ u: NormalizedUtterance, original: String, context: IntentContext) -> [EditIntent] {
        if let version = parseVersion(u, original: original) { return [version] }
        if let meta = parseMeta(u, context: context) { return [meta] }
        if context.mode == .photo, let describe = parseDescribe(u) { return [describe] }
        if context.mode == .pdf { return parsePDF(u, original: original, context: context) }
        if context.mode == .video, let video = parseVideo(u, context: context) { return video }
        if context.mode == .photo, let goal = parseGoal(u, context: context) { return goal }
        if context.mode == .photo, let portrait = parsePortrait(u) { return [portrait] }
        if context.mode == .photo, let generative = parseGenerative(u, original: original, context: context) { return [generative] }
        if let background = parseBackground(u) { return [background] }
        if let removal = parseRemoveObject(u, context: context) { return [removal] }
        if let text = parseText(u, original: original, context: context) { return [text] }
        if let enhance = parseAutoEnhance(u) { return [enhance] }
        if let crop = parseCrop(u) { return [crop] }
        if let geometry = parseGeometry(u, context: context) { return [geometry] }
        if let look = parseLook(u) { return [look] }
        if let resolution = parseResolution(u) { return [resolution] }
        if let adjust = parseAdjust(u, context: context) { return [adjust] }
        if let followUp = parseFollowUp(u, context: context) { return [followUp] }
        if let layer = parseLayer(u, context: context) { return [layer] }
        return [EditIntent(action: .unknown, confidence: 0)]
    }

    // MARK: - Shared helpers

    static let removeVerbs: [String] = [
        "efface", "effacer", "effaces", "enleve", "enlever", "enleves", "supprime", "supprimer", "supprimes", "retire", "retirer", "retires",
        "gomme", "gommer", "vire", "virer", "degage", "fais disparaitre", "fait disparaitre", "faire disparaitre", "elimine", "eliminer",
        "nettoie", "nettoyer", "ote", "oter", "masque", "masquer", "cache", "cacher", "remove", "erase", "delete", "get rid of", "take out",
        "take away", "clear", "clean up", "cleanup", "wipe", "eliminate", "hide", "zap", "scrub", "scrub out", "make disappear", "drop",
        "cut out", "efface moi", "enleve moi", "supprime moi", "vire moi", "retire moi",
    ]

    static let backgroundWords: [String] = ["background", "backdrop", "fond", "arriere plan", "l arriere plan", "decor", "arriere", "derriere le sujet", "behind the subject", "bg"]

    static let allWords: [String] = ["all", "every", "everything", "tous", "toutes", "tout", "chaque", "all the", "all of the", "tous les", "toutes les"]

    /// Extracts a target description from a phrase such as "the two dogs on the left".
    func makeTarget(from phrase: String, context: IntentContext) -> ObjectTarget? {
        let normalizedPhrase = NormalizedUtterance(phrase)
        var tokens = normalizedPhrase.tokens
        guard !tokens.isEmpty else { return nil }

        var spatial: SpatialHint?
        for hint in SpatialHint.allCases {
            if let matched = normalizedPhrase.firstMatch(hint.aliases) {
                spatial = spatial ?? hint
                tokens = remove(phrase: matched, from: tokens)
            }
        }

        var ordinal: Int?
        for (index, token) in tokens.enumerated() {
            if let value = NumberWords.ordinal(token) {
                ordinal = value
                tokens.remove(at: index)
                break
            }
        }

        var matchesAll = false
        for phrase in Self.allWords.sorted(by: { $0.count > $1.count }) {
            let words = phrase.split(separator: " ").map(String.init)
            if let index = indexOfSequence(words, in: tokens) {
                matchesAll = true
                tokens.removeSubrange(index..<(index + words.count))
            }
        }
        if let number = NumberWords.firstNumber(in: tokens), number.value > 1 {
            matchesAll = true
            tokens.removeSubrange(number.index..<(number.index + number.consumed))
        }

        var attributes: [String] = []
        tokens = tokens.filter { token in
            if ObjectVocabulary.attributeWords.contains(token) {
                attributes.append(token)
                return false
            }
            return true
        }
        tokens = tokens.filter { !ObjectVocabulary.fillerWords.contains($0) }
        tokens = tokens.filter { !["autre", "autres", "other", "others", "aussi", "also", "too", "encore", "again", "completement", "completely", "entirely", "entierement"].contains($0) }

        let cleaned = tokens.joined(separator: " ")
        if cleaned.isEmpty {
            if spatial != nil || ordinal != nil || matchesAll {
                return ObjectTarget(label: "object", originalPhrase: phrase, spatialHint: spatial, ordinal: ordinal, matchesAll: matchesAll, attributes: attributes, point: context.lastTapPoint)
            }
            return nil
        }
        if let match = ObjectVocabulary.match(cleaned) {
            let leftover = remove(phrase: match.matchedForm, from: cleaned.split(separator: " ").map(String.init))
            attributes.append(contentsOf: leftover.filter { $0.count > 2 })
            let point = match.entry.category == .generic ? context.lastTapPoint : nil
            return ObjectTarget(label: match.entry.label, originalPhrase: phrase, spatialHint: spatial, ordinal: ordinal, matchesAll: matchesAll, attributes: attributes, point: point)
        }
        // Unknown noun — keep the words; the grounding layer can still try embeddings.
        return ObjectTarget(label: cleaned, originalPhrase: phrase, spatialHint: spatial, ordinal: ordinal, matchesAll: matchesAll, attributes: attributes, point: context.lastTapPoint)
    }

    func indexOfSequence(_ words: [String], in tokens: [String]) -> Int? {
        guard !words.isEmpty, tokens.count >= words.count else { return nil }
        for start in 0...(tokens.count - words.count) where Array(tokens[start..<(start + words.count)]) == words {
            return start
        }
        return nil
    }

    func remove(phrase: String, from tokens: [String]) -> [String] {
        let words = phrase.split(separator: " ").map(String.init)
        guard let index = indexOfSequence(words, in: tokens) else { return tokens }
        var copy = tokens
        copy.removeSubrange(index..<(index + words.count))
        return copy
    }

    /// Words following the first matched verb phrase, or nil.
    func remainder(of u: NormalizedUtterance, after phrases: [String]) -> String? {
        u.remainder(after: phrases)
    }

    // MARK: - Clarification replies

    func parseCandidateChoice(_ u: NormalizedUtterance, pending: ClarificationRequest, context: IntentContext) -> EditIntent? {
        // "non, le chat" names another object: that is a correction, not a cancellation.
        let restated = makeTarget(from: u.text, context: context)
        let restatedKnown = restated.flatMap { ObjectVocabulary.entry(forLabel: $0.label) }.map { $0.category != .generic } ?? false
        let pendingLabel = pending.pendingIntent.target?.label
        if u.contains(["cancel", "annule", "laisse tomber", "never mind", "nevermind", "forget it", "non", "no", "aucun", "aucune", "none", "stop", "oublie"]),
           !restatedKnown || restated?.label == pendingLabel {
            return EditIntent(action: .cancel)
        }
        if u.contains(["both", "les deux", "all", "tous", "toutes", "all of them", "everyone", "tout le monde", "everything"]) {
            return EditIntent(action: .chooseCandidate, scope: .all, confidence: 0.95)
        }
        for token in u.tokens {
            if let ordinal = NumberWords.ordinal(token) {
                let resolved = ordinal == -1 ? pending.candidates.count : ordinal
                return EditIntent(action: .chooseCandidate, index: resolved, confidence: 0.95)
            }
        }
        if let number = NumberWords.firstNumber(in: u.tokens), number.value >= 1, number.value <= Double(pending.candidates.count),
           number.value == number.value.rounded(), !(u.tokens[number.index] == "a" || u.tokens[number.index] == "un" || u.tokens[number.index] == "une") {
            return EditIntent(action: .chooseCandidate, index: Int(number.value), confidence: 0.9)
        }
        for hint in SpatialHint.allCases where u.contains(hint.aliases) {
            var intent = EditIntent(action: .chooseCandidate, confidence: 0.9)
            intent.target = ObjectTarget(label: pending.pendingIntent.target?.label ?? "object", originalPhrase: u.original, spatialHint: hint)
            return intent
        }
        if u.contains(["this one", "that one", "celui la", "celle la", "celui ci", "celle ci", "ca", "cela", "there", "la"]), let point = context.lastTapPoint {
            var intent = EditIntent(action: .chooseCandidate, confidence: 0.85)
            intent.target = ObjectTarget(label: pending.pendingIntent.target?.label ?? "object", originalPhrase: u.original, point: point)
            return intent
        }
        // Re-stated target with attributes: "le chien noir" → pass through as a refined target.
        if let target = restated, target.label == pendingLabel, (!target.attributes.isEmpty || target.spatialHint != nil) {
            var intent = EditIntent(action: .chooseCandidate, confidence: 0.8)
            intent.target = target
            return intent
        }
        // A different object: redo the pending command on it ("non, le chat", "the lamp instead").
        if let target = restated, restatedKnown, target.label != pendingLabel {
            var intent = pending.pendingIntent
            intent.id = UUID()
            intent.target = target
            intent.confidence = 0.85
            return intent
        }
        return nil
    }

    // MARK: - Meta commands

    func parseMeta(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        if u.contains(["help", "aide", "aide moi", "what can you do", "que peux tu faire", "qu est ce que tu sais faire", "commandes", "commands", "what can i say", "que puis je dire"]) {
            return EditIntent(action: .help)
        }
        let hasTime = TimeExpressions.firstTime(in: u.tokens, frameRate: context.frameRate) != nil
        if u.contains(["undo", "annule", "annuler", "annule ca", "reviens en arriere", "revenir en arriere", "retourne en arriere", "retour en arriere", "go back", "oops", "undo that", "undo the last", "annule la derniere", "non pas ca", "pas ca", "revert that", "annule le dernier", "step back", "annule ce que tu viens de faire", "undo what you just did", "revert the last change", "cancel the last change", "enleve ce que tu viens de faire", "remets comme avant", "put it back", "c etait mieux avant", "it was better before"]) && !u.contains(["annule tout", "undo everything", "undo all"]) && !(context.mode == .video && hasTime) {
            return EditIntent(action: .undo)
        }
        if u.contains(["redo", "retablis", "retablir", "refais", "refaire", "redo that", "remets ce que", "restore that"]) {
            return EditIntent(action: .redo)
        }
        if u.contains(["revert", "revert to original", "back to the original", "reviens a l original", "remets l original", "retour a l original", "start over", "recommence", "recommencer",
                       "reset everything", "reset all", "tout annuler", "annule tout", "undo everything", "undo all", "remove all edits", "enleve toutes les modifications",
                       "supprime toutes les modifications", "enleve tous les reglages", "reset the photo", "reset the image", "reset the video", "reinitialise", "reinitialiser", "version originale", "original version", "restore the original"]) {
            return EditIntent(action: .revert)
        }
        if u.contains(["compare", "comparer", "avant apres", "avant et apres", "before and after", "before after", "show the original", "montre l original", "show me the original", "montre moi l original", "show before", "montre avant", "montre moi avant", "show me before", "voir l original", "see the original", "avant", "before"]) && u.tokens.count <= 5 {
            return EditIntent(action: .compare)
        }
        if u.contains(["export", "exporte", "exporter", "save", "sauvegarde", "sauvegarder", "enregistre", "enregistrer", "download", "telecharge", "save it", "save the photo", "save the video", "enregistre la photo", "enregistre la video", "save to photos", "save to camera roll", "enregistre dans photos"]) && !u.contains(["frame", "image", "capture"]) {
            return EditIntent(action: .export)
        }
        if u.contains(["share", "partage", "partager", "send it", "envoie", "envoyer", "share it", "partage la photo", "partage la video", "airdrop", "send to"]) && !(context.mode == .pdf && u.contains(Self.pageWords)) {
            return EditIntent(action: .share)
        }
        if u.contains(["zoom in", "zoom avant", "zoome", "zoom", "agrandis la vue", "rapproche", "closer", "zoom out", "zoom arriere", "dezoome", "eloigne", "fit to screen", "fit", "ajuste a l ecran", "vue d ensemble", "show everything", "montre tout", "zoom sur", "zoom on"]) {
            var intent = EditIntent(action: .zoom)
            if u.contains(["zoom out", "zoom arriere", "dezoome", "eloigne", "recule"]) {
                intent.amount = .multiplier(0.5)
            } else if u.contains(["fit", "fit to screen", "ajuste a l ecran", "vue d ensemble", "show everything", "montre tout", "reset zoom", "zoom normal"]) {
                intent.amount = .absolute(1)
            } else {
                intent.amount = .multiplier(2)
            }
            if let rest = remainder(of: u, after: ["zoom sur", "zoom on", "zoom in on", "zoome sur", "rapproche toi de", "closer to", "zoom to"]), let target = makeTarget(from: rest, context: context) {
                intent.target = target
            }
            return intent
        }
        if context.pendingClarification == nil {
            if u.contains(["cancel", "laisse tomber", "never mind", "nevermind", "forget it", "oublie", "stop", "arrete"]) && context.mode == .photo {
                return EditIntent(action: .cancel)
            }
            if u.tokens.count <= 3, u.contains(["yes", "oui", "ok", "okay", "confirme", "vas y", "go", "do it", "fais le", "c est bon", "parfait", "yep", "ouais", "sure", "exactly", "exactement", "correct"]) {
                return EditIntent(action: .confirm)
            }
        }
        return nil
    }

    // MARK: - Background

    func parseBackground(_ u: NormalizedUtterance) -> EditIntent? {
        if u.contains(["everything except", "everything but", "all but", "tout sauf", "tout le monde sauf", "everyone except", "everyone but", "apart from", "a part"]) && (u.contains(Self.removeVerbs) || u.contains(["keep", "garde", "only", "seulement"])) {
            return EditIntent(action: .removeBackground, background: .transparent, confidence: 0.85)
        }
        let mentionsBackground = u.contains(Self.backgroundWords)
        // Blur / portrait effect.
        if u.contains(["blur the background", "blur background", "blurred background", "floute le fond", "floute l arriere plan", "flouter le fond", "flouter l arriere plan", "fond flou", "arriere plan flou", "portrait mode", "mode portrait", "effet portrait", "portrait effect", "bokeh", "depth effect", "effet de profondeur", "profondeur de champ", "depth of field", "background blur", "flou d arriere plan", "flou de fond"])
            || (mentionsBackground && u.contains(["blur", "floute", "flouter", "flou", "floue", "soften", "adoucis"])) {
            var intent = EditIntent(action: .blurBackground)
            let magnitude = AmountParser.magnitude(in: u)
            intent.amount = .absolute(magnitude.explicitNumber.map { $0 } ?? (magnitude.qualifier == .slight ? 0.35 : magnitude.qualifier == .strong ? 0.9 : 0.65))
            if u.contains(["less", "moins", "reduce", "reduis", "diminue", "baisse"]) { intent.amount = .relative(-0.2) }
            if u.contains(["more", "plus", "davantage"]) && !u.contains(["floute", "flouter", "blur the"]) { intent.amount = .relative(0.2) }
            return intent
        }
        // Replace with a colour / gradient.
        if mentionsBackground || u.contains(["fond blanc", "fond noir", "white background", "black background"]) {
            let colorToken = u.tokens.compactMap { PSColor.named($0) != nil ? $0 : nil }
            let twoWordColors = ["bleu clair", "bleu fonce", "vert clair", "vert fonce", "light blue", "dark blue", "light gray", "dark gray", "light grey", "dark grey", "light green", "dark green", "rose clair", "light pink"]
            let colorPhrase = u.firstMatch(twoWordColors) ?? colorToken.first
            let wantsChange = u.contains(["change", "changer", "replace", "remplace", "remplacer", "mets", "met", "mettre", "put", "set", "make", "rends", "rendre", "fais", "swap", "use", "utilise", "colore", "color", "colour", "en", "with", "avec", "to", "into", "fond blanc", "fond noir", "white background", "black background"])
            if let colorPhrase, wantsChange || colorToken.count == 1 {
                if u.contains(["transparent", "transparente"]) {
                    return EditIntent(action: .removeBackground, background: .transparent)
                }
                let color = PSColor.named(colorPhrase) ?? .white
                return EditIntent(action: .replaceBackground, color: color, background: .color(color))
            }
            if u.contains(["transparent", "transparente", "sans fond", "no background", "png"]) {
                return EditIntent(action: .removeBackground, background: .transparent)
            }
            if u.contains(["gradient", "degrade"]) {
                return EditIntent(action: .replaceBackground, background: .gradient(PSColor(red: 0.16, green: 0.2, blue: 0.36), PSColor(red: 0.55, green: 0.35, blue: 0.75)))
            }
            if backgroundIsDirectObject(of: u) || u.contains(["detoure", "detourer", "cut out", "cutout", "isolate", "isole", "extract the subject", "extrais le sujet", "keep only the subject", "garde seulement le sujet", "ne garde que"]) {
                return EditIntent(action: .removeBackground, background: .transparent)
            }
            if u.contains(Self.removeVerbs) {
                // "remove the car in the background" → object removal with a spatial hint.
                return nil
            }
            if u.contains(["change", "changer", "replace", "remplace", "remplacer", "swap", "new background", "nouveau fond", "autre fond", "another background", "different background"]) {
                return EditIntent(action: .replaceBackground, background: nil, confidence: 0.85)
            }
        }
        if u.contains(["detoure", "detourer", "detoure moi", "detourage", "cut out the subject", "cut out", "cutout", "isolate the subject", "isole le sujet", "extract the subject", "extrais le sujet", "keep only the subject", "garde seulement le sujet", "sticker", "make a sticker", "fais un sticker", "remove bg", "supprime le decor"]) {
            return EditIntent(action: .removeBackground, background: .transparent)
        }
        return nil
    }

    /// True when the words right after the remove verb name the background itself
    /// ("efface le fond"), as opposed to an object located in it.
    func backgroundIsDirectObject(of u: NormalizedUtterance) -> Bool {
        guard let rest = remainder(of: u, after: Self.removeVerbs) else { return false }
        let tokens = rest.split(separator: " ").map(String.init).filter { !ObjectVocabulary.fillerWords.contains($0) && $0 != "completement" && $0 != "completely" && $0 != "entirely" }
        let head = tokens.prefix(2).joined(separator: " ")
        return Self.backgroundWords.contains { head == $0 || head.hasPrefix($0 + " ") || tokens.first == $0 }
    }

    // MARK: - Generative fill & recolor

    static let replaceVerbs: [String] = ["remplace", "remplacer", "replace", "change", "changer", "transforme", "transformer", "turn", "swap", "convertis", "convert", "mets", "put"]

    /// What to generate when the user names a region but not its replacement.
    static let defaultGenerativePrompts: [String: String] = [
        "sky": "a clear blue sky with soft white clouds",
        "cloud": "a clear blue sky",
        "grass": "lush green grass",
        "water": "calm clear water",
    ]

    func parseGenerative(_ u: NormalizedUtterance, original: String, context: IntentContext) -> EditIntent? {
        // "remplace le ciel par un coucher de soleil" / "replace the sky with a sunset" / "turn the car into a boat"
        let connectors = ["par", "with", "into", "en", "to", "by"]
        if u.contains(Self.replaceVerbs), let rest = remainder(of: u, after: Self.replaceVerbs) {
            let restTokens = rest.split(separator: " ").map(String.init)
            if let split = restTokens.indices.dropFirst().first(where: { connectors.contains(restTokens[$0]) }), split < restTokens.count - 1 {
                let subject = restTokens[..<split].joined(separator: " ")
                let replacementTokens = Array(restTokens[(split + 1)...])
                let replacement = replacementTokens.joined(separator: " ")
                let subjectIsBackground = NormalizedUtterance(subject).contains(Self.backgroundWords)
                // Colour target → recolor.
                let colorWords = replacementTokens.filter { !ObjectVocabulary.fillerWords.contains($0) }
                if colorWords.count <= 2, let color = PSColor.named(colorWords.joined(separator: " ")), !subjectIsBackground,
                   let target = makeTarget(from: subject, context: context) {
                    return EditIntent(action: .recolor, target: target, color: color, confidence: 0.9)
                }
                if subjectIsBackground, let color = PSColor.named(colorWords.joined(separator: " ")) {
                    return EditIntent(action: .replaceBackground, color: color, background: .color(color))
                }
                if NormalizedUtterance(subject).contains(["text", "texte", "titre", "title", "filter", "filtre", "look", "music", "musique"]) { return nil }
                let prompt = originalSubstring(matching: replacement, in: original) ?? replacement
                if subjectIsBackground {
                    return EditIntent(action: .generativeFill, target: ObjectTarget(label: "background", originalPhrase: subject), text: prompt, confidence: 0.85)
                }
                if let target = makeTarget(from: subject, context: context) {
                    return EditIntent(action: .generativeFill, target: target, text: prompt, confidence: 0.85)
                }
            } else if let target = makeTarget(from: rest, context: context), let prompt = Self.defaultGenerativePrompts[target.label], target.attributes.isEmpty,
                      ParameterVocabulary.match(in: NormalizedUtterance(rest)) == nil, AmountParser.sign(in: NormalizedUtterance(rest)) == 0,
                      !NormalizedUtterance(rest).contains(["text", "texte", "titre", "title", "filter", "filtre", "look", "music", "musique", "couleur", "color", "colour"]) {
                // "change le ciel" / "replace the sky": no replacement said, use a sensible default.
                return EditIntent(action: .generativeFill, target: target, text: prompt, confidence: 0.8)
            }
        }
        // "rends la voiture rouge" / "make the car red" / "colore les murs en bleu"
        if u.contains(["make", "rends", "rendre", "colore", "colorer", "colorie", "colour", "color", "paint", "peins", "peindre", "teins"]) {
            let twoWord = ["bleu clair", "bleu fonce", "vert clair", "vert fonce", "light blue", "dark blue", "light gray", "dark gray", "light green", "dark green", "rose clair", "light pink"]
            let colorPhrase = u.firstMatch(twoWord) ?? u.tokens.first { PSColor.named($0) != nil && !["clear", "light", "rose"].contains($0) }
            let comparativeBefore = colorPhrase.flatMap { phrase -> Bool? in
                guard let index = u.tokenIndex(of: phrase), index > 0 else { return false }
                return ["plus", "more", "moins", "less", "trop", "too", "tres", "very", "un peu", "bit"].contains(u.tokens[index - 1])
            } ?? false
            if let colorPhrase, let color = PSColor.named(colorPhrase), !comparativeBefore, !u.contains(["background", "fond", "arriere plan", "text", "texte"]) {
                var words = remove(phrase: colorPhrase, from: u.tokens)
                words = words.filter { !["make", "rends", "rendre", "colore", "colorer", "colorie", "colour", "color", "paint", "peins", "peindre", "teins", "en", "in", "de", "to"].contains($0) }
                if let target = makeTarget(from: words.joined(separator: " "), context: context), ObjectVocabulary.entry(forLabel: target.label) != nil, target.label != "object" {
                    return EditIntent(action: .recolor, target: target, color: color, confidence: 0.85)
                }
            }
        }
        // "ajoute un chapeau" / "add a hat on his head" / "génère un dragon dans le ciel"
        if u.contains(["genere", "generer", "generate", "imagine", "dessine", "draw", "invente", "cree", "create"]) || (u.contains(["ajoute", "add", "mets", "put"]) && !u.contains(["text", "texte", "titre", "title", "legende", "caption", "filter", "filtre", "look", "vignette", "grain", "music", "musique", "transition", "page", "signature", "numero"])) {
            let rest = remainder(of: u, after: ["genere", "generer", "generate", "imagine", "dessine", "draw", "invente", "cree", "create", "ajoute", "add", "mets", "put"]) ?? u.text
            let restTokens = rest.split(separator: " ").map(String.init)
            var target: ObjectTarget?
            var promptTokens = restTokens
            let placementConnectors = ["sur", "on", "dans", "in", "onto", "a la place de", "instead of", "devant", "in front of", "derriere", "behind", "au dessus de", "above"]
            if let split = restTokens.indices.dropFirst().first(where: { placementConnectors.contains(restTokens[$0]) }), split < restTokens.count - 1 {
                promptTokens = Array(restTokens[..<split])
                target = makeTarget(from: restTokens[(split + 1)...].joined(separator: " "), context: context)
            }
            let cleaned = promptTokens.filter { !["un", "une", "a", "an", "des", "some", "the", "le", "la", "les"].contains($0) }
            guard !cleaned.isEmpty, ParameterVocabulary.match(in: NormalizedUtterance(cleaned.joined(separator: " "))) == nil || u.contains(["genere", "generate", "imagine", "dessine", "draw"]) else { return nil }
            if ObjectVocabulary.match(cleaned.joined(separator: " ")) == nil, !u.contains(["genere", "generer", "generate", "imagine", "dessine", "draw", "invente", "cree", "create"]) { return nil }
            let prompt = originalSubstring(matching: promptTokens.joined(separator: " "), in: original) ?? promptTokens.joined(separator: " ")
            var intent = EditIntent(action: .generativeFill, target: target, text: prompt, confidence: 0.75)
            if intent.target == nil, let point = context.lastTapPoint { intent.target = ObjectTarget(label: "object", originalPhrase: "here", point: point) }
            return intent
        }
        return nil
    }

    // MARK: - Goals ("make it a profile picture", "photo produit", "restore this old photo")

    static let cropWords: [String] = ["crop", "recadre", "recadrer", "recadrage", "format", "ratio", "aspect"]

    /// Everyday goals become the sequence of edits a retoucher would do. The
    /// result is deterministic and confident, so it never waits for a model.
    func parseGoal(_ u: NormalizedUtterance, context: IntentContext) -> [EditIntent]? {
        let identity = ["photo d identite", "id photo", "passport photo", "photo passeport", "passport", "photo pour passeport", "visa photo", "identity photo", "photo identite", "photo pour visa"]
        let product = ["photo produit", "product photo", "product shot", "product picture", "product image", "e commerce", "ecommerce", "vinted", "leboncoin", "ebay", "etsy", "amazon", "pour vendre", "to sell", "for sale", "shop listing", "listing photo", "fiche produit", "catalogue", "catalog"]
        let headshot = ["linkedin", "headshot", "pour mon cv", "for my resume", "for my cv", "photo cv", "photo pro"]
        let profile = ["photo de profil", "photo de profile", "profile picture", "profile photo", "profile pic", "avatar", "pour mon profil", "for my profile", "pfp"]
        let professional = ["professionnel", "professionnelle", "professional", "corporate"]
        let wallpaper = ["fond d ecran", "wallpaper", "lock screen", "ecran de verrouillage", "ecran d accueil", "home screen"]
        let restore = ["restaure", "restaurer", "restore", "vieille photo", "old photo", "ancienne photo", "photo ancienne", "photo abimee", "damaged photo", "faded photo", "old picture", "vieux cliche", "photo scannee", "scanned photo", "photo numerisee"]
        let night = ["photo de nuit", "prise de nuit", "taken at night", "night shot", "night photo", "low light", "faible lumiere", "basse lumiere", "trop sombre pour voir", "too dark to see", "on ne voit rien", "can t see anything"]
        let backlit = ["contre jour", "backlit", "backlight", "against the light", "sujet trop sombre", "subject is too dark", "subject too dark", "visage trop sombre", "face is too dark", "face too dark"]
        let hdr = ["hdr", "effet hdr", "hdr look", "high dynamic range"]
        let aesthetic = ["aesthetic", "esthetique", "tendance", "trendy", "pinterest", "vsco"]

        var intents: [EditIntent] = []
        if u.contains(identity) {
            intents = [EditIntent(action: .replaceBackground, color: .white, background: .color(.white)), EditIntent(action: .crop, aspect: .ratio3x4)]
        } else if u.contains(product) {
            intents = [EditIntent(action: .replaceBackground, color: .white, background: .color(.white)), EditIntent(action: .autoEnhance, amount: .absolute(0.7))]
        } else if u.contains(headshot) || u.contains(profile) {
            intents = [EditIntent(action: .autoEnhance, amount: .absolute(0.7)), EditIntent(action: .crop, aspect: .square)]
        } else if u.contains(professional) {
            intents = [EditIntent(action: .autoEnhance, amount: .absolute(0.7))]
        } else if u.contains(wallpaper) {
            intents = [EditIntent(action: .crop, aspect: .ratio9x16)]
        } else if u.contains(restore) {
            intents = [EditIntent(action: .autoEnhance, amount: .absolute(0.8)),
                       EditIntent(action: .adjust, parameter: .noiseReduction, amount: .relative(0.4)),
                       EditIntent(action: .adjust, parameter: .sharpness, amount: .relative(0.2))]
        } else if u.contains(backlit) {
            intents = [EditIntent(action: .adjust, parameter: .shadows, amount: .relative(0.4)), EditIntent(action: .adjust, parameter: .highlights, amount: .relative(-0.2))]
        } else if u.contains(night) {
            intents = [EditIntent(action: .adjust, parameter: .brightness, amount: .relative(0.2)),
                       EditIntent(action: .adjust, parameter: .shadows, amount: .relative(0.3)),
                       EditIntent(action: .adjust, parameter: .noiseReduction, amount: .relative(0.3))]
        } else if u.contains(hdr) {
            intents = [EditIntent(action: .adjust, parameter: .shadows, amount: .relative(0.35)),
                       EditIntent(action: .adjust, parameter: .highlights, amount: .relative(-0.35)),
                       EditIntent(action: .adjust, parameter: .clarity, amount: .relative(0.3))]
        } else if u.contains(aesthetic) {
            intents = [EditIntent(action: .applyLook, amount: .absolute(0.8), look: .matte)]
        }
        guard !intents.isEmpty else { return nil }
        if u.contains(Self.cropWords) {
            // "crop for my profile picture" only wants the frame.
            let crops = intents.filter { $0.action == .crop }
            return crops.isEmpty ? nil : crops
        }
        return intents
    }

    // MARK: - Portrait retouching

    static let skinSmoothingPhrases: [String] = ["smooth the skin", "smooth skin", "smooth out the skin", "skin smoothing", "soften the skin", "soften skin", "smooth my skin", "skin retouch", "beauty retouch", "beautify",
                                                 "lisse la peau", "lisser la peau", "adoucis la peau", "adoucir la peau", "peau plus lisse", "peau plus douce", "retouche la peau", "lisse ma peau", "adoucis ma peau", "retouche beaute", "gomme les rides", "efface les rides", "remove the wrinkles", "remove wrinkles"]

    /// "lisse la peau" → a gentle noise reduction masked to the face.
    func parsePortrait(_ u: NormalizedUtterance) -> EditIntent? {
        guard u.contains(Self.skinSmoothingPhrases) else { return nil }
        let magnitude = AmountParser.magnitude(in: u)
        let amount = magnitude.explicitNumber.map { abs($0) } ?? (magnitude.qualifier == .slight ? 0.3 : magnitude.qualifier == .strong ? 0.8 : 0.5)
        let phrase = u.language == .french ? "la peau" : "the skin"
        return EditIntent(action: .selectiveAdjust, target: ObjectTarget(label: "face", originalPhrase: phrase), parameter: .noiseReduction, amount: .relative(amount), confidence: 0.9)
    }

    // MARK: - Follow-ups ("encore un peu", "a bit more", "trop", "less")

    static let followUpAgainWords: [String] = ["encore", "again", "pareil", "same", "same again", "continue", "once more", "one more time", "une fois de plus", "refais pareil", "more of that", "plus encore", "recommence", "idem"]
    static let followUpTooWords: [String] = ["trop", "too much", "too far", "way too much", "overdone", "c est trop", "that s too much", "beaucoup trop", "excessif", "too strong", "trop fort"]
    static let followUpNotEnoughWords: [String] = ["pas assez", "not enough", "insuffisant", "plus que ca", "more than that", "plus fort", "stronger", "harder", "encore plus", "davantage"]
    static let followUpFunctionWords: Set<String> = ["ca", "c", "est", "it", "s", "un", "une", "peu", "encore", "again", "trop", "too", "much", "more", "less", "plus", "moins", "pas", "assez", "enough", "bit", "little", "lot", "beaucoup", "way", "far", "fort", "forte", "stronger", "harder", "same", "pareil", "continue", "once", "one", "time", "fois", "de", "que", "that", "overdone", "excessif", "davantage", "legerement", "slightly", "tres", "very", "really", "vraiment", "petit", "chouia", "poil", "tad", "touch", "ok", "okay", "oui", "yes", "hmm", "euh", "encore", "idem", "recommence", "refais", "insuffisant", "strong", "a", "the", "this", "et", "and", "now", "maintenant", "please", "stp", "svp", "merci", "thanks"]

    /// A bare amount word after an adjustment refers to that adjustment.
    func parseFollowUp(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        guard let parameter = context.lastParameter else { return nil }
        let leftovers = u.tokens.filter { !Self.followUpFunctionWords.contains($0) && !ObjectVocabulary.fillerWords.contains($0) && Double($0) == nil && NumberWords.parse([$0], at: 0) == nil }
        guard leftovers.isEmpty else { return nil }
        let last = context.lastAdjustmentDirection == 0 ? 1 : context.lastAdjustmentDirection
        let tooMuch = u.contains(Self.followUpTooWords)
        let direction: Int
        if tooMuch {
            direction = -last
        } else if u.contains(Self.followUpNotEnoughWords) || u.contains(Self.followUpAgainWords) {
            direction = last
        } else {
            let sign = AmountParser.sign(in: u)
            guard sign != 0 else { return nil }
            direction = sign
        }
        let magnitude = AmountParser.magnitude(in: u)
        var step = tooMuch ? 0.12 : 0.15
        if magnitude.qualifier == .slight { step = 0.1 }
        if magnitude.qualifier == .strong { step = 0.3 }
        if let number = magnitude.explicitNumber { step = abs(number) }
        return EditIntent(action: .adjust, parameter: parameter, amount: .relative(step * Double(direction)), confidence: 0.85)
    }

    // MARK: - Object removal

    func parseRemoveObject(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        // "make him disappear" / "fais disparaître le chien" / "je ne veux plus voir la voiture"
        if u.contains(["disappear", "disparaitre", "vanish", "gone"]), let start = remainder(of: u, after: ["make", "fais", "fait", "faire", "rends"]) {
            let phrase = start.replacingOccurrences(of: " disappear", with: "").replacingOccurrences(of: "disparaitre ", with: "").replacingOccurrences(of: " vanish", with: "").replacingOccurrences(of: " gone", with: "")
            if let target = makeTarget(from: phrase, context: context) {
                return EditIntent(action: .removeObject, target: target, confidence: ObjectVocabulary.entry(forLabel: target.label) != nil ? 0.9 : 0.65)
            }
        }
        guard let rest = remainder(of: u, after: Self.removeVerbs) else {
            // "sans le chien" / "without the dog" / "je ne veux pas du chien"
            if let rest = remainder(of: u, after: ["sans", "without", "je ne veux pas", "je veux pas", "i don t want", "i do not want", "dont want", "don t want"]),
               let target = makeTarget(from: rest, context: context), target.label != "object" {
                return EditIntent(action: .removeObject, target: target, confidence: 0.75)
            }
            return nil
        }
        // "remove the text" on a document with text layers is a layer operation.
        if context.mode == .photo, context.textLayerCount > 0, NormalizedUtterance(rest).contains(["text", "texte", "title", "titre", "caption", "legende", "words", "mots"]) {
            return EditIntent(action: .removeText)
        }
        if context.mode == .video, NormalizedUtterance(rest).contains(["clip", "segment", "partie", "part", "passage", "scene", "sequence", "morceau", "bout", "beginning", "debut", "end", "fin", "son", "sound", "audio", "music", "musique", "transition", "transitions"]) {
            return nil
        }
        let restUtterance = NormalizedUtterance(rest)
        if restUtterance.contains(["filter", "filtre", "look", "effect", "effet", "vignette", "vignettage", "grain", "flou", "blur", "noise", "bruit", "modification", "modifications", "edits", "edit", "reglages", "adjustments", "crop", "recadrage", "layer", "calque", "zoom"]) {
            return nil
        }
        guard let target = makeTarget(from: rest, context: context) else {
            if u.contains(["ca", "cela", "this", "that", "it", "la", "ici", "here", "there"]) {
                return EditIntent(action: .removeObject, target: ObjectTarget(label: "object", originalPhrase: u.original, point: context.lastTapPoint), confidence: 0.6)
            }
            return nil
        }
        let known = ObjectVocabulary.entry(forLabel: target.label) != nil
        return EditIntent(action: .removeObject, target: target, confidence: known ? 0.92 : 0.65)
    }

    // MARK: - Auto enhance

    func parseAutoEnhance(_ u: NormalizedUtterance) -> EditIntent? {
        guard u.contains(["auto enhance", "auto", "automatique", "automatic", "enhance", "enhance it", "enhance the photo", "enhance the picture", "enhance the video", "ameliore", "ameliorer", "ameliore la photo", "ameliore l image", "ameliore la video", "improve", "improve it", "improve the photo", "fix it", "fix the photo", "fix the picture", "fix the lighting", "corrige", "corrige la photo", "corrige la lumiere", "corrige les couleurs", "fix the colors", "fix the colours", "magic", "magique", "baguette magique", "magic wand", "make it better", "make it look better", "make it nicer", "make it beautiful", "rends la plus belle", "rends la plus jolie", "embellis", "embellir", "optimise", "optimize", "optimise la photo", "retouche automatique", "auto retouch", "sublime", "sublimer", "one tap", "make it pop", "fais la briller", "rends la meilleure", "mets la en valeur", "arrange la photo", "arrange ca", "touch up", "touch it up", "retouche", "retoucher", "quick fix", "auto fix", "autofix", "smart enhance", "enhance colors", "enhance colours", "c est moche", "it looks bad", "looks bad", "ca rend mal", "pas terrible", "not great", "make it nice", "make it look nice", "make it look good", "fix this", "fix this photo", "repare la photo", "ameliore ca", "ameliore tout", "fais quelque chose", "do something", "do your magic", "fais ta magie", "surprise me", "surprends moi", "rends la belle", "make it better", "make this better", "fais mieux", "fais au mieux", "do your best", "help me with this photo", "aide moi avec cette photo", "c est pas top", "meh"]) else { return nil }
        let magnitude = AmountParser.magnitude(in: u)
        let strength: Double = magnitude.qualifier == .slight ? 0.5 : magnitude.qualifier == .strong ? 1.0 : 0.8
        return EditIntent(action: .autoEnhance, amount: .absolute(magnitude.explicitNumber ?? strength))
    }

    // MARK: - Look / filter

    static let lookKeywords: [String] = ["filter", "filtre", "look", "style", "preset", "effect", "effet", "ambiance", "mood", "vibe", "tone", "ton", "grade", "color grade", "colour grade", "etalonnage", "rendu"]
    static let strongLookPhrases: [String] = [
        "noir et blanc", "black and white", "black & white", "monochrome", "grayscale", "greyscale", "sepia", "sepia tone", "vintage", "retro", "cinematic", "cinematique", "cinema",
        "golden hour", "heure doree", "dramatic", "dramatique", "teal and orange", "teal orange", "teal & orange", "matte", "film noir", "argentique", "analog", "analogue",
        "pastel", "vivid", "eclatant", "silvertone", "hollywood", "blockbuster", "kodak", "fuji", "polaroid", "nostalgic", "nostalgique", "punchy", "35mm", "moody", "light and airy",
    ]

    func parseLook(_ u: NormalizedUtterance) -> EditIntent? {
        let hasKeyword = u.contains(Self.lookKeywords)
        let strong = u.firstMatch(Self.strongLookPhrases)
        guard hasKeyword || strong != nil else { return nil }
        if hasKeyword, u.contains(Self.removeVerbs) || u.contains(["no filter", "sans filtre", "aucun filtre", "remove the filter", "enleve le filtre", "reset the look", "original look"]) {
            return EditIntent(action: .applyLook, look: .original)
        }
        var preset: FilterPreset?
        if let strong {
            preset = strong == "sepia" || strong == "sepia tone" || strong == "polaroid" ? .vintage : (strong == "moody" ? .cinematic : FilterPreset.matching(strong))
        }
        if preset == nil {
            let candidate = remainder(of: u, after: Self.lookKeywords) ?? u.text
            let cleaned = candidate.split(separator: " ").filter { !ObjectVocabulary.fillerWords.contains(String($0)) && !["appelle", "called", "named", "nomme", "genre", "type", "style", "kind", "of"].contains(String($0)) }.joined(separator: " ")
            preset = FilterPreset.matching(cleaned) ?? FilterPreset.matching(u.text)
        }
        guard let resolved = preset else {
            return hasKeyword ? EditIntent(action: .applyLook, look: nil, confidence: 0.5) : nil
        }
        let magnitude = AmountParser.magnitude(in: u)
        var intensity = magnitude.explicitNumber ?? 1
        if magnitude.qualifier == .slight { intensity = 0.5 }
        if magnitude.qualifier == .strong { intensity = 1 }
        return EditIntent(action: .applyLook, amount: .absolute(intensity), look: resolved, confidence: 0.9)
    }

    // MARK: - Versions & description

    static let saveVersionPhrases = ["enregistre cette version", "sauvegarde cette version", "garde cette version", "conserve cette version", "enregistre la version", "sauvegarde la version", "nomme cette version", "appelle cette version", "marque cette version", "cree une version", "nouvelle version",
                                     "save this version", "save the version", "save version", "save a version", "name this version", "call this version", "bookmark this version", "snapshot", "create a version", "new version"]
    static let restoreVersionPhrases = ["reviens a la version", "retourne a la version", "restaure la version", "reprends la version", "charge la version", "remets la version", "recharge la version", "passe a la version", "montre la version", "ouvre la version",
                                        "go back to version", "go back to the version", "restore version", "restore the version", "load version", "load the version", "switch to version", "back to version", "show version", "open version", "revert to version"]

    /// "enregistre cette version sous brouillon" / "reviens à la version brouillon".
    func parseVersion(_ u: NormalizedUtterance, original: String) -> EditIntent? {
        let fillers: Set<String> = ["sous", "as", "comme", "nommee", "nommé", "named", "called", "appelee", "le", "la", "the", "nom", "name", "en", "in", "de", "of", "a", "to"]
        func name(after phrases: [String]) -> String {
            if let quoted = extractQuoted(from: original) { return quoted }
            var words = remainder(of: u, after: phrases)?.split(separator: " ").map(String.init) ?? []
            while let first = words.first, fillers.contains(first) { words.removeFirst() }
            let joined = words.joined(separator: " ")
            return originalSubstring(matching: joined, in: original) ?? joined
        }
        if u.contains(Self.restoreVersionPhrases) {
            let value = name(after: Self.restoreVersionPhrases)
            return EditIntent(action: .restoreVersion, text: value.isEmpty ? nil : value, confidence: value.isEmpty ? 0.6 : 1)
        }
        if u.contains(Self.saveVersionPhrases) {
            let value = name(after: Self.saveVersionPhrases)
            return EditIntent(action: .saveVersion, text: value.isEmpty ? nil : value)
        }
        return nil
    }

    /// "décris la photo", "qu'est-ce qu'il y a sur cette image", "what do you see".
    func parseDescribe(_ u: NormalizedUtterance) -> EditIntent? {
        let phrases = ["decris", "decris moi", "decrire", "description", "qu est ce qu il y a", "qu y a t il", "que vois tu", "qu est ce que tu vois", "tu vois quoi", "c est quoi cette photo", "c est quoi cette image", "qu est ce que c est", "raconte moi la photo", "analyse la photo", "analyse l image",
                       "describe", "what s in", "what is in", "what do you see", "what can you see", "what s this", "what is this", "what s on", "what is on", "tell me about", "analyse the photo", "analyze the photo", "analyze this", "analyse this"]
        guard u.contains(phrases), !u.contains(Self.removeVerbs) else { return nil }
        return EditIntent(action: .describe)
    }

    // MARK: - Crop

    func parseCrop(_ u: NormalizedUtterance) -> EditIntent? {
        let cropVerbs = ["crop", "recadre", "recadrer", "recadrage", "rogne", "rogner", "cadre", "cadrer", "coupe les bords", "trim the edges", "format", "ratio", "aspect", "aspect ratio", "resize to", "redimensionne en", "mets en format", "passe en format", "en format"]
        let hasVerb = u.contains(cropVerbs)
        let aspect = AspectPreset.matching(u.text)
        if hasVerb {
            if u.contains(["reset", "original", "d origine", "annule le recadrage", "remove the crop", "enleve le recadrage", "uncrop"]) {
                return EditIntent(action: .setAspect, aspect: .original)
            }
            var intent = EditIntent(action: .crop, aspect: aspect ?? .free)
            if let rest = remainder(of: u, after: ["crop to the", "crop on the", "crop around the", "recadre sur", "recadre autour de", "recadre autour du", "recadre sur le", "recadre sur la", "zoom on the", "crop to"]),
               aspect == nil, let target = makeTarget(from: rest, context: .photo), target.label != "object" {
                intent.target = target
            }
            if aspect == nil, intent.target == nil, !u.contains(["free", "libre", "manually", "manuellement"]) {
                intent.confidence = 0.7
            }
            return intent
        }
        if let aspect, aspect != .original, aspect != .free, u.contains(["square", "carre", "story", "stories", "reel", "reels", "tiktok", "instagram", "youtube", "widescreen", "cinemascope", "16 9", "9 16", "4 3", "3 4", "1 1", "16:9", "9:16", "4:3", "3:4", "1:1", "4:5", "4 5", "5:4", "21:9"]) {
            return EditIntent(action: .crop, aspect: aspect, confidence: 0.85)
        }
        return nil
    }

    // MARK: - Rotate / straighten / flip

    func parseGeometry(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        if u.contains(["straighten", "straighten it", "level", "level the horizon", "horizon", "redresse", "redresser", "redresse l horizon", "aligne l horizon", "mets droit", "mets la droite", "de niveau", "c est de travers", "it s crooked", "crooked", "tilted", "penche", "penchee", "de travers"]) {
            var intent = EditIntent(action: .straighten)
            if let number = NumberWords.firstNumber(in: u.tokens) {
                var degrees = number.value
                if u.contains(["left", "gauche", "anticlockwise", "counterclockwise", "counter clockwise", "anti horaire"]) { degrees = -degrees }
                intent.degrees = degrees
            }
            return intent
        }
        if context.mode == .video, u.contains(["reverse", "inverse", "backwards", "a l envers", "rewind", "marche arriere"]), !u.contains(["flip", "mirror", "miroir", "retourne"]) {
            return nil
        }
        if u.contains(["flip", "mirror", "miroir", "retourne", "retourner", "inverse", "inverser", "flip it", "mirror it", "en miroir", "symetrie", "symmetry"]) && !u.contains(["upside down", "a l envers", "tete en bas"]) {
            let axis: FlipAxis = u.contains(["vertical", "verticalement", "vertically", "upside", "haut en bas", "top to bottom"]) ? .vertical : .horizontal
            return EditIntent(action: .flip, flipAxis: axis)
        }
        if u.contains(["rotate", "turn", "tourne", "tourner", "pivote", "pivoter", "fais pivoter", "fais tourner", "rotation", "upside down", "a l envers", "tete en bas", "en paysage", "en portrait", "to landscape", "to portrait"]) {
            var degrees = 90.0
            if let number = NumberWords.firstNumber(in: u.tokens) { degrees = number.value }
            if u.contains(["upside down", "a l envers", "tete en bas", "180"]) { degrees = 180 }
            if u.contains(["left", "gauche", "anticlockwise", "counterclockwise", "counter clockwise", "anti horaire", "sens inverse", "sens antihoraire"]) { degrees = -abs(degrees) }
            if u.contains(["half", "demi", "quart de tour", "quarter turn"]) && NumberWords.firstNumber(in: u.tokens) == nil {
                degrees = u.contains(["half", "demi"]) ? 180 : 90
            }
            if u.contains(["en paysage", "to landscape", "en portrait", "to portrait"]) { degrees = 90 }
            return EditIntent(action: .rotate, degrees: degrees)
        }
        return nil
    }

    // MARK: - Text

    func parseText(_ u: NormalizedUtterance, original: String, context: IntentContext) -> EditIntent? {
        let addPhrases = ["add text", "add the text", "add a text", "add some text", "add a caption", "add caption", "add a title", "add title", "add the words", "add the word", "write", "put the text", "put text", "insert text", "insert the text", "type",
                          "ajoute le texte", "ajoute un texte", "ajoute du texte", "ajoute texte", "ajoute une legende", "ajoute la legende", "ajoute un titre", "ajoute le titre", "ajoutes le texte", "ecris", "ecrire", "mets le texte", "mets un texte", "mets le mot", "mets les mots", "insere le texte", "insere un texte", "marque", "note", "titre", "legende", "caption"]
        let editPhrases = ["change the text to", "change the text", "replace the text with", "replace the text by", "edit the text", "modifie le texte", "change le texte en", "change le texte", "remplace le texte par", "remplace le texte"]
        let mentionsText = u.contains(["text", "texte", "title", "titre", "caption", "legende", "words", "mots", "subtitle", "sous titre", "label", "heading"])
        if context.textLayerCount > 0, u.contains(editPhrases) {
            var intent = EditIntent(action: .editText)
            intent.text = extractQuoted(from: original) ?? remainder(of: u, after: editPhrases)?.replacingOccurrences(of: "^(en|par|to|with|by|into) ", with: "", options: .regularExpression)
            return intent
        }
        if context.textLayerCount > 0, mentionsText, u.contains(["bigger", "larger", "smaller", "plus grand", "plus gros", "plus petit", "in red", "in blue", "en rouge", "en bleu", "en blanc", "en noir", "in white", "in black", "move", "deplace", "center", "centre", "top", "bottom", "en haut", "en bas", "font", "police", "bold", "gras", "color", "couleur"]), !u.contains(addPhrases) {
            var intent = EditIntent(action: .editText)
            intent.placement = placement(in: u)
            intent.color = colorMention(in: u)
            if u.contains(["bigger", "larger", "plus grand", "plus gros", "grand", "big"]) { intent.amount = .multiplier(1.35) }
            if u.contains(["smaller", "plus petit", "petit", "small"]) { intent.amount = .multiplier(0.75) }
            return intent
        }
        guard u.contains(addPhrases) || (mentionsText && u.contains(["add", "ajoute", "mets", "put", "insert", "insere", "with", "avec", "saying", "disant", "qui dit"])) else { return nil }
        if u.contains(Self.removeVerbs) && !u.contains(["add", "ajoute"]) { return nil }
        var intent = EditIntent(action: .addText)
        var content = extractQuoted(from: original)
        if content == nil {
            // Take the words after the trigger phrase, dropping placement and styling words.
            let after = remainder(of: u, after: addPhrases + ["saying", "that says", "qui dit", "disant", "which says", "with the text", "avec le texte", "with the words", "avec les mots", "the text", "le texte", "text", "texte"])
            var words = after?.split(separator: " ").map(String.init) ?? []
            if words.first == "saying" || words.first == "disant" || words.first == "que" || words.first == "that" || words.first == "says" { words.removeFirst() }
            if words.first == "dit" { words.removeFirst() }
            for phrase in Self.placementPhrases.keys.sorted(by: { $0.count > $1.count }) { words = remove(phrase: phrase, from: words) }
            for phrase in ["in red", "in blue", "in white", "in black", "in yellow", "in green", "in pink", "in orange", "en rouge", "en bleu", "en blanc", "en noir", "en jaune", "en vert", "en rose", "en orange", "en gras", "in bold", "en grand", "in big", "big", "large", "small", "en petit", "petit", "grand", "gros"] {
                words = remove(phrase: phrase, from: words)
            }
            if words.first == "in" || words.first == "en" || words.first == "de" || words.first == "on" || words.first == "sur" { words.removeFirst() }
            if context.mode == .video { words = stripTimePhrases(from: words, frameRate: context.frameRate) }
            let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                // Recover original casing/accents by locating the phrase in the raw string when possible.
                content = originalSubstring(matching: joined, in: original) ?? joined
            }
        }
        intent.text = content
        intent.placement = placement(in: u) ?? .bottom
        intent.color = colorMention(in: u)
        if u.contains(["big", "large", "grand", "gros", "huge", "enorme", "en grand", "bigger"]) { intent.amount = .absolute(0.09) }
        if u.contains(["small", "petit", "tiny", "discret", "en petit"]) { intent.amount = .absolute(0.035) }
        if context.mode == .video {
            let times = TimeExpressions.allTimes(in: u.tokens, frameRate: context.frameRate)
            if u.contains(["from", "de", "entre", "between"]), times.count >= 2 {
                intent.timeRange = TimeSpan(start: times[0], end: times[1])
            } else if u.contains(["pendant", "for", "during", "durant"]), let duration = times.first {
                intent.timeRange = TimeSpan(start: context.playheadSeconds, duration: duration)
            } else if u.contains(["at", "a partir de", "starting at", "from"]), let start = times.first {
                intent.timeRange = TimeSpan(start: start, duration: 3)
            }
        }
        intent.confidence = content == nil ? 0.6 : 0.9
        return intent
    }

    /// Removes "pendant 3 secondes", "from 2 to 5 seconds", "à 10 secondes" from a text payload.
    func stripTimePhrases(from words: [String], frameRate: Double) -> [String] {
        let prepositions: Set<String> = ["pendant", "for", "during", "durant", "a", "at", "de", "from", "to", "jusqu", "entre", "between", "et", "and", "partir", "starting"]
        var result: [String] = []
        var index = 0
        while index < words.count {
            if TimeExpressions.parse(words, at: index, frameRate: frameRate) != nil || (NumberWords.parse(words, at: index) != nil && index + 1 < words.count && TimeExpressions.rangeConnectors.contains(words[index + 1]) && (index + 2 < words.count) && TimeExpressions.parse(words, at: index + 2, frameRate: frameRate) != nil) {
                while let last = result.last, prepositions.contains(last) { result.removeLast() }
                // Skip the whole time phrase.
                if let single = TimeExpressions.parse(words, at: index, frameRate: frameRate) {
                    index += single.consumed
                } else {
                    let bare = NumberWords.parse(words, at: index)!
                    let second = TimeExpressions.parse(words, at: index + 2, frameRate: frameRate)!
                    index += bare.consumed + 1 + second.consumed
                }
                continue
            }
            result.append(words[index])
            index += 1
        }
        return result
    }

    static let placementPhrases: [String: TextElement.Placement] = [
        "at the top": .top, "on top": .top, "top": .top, "en haut": .top, "dans le haut": .top, "at the bottom": .bottom, "bottom": .bottom, "en bas": .bottom,
        "dans le bas": .bottom, "in the middle": .center, "in the center": .center, "in the centre": .center, "centered": .center, "au centre": .center,
        "au milieu": .center, "centre": .center, "center": .center, "top left": .topLeading, "en haut a gauche": .topLeading, "top right": .topTrailing,
        "en haut a droite": .topTrailing, "bottom left": .bottomLeading, "en bas a gauche": .bottomLeading, "bottom right": .bottomTrailing,
        "en bas a droite": .bottomTrailing, "in the corner": .bottomTrailing, "dans le coin": .bottomTrailing,
    ]

    func placement(in u: NormalizedUtterance) -> TextElement.Placement? {
        guard let phrase = u.firstMatch(Array(Self.placementPhrases.keys)) else { return nil }
        return Self.placementPhrases[phrase]
    }

    func colorMention(in u: NormalizedUtterance) -> PSColor? {
        let twoWord = ["bleu clair", "bleu fonce", "vert clair", "vert fonce", "light blue", "dark blue", "light gray", "dark gray", "light green", "dark green", "rose clair", "light pink"]
        if let phrase = u.firstMatch(twoWord) { return PSColor.named(phrase) }
        for token in u.tokens {
            if let color = PSColor.named(token), token != "clear", token != "light", token != "rose" || u.contains(["en rose", "in pink"]) { return color }
        }
        return nil
    }

    func extractQuoted(from original: String) -> String? {
        let patterns = ["\"([^\"]+)\"", "“([^”]+)”", "«\\s*([^»]+?)\\s*»", "'([^']{2,})'"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
               let range = Range(match.range(at: 1), in: original) {
                return String(original[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Finds the span of the original string whose normalised form equals `normalizedPhrase`.
    func originalSubstring(matching normalizedPhrase: String, in original: String) -> String? {
        let words = original.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "!" || $0 == "?" || $0 == ":" }).map(String.init)
        let targetCount = normalizedPhrase.split(separator: " ").count
        guard words.count >= targetCount, targetCount > 0 else { return nil }
        for start in 0...(words.count - targetCount) {
            let slice = words[start..<(start + targetCount)].joined(separator: " ")
            if NormalizedUtterance.normalize(slice) == normalizedPhrase { return slice }
        }
        // Handle elisions ("l'été") where token counts differ.
        for start in 0..<words.count {
            for end in start..<words.count {
                let slice = words[start...end].joined(separator: " ")
                if NormalizedUtterance.normalize(slice) == normalizedPhrase { return slice }
            }
        }
        return nil
    }

    // MARK: - Resolution & detail operations

    func parseResolution(_ u: NormalizedUtterance) -> EditIntent? {
        if u.contains(["upscale", "upscaling", "super resolution", "increase the resolution", "increase resolution", "augmente la resolution", "augmenter la resolution", "plus de resolution", "higher resolution", "haute resolution", "en 4k", "in 4k", "4k", "agrandis l image", "agrandis la photo", "agrandir l image", "agrandis la", "double the size", "double la taille", "enlarge", "make it bigger", "rends la plus grande", "more pixels", "plus de pixels", "hd", "en hd", "upscale it"]) {
            var factor = 2.0
            if let number = NumberWords.firstNumber(in: u.tokens), number.value == 2 || number.value == 3 || number.value == 4 { factor = number.value }
            if u.contains(["4k"]) { factor = 2 }
            return EditIntent(action: .upscale, amount: .absolute(factor))
        }
        if u.contains(["relight", "re light", "reeclaire", "re eclaire", "eclaire le visage", "light the face", "add light", "ajoute de la lumiere", "studio light", "lumiere de studio", "portrait light", "portrait lighting", "eclairage portrait", "eclairage studio"]) {
            var direction = 0.0
            if u.contains(["left", "gauche"]) { direction = -1 }
            if u.contains(["right", "droite"]) { direction = 1 }
            return EditIntent(action: .relight, amount: .absolute(0.6), degrees: direction)
        }
        return nil
    }

    // MARK: - Layers (photo)

    func parseLayer(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        guard context.mode == .photo else { return nil }
        if u.contains(["select the layer", "select layer", "selectionne le calque", "selectionne la couche", "go to layer", "va au calque", "choose the layer", "choisis le calque", "select the text", "selectionne le texte", "select the photo", "selectionne la photo"]) {
            var intent = EditIntent(action: .selectLayer)
            if let number = NumberWords.firstNumber(in: u.tokens) { intent.index = Int(number.value) }
            for token in u.tokens { if let ordinal = NumberWords.ordinal(token) { intent.index = ordinal } }
            if u.contains(["text", "texte"]) { intent.text = "text" }
            if u.contains(["photo", "image", "picture", "base"]) { intent.text = "image" }
            return intent
        }
        if u.contains(["duplicate", "duplique", "dupliquer", "copy the layer", "copie le calque", "clone the layer"]) {
            return EditIntent(action: .duplicateLayer)
        }
        if u.contains(["delete the layer", "delete layer", "remove the layer", "remove layer", "supprime le calque", "efface le calque", "enleve le calque"]) {
            return EditIntent(action: .deleteLayer)
        }
        return nil
    }

    // MARK: - Adjustments

    func parseAdjust(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        guard let match = ParameterVocabulary.match(in: u) else {
            return nil
        }
        let parameter = match.parameter
        let outside = remove(phrase: match.matchedPhrase, from: u.tokens)
        let outsideUtterance = NormalizedUtterance(outside.joined(separator: " "))
        let magnitude = AmountParser.magnitude(in: outsideUtterance)
        let current = context.currentAdjustments[parameter]

        // Selective adjustments: "make the sky bluer", "éclaircis le visage", "blur the background" is handled earlier.
        var selectiveTarget: ObjectTarget?
        let nouns = outside.filter { !ObjectVocabulary.fillerWords.contains($0) && !AmountParser.slightWords.contains($0) && !AmountParser.strongWords.contains($0) }
        if let match = ObjectVocabulary.match(nouns.joined(separator: " ")), [.region, .person, .animal, .nature, .object, .vehicle, .furniture].contains(match.entry.category),
           !["object"].contains(match.entry.label), !u.contains(["photo", "image", "picture", "la photo", "l image", "the photo", "the picture", "whole", "entire", "toute"]) || match.entry.category == .region {
            selectiveTarget = ObjectTarget(label: match.entry.label, originalPhrase: match.matchedForm)
        }
        func finish(_ intent: EditIntent) -> EditIntent {
            guard let selectiveTarget else { return intent }
            var copy = intent
            copy.action = .selectiveAdjust
            copy.target = selectiveTarget
            return copy
        }

        // Reset.
        if outsideUtterance.contains(AmountParser.resetWords) {
            return EditIntent(action: .adjust, parameter: parameter, amount: .absolute(0))
        }
        if u.contains(Self.removeVerbs), !parameter.isBipolar, magnitude.explicitNumber == nil, magnitude.qualifier == nil {
            // "remove the vignette", "enlève le grain"
            return EditIntent(action: .adjust, parameter: parameter, amount: .absolute(0))
        }

        // Direction.
        var direction = match.impliedDirection
        let sign = AmountParser.sign(in: outsideUtterance)
        if sign != 0 {
            direction = direction == 0 ? sign : direction * sign
        }
        let tooMuch = outsideUtterance.contains(AmountParser.tooWords)
        if tooMuch {
            direction = direction == 0 ? -1 : (sign == 0 ? -direction : direction)
        }
        // "too much noise" / "less noise" ask for MORE noise reduction.
        if parameter == .noiseReduction, !match.matchedPhrase.contains("reduction"), !match.matchedPhrase.contains("denoise") {
            direction = 1
        }
        if direction == 0 { direction = 1 }

        // Maximum / minimum.
        if outsideUtterance.contains(AmountParser.maxWords) {
            let bound = direction >= 0 ? parameter.range.upperBound : parameter.range.lowerBound
            return finish(EditIntent(action: .adjust, parameter: parameter, amount: .absolute(bound)))
        }

        // Explicit number: absolute when preceded by "to"/"à"/"at"/"set", otherwise relative.
        if let number = magnitude.explicitNumber {
            let absolute = magnitude.isAbsolute || outsideUtterance.contains(AmountParser.setVerbs)
            if absolute {
                let signed = magnitude.hasExplicitNegative ? -abs(number) : (direction < 0 && !magnitude.hasExplicitPositive && sign == 0 && match.impliedDirection == 0 ? -abs(number) : number)
                return finish(EditIntent(action: .adjust, parameter: parameter, amount: .absolute(signed)))
            }
            let delta = abs(number) * Double(direction)
            return finish(EditIntent(action: .adjust, parameter: parameter, amount: .relative(magnitude.hasExplicitNegative ? -abs(number) : delta)))
        }

        var step = parameter.defaultStep + 0.05
        switch magnitude.qualifier {
        case .slight: step = 0.1
        case .strong: step = 0.4
        case .none: break
        }
        // Unipolar parameters at zero cannot go negative: nudge them up unless the user asked for less.
        if !parameter.isBipolar, direction < 0, current <= 0, selectiveTarget == nil {
            return EditIntent(action: .adjust, parameter: parameter, amount: .absolute(0), confidence: 0.8)
        }
        return finish(EditIntent(action: .adjust, parameter: parameter, amount: .relative(step * Double(direction))))
    }
}
