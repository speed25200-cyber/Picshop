import Foundation

/// Layers that were made together and belong together: the text layers of one table fill,
/// or the boxes of one highlight. One step adds the whole group in one history commit, so one
/// undo removes it; the layers panel shows it as one row.
public struct LayerGroup: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        /// One text layer per table cell (fillCells).
        case tableCells
        /// Translucent boxes over rows, columns or cells (highlightCells).
        case tableHighlight
    }

    public var id: UUID
    public var kind: Kind
    /// 1-based data address of a cell layer, as the table line numbers it (D1); nil for a
    /// whole-row or whole-column highlight.
    public var row: Int?
    public var column: Int?

    public init(id: UUID, kind: Kind, row: Int? = nil, column: Int? = nil) {
        self.id = id
        self.kind = kind
        self.row = row
        self.column = column
    }
}
