import Foundation

/// What a table step (fillCells, clearCells, highlightCells) acts on and writes. `EditIntent.table`.
public struct TableEditSpec: Hashable, Codable, Sendable {
    public enum Ref: Hashable, Codable, Sendable {
        /// 1-based data row or column as the table line numbers it; -1 = the last one.
        case index(Int)
        /// A header or row label as said ("Opus 5", "GPT six Astra").
        case name(String)
    }

    /// [] = every data row.
    public var rows: [Ref]
    /// [] = every data column.
    public var columns: [Ref]
    /// Only the empty cells (D4); a single cell named by row and column is overwritten whatever this says.
    public var onlyEmpty: Bool
    public var value: CellValue?
    /// "… ou des chiffres aléatoires": offered afterwards, not applied.
    public var alternative: CellValue?
    public var style: CellStyleOverride?

    public init(rows: [Ref] = [], columns: [Ref] = [], onlyEmpty: Bool = true, value: CellValue? = nil,
                alternative: CellValue? = nil, style: CellStyleOverride? = nil) {
        self.rows = rows
        self.columns = columns
        self.onlyEmpty = onlyEmpty
        self.value = value
        self.alternative = alternative
        self.style = style
    }

    /// Exactly one row and one column: a single cell, which is overwritten (D4).
    public var namesOneCell: Bool { rows.count == 1 && columns.count == 1 }
}

/// What goes in the cells (D6).
public enum CellValue: Hashable, Codable, Sendable {
    /// Written verbatim, at most 24 characters.
    case constant(String)
    /// nils: the column's remembered or observed format and range, else integers 0…100.
    case random(min: Double?, max: Double?, decimals: Int?)
    case sequence(start: Double, step: Double)
    /// One value per selected cell, row-major.
    case list([String])
    /// Believable values for the column; only on explicit request.
    case plausible

    /// Short English form for reports and the model: "1", "random", "random 50–90", "sequence", "list", "plausible".
    public var reportText: String {
        switch self {
        case .constant(let text): return text
        case .random(let min, let max, _):
            if let min, let max { return "random \(Self.short(min))–\(Self.short(max))" }
            return "random"
        case .sequence: return "sequence"
        case .list: return "list"
        case .plausible: return "plausible"
        }
    }

    /// "90" for 90.0, "12.5" otherwise.
    public static func short(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e12 ? String(Int(value)) : String(value)
    }
}

/// Changes the user asked for on top of the table's own style.
public struct CellStyleOverride: Hashable, Codable, Sendable {
    public var color: PSColor?
    public var weight: TableGrid.FontWeight?
    /// × the table's size, 0.5…2.
    public var scale: Double?

    public init(color: PSColor? = nil, weight: TableGrid.FontWeight? = nil, scale: Double? = nil) {
        self.color = color
        self.weight = weight
        self.scale = scale
    }
}

public enum TableEditError: Error, Hashable, Sendable {
    case noTable
    /// The name said, and the names that exist on that axis.
    case unknown(TableGrid.Axis, String, names: [String])
    /// 1-based data indices of the rows or columns the name fits.
    case ambiguous(TableGrid.Axis, String, candidates: [Int])
    case nothingToDo
    case tooMany(Int)
    case listMismatch(values: Int, cells: Int)
}

/// Which data cells a spec names.
public enum TableSelection {
    /// D16: more cells than this in one step fail with too_many.
    public static let maxCells = 400

    /// Every data cell the spec's rows and columns name, row-major, whatever is in them.
    public static func scope(for spec: TableEditSpec, in grid: TableGrid) throws -> [TableGrid.Cell] {
        let rows = try resolve(spec.rows, axis: .row, in: grid)
        let columns = try resolve(spec.columns, axis: .column, in: grid)
        var cells: [TableGrid.Cell] = []
        for row in rows {
            for column in columns {
                if let cell = grid.cell(dataRow: row, dataColumn: column) { cells.append(cell) }
            }
        }
        return cells
    }

