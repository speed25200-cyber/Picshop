import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// A1, A2, A10, A16 and the table executor: one step fills, clears or highlights N cells in the
/// table's own style, as one grouped mutation, and says what it did through the machine channel.
final class TableFillTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    private func run(_ phrase: String, on document: PhotoDocument = TableFixtures.document(), services: TableFakeServices = TableFakeServices(),
                     table: TableGrid? = nil, last: TableEditSpec? = nil, language: NormalizedUtterance.Language = .french) async -> (PhotoDocument, ExecutionResult, EditIntent) {
        let grid = table ?? services.grid?.overlaying(document.layers)
        let context = IntentContext(mode: .photo, preferredLanguage: language.rawValue, table: grid, lastTableEdit: last)
        let plan = engine.parse(phrase, context: context)
        let intent = plan.intents[0]
        let (after, result) = await PhotoCommandExecutor(services: services, language: language).execute(intent, on: document, context: context)
        return (after, result, intent)
    }

    private func cellLayers(_ document: PhotoDocument) -> [Layer] { document.layers.filter { $0.group?.kind == .tableCells } }

    // MARK: A1

    func testTheUsersSentenceFillsEveryCellInOneStep() async throws {
        let before = TableFixtures.document()
        let (after, result, _) = await run("Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires", on: before)
        let layers = cellLayers(after)
        XCTAssertEqual(layers.count, 45)
        XCTAssertEqual(Set(layers.compactMap { $0.group?.id }).count, 1, "one group")
        XCTAssertEqual(result.label, "Fill Cells")
        XCTAssertEqual(result.outcome, .applied(label: "Fill Cells"))
        XCTAssertFalse(result.effects.contains { if case .selectLayer = $0 { return true } else { return false } }, "the text tool does not open")
        XCTAssertTrue(result.changedDocument, "one history commit")
        let report = try XCTUnwrap(result.tableReport)
        XCTAssertEqual(report.changed, 45)
        XCTAssertEqual(report.emptyLeft, 0)
        XCTAssertEqual(report.value, "1")
        XCTAssertEqual(report.alternative, "random")
        XCTAssertEqual(report.groupID, layers.first?.group?.id)
        let grid = TableFixtures.benchmark()
        for layer in layers {
            let element = try XCTUnwrap(layer.textElement)
            let cell = try XCTUnwrap(grid.cell(dataRow: layer.group!.row!, dataColumn: layer.group!.column!))
            XCTAssertEqual(element.text, "1")
            XCTAssertEqual(element.center.x, cell.contentRect.midX, accuracy: 0.002)
            XCTAssertEqual(element.center.y, cell.contentRect.midY, accuracy: 0.002)
            XCTAssertEqual(layer.transform.center, element.center, "the layer is placed where the text is")
            XCTAssertEqual(element.relativeSize, TableFixtures.style.relativeSize, accuracy: TableFixtures.style.relativeSize * 0.1)
            XCTAssertEqual(element.style, .plain)
            XCTAssertEqual(element.fontName, "SFProDigits-Regular")
            XCTAssertEqual(element.color, TableFixtures.style.color)
            XCTAssertEqual(element.letterSpacing, 0)
            XCTAssertEqual(element.lineSpacing, 1)
        }
        XCTAssertEqual(layers.first?.name, "Agentic coding · Opus 5.5")
        XCTAssertEqual(after.selectedLayerID, before.selectedLayerID, "the selection stays")
    }

    // MARK: A2

    func testTheFollowUpAdoptsTheStrayOne() async throws {
        let stray = TableFixtures.strayOne(in: TableFixtures.document())
        let (after, result, intent) = await run("Il faut remplir les autres cases aussi.", on: stray)
        XCTAssertEqual(intent.table?.value, .constant("1"))
        let layers = cellLayers(after)
        XCTAssertEqual(layers.count, 45, "44 filled and the stray one adopted")
        XCTAssertEqual(after.textLayers.count, 45, "no stray layer left over")
        XCTAssertEqual(Set(layers.map { $0.textElement!.relativeSize }).count, 1, "uniform")
        XCTAssertEqual(Set(layers.map { $0.textElement!.fontName }), ["SFProDigits-Regular"])
        let report = try XCTUnwrap(result.tableReport)
        // The adopted layer was written with the value (restyled, recentred): it counts as changed, never as kept.
        XCTAssertEqual(report.changed, 45)
        XCTAssertEqual(report.kept, 0)
        XCTAssertEqual(report.emptyLeft, 0)

        // With a random fill before, the others get random numbers; the stray "1" keeps its word but takes the
        // table's style and joins the group, so the table stays uniform (kept, not rewritten).
        let (random, randomResult, _) = await run("Il faut remplir les autres cases aussi.", on: stray, last: TableEditSpec(value: .random(min: nil, max: nil, decimals: nil)))
        let randomLayers = cellLayers(random)
        let values = randomLayers.compactMap { $0.textElement?.text }
        XCTAssertEqual(values.count, 45, "44 random and the stray one, grouped")
        XCTAssertTrue(values.allSatisfy { Int($0).map { (0...100).contains($0) } ?? false }, "\(values)")
        XCTAssertEqual(Set(randomLayers.map { $0.textElement!.fontName }), ["SFProDigits-Regular"], "the giant bold 1 took the table's style")
        XCTAssertEqual(random.textLayers.count, 45, "no stray layer left in its old style")
        XCTAssertEqual(randomResult.tableReport?.changed, 44)
        XCTAssertEqual(randomResult.tableReport?.kept, 1)
    }

    /// The stray "1" and a random fill said directly: the table ends uniform, the stray value kept.
    func testStrayOneAndRandomValues() async throws {
        let stray = TableFixtures.strayOne(in: TableFixtures.document())
        let (after, result, intent) = await run("mets des chiffres aléatoires dans toutes les cases du tableau", on: stray)
        XCTAssertEqual(intent.table?.value, .random(min: nil, max: nil, decimals: nil))
        let layers = cellLayers(after)
        XCTAssertEqual(layers.count, 45)
        XCTAssertEqual(Set(layers.map { $0.textElement!.fontName }), ["SFProDigits-Regular"])
        XCTAssertEqual(Set(layers.compactMap { $0.group?.id }).count, 1, "one group, one undo")
        XCTAssertEqual(result.tableReport?.kept, 1)
    }

    /// "en gras" after a random fill restyles the cells and keeps every value (no new draw).
    func testRestylingCellsKeepsTheirValues() async throws {
        let (filled, _, _) = await run("mets des nombres au hasard partout", on: TableFixtures.document())
        let before = cellLayers(filled).compactMap { $0.textElement?.text }
        XCTAssertEqual(before.count, 45)
        let spec = TableEditSpec(onlyEmpty: false, style: CellStyleOverride(weight: .bold))
        let executor = PhotoCommandExecutor(services: TableFakeServices(grid: TableFixtures.benchmark()), language: .french)
        let (bold, result) = await executor.execute(EditIntent(action: .fillCells, table: spec), on: filled,
                                                    context: IntentContext(mode: .photo, table: TableFixtures.benchmark().overlaying(filled.layers)))
        XCTAssertEqual(result.tableReport?.changed, 45)
        XCTAssertEqual(cellLayers(bold).compactMap { $0.textElement?.text }, before, "same values")
        XCTAssertTrue(cellLayers(bold).allSatisfy { $0.textElement?.fontName == "SFProDigits-Bold" })
    }

    // MARK: A10

    func testOneUndoRemovesTheWholeFill() async throws {
        let before = TableFixtures.document()
        let (after, result, _) = await run("remplis la colonne Opus 5.5 avec 1", on: before)
        XCTAssertEqual(cellLayers(after).count, 9)
        let group = try XCTUnwrap(result.tableReport?.groupID)
        var history = EditHistory(initial: before)
        history.commit(after, label: result.label)
        XCTAssertEqual(history.count, 1, "one history commit")
        XCTAssertEqual(history.undo(), "Fill Cells")
        XCTAssertEqual(history.present.layers.count, before.layers.count, "one undo step takes all nine")
        var removed = after
        XCTAssertEqual(removed.removeLayers(inGroup: group), 9)
    }

    // MARK: A16

    func testAddTextHonoursThePoint() async {
        let executor = PhotoCommandExecutor(services: TableFakeServices())
        let intent = EditIntent(action: .addText, target: ObjectTarget(label: "object", point: PSPoint(x: 0.3, y: 0.4)), text: "Hello")
        let (after, _) = await executor.execute(intent, on: TableFixtures.document(), context: .photo)
        XCTAssertEqual(after.textLayers.last?.textElement?.center, PSPoint(x: 0.3, y: 0.4))
        XCTAssertEqual(after.textLayers.last?.transform.center, PSPoint(x: 0.3, y: 0.4))
        let normalized = IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "Hi", point: PSPoint(x: 0.3, y: 0.4)), context: .photo)
        let (placed, _) = await executor.execute(normalized!, on: TableFixtures.document(), context: .photo)
        XCTAssertEqual(placed.textLayers.last?.textElement?.center.x ?? 0, 0.3, accuracy: 1e-9)
    }

    // MARK: Scopes and values

    func testOneNamedCellIsWrittenAndPrintedValuesNeverAre() async throws {
        // One named cell over a printed value: a replacement, erased with a tight mask in the same step.
        let services = TableFakeServices(grid: TableFixtures.benchmark(withValues: true))
        let (after, result, intent) = await run("mets 90% à Opus 5 sur la ligne Agentic coding", services: services)
        XCTAssertEqual(intent.table?.columns, [.name("Opus 5")])
        XCTAssertEqual(cellLayers(after).count, 1)
        XCTAssertEqual(cellLayers(after).first?.group?.column, 2)
        XCTAssertEqual(cellLayers(after).first?.textElement?.text, "90%")
        XCTAssertEqual(services.calls.mask, 1, "the printed 77.2% was erased")
        guard case .removeObject? = after.baseLayer?.edits.operations.last?.kind else { return XCTFail("an erase") }
        XCTAssertNotNil(after.tableMemory, "the table is remembered before its value goes")
        XCTAssertEqual(result.tableReport?.changed, 1)

        // Everything printed: nothing to do, and it says so.
        let (_, full, _) = await run("remplis le tableau avec des 1", services: services)
        XCTAssertEqual(full.reason, .nothingToDo)
        XCTAssertEqual(full.outcome.message, "Toutes ces cases sont déjà remplies.")
    }

    func testRandomValuesFollowTheColumnsFormat() async throws {
        var grid = TableFixtures.benchmark()
        for index in grid.columns.indices where !grid.columns[index].isLabel {
            grid.columns[index].format = TableGrid.NumberFormat(decimals: 1, suffix: "%", range: 40...90)
        }
        let (after, result, _) = await run("mets des chiffres aléatoires dans toutes les cases", services: TableFakeServices(grid: grid))
        let values = cellLayers(after).compactMap { $0.textElement?.text }
        XCTAssertEqual(values.count, 45)
        XCTAssertTrue(values.allSatisfy { $0.hasSuffix("%") && $0.split(separator: ".").last?.count == 2 }, "\(values)")
        XCTAssertTrue(values.allSatisfy { Double($0.dropLast()).map { (40...90).contains($0) } ?? false }, "\(values)")
        XCTAssertEqual(result.tableReport?.value, "random")
        // Same step twice: the same numbers; another request: others.
        let intent = EditIntent(action: .fillCells, table: TableEditSpec(value: .random(min: nil, max: nil, decimals: nil)))
        let executor = PhotoCommandExecutor(services: TableFakeServices(grid: grid))
        let (first, _) = await executor.execute(intent, on: TableFixtures.document(), context: .photo)
        let (second, _) = await executor.execute(intent, on: TableFixtures.document(), context: .photo)
        XCTAssertEqual(cellLayers(first).map { $0.textElement!.text }, cellLayers(second).map { $0.textElement!.text })
    }

    func testReplaceTheLayersOfAFill() async throws {
        let (filled, _, _) = await run("remplis le tableau avec des 1")
        let (rerolled, result, intent) = await run("remplace les 1 par des chiffres aléatoires", on: filled, last: TableEditSpec(value: .constant("1")))
        XCTAssertEqual(intent.table?.onlyEmpty, false)
        XCTAssertEqual(cellLayers(rerolled).count, 45, "replaced, not stacked")
        XCTAssertFalse(cellLayers(rerolled).contains { $0.textElement?.text == "1" && false })
        XCTAssertEqual(result.tableReport?.changed, 45)
        XCTAssertNotEqual(Set(cellLayers(rerolled).compactMap { $0.group?.id }), Set(cellLayers(filled).compactMap { $0.group?.id }))
    }

    func testListsSequencesAndStyleOverrides() async throws {
        let (listed, _, _) = await run("mets 80, 75, 70, 65 et 60 sur la ligne Agentic coding")
        XCTAssertEqual(cellLayers(listed).sorted { $0.group!.column! < $1.group!.column! }.map { $0.textElement!.text }, ["80", "75", "70", "65", "60"])
        let (short, mismatch, _) = await run("mets 80, 75 et 70 sur la ligne Agentic coding")
        XCTAssertEqual(cellLayers(short).count, 0)
        XCTAssertEqual(mismatch.outcome.message, "Tu m'as donné 3 valeurs pour 5 cases.")
        let (numbered, _, _) = await run("numérote les cases de 1 à 45")
        XCTAssertEqual(cellLayers(numbered).map { $0.textElement!.text }.prefix(6), ["1", "2", "3", "4", "5", "6"], "row-major")
        let (styled, _, _) = await run("remplis la colonne Opus 5 avec 1 en rouge")
        XCTAssertEqual(cellLayers(styled).first?.textElement?.color, .red)
        let (bold, _, _) = await run("mets des 1 en gras dans la colonne Opus 5")
        XCTAssertEqual(cellLayers(bold).first?.textElement?.fontName, "SFProDigits-Bold")
    }

    func testLeadingColumnsAreFramed() async throws {
        var grid = TableFixtures.benchmark()
        grid.bodyStyle?.alignment = .leading
        let (after, _, _) = await run("remplis la colonne Opus 5 avec 1", services: TableFakeServices(grid: grid))
        let layer = try XCTUnwrap(cellLayers(after).first)
        let cell = try XCTUnwrap(grid.cell(dataRow: layer.group!.row!, dataColumn: 2))
        XCTAssertEqual(layer.textElement?.alignment, .leading)
        XCTAssertEqual(layer.textElement?.frameWidth ?? 0, cell.contentRect.width, accuracy: 1e-9)
    }

    func testLongValuesShrinkToTheCell() {
        let canvas = TableFixtures.canvas
        let cell = TableFixtures.benchmark().cell(dataRow: 1, dataColumn: 1)!
        let size = PhotoCommandExecutor.fittedSize("100000000000.5%", 0.0156, width: cell.contentRect.width, height: cell.contentRect.height, canvas: canvas)
        XCTAssertLessThan(size, 0.0156)
        XCTAssertLessThanOrEqual(PhotoCommandExecutor.estimatedWidth("100000000000.5%", relativeSize: size, canvas: canvas), 0.85 * cell.contentRect.width + 1e-9)
    }

    // MARK: Failures

    func testNamesThatAreNotThereListTheRealOnes() async {
        let (_, result, _) = await run("remplis la colonne GPT 7 avec 1")
        XCTAssertEqual(result.reason, .unknownColumn)
        XCTAssertEqual(result.outcome.message, "Je ne trouve pas la colonne « GPT 7 ». Colonnes : Opus 5.5, Opus 5, Fable 5.1, Gemini 3.5 Pro, GPT-6 Astra.")
        let (_, row, _) = await run("fill the Quantum row with 1", language: .english)
        XCTAssertEqual(row.reason, .unknownRow)
    }

    func testTooManyCells() async {
        // 21 × 21 = 441 data cells.
        let rows = (0...21).map { TableGrid.Row(index: $0, rect: PSRect(x: 0, y: Double($0) / 22, width: 1, height: 1.0 / 22), label: $0 == 0 ? "" : "Row \($0)", isHeader: $0 == 0) }
        let columns = (0...21).map { TableGrid.Column(index: $0, rect: PSRect(x: Double($0) / 22, y: 0, width: 1.0 / 22, height: 1), header: $0 == 0 ? "" : "C\($0)", isLabel: $0 == 0) }
        var cells: [TableGrid.Cell] = []
        for row in rows {
            for column in columns {
                let kind: TableGrid.CellKind = row.isHeader ? (column.isLabel ? .corner : .header) : (column.isLabel ? .label : .data)
                let rect = PSRect(x: column.rect.minX, y: row.rect.minY, width: column.rect.width, height: row.rect.height)
                cells.append(TableGrid.Cell(row: row.index, column: column.index, rect: rect, contentRect: rect, kind: kind))
            }
        }
        let grid = TableGrid(id: "big", bounds: .unit, title: nil, rows: rows, columns: columns, cells: cells, headerRowCount: 1, labelColumnCount: 1,
                             ruling: .full, bodyStyle: TableFixtures.style, confidence: 0.9, source: .detected)
        let (after, result, _) = await run("remplis le tableau avec des 1", services: TableFakeServices(grid: grid))
        XCTAssertEqual(result.reason, .tooMany)
        XCTAssertEqual(after.layers.count, 1)
    }

    func testNoTableSaysSo() async {
        let (_, result, _) = await run("remplis le tableau avec des 1", services: TableFakeServices(grid: nil))
        XCTAssertEqual(result.reason, .noTable)
    }

    // MARK: Clear and highlight

    func testClearRemovesLayersAndErasesPrintedValuesTightly() async throws {
        let (filled, _, _) = await run("remplis la colonne Opus 5 avec 1")
        let (cleared, result, _) = await run("vide la colonne Opus 5", on: filled)
        XCTAssertEqual(cellLayers(cleared).count, 0)
        XCTAssertEqual(result.label, "Clear Cells")
        XCTAssertEqual(result.tableReport?.changed, 9)

        let services = TableFakeServices(grid: TableFixtures.benchmark(withValues: true))
        let (erased, printed, _) = await run("efface la colonne GPT-6 Astra", services: services)
        XCTAssertEqual(printed.tableReport?.changed, 9)
        XCTAssertEqual(services.calls.mask, 1, "one tight mask for the nine values")
        XCTAssertNotNil(erased.tableMemory)
        XCTAssertEqual(erased.rememberedTable?.cell(dataRow: 1, dataColumn: 5)?.text, "74.9%", "remembered as it was")
        let (_, nothing, _) = await run("vide la colonne Opus 5")
        XCTAssertEqual(nothing.reason, .nothingToDo)
    }

    func testHighlightGoesUnderTheText() async throws {
        let (filled, _, _) = await run("remplis le tableau avec des 1")
        let (after, result, _) = await run("surligne la colonne Opus 5.5 en vert", on: filled)
        let boxes = after.layers.filter { $0.group?.kind == .tableHighlight }
        XCTAssertEqual(boxes.count, 1)
        let box = try XCTUnwrap(boxes.first)
        XCTAssertEqual(box.blendMode, .multiply)
        XCTAssertEqual(box.shapeElement?.fill.alpha ?? 0, 0.28, accuracy: 1e-9)
        XCTAssertEqual(box.shapeElement?.fill.withAlpha(1), PSColor.green)
        let column = TableFixtures.benchmark().dataColumns[0].rect
        XCTAssertEqual(box.transform.center.x, column.midX, accuracy: 1e-9)
        XCTAssertEqual(box.shapeElement?.relativeSize.height ?? 0, column.height, accuracy: 1e-9)
        let index = try XCTUnwrap(after.index(of: box.id))
        XCTAssertEqual(index, 1, "right above the photo")
        XCTAssertTrue(after.layers[(index + 1)...].allSatisfy { $0.isText }, "under every text layer")
        XCTAssertEqual(result.tableReport?.changed, 9)
        XCTAssertEqual(result.label, "Highlight Cells")
    }

    // MARK: Memory at erase (D7)

    func testTheTableIsRememberedRightBeforeItsValuesAreErased() async throws {
        let services = TableFakeServices(grid: TableFixtures.benchmark(withValues: true))
        let executor = PhotoCommandExecutor(services: services, language: .french)
        let plan = engine.parse("Supprime toutes les données du tableau.", context: .photo)
        var erase = plan.intents[0]
        erase.target = ObjectTarget(label: "text", originalPhrase: "toutes les données du tableau", matchesAll: true)
        let candidates = TableFixtures.benchmark(withValues: true).dataCells.map { ObjectCandidate(label: "text", boundingBox: $0.wordBoxes[0], confidence: 1) }
        struct Words: PhotoAIServices {
            var base: TableFakeServices
            var words: [ObjectCandidate]
            func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] { words }
            func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
                try await base.mask(for: candidates, target: target, in: document)
            }
            func subjectMask(in document: PhotoDocument) async throws -> MaskReference { try await base.subjectMask(in: document) }
            func horizonAngle(in document: PhotoDocument) async throws -> Double? { nil }
            func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? { nil }
            func tableGrid(in document: PhotoDocument, remembered: TableGrid?) async throws -> TableGrid? { try await base.tableGrid(in: document, remembered: remembered) }
        }
        let wordsExecutor = PhotoCommandExecutor(services: Words(base: services, words: candidates), language: .french)
        let (after, result) = await wordsExecutor.execute(erase, on: TableFixtures.document(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertEqual(after.tableMemory?.geometryKey, after.tableGeometryKey)
        XCTAssertEqual(after.rememberedTable?.dataColumns.first?.format?.suffix, "%")
        _ = executor
        // Undoing the erase drops the memory with it: it was in the same mutation.
        XCTAssertNil(TableFixtures.document().tableMemory)
    }
}
