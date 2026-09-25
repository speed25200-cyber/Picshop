import Foundation
import PicshopCore

/// Questions about what the picture holds, answered from the table and the scene map by code, so Live
/// answers them without a model ("que vaut Opus 5 en Agentic coding ?", "c'est écrit quoi en bas ?",
/// "combien de cases sont vides ?"). Nil when the words ask something else: the brain answers.
/// One short sentence in the reply language; printed values are read as printed (French decimals).
public enum LiveQuestionAnswers {
    public static func answer(_ words: String, table: TableGrid?, scene: SceneMap?, language: NormalizedUtterance.Language) -> String? {
        let tokens = NormalizedUtterance(words).tokens
        guard LiveTurnRouter.isQuestion(words, tokens: tokens) || tokens.contains(where: { ["combien", "quel", "quelle", "what", "which", "how"].contains($0) }) else {
            return nil
        }
        if let table, let answer = tableAnswer(tokens: tokens, words: words, table: table, language: language) { return answer }
        if let scene, let answer = sceneAnswer(tokens: tokens, scene: scene, language: language) { return answer }
        return nil
    }

    // MARK: Tables

    static func tableAnswer(tokens: [String], words: String, table: TableGrid, language: NormalizedUtterance.Language) -> String? {
        let fr = language == .french
        let spoken = TableGrid.foldedTokens(words)
        let set = Set(tokens)
        let columns = table.names(.column).map { $0.replacingOccurrences(of: "\n", with: " ") }
        let rows = table.names(.row).map { $0.replacingOccurrences(of: "\n", with: " ") }
        let columnWords: Set<String> = ["colonne", "column", "col"], rowWords: Set<String> = ["ligne", "row", "rangee"]
        let namedColumn = LiveSceneLines.namedIndex(columns, in: spoken, axisWords: columnWords)
        let namedRow = LiveSceneLines.namedIndex(rows, in: spoken, axisWords: rowWords)
        // "la dernière ligne", "the first column": an ordinal next to the word for the axis.
        let ordinalColumn = namedColumn == nil ? ordinal(spoken, axis: columnWords, count: columns.count) : nil
        let ordinalRow = namedRow == nil ? ordinal(spoken, axis: rowWords, count: rows.count) : nil
        let column = namedColumn ?? ordinalColumn
        let row = namedRow ?? ordinalRow
        let asksMost = !set.isDisjoint(with: ["meilleur", "meilleure", "meilleurs", "best", "highest", "plus", "max", "maximum", "top"])
            && (set.contains("plus") ? !set.isDisjoint(with: ["haut", "haute", "grand", "grande", "eleve", "elevee", "fort"]) : true)

        func value(_ cell: TableGrid.Cell?) -> String? {
            guard let cell, cell.state != .empty, !cell.text.isEmpty else { return nil }
            return spokenValue(cell.text, fr: fr)
        }
        func number(_ cell: TableGrid.Cell?) -> Double? {
            guard let text = cell?.text, cell?.state != .empty else { return nil }
            return Double(text.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.replacingOccurrences(of: ",", with: "."))
        }

        if let r = row, let c = column {
            let cell = table.cell(dataRow: r, dataColumn: c)
            guard let said = value(cell) else {
                return fr ? "La case \(columns[c - 1]) en \(rows[r - 1]) est vide." : "The \(columns[c - 1]) cell for \(rows[r - 1]) is empty."
            }
            return fr ? "\(columns[c - 1]) en \(rows[r - 1]) : \(said)." : "\(columns[c - 1]) for \(rows[r - 1]): \(said)."
        }
        if asksMost, let c = column {
            let best = (1...max(1, rows.count)).compactMap { r in number(table.cell(dataRow: r, dataColumn: c)).map { (r, $0) } }.max { $0.1 < $1.1 }
            if let best, let said = value(table.cell(dataRow: best.0, dataColumn: c)) {
                return fr ? "\(said), en \(rows[best.0 - 1])." : "\(said), in \(rows[best.0 - 1])."
            }
        }
        if asksMost, let r = row {
            let best = (1...max(1, columns.count)).compactMap { c in number(table.cell(dataRow: r, dataColumn: c)).map { (c, $0) } }.max { $0.1 < $1.1 }
            if let best, let said = value(table.cell(dataRow: r, dataColumn: best.0)) {
                return fr ? "\(columns[best.0 - 1]), avec \(said)." : "\(columns[best.0 - 1]), with \(said)."
            }
        }
        let empty = table.dataCells.filter { $0.state == .empty }.count
        if !set.isDisjoint(with: ["vide", "vides", "empty", "blank"]), !set.isDisjoint(with: ["combien", "how", "many", "nombre"]) {
            if fr { return empty == table.dataCells.count ? "Les \(empty) cases sont vides." : "\(empty) \(empty == 1 ? "case est vide" : "cases sont vides")." }
            return empty == table.dataCells.count ? "All \(empty) cells are empty." : "\(empty) \(empty == 1 ? "cell is" : "cells are") empty."
        }
        let asksColumns = !set.isDisjoint(with: ["colonne", "colonnes", "column", "columns"])
        let asksRows = !set.isDisjoint(with: ["ligne", "lignes", "row", "rows", "rangee", "rangees"])
        // "c'est quoi la dernière colonne ?": its name.
        if let c = ordinalColumn, row == nil { return columns[c - 1] + "." }
        if let r = ordinalRow, column == nil { return rows[r - 1] + "." }
        let plural = !set.isDisjoint(with: ["quelles", "quels", "which", "what", "liste", "list"])
        if asksRows, plural, row == nil { return list(rows, fr: fr) }
        if asksColumns, plural, column == nil { return list(columns, fr: fr) }
        return nil
    }

