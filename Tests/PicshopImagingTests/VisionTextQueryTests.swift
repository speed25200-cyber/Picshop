import XCTest
import PicshopCore
@testable import PicshopImaging

/// What a text target selects among recognised words. Pure Swift, runs everywhere.
final class VisionTextQueryTests: XCTestCase {
    private func query(_ phrase: String, label: String = "text", all: Bool = false, hint: SpatialHint? = nil) -> VisionTextQuery {
        VisionTextQuery(target: ObjectTarget(label: label, originalPhrase: phrase, spatialHint: hint, matchesAll: all))
    }

    /// Model | MMLU | GSM8K / GPT-4o | 88.7 | 90,5 / Llama 3.1 70B | 86.0 | 95.1%, one box per word.
    private let table: [VisionWord] = VisionTextQueryTests.layout([[["Model"], ["MMLU"], ["GSM8K"]], [["GPT-4o"], ["88.7"], ["90,5"]], [["Llama", "3.1", "70B"], ["86.0"], ["95.1%"]]])

    /// Rows of cells of words, one recognised line per row: a word space (a quarter of the
    /// height) inside a cell, columns a quarter of the width apart.
    private static func layout(_ rows: [[[String]]], top: Double = 0.2) -> [VisionWord] {
        var words: [VisionWord] = []
        for (line, row) in rows.enumerated() {
            for (column, cell) in row.enumerated() {
                var x = 0.05 + Double(column) * 0.25
                for text in cell {
                    words.append(VisionWord(text: text, box: PSRect(x: x, y: top + Double(line) * 0.1, width: 0.06, height: 0.04), line: line))
                    x += 0.07
                }
            }
        }
        return words
    }

    /// A screenshot: status bar, a title, the table above, a page number at the bottom.
    private var screen: [VisionWord] {
        var words = [VisionWord(text: "9:41", box: PSRect(x: 0.05, y: 0, width: 0.08, height: 0.04), line: 0),
                     VisionWord(text: "87%", box: PSRect(x: 0.85, y: 0, width: 0.08, height: 0.04), line: 1),
                     VisionWord(text: "Benchmarks", box: PSRect(x: 0.1, y: 0.1, width: 0.3, height: 0.04), line: 2)]
        words += table.map { word in
            var shifted = word
            shifted.line += 3
            return shifted
        }
        words.append(VisionWord(text: "12", box: PSRect(x: 0.48, y: 0.94, width: 0.04, height: 0.04), line: 6))
        return words
    }

    func testNumericTokens() {
        for token in ["87.3", "87,3", "+2.1", "(±0.4)", "95%", "1,234", "−3", "70B", "%", "2024"] {
            XCTAssertTrue(VisionTextQuery.isNumeric(token), token)
        }
        for token in ["MMLU", "GSM8K", "GPT-4o", "Llama", "N/A", "Total", "—", ""] {
            XCTAssertFalse(VisionTextQuery.isNumeric(token), token)
        }
    }

    func testDataWordsAskForEveryNumber() {
        // The reported request, before and after the vocabulary maps "données" to text.
        for label in ["text", "donnees tableau"] {
            let target = ObjectTarget(label: label, originalPhrase: "toutes les données du tableau", matchesAll: true)
            XCTAssertTrue(VisionTextQuery.isTextTarget(target), label)
            let query = VisionTextQuery(target: target)
            XCTAssertEqual(query.kind, .numeric, label)
            XCTAssertTrue(query.selectsAll, label)
            XCTAssertTrue(query.withinTable, label)
            XCTAssertTrue(query.tight, label)
        }
        XCTAssertEqual(query("remove the numbers").kind, .numeric)
        XCTAssertFalse(query("remove the numbers").withinTable)
        XCTAssertTrue(query("les chiffres").selectsAll, "numbers asked for without a position mean all of them")
        XCTAssertTrue(query("the data").selectsAll)
        XCTAssertFalse(query("les chiffres", hint: .right).selectsAll, "a position narrows them to a choice")
    }

    func testSingularDataNounIsAChoice() {
        for phrase in ["le numéro", "le chiffre", "la valeur", "the score", "the number"] {
            let single = query(phrase)
            XCTAssertEqual(single.kind, .numeric, phrase)
            XCTAssertFalse(single.selectsAll, "\(phrase): one number, picked by the selector or asked")
        }
        XCTAssertTrue(query("tous les chiffres").selectsAll)
        XCTAssertTrue(query("le chiffre", all: true).selectsAll)
    }

