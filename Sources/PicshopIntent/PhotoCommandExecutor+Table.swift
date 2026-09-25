import Foundation
import PicshopCore

// Table steps: fillCells, clearCells, highlightCells (contract §9). One execute() is one document
// mutation: one history commit, one undo step. Cells never take a pixel of paint: values are text
// layers in the table's own typography, grouped; printed values are only erased when one cell is named
// (a replacement) or the cells are cleared, with a tight mask that spares the rules.

extension PhotoCommandExecutor {
    /// D16: more cells than this in one step fail with too_many.
    static let maxCells = TableSelection.maxCells

    // MARK: fillCells

    /// Writes a value in table cells: one text layer per cell, grouped, in the table's own style.
    func fillCells(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        let fr = language == .french
        guard let (raw, grid) = await tables(in: document) else { return (document, noTable()) }
        var spec = intent.table ?? TableEditSpec()
        // No value and a style ("en gras", "plus gros", "en rouge" after a fill): the Picshop cells in scope are
        // restyled and keep their words; random values are never drawn again for a change of look.
        if spec.value == nil, let override = spec.style, override.color != nil || override.weight != nil || override.scale != nil {
            var restyleScope = spec
            restyleScope.onlyEmpty = false
            if let scope = try? TableSelection.scope(for: restyleScope, in: grid), scope.contains(where: { $0.state == .layer }) {
                return restyleCells(scope, spec: spec, grid: grid, document: document)
            }
        }
        // "les autres aussi" with nothing said: the last fill's value, else the one the laid-over cells share.
        if spec.value == nil { spec.value = context.lastTableEdit?.value ?? Self.sharedLayerValue(in: grid) }
        guard let value = spec.value else {
            let question = fr ? "Avec quoi ? Des 1, ou des nombres au hasard ?" : "With what? Ones, or random numbers?"
            return (document, ExecutionResult(outcome: .info(message: question), effects: [ExecutionReason.needsSelection.effect]))
        }

        let scope: [TableGrid.Cell]
        do { scope = try TableSelection.scope(for: spec, in: grid) } catch { return (document, tableFailure(error, intent: intent, grid: grid)) }
        let single = spec.namesOneCell
        let onlyEmpty = spec.onlyEmpty && !single
        var targets: [TableGrid.Cell] = []
        var adopted: [(cell: TableGrid.Cell, layerID: UUID)] = []
        /// Lone short numbers laid over a cell (the old build's giant "1"): they keep their words but take the
        /// table's style and join the group, so the table is uniform whatever the value; counted as kept.
        var restyled: [(cell: TableGrid.Cell, layerID: UUID)] = []
        var kept = 0
        var erase: [TableGrid.Cell] = []
        for cell in scope {
            switch cell.state {
            case .empty:
                targets.append(cell)
            case .layer:
                let lone = cell.layerID.flatMap { id in document.layer(id: id).map { (id, $0) } }.flatMap { $0.1.group == nil ? $0 : nil }
                // D4: the lone layer already saying the value is adopted (restyled, recentred, grouped).
                if case .constant(let text) = value, let (id, layer) = lone,
                   SceneMap.folded(layer.textElement?.text ?? "") == SceneMap.folded(text), !SceneMap.folded(text).isEmpty {
                    adopted.append((cell, id))
                } else if !onlyEmpty {
                    targets.append(cell)
                } else if let (id, layer) = lone, Self.isShortNumber(layer.textElement?.text ?? "") {
                    restyled.append((cell, id))
                    kept += 1
                } else {
                    kept += 1
                }
            case .printed, .placeholder:
                // Printed values are never written over, except the one cell named by row and column.
                if single { targets.append(cell); erase.append(cell) } else { kept += 1 }
            }
        }
        guard !targets.isEmpty || !adopted.isEmpty else { return (document, tableFailure(TableEditError.nothingToDo, intent: intent, grid: grid)) }
        guard targets.count <= Self.maxCells else { return (document, tableFailure(TableEditError.tooMany(targets.count), intent: intent, grid: grid)) }

        var generator = CellValueGenerator(seed: CellValueGenerator.seed(for: intent.id))
        let values: [String]
        do { values = try generator.values(value, for: targets, in: grid) } catch { return (document, tableFailure(error, intent: intent, grid: grid)) }

        // Printed words of a replaced cell go first, with a tight mask (the memory keeps what was there).
        if !erase.isEmpty {
            rememberTable(raw, in: &document)
            do { try await eraseWords(of: erase, in: &document) } catch { return (input, failure(error)) }
        }

        let groupID = UUID()
        let remembered = document.rememberedTable
        for (cell, text) in zip(targets, values) {
            if let old = cell.layerID { document.removeLayer(id: old) }
            guard let address = grid.dataAddress(of: cell) else { continue }
            let element = cellElement(text, cell: cell, address: address, grid: grid, remembered: remembered, override: spec.style, canvas: document.canvasSize)
            let layer = Layer(name: Self.cellLayerName(grid: grid, address: address), content: .text(element), transform: LayerTransform(center: element.center),
                              group: LayerGroup(id: groupID, kind: .tableCells, row: address.row, column: address.column))
            document.addLayer(layer, select: false)
        }
        for (cell, id) in adopted + restyled {
            guard let address = grid.dataAddress(of: cell), let text = document.layer(id: id)?.textElement?.text else { continue }
            let element = cellElement(text, cell: cell, address: address, grid: grid, remembered: remembered, override: spec.style, canvas: document.canvasSize)
            document.update(layerID: id) { layer in
                layer.content = .text(element)
                layer.transform = LayerTransform(center: element.center)
                layer.name = Self.cellLayerName(grid: grid, address: address)
                layer.group = LayerGroup(id: groupID, kind: .tableCells, row: address.row, column: address.column)
            }
        }
        if let selected = document.selectedLayerID, document.layer(id: selected) == nil { document.selectedLayerID = document.baseLayerID }

        let filledEmpty = targets.filter { $0.state == .empty }.count
        // An adopted layer was written with the value (restyled, recentred): it counts as changed.
        let report = TableEditReport(action: .fillCells, changed: targets.count + adopted.count, kept: kept,
                                     emptyLeft: max(0, grid.emptyDataCells.count - filledEmpty), dataRows: grid.dataRows.count,
                                     dataColumns: grid.dataColumns.count, value: value.reportText, alternative: spec.alternative?.reportText, groupID: groupID)
        return (document, ExecutionResult(outcome: .applied(label: "Fill Cells"), effects: [report.effect], label: "Fill Cells"))
    }

