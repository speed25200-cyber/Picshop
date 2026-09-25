import Foundation
import PicshopCore

// The table grammar (FR/EN, contract §10): fill, clear and highlight cells, with scopes, values,
// alternatives, style words, relative references ("la case à droite") and follow-ups ("les autres
// aussi", "pareil pour la colonne Gemini"). It reads the whole utterance before UtteranceSegmenter,
// whose " et " split would break "entre 50 et 90"; a second command after "et"/"puis" ("… et surligne-la")
// is split off by `parse` only where a verb starts it.

extension RuleBasedIntentEngine {
    enum TableVerb { case fill, clear, highlight }

    // MARK: Vocabulary

    static let tableFillVerbs: Set<String> = [
        "remplis", "remplir", "remplisse", "remplissez", "complete", "completer", "completes", "completez", "mets", "met", "mettre", "mettez",
        "ecris", "ecrire", "ecrit", "ecrivez", "ajoute", "ajouter", "ajoutes", "ajoutez", "inscris", "inscrire", "saisis", "saisir", "tape", "taper",
        "place", "placer", "numerote", "numeroter", "remplace", "remplacer", "fill", "put", "write", "enter", "type", "add", "set", "populate",
        "replace", "number", "insert", "insere", "inserer", "remets", "remettre", "reecris", "rewrite", "rajoute", "rajouter", "rajoutes",
    ]
    static let tableClearVerbs: Set<String> = [
        "vide", "vider", "videz", "efface", "effacer", "effacez", "enleve", "enlever", "enlevez", "supprime", "supprimer", "supprimez", "retire",
        "retirer", "clear", "empty", "erase", "remove", "delete", "wipe",
    ]
    static let tableHighlightVerbs: Set<String> = [
        "surligne", "surligner", "surlignes", "surlignez", "colore", "colorer", "colorie", "colorier", "encadre", "encadrer", "entoure", "entourer",
        "highlight", "shade", "outline",
    ]
    static let tableHighlightPhrases = ["mets en evidence", "met en evidence", "mettre en evidence", "mets en valeur", "met en valeur", "mettre en valeur",
                                        "fais ressortir", "fait ressortir", "make it stand out", "make stand out"]
    /// Nouns that only a table has.
    static let strongTableNouns: Set<String> = ["cellule", "cellules", "cell", "cells", "tableau", "tableaux", "colonne", "colonnes", "column", "columns", "grille",
                                                "grid", "grids", "spreadsheet"]
    /// "suivante", "à droite": a place relative to the last edit, not a name.
    static let relativeWords: Set<String> = ["suivante", "suivant", "precedente", "precedent", "next", "previous", "d", "apres", "avant", "droite", "gauche",
                                             "dessous", "dessus", "right", "left", "below", "above", "same", "meme"]
    static let caseNouns: Set<String> = ["case", "cases"]
    static let lineNouns: Set<String> = ["ligne", "lignes", "rangee", "rangees", "row", "rows"]
    static let columnCues: Set<String> = ["colonne", "colonnes", "column", "columns", "col"]
    static let cellCues: Set<String> = ["case", "cases", "cellule", "cellules", "cell", "cells"]
    /// Words that end a name ("la colonne Opus 5 avec des 1").
    static let hardStops: Set<String> = ["avec", "par", "with", "by", "et", "ou", "and", "or", "puis", "then", "ensuite", "aussi", "too", "also", "stp", "svp",
                                         "please", "entre", "between", "comme", "like", "sauf", "except"]
    static let softStops: Set<String> = ["en", "sur", "pour", "sous", "dans", "a", "au", "aux", "de", "du", "des", "to", "in", "on", "for", "under", "at",
                                         "into", "of", "from", "the", "la", "le", "les", "l"]
    static let particles: Set<String> = ["de", "du", "des", "d", "of", "the", "la", "le", "les", "l", "nommee", "appelee", "named", "called", "intitulee"]
    /// "Les autres (cases)", "the rest": a follow-up that names its new scope.
    static let followUpScopeWords = ["les autres", "les autres cases", "le reste", "the others", "the rest", "the other cells", "the remaining", "les restantes",
                                     "celles qui manquent", "celles qui restent", "ceux qui restent", "remaining cells", "cases restantes", "the other ones"]
    /// "Pareil", "aussi", "same": a follow-up only when nothing else is said but where.
    static let followUpSameWords = ["aussi", "egalement", "too", "as well", "also", "pareil", "la meme chose", "de meme", "idem", "same", "same thing",
                                    "likewise", "the same", "meme chose"]
    /// Words a "same again" follow-up may hold besides the scope ("pareil pour la colonne Gemini").
    static let followUpFiller: Set<String> = ["pareil", "la", "le", "les", "l", "meme", "chose", "de", "du", "des", "pour", "sur", "dans", "a", "aussi",
                                              "egalement", "idem", "et", "fais", "fait", "faire", "same", "for", "the", "too", "also", "as", "well", "do",
                                              "likewise", "thing", "in", "on", "please", "stp", "svp", "maintenant", "now", "ok", "alors", "puis", "then",
                                              "il", "faut", "tu", "peux", "can", "you", "cases", "case", "cellules", "cells", "remplir", "remplis", "fill",
                                              "it", "them", "autres", "others", "other", "reste", "rest", "vides", "empty", "toutes", "tous", "all"]
    static let rerollWords = ["encore", "again", "d autres", "autres chiffres", "autres nombres", "autres valeurs", "other numbers", "other values",
                              "new numbers", "nouveaux chiffres", "nouvelles valeurs", "relance", "re roll", "reroll", "reshuffle", "melange"]
    static let overwriteWords = ["a la place", "instead", "remplace", "remplacer", "replace", "ecrase", "ecraser", "overwrite", "meme celles", "meme les",
                                 "even the", "change les", "change the", "tout remplacer", "par dessus"]
    static let emptyScopeWords = ["vides", "vide", "empty", "blank", "restantes", "restants", "remaining", "les autres", "le reste", "the rest", "the others",
                                  "other cells", "celles qui manquent", "les trous", "the gaps", "manquantes", "missing"]
    static let randomWords = ["aleatoire", "aleatoires", "aleatoirement", "hasard", "random", "randomly", "au pif", "n importe quel", "n importe quels",
                              "n importe quelles", "quelconques", "any numbers"]
    static let plausibleWords = ["realiste", "realistes", "credible", "credibles", "plausible", "plausibles", "vraisemblable", "vraisemblables",
                                 "realistic", "believable"]
    static let sequenceWords = ["numerote", "numeroter", "numerotes", "numerotez", "dans l ordre", "in order", "sequence", "suite", "croissant",
                                "croissants", "increasing", "number the", "count up", "1 2 3"]

    // MARK: Entry points