    func testOnlyDataAndTableTextIsTight() {
        for phrase in ["le filigrane", "la date", "le logo", "the watermark", "la légende", "tout le texte"] {
            XCTAssertFalse(query(phrase).tight, "\(phrase): padded so a shadow or an outline goes too")
        }
        for phrase in ["les données", "le mot « Total »", "la valeur 87,3", "tout le texte du tableau", "le texte des cellules"] {
            XCTAssertTrue(query(phrase).tight, phrase)
        }
    }

    func testTableKeepsToTheTable() {
        let words = screen
        XCTAssertEqual(VisionTextQuery.tableWords(in: words), Array(3...13), "not the status bar, the title or the page number")
        let inTable = VisionTextQuery(kind: .numeric, withinTable: true).matches(in: words).map { $0.map { words[$0].text } }
        XCTAssertEqual(inTable, [["88.7"], ["90,5"], ["86.0"], ["95.1%"]], "not the version and size in the model's name")
        XCTAssertEqual(VisionTextQuery(kind: .numeric).matches(in: words).count, 7, "anywhere: the status bar and the page number too")
        XCTAssertEqual(VisionTextQuery(kind: .all, withinTable: true).matches(in: words), [[3, 4, 5], [6, 7, 8], [9, 10, 11, 12, 13]])
        // Without two rows of numbers there is no table, and the query reads the whole picture.
        let lone = [VisionWord(text: "12", box: PSRect(x: 0.48, y: 0.94, width: 0.04, height: 0.04), line: 0)]
        XCTAssertNil(VisionTextQuery.tableWords(in: lone))
        XCTAssertEqual(VisionTextQuery(kind: .numeric, withinTable: true).matches(in: lone), [[0]])
    }

    func testLiteralWords() {
        XCTAssertEqual(query("le mot « Total »").kind, .matching("Total"))
        XCTAssertEqual(query("the word \"Revenue\"").kind, .matching("Revenue"))
        XCTAssertEqual(query("le mot total du tableau", label: "mot total").kind, .matching("total"))
        XCTAssertTrue(VisionTextQuery.isTextTarget(ObjectTarget(label: "mot total", originalPhrase: "le mot total")))
        XCTAssertEqual(query("la valeur 87,3", label: "valeur", all: true).kind, .matching("87.3"))
        XCTAssertEqual(query("les mots en haut", hint: .top).kind, .all)
    }

    func testOtherTargetsKeepTheirPaths() {
        XCTAssertFalse(VisionTextQuery.isTextTarget(ObjectTarget(label: "dog")))
        XCTAssertFalse(VisionTextQuery.isTextTarget(ObjectTarget(label: "figure")), "a figure can be a face")
        XCTAssertFalse(VisionTextQuery.isTextTarget(ObjectTarget(label: "tableau")))
        XCTAssertTrue(VisionTextQuery.isTextTarget(ObjectTarget(label: "text", originalPhrase: "le texte")))
        let text = query("le texte")
        XCTAssertEqual(text.kind, .all)
        XCTAssertFalse(text.selectsAll)
        XCTAssertTrue(query("tout le texte").selectsAll)
    }

    func testNumericSelectionSkipsLabelsAndHeaders() {
        let picked = VisionTextQuery(kind: .numeric).matches(in: table).map { $0.map { table[$0].text } }
        XCTAssertEqual(picked, [["88.7"], ["90,5"], ["86.0"], ["95.1%"]])
    }

    /// "Supprime toutes les données du tableau" on a benchmark table: every score and its
    /// uncertainty goes; the caption, the headers and the model names stay whole.
    func testTableDataSparesNamesAndCaption() {
        let words = Self.layout([[["Table", "2:", "Results", "on", "standard", "benchmarks."]],
                                 [["Model"], ["MMLU"], ["GSM8K"]],
                                 [["Claude", "3.5", "Sonnet"], ["88.7"], ["96.4"]],
                                 [["Llama", "3.1", "405B"], ["86.1", "±", "0.4"], ["96.8"]],
                                 [["Gemini", "1.5", "Pro"], ["85.9"], ["90.8"]],
                                 [["Qwen2.5", "72B"], ["86.1"], ["91.5"]]], top: 0.1)
        let query = VisionTextQuery(target: ObjectTarget(label: "text", originalPhrase: "toutes les données du tableau", matchesAll: true))
        let erased = query.matches(in: words).flatMap { $0 }.map { words[$0].text }
        XCTAssertEqual(erased, ["88.7", "96.4", "86.1", "±", "0.4", "96.8", "85.9", "90.8", "86.1", "91.5"])
        let tableText = Set(VisionTextQuery(kind: .all, withinTable: true).matches(in: words).flatMap { $0 }.map { words[$0].text })
        XCTAssertFalse(tableText.contains("benchmarks."), "the caption names the table, it is not in it")
        XCTAssertTrue(tableText.contains("Model"))
    }

