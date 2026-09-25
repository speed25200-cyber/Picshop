import Foundation
import PicshopCore

/// The grounding lines of `<editor_state>`, written by code from what the editor knows, so a small
/// model names what it acts on instead of guessing: the table, the scene map's ids, the last action.
/// Deterministic and English; facts, never orders. Printed text is data: quoted, one line, cut short,
/// and never read as an instruction. Boxes are in the model's own grid, 0–1000 with a top-left origin
/// (`box(_:)`), the same grid as `point`.
///
/// ```
/// table: 9 rows x 5 cols, title "Model benchmark"
/// cols: 1 Opus 5.5 | 2 Opus 5 | 3 Fable 5.1 | 4 Gemini 3.5 Pro | 5 GPT-6 Astra
/// rows: 1 Agentic coding | 2 Agentic terminal c… | … | 9 Knowledge work
/// cells: 44 empty, 1 filled by you (r6c3 "1"), 0 printed
/// empty at: r1-5 c1-5; r6 c1-2,4-5; r7-9 c1-5
/// texts: t1 "SOLDES D'ÉTÉ" 120,50,880,140 title light bold | t2 "-50% sur tout" 300,160,700,200 body light
/// objects: o1 person 300,240,700,940
/// free: f1 700,220,980,400 light | f2 300,930,980,990 light
/// last: fillCells text=1 cells=empty → applied, filled 44, empty left 0 (grammar)
/// ```
public enum LiveSceneLines {
    public static let lastBudget = LocalLivePrompt.Budgets.lastLine
    /// Headers and labels as the table line prints them.
    static let headerLimit = 16, labelLimit = 18
    /// A quoted text in the texts line.
    static let quoteLimit = 24

    // MARK: Table

    /// The `table:`, `cols:`, `rows:` and `cells:` lines, plus `empty at:` when only part of the table is
    /// empty (headers cut at 16 characters, labels at 18), at most `budget` characters in all. Long lists
    /// keep their first and last names around a "…".
    public static func table(_ grid: TableGrid, budget: Int = LocalLivePrompt.Budgets.tableLines) -> [String] {
        let rows = grid.dataRows, columns = grid.dataColumns
        var head = "table: \(rows.count) rows x \(columns.count) cols"
        if let title = grid.title.map(oneLine), !title.isEmpty { head += ", title \"\(cut(title, 32))\"" }
        let columnNames = columns.enumerated().map { "\($0.offset + 1) \(cutName(oneLine($0.element.header), headerLimit))" }
        let rowNames = rows.enumerated().map { "\($0.offset + 1) \(cutName(oneLine($0.element.label), labelLimit))" }
        let cells = cellsLine(grid)
        var runs = emptyRunsLine(grid)
        var keptRows = rowNames.count, keptColumns = columnNames.count

        func render() -> [String] {
            var lines = [head, "cols: " + elided(columnNames, keep: keptColumns), "rows: " + elided(rowNames, keep: keptRows), cells]
            if let runs { lines.append(runs) }
            return lines
        }
        func length(_ lines: [String]) -> Int { lines.joined(separator: "\n").count }

        var lines = render()
        while length(lines) > budget {
            if runs != nil {
                runs = nil
            } else if keptRows > 3 {
                keptRows -= 1
            } else if keptColumns > 3 {
                keptColumns -= 1
            } else {
                break
            }
            lines = render()
        }
        if length(lines) > budget {
            // Still too long (very long names): every line shares the room.
            let room = max(24, budget / max(1, lines.count) - 1)
            lines = lines.map { cut($0, room) }
        }
        return lines
    }