    /// On the whole utterance, before UtteranceSegmenter. Nil when the utterance is not a table command.
    func parseTable(_ u: NormalizedUtterance, original: String, context: IntentContext) -> EditIntent? {
        let tokens = u.tokens
        guard !tokens.isEmpty, context.mode == .photo, !Self.isQuestion(u, original: original), !Self.textAboutTheTable(u) else { return nil }
        let grid = context.table
        let english = u.language == .english
        let found = Self.tableVerb(in: u)
        let lastIsTable = context.lastIntent.map { IntentNormalizer.tableActions.contains($0.action) } ?? (context.lastTableEdit != nil)
        let hasLayerCells = grid?.dataCells.contains { $0.state == .layer } ?? false
        let reroll = found == nil && lastIsTable && u.contains(Self.rerollWords) && Self.isRandomish(context.lastTableEdit?.value)
            && tokens.count <= 8

        // Evidence that the words are about a table.
        let tokenSet = Self.tableWords(u)
        let inCase = u.contains(["in case", "just in case", "en cas", "au cas"])
        let saysCase = !english && !inCase && !tokenSet.isDisjoint(with: Self.caseNouns)
        let strong = !tokenSet.isDisjoint(with: Self.strongTableNouns) || saysCase || (grid != nil && Self.saysTheTable(tokens))
            || (grid != nil && u.contains(["partout", "everywhere", "dans tout", "all over", "de partout"]))
            || (grid != nil && Self.saysEverything(u) && Self.tableValues(u, original: original, consumed: [], verb: nil).value != nil)
        let saysLine = !tokenSet.isDisjoint(with: Self.lineNouns) && !u.contains(["ligne d horizon", "horizon", "ligne de texte", "line of text", "row of trees"])
        var consumed = Set<Int>()
        var spec = TableEditSpec()
        // One cell by where it sits: "la case en bas à droite", "la première case", "the last cell" (no row or column said).
        let oneCell = Self.namesOneCellNoun(u)
        let position = oneCell && tokenSet.isDisjoint(with: Self.lineNouns.union(Self.columnCues)) ? Self.cellPosition(u, consumed: &consumed) : nil
        // Next to a name: "la case à droite de Opus 5.5", "la colonne juste avant GPT-6 Astra".
        let neighbours = grid.map { Self.neighbourRefs(u, grid: $0, consumed: &consumed) } ?? []
        let refs = Self.tableRefs(u, grid: grid, consumed: &consumed, english: english, lineCues: saysLine, original: original)
        spec.rows = neighbours.filter { $0.axis == .row }.map(\.ref) + refs.rows.filter { ref in !neighbours.contains { $0.axis == .row && $0.ref == ref } }
        spec.columns = neighbours.filter { $0.axis == .column }.map(\.ref) + refs.columns.filter { ref in !neighbours.contains { $0.axis == .column && $0.ref == ref } }
        if let position {
            if spec.rows.isEmpty { spec.rows = [position.row] }
            if spec.columns.isEmpty { spec.columns = [position.column] }
        }
        let named = !spec.rows.isEmpty || !spec.columns.isEmpty
        let relative = position == nil && neighbours.isEmpty ? Self.relativeRefs(u, last: context.lastTableEdit, grid: grid) : nil
        if let relative {
            if spec.rows.isEmpty { spec.rows = relative.rows }
            if spec.columns.isEmpty { spec.columns = relative.columns }
        }
        let leftover = tokens.indices.filter { !consumed.contains($0) }.map { tokens[$0] }
        let sameAgain = u.contains(Self.followUpSameWords) && leftover.allSatisfy { Self.followUpFiller.contains($0) || Self.lineNouns.contains($0) || Self.columnCues.contains($0) }
        // "encore pour Gemini 3.5 Pro", "again in the second column": the last table step on a new scope.
        let againElsewhere = found == nil && lastIsTable && named && u.contains(["encore", "again", "de nouveau", "une fois de plus", "once more"])
        // "non, plutôt des chiffres au hasard", "rather random numbers": the last cells, another value.
        let rather = lastIsTable && u.contains(Self.ratherWords)
        // "en gras", "en rouge", "plus gros" after a fill: the cells written, restyled.
        let restyle = lastIsTable && (context.lastTableEdit != nil || hasLayerCells) && Self.isStyleOnly(leftover) && !u.contains(Self.lookPhrases)
        // "et la case à droite ?", "remplace les 1 par des chiffres aléatoires": about the last table edit.
        let placed = relative != nil || !neighbours.isEmpty || position != nil
        let aboutLast = lastIsTable && (placed || u.contains(Self.overwriteWords) || rather)
        let followUp = (u.contains(Self.followUpScopeWords) || sameAgain || aboutLast || againElsewhere || restyle) && (context.lastTableEdit != nil || hasLayerCells)

        // "random numbers with one decimal between 50 and 90 in the Opus 5.5 column": no verb, but a scope the
        // table has and values that only cells take (random, plausible, a sequence).
        let verbless: Bool = {
            guard found == nil, !followUp, !reroll, grid != nil, named, !tokenSet.isDisjoint(with: Self.strongTableNouns.union(Self.lineNouns)) else { return false }
            switch Self.tableValues(u, original: original, consumed: consumed, verb: nil).value {
            case .random?, .plausible?, .sequence?: return true
            default: return false
            }
        }()
        guard found != nil || followUp || reroll || verbless else { return nil }
        // A follow-up with no verb does what the last table step did ("pareil pour Opus 5" after a highlight).
        let lastVerb: TableVerb? = {
            switch context.lastIntent?.action {
            case .highlightCells?: return .highlight
            case .clearCells?: return .clear
            case .fillCells?: return .fill
            default: return nil
            }
        }()
        let verb = found?.verb ?? (restyle ? .fill : lastVerb ?? .fill)
        switch verb {
        case .fill:
            guard strong || followUp || reroll || (saysLine && (grid != nil || named)) || (grid != nil && named) else { return nil }
        case .clear:
            // "supprime toutes les données du tableau" stays an erase of what is printed.
            let parts = !tokenSet.isDisjoint(with: Self.cellCues.union(Self.columnCues)) || (saysLine && !tokenSet.isDisjoint(with: Self.lineNouns))
                || u.contains(["contenu", "content", "contents"])
            let emptiesTable = u.contains(["vide", "vider", "videz", "clear", "empty"]) && (strong || grid != nil)
            guard (parts && (strong || saysLine || grid != nil)) || emptiesTable || (grid != nil && named) || (followUp && found == nil) else { return nil }
            guard !u.contains(["donnees", "data", "chiffres", "numbers", "valeurs", "values"]) || parts else { return nil }
        case .highlight:
            guard strong || saysLine || (grid != nil && named) || (followUp && found == nil) else { return nil }
        }

        // Where: the whole table unless named; empty cells only unless told to write over.
        if u.contains(Self.overwriteWords) || rather || (reroll && !u.contains(Self.emptyScopeWords)) { spec.onlyEmpty = false }
        if reroll || rather || restyle, let last = context.lastTableEdit, !named {
            spec.rows = last.rows
            spec.columns = last.columns
        }
        if u.contains(Self.emptyScopeWords) { spec.onlyEmpty = true }
        // "mets des 0 dans la colonne Fable 5.1" over the 1s written there before: a named scope with no empty cell
        // left and Picshop's own values in it is written over (printed values stay protected by the executor).
        if verb == .fill, spec.onlyEmpty, named, found != nil, !u.contains(Self.emptyScopeWords), let grid,
           let scope = try? TableSelection.scope(for: spec, in: grid), !scope.isEmpty,
           !scope.contains(where: { $0.state == .empty }), scope.contains(where: { $0.state == .layer }) {
            spec.onlyEmpty = false
        }
        let action: IntentAction
        switch verb {
        case .fill: action = .fillCells
        case .clear: action = .clearCells
        case .highlight: action = .highlightCells
        }
        var intent = EditIntent(action: action, table: spec)
        var style = CellStyleOverride()
        let color = Self.colorMention(u, consumed: consumed)
        if u.contains(["en gras", "in bold", "bold", "gras"]) { style.weight = .bold }
        if u.contains(["plus gros", "plus grand", "plus grands", "plus gros chiffres", "bigger", "larger", "en grand"]) { style.scale = 1.3 }
        if u.contains(["plus petit", "plus petits", "smaller", "en petit"]) { style.scale = 0.8 }
        style.color = color

        let evidence = strong || grid != nil
        switch verb {
        case .fill:
            let values = Self.tableValues(u, original: original, consumed: consumed, verb: found)
            spec.value = values.value
            spec.alternative = values.alternative
            if restyle, spec.value == nil, style.color != nil || style.weight != nil || style.scale != nil {
                // The cells keep their words; only their look changes (fillCells without a value, D4 scope: all).
                spec.style = style
                spec.onlyEmpty = false
                intent.table = spec
                intent.confidence = 0.9
                return intent
            }
            // "de 1 à 45" over exactly 45 cells counts them, it does not draw at random.
            if case .random(let low?, let high?, nil)? = spec.value, !u.contains(Self.randomWords), let grid,
               let scope = try? TableSelection.scope(for: spec, in: grid),
               Int(high - low) + 1 == scope.filter({ !spec.onlyEmpty || $0.state == .empty }).count {
                spec.value = .sequence(start: low, step: 1)
            }
            if spec.value == nil { spec.value = reroll || followUp ? context.lastTableEdit?.value : nil }
            if spec.value == nil, followUp || (grid != nil && evidence) { spec.value = context.lastTableEdit?.value ?? PhotoCommandExecutor.sharedLayerValue(in: grid ?? Self.emptyGrid) }
            if spec.value == nil, !evidence || (!strong && !named) { return nil }
            if style.color != nil || style.weight != nil || style.scale != nil { spec.style = style }
            intent.confidence = spec.value == nil ? 0.6 : (evidence || followUp ? 0.92 : 0.75)
        case .clear:
            intent.confidence = evidence ? 0.92 : 0.75
        case .highlight:
            if style.color != nil { spec.style = CellStyleOverride(color: style.color) }
            intent.color = style.color
            intent.confidence = evidence ? 0.92 : 0.75
        }
        // "la case" and not which one: ask, never fill a whole column or table for one cell (D4).
        if oneCell, !spec.namesOneCell { intent.confidence = min(intent.confidence, 0.6) }
        intent.table = spec
        return intent
    }

