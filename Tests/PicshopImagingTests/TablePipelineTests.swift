import XCTest
import Foundation
import PicshopCore
@testable import PicshopImaging

/// The benchmark screenshot of the report, drawn by hand at 1709 × 2048 with Vision-like words: the
/// whole pure pipeline (RulingLineDetector, TableGridBuilder, TableGridRefiner) on Linux, with the
/// values, with them erased, and in dark mode with a full grid.
final class TablePipelineTests: XCTestCase {
    static let width = 1709, height = 2048
    static let headers = [["Claude", "Opus 5.5"], ["Claude", "Opus 5"], ["Fable", "5.1"], ["Gemini", "3.5 Pro"], ["GPT-6", "Astra"]]
    static let labels = [["Agentic coding"], ["Agentic terminal", "coding"], ["Scaled tool use"], ["Multidisciplinary", "reasoning"],
                         ["Novel problem", "solving"], ["Agentic computer", "use"], ["Graduate-level", "reasoning"], ["Visual reasoning"],
                         ["Knowledge work"]]
    /// Table geometry, in pixels.
    static let left = 80, labelRight = 620, columnWidth = 201, headerTop = 250, firstRule = 390, rowHeight = 150
    static var right: Int { labelRight + 5 * columnWidth }
    /// 32 px type: cap height 22.6 px, x-height 16.9 px (SF Pro).
    static let fontSize = 32.0

    struct Drawing {
        var picture: SyntheticPicture
        var words: [TableGridBuilder.Word]
        /// Centre of each data cell's value, row-major (pixels).
        var centres: [(x: Double, y: Double)]
    }

    static func value(row: Int, column: Int) -> String { "\(50 + (row * 7 + column * 13) % 45).\((row + column) % 10)%" }

    static func draw(values: Bool, dark: Bool = false, fullGrid: Bool = false) -> Drawing {
        let paper: UInt8 = dark ? 0x1C : 0xFF, ink: UInt8 = dark ? 0xEB : 0x1C, rule: UInt8 = dark ? 0x48 : 0xE3
        var picture = SyntheticPicture(width: width, height: height, paper: paper)
        var words: [TableGridBuilder.Word] = []
        var line = 0
        let capHeight = Int((fontSize * 0.705).rounded())

        /// A word of `text` at `x` on `baseline`, drawn as glyph marks as tall as its letters say.
        func word(_ text: String, x: Int, baseline: Int, size: Double = fontSize) {
            let tall = TableStyleEstimator.glyphClasses(of: text)
            let glyph = Int((size * (tall.short > tall.tall ? 0.528 : 0.705)).rounded())
            let advance = Int(size * 0.55)
            picture.word(x: x, baseline: baseline, size: glyph, count: max(1, text.count), stem: max(2, Int(size * 0.085)), level: ink)
            let widthPx = Double(max(1, text.count) * advance)
            words.append(TableGridBuilder.Word(text: text, box: PSRect(x: Double(x) / Double(width), y: (Double(baseline) - 0.8 * size) / Double(height),
                                                                       width: widthPx / Double(width), height: size / Double(height)), line: line, confidence: 0.95))
        }
        func lineOfWords(_ text: String, x: Int, baseline: Int, size: Double = fontSize) {
            var cursor = x
            for token in text.split(separator: " ") {
                word(String(token), x: cursor, baseline: baseline, size: size)
                cursor += Int(Double(token.count + 1) * size * 0.55)
            }
            line += 1
        }

        lineOfWords("Claude Opus 5.5", x: left, baseline: 170, size: 56)
        // Two-line headers, centred on their columns.
        for lineIndex in 0..<2 {
            for (column, header) in headers.enumerated() {
                let centre = labelRight + column * columnWidth + columnWidth / 2
                let text = header[lineIndex]
                lineOfWords(text, x: centre - Int(Double(text.count) * 26 * 0.55 / 2), baseline: 310 + lineIndex * 40, size: 26)
            }
        }
        var centres: [(x: Double, y: Double)] = []
        for (row, label) in labels.enumerated() {
            let middle = firstRule + row * rowHeight + rowHeight / 2
            let baselines = label.count == 1 ? [middle + capHeight / 2] : [middle - 8, middle + 32]
            for (text, baseline) in zip(label, baselines) { lineOfWords(text, x: left + 20, baseline: baseline) }
            for column in 0..<5 {
                let centre = labelRight + column * columnWidth + columnWidth / 2
                centres.append((Double(centre), Double(middle)))
                if values {
                    let text = value(row: row, column: column)
                    lineOfWords(text, x: centre - Int(Double(text.count) * fontSize * 0.55 / 2), baseline: middle + capHeight / 2)
                }
            }
        }
        for index in 0...9 { picture.fill(x: left, y: firstRule + index * rowHeight, width: right - left, height: 1, level: rule) }
        if fullGrid {
            picture.fill(x: left, y: headerTop, width: right - left, height: 1, level: rule)
            for x in [left, labelRight] + (1...5).map({ labelRight + $0 * columnWidth }) {
                picture.fill(x: x, y: headerTop, width: 1, height: firstRule + 9 * rowHeight - headerTop + 1, level: rule)
            }
        }
        return Drawing(picture: picture, words: words, centres: centres)
    }