    func testMatchingIgnoresCaseAccentsAndDecimalComma() {
        XCTAssertEqual(VisionTextQuery(kind: .matching("90.5")).matches(in: table), [[5]])
        XCTAssertEqual(VisionTextQuery(kind: .matching("gpt-4o")).matches(in: table), [[3]])
        XCTAssertEqual(VisionTextQuery(kind: .matching("llama 3.1")).matches(in: table), [[6, 7]])
        XCTAssertEqual(VisionTextQuery(kind: .matching("GSM8K GPT-4o")).matches(in: table), [], "an occurrence stays on one line")
        XCTAssertEqual(VisionTextQuery.folded("Été:"), "ete")
        XCTAssertEqual(VisionTextQuery.folded("l’été"), "l'ete")
    }

    func testRegionAndLines() {
        let middleRow = PSRect(x: 0, y: 0.25, width: 1, height: 0.1)
        XCTAssertEqual(VisionTextQuery(kind: .numeric, region: middleRow).matches(in: table), [[4], [5]])
        XCTAssertEqual(VisionTextQuery(kind: .all).matches(in: table), [[0, 1, 2], [3, 4, 5], [6, 7, 8, 9, 10]])
    }

    func testMaskBoxIsTight() {
        // 15 % of a 20 px word = 3 px on every side.
        let box = VisionWord(text: "88.7", box: PSRect(x: 0.5, y: 0.5, width: 0.04, height: 0.02), line: 0).maskBox(imageWidth: 2000, imageHeight: 1000)
        XCTAssertEqual(box.minX, 0.5 - 3.0 / 2000, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0.5 - 3.0 / 1000, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.02 + 6.0 / 1000, accuracy: 1e-9)
        // At least 1.5 px, clamped to the picture.
        let tiny = VisionWord(text: "1", box: PSRect(x: 0, y: 0, width: 0.004, height: 0.004), line: 0).maskBox(imageWidth: 1000, imageHeight: 1000)
        XCTAssertEqual(tiny.minX, 0)
        XCTAssertEqual(tiny.maxY, 0.004 + 1.5 / 1000, accuracy: 1e-9)
    }

    // MARK: The reported benchmark table

    /// A 1709 × 2048 screenshot of a benchmark table, laid out in pixels like the one reported:
    /// a status bar, a title and a caption; two-line column titles over five model columns; a
    /// label column with row labels of two or three lines; values with superscripts, dashes for
    /// missing results and small notes ("with tools", "partial") under some of them; footnote
    /// paragraphs below, the last line of one short enough to sit in a column.
    private struct Screenshot {
        static let width = 1709.0, height = 2048.0
        static let columns = [700.0, 900, 1100, 1300, 1500]
        var words: [VisionWord] = []
        /// Indices of the words in data cells, which "toutes les données du tableau" erases.
        var data: Set<Int> = []
        var line = -1

        mutating func newLine() -> Int {
            line += 1
            return line
        }

        /// The words of `text`, from `x` or centred on `centre`, `top` px down and `size` px high.
        mutating func add(_ text: String, x: Double? = nil, centre: Double? = nil, top: Double, size: Double, line: Int, isData: Bool = false) {
            let tokens = text.split(separator: " ").map(String.init)
            let widths = tokens.map { Double($0.count) * 0.55 * size }
            let space = 0.3 * size
            let total = widths.reduce(0, +) + space * Double(tokens.count - 1)
            var left = x ?? (centre ?? 0) - total / 2
            for (token, width) in zip(tokens, widths) {
                if isData { data.insert(words.count) }
                let box = PSRect(x: left / Self.width, y: top / Self.height, width: width / Self.width, height: size / Self.height)
                words.append(VisionWord(text: token, box: box, line: line))
                left += width + space
            }
        }