    /// What the table grammar asks before a plan can run.
    enum TableQuestion: Equatable {
        /// "Avec quoi ? Des 1, ou des nombres au hasard ?"
        case value
        /// "Quelle case ?": one cell was said, but not which one.
        case cell
    }

    /// The question a parsed table step still needs answered, if any.
    static func question(for intent: EditIntent, _ u: NormalizedUtterance) -> TableQuestion? {
        guard IntentNormalizer.tableActions.contains(intent.action), let spec = intent.table else { return nil }
        if namesOneCellNoun(u), !spec.namesOneCell { return .cell }
        if intent.action == .fillCells, spec.value == nil, !(spec.style != nil && !spec.onlyEmpty) { return .value }
        return nil
    }

    // MARK: One cell, neighbours, style-only follow-ups

    /// "la case", "une cellule", "the cell": one cell (not "chaque case", "every cell", "les cases").
    static func namesOneCellNoun(_ u: NormalizedUtterance) -> Bool {
        let quantifiers: Set<String> = ["chaque", "toute", "tout", "toutes", "tous", "every", "each", "all", "any"]
        let inCase = u.contains(["in case", "just in case", "en cas", "au cas"])
        for (index, token) in u.tokens.enumerated() {
            let singular = token == "cellule" || token == "cell" || (token == "case" && u.language == .french && !inCase)
            guard singular else { continue }
            let previous = index > 0 ? u.tokens[index - 1] : ""
            let before = index > 1 ? u.tokens[index - 2] : ""
            if quantifiers.contains(previous) || quantifiers.contains(before) && ["la", "les", "the"].contains(previous) { continue }
            // "cell phone", "prison cell".
            if index + 1 < u.tokens.count, ["phone", "phones", "tower", "towers"].contains(u.tokens[index + 1]) { continue }
            return true
        }
        return false
    }

    /// Corner and ordinal words that place one cell: rows and columns 1-based, -1 the last.
    static let cellPositions: [(phrase: String, row: Int, column: Int)] = [
        ("tout en haut a gauche", 1, 1), ("en haut a gauche", 1, 1), ("haut a gauche", 1, 1), ("top left", 1, 1), ("upper left", 1, 1), ("top left hand", 1, 1),
        ("tout en bas a droite", -1, -1), ("en bas a droite", -1, -1), ("bas a droite", -1, -1), ("bottom right", -1, -1), ("lower right", -1, -1),
        ("tout en haut a droite", 1, -1), ("en haut a droite", 1, -1), ("haut a droite", 1, -1), ("top right", 1, -1), ("upper right", 1, -1),
        ("tout en bas a gauche", -1, 1), ("en bas a gauche", -1, 1), ("bas a gauche", -1, 1), ("bottom left", -1, 1), ("lower left", -1, 1),
    ]

