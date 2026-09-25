import Foundation

/// The main table of a picture: rows, columns and cells in canvas space (normalised, top-left
/// origin, D1), with the typography and number format of its values. Built by `TableGridBuilder`
/// from OCR words and ruling lines, so it also exists when every data cell is empty.
///
/// Numbering: `Row.index`, `Column.index`, `Cell.row` and `Cell.column` are 0-based over all rows
/// and columns (header rows and label columns included). Everything spoken or shown to the model
/// uses 1-based data rows and columns (headers and labels excluded); -1 means the last one.
public struct TableGrid: Hashable, Codable, Sendable {
    public enum FontWeight: String, Hashable, Codable, Sendable, CaseIterable { case regular, medium, semibold, bold }
    public enum FontDesign: String, Hashable, Codable, Sendable, CaseIterable { case sans, serif, mono, rounded }
    public enum Ruling: String, Hashable, Codable, Sendable { case full, horizontal, vertical, none }
    public enum Source: String, Hashable, Codable, Sendable { case detected, remembered, values }
    public enum Axis: String, Hashable, Codable, Sendable { case row, column }
    /// A name or number resolved against the data rows or columns (1-based data index).
    public enum Match: Hashable, Sendable { case exact(Int), partial(Int), ambiguous([Int]), none }

    /// How the values of a column are written: "80.9%" is 1 decimal with the suffix "%".
    public struct NumberFormat: Hashable, Codable, Sendable {
        public var decimals: Int
        public var decimalSeparator: String
        public var prefix: String
        public var suffix: String
        /// The observed values, when there were some: random values stay inside it.
        public var range: ClosedRange<Double>?

        public init(decimals: Int = 0, decimalSeparator: String = ".", prefix: String = "", suffix: String = "", range: ClosedRange<Double>? = nil) {
            self.decimals = max(0, min(decimals, 6))
            self.decimalSeparator = decimalSeparator
            self.prefix = prefix
            self.suffix = suffix
            self.range = range
        }

        /// The format shared by most of `texts` ("80.9%" -> 1 decimal, suffix "%"; "87,3" -> ","); nil when
        /// fewer than half of them are numbers.
        public static func infer(from texts: [String]) -> NumberFormat? {
            var parsed: [(value: Double, decimals: Int, separator: String, prefix: String, suffix: String)] = []
            for raw in texts {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var start = text.startIndex
                while start < text.endIndex, !text[start].isNumber, text[start] != "-" && text[start] != "−" { start = text.index(after: start) }
                var end = text.endIndex
                while end > start, !text[text.index(before: end)].isNumber { end = text.index(before: end) }
                guard start < end else { continue }
                let core = String(text[start..<end]).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: " ", with: "")
                let separator = core.contains(",") && !core.contains(".") ? "," : "."
                // A comma next to a point is a thousands separator ("1,234.5").
                let plain = separator == "," ? core.replacingOccurrences(of: ",", with: ".") : core.replacingOccurrences(of: ",", with: "")
                guard let value = Double(plain) else { continue }
                let decimals = plain.firstIndex(of: ".").map { plain.distance(from: $0, to: plain.endIndex) - 1 } ?? 0
                parsed.append((value, decimals, separator, String(text[text.startIndex..<start]), String(text[end..<text.endIndex])))
            }
            let meaningful = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            guard !parsed.isEmpty, parsed.count * 2 >= meaningful else { return nil }
            /// The most frequent value; ties go to the first seen, so the result never depends on hashing.
            func mostCommon<T: Hashable>(_ values: [T]) -> T {
                var counts: [T: Int] = [:]
                for value in values { counts[value, default: 0] += 1 }
                var best = values[0]
                for value in values where counts[value, default: 0] > counts[best, default: 0] { best = value }
                return best
            }
            let values = parsed.map(\.value)
            return NumberFormat(decimals: mostCommon(parsed.map(\.decimals)), decimalSeparator: mostCommon(parsed.map(\.separator)),
                                prefix: mostCommon(parsed.map(\.prefix)), suffix: mostCommon(parsed.map(\.suffix)),
                                range: values.min()!...values.max()!)
        }

