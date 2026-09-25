import XCTest
import Foundation
import PicshopCore
@testable import PicshopImaging

/// A gray or RGB picture drawn by hand: rules, bands and glyph-like marks at known places.
struct SyntheticPicture {
    var width: Int
    var height: Int
    var gray: [UInt8]

    init(width: Int, height: Int, paper: UInt8 = 255) {
        self.width = width
        self.height = height
        gray = [UInt8](repeating: paper, count: width * height)
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, level: UInt8) {
        let rows = max(0, y)..<max(max(0, y), min(height, y + h)), columns = max(0, x)..<max(max(0, x), min(width, x + w))
        for row in rows {
            for column in columns { gray[row * width + column] = level }
        }
    }

    /// A word-like mark: `count` glyphs, each a stem and a bowl-ish bar pattern, `size` px tall.
    mutating func word(x: Int, baseline: Int, size: Int, count: Int, stem: Int, level: UInt8) {
        var left = x
        for glyph in 0..<count {
            let top = baseline - size
            fill(x: left, y: top, width: stem, height: size, level: level)
            if glyph % 2 == 0 {
                fill(x: left, y: top, width: size / 2, height: stem, level: level)
                fill(x: left + size / 2 - stem, y: top, width: stem, height: size, level: level)
                fill(x: left, y: baseline - stem, width: size / 2, height: stem, level: level)
            }
            left += size / 2 + max(3, size / 5)
        }
    }

    var rgba: [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = gray[index]
            bytes[index * 4 + 1] = gray[index]
            bytes[index * 4 + 2] = gray[index]
        }
        return bytes
    }

    /// RGB with a text colour for every pixel darker than the paper (for colour checks).
    func rgba(ink: (UInt8, UInt8, UInt8), paper: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let isInk = gray[index] != paper
            bytes[index * 4] = isInk ? ink.0 : gray[index]
            bytes[index * 4 + 1] = isInk ? ink.1 : gray[index]
            bytes[index * 4 + 2] = isInk ? ink.2 : gray[index]
        }
        return bytes
    }

    func box(x: Int, y: Int, width w: Int, height h: Int) -> PSRect {
        PSRect(x: Double(x) / Double(width), y: Double(y) / Double(height), width: Double(w) / Double(width), height: Double(h) / Double(height))
    }
}

/// Table detection, the pure part (contract §6): ruling lines, bands, typography, the grid refinement,
/// the word bridge. Synthetic bitmaps, no Vision: runs on Linux.
final class TableDetectionTests: XCTestCase {
    func testWordBridgeKeepsTextBoxLineAndConfidence() {
        let word = VisionWord(text: "80.9%", box: PSRect(x: 0.41, y: 0.22, width: 0.05, height: 0.012), line: 7, confidence: 0.8)
        XCTAssertEqual(TableGridBuilder.Word(word), TableGridBuilder.Word(text: "80.9%", box: word.box, line: 7, confidence: 0.8))
    }

    func testWeightClassesFollowTheCalibratedThresholds() {
        let thresholds = TableStyleEstimator.Calibration.weightThresholds
        XCTAssertEqual(thresholds.count, 3, "regular | medium | semibold | bold")
        XCTAssertEqual(thresholds, thresholds.sorted())
        XCTAssertEqual(TableStyleEstimator.weight(strokeToXHeight: 0), .regular)
        XCTAssertEqual(TableStyleEstimator.weight(strokeToXHeight: 1), .bold)
        XCTAssertEqual(TableStyleEstimator.weight(strokeToXHeight: .nan), .regular)
        let classes = [0.0, thresholds[0], thresholds[1], thresholds[2]].map { TableStyleEstimator.weight(strokeToXHeight: $0 + 0.001) }
        XCTAssertEqual(classes, [.regular, .medium, .semibold, .bold])
    }

    func testCalibrationIsPlausible() {
        XCTAssertTrue((0.6...1.8).contains(TableStyleEstimator.Calibration.boxHeightToFontSize))
        // SF Pro: cap height 0.705 em, x-height 0.528 em.
        XCTAssertEqual(1 / TableStyleEstimator.Calibration.capHeightToFontSize, 0.705, accuracy: 0.01)
        XCTAssertEqual(1 / TableStyleEstimator.Calibration.xHeightToFontSize, 0.528, accuracy: 0.01)
    }