    static func grid(of drawing: Drawing, remembered: TableGrid? = nil) -> TableGrid? {
        let picture = drawing.picture
        let rules = RulingLineDetector.detect(gray: picture.gray, width: picture.width, height: picture.height)
        let input = TableGridBuilder.Input(words: drawing.words, lines: rules.lines, bands: rules.bands,
                                           imageSize: PSSize(width: Double(picture.width), height: Double(picture.height)), remembered: remembered)
        return TableGridRefiner.refine(fresh: TableGridBuilder.build(input), words: drawing.words, gray: picture.gray, rgba: picture.rgba,
                                       width: picture.width, height: picture.height, remembered: remembered)
    }

    private func assertShape(_ grid: TableGrid, _ drawing: Drawing, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(grid.dataRows.count, 9, file: file, line: line)
        XCTAssertEqual(grid.dataColumns.count, 5, file: file, line: line)
        XCTAssertEqual(grid.names(.column).map { $0.replacingOccurrences(of: "Claude ", with: "") },
                       ["Opus 5.5", "Opus 5", "Fable 5.1", "Gemini 3.5 Pro", "GPT-6 Astra"], file: file, line: line)
        XCTAssertNotEqual(grid.title?.contains("Opus 5.5"), false, "the title is not a header", file: file, line: line)
        for (index, centre) in drawing.centres.enumerated() {
            let cell = grid.cell(dataRow: index / 5 + 1, dataColumn: index % 5 + 1)
            let point = PSPoint(x: centre.x / Double(Self.width), y: centre.y / Double(Self.height))
            XCTAssertTrue(cell?.rect.contains(point) ?? false, "r\(index / 5 + 1)c\(index % 5 + 1)", file: file, line: line)
            if let content = cell?.contentRect {
                XCTAssertEqual(content.midX, point.x, accuracy: 0.03, file: file, line: line)
            }
        }
    }

    func testWithValuesEveryCellIsPrintedAndStyled() throws {
        let drawing = Self.draw(values: true)
        let grid = try XCTUnwrap(Self.grid(of: drawing))
        assertShape(grid, drawing)
        XCTAssertEqual(grid.dataCells.filter { $0.state == .printed }.count, 45)
        XCTAssertEqual(grid.cell(dataRow: 1, dataColumn: 1)?.text, Self.value(row: 0, column: 0))
        let style = try XCTUnwrap(grid.style(forDataColumn: 1))
        XCTAssertEqual(style.relativeSize * Double(Self.height), Self.fontSize, accuracy: Self.fontSize * 0.12)
        XCTAssertEqual(style.color.red, Double(0x1C) / 255, accuracy: 0.02)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(grid.dataColumns.first?.format?.suffix, "%")
    }

    func testErasedValuesLeaveFortyFiveEmptyCellsStyledFromTheLabels() throws {
        let drawing = Self.draw(values: false)
        let grid = try XCTUnwrap(Self.grid(of: drawing))
        assertShape(grid, drawing)
        XCTAssertEqual(grid.emptyDataCells.count, 45)
        let style = try XCTUnwrap(grid.style(forDataColumn: 3))
        XCTAssertEqual(style.relativeSize * Double(Self.height), Self.fontSize, accuracy: Self.fontSize * 0.12)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertNotNil(grid.bodyStyle)
    }

    func testDarkFullGrid() throws {
        let drawing = Self.draw(values: true, dark: true, fullGrid: true)
        let grid = try XCTUnwrap(Self.grid(of: drawing))
        assertShape(grid, drawing)
        let style = try XCTUnwrap(grid.style(forDataColumn: 2))
        XCTAssertEqual(style.color.red, Double(0xEB) / 255, accuracy: 0.02)
    }

    func testTheMemoryKeepsTheStyleAfterTheErase() throws {
        let before = try XCTUnwrap(Self.grid(of: Self.draw(values: true)))
        let after = try XCTUnwrap(Self.grid(of: Self.draw(values: false), remembered: before))
        XCTAssertEqual(after.source, .remembered)
        XCTAssertEqual(after.emptyDataCells.count, 45)
        XCTAssertEqual(after.style(forDataColumn: 1), before.style(forDataColumn: 1))
        XCTAssertEqual(after.dataColumns.first?.format?.suffix, "%")
    }
}