        static func make() -> Screenshot {
            var shot = Screenshot()
            let status = shot.newLine()
            shot.add("9:41", x: 80, top: 20, size: 24, line: status)
            shot.add("100%", x: 1560, top: 20, size: 24, line: status)
            shot.add("Claude Opus 5.5", x: 80, top: 60, size: 44, line: shot.newLine())
            shot.add("Benchmark results across frontier models", centre: 854, top: 130, size: 24, line: shot.newLine())
            let titles = [("Claude", "Opus 5.5"), ("Claude", "Opus 4.5"), ("Claude", "Sonnet 4.5"), ("Gemini", "3 Pro"), ("GPT-5.1", "(high)")]
            let firstTitleLine = shot.newLine()
            for (column, title) in zip(columns, titles) { shot.add(title.0, centre: column, top: 200, size: 28, line: firstTitleLine) }
            let secondTitleLine = shot.newLine()
            shot.add("Benchmark", x: 80, top: 236, size: 28, line: secondTitleLine)
            for (column, title) in zip(columns, titles) { shot.add(title.1, centre: column, top: 236, size: 28, line: secondTitleLine) }

            // (value, superscript, note) per column.
            typealias Cell = (value: String, sup: String?, note: String?)
            let rows: [(labels: [String], cells: [Cell])] = [
                (["Agentic coding", "SWE-bench Verified"], [("80.9%", nil, nil), ("77.2%", nil, nil), ("76.2%", nil, nil), ("74.9%", nil, nil), ("72.8%", nil, nil)]),
                (["Agentic terminal coding", "Terminal-Bench 4.0"], [("66.4%", "1", nil), ("59.3%", nil, nil), ("—", nil, nil), ("54.2%", nil, nil), ("47.6%", nil, nil)]),
                (["Scaled tool use", "MCP Atlas"], [("62.3%", nil, nil), ("43.8%", nil, nil), ("40.6%", nil, nil), ("—", nil, nil), ("44.5%", nil, nil)]),
                (["Multidisciplinary", "reasoning", "Humanity's Last Exam"], [("41.2%", nil, "with tools"), ("30.8%", nil, "with tools"), ("—", nil, nil), ("37.5%", nil, nil), ("26.5%", "2", "with tools")]),
                (["Novel problem", "solving", "ARC-AGI-3"], [("37.6%", nil, nil), ("13.6%", nil, "partial"), ("—", nil, nil), ("31.1%", nil, nil), ("17.6%", nil, nil)]),
                (["Agentic computer use", "OSWorld"], [("72.7%", nil, nil), ("66.3%", nil, nil), ("61.4%", nil, nil), ("—", nil, nil), ("—", nil, nil)]),
                (["Graduate-level", "reasoning", "GPQA Diamond"], [("91.3%", nil, nil), ("87.0%", nil, nil), ("83.4%", nil, nil), ("91.9%", nil, nil), ("88.1%", nil, nil)]),
                (["Visual reasoning", "MMMU"], [("80.7%", nil, nil), ("77.8%", nil, nil), ("—", nil, nil), ("81.0%", nil, nil), ("85.4%", nil, nil)]),
                (["Knowledge work", "GDPval-AA Elo"], [("1846", nil, nil), ("1634", nil, "partial"), ("1512", nil, nil), ("—", nil, nil), ("1420", nil, "partial")]),
            ]
            for (index, row) in rows.enumerated() {
                let rowTop = 330 + Double(index) * 150
                let centreY = rowTop + (Double(row.labels.count) * 36 - 8) / 2
                // The values share a recognised line, and so does the label line level with them.
                let valueLine = shot.newLine()
                for (number, label) in row.labels.enumerated() {
                    let top = rowTop + Double(number) * 36
                    let level = abs(top + 14 - centreY) < 16
                    shot.add(label, x: 80, top: top, size: 28, line: level ? valueLine : shot.newLine())
                }
                let noteLine = shot.newLine()
                for (column, cell) in zip(columns, row.cells) {
                    let valueTop = cell.note == nil ? centreY - 16 : centreY - 29
                    shot.add(cell.value, centre: column, top: valueTop, size: 32, line: valueLine, isData: true)
                    if let sup = cell.sup {
                        shot.add(sup, x: column + Double(cell.value.count) * 0.55 * 16 + 4, top: valueTop - 4, size: 16, line: valueLine, isData: true)
                    }
                    if let note = cell.note {
                        shot.add(note, centre: column, top: valueTop + 36, size: 22, line: noteLine, isData: true)
                    }
                }
            }
            shot.add("¹ Averaged over 5 trials with a 64K thinking budget and default sampling settings for every model listed above.", x: 80, top: 1720, size: 22, line: shot.newLine())
            shot.add("² Scores for GPT-5.1 use high reasoning effort; results marked partial ran on a subset of 120 tasks with", x: 80, top: 1752, size: 22, line: shot.newLine())
            shot.add("tools.", centre: 700, top: 1784, size: 22, line: shot.newLine())
            shot.add("Humanity's Last Exam with tools uses search and code execution; see the system card for details.", x: 80, top: 1830, size: 22, line: shot.newLine())
            return shot
        }
    }