    /// The cell a corner or "first"/"last" names, its words consumed so no name or relative place reads them.
    static func cellPosition(_ u: NormalizedUtterance, consumed: inout Set<Int>) -> (row: TableEditSpec.Ref, column: TableEditSpec.Ref)? {
        for position in cellPositions.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            guard let start = u.tokenIndex(of: position.phrase) else { continue }
            for index in start..<(start + position.phrase.split(separator: " ").count) { consumed.insert(index) }
            return (.index(position.row), .index(position.column))
        }
        // "la première case", "the last cell", "la case du début".
        for (index, token) in u.tokens.enumerated() where ["case", "cellule", "cell"].contains(token) {
            let neighbours = [index - 1, index + 1].filter { u.tokens.indices.contains($0) }
            for other in neighbours {
                guard let ordinal = TableGrid.ordinal(u.tokens[other]), ordinal == 1 || ordinal == -1 else { continue }
                consumed.insert(other)
                return (.index(ordinal), .index(ordinal))
            }
        }
        return nil
    }

    /// Relations to a named row or column: the ref it names, shifted ("à droite de Opus 5.5" is column 2).
    static let neighbourPhrases: [(phrase: String, delta: Int, axis: TableGrid.Axis)] = [
        ("juste a droite de", 1, .column), ("juste a droite du", 1, .column), ("a droite de", 1, .column), ("a droite du", 1, .column),
        ("to the right of", 1, .column), ("right of", 1, .column), ("juste apres", 1, .column), ("right after", 1, .column),
        ("juste a gauche de", -1, .column), ("juste a gauche du", -1, .column), ("a gauche de", -1, .column), ("a gauche du", -1, .column),
        ("to the left of", -1, .column), ("left of", -1, .column), ("juste avant", -1, .column), ("right before", -1, .column),
        ("juste en dessous de", 1, .row), ("en dessous de", 1, .row), ("en dessous du", 1, .row), ("au dessous de", 1, .row), ("below", 1, .row),
        ("juste au dessus de", -1, .row), ("au dessus de", -1, .row), ("au dessus du", -1, .row), ("above", -1, .row),
    ]

    /// "la case à droite de Opus 5.5", "la colonne juste avant GPT-6 Astra", "the row below Agentic coding": the
    /// named row or column moved by one; the relation, the name and the noun before them are consumed.
    static func neighbourRefs(_ u: NormalizedUtterance, grid: TableGrid, consumed: inout Set<Int>) -> [(axis: TableGrid.Axis, ref: TableEditSpec.Ref)] {
        let tokens = u.tokens
        var found: [(axis: TableGrid.Axis, ref: TableEditSpec.Ref)] = []
        for relation in neighbourPhrases.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            guard let at = u.tokenIndex(of: relation.phrase), !consumed.contains(at) else { continue }
            var start = at + relation.phrase.split(separator: " ").count
            while start < tokens.count, ["de", "du", "la", "le", "l", "the", "of", "colonne", "column", "ligne", "row"].contains(tokens[start]) { start += 1 }
            let available = tokens[start...].prefix { !hardStops.contains($0) && !["sur", "on", "pour", "for", "dans", "in"].contains($0) }.count
            guard available > 0 else { continue }
            var matched: (index: Int, length: Int)?
            for length in stride(from: min(available, 7), through: 1, by: -1) {
                let words = tokens[start..<(start + length)].joined(separator: " ")
                switch grid.match(.name(words), on: relation.axis) {
                case .exact(let index): matched = (index, length)
                case .partial(let index) where words.count >= 4: matched = (index, length)
                default: break
                }
                if matched != nil { break }
            }
            guard let matched else { continue }
            let count = relation.axis == .column ? grid.dataColumns.count : grid.dataRows.count
            let target = matched.index + relation.delta
            guard target >= 1, target <= count else { continue }
            var first = at
            // The noun the relation hangs on ("la case à droite de", "la colonne juste avant") is taken with it.
            if first >= 1, cellCues.union(columnCues).union(lineNouns).contains(tokens[first - 1]) { first -= 1 }
            for index in first..<(start + matched.length) { consumed.insert(index) }
            found.append((relation.axis, .index(target)))
        }
        return found
    }

    /// "non, plutôt …", "rather …", "à la place": the last cells with another value.
    static let ratherWords = ["plutot", "rather", "instead", "a la place", "au lieu", "prefere", "je prefere", "i prefer"]

    /// Only style words left ("en gras", "mets-les en rouge", "plus gros", "make them bold"), at least one of them.
    static func isStyleOnly(_ words: [String]) -> Bool {
        let styles: Set<String> = ["gras", "bold", "rouge", "bleu", "vert", "jaune", "noir", "blanc", "orange", "rose", "violet", "gris", "red", "blue", "green",
                                   "yellow", "black", "white", "pink", "purple", "gray", "grey", "gros", "grand", "grands", "petit", "petits", "bigger",
                                   "larger", "smaller", "big", "small"]
        let allowed: Set<String> = ["en", "in", "plus", "more", "mets", "met", "mettre", "fais", "fait", "rends", "passe", "make", "put", "set", "turn", "les",
                                    "le", "la", "l", "them", "it", "tout", "toutes", "tous", "all", "cases", "cellules", "cells", "chiffres", "nombres",
                                    "numbers", "valeurs", "values", "aussi", "too", "maintenant", "now", "stp", "svp", "please", "et", "and", "ecris",
                                    "ecrire", "write", "ok", "alors", "non", "no", "plutot", "rather", "un", "peu", "a", "bit"]
        guard words.contains(where: { styles.contains($0) }) else { return false }
        return words.allSatisfy { styles.contains($0) || allowed.contains($0) }
    }

    /// "noir et blanc", "sepia": a look for the picture, never a style for cells.
    static let lookPhrases = ["noir et blanc", "black and white", "sepia", "monochrome", "n b", "b w"]

    /// "remplis tout", "fill everything", "tout remplir": the whole table, when there is one.
    static func saysEverything(_ u: NormalizedUtterance) -> Bool {
        guard !u.contains(lookPhrases) else { return false }
        let tokens = u.tokens
        for (index, token) in tokens.enumerated() where ["tout", "everything", "toutes", "tous"].contains(token) {
            let previous = index > 0 ? tokens[index - 1] : "", next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if tableFillVerbs.union(tableClearVerbs).contains(previous) || tableFillVerbs.union(tableClearVerbs).contains(next) { return true }
        }
        return u.contains(["fill it all", "fill them all", "fill all", "remplis les toutes", "remplis les tous"])
    }

    /// Verbs that start a second command after "et"/"puis" ("… et surligne-la", "… then clear row 3").
    static let clauseVerbs: Set<String> = tableFillVerbs.union(tableClearVerbs).union(tableHighlightVerbs).union([
        "augmente", "baisse", "diminue", "rends", "passe", "recadre", "tourne", "applique", "annule", "floute", "eclaircis", "assombris",
        "agrandis", "reduis", "deplace", "bouge", "change", "modifie", "souligne", "retourne", "zoome", "sauvegarde", "enregistre", "exporte",
        "partage", "accentue", "renforce", "redresse", "fais", "fait", "do", "increase", "decrease", "make", "crop", "rotate", "apply", "undo", "blur", "brighten",
        "darken", "move", "resize", "save", "export", "share", "sharpen", "change", "straighten", "enlarge", "shrink",
    ])

    /// The table command, and a second one after "et"/"puis"/"and"/"then" when a verb starts it; a
    /// second table command with no scope of its own ("surligne-la") takes the first one's. A second
    /// "avec V" clause with no verb of its own ("la première colonne avec 1 et la dernière avec 0") is its
    /// own step with the first one's verb: two values are never merged into one list. A second clause the
    /// grammar cannot read leaves the plan below the fast lane (0.85), so the words are never half done.
    func parseTablePlan(_ u: NormalizedUtterance, original: String, context: IntentContext) -> (intents: [EditIntent], question: TableQuestion?)? {
        let tokens = u.tokens
        let protected = Self.rangeConjunctions(tokens)
        var split: (at: Int, next: Int)?
        var borrowedVerb: String?
        for (index, token) in tokens.enumerated() where Self.conjunctions.contains(token) && index > 0 && !protected.contains(index) {
            var next = index + 1
            while next < tokens.count, ["puis", "ensuite", "then", "apres", "after", "aussi", "also"].contains(tokens[next]) { next += 1 }
            if next < tokens.count, Self.clauseVerbs.contains(tokens[next]) { split = (index, next); break }
        }
        if split == nil, let second = Self.secondValueClause(tokens, protected: protected), let verb = Self.tableVerb(in: u), verb.index < second.at {
            split = second
            borrowedVerb = tokens[verb.index]
        }
        guard let split else {
            guard let intent = parseTable(u, original: original, context: context) else { return nil }
            return ([intent], Self.question(for: intent, u))
        }
        let left = NormalizedUtterance(tokens[..<split.at].joined(separator: " "))
        let right = NormalizedUtterance(([borrowedVerb].compactMap { $0 } + tokens[split.next...]).joined(separator: " "))
        guard var first = parseTable(left, original: original, context: context) else {
            // "change le titre en « Scores » et remplis tout avec des 1": another step, then a table one.
            guard borrowedVerb == nil, let second = parseTable(right, original: original, context: context) else { return nil }
            let before = UtteranceSegmenter.segments(of: left.text).flatMap { parseSegment(NormalizedUtterance($0), original: original, context: context) }
            var understood = before.filter { $0.action != .unknown }
            guard !understood.isEmpty else { return nil }
            if understood.count < before.count { understood = understood.map { Self.capped($0) } }
            return (understood + [second], Self.question(for: second, right))
        }
        if borrowedVerb == nil, first.action == .fillCells, first.table?.value == nil, let value = Self.tableValues(u, original: original, consumed: [], verb: nil).value {
            first.table?.value = value
            first.confidence = max(first.confidence, 0.9)
        }
        var followingContext = context
        followingContext.lastTableEdit = first.table
        followingContext.lastIntent = first
        var intents = [first]
        let ownScope = right.contains(Self.followUpScopeWords + Self.emptyScopeWords + ["tout", "toutes", "tous", "partout", "everything", "all", "every", "chaque", "each"])
        if var second = parseTable(right, original: borrowedVerb == nil ? original : "", context: followingContext) {
            if !ownScope, second.table?.rows.isEmpty == true, second.table?.columns.isEmpty == true {
                second.table?.rows = first.table?.rows ?? []
                second.table?.columns = first.table?.columns ?? []
            }
            intents.append(second)
        } else if let verb = Self.tableVerb(in: right), verb.index == 0, right.tokens.count > 1,
                  ["la", "le", "les", "l", "it", "them", "y", "en", "those", "ces", "celles"].contains(right.tokens[1]) {
            // "… et surligne-la", "puis remplis-la avec des 0": the same cells, another action.
            var spec = TableEditSpec(rows: first.table?.rows ?? [], columns: first.table?.columns ?? [])
            let action: IntentAction
            switch verb.verb {
            case .fill:
                action = .fillCells
                spec.value = Self.tableValues(right, original: "", consumed: [], verb: verb).value
            case .clear: action = .clearCells
            case .highlight: action = .highlightCells
            }
            var second = EditIntent(action: action, confidence: action == .fillCells && spec.value == nil ? 0.6 : 0.9, table: spec)
            if action == .highlightCells, let color = Self.colorMention(right, consumed: []) {
                second.color = color
                second.table?.style = CellStyleOverride(color: color)
            }
            intents.append(second)
        } else {
            let rest = UtteranceSegmenter.segments(of: right.text).flatMap { parseSegment(NormalizedUtterance($0), original: original, context: context) }
            let understood = rest.filter { $0.action != .unknown }
            intents += understood
            // The second clause was not understood (or only in part): never run the first alone on the fast lane.
            if understood.isEmpty || understood.count < rest.count { intents = intents.map { Self.capped($0) } }
        }
        return (intents, Self.question(for: intents[0], left))
    }

    static let conjunctions: Set<String> = ["et", "puis", "ensuite", "and", "then"]

    /// Below the fast lane (D9 needs 0.9): the model, when there is one, reads the whole sentence.
    static func capped(_ intent: EditIntent) -> EditIntent {
        var intent = intent
        intent.confidence = min(intent.confidence, 0.85)
        return intent
    }

    /// The "et"/"and" inside "entre 50 et 90", "between 50 and 90", "de 1 à 45 et": part of a range.
    static func rangeConjunctions(_ tokens: [String]) -> Set<Int> {
        var protected = Set<Int>()
        for (index, token) in tokens.enumerated() where ["et", "and"].contains(token) && index >= 2 {
            let window = tokens[max(0, index - 4)..<index]
            if window.contains(where: { ["entre", "between"].contains($0) }), NumberWords.parse(tokens, at: index - 1) != nil || Double(tokens[index - 1]) != nil {
                protected.insert(index)
            }
        }
        return protected
    }

    /// "… avec 1 et la dernière avec 0", "… with 1, then the rest with 0": a conjunction between two "avec V"
    /// clauses, the second without a verb of its own. Where to split, and where the second clause starts.
    static func secondValueClause(_ tokens: [String], protected: Set<Int>) -> (at: Int, next: Int)? {
        let valueWords: Set<String> = ["avec", "with", "par", "by"]
        for (index, token) in tokens.enumerated() where conjunctions.contains(token) && index > 0 && !protected.contains(index) {
            guard tokens[..<index].contains(where: { valueWords.contains($0) }), tokens[(index + 1)...].contains(where: { valueWords.contains($0) }) else { continue }
            var next = index + 1
            while next < tokens.count, ["puis", "ensuite", "then", "apres", "after", "aussi", "also"].contains(tokens[next]) { next += 1 }
            guard next < tokens.count, !clauseVerbs.contains(tokens[next]) else { continue }
            return (index, next)
        }
        return nil
    }

    /// Whether the utterance names table cells ("chaque case du tableau", "the empty cells"): parseText
    /// and parseGenerative leave it to the table grammar.
    static func namesTableCells(_ u: NormalizedUtterance) -> Bool {
        if textAboutTheTable(u) { return false }
        let tokens = tableWords(u)
        if !tokens.isDisjoint(with: ["cellule", "cellules", "cell", "cells", "tableau", "tableaux", "colonne", "colonnes", "column", "columns"]) { return true }
        let inCase = u.contains(["in case", "just in case", "en cas", "au cas"])
        return u.language == .french && !inCase && !tokens.isDisjoint(with: caseNouns)
    }

    /// "ajoute le titre « Résultats » au-dessus du tableau", "add a caption under the table": a text layer
    /// about the table, not values in its cells (no cell, row or column is named).
    static func textAboutTheTable(_ u: NormalizedUtterance) -> Bool {
        guard u.contains(["texte", "titre", "legende", "sous titre", "text", "title", "caption", "heading", "subtitle", "label", "source", "note"]) else { return false }
        let parts = cellCues.union(columnCues).union(lineNouns)
        return tableWords(u).isDisjoint(with: parts)
    }

    /// "fill the table", "vide la table": the table as the thing acted on, never "a vase on the table".
    static func saysTheTable(_ tokens: [String]) -> Bool {
        for (index, token) in tokens.enumerated() where token == "table" || token == "tables" {
            let before = index >= 1 ? tokens[index - 1] : ""
            let verb = index >= 2 ? tokens[index - 2] : ""
            if ["the", "this", "la", "cette", "ce"].contains(before), tableFillVerbs.union(tableClearVerbs).union(tableHighlightVerbs).contains(verb) { return true }
            if index + 1 < tokens.count, ["with", "avec"].contains(tokens[index + 1]) { return true }
        }
        return false
    }

    /// The words said, without those that only look like table words ("cell phone", "prison cell").
    static func tableWords(_ u: NormalizedUtterance) -> Set<String> {
        var words: Set<String> = []
        for (index, token) in u.tokens.enumerated() {
            let next = index + 1 < u.tokens.count ? u.tokens[index + 1] : ""
            let previous = index > 0 ? u.tokens[index - 1] : ""
            if ["cell", "cells"].contains(token), ["phone", "phones", "tower", "towers"].contains(next) || ["prison", "jail", "battery", "solar"].contains(previous) { continue }
            words.insert(token)
        }
        return words
    }

    // MARK: Verb

    /// The first table verb said, and where.
    static func tableVerb(in u: NormalizedUtterance) -> (verb: TableVerb, index: Int)? {
        let tokens = u.tokens
        var best: (verb: TableVerb, index: Int)?
        func consider(_ verb: TableVerb, _ index: Int) {
            if best == nil || index < best!.index { best = (verb, index) }
        }
        for phrase in tableHighlightPhrases {
            if let index = u.tokenIndex(of: phrase) { consider(.highlight, index) }
        }
        for (index, token) in tokens.enumerated() {
            let previous = index > 0 ? tokens[index - 1] : ""
            if tableHighlightVerbs.contains(token) { consider(.highlight, index) }
            else if tableFillVerbs.contains(token) {
                // "mets en évidence" was a highlight; "number" after an article is a noun.
                if token == "number", ["the", "a", "any"].contains(previous) { continue }
                if ["mets", "met", "mettre"].contains(token), index + 2 < tokens.count, tokens[index + 1] == "en", ["evidence", "valeur"].contains(tokens[index + 2]) { continue }
                consider(.fill, index)
            } else if tableClearVerbs.contains(token) {
                // "les cases vides", "the empty cells": adjectives.
                if token == "vide", caseNouns.union(["cellule", "cellules", "ligne", "colonne"]).contains(previous) { continue }
                if token == "empty", index > 0, !["please", "now", "then", "and", "you", "can", "just"].contains(previous) { continue }
                consider(.clear, index)
            }
        }
        return best
    }

    /// A question about the table is answered, not executed ("combien de cases sont vides ?").
    /// "tu peux remplir le tableau ?" is a request (PoliteRequest); a "?" inside quotes asks nothing.
    static func isQuestion(_ u: NormalizedUtterance, original: String) -> Bool {
        if PoliteRequest.isRequest(u.tokens) { return false }
        if withoutQuotes(original).contains("?") { return true }
        guard let first = u.tokens.first else { return false }
        return ["combien", "quel", "quelle", "quels", "quelles", "pourquoi", "comment", "what", "which", "how", "why", "is", "are", "does", "do", "que", "qu"].contains(first)
    }

    /// A question to answer, read strictly (a "?" outside quotes, or an interrogative first word), never a polite
    /// request: Live without a model answers these or says it cannot, and never edits for them ("do your magic"
    /// is a command).
    static func asksAQuestion(_ u: NormalizedUtterance, original: String) -> Bool {
        if PoliteRequest.isRequest(u.tokens) { return false }
        if withoutQuotes(original).contains("?") { return true }
        guard let first = u.tokens.first else { return false }
        if ["pourquoi", "comment", "combien", "quel", "quelle", "quels", "quelles", "why", "how", "which", "what"].contains(first) { return true }
        return u.tokens.starts(with: ["est", "ce", "que"]) || u.tokens.starts(with: ["qu", "est", "ce"])
    }

    /// The words outside quotes: « Pourquoi ? » written as text is not a question.
    static func withoutQuotes(_ original: String) -> String {
        var text = original
        for pattern in ["\"[^\"]*\"", "“[^”]*”", "«[^»]*»"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }

    static func isRandomish(_ value: CellValue?) -> Bool {
        switch value {
        case .random?, .plausible?: return true
        default: return false
        }
    }

    static let emptyGrid = TableGrid(id: "", bounds: .zero, title: nil, rows: [], columns: [], cells: [], headerRowCount: 0, labelColumnCount: 0,
                                     ruling: .none, bodyStyle: nil, confidence: 0, source: .detected)

    // MARK: Rows and columns

    /// Rows and columns named: after "colonne"/"ligne"/"row"/"column" (a name or a number), an ordinal
    /// before them ("la dernière colonne", "the third row"), a cell ("la case Opus 5 / Agentic coding"),
    /// and with a table, after "pour", "sous", "à", "en" or a full header or label said anywhere.
    static func tableRefs(_ u: NormalizedUtterance, grid: TableGrid?, consumed: inout Set<Int>, english: Bool,
                          lineCues: Bool = true, original: String = "") -> (rows: [TableEditSpec.Ref], columns: [TableEditSpec.Ref]) {
        let tokens = u.tokens
        var rows: [TableEditSpec.Ref] = [], columns: [TableEditSpec.Ref] = []
        func add(_ ref: TableEditSpec.Ref, _ axis: TableGrid.Axis) {
            if axis == .row { if !rows.contains(ref) { rows.append(ref) } } else if !columns.contains(ref) { columns.append(ref) }
        }
        func resolved(_ span: [String], cue: String?, axis: TableGrid.Axis) -> (ref: TableEditSpec.Ref, length: Int)? {
            guard !span.isEmpty else { return nil }
            // "la ligne A", "row B": a lone letter names a row or column the table may not have (asked, never all of them).
            if span.count == 1, span[0].count == 1, span[0].first?.isLetter == true {
                if let grid, case .exact(let index) = grid.match(.name(span[0]), on: axis) { return (canonical(index, axis: axis, grid: grid, said: span), 1) }
                return (.name(span[0].uppercased()), 1)
            }
            // The name as said runs to the first small word ("la colonne GPT 7 avec…" -> "GPT 7").
            let nameSpan = Array(span.prefix { !softStops.contains($0) })
            if let grid {
                // A name exactly, the longest first (names may hold small words: "Taux de réussite").
                for length in stride(from: min(span.count, 7), through: 1, by: -1) {
                    let words = Array(span.prefix(length))
                    let phrase = ([cue].compactMap { $0 } + words).joined(separator: " ")
                    if case .exact(let index) = grid.match(.name(phrase), on: axis) { return (canonical(index, axis: axis, grid: grid, said: words), length) }
                }
                // Part of a name ("Gemini", "Astra", "Opus"), only when it is all that was said: "GPT 7" is not "GPT-6 Astra".
                if !nameSpan.isEmpty {
                    let phrase = ([cue].compactMap { $0 } + nameSpan).joined(separator: " ")
                    switch grid.match(.name(phrase), on: axis) {
                    case .partial(let index): return (canonical(index, axis: axis, grid: grid, said: nameSpan), nameSpan.count)
                    case .ambiguous: return (.name(said(nameSpan, in: original)), nameSpan.count)
                    default: break
                    }
                }
                // Not in the table: the words as said, so the answer can list the real names.
                return nameSpan.isEmpty ? nil : (.name(said(nameSpan, in: original)), nameSpan.count)
            }
            if span.count == 1, let number = Int(span[0]), number >= 1 { return (.index(number), 1) }
            if span.count == 1, let number = NumberWords.parse(span, at: 0)?.value, number >= 1, number == number.rounded() { return (.index(Int(number)), 1) }
            return nameSpan.isEmpty ? nil : (.name(said(nameSpan, in: original)), nameSpan.count)
        }
        /// Up to 7 words after `start`, stopping at a hard stop or a consumed word; leading particles skipped.
        func window(from start: Int) -> (start: Int, words: [String]) {
            var index = start
            while index < tokens.count, particles.contains(tokens[index]) { index += 1 }
            var words: [String] = []
            var cursor = index
            while cursor < tokens.count, words.count < 7, !hardStops.contains(tokens[cursor]), !consumed.contains(cursor) {
                words.append(tokens[cursor])
                cursor += 1
            }
            return (index, words)
        }
        func consume(_ start: Int, _ length: Int) { for index in start..<min(tokens.count, start + length) { consumed.insert(index) } }

        for (index, token) in tokens.enumerated() where !consumed.contains(index) {
            let axis: TableGrid.Axis?
            if columnCues.contains(token) { axis = .column } else if lineCues, lineNouns.contains(token) { axis = .row } else { axis = nil }
            guard let axis else { continue }
            // An ordinal right before: "la dernière colonne", "3e ligne", "the last row", "avant-dernière colonne".
            let before = index - 1
            if before >= 0, let ordinal = TableGrid.ordinal(tokens[before]) ?? NumberWords.ordinal(tokens[before]) {
                if before >= 1, tokens[before - 1] == "avant", ordinal == -1, let grid {
                    add(.index(max(1, (axis == .row ? grid.dataRows.count : grid.dataColumns.count) - 1)), axis)
                    consume(before - 1, 3)
                } else {
                    add(.index(ordinal), axis)
                    consume(before, 2)
                }
                continue
            }
            let (start, words) = window(from: index + 1)
            // "la colonne suivante", "the row below": relative to the last edit (relativeRefs).
            if let first = words.first, relativeWords.contains(first) {
                consume(index, 1)
                continue
            }
            if let first = words.first, !["a", "an"].contains(first),
               let number = Int(first) ?? NumberWords.parse(words, at: 0).flatMap({ $0.value == $0.value.rounded() && $0.consumed == 1 ? Int($0.value) : nil }),
               number >= 1 {
                add(.index(number), axis)
                consume(index, start - index + 1)
                continue
            }
            if let found = resolved(words, cue: token, axis: axis) {
                add(found.ref, axis)
                consume(index, start - index + found.length)
                continue
            }
            // "the Opus 5 column": the name comes first in English.
            var back = index - 1
            var span: [String] = []
            while back >= 0, span.count < 6, !consumed.contains(back), !["the", "in", "into", "to", "for", "on", "of", "fill", "put", "write", "highlight", "clear", "empty"].contains(tokens[back]),
                  !hardStops.contains(tokens[back]) {
                span.insert(tokens[back], at: 0)
                back -= 1
            }
            // In French a name comes after its noun: a name before it only counts when the table has it.
            if !span.isEmpty, let found = resolved(span, cue: nil, axis: axis),
               english || (grid.map { grid -> Bool in if case .none = grid.match(found.ref, on: axis) { return false }; return true } ?? false) {
                add(found.ref, axis)
                consume(back + 1, span.count + 1)
            } else {
                consume(index, 1)
            }
        }

        // "la case Opus 5 / Agentic coding", "cell Fable 5.1 Visual reasoning", "r6c3".
        for (index, token) in tokens.enumerated() where !consumed.contains(index) {
            if let address = cellAddress(token) {
                add(.index(address.row), .row)
                add(.index(address.column), .column)
                consumed.insert(index)
                continue
            }
            guard cellCues.contains(token), let grid else { continue }
            let (start, words) = window(from: index + 1)
            guard words.count >= 2 else { continue }
            var best: (column: TableEditSpec.Ref, row: TableEditSpec.Ref, length: Int)?
            for split in 1..<words.count {
                for end in stride(from: words.count, to: split, by: -1) {
                    let left = Array(words[..<split]), right = Array(words[split..<end])
                    let pairs: [(TableGrid.Axis, [String], TableGrid.Axis, [String])] = [(.column, left, .row, right), (.row, left, .column, right)]
                    for (firstAxis, first, secondAxis, second) in pairs {
                        guard case .exact(let a) = grid.match(.name(first.joined(separator: " ")), on: firstAxis),
                              case .exact(let b) = grid.match(.name(second.joined(separator: " ")), on: secondAxis) else { continue }
                        let column = firstAxis == .column ? canonical(a, axis: .column, grid: grid, said: first) : canonical(b, axis: .column, grid: grid, said: second)
                        let row = firstAxis == .row ? canonical(a, axis: .row, grid: grid, said: first) : canonical(b, axis: .row, grid: grid, said: second)
                        if best == nil || end > best!.length { best = (column, row, end) }
                    }
                }
            }
            if let best {
                add(best.row, .row)
                add(best.column, .column)
                consume(index, start - index + best.length)
            }
        }

        // No table to check against: "à Opus 5 sur la ligne Agentic coding" still names a cell.
        if grid == nil, !rows.isEmpty, columns.isEmpty, !english {
            for (index, token) in tokens.enumerated() where !consumed.contains(index) && ["a", "pour", "sous"].contains(token) {
                let (start, words) = window(from: index + 1)
                let name = words.prefix { !softStops.contains($0) }
                guard !name.isEmpty, Double(name[0]) == nil else { continue }
                add(.name(name.joined(separator: " ")), .column)
                consume(index, start - index + name.count)
                break
            }
        }

        // With a table: "pour Opus 5", "sous Gemini", "à Opus 5", "en Agentic coding", "for GPT-6 Astra",
        // and any full header or label said on its own.
        if let grid {
            let cues: Set<String> = english ? ["for", "under", "at", "on", "in"] : ["pour", "sous", "a", "en", "sur", "dans"]
            for (index, token) in tokens.enumerated() where !consumed.contains(index) && cues.contains(token) {
                let (start, words) = window(from: index + 1)
                guard !words.isEmpty else { continue }
                let preferRow = ["en", "on", "sur", "in"].contains(token)
                var matches: [(ref: TableEditSpec.Ref, axis: TableGrid.Axis, length: Int, exact: Bool)] = []
                for axis in [TableGrid.Axis.column, .row] {
                    for length in stride(from: min(words.count, 7), through: 1, by: -1) {
                        let words = Array(words.prefix(length))
                        switch grid.match(.name(words.joined(separator: " ")), on: axis) {
                        case .exact(let found): matches.append((canonical(found, axis: axis, grid: grid, said: words), axis, length, true))
                        case .partial(let found) where words.count >= 1 && words.joined().count >= 4:
                            matches.append((canonical(found, axis: axis, grid: grid, said: words), axis, length, false))
                        default: continue
                        }
                        break
                    }
                }
                let chosen = matches.sorted { a, b in
                    if a.exact != b.exact { return a.exact }
                    if a.length != b.length { return a.length > b.length }
                    return (a.axis == .row) == preferRow
                }.first
                if let chosen {
                    add(chosen.ref, chosen.axis)
                    consume(index, start - index + chosen.length)
                }
            }
            // Full names said with no cue, longest first.
            for length in stride(from: min(tokens.count, 7), through: 1, by: -1) {
                for start in 0...(tokens.count - length) {
                    let range = start..<(start + length)
                    guard !range.contains(where: { consumed.contains($0) }) else { continue }
                    let words = Array(tokens[range])
                    guard words.contains(where: { $0.count >= 3 || Double($0) != nil }) else { continue }
                    for axis in [TableGrid.Axis.column, .row] {
                        if case .exact(let found) = grid.match(.name(words.joined(separator: " ")), on: axis),
                           !TableGrid.foldedTokens(words.joined(separator: " ")).allSatisfy({ Double($0) != nil }) {
                            add(canonical(found, axis: axis, grid: grid, said: words), axis)
                            consume(start, length)
                            break
                        }
                    }
                }
            }
        }
        return (rows, columns)
    }

    /// Normalised words as the person wrote them ("gpt 7" -> "GPT 7"), else as they are.
    static func said(_ words: [String], in original: String) -> String {
        let joined = words.joined(separator: " ")
        let written = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !written.isEmpty, !words.isEmpty else { return joined }
        for start in written.indices {
            for end in start..<min(written.count, start + words.count + 2) {
                let slice = written[start...end].joined(separator: " ")
                if NormalizedUtterance.normalize(slice) == joined { return slice.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;")) }
            }
        }
        return joined
    }

    /// The header or label as printed (first label line) for a matched index.
    static func canonical(_ index: Int, axis: TableGrid.Axis, grid: TableGrid, said: [String]) -> TableEditSpec.Ref {
        let names = grid.names(axis)
        guard index >= 1, index <= names.count else { return .name(said.joined(separator: " ")) }
        let name = names[index - 1]
        let first = name.split(separator: "\n").first.map(String.init) ?? name
        // A second label line said ("GPQA Diamond") names the same row; keep the first line, which is unique.
        return .name(first.isEmpty ? said.joined(separator: " ") : first)
    }

    /// "r6c3", "l2c4": a cell by its 1-based data row and column, as the table line prints them.
    static func cellAddress(_ token: String) -> (row: Int, column: Int)? {
        guard token.first == "r", let c = token.firstIndex(of: "c") else { return nil }
        let row = Int(token[token.index(after: token.startIndex)..<c]), column = Int(token[token.index(after: c)...])
        guard let row, let column, row >= 1, column >= 1 else { return nil }
        return (row, column)
    }

    /// "la case à droite", "the cell below", "la colonne suivante", "the next row": next to the last table
    /// edit's cell, column or row.
    static func relativeRefs(_ u: NormalizedUtterance, last: TableEditSpec?, grid: TableGrid?) -> (rows: [TableEditSpec.Ref], columns: [TableEditSpec.Ref])? {
        guard let last, let grid else { return nil }
        func index(_ refs: [TableEditSpec.Ref], _ axis: TableGrid.Axis) -> Int? {
            guard refs.count == 1 else { return nil }
            switch grid.match(refs[0], on: axis) {
            case .exact(let found), .partial(let found): return found
            default: return nil
            }
        }
        let row = index(last.rows, .row), column = index(last.columns, .column)
        let rowCount = grid.dataRows.count, columnCount = grid.dataColumns.count
        func clampRow(_ value: Int) -> Int? { value >= 1 && value <= rowCount ? value : nil }
        func clampColumn(_ value: Int) -> Int? { value >= 1 && value <= columnCount ? value : nil }
        if u.contains(["colonne suivante", "next column", "column after", "colonne d apres", "colonne d a cote"]), let column, let next = clampColumn(column + 1) {
            return (last.rows, [.index(next)])
        }
        if u.contains(["colonne precedente", "previous column", "column before", "colonne d avant"]), let column, let next = clampColumn(column - 1) {
            return (last.rows, [.index(next)])
        }
        if u.contains(["ligne suivante", "next row", "row below", "ligne d apres", "ligne d en dessous", "rangee suivante"]), let row, let next = clampRow(row + 1) {
            return ([.index(next)], last.columns)
        }
        if u.contains(["ligne precedente", "previous row", "row above", "ligne d avant", "ligne du dessus"]), let row, let next = clampRow(row - 1) {
            return ([.index(next)], last.columns)
        }
        guard let row, let column else { return nil }
        if u.contains(["a droite", "to the right", "on the right", "right of it", "d a cote", "suivante", "next cell", "the next one", "celle d apres"]) {
            if let next = clampColumn(column + 1) { return ([.index(row)], [.index(next)]) }
            if let down = clampRow(row + 1) { return ([.index(down)], [.index(1)]) }
        }
        if u.contains(["a gauche", "to the left", "on the left", "left of it", "precedente", "previous cell"]), let next = clampColumn(column - 1) {
            return ([.index(row)], [.index(next)])
        }
        if u.contains(["en dessous", "au dessous", "dessous", "en bas", "below", "underneath", "under it"]), let next = clampRow(row + 1) {
            return ([.index(next)], [.index(column)])
        }
        if u.contains(["au dessus", "dessus", "en haut", "above", "over it"]), let next = clampRow(row - 1) {
            return ([.index(next)], [.index(column)])
        }
        return nil
    }

    // MARK: Values

    /// What goes in the cells, and the alternative named after "ou"/"or" ("avec 1 ou des chiffres aléatoires").
    static func tableValues(_ u: NormalizedUtterance, original: String, consumed: Set<Int>, verb: (verb: TableVerb, index: Int)?) -> (value: CellValue?, alternative: CellValue?) {
        let tokens = u.tokens
        // Quoted text is verbatim; after "par"/"avec"/"with" when there are two.
        let quotes = quotedStrings(in: original)
        if let quoted = quotes.last, !quoted.isEmpty {
            return (.constant(String(quoted.prefix(24))), nil)
        }
        // "A ou B": the value first, the alternative after.
        var split: Int?
        for (index, token) in tokens.enumerated() where (token == "ou" || token == "or") && !consumed.contains(index) {
            if index + 1 < tokens.count, !["bien", "else"].contains(tokens[index + 1]) { split = index; break }
        }
        if let split {
            let left = value(in: Array(0..<split), tokens: tokens, consumed: consumed, original: original, verbIndex: verb?.index)
            let right = value(in: Array((split + 1)..<tokens.count), tokens: tokens, consumed: consumed, original: original, verbIndex: nil)
            if let left, let right { return (left, right) }
            if left == nil, let right { return (right, nil) }
            return (left, nil)
        }
        return (value(in: Array(tokens.indices), tokens: tokens, consumed: consumed, original: original, verbIndex: verb?.index), nil)
    }

    /// The value one part of the utterance says, reading only the words not already taken by a name.
    static func value(in indices: [Int], tokens: [String], consumed: Set<Int>, original: String, verbIndex: Int?) -> CellValue? {
        let free = indices.filter { !consumed.contains($0) }
        let words = free.map { tokens[$0] }
        let text = " " + words.joined(separator: " ") + " "
        func says(_ phrases: [String]) -> Bool { phrases.contains { text.contains(" " + $0 + " ") } }

        // Numbers said, with where they are ("45 cases" counts cells, it is not a value).
        var numbers: [(value: Double, written: String, at: Int, percent: Bool)] = []
        var position = 0
        while position < words.count {
            let word = words[position]
            if ["un", "une", "a", "an"].contains(word) { position += 1; continue }
            guard let parsed = NumberWords.parse(words, at: position) else { position += 1; continue }
            let after = position + parsed.consumed
            let next = after < words.count ? words[after] : ""
            if cellCues.union(lineNouns).union(columnCues).union(["fois", "times", "decimale", "decimales", "decimal", "decimals", "chiffres", "digits"]).contains(next)
                || (next == "premieres" || next == "dernieres") {
                position = after
                continue
            }
            var percent = false
            var consumedExtra = 0
            if next == "pourcent" || next == "percent" { percent = true; consumedExtra = 1 }
            if next == "pour", after + 1 < words.count, words[after + 1] == "cent" { percent = true; consumedExtra = 2 }
            // Digits keep their spelling ("12,5", "007"); a number said as a word is written in digits ("deux" -> "2").
            let raw = parsed.consumed == 1 && word.first?.isNumber == true ? word : CellValue.short(parsed.value)
            numbers.append((parsed.value, writtenNumber(raw, original: original), position, percent))
            position = after + consumedExtra
        }
        let range = rangeBounds(words)

        if says(randomWords) {
            var low = range?.low, high = range?.high
            if low == nil, high == nil, says(["un chiffre", "digits", "single digits", "chiffres de 0 a 9", "a digit"]) { low = 0; high = 9 }
            if low == nil, high == nil, let bound = numbers.first(where: { _ in says(["jusqu a", "up to", "au plus", "at most", "max", "maximum"]) }) { low = 0; high = bound.value }
            return .random(min: low, max: high, decimals: decimals(in: words))
        }
        if says(plausibleWords) { return .plausible }
        // "des nombres de 0 à 100": values in a range; "de 1 à 45" alone: counting.
        if let range, says(["nombres", "valeurs", "chiffres", "numbers", "values", "pourcentages", "percentages", "notes", "scores"]), !says(sequenceWords) {
            return .random(min: range.low, max: range.high, decimals: decimals(in: words))
        }
        if says(sequenceWords) || (range != nil && says(["de", "from"]) && !says(["entre", "between"])) {
            if let range { return .sequence(start: range.low, step: 1) }
            if let first = numbers.first { return .sequence(start: first.value, step: 1) }
            return .sequence(start: 1, step: 1)
        }
        let values = numbers.filter { number in !(range.map { $0.low == number.value || $0.high == number.value } ?? false) || range == nil }
        if values.count >= 2 {
            return .list(values.map { $0.written + ($0.percent ? "%" : "") })
        }
        if let only = values.first { return .constant(String((only.written + (only.percent ? "%" : "")).prefix(24))) }
        if says(["tiret", "tirets", "trait", "traits", "dash", "dashes"]) { return .constant("—") }
        if says(["n a", "na", "n d", "nd"]) { return .constant("N/A") }
        if says(["zeros", "zero"]) { return .constant("0") }
        if says(["ones"]) { return .constant("1") }
        if says(["coche", "coches", "check", "checks", "checkmark", "checkmarks", "tick", "ticks"]) { return .constant("✓") }
        if says(["croix", "cross", "crosses"]) { return .constant("✗") }
        if let word = ["oui", "non", "yes", "no"].first(where: { says(["avec " + $0, "par " + $0, "with " + $0, "mets " + $0, "put " + $0, "write " + $0, "ecris " + $0]) }) {
            return .constant(word.prefix(1).uppercased() + word.dropFirst())
        }
        return nil
    }

    /// "entre 50 et 90", "de 0 à 100", "between 50 and 90", "from 1 to 45".
    static func rangeBounds(_ words: [String]) -> (low: Double, high: Double)? {
        for (index, word) in words.enumerated() where ["entre", "between", "de", "from"].contains(word) {
            guard index + 1 < words.count, let first = NumberWords.parse(words, at: index + 1) else { continue }
            let connector = index + 1 + first.consumed
            guard connector < words.count, ["et", "and", "a", "to", "au"].contains(words[connector]),
                  let second = NumberWords.parse(words, at: connector + 1) else { continue }
            return (min(first.value, second.value), max(first.value, second.value))
        }
        return nil
    }

    /// "avec une décimale" -> 1, "deux décimales" -> 2, "whole numbers" -> 0; nil when not said.
    static func decimals(in words: [String]) -> Int? {
        let text = " " + words.joined(separator: " ") + " "
        if [" entiers ", " entier ", " integers ", " whole numbers ", " sans virgule ", " sans decimale ", " no decimals "].contains(where: text.contains) { return 0 }
        for (index, word) in words.enumerated() where ["decimale", "decimales", "decimal", "decimals", "chiffre apres la virgule"].contains(word) {
            guard index > 0 else { return 1 }
            switch words[index - 1] {
            case "deux", "two", "2": return 2
            case "trois", "three", "3": return 3
            default: return 1
            }
        }
        return nil
    }

    /// A number as the person wrote it: "12,5" keeps its comma.
    static func writtenNumber(_ normalized: String, original: String) -> String {
        guard normalized.contains(".") else { return normalized }
        let comma = normalized.replacingOccurrences(of: ".", with: ",")
        return original.contains(comma) ? comma : normalized
    }

    /// Words between quotes, in order.
    static func quotedStrings(in original: String) -> [String] {
        var found: [String] = []
        for pattern in ["\"([^\"]+)\"", "“([^”]+)”", "«\\s*([^»]+?)\\s*»"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: original, range: NSRange(original.startIndex..., in: original)) {
                if let range = Range(match.range(at: 1), in: original) { found.append(String(original[range]).trimmingCharacters(in: .whitespaces)) }
            }
        }
        return found
    }

    /// A colour said outside the names ("en rouge", "in green").
    static func colorMention(_ u: NormalizedUtterance, consumed: Set<Int>) -> PSColor? {
        for (index, token) in u.tokens.enumerated() where !consumed.contains(index) {
            guard index > 0, ["en", "in"].contains(u.tokens[index - 1]) || ["rouge", "vert", "jaune", "bleu", "orange", "red", "green", "yellow", "blue"].contains(token) else { continue }
            if let color = PSColor.named(token), token != "clear", token != "light" { return color }
        }
        return nil
    }
}