        /// `value` written in this format ("80.9%").
        public func format(_ value: Double) -> String {
            let number = String(format: "%.\(decimals)f", value)
            let written = decimalSeparator == "." ? number : number.replacingOccurrences(of: ".", with: decimalSeparator)
            return prefix + written + suffix
        }
    }

    /// Typography of values, measured on the picture (TableStyleEstimator) or remembered.
    public struct Style: Hashable, Codable, Sendable {
        /// Font size / canvas height, the same unit as `TextElement.relativeSize`.
        public var relativeSize: Double
        public var color: PSColor
        public var weight: FontWeight
        public var design: FontDesign
        public var alignment: TextElement.Alignment

        public init(relativeSize: Double, color: PSColor, weight: FontWeight = .regular, design: FontDesign = .sans, alignment: TextElement.Alignment = .center) {
            self.relativeSize = relativeSize
            self.color = color
            self.weight = weight
            self.design = design
            self.alignment = alignment
        }

        /// D5 grammar the rasterizer resolves: "SFProDigits-Regular", "SFProSerif-Bold", "SFMono-Medium", "SFProRounded-Semibold".
        public var fontName: String {
            let family: String
            switch design {
            case .sans: family = "SFProDigits"
            case .serif: family = "SFProSerif"
            case .mono: family = "SFMono"
            case .rounded: family = "SFProRounded"
            }
            let face: String
            switch weight {
            case .regular: face = "Regular"
            case .medium: face = "Medium"
            case .semibold: face = "Semibold"
            case .bold: face = "Bold"
            }
            return family + "-" + face
        }
    }

    public struct Column: Hashable, Codable, Sendable {
        public var index: Int
        public var rect: PSRect
        /// The header as printed, lines joined with a space ("Gemini 3.5 Pro"); "" for a label column without one.
        public var header: String
        /// The row-label column(s) on the left.
        public var isLabel: Bool
        public var style: Style?
        public var format: NumberFormat?

        public init(index: Int, rect: PSRect, header: String, isLabel: Bool = false, style: Style? = nil, format: NumberFormat? = nil) {
            self.index = index
            self.rect = rect
            self.header = header
            self.isLabel = isLabel
            self.style = style
            self.format = format
        }
    }

    public struct Row: Hashable, Codable, Sendable {
        public var index: Int
        public var rect: PSRect
        /// The row label as printed; a label on several lines keeps them separated by "\n".
        public var label: String
        public var isHeader: Bool

        public init(index: Int, rect: PSRect, label: String, isHeader: Bool = false) {
            self.index = index
            self.rect = rect
            self.label = label
            self.isHeader = isHeader
        }
    }

    public enum CellKind: String, Hashable, Codable, Sendable { case corner, header, label, data }
    /// empty: nothing printed or laid over; placeholder: "—", "–", "-", "n/a"; printed: pixels of text
    /// (OCR or the ink check); layer: a Picshop text layer sits in it (`overlaying`).
    public enum CellState: String, Hashable, Codable, Sendable { case empty, placeholder, printed, layer }

    public struct Cell: Hashable, Codable, Sendable {
        /// 0-based over all rows and columns.
        public var row: Int
        public var column: Int
        public var rect: PSRect
        /// Where a value goes: the rect inset past the rules and the padding.
        public var contentRect: PSRect
        public var text: String
        /// Printed words (a tight erase uses them).
        public var wordBoxes: [PSRect]
        public var kind: CellKind
        public var state: CellState
        /// The Picshop text layer over the cell, when there is one.
        public var layerID: UUID?

        public init(row: Int, column: Int, rect: PSRect, contentRect: PSRect, text: String = "", wordBoxes: [PSRect] = [],
                    kind: CellKind, state: CellState = .empty, layerID: UUID? = nil) {
            self.row = row
            self.column = column
            self.rect = rect
            self.contentRect = contentRect
            self.text = text
            self.wordBoxes = wordBoxes
            self.kind = kind
            self.state = state
            self.layerID = layerID
        }
    }

    /// FNV-1a hex of the rounded geometry (deterministic, `makeID`).
    public var id: String
    public var bounds: PSRect
    /// A line above the header that names the table ("Benchmark results"); never a header.
    public var title: String?
    public var rows: [Row]
    public var columns: [Column]
    /// Row-major.
    public var cells: [Cell]
    public var headerRowCount: Int
    public var labelColumnCount: Int
    public var ruling: Ruling
    public var bodyStyle: Style?
    public var confidence: Double
    public var source: Source

    public init(id: String, bounds: PSRect, title: String?, rows: [Row], columns: [Column], cells: [Cell], headerRowCount: Int,
                labelColumnCount: Int, ruling: Ruling, bodyStyle: Style?, confidence: Double, source: Source) {
        self.id = id
        self.bounds = bounds
        self.title = title
        self.rows = rows
        self.columns = columns
        self.cells = cells
        self.headerRowCount = headerRowCount
        self.labelColumnCount = labelColumnCount
        self.ruling = ruling
        self.bodyStyle = bodyStyle
        self.confidence = confidence
        self.source = source
    }

    /// The deterministic id of a geometry: bounds and every row and column edge, rounded to 0.1%.
    public static func makeID(bounds: PSRect, rows: [Row], columns: [Column]) -> String {
        var parts = [bounds.minX, bounds.minY, bounds.width, bounds.height].map { StableHash.token($0, decimals: 3) }
        parts += rows.flatMap { [$0.rect.minY, $0.rect.maxY] }.map { StableHash.token($0, decimals: 3) }
        parts.append("|")
        parts += columns.flatMap { [$0.rect.minX, $0.rect.maxX] }.map { StableHash.token($0, decimals: 3) }
        return StableHash.hex(parts.joined(separator: ","))
    }

    // MARK: Data addressing (1-based, headers and labels excluded)

    public var dataRows: [Row] { rows.filter { !$0.isHeader } }
    public var dataColumns: [Column] { columns.filter { !$0.isLabel } }
    public var dataCells: [Cell] { cells.filter { $0.kind == .data } }

    /// 1-based data address; -1 is the last row or column.
    public func cell(dataRow: Int, dataColumn: Int) -> Cell? {
        let rows = dataRows, columns = dataColumns
        let r = dataRow == -1 ? rows.count : dataRow
        let c = dataColumn == -1 ? columns.count : dataColumn
        guard r >= 1, r <= rows.count, c >= 1, c <= columns.count else { return nil }
        let row = rows[r - 1].index, column = columns[c - 1].index
        return cells.first { $0.row == row && $0.column == column }
    }

    /// 1-based data address of a data cell.
    public func dataAddress(of cell: Cell) -> (row: Int, column: Int)? {
        guard cell.kind == .data,
              let r = dataRows.firstIndex(where: { $0.index == cell.row }),
              let c = dataColumns.firstIndex(where: { $0.index == cell.column }) else { return nil }
        return (r + 1, c + 1)
    }

    /// Data cells with nothing in them (`.empty` only; placeholders are printed content).
    public var emptyDataCells: [Cell] { dataCells.filter { $0.state == .empty } }

    /// The measured style of a 1-based data column, else the table's body style.
    public func style(forDataColumn column: Int) -> Style? {
        let columns = dataColumns
        let c = column == -1 ? columns.count : column
        guard c >= 1, c <= columns.count else { return bodyStyle }
        return columns[c - 1].style ?? bodyStyle
    }

    /// When nothing was measured or remembered: a third of the median data-row height, #1C1C1E, regular, centred.
    public var fallbackStyle: Style {
        let heights = dataRows.map(\.rect.height).filter { $0 > 0 }.sorted()
        let median = heights.isEmpty ? 0.06 : heights[heights.count / 2]
        return Style(relativeSize: max(0.006, 0.33 * median), color: PSColor(hex: "#1C1C1E") ?? .black)
    }

    /// The table fills most of the picture: a screenshot of a table (D2), with no subject to cut out.
    public var coversPicture: Bool { bounds.area >= 0.25 }

    /// Data headers (columns) or row labels (rows), in order.
    public func names(_ axis: Axis) -> [String] {
        switch axis {
        case .row: return dataRows.map(\.label)
        case .column: return dataColumns.map(\.header)
        }
    }

    // MARK: Name matching

    /// Resolves what the user named against the data rows or columns.
    /// Accent/case/hyphen folding ("GPT-6" == "gpt -6" == "gpt 6"), spoken numbers ("six" == 6), an exact
    /// token-set match first ("Opus 5" never matches "Opus 5.5"), every label line counts, ordinals and "dernière".
    public func match(_ ref: TableEditSpec.Ref, on axis: Axis) -> Match {
        let names = self.names(axis)
        switch ref {
        case .index(let index):
            if index == -1, !names.isEmpty { return .exact(names.count) }
            return index >= 1 && index <= names.count ? .exact(index) : .none
        case .name(let spoken):
            let said = Self.foldedTokens(spoken)
            // "la colonne Opus 5" names "Opus 5": the words that only say which kind of thing go.
            let meaningful = said.filter { !Self.referenceWords.contains($0) }
            // Words that only say what kind of thing it is ("la colonne", "the table") name none of them.
            let wanted = Set(meaningful)
            guard !wanted.isEmpty else { return .none }
            var exact: [Int] = [], partial: [Int] = []
            let variants = names.map { name in ([name] + name.split(separator: "\n").map(String.init)).map { Set(Self.foldedTokens($0)) }.filter { !$0.isEmpty } }
            for (offset, tokenSets) in variants.enumerated() {
                if tokenSets.contains(wanted) { exact.append(offset + 1) }
                else if tokenSets.contains(where: { wanted.isSubset(of: $0) }) { partial.append(offset + 1) }
            }
            if exact.count == 1 { return .exact(exact[0]) }
            if exact.count > 1 { return .ambiguous(exact) }
            if partial.count == 1 { return .partial(partial[0]) }
            if partial.count > 1 { return .ambiguous(partial) }
            // "la dernière", "3e colonne", "the second row", "colonne 3".
            if wanted.count == 1, let token = wanted.first {
                if let ordinal = Self.ordinal(token) {
                    let index = ordinal == -1 ? names.count : ordinal
                    return index >= 1 && index <= names.count ? .exact(index) : .none
                }
                // "colonne 3", "row 2": a number is an index only next to the word for the axis.
                if let number = Int(token), number >= 1, number <= names.count, !Set(said).isDisjoint(with: Self.axisWords) { return .exact(number) }
            }
            if wanted.count == 2, wanted.contains("avant"), wanted.contains("derniere") || wanted.contains("dernier"), names.count >= 2 {
                return .exact(names.count - 1)
            }
            // Heard slightly wrong ("Jémini", "Astre"): one letter off in a long word; numbers never.
            var close: [Int] = []
            for (offset, tokenSets) in variants.enumerated() where tokenSets.contains(where: { set in
                wanted.allSatisfy { token in set.contains(token) || set.contains { Self.isNear(token, $0) } }
            }) {
                close.append(offset + 1)
            }
            if close.count == 1 { return .partial(close[0]) }
            if close.count > 1 { return .ambiguous(close) }
            return .none
        }
    }

    /// Words that say what kind of thing is named, not which one.
    static let referenceWords: Set<String> = [
        "la", "le", "les", "l", "de", "du", "des", "d", "the", "of", "a", "au", "aux", "en", "sur", "pour", "dans", "on", "in", "for",
        "colonne", "colonnes", "column", "columns", "ligne", "lignes", "row", "rows", "rangee", "rangees", "case", "cases", "cellule",
        "cellules", "cell", "cells", "col", "table", "tables", "tableau", "tableaux", "grille", "grid",
    ]

    /// The words for a row or a column.
    static let axisWords: Set<String> = ["colonne", "colonnes", "column", "columns", "col", "ligne", "lignes", "row", "rows", "rangee", "rangees"]

    /// Ordinal words (folded) as a 1-based index; -1 = the last.
    public static func ordinal(_ token: String) -> Int? {
        let table: [String: Int] = [
            "premiere": 1, "premier": 1, "1ere": 1, "1er": 1, "first": 1, "1st": 1,
            "deuxieme": 2, "seconde": 2, "second": 2, "2e": 2, "2eme": 2, "2nd": 2,
            "troisieme": 3, "third": 3, "3e": 3, "3eme": 3, "3rd": 3,
            "quatrieme": 4, "fourth": 4, "4e": 4, "4eme": 4, "4th": 4,
            "cinquieme": 5, "fifth": 5, "5e": 5, "5eme": 5, "5th": 5,
            "sixieme": 6, "sixth": 6, "6e": 6, "6eme": 6, "6th": 6,
            "septieme": 7, "seventh": 7, "7e": 7, "7eme": 7, "7th": 7,
            "huitieme": 8, "eighth": 8, "8e": 8, "8eme": 8, "8th": 8,
            "neuvieme": 9, "ninth": 9, "9e": 9, "9eme": 9, "9th": 9,
            "dixieme": 10, "tenth": 10, "10e": 10, "10eme": 10, "10th": 10,
            "derniere": -1, "dernier": -1, "last": -1,
        ]
        return table[token]
    }

    /// Two words one edit apart (two for long words), letters only: what speech recognition gets wrong.
    static func isNear(_ a: String, _ b: String) -> Bool {
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 2,
              !a.contains(where: \.isNumber), !b.contains(where: \.isNumber) else { return false }
        let limit = min(a.count, b.count) >= 8 ? 2 : 1
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count] <= limit
    }

    /// Spoken numbers as digits, so "GPT six" is "GPT 6" and "cinq point cinq" is "5.5".
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "sept": "7", "huit": "8",
        "neuf": "9", "dix": "10", "onze": "11", "douze": "12",
    ]

    /// Lower case, no accents, hyphens and slashes as spaces, decimal commas as points, spoken numbers
    /// as digits ("cinq point cinq" -> "5.5").
    public static func foldedTokens(_ text: String) -> [String] {
        var folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for separator in ["-", "‐", "–", "—", "_", "/", "(", ")", ":", "·", "\n", "'", "’", "\"", "«", "»", "?", "!", ";"] {
            folded = folded.replacingOccurrences(of: separator, with: " ")
        }
        var tokens: [String] = folded.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { token in
            var word = String(token)
            if word.contains(","), word.allSatisfy({ $0.isNumber || $0 == "," }) { word = word.replacingOccurrences(of: ",", with: ".") }
            while word.hasSuffix(".") || word.hasSuffix(",") { word.removeLast() }
            return numberWords[word] ?? word
        }.filter { !$0.isEmpty }
        // "5 point 5", "5 virgule 5", "five dot five".
        var index = 1
        while index + 1 < tokens.count {
            if ["point", "virgule", "dot"].contains(tokens[index]), Int(tokens[index - 1]) != nil, Int(tokens[index + 1]) != nil {
                tokens[index - 1] = tokens[index - 1] + "." + tokens[index + 1]
                tokens.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }
        return tokens
    }

    // MARK: Picshop layers

    /// Picshop text layers laid over the grid: by `layer.group` row and column, else by centre in a
    /// data cell rect. A printed cell stays printed (its layer id is recorded); others become `.layer`.
    public func overlaying(_ layers: [Layer]) -> TableGrid {
        var grid = self
        let rows = dataRows, columns = dataColumns
        for layer in layers where layer.isVisible {
            guard let element = layer.textElement else { continue }
            var target: Int?
            if let group = layer.group, group.kind == .tableCells, let r = group.row, let c = group.column,
               r >= 1, r <= rows.count, c >= 1, c <= columns.count {
                target = grid.cells.firstIndex { $0.row == rows[r - 1].index && $0.column == columns[c - 1].index }
            } else if layer.group == nil {
                target = grid.cells.firstIndex { $0.kind == .data && $0.rect.contains(element.center) }
            }
            guard let index = target else { continue }
            grid.cells[index].layerID = layer.id
            if grid.cells[index].state != .printed {
                grid.cells[index].state = .layer
                grid.cells[index].text = element.text
            }
        }
        return grid
    }
}