    /// Data cells the spec names, row-major: printed values and placeholders are never written over (D3);
    /// cells holding a Picshop layer are skipped when `onlyEmpty` (D4). Throws TableEditError.
    public static func cells(for spec: TableEditSpec, in grid: TableGrid) throws -> [TableGrid.Cell] {
        let scope = try scope(for: spec, in: grid)
        let onlyEmpty = spec.onlyEmpty && !spec.namesOneCell
        let cells = scope.filter { cell in
            switch cell.state {
            case .empty: return true
            case .layer: return !onlyEmpty
            case .printed, .placeholder: return false
            }
        }
        guard !cells.isEmpty else { throw TableEditError.nothingToDo }
        guard cells.count <= maxCells else { throw TableEditError.tooMany(cells.count) }
        return cells
    }

    /// 1-based data indices, in table order, without repeats; [] = all of them. Throws unknown or ambiguous.
    public static func resolve(_ refs: [TableEditSpec.Ref], axis: TableGrid.Axis, in grid: TableGrid) throws -> [Int] {
        let count = axis == .row ? grid.dataRows.count : grid.dataColumns.count
        guard !refs.isEmpty else { return Array(stride(from: 1, through: count, by: 1)) }
        var indices: [Int] = []
        for ref in refs {
            switch grid.match(ref, on: axis) {
            case .exact(let index), .partial(let index):
                if !indices.contains(index) { indices.append(index) }
            case .ambiguous(let candidates):
                throw TableEditError.ambiguous(axis, spokenName(ref), candidates: candidates)
            case .none:
                throw TableEditError.unknown(axis, spokenName(ref), names: grid.names(axis))
            }
        }
        return indices.sorted()
    }

    static func spokenName(_ ref: TableEditSpec.Ref) -> String {
        switch ref {
        case .index(let index): return String(index)
        case .name(let name): return name
        }
    }
}

/// Values for the selected cells (D6). SplitMix64 seeded by FNV-1a of the intent id: the same
/// request gives the same values, another request other values.
public struct CellValueGenerator: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// FNV-1a of `id.uuidString`.
    public static func seed(for id: UUID) -> UInt64 {
        StableHash.fnv1a64(id.uuidString)
    }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    /// One value per cell, in the cells' order.
    public mutating func values(_ value: CellValue, for cells: [TableGrid.Cell], in grid: TableGrid) throws -> [String] {
        switch value {
        case .constant(let text):
            let written = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            return cells.map { _ in written }
        case .list(let values):
            guard values.count == cells.count else { throw TableEditError.listMismatch(values: values.count, cells: cells.count) }
            return values.map { String($0.prefix(24)) }
        case .sequence(let start, let step):
            let decimals = max(Self.decimals(of: start), Self.decimals(of: step))
            return cells.indices.map { offset in
                TableGrid.NumberFormat(decimals: decimals).format(start + Double(offset) * step)
            }
        case .random(let min, let max, let decimals):
            return cells.map { cell in randomValue(min: min, max: max, decimals: decimals, format: format(of: cell, in: grid)) }
        case .plausible:
            // Phase 1: believable values per row; until then the column's observed range.
            return cells.map { cell in randomValue(min: nil, max: nil, decimals: nil, format: format(of: cell, in: grid)) }
        }
    }

    mutating func randomValue(min: Double?, max: Double?, decimals: Int?, format: TableGrid.NumberFormat?) -> String {
        var low = 0.0, high = 100.0
        if let range = format?.range, range.upperBound > range.lowerBound { low = range.lowerBound; high = range.upperBound }
        if let min, let max { low = Swift.min(min, max); high = Swift.max(min, max) }
        else if let min { low = min; high = Swift.max(high, min + 100) }
        else if let max { low = Swift.min(0, max); high = max }
        var written = format ?? TableGrid.NumberFormat()
        written.decimals = Swift.max(0, Swift.min(decimals ?? format?.decimals ?? 0, 3))
        let scale = pow(10, Double(written.decimals))
        let value = ((low + unit() * (high - low)) * scale).rounded() / scale
        return written.format(Swift.min(Swift.max(value, low), high))
    }

    func format(of cell: TableGrid.Cell, in grid: TableGrid) -> TableGrid.NumberFormat? {
        guard let column = grid.columns.first(where: { $0.index == cell.column }) else { return nil }
        return column.format
    }

    static func decimals(of value: Double) -> Int {
        guard value.isFinite, value != value.rounded() else { return 0 }
        for decimals in 1...3 where abs(value * pow(10, Double(decimals)) - (value * pow(10, Double(decimals))).rounded()) < 1e-9 {
            return decimals
        }
        return 3
    }
}