    /// The 1-based index an ordinal next to an axis word names ("la dernière ligne" → the count), nil without one.
    static func ordinal(_ spoken: [String], axis: Set<String>, count: Int) -> Int? {
        for (index, token) in spoken.enumerated() where axis.contains(token) {
            for neighbour in [index - 1, index + 1] where spoken.indices.contains(neighbour) {
                guard let value = TableGrid.ordinal(spoken[neighbour]) else { continue }
                let resolved = value == -1 ? count : value
                if resolved >= 1, resolved <= count { return resolved }
            }
        }
        return nil
    }

    /// "Agentic coding, Agentic terminal coding… jusqu'à Knowledge work."
    static func list(_ names: [String], fr: Bool) -> String? {
        guard let first = names.first, let last = names.last else { return nil }
        if names.count <= 3 { return names.joined(separator: ", ") + "." }
        return fr ? "\(first), \(names[1])… jusqu'à \(last)." : "\(first), \(names[1])… up to \(last)."
    }

    /// "77.2%" → "77,2 %" in French.
    static func spokenValue(_ text: String, fr: Bool) -> String {
        guard fr else { return text }
        var said = text
        if said.contains("."), !said.contains(","), said.allSatisfy({ $0.isNumber || $0 == "." || $0 == "%" || $0 == "-" }) {
            said = said.replacingOccurrences(of: ".", with: ",")
        }
        if said.hasSuffix("%"), !said.hasSuffix(" %") { said = String(said.dropLast()) + " %" }
        return said
    }

    // MARK: The scene map

    static func sceneAnswer(tokens: [String], scene: SceneMap, language: NormalizedUtterance.Language) -> String? {
        let fr = language == .french
        let set = Set(tokens)
        let texts = scene.texts
        let asksWriting = !set.isDisjoint(with: ["ecrit", "ecrite", "dit", "lit", "say", "says", "written", "read", "reads"])
        if asksWriting {
            var block: SceneMap.TextBlock?
            if !set.isDisjoint(with: ["titre", "title"]) { block = scene.title }
            else if !set.isDisjoint(with: ["bas", "bottom"]) { block = texts.max { $0.box.midY < $1.box.midY } }
            else if !set.isDisjoint(with: ["haut", "top"]) { block = texts.min { $0.box.midY < $1.box.midY } }
            else if !set.isDisjoint(with: ["prix", "price"]) { block = texts.first { $0.text.contains("€") || $0.text.contains("$") } }
            if let block { return fr ? "C'est écrit « \(block.text) »." : "It says “\(block.text)”." }
        }
        if !set.isDisjoint(with: ["textes", "texts"]), !set.isDisjoint(with: ["combien", "how", "many"]) {
            let count = texts.count
            let words = ["zéro", "un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix"]
            if fr { return count < words.count ? "\(words[count].capitalizedFirst) texte\(count > 1 ? "s" : "")." : "\(count) textes." }
            return "\(count) text\(count == 1 ? "" : "s")."
        }
        if !set.isDisjoint(with: ["personne", "personnes", "quelqu", "person", "people", "someone", "anyone"]) {
            let people = scene.objects.filter { $0.kind == .person || $0.kind == .face }.count
            if fr { return people == 0 ? "Non, je ne vois personne." : "Oui, \(people == 1 ? "une personne" : "\(people) personnes")." }
            return people == 0 ? "No, I can't see anyone." : "Yes, \(people == 1 ? "one person" : "\(people) people")."
        }
        return nil
    }
}