    /// "Supprime toutes les données du tableau" on the reported screenshot: every data cell goes,
    /// down to the last row (labels of three lines, notes and dashes used to cut the table in
    /// half), and nothing else: not the column titles, the row labels, the title, the caption,
    /// the status bar or the footnotes.
    func testAllTableDataOfTheReportedScreenshot() {
        let shot = Screenshot.make()
        let words = shot.words
        let query = VisionTextQuery(target: ObjectTarget(label: "donnees tableau", originalPhrase: "supprime toutes les données du tableau", matchesAll: true))
        let erased = Set(query.matches(in: words).flatMap { $0 })
        let texts = { (indices: Set<Int>) in indices.sorted().map { words[$0].text } }
        XCTAssertEqual(texts(erased.subtracting(shot.data)), [], "only data cells")
        XCTAssertEqual(texts(shot.data.subtracting(erased)), [], "every data cell")
        for kept in ["Opus", "5.5", "4.5", "Benchmark", "Multidisciplinary", "reasoning", "Exam", "Terminal-Bench", "4.0", "ARC-AGI-3", "Averaged", "tools.", "9:41", "100%", "frontier"] {
            XCTAssertTrue(words.indices.contains { words[$0].text == kept && !erased.contains($0) }, kept)
        }
        XCTAssertTrue(erased.contains { words[$0].text == "1420" }, "the last row")
        XCTAssertTrue(erased.contains { words[$0].text == "—" })
        XCTAssertTrue(erased.contains { words[$0].text == "with" })
    }

    func testReportedScreenshotTableSpan() throws {
        let shot = Screenshot.make()
        let words = shot.words
        let table = try XCTUnwrap(VisionTextQuery.table(in: words))
        XCTAssertEqual(Set(table.data), shot.data)
        let inTable = Set(table.words.map { words[$0].text })
        for text in ["Claude", "Opus", "Benchmark", "Multidisciplinary", "Exam", "GDPval-AA", "Elo", "1846", "partial"] {
            XCTAssertTrue(inTable.contains(text), text)
        }
        for text in ["frontier", "Averaged", "tools.", "9:41", "100%", "details."] {
            XCTAssertFalse(inTable.contains(text), text)
        }
        // A choice of one value is still among the numbers only.
        let choice = VisionTextQuery(kind: .numeric, withinTable: true).matches(in: words).flatMap { $0 }.map { words[$0].text }
        XCTAssertEqual(choice.count, 39, "37 values and 2 superscripts: \(choice)")
        XCTAssertTrue(choice.allSatisfy { VisionTextQuery.isNumeric($0) }, "\(choice)")
        XCTAssertFalse(choice.contains("5.5"), "not a column title")
    }

    /// Two tables with the same columns far apart are two tables; the one with more numbers wins.
    func testDistantTablesStayApart() {
        var words = Self.layout([[["Model"], ["A"], ["B"]], [["x"], ["1.0"], ["2.0"]], [["y"], ["3.0"], ["4.0"]], [["z"], ["5.0"], ["6.0"]]], top: 0.1)
        words += Self.layout([[["Model"], ["A"], ["B"]], [["x"], ["7.0"], ["8.0"]], [["y"], ["9.0"], ["10.0"]]], top: 0.7).map { word in
            var shifted = word
            shifted.line += 4
            return shifted
        }
        XCTAssertEqual(VisionTextQuery.tableWords(in: words), Array(0...11))
        XCTAssertEqual(VisionTextQuery.table(in: words)?.data.map { words[$0].text }, ["1.0", "2.0", "3.0", "4.0", "5.0", "6.0"])
    }
}
