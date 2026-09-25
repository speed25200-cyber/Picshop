import XCTest
@testable import PicshopCore

/// A6: the grid is found with its values, once they are erased (rules or not), with labels on two
/// lines, headers on two lines and dashes; never on paragraphs, a status bar or a key/value list.
final class TableGridBuilderTests: XCTestCase {
    typealias Fixture = TableCoreFixtures

    private func build(_ options: Fixture.Options, file: StaticString = #filePath, line: UInt = #line) throws -> TableGrid {
        try XCTUnwrap(TableGridBuilder.build(Fixture.input(options)), "no grid", file: file, line: line)
    }

    /// Every data cell's rect holds the centre where its value is (or would be) printed.
    private func assertCellsAreWhereTheValuesGo(_ grid: TableGrid, file: StaticString = #filePath, line: UInt = #line) {
        for row in 0..<Fixture.labels.count {
            for column in 0..<Fixture.headers.count {
                guard let cell = grid.cell(dataRow: row + 1, dataColumn: column + 1) else { return XCTFail("r\(row + 1)c\(column + 1)", file: file, line: line) }
                let center = PSPoint(x: Fixture.columnCenter(column) / Fixture.size.width, y: (Fixture.rowTop(row) + Fixture.rowHeight / 2) / Fixture.size.height)
                XCTAssertTrue(cell.rect.contains(center), "r\(row + 1)c\(column + 1)", file: file, line: line)
                XCTAssertEqual(cell.contentRect.midX, center.x, accuracy: 0.006, "r\(row + 1)c\(column + 1) x", file: file, line: line)
                XCTAssertEqual(cell.contentRect.midY, center.y, accuracy: 0.006, "r\(row + 1)c\(column + 1) y", file: file, line: line)
            }
        }
    }

    func testWithValuesAndRules() throws {
        let grid = try build(Fixture.Options(values: true))
        XCTAssertEqual(grid.names(.column), Fixture.headers)
        XCTAssertEqual(grid.names(.row), Fixture.labels)
        XCTAssertEqual(grid.dataCells.count, 45)
        XCTAssertEqual(grid.cell(dataRow: 1, dataColumn: 1)?.text, "80.9%")
        XCTAssertEqual(grid.cell(dataRow: 9, dataColumn: 5)?.text, "75.8%")
        XCTAssertTrue(grid.dataCells.allSatisfy { $0.state == .printed && !$0.wordBoxes.isEmpty })
        XCTAssertEqual(grid.dataColumns[0].format?.decimals, 1)
        XCTAssertEqual(grid.dataColumns[0].format?.suffix, "%")
        XCTAssertEqual(grid.ruling, .horizontal)
        XCTAssertEqual(grid.title, Fixture.title, "the title is not a header")
        XCTAssertGreaterThanOrEqual(grid.confidence, 0.9)
        XCTAssertTrue(grid.coversPicture)
        assertCellsAreWhereTheValuesGo(grid)
    }

    func testErasedValuesWithRulesOnly() throws {
        let grid = try build(Fixture.Options(values: false, rules: true))
        XCTAssertEqual(grid.names(.column), Fixture.headers)
        XCTAssertEqual(grid.names(.row), Fixture.labels)
        XCTAssertEqual(grid.emptyDataCells.count, 45)
        XCTAssertEqual(grid.ruling, .horizontal)
        XCTAssertGreaterThanOrEqual(grid.confidence, 0.8)
        assertCellsAreWhereTheValuesGo(grid)
        // The rules are the row edges.
        XCTAssertEqual(grid.dataRows[0].rect.minY, Fixture.headerBottom / Fixture.size.height, accuracy: 0.001)
        XCTAssertEqual(grid.dataRows[8].rect.maxY, Fixture.rowTop(9) / Fixture.size.height, accuracy: 0.001)
    }

    func testErasedValuesWithoutRulesFromTheAnchorsOnly() throws {
        let grid = try build(Fixture.Options(values: false, rules: false))
        XCTAssertEqual(grid.names(.column), Fixture.headers)
        XCTAssertEqual(grid.names(.row), Fixture.labels)
        XCTAssertEqual(grid.emptyDataCells.count, 45)
        XCTAssertEqual(grid.ruling, TableGrid.Ruling.none)
        XCTAssertGreaterThanOrEqual(grid.confidence, 0.5)
        assertCellsAreWhereTheValuesGo(grid)
    }

    func testLabelsOnTwoLinesAreOneRow() throws {
        for rules in [true, false] {
            for values in [true, false] {
                let grid = try build(Fixture.Options(values: values, rules: rules, subtitles: true))
                XCTAssertEqual(grid.dataRows.count, 9, "rules \(rules) values \(values)")
                XCTAssertEqual(grid.dataRows[0].label, "Agentic coding\nSWE-bench Verified", "rules \(rules) values \(values)")
                XCTAssertEqual(grid.match(.name("GPQA Diamond"), on: .row), .exact(7), "every label line counts")
                XCTAssertEqual(grid.match(.name("Graduate-level reasoning"), on: .row), .exact(7))
                assertCellsAreWhereTheValuesGo(grid)
            }
        }
    }

