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
        if u.contains(["last page", "derniere page", "a la fin", "to the end", "end of the document", "fin du document"]) && !u.contains(Self.removeVerbs + ["move", "deplace", "rotate", "tourne", "envoie", "ajoute", "add", "insere", "insert", "vide", "blank", "blanche", "nouvelle", "new"]) {
            return [EditIntent(action: .goToPage, index: -1)]
        }
        // "page 7" on its own.
        if let page, u.tokens.count <= 3, let first = u.tokens.first,
           Self.pageWords.contains(first) || ["la", "le", "the", "a", "to"].contains(first), !u.contains(Self.removeVerbs) {
            return [EditIntent(action: .goToPage, index: page)]
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
            if u.contains(["signature", "annotation", "annotations", "surlignage", "surlignages", "highlight", "highlights", "drawing", "dessin", "dessins", "markup", "markups", "text", "texte", "numeros", "numbers", "everything", "tout", "trait", "image", "photo"]) {
                let kind: String? = u.contains(["everything", "tout", "all", "toutes", "tous"]) ? "all"
                    : u.contains(["signature"]) ? "signature"
                    : u.contains(["surlignage", "surlignages", "highlight", "highlights"]) ? "highlight"
                    : u.contains(["drawing", "dessin", "dessins", "trait"]) ? "ink"
                    : u.contains(["text", "texte"]) ? "text"
                    : u.contains(["image", "photo"]) ? "image"
                    : u.contains(["numeros", "numbers"]) ? "pageNumber" : nil
                return [EditIntent(action: .removeText, text: kind)]
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
        if u.contains(["move", "deplace", "deplacer", "bouge", "mets la page", "put page", "put the page", "place la page", "reorder", "swap", "envoie", "send"]) && u.contains(Self.pageWords) {
            var intent = EditIntent(action: .movePage, index: page)
            var destination: Int?
            if u.contains(["beginning", "start", "debut", "first", "en premier", "au debut"]) { destination = 1 }
            if u.contains(["end", "fin", "last", "en dernier", "a la fin"]) { destination = -1 }
            if destination == nil, let rest = remainder(of: u, after: ["to position", "en position", "at position", "after page", "apres la page", "before page", "avant la page", "to page", "a la page", "en", "to", "vers"]),
               let number = NumberWords.firstNumber(in: rest.split(separator: " ").map(String.init)) {
                var value = Int(number.value)
                let source = page ?? context.currentPage
                if u.contains(["after page", "apres la page"]), source > value { value += 1 }
                if u.contains(["before page", "avant la page"]), source < value { value -= 1 }
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
        if u.contains(["insere une photo", "insere une image", "ajoute une photo", "ajoute une image", "insert a photo", "insert an image", "add a photo", "add a picture", "add an image", "mets une photo", "put a photo"]) {
            return [EditIntent(action: .mergeDocument, text: "image")]
        }
        let findVerbs = ["find", "search", "cherche", "chercher", "recherche", "trouve", "trouver", "look for", "where is", "ou est"]
        if u.contains(["signature", "signe", "signer", "sign here", "sign the", "sign this", "sign it", "ma signature", "my signature"]) && !u.contains(findVerbs) {
            var intent = EditIntent(action: .addSignature, index: page)
            intent.placement = placement(in: u) ?? .bottomTrailing
            return [intent]
        }
        if u.contains(["extract", "extrais", "extraire", "exporte la page", "export the page", "export this page", "save the page as", "enregistre la page", "en photo", "as a photo", "as an image", "en image", "to photos", "dans photos", "make it a photo", "convert the page", "convertis la page"]) {
            return [EditIntent(action: .extractPage, index: page)]
        }

        // Replace words: "remplace monsieur par madame", "change X en Y", "replace X with Y".
        if let replacement = parseReplacement(u, original: original) { return [replacement] }
        // Erase words: "efface le mot monsieur", "supprime « total » partout", "remove the word draft".
        if let erase = parseEraseWords(u, original: original) { return [erase] }

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
                words = words.filter { !["the", "word", "words", "le", "la", "les", "mot", "mots", "phrase", "sentence", "texte", "text", "en", "jaune", "yellow", "in", "on", "sur", "cette", "this", "page", "tous", "toutes", "all", "every", "chaque", "occurrences", "occurrence", "for", "pour", "partout", "everywhere", "and", "et"].contains($0) && PSColor.named($0) == nil }
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

    // MARK: Replace text

    static let replaceTextVerbs = ["remplace", "remplacer", "remplaces", "replace", "substitue", "substituer", "change", "changer", "changes", "modifie", "modifier", "swap", "corrige", "corriger", "renomme", "rename"]

    /// "remplace X par Y" → replaceText(text: X, replacement: Y). Quotes win; otherwise
    /// the words after the verb are split on the first connector (par / with / by / en / to).
    func parseReplacement(_ u: NormalizedUtterance, original: String) -> EditIntent? {
        guard u.contains(Self.replaceTextVerbs) else { return nil }
        var from: String?
        var to: String?
        let quoted = allQuoted(from: original)
        if quoted.count >= 2 {
            from = quoted[0]
            to = quoted[1]
        } else if let rest = remainder(of: u, after: Self.replaceTextVerbs) {
            let padded = " " + rest + " "
            let connectors = [" par ", " with ", " by ", " en ", " into ", " to ", " avec ", " pour ", " contre "]
            var best: (Range<String.Index>, String)?
            for connector in connectors {
                if let range = padded.range(of: connector), best == nil || range.lowerBound < best!.0.lowerBound { best = (range, connector) }
            }
            guard let (range, _) = best else { return nil }
            let fillers: Set<String> = ["le", "la", "les", "l", "the", "mot", "mots", "word", "words", "texte", "text", "terme", "term", "toutes", "tous", "all", "every", "chaque", "occurrences", "occurrence", "de", "of", "du", "des", "partout", "everywhere", "dans", "in", "ce", "cette", "this", "document", "pdf", "sur", "on", "page", "cette page"]
            func clean(_ slice: Substring) -> String {
                var words = slice.split(separator: " ").map(String.init)
                while let first = words.first, fillers.contains(first) { words.removeFirst() }
                while let last = words.last, fillers.contains(last) { words.removeLast() }
                return words.joined(separator: " ")
            }
            let a = clean(padded[..<range.lowerBound])
            let b = clean(padded[range.upperBound...])
            guard !a.isEmpty, !b.isEmpty else { return nil }
            from = originalSubstring(matching: a, in: original) ?? a
            to = originalSubstring(matching: b, in: original) ?? b
            if quoted.count == 1 {
                // One quoted phrase: it is whichever side it matches.
                if u.remainder(after: Self.replaceTextVerbs)?.hasPrefix(NormalizedUtterance.normalize(quoted[0])) == true { from = quoted[0] } else { to = quoted[0] }
            }
        }
        guard let from, let to, !from.isEmpty, !to.isEmpty, from.lowercased() != to.lowercased() else { return nil }
        // "change la page en paysage" and friends belong to other rules.
        if Self.pageWords.contains(where: { from.lowercased().split(separator: " ").map(String.init).contains($0) }) { return nil }
        let scope: TargetScope = u.contains(["everywhere", "partout", "all", "toutes", "tous", "every", "chaque", "whole document", "tout le document", "dans tout"]) ? .all : .current
        return EditIntent(action: .replaceText, text: from, scope: scope, replacement: to)
    }

    /// "efface le mot X" → replaceText(text: X, replacement: "") which covers the words.
    func parseEraseWords(_ u: NormalizedUtterance, original: String) -> EditIntent? {
        let verbs = ["efface", "effacer", "supprime", "supprimer", "enleve", "enlever", "retire", "retirer", "gomme", "gommer", "erase", "remove", "delete", "wipe"]
        guard u.contains(verbs), !u.contains(Self.pageWords), !u.contains(["signature", "image", "photo", "dessin", "drawing", "surlignage", "highlight", "annotation", "tout", "everything", "all the"]) else { return nil }
        var target = extractQuoted(from: original)
        if target == nil, let rest = remainder(of: u, after: verbs) {
            let fillers: Set<String> = ["le", "la", "les", "l", "the", "mot", "mots", "word", "words", "texte", "text", "terme", "term", "toutes", "tous", "all", "every", "chaque", "occurrences", "occurrence", "de", "of", "du", "des", "partout", "everywhere", "dans", "in", "ce", "cette", "this", "document", "pdf", "sur", "on"]
            var words = rest.split(separator: " ").map(String.init)
            let mentionsWord = words.contains { ["mot", "mots", "word", "words", "texte", "text", "terme", "term"].contains($0) }
            while let first = words.first, fillers.contains(first) { words.removeFirst() }
            while let last = words.last, fillers.contains(last) { words.removeLast() }
            // Without "the word …" or quotes, a bare "efface X" is ambiguous; require the marker.
            guard mentionsWord, !words.isEmpty else { return nil }
            let joined = words.joined(separator: " ")
            target = originalSubstring(matching: joined, in: original) ?? joined
        }
        guard let target, !target.isEmpty else { return nil }
        let scope: TargetScope = u.contains(["everywhere", "partout", "all", "toutes", "tous", "every", "chaque", "whole document", "tout le document"]) ? .all : .current
        return EditIntent(action: .replaceText, text: target, scope: scope, replacement: "")
    }

    /// Every quoted phrase, in order of appearance.
    func allQuoted(from original: String) -> [String] {
        let pattern = "\"([^\"]+)\"|“([^”]+)”|«\\s*([^»]+?)\\s*»|'([^']{2,})'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: original, range: NSRange(original.startIndex..., in: original)).compactMap { match in
            for group in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: original) { return String(original[range]).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        }
    }
}