    /// fillCells with no value and a style: the Picshop layers of the cells in scope take the style and keep
    /// their words (one commit); printed cells and empty ones are left alone.
    func restyleCells(_ scope: [TableGrid.Cell], spec: TableEditSpec, grid: TableGrid, document input: PhotoDocument) -> (PhotoDocument, ExecutionResult) {
        var document = input
        let remembered = document.rememberedTable
        var changed = 0
        var groupID: UUID?
        for cell in scope where cell.state == .layer {
            guard let id = cell.layerID, let layer = document.layer(id: id), let old = layer.textElement, let address = grid.dataAddress(of: cell) else { continue }
            // The cell's own style first (a colour or weight it already has is kept), then the override.
            var element = cellElement(old.text, cell: cell, address: address, grid: grid, remembered: remembered, override: spec.style, canvas: document.canvasSize)
            if spec.style?.color == nil { element.color = old.color }
            if spec.style?.weight == nil, layer.group != nil { element.fontName = old.fontName }
            if let scale = spec.style?.scale {
                element.relativeSize = Self.fittedSize(old.text, old.relativeSize * scale.clamped(to: 0.5...2), width: cell.contentRect.width,
                                                       height: cell.contentRect.height, canvas: document.canvasSize)
            } else {
                element.relativeSize = old.relativeSize
            }
            let group = layer.group ?? LayerGroup(id: groupID ?? UUID(), kind: .tableCells, row: address.row, column: address.column)
            groupID = groupID ?? group.id
            document.update(layerID: id) { layer in
                layer.content = .text(element)
                layer.transform = LayerTransform(center: element.center)
                layer.group = group
            }
            changed += 1
        }
        guard changed > 0 else { return (input, tableFailure(TableEditError.nothingToDo, intent: EditIntent(action: .fillCells, table: spec), grid: grid)) }
        let report = TableEditReport(action: .fillCells, changed: changed, kept: 0, emptyLeft: grid.emptyDataCells.count, dataRows: grid.dataRows.count,
                                     dataColumns: grid.dataColumns.count, value: "style", groupID: groupID)
        return (document, ExecutionResult(outcome: .applied(label: "Fill Cells"), effects: [report.effect], label: "Fill Cells"))
    }