    func testMalformedBuffersFindNothing() {
        XCTAssertEqual(RulingLineDetector.detect(gray: [], width: 0, height: 0), RulingLineDetector.Output())
        XCTAssertEqual(RulingLineDetector.detect(gray: [0, 0, 0], width: 10, height: 10), RulingLineDetector.Output())
        XCTAssertNil(TableStyleEstimator.style(of: [], texts: [], rgba: [], width: 0, height: 0))
        XCTAssertNil(TableStyleEstimator.style(of: [PSRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)], texts: ["1"], rgba: [0, 0], width: 4, height: 4))
    }

    func testBlankPageHasNoRulesAndNoBands() {
        let width = 240, height = 320
        let output = RulingLineDetector.detect(gray: [UInt8](repeating: 250, count: width * height), width: width, height: height)
        XCTAssertTrue(output.lines.isEmpty)
        XCTAssertTrue(output.bands.isEmpty)
    }

    // MARK: Ruling lines

    /// 1-px #E0E0E0 rules on white, every 60 px (11 across, 7 down), like a full grid.
    private func fullGrid(paper: UInt8 = 255, rule: UInt8 = 0xE0) -> (SyntheticPicture, rows: [Int], columns: [Int]) {
        var picture = SyntheticPicture(width: 600, height: 800, paper: paper)
        let rows = (0..<11).map { 100 + $0 * 60 }, columns = (0..<7).map { 60 + $0 * 80 }
        for y in rows { picture.fill(x: 60, y: y, width: 481, height: 1, level: rule) }
        for x in columns { picture.fill(x: x, y: 100, width: 1, height: 601, level: rule) }
        return (picture, rows, columns)
    }

    func testAFullGridGivesEveryRuleWithinAPixel() {
        let (picture, rows, columns) = fullGrid()
        let output = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        let horizontal = output.lines.filter { $0.axis == .horizontal }.sorted { $0.position < $1.position }
        let vertical = output.lines.filter { $0.axis == .vertical }.sorted { $0.position < $1.position }
        XCTAssertEqual(horizontal.count, 11)
        XCTAssertEqual(vertical.count, 7)
        for (line, y) in zip(horizontal, rows) {
            XCTAssertEqual(line.position * 800, Double(y) + 0.5, accuracy: 1.5)
            XCTAssertEqual(line.start * 600, 60, accuracy: 2)
            XCTAssertEqual(line.end * 600, 541, accuracy: 2)
            XCTAssertLessThanOrEqual(line.thickness * 800, 3)
            XCTAssertGreaterThan(line.contrast, 0.05)
        }
        for (line, x) in zip(vertical, columns) {
            XCTAssertEqual(line.position * 600, Double(x) + 0.5, accuracy: 1.5)
            XCTAssertEqual(line.start * 800, 100, accuracy: 2)
            XCTAssertEqual(line.end * 800, 701, accuracy: 2)
        }
    }

    func testHorizontalRulesOnlyGiveNoVerticalLines() {
        var picture = SyntheticPicture(width: 600, height: 800)
        for index in 0..<10 { picture.fill(x: 40, y: 120 + index * 60, width: 520, height: 1, level: 0xE3) }
        let output = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        XCTAssertEqual(output.lines.filter { $0.axis == .horizontal }.count, 10)
        XCTAssertTrue(output.lines.filter { $0.axis == .vertical }.isEmpty)
    }

    func testWordsNeverBecomeLines() {
        var picture = SyntheticPicture(width: 800, height: 600)
        // Rows of dense words, including long bold ones, as a table's labels and values.
        for row in 0..<8 {
            var x = 20
            for word in 0..<6 {
                picture.word(x: x, baseline: 60 + row * 64, size: 30, count: 3 + (word + row) % 5, stem: row % 2 == 0 ? 3 : 6, level: 0x1C)
                x += 130
            }
        }
        let output = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        XCTAssertTrue(output.lines.isEmpty, "\(output.lines)")
    }

    func testDarkModeRulesAreFound() {
        let (picture, _, _) = fullGrid(paper: 0x1C, rule: 0x48)
        let output = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        XCTAssertEqual(output.lines.filter { $0.axis == .horizontal }.count, 11)
        XCTAssertEqual(output.lines.filter { $0.axis == .vertical }.count, 7)
    }

    func testMinPoolingKeepsAOnePixelRuleOnEitherRow() {
        for y in [301, 302] {
            var picture = SyntheticPicture(width: 500, height: 600)
            picture.fill(x: 20, y: y, width: 460, height: 1, level: 0xE3)
            let lines = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height).lines
            XCTAssertEqual(lines.count, 1, "row \(y)")
            XCTAssertEqual((lines.first?.position ?? 0) * 600, Double(y), accuracy: 1.5)
        }
    }

    func testShortStrokesAndThickBarsAreNotRules() {
        var picture = SyntheticPicture(width: 600, height: 600)
        picture.fill(x: 20, y: 100, width: 60, height: 1, level: 0x80)   // 10 % of the width
        picture.fill(x: 20, y: 300, width: 560, height: 40, level: 0x20) // a filled bar, not a rule
        let lines = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height).lines
        XCTAssertTrue(lines.filter { $0.axis == .horizontal }.isEmpty, "\(lines)")
    }

    func testZebraRowsGiveBands() {
        var picture = SyntheticPicture(width: 600, height: 800)
        let stripes = [(100, 160), (220, 280), (340, 400)]
        for (start, end) in stripes { picture.fill(x: 0, y: start, width: 600, height: end - start, level: 0xF2) }
        let bands = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height).bands.filter { $0.axis == .horizontal }
        XCTAssertEqual(bands.count, 3)
        for (band, stripe) in zip(bands, stripes) {
            XCTAssertEqual(band.start * 800, Double(stripe.0), accuracy: 2.5)
            XCTAssertEqual(band.end * 800, Double(stripe.1), accuracy: 2.5)
        }
    }

    func testDetectorOnAFullSizeScreenshotStaysFast() {
        var picture = SyntheticPicture(width: 1709, height: 2048)
        for index in 0..<11 { picture.fill(x: 80, y: 400 + index * 140, width: 1550, height: 1, level: 0xE3) }
        for row in 0..<10 { picture.word(x: 100, baseline: 480 + row * 140, size: 32, count: 8, stem: 3, level: 0x1C) }
        let start = Date()
        let output = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(output.lines.count, 11)
        // ≤ 30 ms on an A18 in release; debug builds on CI get far more room.
        XCTAssertLessThan(elapsed, 5, "detector took \(elapsed) s")
    }

    // MARK: Typography

    /// "1"-like glyphs: a stem `stem` px wide and `size` px tall, 5 per word.
    private func ones(stem: Int, size: Int = 44, level: UInt8 = 0x1C) -> (SyntheticPicture, [PSRect]) {
        var picture = SyntheticPicture(width: 800, height: 600)
        var boxes: [PSRect] = []
        for word in 0..<4 {
            let x = 60 + word * 180, baseline = 200 + (word % 2) * 120
            for glyph in 0..<3 { picture.fill(x: x + glyph * 30, y: baseline - size, width: stem, height: size, level: level) }
            boxes.append(picture.box(x: x - 4, y: baseline - Int(Double(size) * 1.1), width: 70 + stem, height: Int(Double(size) * 1.4)))
        }
        return (picture, boxes)
    }

    func testDigitHeightGivesTheFontSize() throws {
        let (picture, boxes) = ones(stem: 3)
        let style = try XCTUnwrap(TableStyleEstimator.style(of: boxes, texts: ["111", "111", "111", "111"], rgba: picture.rgba, width: 800, height: 600))
        // Glyphs 44 px tall are SF Pro's cap height: 44 / 0.705 px, over a 600 px canvas.
        XCTAssertEqual(style.relativeSize * 600, 44 * TableStyleEstimator.Calibration.capHeightToFontSize, accuracy: 1)
        XCTAssertEqual(style.color.red, Double(0x1C) / 255, accuracy: 0.01)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(style.design, .sans)
    }

    func testXHeightTextGivesTheFontSizeFromTheXHeight() throws {
        var picture = SyntheticPicture(width: 600, height: 400)
        picture.word(x: 40, baseline: 200, size: 20, count: 6, stem: 2, level: 0x30)
        let box = picture.box(x: 36, y: 172, width: 160, height: 36)
        let style = try XCTUnwrap(TableStyleEstimator.style(of: [box], texts: ["onarcs"], rgba: picture.rgba, width: 600, height: 400))
        XCTAssertEqual(style.relativeSize * 400, 20 * TableStyleEstimator.Calibration.xHeightToFontSize, accuracy: 1)
    }

    func testStrokeWidthSortsWeights() throws {
        let thin = try XCTUnwrap(TableStyleEstimator.style(of: ones(stem: 3).1, texts: ["111"], rgba: ones(stem: 3).0.rgba, width: 800, height: 600))
        let heavy = try XCTUnwrap(TableStyleEstimator.style(of: ones(stem: 8).1, texts: ["111"], rgba: ones(stem: 8).0.rgba, width: 800, height: 600))
        XCTAssertEqual(thin.weight, .regular)
        XCTAssertEqual(heavy.weight, .bold)
    }

    func testColourIsTheInkNotTheAntialiasing() throws {
        let (picture, boxes) = ones(stem: 4, level: 0x40)
        let red = picture.rgba(ink: (200, 30, 40), paper: 255)
        let style = try XCTUnwrap(TableStyleEstimator.style(of: boxes, texts: ["111"], rgba: red, width: 800, height: 600))
        XCTAssertEqual(style.color.red, 200 / 255, accuracy: 0.02)
        XCTAssertEqual(style.color.green, 30 / 255, accuracy: 0.02)
        XCTAssertEqual(style.color.blue, 40 / 255, accuracy: 0.02)
    }

    func testLightTextOnADarkTableReadsLight() throws {
        var picture = SyntheticPicture(width: 800, height: 600, paper: 0x1C)
        var boxes: [PSRect] = []
        for word in 0..<3 {
            for glyph in 0..<3 { picture.fill(x: 60 + word * 200 + glyph * 30, y: 156, width: 3, height: 44, level: 0xEB) }
            boxes.append(picture.box(x: 56 + word * 200, y: 150, width: 80, height: 56))
        }
        let style = try XCTUnwrap(TableStyleEstimator.style(of: boxes, texts: ["111"], rgba: picture.rgba, width: 800, height: 600))
        XCTAssertEqual(style.color.red, Double(0xEB) / 255, accuracy: 0.01)
        XCTAssertEqual(style.relativeSize * 600, 44 * TableStyleEstimator.Calibration.capHeightToFontSize, accuracy: 1)
    }

    // MARK: Grid refinement

    /// A 3 × 3 grid (1 header row, 1 label column) over a 600 × 400 picture; 2 × 2 data cells.
    private func grid(values: [String: String] = [:]) -> TableGrid {
        let xs = [0.1, 0.4, 0.65, 0.9], ys = [0.1, 0.3, 0.55, 0.8]
        var rows: [TableGrid.Row] = [], columns: [TableGrid.Column] = [], cells: [TableGrid.Cell] = []
        for r in 0..<3 {
            rows.append(TableGrid.Row(index: r, rect: PSRect(x: 0.1, y: ys[r], width: 0.8, height: ys[r + 1] - ys[r]), label: r == 0 ? "" : "Row \(r)", isHeader: r == 0))
        }
        for c in 0..<3 {
            columns.append(TableGrid.Column(index: c, rect: PSRect(x: xs[c], y: 0.1, width: xs[c + 1] - xs[c], height: 0.7), header: c == 0 ? "" : "Col \(c)", isLabel: c == 0))
        }
        for r in 0..<3 {
            for c in 0..<3 {
                let rect = PSRect(x: xs[c], y: ys[r], width: xs[c + 1] - xs[c], height: ys[r + 1] - ys[r])
                let kind: TableGrid.CellKind = r == 0 ? (c == 0 ? .corner : .header) : (c == 0 ? .label : .data)
                let text = values["\(r)\(c)"] ?? ""
                cells.append(TableGrid.Cell(row: r, column: c, rect: rect, contentRect: rect.insetBy(dx: 0.01, dy: 0.01), text: text, kind: kind,
                                            state: text.isEmpty ? .empty : .printed))
            }
        }
        return TableGrid(id: "g", bounds: PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7), title: nil, rows: rows, columns: columns, cells: cells,
                         headerRowCount: 1, labelColumnCount: 1, ruling: .horizontal, bodyStyle: nil, confidence: 0.9, source: .detected)
    }

    func testInkCheckMarksAMissedValueButNotASmudge() {
        var picture = SyntheticPicture(width: 600, height: 400)
        // r1c1: a value OCR missed (dark strokes); r1c2: an inpainting smudge (faint); r2 empty.
        picture.fill(x: 310, y: 150, width: 6, height: 30, level: 0x20)
        picture.fill(x: 330, y: 150, width: 6, height: 30, level: 0x20)
        picture.fill(x: 440, y: 140, width: 60, height: 40, level: 0xF6)
        let checked = TableGridRefiner.inkChecked(grid(), gray: picture.gray, width: 600, height: 400)
        let data = checked.cells.filter { $0.kind == .data }
        XCTAssertEqual(data.map(\.state), [.printed, .empty, .empty, .empty])
        XCTAssertEqual(data[0].text, "")
    }

    func testInkCoverageReadsDarkTables() {
        var picture = SyntheticPicture(width: 100, height: 100, paper: 0x1C)
        picture.fill(x: 40, y: 40, width: 10, height: 10, level: 0xE0)
        XCTAssertEqual(TableGridRefiner.inkCoverage(in: .unit, gray: picture.gray, width: 100, height: 100), 0.01, accuracy: 0.001)
        XCTAssertEqual(TableGridRefiner.inkCoverage(in: PSRect(x: 0, y: 0, width: 0.3, height: 0.3), gray: picture.gray, width: 100, height: 100), 0)
    }

    func testRememberedGridGetsFreshOccupancy() throws {
        var remembered = grid(values: ["11": "80.9%", "12": "72.5%", "21": "61.0%", "22": "44.3%"])
        remembered.bodyStyle = TableGrid.Style(relativeSize: 0.02, color: .black)
        remembered.source = .detected
        // After the erase: one value is left, one layer id to forget.
        remembered.cells[4].layerID = UUID()
        let words = [TableGridBuilder.Word(text: "44.3%", box: PSRect(x: 0.72, y: 0.66, width: 0.1, height: 0.04), line: 3),
                     TableGridBuilder.Word(text: "—", box: PSRect(x: 0.5, y: 0.66, width: 0.03, height: 0.04), line: 3)]
        let blank = [UInt8](repeating: 255, count: 600 * 400)
        let result = try XCTUnwrap(TableGridRefiner.refine(fresh: nil, words: words, gray: blank, rgba: SyntheticPicture(width: 600, height: 400).rgba,
                                                          width: 600, height: 400, remembered: remembered))
        XCTAssertEqual(result.source, .remembered)
        XCTAssertEqual(result.bodyStyle, remembered.bodyStyle)
        XCTAssertEqual(result.bounds, remembered.bounds)
        XCTAssertEqual(result.dataCells.map(\.state), [.empty, .empty, .placeholder, .printed])
        XCTAssertEqual(result.dataCells.map(\.text), ["", "", "—", "44.3%"])
        XCTAssertTrue(result.cells.allSatisfy { $0.layerID == nil })
        XCTAssertEqual(result.names(.column), ["Col 1", "Col 2"], "headers keep their remembered text")
    }

    func testAFreshGridThatMovedIsNotTheRememberedOne() throws {
        let remembered = grid()
        var fresh = grid()
        fresh.bounds = PSRect(x: 0.3, y: 0.3, width: 0.5, height: 0.5)
        let blank = SyntheticPicture(width: 600, height: 400)
        let result = try XCTUnwrap(TableGridRefiner.refine(fresh: fresh, words: [], gray: blank.gray, rgba: blank.rgba, width: 600, height: 400, remembered: remembered))
        XCTAssertEqual(result.source, .detected)
        XCTAssertNil(TableGridRefiner.refine(fresh: nil, words: [], gray: blank.gray, rgba: blank.rgba, width: 600, height: 400, remembered: nil))
    }

    func testColumnsAreStyledFromTheirValuesElseTheLabels() throws {
        var picture = SyntheticPicture(width: 600, height: 400)
        var table = grid()
        // Column 1 has two right-aligned values ("11"), drawn 20 px tall; column 2 is empty.
        for (row, top) in [(1, 150), (2, 250)] {
            let x = 368
            picture.fill(x: x, y: top, width: 3, height: 20, level: 0x1C)
            picture.fill(x: x + 10, y: top, width: 3, height: 20, level: 0x1C)
            let index = table.cells.firstIndex { $0.row == row && $0.column == 1 }!
            table.cells[index].text = "11"
            table.cells[index].state = .printed
            table.cells[index].wordBoxes = [picture.box(x: x - 1, y: top - 2, width: 16, height: 24)]
        }
        // Row labels, 14 px capitals.
        for (row, top) in [(1, 160), (2, 260)] {
            picture.fill(x: 70, y: top, width: 2, height: 14, level: 0x55)
            picture.fill(x: 80, y: top, width: 2, height: 14, level: 0x55)
            let index = table.cells.firstIndex { $0.row == row && $0.column == 0 }!
            table.cells[index].text = "II"
            table.cells[index].wordBoxes = [picture.box(x: 68, y: top - 2, width: 16, height: 18)]
        }
        let styled = TableGridRefiner.styled(table, rgba: picture.rgba, width: 600, height: 400, remembered: nil)
        let first = try XCTUnwrap(styled.style(forDataColumn: 1)), second = try XCTUnwrap(styled.style(forDataColumn: 2))
        XCTAssertEqual(first.alignment, .trailing)
        XCTAssertEqual(first.relativeSize * 400, 20 * TableStyleEstimator.Calibration.capHeightToFontSize, accuracy: 1)
        XCTAssertEqual(second.alignment, .center, "from the labels, centred")
        XCTAssertEqual(second.relativeSize * 400, 14 * TableStyleEstimator.Calibration.capHeightToFontSize, accuracy: 1)
        XCTAssertEqual(second.color.red, Double(0x55) / 255, accuracy: 0.01)
        XCTAssertNotNil(styled.bodyStyle)
    }

    func testRememberedColumnStylesWinOverTheLabels() throws {
        var remembered = grid()
        let kept = TableGrid.Style(relativeSize: 0.031, color: .blue, weight: .semibold, alignment: .trailing)
        remembered.columns[2].style = kept
        let blank = SyntheticPicture(width: 600, height: 400)
        let styled = TableGridRefiner.styled(grid(), rgba: blank.rgba, width: 600, height: 400, remembered: remembered)
        XCTAssertEqual(styled.style(forDataColumn: 2), kept)
        XCTAssertNil(styled.columns[1].style, "nothing to measure and nothing remembered")
    }

    func testAlignmentVotes() {
        func cell(_ word: PSRect) -> TableGrid.Cell {
            TableGrid.Cell(row: 1, column: 1, rect: PSRect(x: 0, y: 0, width: 1, height: 1), contentRect: PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                           text: "1", wordBoxes: [word], kind: .data, state: .printed)
        }
        XCTAssertEqual(TableGridRefiner.alignment(of: [cell(PSRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1))]), .leading)
        XCTAssertEqual(TableGridRefiner.alignment(of: [cell(PSRect(x: 0.7, y: 0.4, width: 0.2, height: 0.1))]), .trailing)
        XCTAssertEqual(TableGridRefiner.alignment(of: [cell(PSRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1))]), .center)
        XCTAssertEqual(TableGridRefiner.alignment(of: []), .center)
    }

    func testMedianStyle() throws {
        let styles = [TableGrid.Style(relativeSize: 0.01, color: .black, weight: .bold),
                      TableGrid.Style(relativeSize: 0.02, color: .white, weight: .regular),
                      TableGrid.Style(relativeSize: 0.03, color: .black, weight: .regular)]
        let median = try XCTUnwrap(TableGridRefiner.medianStyle(styles))
        XCTAssertEqual(median.relativeSize, 0.02)
        XCTAssertEqual(median.color.red, 0)
        XCTAssertEqual(median.weight, .regular)
        XCTAssertNil(TableGridRefiner.medianStyle([]))
    }

    /// Hairline separators as light as #E3E3E3 on white are rules (the reported table's style).
    func testHairlineRulesAreFound() {
        let width = 1709, height = 2048
        var gray = [UInt8](repeating: 255, count: width * height)
        for index in 0..<10 {
            let y = 390 + index * 150
            for x in 80..<1625 { gray[y * width + x] = 227 }
        }
        let lines = RulingLineDetector.detect(gray: gray, width: width, height: height).lines
        XCTAssertEqual(lines.filter { $0.axis == .horizontal }.count, 10)
        XCTAssertTrue(lines.filter { $0.axis == .vertical }.isEmpty)
    }
}
