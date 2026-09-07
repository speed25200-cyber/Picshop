import Foundation
import PicshopCore

extension RuleBasedIntentEngine {
    static let pageWords: [String] = ["page", "pages", "feuille", "feuilles", "sheet", "sheets", "slide", "diapo"]

    /// PDF grammar. Runs after the meta commands.
    func parsePDF(_ u: NormalizedUtterance, original: String, context: IntentContext) -> [EditIntent] {
        let page = pageNumber(in: u, context: context)

        if u.contains(["next page", "page suivante", "suivante", "page d apres", "continue"]) {
            return [EditIntent(action: .goToPage, index: min(context.pageCount, context.currentPage + 1))]
        }
        if u.contains(["previous page", "page precedente", "precedente", "page d avant", "back a page", "reviens a la page precedente"]) {
            return [EditIntent(action: .goToPage, index: max(1, context.currentPage - 1))]
        }
        if u.contains(["first page", "premiere page", "au debut", "to the beginning", "start of the document", "debut du document"]) && !u.contains(Self.removeVerbs + ["move", "deplace", "rotate", "tourne"]) {
            return [EditIntent(action: .goToPage, index: 1)]
        }
        if u.contains(["last page", "derniere page", "a la fin", "to the end", "end of the document", "fin du document"]) && !u.contains(Self.removeVerbs + ["move", "deplace", "rotate", "tourne"]) {
            return [EditIntent(action: .goToPage, index: -1)]
        }
        if u.contains(["go to page", "va a la page", "vas a la page", "aller a la page", "ouvre la page", "open page", "montre la page", "show page", "show me page", "affiche la page", "jump to page", "page numero"]), let page {
            return [EditIntent(action: .goToPage, index: page)]
        }

        // Page management.
        if u.contains(Self.removeVerbs) || u.contains(["delete", "supprime", "retire", "enleve"]) {
            if u.contains(Self.pageWords) || u.contains(["this one", "celle ci", "celle la"]) {
                let scope: TargetScope = u.contains(["all", "toutes", "tous"]) ? .all : .current
                if let range = pageRange(in: u) {
                    return range.map { EditIntent(action: .deletePage, index: $0, scope: scope) }
                }
                return [EditIntent(action: .deletePage, index: page, scope: scope)]
            }
            if u.contains(["signature", "annotation", "annotations", "surlignage", "highlight", "highlights", "drawing", "dessin", "dessins", "markup", "markups", "text", "texte", "numeros", "numbers", "everything", "tout"]) {
                return [EditIntent(action: .removeText, text: u.contains(["everything", "tout", "all", "toutes", "tous"]) ? "all" : nil)]
            }
        }
        if u.contains(["rotate", "tourne", "tourner", "pivote", "pivoter", "fais pivoter", "turn", "en paysage", "en portrait", "to landscape", "to portrait", "a l envers", "upside down"]) {
            var degrees = 90.0
            if let number = NumberWords.firstNumber(in: u.tokens.filter { !$0.hasPrefix("page") }), [90, 180, 270].contains(number.value) { degrees = number.value }
            if u.contains(["left", "gauche", "anticlockwise", "counterclockwise", "counter clockwise", "anti horaire"]) { degrees = -degrees }
            if u.contains(["a l envers", "upside down", "180"]) { degrees = 180 }
            let scope: TargetScope = u.contains(["all", "toutes les pages", "tout le document", "every page", "whole document", "the document"]) ? .all : .current
            return [EditIntent(action: .rotatePage, degrees: degrees, index: page, scope: scope)]
        }
        if u.contains(["move", "deplace", "deplacer", "bouge", "mets la page", "put page", "put the page", "place la page", "reorder", "swap"]) && u.contains(Self.pageWords) {
            var intent = EditIntent(action: .movePage, index: page)
            var destination: Int?
            if u.contains(["beginning", "start", "debut", "first", "en premier", "au debut"]) { destination = 1 }
            if u.contains(["end", "fin", "last", "en dernier", "a la fin"]) { destination = -1 }
            if let rest = remainder(of: u, after: ["to position", "en position", "at position", "after page", "apres la page", "before page", "avant la page", "to page", "a la page", "en", "to", "vers"]),
               let number = NumberWords.firstNumber(in: rest.split(separator: " ").map(String.init)) {
                var value = Int(number.value)
                if u.contains(["after page", "apres la page"]) { value += 1 }
                destination = value
            }
            intent.clipIndex = destination
            return [intent]
        }
        if u.contains(["duplicate", "duplique", "dupliquer", "copy the page", "copie la page", "copy this page", "double la page"]) {
            return [EditIntent(action: .duplicatePage, index: page)]
        }
        if u.contains(["blank page", "page blanche", "page vide", "empty page", "new page", "nouvelle page", "insert a page", "insere une page", "ajoute une page", "add a page"]) {
            var intent = EditIntent(action: .insertBlankPage, index: page)
            if u.contains(["after", "apres"]) { intent.scope = .selection }
            if u.contains(["at the end", "a la fin", "en dernier"]) { intent.index = -1; intent.scope = .selection }
            return [intent]
        }
        if u.contains(["page number", "page numbers", "numeros de page", "numero de page", "numerote", "numeroter", "pagination", "paginate", "number the pages"]) {
            return [EditIntent(action: .addPageNumbers)]
        }
        if u.contains(["merge", "fusionne", "fusionner", "combine", "assemble", "join with", "append", "ajoute un autre pdf", "add another pdf", "attach"]) {
            return [EditIntent(action: .mergeDocument)]
        }
        if u.contains(["signature", "signe", "signer", "sign here", "sign the", "sign this", "sign it", "ma signature", "my signature"]) {
            var intent = EditIntent(action: .addSignature, index: page)
            intent.placement = placement(in: u) ?? .bottomTrailing
            return [intent]
        }
        if u.contains(["extract", "extrais", "extraire", "exporte la page", "export the page", "export this page", "save the page as", "enregistre la page", "en photo", "as a photo", "as an image", "en image", "to photos", "dans photos", "make it a photo", "convert the page", "convertis la page"]) {
            return [EditIntent(action: .extractPage, index: page)]
        }

        // Text markup: highlight / underline / redact / find.
        let quoted = extractQuoted(from: original)
        let markupVerbs: [(String, [String])] = [
            ("highlight", ["highlight", "surligne", "surligner", "surlignes", "mark", "marque en jaune", "en jaune"]),
            ("underline", ["underline", "souligne", "souligner"]),
            ("strike", ["strike", "strikethrough", "cross out", "barre", "barrer", "raye", "rayer"]),
            ("redact", ["redact", "caviarde", "caviarder", "censure", "censurer", "black out", "masque", "hide"]),
            ("find", ["find", "search", "cherche", "chercher", "recherche", "trouve", "trouver", "look for", "where is", "ou est"]),
        ]
        for (kind, verbs) in markupVerbs where u.contains(verbs) {
            var query = quoted
            if query == nil, let rest = remainder(of: u, after: verbs) {
                var words = rest.split(separator: " ").map(String.init)
                words = words.filter { !["the", "word", "words", "le", "la", "les", "mot", "mots", "phrase", "sentence", "texte", "text", "en", "jaune", "yellow", "in", "on", "sur", "cette", "this", "page", "tous", "toutes", "all", "every", "chaque", "occurrences", "occurrence", "for", "pour"].contains($0) }
                let joined = words.joined(separator: " ")
                if !joined.isEmpty { query = originalSubstring(matching: joined, in: original) ?? joined }
            }
            guard let query, !query.isEmpty else {
                if kind == "highlight" || kind == "underline" { return [EditIntent(action: kind == "highlight" ? .highlightText : .underlineText, text: nil, confidence: 0.6)] }
                continue
            }
            let scope: TargetScope = u.contains(["everywhere", "partout", "all", "toutes", "tous", "every", "chaque", "whole document", "tout le document"]) ? .all : .current
            let colorMention = colorMention(in: u)
            switch kind {
            case "highlight": return [EditIntent(action: .highlightText, text: query, color: colorMention, scope: scope)]
            case "underline": return [EditIntent(action: .underlineText, text: query, color: colorMention, scope: scope)]
            case "strike": return [EditIntent(action: .underlineText, text: query, color: colorMention ?? .red, scope: scope, confidence: 0.85)]
            case "redact": return [EditIntent(action: .redactText, text: query, scope: scope)]
            default: return [EditIntent(action: .findText, text: query)]
            }
        }

        // Text on the page.
        if let text = parseText(u, original: original, context: context) { return [text] }
        if u.contains(["draw", "dessine", "annoter", "annotate", "pen", "stylo", "crayon", "marker"]) {
            return [EditIntent(action: .help, text: "draw")]
        }
        return [EditIntent(action: .unknown, confidence: 0)]
    }

