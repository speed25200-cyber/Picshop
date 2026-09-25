import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Phase 0 (T0): the frozen cross-owner pieces are real — the machine channel (ExecutionReason,
/// TableEditReport), noSubject, the fixtures, selection and values, the model fields.
final class TableContractTests: XCTestCase {
    // MARK: Machine channel

    func testEveryReasonRoundTripsThroughTheEffects() {
        for reason in ExecutionReason.allCases {
            XCTAssertEqual(reason.effect, .message("reason:" + reason.rawValue))
            XCTAssertEqual(ExecutionReason(effects: [.message("selectRegion"), reason.effect]), reason)
        }
        XCTAssertNil(ExecutionReason(effects: [.message("reason:whatever"), .selectLayer(UUID())]))
        XCTAssertEqual(ExecutionReason.noSubject.rawValue, "no_subject")
        XCTAssertEqual(ExecutionReason.verifyFailed.rawValue, "verify_failed")
    }

    func testTableReportRoundTripsAndStaysShort() {
        let group = UUID()
        let report = TableEditReport(action: .fillCells, changed: 44, kept: 1, emptyLeft: 0, dataRows: 9, dataColumns: 5,
                                     value: "random 50–90", alternative: "1; a=b", groupID: group)
        guard case .message(let message) = report.effect else { return XCTFail("a message effect") }
        XCTAssertTrue(message.hasPrefix("table:action=fillCells;changed=44;kept=1;left=0;rows=9;cols=5;value="))
        XCTAssertLessThanOrEqual(message.count, 200)
        XCTAssertEqual(TableEditReport(effects: [.message("reason:no_table"), report.effect]), report)

        let long = TableEditReport(action: .fillCells, changed: 400, kept: 0, emptyLeft: 0, dataRows: 20, dataColumns: 20,
                                   value: String(repeating: "é", count: 40), alternative: String(repeating: "à", count: 40), groupID: group)
        guard case .message(let longMessage) = long.effect else { return XCTFail("a message effect") }
        XCTAssertLessThanOrEqual(longMessage.count, 200)
        XCTAssertEqual(TableEditReport(effects: [long.effect])?.changed, 400)
        XCTAssertEqual(TableEditReport(effects: [long.effect])?.groupID, group)
        XCTAssertNil(TableEditReport(effects: [.message("table:action=nope")]))
    }

    func testMachineMessagesAreNeutralForChangedDocument() {
        let report = TableEditReport(action: .fillCells, changed: 45, kept: 0, emptyLeft: 0, dataRows: 9, dataColumns: 5)
        let filled = ExecutionResult(outcome: .applied(label: "Fill Cells"), effects: [report.effect], label: "Fill Cells")
        XCTAssertTrue(filled.changedDocument)
        XCTAssertEqual(filled.tableReport?.changed, 45)
        let failed = ExecutionResult(outcome: .failed(message: "x"), effects: [ExecutionReason.noSubject.effect])
        XCTAssertFalse(failed.changedDocument)
        XCTAssertEqual(failed.reason, .noSubject)
        XCTAssertFalse(ExecutionResult(outcome: .applied(label: "Crop"), effects: [.message("crop")], label: "Crop").changedDocument)
    }

    func testNoSubjectSpeaksBothLanguagesWithoutInternalWords() {
        XCTAssertEqual(PicshopError.noSubject.message(french: true), "Je ne vois ni personne ni sujet à détacher sur cette image.")
        XCTAssertEqual(PicshopError.noSubject.message(french: false), "There's no person or main subject to cut out in this picture.")
        XCTAssertEqual(ObjectVocabulary.frenchName(forLabel: "subject"), "sujet")
        XCTAssertNil(ObjectVocabulary.frenchName(forLabel: "zorglub"))
    }

    // MARK: Fixtures

    func testBenchmarkFixtureIsTheReportedTable() {
        let empty = TableFixtures.benchmark()
        XCTAssertEqual(empty.dataRows.count, 9)
        XCTAssertEqual(empty.dataColumns.count, 5)
        XCTAssertEqual(empty.dataCells.count, 45)
        XCTAssertEqual(empty.emptyDataCells.count, 45)
        XCTAssertEqual(empty.names(.column), TableFixtures.headers)
        XCTAssertEqual(empty.names(.row), TableFixtures.labels)
        XCTAssertTrue(empty.coversPicture)
        XCTAssertEqual(empty.style(forDataColumn: 1)?.fontName, "SFProDigits-Regular")
        XCTAssertEqual(empty.cell(dataRow: 6, dataColumn: 3).flatMap { empty.dataAddress(of: $0) }?.row, 6)

        let full = TableFixtures.benchmark(withValues: true)
        XCTAssertEqual(full.emptyDataCells.count, 0)
        XCTAssertEqual(full.dataColumns[0].format?.suffix, "%")
        XCTAssertEqual(full.id, empty.id, "the id is the geometry, not the values")

        let stray = TableFixtures.strayOne(in: TableFixtures.document())
        let overlaid = empty.overlaying(stray.layers)
        XCTAssertEqual(overlaid.cell(dataRow: 6, dataColumn: 3)?.state, .layer)
        XCTAssertEqual(overlaid.emptyDataCells.count, 44)
    }

    func testNamesMatchExactlyFirst() {
        let grid = TableFixtures.benchmark()
        XCTAssertEqual(grid.match(.name("Opus 5"), on: .column), .exact(2))
        XCTAssertEqual(grid.match(.name("opus 5.5"), on: .column), .exact(1))
        XCTAssertEqual(grid.match(.name("GPT 6 Astra"), on: .column), .exact(5))
        XCTAssertEqual(grid.match(.name("Astra"), on: .column), .partial(5))
        XCTAssertEqual(grid.match(.name("Opus"), on: .column), .ambiguous([1, 2]))
        XCTAssertEqual(grid.match(.index(-1), on: .row), .exact(9))
        XCTAssertEqual(grid.match(.name("GPT 7"), on: .column), .none)
    }

    // MARK: Selection and values

    func testSelectionFollowsD4AndThrowsClearly() throws {
        let grid = TableFixtures.benchmark().overlaying(TableFixtures.strayOne(in: TableFixtures.document()).layers)
        XCTAssertEqual(try TableSelection.cells(for: TableEditSpec(), in: grid).count, 44)
        XCTAssertEqual(try TableSelection.cells(for: TableEditSpec(onlyEmpty: false), in: grid).count, 45)
        XCTAssertEqual(try TableSelection.cells(for: TableEditSpec(rows: [.index(6)], columns: [.index(3)]), in: grid).count, 1,
                       "one named cell is overwritten")
        XCTAssertThrowsError(try TableSelection.cells(for: TableEditSpec(columns: [.name("GPT 7")]), in: grid)) { error in
            XCTAssertEqual(error as? TableEditError, .unknown(.column, "GPT 7", names: TableFixtures.headers))
        }
        XCTAssertThrowsError(try TableSelection.cells(for: TableEditSpec(columns: [.name("Opus")]), in: grid)) { error in
            XCTAssertEqual(error as? TableEditError, .ambiguous(.column, "Opus", candidates: [1, 2]))
        }
        let full = TableFixtures.benchmark(withValues: true)
        XCTAssertThrowsError(try TableSelection.cells(for: TableEditSpec(), in: full)) { error in
            XCTAssertEqual(error as? TableEditError, .nothingToDo)
        }
    }

    func testValuesAreReproduciblePerIntentAndInFormat() throws {
        let grid = TableFixtures.benchmark(withValues: true)
        let cells = grid.dataCells
        let id = UUID()
        var first = CellValueGenerator(seed: CellValueGenerator.seed(for: id))
        var again = CellValueGenerator(seed: CellValueGenerator.seed(for: id))
        var other = CellValueGenerator(seed: CellValueGenerator.seed(for: UUID()))
        let a = try first.values(.random(min: nil, max: nil, decimals: nil), for: cells, in: grid)
        XCTAssertEqual(a, try again.values(.random(min: nil, max: nil, decimals: nil), for: cells, in: grid))
        XCTAssertNotEqual(a, try other.values(.random(min: nil, max: nil, decimals: nil), for: cells, in: grid))
        XCTAssertTrue(a.allSatisfy { $0.hasSuffix("%") && $0.split(separator: ".").last?.count == 2 }, "\(a)")
        var ranged = CellValueGenerator(seed: 7)
        let values = try ranged.values(.random(min: 50, max: 90, decimals: 0), for: cells, in: TableFixtures.benchmark())
        XCTAssertTrue(values.allSatisfy { Int($0).map { (50...90).contains($0) } ?? false }, "\(values)")
        var constant = CellValueGenerator(seed: 1)
        XCTAssertEqual(try constant.values(.constant("1"), for: Array(cells.prefix(3)), in: grid), ["1", "1", "1"])
        XCTAssertThrowsError(try constant.values(.list(["1", "2"]), for: Array(cells.prefix(3)), in: grid))
    }

    // MARK: Model fields

    func testTableStepsNormalize() {
        let context = IntentContext(mode: .photo, table: TableFixtures.benchmark())
        let fill = IntentNormalizer.normalize(RawIntentStep(action: "fill_table", text: "1", cells: "empty"), context: context)
        XCTAssertEqual(fill?.action, .fillCells)
        XCTAssertEqual(fill?.table, TableEditSpec(onlyEmpty: true, value: .constant("1")))

        let random = IntentNormalizer.normalize(RawIntentStep(action: "fillCells", color: "red", cells: "all", row: "last", column: "Opus 5|3",
                                                              values: "random", min: 50, max: 90, decimals: 1), context: context)
        XCTAssertEqual(random?.table?.rows, [.index(-1)])
        XCTAssertEqual(random?.table?.columns, [.name("Opus 5"), .index(3)])
        XCTAssertEqual(random?.table?.onlyEmpty, false)
        XCTAssertEqual(random?.table?.value, .random(min: 50, max: 90, decimals: 1))
        XCTAssertEqual(random?.table?.style?.color, .red)

        XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "fillCells"), context: context)?.confidence, 0.5)
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "fillCells", text: "1"), context: .video), "photo only")
        XCTAssertEqual(IntentNormalizer.action(named: "highlight_column"), .highlightCells)
        XCTAssertEqual(IntentNormalizer.action(named: "empty-cells"), .clearCells)
    }

    func testPrimitiveStepsNormalizeStrictly() {
        let context = IntentContext.photo
        let edit = IntentNormalizer.normalize(RawIntentStep(action: "editText", text: "Bilan 2026", ref: "t3", weight: "bold"), context: context)
        XCTAssertEqual(edit?.ref, .text(3))
        XCTAssertEqual(edit?.textStyle?.weight, .bold)
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "editText", text: "x", ref: "the title"), context: context), "an id that is not one")
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "editText", text: "x", ref: "o1"), context: context), "an object is not text")
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "x", weight: "extra-wide"), context: context))

        let erase = IntentNormalizer.normalize(RawIntentStep(action: "eraseRegion", box: PSRect(x: 100, y: 200, width: 300, height: 100)), context: context)
        XCTAssertEqual(erase?.region, PSRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "eraseRegion"), context: context)?.confidence, 0.5,
                       "nothing named: the executor asks for a box")
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "eraseRegion", box: PSRect(x: 0.5, y: 0.5, width: 0, height: 0.1)), context: context))

        let add = IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "Nouveau", placement: nil, point: PSPoint(x: 0.8, y: 0.3),
                                                           size: "match", align: "right", match: nil), context: context)
        XCTAssertEqual(add?.target?.point, PSPoint(x: 0.8, y: 0.3))
        XCTAssertEqual(add?.textStyle, TextStyleSpec(alignment: .trailing, match: .nearby))
        XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "a", size: "32"), context: context)?.textStyle?.size, .relative(0.032))
        XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "a", size: "x1.5"), context: context)?.textStyle?.size, .scale(1.5))
        XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "replaceText", text: "Soldes", replacement: "Promo", ref: "t1"), context: context)?.action,
                       .editText, "on a photo, replaceText edits the block")
    }

    func testStepsRoundTripThroughTheModelVocabulary() {
        let context = IntentContext.photo
        let intents = [
            EditIntent(action: .fillCells, table: TableEditSpec(rows: [.name("Agentic coding")], columns: [.index(-1)], onlyEmpty: false,
                                                                value: .random(min: 50, max: 90, decimals: 1))),
            EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1"))),
            EditIntent(action: .editText, text: "Promo", ref: .text(1), textStyle: TextStyleSpec(size: .scale(1.35), weight: .bold, match: .ref(.text(2)))),
            EditIntent(action: .eraseRegion, region: PSRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
            EditIntent(action: .moveText, placement: .bottom, ref: .layer(2)),
        ]
        for intent in intents {
            let step = RawIntentStep(intent: intent)
            let back = IntentNormalizer.normalize(step, context: context)
            XCTAssertEqual(back?.action, intent.action, "\(step)")
            XCTAssertEqual(back?.table, intent.table, "\(step)")
            XCTAssertEqual(back?.ref, intent.ref, "\(step)")
            XCTAssertEqual(back?.region, intent.region, "\(step)")
            XCTAssertEqual(back?.textStyle, intent.textStyle, "\(step)")
        }
    }

    // MARK: Executor (Phase 0 stubs)

    func testTableStepsWithoutATableSayNoTable() async {
        let executor = PhotoCommandExecutor(services: TableFakeServices(grid: nil), language: .french)
        let intent = EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1")))
        let (document, result) = await executor.execute(intent, on: TableFixtures.document(), context: IntentContext(mode: .photo))
        XCTAssertEqual(result.reason, .noTable)
        XCTAssertEqual(result.outcome.message, "Je ne vois pas de tableau sur cette image. Recadre dessus, puis redis-le.")
        XCTAssertEqual(document.layers.count, 1)
    }

    func testRememberedTableIsUsedWhenDetectionFindsNothing() async {
        let services = TableFakeServices(grid: nil)
        let executor = PhotoCommandExecutor(services: services)
        let document = TableFixtures.document(grid: TableFixtures.benchmark(withValues: true))
        let grid = await executor.currentTable(in: document)
        XCTAssertEqual(grid?.source, .remembered)
        XCTAssertEqual(grid?.emptyDataCells.count, 45, "remembered values were erased")
        XCTAssertEqual(grid?.dataColumns.first?.format?.suffix, "%", "the format is remembered")
        XCTAssertEqual(services.calls.tableGrid, 1)
    }

    func testSubjectStepsOnATableScreenshotFailWithNoSubject() async {
        let executor = PhotoCommandExecutor(services: TableFakeServices(), language: .french)
        let (_, result) = await executor.execute(EditIntent(action: .textBehind, text: "1"), on: TableFixtures.document(), context: .photo)
        XCTAssertEqual(result.outcome, .failed(message: PicshopError.noSubject.message(french: true)))
        XCTAssertFalse(result.outcome.message?.contains("subject") ?? true)
    }
}
