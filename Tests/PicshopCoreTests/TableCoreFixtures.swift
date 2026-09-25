import Foundation
@testable import PicshopCore

/// Synthetic OCR for the builder: the benchmark screenshot of the report laid out in pixels
/// (1709 × 2048, 32 px values), written the way Vision reports it: one line per text run, word
/// boxes about 0.72 of the font size tall, 0.55 em per character.
enum TableCoreFixtures {
    static let size = PSSize(width: 1709, height: 2048)
    static let title = "Claude Opus 5.5"
    static let headers = ["Opus 5.5", "Opus 5", "Fable 5.1", "Gemini 3.5 Pro", "GPT-6 Astra"]
    static let labels = ["Agentic coding", "Agentic terminal coding", "Scaled tool use", "Multidisciplinary reasoning",
                         "Novel problem solving", "Agentic computer use", "Graduate-level reasoning", "Visual reasoning", "Knowledge work"]
    static let subtitles = ["SWE-bench Verified", "Terminal-bench 2.0", "MCP Atlas", "Humanity's Last Exam", "ARC-AGI-2",
                            "OSWorld", "GPQA Diamond", "MMMU", "GDPval"]
    static let values: [[String]] = [
        ["80.9%", "77.2%", "74.5%", "76.2%", "74.9%"],
        ["59.3%", "50.0%", "47.8%", "54.2%", "58.1%"],
        ["86.2%", "81.6%", "79.3%", "83.0%", "80.4%"],
        ["40.1%", "36.8%", "33.9%", "38.4%", "37.7%"],
        ["71.4%", "66.0%", "61.2%", "68.9%", "70.3%"],
        ["66.3%", "61.4%", "58.8%", "54.7%", "49.9%"],
        ["87.0%", "84.3%", "83.1%", "86.4%", "85.7%"],
        ["80.7%", "77.9%", "75.0%", "79.8%", "76.1%"],
        ["79.4%", "74.6%", "70.2%", "73.3%", "75.8%"],
    ]

    static let font = 32.0
    /// Headers are set smaller than the values, as in the report ("Gemini 3.5 Pro" fits its column).
    static let headerFont = 26.0
    static let tableLeft = 51.0, tableRight = 1658.0
    static let labelWidth = 598.0
    static let headerTop = 205.0, headerBottom = 348.0
    static let rowHeight = 179.8

    static var columnWidth: Double { (tableRight - tableLeft - labelWidth) / Double(headers.count) }
    static func columnCenter(_ column: Int) -> Double { tableLeft + labelWidth + columnWidth * (Double(column) + 0.5) }
    static func rowTop(_ row: Int) -> Double { headerBottom + rowHeight * Double(row) }

    struct Options {
        var values = false
        var rules = true
        var subtitles = false
        var twoLineHeaders = false
        var title = true
        /// Cells (0-based row, column) printed as "—".
        var dashes: Set<[Int]> = []
    }

    /// The builder input for the benchmark with `options`.
    static func input(_ options: Options = Options()) -> TableGridBuilder.Input {
        var words: [TableGridBuilder.Word] = []
        var line = 0
        func add(_ text: String, left: Double, midY: Double, font: Double = font) {
            var x = left
            let height = font * 0.72
            for word in text.split(separator: " ") {
                let width = Double(word.count) * font * 0.55
                let box = PSRect(x: x, y: midY - height / 2, width: width, height: height)
                words.append(TableGridBuilder.Word(text: String(word), box: box.normalized(in: size), line: line))
                x += width + font * 0.3
            }
            line += 1
        }
        func width(_ text: String, font: Double = font) -> Double {
            let words = text.split(separator: " ")
            return words.map { Double($0.count) * font * 0.55 }.reduce(0, +) + Double(max(0, words.count - 1)) * font * 0.3
        }
        func centered(_ text: String, x: Double, midY: Double, font: Double = font) { add(text, left: x - width(text, font: font) / 2, midY: midY, font: font) }

        if options.title { add(title, left: tableLeft, midY: 100, font: 80) }
        for (column, header) in headers.enumerated() {
            if options.twoLineHeaders {
                let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
                centered(parts[0], x: columnCenter(column), midY: 258, font: headerFont)
                if parts.count > 1 { centered(parts[1], x: columnCenter(column), midY: 294, font: headerFont) }
            } else {
                centered(header, x: columnCenter(column), midY: 276, font: headerFont)
            }
        }
        let labelLeft = tableLeft + 48
        for (row, label) in labels.enumerated() {
            let mid = rowTop(row) + rowHeight / 2
            if options.subtitles {
                add(label, left: labelLeft, midY: mid - 21)
                add(subtitles[row], left: labelLeft, midY: mid + 21, font: 28)
            } else {
                add(label, left: labelLeft, midY: mid)
            }
            guard options.values || !options.dashes.isEmpty else { continue }
            for column in headers.indices {
                if options.dashes.contains([row, column]) { centered("—", x: columnCenter(column), midY: mid) }
                else if options.values { centered(values[row][column], x: columnCenter(column), midY: mid) }
            }
        }
        var lines: [TableGridBuilder.RulingLine] = []
        if options.rules {
            for row in 0...labels.count {
                let y = rowTop(row)
                lines.append(TableGridBuilder.RulingLine(axis: .horizontal, position: y / size.height, start: tableLeft / size.width,
                                                         end: tableRight / size.width, thickness: 1 / size.height, contrast: 0.12))
            }
        }
        return TableGridBuilder.Input(words: words, lines: lines, imageSize: size)
    }

    /// Words of free text laid out one run per line, left-aligned, for the "not a table" cases.
    static func lines(_ texts: [String], left: Double = 80, top: Double = 300, pitch: Double = 48, font: Double = 32, gapColumns: [Double] = []) -> [TableGridBuilder.Word] {
        var words: [TableGridBuilder.Word] = []
        for (index, text) in texts.enumerated() {
            let parts = text.components(separatedBy: " | ")
            for (part, piece) in parts.enumerated() {
                var x = part == 0 ? left : gapColumns[part - 1]
                for word in piece.split(separator: " ") {
                    let width = Double(word.count) * font * 0.55
                    let box = PSRect(x: x, y: top + Double(index) * pitch, width: width, height: font * 0.72)
                    words.append(TableGridBuilder.Word(text: String(word), box: box.normalized(in: size), line: index * 10 + part))
                    x += width + font * 0.3
                }
            }
        }
        return words
    }
}