    func testHeadersOnTwoLinesAndNoTitle() throws {
        let grid = try build(Fixture.Options(values: false, rules: true, twoLineHeaders: true, title: false))
        XCTAssertEqual(grid.names(.column), Fixture.headers)
        XCTAssertNil(grid.title)
        XCTAssertEqual(grid.dataRows.count, 9)
        let withValues = try build(Fixture.Options(values: true, rules: false, twoLineHeaders: true))
        XCTAssertEqual(withValues.names(.column), Fixture.headers)
        XCTAssertEqual(withValues.title, Fixture.title)
    }

    func testDashesArePlaceholders() throws {
        let grid = try build(Fixture.Options(values: false, rules: true, dashes: [[0, 0], [3, 4]]))
        XCTAssertEqual(grid.cell(dataRow: 1, dataColumn: 1)?.state, .placeholder)
        XCTAssertEqual(grid.cell(dataRow: 4, dataColumn: 5)?.state, .placeholder)
        XCTAssertEqual(grid.emptyDataCells.count, 43)
        XCTAssertEqual(try TableSelection.cells(for: TableEditSpec(), in: grid).count, 43, "a dash is never written over")
    }

    func testNoLabelColumnAndAFullGrid() throws {
        // A spreadsheet: a header row, rows of numbers, every cell boxed.
        let size = Fixture.size
        var words: [TableGridBuilder.Word] = []
        var lines: [TableGridBuilder.RulingLine] = []
        let left = 200.0, width = 300.0, top = 400.0, pitch = 90.0
        let rows = [["Q1", "Q2", "Q3", "Q4"], ["12", "15", "9", "21"], ["7", "3", "11", "5"], ["30", "28", "35", "31"]]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() {
                let w = Double(text.count) * 17.6
                let box = PSRect(x: left + width * (Double(c) + 0.5) - w / 2, y: top + pitch * (Double(r) + 0.5) - 11.5, width: w, height: 23)
                words.append(TableGridBuilder.Word(text: text, box: box.normalized(in: size), line: r * 10 + c))
            }
        }
        for r in 0...rows.count {
            lines.append(TableGridBuilder.RulingLine(axis: .horizontal, position: (top + pitch * Double(r)) / size.height, start: left / size.width,
                                                     end: (left + 4 * width) / size.width, thickness: 0.001, contrast: 0.5))
        }
        for c in 0...4 {
            lines.append(TableGridBuilder.RulingLine(axis: .vertical, position: (left + width * Double(c)) / size.width, start: top / size.height,
                                                     end: (top + pitch * 4) / size.height, thickness: 0.001, contrast: 0.5))
        }
        let grid = try XCTUnwrap(TableGridBuilder.build(TableGridBuilder.Input(words: words, lines: lines, imageSize: size)))
        XCTAssertEqual(grid.labelColumnCount, 0)
        XCTAssertEqual(grid.names(.column), ["Q1", "Q2", "Q3", "Q4"])
        XCTAssertEqual(grid.dataRows.count, 3)
        XCTAssertEqual(grid.ruling, .full)
        XCTAssertEqual(grid.cell(dataRow: 2, dataColumn: 3)?.text, "11")
        // The vertical rules are the column edges.
        XCTAssertEqual(grid.dataColumns[1].rect.minX, (left + width) / size.width, accuracy: 0.001)
        XCTAssertEqual(grid.bounds.maxX, (left + 4 * width) / size.width, accuracy: 0.001)
    }

    func testBuildsFast() {
        let input = Fixture.input(Fixture.Options(values: true, subtitles: true))
        let start = Date()
        for _ in 0..<10 { _ = TableGridBuilder.build(input) }
        // Debug build on a CI runner; the device budget (≤ 30 ms with the detector) is far below this.
        XCTAssertLessThan(Date().timeIntervalSince(start) / 10, 0.25)
    }

    func testNotATable() {
        let paragraph = Fixture.lines(["Picshop edits your photos by voice.", "Say what you want and it happens,", "right on your iPhone, with nothing",
                                       "sent anywhere. Every edit can be", "undone in one tap."])
        XCTAssertNil(TableGridBuilder.build(TableGridBuilder.Input(words: paragraph, imageSize: Fixture.size)))

        let statusBar = Fixture.lines(["9:41 | 5G | 87%"], top: 20, gapColumns: [1400, 1560])
            + Fixture.lines(["Messages are end-to-end encrypted and", "nobody outside this chat can read them.", "Tap to learn more about it."], top: 400)
        XCTAssertNil(TableGridBuilder.build(TableGridBuilder.Input(words: statusBar, imageSize: Fixture.size)))

        let keyValue = Fixture.lines(["Name | Alice Martin", "Age | 34", "City | Lyon", "Phone | 06 12 34 56 78"], gapColumns: [700])
        XCTAssertNil(TableGridBuilder.build(TableGridBuilder.Input(words: keyValue, imageSize: Fixture.size)))
    }

    func testRememberedGeometryKeepsItsStyleAndReadsOccupancyAgain() throws {
        var remembered = try build(Fixture.Options(values: true))
        let style = TableGrid.Style(relativeSize: 0.0156, color: PSColor(hex: "#1C1C1E")!)
        for index in remembered.columns.indices where !remembered.columns[index].isLabel { remembered.columns[index].style = style }
        // Values erased by Picshop: detection finds the same table empty.
        var input = Fixture.input(Fixture.Options(values: false))
        input.remembered = remembered
        let grid = try XCTUnwrap(TableGridBuilder.build(input))
        XCTAssertEqual(grid.source, .remembered)
        XCTAssertEqual(grid.emptyDataCells.count, 45)
        XCTAssertEqual(grid.style(forDataColumn: 2), style)
        XCTAssertEqual(grid.dataColumns[0].format?.suffix, "%")
        // Nothing detected at all: the memory still answers.
        let alone = try XCTUnwrap(TableGridBuilder.build(TableGridBuilder.Input(words: [], imageSize: Fixture.size, remembered: remembered)))
        XCTAssertEqual(alone.source, .remembered)
        // A different table: the fresh one wins.
        var other = Fixture.input(Fixture.Options(values: false))
        other.words = other.words.map { word in
            var moved = word
            moved.box = PSRect(x: word.box.minX * 0.5, y: word.box.minY * 0.5, width: word.box.width * 0.5, height: word.box.height * 0.5)
            return moved
        }
        other.lines = []
        other.remembered = remembered
        XCTAssertEqual(TableGridBuilder.build(other)?.source, .detected)
    }

    func testErasedValuesLandWhereTheOldOnesWere() throws {
        let grid = try build(Fixture.Options(values: true))
        var shifted = grid
        // A value printed high in its cell: the erased cell remembers where it was.
        let index = try XCTUnwrap(shifted.cells.firstIndex { $0.kind == .data && $0.row == 1 && $0.column == 1 })
        let old = shifted.cells[index].wordBoxes[0]
        shifted.cells[index].wordBoxes = [PSRect(x: old.minX, y: shifted.cells[index].rect.minY + 0.01, width: old.width, height: old.height)]
        let erased = shifted.withValuesErased()
        XCTAssertEqual(erased.cells[index].state, .empty)
        XCTAssertEqual(erased.cells[index].contentRect.midY, shifted.cells[index].rect.minY + 0.01 + old.height / 2, accuracy: 0.004)
    }

    func testCodableRoundTripAndDeterministicID() throws {
        let grid = try build(Fixture.Options(values: true))
        let decoded = try JSONDecoder().decode(TableGrid.self, from: JSONEncoder().encode(grid))
        XCTAssertEqual(decoded, grid)
        XCTAssertEqual(try build(Fixture.Options(values: true)).id, grid.id, "the same picture, the same id")
        XCTAssertEqual(grid.id, TableGrid.makeID(bounds: grid.bounds, rows: grid.rows, columns: grid.columns))
        let input = Fixture.input()
        XCTAssertEqual(try JSONDecoder().decode(TableGridBuilder.Input.self, from: JSONEncoder().encode(input)), input, "OCR dumps paste as fixtures")
    }

    func testNameMatching() throws {
        let grid = try build(Fixture.Options(values: false))
        XCTAssertEqual(grid.match(.name("gpt six astra"), on: .column), .exact(5))
        XCTAssertEqual(grid.match(.name("GPT-6 Astra"), on: .column), .exact(5))
        XCTAssertEqual(grid.match(.name("Astra"), on: .column), .partial(5))
        XCTAssertEqual(grid.match(.name("Opus 5"), on: .column), .exact(2))
        XCTAssertEqual(grid.match(.name("Opus"), on: .column), .ambiguous([1, 2]))
        XCTAssertEqual(grid.match(.name("la dernière colonne"), on: .column), .exact(5))
        XCTAssertEqual(grid.match(.name("3e colonne"), on: .column), .exact(3))
        XCTAssertEqual(grid.match(.name("première ligne"), on: .row), .exact(1))
        XCTAssertEqual(grid.match(.name("gémini"), on: .column), .partial(4))
        XCTAssertEqual(grid.match(.name("agentic coding"), on: .row), .exact(1))
        XCTAssertEqual(grid.match(.name("agentic"), on: .row), .ambiguous([1, 2, 6]))
    }
}