    /// "1", "42", "80,9 %", "-3": a short number, as the stray layer of the old build was.
    static func isShortNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8 else { return false }
        let digits = trimmed.filter(\.isNumber)
        return !digits.isEmpty && trimmed.allSatisfy { $0.isNumber || ".,%-+ ".contains($0) }
    }

    /// The text layer of one cell: the value in the table's style (D5), plain, shrunk to fit the cell.
    func cellElement(_ text: String, cell: TableGrid.Cell, address: (row: Int, column: Int), grid: TableGrid, remembered: TableGrid?,
                     override: CellStyleOverride?, canvas: PSSize) -> TextElement {
        var style = grid.style(forDataColumn: address.column) ?? remembered?.style(forDataColumn: address.column) ?? grid.fallbackStyle
        if let override {
            if let color = override.color { style.color = color }
            if let weight = override.weight { style.weight = weight }
            if let scale = override.scale { style.relativeSize *= scale.clamped(to: 0.5...2) }
        }
        let content = cell.contentRect
        let size = Self.fittedSize(text, style.relativeSize, width: content.width, height: content.height, canvas: canvas)
        let framed = style.alignment != .center
        return TextElement(text: text, fontName: style.fontName, relativeSize: size, color: style.color, alignment: style.alignment,
                           style: .plain, center: content.center, letterSpacing: 0, lineSpacing: 1.0,
                           maxRelativeWidth: max(content.width, cell.rect.width), frameWidth: framed ? content.width : nil)
    }

    /// A font size (fraction of the canvas height) no wider than 0.85 of `width` and no taller than 0.8
    /// of `height`, by the estimated advance of each character.
    static func fittedSize(_ text: String, _ size: Double, width: Double, height: Double, canvas: PSSize) -> Double {
        var fitted = size
        let estimated = estimatedWidth(text, relativeSize: fitted, canvas: canvas)
        if estimated > 0.85 * width, estimated > 0 { fitted *= 0.85 * width / estimated }
        if height > 0 { fitted = min(fitted, 0.8 * height) }
        return max(0.004, fitted)
    }

    /// Estimated width (fraction of the canvas width): digit 0.6 em, "%" 0.85, "." or "," 0.28, letter 0.55.
    static func estimatedWidth(_ text: String, relativeSize: Double, canvas: PSSize) -> Double {
        let ems = text.reduce(0.0) { sum, character in
            if character.isNumber { return sum + 0.6 }
            if character == "%" { return sum + 0.85 }
            if character == "." || character == "," || character == " " { return sum + 0.28 }
            if character.isUppercase { return sum + 0.65 }
            return sum + 0.55
        }
        let aspect = canvas.width > 0 && canvas.height > 0 ? canvas.height / canvas.width : 1
        return ems * relativeSize * aspect
    }

    /// "Agentic coding · Opus 5", at most 40 characters.
    static func cellLayerName(grid: TableGrid, address: (row: Int, column: Int)) -> String {
        let label = grid.dataRows[address.row - 1].label.split(separator: "\n").first.map(String.init) ?? ""
        let header = grid.dataColumns[address.column - 1].header
        let name = [label, header].filter { !$0.isEmpty }.joined(separator: " · ")
        return String((name.isEmpty ? "r\(address.row)c\(address.column)" : name).prefix(40))
    }

    /// The text every laid-over data cell shares (the stray "1"), when they all say the same thing.
    static func sharedLayerValue(in grid: TableGrid) -> CellValue? {
        let texts = Set(grid.dataCells.filter { $0.state == .layer }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard texts.count == 1, let text = texts.first, !text.isEmpty else { return nil }
        return .constant(text)
    }

    // MARK: clearCells

    /// Empties table cells: Picshop layers removed, printed values erased with a tight mask.
    func clearCells(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        guard let (raw, grid) = await tables(in: document) else { return (document, noTable()) }
        let spec = intent.table ?? TableEditSpec()
        let scope: [TableGrid.Cell]
        do { scope = try TableSelection.scope(for: spec, in: grid) } catch { return (document, tableFailure(error, intent: intent, grid: grid)) }
        let layered = scope.filter { $0.state == .layer }
        let printed = scope.filter { ($0.state == .printed || $0.state == .placeholder) && !$0.wordBoxes.isEmpty }
        guard !layered.isEmpty || !printed.isEmpty else {
            let message = language == .french ? "Ces cases sont déjà vides." : "Those cells are already empty."
            return (document, ExecutionResult(outcome: .info(message: message), effects: [ExecutionReason.nothingToDo.effect]))
        }
        guard layered.count + printed.count <= Self.maxCells else {
            return (document, tableFailure(TableEditError.tooMany(layered.count + printed.count), intent: intent, grid: grid))
        }
        if !printed.isEmpty {
            rememberTable(raw, in: &document)
            do { try await eraseWords(of: printed, in: &document) } catch { return (input, failure(error)) }
        }
        for cell in layered { if let id = cell.layerID { document.removeLayer(id: id) } }
        let report = TableEditReport(action: .clearCells, changed: layered.count + printed.count, kept: 0,
                                     emptyLeft: grid.emptyDataCells.count + layered.count + printed.count, dataRows: grid.dataRows.count,
                                     dataColumns: grid.dataColumns.count)
        return (document, ExecutionResult(outcome: .applied(label: "Clear Cells"), effects: [report.effect], label: "Clear Cells"))
    }

    // MARK: highlightCells

    /// A translucent box over each named column (header included), row or cell, under every text layer.
    func highlightCells(_ intent: EditIntent, on input: PhotoDocument, context: IntentContext) async -> (PhotoDocument, ExecutionResult) {
        var document = input
        guard let (_, grid) = await tables(in: document) else { return (document, noTable()) }
        let spec = intent.table ?? TableEditSpec()
        let rows: [Int], columns: [Int]
        do {
            rows = try spec.rows.isEmpty ? [] : TableSelection.resolve(spec.rows, axis: .row, in: grid)
            columns = try spec.columns.isEmpty ? [] : TableSelection.resolve(spec.columns, axis: .column, in: grid)
        } catch {
            return (document, tableFailure(error, intent: intent, grid: grid))
        }
        var boxes: [(rect: PSRect, row: Int?, column: Int?, name: String)] = []
        switch (rows.isEmpty, columns.isEmpty) {
        case (true, false):
            for column in columns {
                let header = grid.dataColumns[column - 1]
                boxes.append((header.rect, nil, column, header.header))
            }
        case (false, true):
            for row in rows {
                let line = grid.dataRows[row - 1]
                boxes.append((line.rect, row, nil, line.label.split(separator: "\n").first.map(String.init) ?? ""))
            }
        case (false, false):
            for row in rows {
                for column in columns {
                    guard let cell = grid.cell(dataRow: row, dataColumn: column) else { continue }
                    boxes.append((cell.rect, row, column, Self.cellLayerName(grid: grid, address: (row, column))))
                }
            }
        case (true, true):
            boxes.append((grid.bounds, nil, nil, language == .french ? "Tableau" : "Table"))
        }
        let covered = rows.isEmpty && columns.isEmpty ? grid.dataCells.count
            : (rows.isEmpty ? grid.dataRows.count : rows.count) * (columns.isEmpty ? grid.dataColumns.count : columns.count)
        guard covered <= Self.maxCells else { return (document, tableFailure(TableEditError.tooMany(covered), intent: intent, grid: grid)) }

        let groupID = UUID()
        let tint = spec.style?.color ?? intent.color ?? .yellow
        // Just above the photo and any lower picture layer, under every text and shape layer.
        var index = (document.baseLayerID.flatMap { document.index(of: $0) } ?? -1) + 1
        while index < document.layers.count, document.layers[index].isImage || document.layers[index].group?.kind == .tableHighlight { index += 1 }
        for box in boxes {
            let rect = box.rect.clampedToUnit()
            guard rect.width > 0, rect.height > 0 else { continue }
            let shape = ShapeElement(kind: .roundedRectangle, fill: tint.withAlpha(0.28), cornerRadius: min(0.006, min(rect.width, rect.height) * 0.15),
                                     relativeSize: PSSize(width: rect.width, height: rect.height))
            let name = (language == .french ? "Surlignage · " : "Highlight · ") + box.name
            let layer = Layer(name: String(name.prefix(40)), content: .shape(shape), transform: LayerTransform(center: rect.center), blendMode: .multiply,
                              group: LayerGroup(id: groupID, kind: .tableHighlight, row: box.row, column: box.column))
            document.layers.insert(layer, at: min(index, document.layers.count))
            index += 1
        }
        document.touch()
        let report = TableEditReport(action: .highlightCells, changed: covered, kept: 0, emptyLeft: grid.emptyDataCells.count,
                                     dataRows: grid.dataRows.count, dataColumns: grid.dataColumns.count, groupID: groupID)
        return (document, ExecutionResult(outcome: .applied(label: "Highlight Cells"), effects: [report.effect], label: "Highlight Cells"))
    }

    // MARK: Grid

    /// services.tableGrid(in:remembered:) ?? rememberedTable (data cells read as .empty), overlaid with the layers.
    func currentTable(in document: PhotoDocument) async -> TableGrid? {
        await tables(in: document)?.overlaid
    }

    /// The grid as detected (or remembered, values erased) and the same grid with Picshop's layers laid over it.
    func tables(in document: PhotoDocument) async -> (raw: TableGrid, overlaid: TableGrid)? {
        let remembered = document.rememberedTable
        var grid = (try? await services.tableGrid(in: document, remembered: remembered)) ?? nil
        // Remembered values were erased: what was printed is gone, the geometry and style stay.
        if grid == nil { grid = remembered?.withValuesErased() }
        guard let grid else { return nil }
        return (grid, grid.overlaying(document.layers))
    }

    /// D7: the table as it is right before its printed values are erased, so a later fill writes in its
    /// typography. Only a grid with printed values is worth keeping, and never over a richer memory.
    func rememberTable(_ grid: TableGrid, in document: inout PhotoDocument) {
        let printed = grid.dataCells.filter { $0.state == .printed }.count
        guard printed > 0 else { return }
        let key = document.tableGeometryKey
        if let memory = document.tableMemory, memory.geometryKey == key,
           memory.grid.dataCells.filter({ $0.state == .printed }).count > printed { return }
        var stored = grid
        stored.source = .detected
        document.tableMemory = TableMemory(grid: stored, geometryKey: key)
    }

    /// Erases the printed words of `cells` with a tight mask (each word box grown by 15 % of its height,
    /// at least 1.5 px), through the same apply path as an erase.
    func eraseWords(of cells: [TableGrid.Cell], in document: inout PhotoDocument) async throws {
        let canvas = document.canvasSize
        let boxes = cells.flatMap(\.wordBoxes).map { box -> PSRect in
            let pixels = max(1.5, 0.15 * box.height * max(1, canvas.height))
            return box.insetBy(dx: -pixels / max(1, canvas.width), dy: -pixels / max(1, canvas.height)).clampedToUnit()
        }
        guard !boxes.isEmpty else { return }
        let candidates = boxes.map { ObjectCandidate(label: "text", boundingBox: $0, confidence: 1) }
        let target = ObjectTarget(label: "text", originalPhrase: "table values", matchesAll: true)
        let mask = try await services.mask(for: candidates, target: target, in: document)
        document.apply(.removeObject(mask))
    }

    // MARK: Failures

    /// No table: say so, and how to help, with the no_table code.
    func noTable() -> ExecutionResult {
        let message = language == .french ? "Je ne vois pas de tableau sur cette image. Recadre dessus, puis redis-le."
            : "I can't see a table in this picture. Crop to it and ask again."
        return ExecutionResult(outcome: .info(message: message), effects: [ExecutionReason.noTable.effect])
    }

    /// A TableEditError as the user hears it, with its reason code (§9).
    func tableFailure(_ error: Error, intent: EditIntent, grid: TableGrid) -> ExecutionResult {
        let fr = language == .french
        guard let error = error as? TableEditError else { return failure(error) }
        switch error {
        case .noTable:
            return noTable()
        case .unknown(let axis, let name, let names):
            let list = names.map { $0.split(separator: "\n").first.map(String.init) ?? $0 }.joined(separator: ", ")
            let message: String
            if axis == .column {
                message = fr ? "Je ne trouve pas la colonne « \(name) ». Colonnes : \(list)." : "I can't find the column “\(name)”. Columns: \(list)."
            } else {
                message = fr ? "Je ne trouve pas la ligne « \(name) ». Lignes : \(list)." : "I can't find the row “\(name)”. Rows: \(list)."
            }
            return ExecutionResult(outcome: .failed(message: message), effects: [(axis == .column ? ExecutionReason.unknownColumn : .unknownRow).effect])
        case .ambiguous(let axis, let name, let candidates):
            let options: [ObjectCandidate] = candidates.compactMap { index in
                if axis == .column, index >= 1, index <= grid.dataColumns.count {
                    let column = grid.dataColumns[index - 1]
                    return ObjectCandidate(label: column.header, boundingBox: column.rect, confidence: 1)
                }
                if axis == .row, index >= 1, index <= grid.dataRows.count {
                    let row = grid.dataRows[index - 1]
                    return ObjectCandidate(label: row.label.split(separator: "\n").first.map(String.init) ?? row.label, boundingBox: row.rect, confidence: 1)
                }
                return nil
            }
            let names = options.map(\.label)
            let joined = names.count > 1 ? names.dropLast().joined(separator: ", ") + (fr ? " ou " : " or ") + (names.last ?? "") : (names.first ?? name)
            let question = axis == .column ? (fr ? "Quelle colonne : \(joined) ?" : "Which column: \(joined)?") : (fr ? "Quelle ligne : \(joined) ?" : "Which row: \(joined)?")
            var result = ExecutionResult.clarify(ClarificationRequest(question: question, candidates: options, pendingIntent: intent))
            result.effects.append(ExecutionReason.ambiguous.effect)
            return result
        case .nothingToDo:
            let message = fr ? "Toutes ces cases sont déjà remplies." : "All those cells are already filled."
            return ExecutionResult(outcome: .info(message: message), effects: [ExecutionReason.nothingToDo.effect])
        case .tooMany(let count):
            let message = fr ? "Ça fait \(count) cases, plus de \(Self.maxCells) : dis-moi une colonne ou une ligne." : "That's \(count) cells, more than \(Self.maxCells): name a column or a row."
            return ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.tooMany.effect])
        case .listMismatch(let values, let cells):
            let message = fr ? "Tu m'as donné \(values) valeurs pour \(cells) cases." : "You gave me \(values) values for \(cells) cells."
            return ExecutionResult(outcome: .failed(message: message), effects: [ExecutionReason.unsupported.effect])
        }
    }
}
