import Foundation

/// The table as it was right before Picshop erased its values (D7): geometry, styles and number
/// formats survive the erase, so a later fill writes in the table's own typography.
public struct TableMemory: Hashable, Codable, Sendable {
    public var grid: TableGrid
    /// `PhotoDocument.tableGeometryKey` when it was saved; used only while it still matches.
    public var geometryKey: String

    public init(grid: TableGrid, geometryKey: String) {
        self.grid = grid
        self.geometryKey = geometryKey
    }
}

extension PhotoDocument {
    /// FNV-1a hex of the canvas size and the base layer's geometric operations in order (crop, rotate,
    /// flip, straighten, perspective, expand, upscale): equal while table cells stay where they were.
    /// Never `Hasher`, so a saved memory still matches after a relaunch.
    public var tableGeometryKey: String {
        var parts = ["canvas", StableHash.token(canvasSize.width, decimals: 0), StableHash.token(canvasSize.height, decimals: 0)]
        for operation in baseLayer?.edits.operations ?? [] {
            switch operation.kind {
            case .crop(let rect):
                parts += ["crop"] + [rect.minX, rect.minY, rect.width, rect.height].map { StableHash.token($0) }
            case .rotate(let degrees):
                parts += ["rotate", StableHash.token(degrees, decimals: 2)]
            case .straighten(let degrees):
                parts += ["straighten", StableHash.token(degrees, decimals: 2)]
            case .flip(let axis):
                parts += ["flip", axis.rawValue]
            case .perspective(let horizontal, let vertical):
                parts += ["perspective", StableHash.token(horizontal), StableHash.token(vertical)]
            case .expand(let rect):
                parts += ["expand"] + [rect.minX, rect.minY, rect.width, rect.height].map { StableHash.token($0) }
            case .upscale(let factor):
                parts += ["upscale", StableHash.token(factor, decimals: 2)]
            default:
                continue
            }
        }
        return StableHash.hex(parts.joined(separator: ","))
    }

    /// FNV-1a hex of everything that moves or changes what the base picture shows (its text, objects and
    /// free areas): the asset, the canvas size and every base-layer operation id in order, except tonal
    /// and colour edits (exposure, looks, curves, grading…), which leave every word and object where it
    /// was. The scene map and the table grid are cached under it and read again when it changes, so a
    /// slider moved during Live never costs a new text pass; text layers do not change it either (they
    /// are laid over at use time).
    public var baseStateKey: String {
        var parts = ["base", baseLayer?.imageAsset?.relativePath ?? "-", StableHash.token(canvasSize.width, decimals: 0), StableHash.token(canvasSize.height, decimals: 0)]
        parts += (baseLayer?.edits.operations ?? []).filter { !Self.isTonal($0.kind) }.map(\.id.uuidString)
        if let mask = baseLayer?.mask { parts.append("mask:" + mask.id.uuidString) }
        return StableHash.hex(parts.joined(separator: ","))
    }

    /// Edits that change tones and colours only: nothing moves, appears or goes.
    static func isTonal(_ kind: EditOperation.Kind) -> Bool {
        switch kind {
        case .adjust, .adjustments, .toneCurve, .look, .autoEnhance, .colorMixer, .colorGrade, .lut, .colorMatch, .denoise, .sharpen, .relight:
            return true
        default:
            return false
        }
    }

    /// The table memory whose key matches the current geometry, marked `.remembered`.
    public var rememberedTable: TableGrid? {
        guard let memory = tableMemory, memory.geometryKey == tableGeometryKey else { return nil }
        var grid = memory.grid
        grid.source = .remembered
        return grid
    }

    /// The layers of one group, in stacking order.
    public func layers(inGroup id: UUID) -> [Layer] {
        layers.filter { $0.group?.id == id }
    }

    /// Removes every layer of the group; returns how many went.
    @discardableResult
    public mutating func removeLayers(inGroup id: UUID) -> Int {
        let before = layers.count
        layers.removeAll { $0.group?.id == id }
        let removed = before - layers.count
        if removed > 0 {
            if let selected = selectedLayerID, layer(id: selected) == nil { selectedLayerID = baseLayerID }
            touch()
        }
        return removed
    }
}

extension TableGrid {
    /// The grid as it is once its printed values are gone: every data cell empty, and where a value
    /// was printed, its content rect re-centred on it (vertically, and horizontally for a centred
    /// column), so a later fill lands exactly where the old value was.
    public func withValuesErased() -> TableGrid {
        var grid = self
        for index in grid.cells.indices where grid.cells[index].kind == .data {
            var cell = grid.cells[index]
            let boxes = cell.wordBoxes.filter { $0.width > 0 && $0.height > 0 }
            if let first = boxes.first, cell.state == .printed || cell.state == .placeholder {
                let printed = boxes.dropFirst().reduce(first) { $0.union($1) }
                var content = cell.contentRect
                let centred = (columns.first { $0.index == cell.column }?.style?.alignment ?? bodyStyle?.alignment ?? .center) == .center
                // Centred on the old value, no taller than the cell allows around it (never less than the value's own height).
                let room = 2 * min(printed.midY - cell.rect.minY, cell.rect.maxY - printed.midY)
                content.size.height = min(content.height, max(printed.height * 1.5, room))
                let x = centred ? printed.midX - content.width / 2 : content.minX
                content.origin = PSPoint(x: x.clamped(to: cell.rect.minX...max(cell.rect.minX, cell.rect.maxX - content.width)),
                                         y: printed.midY - content.height / 2)
                cell.contentRect = content
            }
            cell.state = .empty
            cell.text = ""
            cell.wordBoxes = []
            cell.layerID = nil
            grid.cells[index] = cell
        }
        return grid
    }
}