    /// "cells: 44 empty, 1 filled by you (r6c3 "1"), 0 printed".
    static func cellsLine(_ grid: TableGrid) -> String {
        let data = grid.dataCells
        let empty = data.filter { $0.state == .empty }.count
        let layers = data.filter { $0.state == .layer }
        let printed = data.filter { $0.state == .printed }.count
        let placeholders = data.filter { $0.state == .placeholder }.count
        var parts = ["\(empty) empty"]
        if !layers.isEmpty {
            var part = "\(layers.count) filled by you"
            let texts = Set(layers.map { oneLine($0.text) })
            if layers.count <= 3 {
                let named = layers.compactMap { cell -> String? in
                    guard let address = grid.dataAddress(of: cell) else { return nil }
                    return "r\(address.row)c\(address.column) \"\(cut(oneLine(cell.text), 12))\""
                }
                if !named.isEmpty { part += " (" + named.joined(separator: ", ") + ")" }
            } else if texts.count == 1, let only = texts.first {
                part += " (all \"\(cut(only, 12))\")"
            }
            parts.append(part)
        }
        parts.append("\(printed) printed")
        if placeholders > 0 { parts.append("\(placeholders) dashes") }
        return "cells: " + parts.joined(separator: ", ")
    }

    /// "empty at: r1-5 c1-5; r6 c1-2,4-5; r7-9 c1-5": where the empty cells are, when only some are.
    /// Nil when every data cell is empty, none is, or the runs would not read in one short line.
    static func emptyRunsLine(_ grid: TableGrid) -> String? {
        let rows = grid.dataRows, columns = grid.dataColumns
        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        let data = grid.dataCells
        let empty = data.filter { $0.state == .empty }.count
        guard empty > 0, empty < data.count else { return nil }
        var perRow: [String] = []
        for rowIndex in 1...rows.count {
            var emptyColumns: [Int] = []
            for columnIndex in 1...columns.count where grid.cell(dataRow: rowIndex, dataColumn: columnIndex)?.state == .empty {
                emptyColumns.append(columnIndex)
            }
            perRow.append(emptyColumns.isEmpty ? "" : "c" + ranges(emptyColumns))
        }
        var groups: [String] = []
        var start = 0
        while start < perRow.count {
            var end = start
            while end + 1 < perRow.count, perRow[end + 1] == perRow[start] { end += 1 }
            if !perRow[start].isEmpty {
                let span = start == end ? "r\(start + 1)" : "r\(start + 1)-\(end + 1)"
                groups.append("\(span) \(perRow[start])")
            }
            start = end + 1
        }
        let line = "empty at: " + groups.joined(separator: "; ")
        return line.count <= 120 ? line : nil
    }

    /// [1, 2, 4, 5] -> "1-2,4-5".
    static func ranges(_ values: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < values.count {
            var end = index
            while end + 1 < values.count, values[end + 1] == values[end] + 1 { end += 1 }
            parts.append(index == end ? "\(values[index])" : "\(values[index])-\(values[end])")
            index = end + 1
        }
        return parts.joined(separator: ",")
    }

    /// `table_focus:` the values of the row or column the words name ("que vaut Opus 5 ?"), or of the one
    /// cell when they name both, so a question is answered without a tool; nil when the words name none.
    /// Names match as whole words in order ("Opus 5" never stands for "Opus 5.5").
    public static func tableFocus(_ grid: TableGrid, words: String, budget: Int = LocalLivePrompt.Budgets.tableFocus) -> String? {
        let spoken = TableGrid.foldedTokens(words)
        guard !spoken.isEmpty else { return nil }
        let column = namedIndex(grid.names(.column), in: spoken, axisWords: ["colonne", "column", "col"])
        let row = namedIndex(grid.names(.row), in: spoken, axisWords: ["ligne", "row", "rangee"])
        func value(_ cell: TableGrid.Cell?) -> String {
            guard let cell else { return "?" }
            switch cell.state {
            case .empty: return "empty"
            case .layer: return "\"\(cut(oneLine(cell.text), 12))\" (yours)"
            case .printed, .placeholder: return cell.text.isEmpty ? "printed" : "\"\(cut(oneLine(cell.text), 12))\""
            }
        }
        let line: String
        switch (row, column) {
        case let (r?, c?):
            let names = (cutName(oneLine(grid.names(.row)[r - 1]), labelLimit), cutName(oneLine(grid.names(.column)[c - 1]), headerLimit))
            line = "table_focus: r\(r)c\(c) (\(names.0), \(names.1)) = " + value(grid.cell(dataRow: r, dataColumn: c))
        case let (nil, c?):
            let cells = (1...max(1, grid.dataRows.count)).map { grid.cell(dataRow: $0, dataColumn: c) }
            let header = cutName(oneLine(grid.names(.column)[c - 1]), headerLimit)
            if cells.allSatisfy({ $0?.state == .empty }) {
                line = "table_focus: col \(c) \(header): all \(cells.count) empty"
            } else {
                line = "table_focus: col \(c) \(header) = " + cells.enumerated().map { "r\($0.offset + 1) \(value($0.element))" }.joined(separator: " | ")
            }
        case let (r?, nil):
            let cells = (1...max(1, grid.dataColumns.count)).map { grid.cell(dataRow: r, dataColumn: $0) }
            let label = cut(oneLine(grid.names(.row)[r - 1]), labelLimit)
            if cells.allSatisfy({ $0?.state == .empty }) {
                line = "table_focus: row \(r) \(label): all \(cells.count) empty"
            } else {
                line = "table_focus: row \(r) \(label) = " + cells.enumerated().map { "c\($0.offset + 1) \(value($0.element))" }.joined(separator: " | ")
            }
        case (nil, nil):
            return nil
        }
        return cut(line, budget)
    }

