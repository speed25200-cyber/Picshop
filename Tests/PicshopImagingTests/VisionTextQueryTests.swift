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
    /// height) inside a cell, a column gap between cells.
    private static func layout(_ rows: [[[String]]], top: Double = 0.2) -> [VisionWord] {
        var words: [VisionWord] = []
        for (line, row) in rows.enumerated() {
            var x = 0.05
            for cell in row {
                for text in cell {
                    words.append(VisionWord(text: text, box: PSRect(x: x, y: top + Double(line) * 0.1, width: 0.06, height: 0.04), line: line))
                    x += 0.07
                }
                x += 0.06
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
}