    /// "page 3", "la troisième page", "cette page" → 1-based page number (nil = current).
    func pageNumber(in u: NormalizedUtterance, context: IntentContext) -> Int? {
        for token in u.tokens {
            if let ordinal = NumberWords.ordinal(token) { return ordinal }
        }
        for word in Self.pageWords {
            if let index = u.tokenIndex(of: word), index + 1 < u.tokens.count, let number = NumberWords.parse(u.tokens, at: index + 1), number.value >= 1 {
                return Int(number.value)
            }
        }
        if u.contains(["last page", "derniere page"]) { return -1 }
        return nil
    }

    /// "pages 2 à 5" / "pages 2 to 5" → [2, 3, 4, 5] (deleted from the end first by the executor).
    func pageRange(in u: NormalizedUtterance) -> [Int]? {
        guard let index = u.tokenIndex(of: "pages") else { return nil }
        let rest = Array(u.tokens[(index + 1)...])
        guard let first = NumberWords.parse(rest, at: 0), first.consumed < rest.count, ["a", "to", "et", "and", "jusqu", "-"].contains(rest[first.consumed]) else { return nil }
        var cursor = first.consumed + 1
        if cursor < rest.count, rest[cursor] == "a" { cursor += 1 }
        guard cursor < rest.count, let second = NumberWords.parse(rest, at: cursor), second.value >= first.value else {
            // "pages 2 et 5" → two pages.
            if let second = NumberWords.parse(rest, at: first.consumed + 1) { return [Int(first.value), Int(second.value)] }
            return nil
        }
        if rest[first.consumed] == "et" || rest[first.consumed] == "and" {
            return [Int(first.value), Int(second.value)]
        }
        return Array(Int(first.value)...Int(second.value))
    }
}