    /// The 1-based index of the name the words spell out, whole words in order, the longest name first
    /// ("opus 5.5" before "opus 5"); "colonne 3" / "row 2" by number. Nil when none or a tie.
    static func namedIndex(_ names: [String], in spoken: [String], axisWords: Set<String>) -> Int? {
        var best: (index: Int, length: Int)?
        var tie = false
        for (offset, name) in names.enumerated() {
            let variants = ([name] + name.split(separator: "\n").map(String.init)).map(TableGrid.foldedTokens).filter { !$0.isEmpty }
            guard let length = variants.filter({ contains(spoken, $0) }).map(\.count).max() else { continue }
            if let current = best {
                if length > current.length { best = (offset + 1, length); tie = false } else if length == current.length { tie = true }
            } else {
                best = (offset + 1, length)
            }
        }
        if let best, !tie { return best.index }
        // "colonne 3", "ligne 2": a number right after the axis word.
        for (index, token) in spoken.enumerated().dropLast() where axisWords.contains(token) {
            if let number = Int(spoken[index + 1]), number >= 1, number <= names.count { return number }
        }
        return nil
    }

    /// Whether `sequence` appears in `tokens`, contiguous and in order.
    static func contains(_ tokens: [String], _ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= tokens.count else { return false }
        for start in 0...(tokens.count - sequence.count) where Array(tokens[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    // MARK: Scene map

    /// The `texts:`, `objects:` and `free:` lines: text blocks (id, "text", box, size class, colour class,
    /// weight), objects and people (id, label, box), free areas (id, box, background). Blocks inside the
    /// table are left to the table lines; the smallest and least confident go first when the budget is
    /// tight, the title last.
    public static func scene(_ map: SceneMap, budget: Int = LocalLivePrompt.Budgets.sceneLines) -> [String] {
        guard budget > 0 else { return [] }
        let table = map.table
        var texts = map.texts.filter { block in
            if [.tableHeader, .tableLabel, .tableCell].contains(block.role) { return false }
            if let table, !block.isLayer, table.bounds.contains(block.box.center) { return false }
            return true
        }
        // The order they give way in: least useful last.
        texts.sort { priority($0, title: map.title?.id) > priority($1, title: map.title?.id) }
        var objects = map.objects.sorted { $0.box.area > $1.box.area }
        var areas = map.freeAreas

        func render() -> [String] {
            var lines: [String] = []
            if !texts.isEmpty {
                let ordered = texts.sorted { readingOrder($0.box, $1.box) }
                lines.append("texts: " + ordered.map(textItem).joined(separator: " | "))
            }
            if !objects.isEmpty { lines.append("objects: " + objects.map { "\($0.id) \(cut(oneLine($0.label), 16)) \(box($0.box))" }.joined(separator: " | ")) }
            if !areas.isEmpty { lines.append("free: " + areas.map(areaItem).joined(separator: " | ")) }
            return lines
        }
        var lines = render()
        while lines.joined(separator: "\n").count > budget {
            if areas.count > 1 {
                areas.removeLast()
            } else if texts.count > 1 {
                texts.removeLast()
            } else if objects.count > 1 {
                objects.removeLast()
            } else if !areas.isEmpty {
                areas.removeLast()
            } else if !objects.isEmpty, !texts.isEmpty {
                objects.removeLast()
            } else {
                break
            }
            lines = render()
        }
        if lines.joined(separator: "\n").count > budget {
            let room = max(20, budget / max(1, lines.count) - 1)
            lines = lines.map { cut($0, room) }
        }
        return lines
    }

    /// How much a block matters to the model: the title first, then larger and surer text, the user's own layers high.
    static func priority(_ block: SceneMap.TextBlock, title: String?) -> Double {
        if block.id == title { return 100 }
        let size: Double
        switch block.sizeClass {
        case .title: size = 5
        case .large: size = 4
        case .body: size = 3
        case .small: size = 2
        case .tiny: size = 1
        }
        return size + (block.isLayer ? 3 : 0) + block.confidence
    }

    static func readingOrder(_ a: PSRect, _ b: PSRect) -> Bool {
        if abs(a.minY - b.minY) > 0.02 { return a.minY < b.minY }
        return a.minX < b.minX
    }

    /// `t1 "SOLDES D'ÉTÉ" 120,50,880,140 title light bold`.
    static func textItem(_ block: SceneMap.TextBlock) -> String {
        var item = "\(block.id) \"\(cut(oneLine(block.text), quoteLimit))\" \(box(block.box)) \(block.sizeClass.rawValue)"
        if let color = block.colorClass { item += " " + color }
        if let weight = block.style?.weight, weight != .regular { item += " " + weight.rawValue }
        return item
    }

    /// `f1 700,220,980,400 light`.
    static func areaItem(_ area: SceneMap.FreeArea) -> String {
        var item = "\(area.id) \(box(area.box))"
        if let background = area.background { item += " " + SceneMap.colorClass(of: background) }
        return item
    }

    /// What kind of picture it is, for the `scene:` line: "table screenshot", "screenshot", "document"; nil for a photo.
    public static func kind(_ state: LiveEditorState) -> String? {
        if state.table?.coversPicture == true || (state.sceneMap?.kind == .table && state.sceneMap?.table?.coversPicture != false) {
            return "table screenshot"
        }
        switch state.sceneMap?.kind {
        case .table?: return "table"
        case .screenshot?: return "screenshot"
        case .document?: return "document"
        case .photo?, nil: return nil
        }
    }

    // MARK: Last action

    /// The `last:` line: the action with its key arguments, what came of it and the lane,
    /// "fillCells text=1 cells=empty → applied, filled 44, empty left 0 (grammar)".
    /// `scene`: the map the model reads now. A printed block a step rewrote is no longer there: the line names
    /// the layer that replaced it ("ref=t2→l2"), or says it is gone, so copying last: never names a dead id.
    public static func last(_ record: LiveActionRecord, budget: Int = lastBudget, scene: SceneMap? = nil) -> String {
        let outcome = outcome(of: record.results)
        let lane = " (\(record.source.rawValue))"
        var argumentLimit = 8
        while true {
            let steps = record.steps.prefix(3).enumerated().map { index, raw -> String in
                step(of: raw, limit: argumentLimit, ref: liveRef(raw, created: record.results.first { $0.index == index }?.createdRef, scene: scene))
            }.joined(separator: " + ") + (record.steps.count > 3 ? " + …" : "")
            let line = "last: " + steps + " → " + outcome + lane
            if line.count <= budget || argumentLimit == 0 { return cut(line, budget) }
            argumentLimit -= 1
        }
    }

    /// The ref a last: step shows: "t2→l2" when the step wrote a new layer in place of a printed block, "l1"
    /// for the layer an addText made, "t2(gone)" when the block is no longer on the map; else the ref.
    static func liveRef(_ raw: RawIntentStep, created: String?, scene: SceneMap?) -> String? {
        if let created {
            guard let ref = raw.ref, ref != created else { return created }
            return "\(ref)→\(created)"
        }
        guard let ref = raw.ref, let scene, let parsed = SceneRef(ref), parsed.isText, scene.block(parsed) == nil else { return raw.ref }
        return ref + "(gone)"
    }

    /// "fillCells text=1 cells=empty": the action and up to `limit` key arguments, in a fixed order.
    static func step(of raw: RawIntentStep, limit: Int = 8, ref: String? = nil) -> String {
        var arguments: [String] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let text = oneLine(value)
            arguments.append("\(key)=" + (text.contains(" ") || text.contains("=") ? "\"\(cut(text, 20))\"" : cut(text, 20)))
        }
        func number(_ value: Double?) -> String? { value.map(RawIntentStep.number) }
        add("ref", ref ?? raw.ref)
        add("target", raw.target)
        add("text", raw.text)
        add("parameter", raw.parameter)
        add("amount", number(raw.amount))
        add("look", raw.look)
        add("column", raw.column)
        add("row", raw.row)
        add("cells", raw.cells)
        add("values", raw.values)
        add("min", number(raw.min))
        add("max", number(raw.max))
        add("decimals", raw.decimals.map(String.init))
        add("size", raw.size)
        add("weight", raw.weight)
        add("align", raw.align)
        add("match", raw.match)
        add("color", raw.color)
        add("placement", raw.placement)
        if let region = raw.box { add("box", box(region)) }
        if let point = raw.point { add("point", "\(Int((point.x * 1_000).rounded())),\(Int((point.y * 1_000).rounded()))") }
        add("degrees", number(raw.degrees))
        add("aspect", raw.aspect)
        return ([raw.action] + arguments.prefix(limit)).joined(separator: " ")
    }

    /// "applied, filled 44, empty left 0" · "failed[no_subject]" · "applied, verify failed 1/3".
    static func outcome(of results: [LiveStepResult]) -> String {
        guard !results.isEmpty else { return "nothing ran" }
        if let failed = results.first(where: { $0.status != .applied && $0.status != .skipped && $0.status != .queued }) {
            let status = failed.status.rawValue + (failed.reason.map { "[\($0.rawValue)]" } ?? "")
            let applied = results.filter { $0.status == .applied }.count
            return applied > 0 ? "\(applied) applied, then \(failed.action.rawValue) \(status)" : status
        }
        var parts = ["applied"]
        if let report = results.lazy.compactMap(\.report).first { parts.append(reportFacts(report)) }
        if let check = results.lazy.compactMap(\.verification).first(where: { $0.status == .failed }) { parts.append(check.summary.components(separatedBy: ":").first ?? "verify failed") }
        return parts.joined(separator: ", ")
    }

    /// "filled 44, kept 1, empty left 0" (cleared / highlighted for the other table steps).
    public static func reportFacts(_ report: TableEditReport, kept: Bool = true) -> String {
        let verb: String
        switch report.action {
        case .clearCells: verb = "cleared"
        case .highlightCells: verb = "highlighted"
        default: verb = "filled"
        }
        var facts = "\(verb) \(report.changed)"
        if kept { facts += ", kept \(report.kept)" }
        facts += ", empty left \(report.emptyLeft)"
        return facts
    }

    // MARK: Pieces

    /// A normalised rect in the model's 0–1000 grid: "120,40,380,90" (x1,y1,x2,y2).
    public static func box(_ rect: PSRect) -> String {
        let corners = [rect.minX, rect.minY, rect.maxX, rect.maxY].map { Int((min(max($0, 0), 1) * 1_000).rounded()) }
        return corners.map(String.init).joined(separator: ",")
    }

    /// One line, no tag, no double quote (it closes the quoted text).
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    /// At most `limit` characters, "…" marking a cut.
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(max(0, limit))) }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A row or column name cut on a word boundary ("Novel problem…", "Graduate-level…"), so what the model
    /// copies begins the real name word for word; one long word is cut where it must.
    static func cutName(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return cut(text, limit) }
        let head = String(text.prefix(limit - 1))
        guard let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= 3 else { return cut(text, limit) }
        return String(head[..<space]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "1 A | 2 B | … | 9 I": the first `keep - 1` names, "…", the last.
    static func elided(_ names: [String], keep: Int) -> String {
        guard names.count > keep, keep >= 2 else { return names.joined(separator: " | ") }
        return (names.prefix(keep - 1) + ["…", names[names.count - 1]]).joined(separator: " | ")
    }
}
