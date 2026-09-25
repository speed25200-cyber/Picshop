#if canImport(Vision) && canImport(CoreImage) && canImport(CoreText)
import XCTest
import Foundation
import CoreGraphics
import CoreText
import UniformTypeIdentifiers
import PicshopCore
@testable import PicshopImaging

/// Table detection on pictures drawn with CoreGraphics and CoreText (SF Pro, the system font), read by
/// Vision (contract A7, A14). macOS only: the package-macos CI job runs it. A machine whose Vision cannot
/// read text skips the OCR tests rather than failing them.
final class TableVisionTests: XCTestCase {
    static let width = 1709, height = 2048
    static let headers = [["Claude", "Opus 5.5"], ["Claude", "Opus 5"], ["Fable", "5.1"], ["Gemini", "3.5 Pro"], ["GPT-6", "Astra"]]
    static let labels = [["Agentic coding"], ["Agentic terminal", "coding"], ["Scaled tool use"], ["Multidisciplinary", "reasoning"],
                         ["Novel problem", "solving"], ["Agentic computer", "use"], ["Graduate-level", "reasoning"], ["Visual reasoning"],
                         ["Knowledge work"]]
    static let left: CGFloat = 80, labelRight: CGFloat = 620, columnWidth: CGFloat = 201, headerTop: CGFloat = 250
    static let firstRule: CGFloat = 390, rowHeight: CGFloat = 150
    static var right: CGFloat { labelRight + 5 * columnWidth }
    static let valueSize: CGFloat = 32

    static func value(row: Int, column: Int) -> String { "\(50 + (row * 7 + column * 13) % 45).\((row + column) % 10)%" }

    // MARK: Drawing

    /// A top-left-origin canvas over a CGContext.
    struct Canvas {
        let context: CGContext
        let height: CGFloat

        init?(width: Int, height: Int, paper: CGColor) {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            self.context = context
            self.height = CGFloat(height)
            context.setFillColor(paper)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        func fill(_ rect: CGRect, color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
        }

        /// Draws `text` with its baseline at `baseline` (from the top); returns its box (top-left pixels):
        /// ascent above the baseline, descent below.
        @discardableResult
        func text(_ text: String, font: CTFont, color: CGColor, x: CGFloat, baseline: CGFloat, centred: Bool = false) -> CGRect {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let start = centred ? x - width / 2 : x
            context.textPosition = CGPoint(x: start, y: height - baseline)
            CTLineDraw(line, context)
            return CGRect(x: start, y: baseline - ascent, width: width, height: ascent + descent)
        }

        var image: CGImage? { context.makeImage() }
    }

    static func systemFont(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    struct Drawing {
        var image: CGImage
        /// Where each data value sits (centre, top-left pixels), row-major.
        var centres: [CGPoint]
        /// Word boxes of the values and of the row labels (normalised, top-left) and their texts.
        var valueBoxes: [PSRect]
        var valueTexts: [String]
        var labelBoxes: [PSRect]
        var labelTexts: [String]
    }

    /// The report's benchmark table: title, 2-line headers, multi-line labels, 9 rows, 1-px #E3E3E3
    /// horizontal rules, 32-px values; `dark` draws light text on #1C1C1E with a full grid of #48484A.
    static func drawTable(values: Bool, dark: Bool = false, boldLabels: Bool = false) -> Drawing? {
        let paper = dark ? CGColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let ink = dark ? CGColor(red: 0xEB / 255, green: 0xEB / 255, blue: 0xF0 / 255, alpha: 1) : CGColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
        let rule = dark ? CGColor(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255, alpha: 1) : CGColor(red: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255, alpha: 1)
        guard let canvas = Canvas(width: width, height: height, paper: paper) else { return nil }
        func normalised(_ rect: CGRect) -> PSRect {
            PSRect(x: Double(rect.minX) / Double(width), y: Double(rect.minY) / Double(height), width: Double(rect.width) / Double(width),
                   height: Double(rect.height) / Double(height))
        }
        canvas.text("Claude Opus 5.5", font: systemFont(56, bold: true), color: ink, x: left, baseline: 170)
        for (column, header) in headers.enumerated() {
            let centre = labelRight + CGFloat(column) * columnWidth + columnWidth / 2
            for (index, line) in header.enumerated() {
                canvas.text(line, font: systemFont(26, bold: true), color: ink, x: centre, baseline: 310 + CGFloat(index) * 40, centred: true)
            }
        }
        var drawing = Drawing(image: canvas.image!, centres: [], valueBoxes: [], valueTexts: [], labelBoxes: [], labelTexts: [])
        let labelFont = systemFont(valueSize, bold: boldLabels), valueFont = systemFont(valueSize)
        let capHeight = CTFontGetCapHeight(valueFont)
        for (row, label) in labels.enumerated() {
            let middle = firstRule + CGFloat(row) * rowHeight + rowHeight / 2
            let baselines = label.count == 1 ? [middle + capHeight / 2] : [middle - 8, middle + 32]
            for (line, baseline) in zip(label, baselines) {
                let box = canvas.text(line, font: labelFont, color: ink, x: left + 20, baseline: baseline)
                drawing.labelBoxes.append(normalised(box))
                drawing.labelTexts.append(line)
            }
            for column in 0..<5 {
                let centre = CGPoint(x: labelRight + CGFloat(column) * columnWidth + columnWidth / 2, y: middle)
                drawing.centres.append(centre)
                guard values else { continue }
                let text = value(row: row, column: column)
                let box = canvas.text(text, font: valueFont, color: ink, x: centre.x, baseline: middle + capHeight / 2, centred: true)
                drawing.valueBoxes.append(normalised(box))
                drawing.valueTexts.append(text)
            }
        }
        for index in 0...9 {
            canvas.fill(CGRect(x: left, y: firstRule + CGFloat(index) * rowHeight, width: right - left, height: 1), color: rule)
        }
        if dark {
            canvas.fill(CGRect(x: left, y: headerTop, width: right - left, height: 1), color: rule)
            for x in [left, labelRight] + (1...5).map({ labelRight + CGFloat($0) * columnWidth }) {
                canvas.fill(CGRect(x: x, y: headerTop, width: 1, height: firstRule + 9 * rowHeight - headerTop + 1), color: rule)
            }
        }
        guard let image = canvas.image else { return nil }
        drawing.image = image
        return drawing
    }

    /// Vision's words for a picture, or a skip when this machine cannot read text.
    static func words(in image: CGImage) throws -> [VisionWord] {
        let words: [VisionWord]
        do {
            words = try VisionGrounding.recognizedWords(in: image)
        } catch {
            throw XCTSkip("Vision text recognition is unavailable here: \(error)")
        }
        if words.count < 5 { throw XCTSkip("Vision read \(words.count) words on the table: text recognition is unavailable here") }
        return words
    }

    /// CIE76 colour difference between two sRGB colours.
    static func deltaE(_ a: PSColor, _ b: PSColor) -> Double {
        func lab(_ color: PSColor) -> (Double, Double, Double) {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b, z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    // MARK: Pure parts on real glyphs (no OCR)

    func testABlankPictureHasNoTable() throws {
        let canvas = try XCTUnwrap(Canvas(width: 427, height: 512, paper: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        XCTAssertNil(TableDetection.grid(in: try XCTUnwrap(canvas.image), words: [], remembered: nil))
    }

    func testTheDrawnRulesAreFound() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: false))
        let gray = ImageSupport.grayBytes(from: drawing.image)
        let output = RulingLineDetector.detect(gray: gray, width: Self.width, height: Self.height)
        let horizontal = output.lines.filter { $0.axis == .horizontal }.sorted { $0.position < $1.position }
        XCTAssertEqual(horizontal.count, 10)
        for (index, line) in horizontal.enumerated() {
            XCTAssertEqual(line.position * Double(Self.height), Double(Self.firstRule + CGFloat(index) * Self.rowHeight) + 0.5, accuracy: 1.5)
            XCTAssertEqual(line.start * Double(Self.width), Double(Self.left), accuracy: 3)
            XCTAssertEqual(line.end * Double(Self.width), Double(Self.right), accuracy: 3)
        }
        XCTAssertTrue(output.lines.filter { $0.axis == .vertical }.isEmpty, "text never makes a vertical rule")

        let dark = try XCTUnwrap(Self.drawTable(values: true, dark: true))
        let darkLines = RulingLineDetector.detect(gray: ImageSupport.grayBytes(from: dark.image), width: Self.width, height: Self.height).lines
        XCTAssertEqual(darkLines.filter { $0.axis == .horizontal }.count, 11)
        XCTAssertEqual(darkLines.filter { $0.axis == .vertical }.count, 7)
    }

    /// Calibration check: SF Pro values drawn at 32 px read back at 32 px (±12 %), in their colour
    /// (ΔE < 10) and regular; bold labels read heavy.
    func testTheValuesStyleIsMeasured() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: true, boldLabels: true))
        let rgba = ImageSupport.rgbaBytes(from: drawing.image)
        let style = try XCTUnwrap(TableStyleEstimator.style(of: drawing.valueBoxes, texts: drawing.valueTexts, rgba: rgba, width: Self.width, height: Self.height))
        print("TABLE-STYLE values size=\(style.relativeSize * Double(Self.height)) weight=\(style.weight) color=\(style.color.hexString)")
        XCTAssertEqual(style.relativeSize * Double(Self.height), Double(Self.valueSize), accuracy: Double(Self.valueSize) * 0.12)
        XCTAssertLessThan(Self.deltaE(style.color, PSColor(hex: "#1C1C1E")!), 10)
        XCTAssertEqual(style.weight, .regular)

        let labels = try XCTUnwrap(TableStyleEstimator.style(of: drawing.labelBoxes, texts: drawing.labelTexts, rgba: rgba, width: Self.width, height: Self.height))
        print("TABLE-STYLE bold labels size=\(labels.relativeSize * Double(Self.height)) weight=\(labels.weight)")
        XCTAssertEqual(labels.relativeSize * Double(Self.height), Double(Self.valueSize), accuracy: Double(Self.valueSize) * 0.15)
        XCTAssertTrue([TableGrid.FontWeight.semibold, .bold].contains(labels.weight), "bold labels read \(labels.weight)")

        let dark = try XCTUnwrap(Self.drawTable(values: true, dark: true))
        let darkStyle = try XCTUnwrap(TableStyleEstimator.style(of: dark.valueBoxes, texts: dark.valueTexts, rgba: ImageSupport.rgbaBytes(from: dark.image),
                                                                width: Self.width, height: Self.height))
        XCTAssertLessThan(Self.deltaE(darkStyle.color, PSColor(hex: "#EBEBF0")!), 10)
        XCTAssertEqual(darkStyle.relativeSize * Double(Self.height), Double(Self.valueSize), accuracy: Double(Self.valueSize) * 0.12)
    }

    // MARK: With Vision

    private func assertGrid(_ grid: TableGrid, drawing: Drawing, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(grid.dataRows.count, 9, file: file, line: line)
        XCTAssertEqual(grid.dataColumns.count, 5, file: file, line: line)
        XCTAssertEqual(grid.names(.column).map { $0.replacingOccurrences(of: "Claude ", with: "") },
                       ["Opus 5.5", "Opus 5", "Fable 5.1", "Gemini 3.5 Pro", "GPT-6 Astra"], "2-line headers, the title left out", file: file, line: line)
        for (index, centre) in drawing.centres.enumerated() {
            guard let cell = grid.cell(dataRow: index / 5 + 1, dataColumn: index % 5 + 1) else {
                XCTFail("no cell r\(index / 5 + 1)c\(index % 5 + 1)", file: file, line: line)
                continue
            }
            let point = PSPoint(x: Double(centre.x) / Double(Self.width), y: Double(centre.y) / Double(Self.height))
            XCTAssertTrue(cell.rect.contains(point), "r\(index / 5 + 1)c\(index % 5 + 1) misses its value", file: file, line: line)
            XCTAssertEqual(cell.contentRect.midX, point.x, accuracy: 0.006 * 4, file: file, line: line)
        }
    }

    func testTheGridOfAFilledTable() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: true))
        let words = try Self.words(in: drawing.image)
        let grid = try XCTUnwrap(TableDetection.grid(in: drawing.image, words: words, remembered: nil))
        assertGrid(grid, drawing: drawing)
        XCTAssertEqual(grid.dataCells.filter { $0.state == .printed }.count, 45)
        let style = try XCTUnwrap(grid.style(forDataColumn: 1))
        XCTAssertEqual(style.relativeSize * Double(Self.height), Double(Self.valueSize), accuracy: Double(Self.valueSize) * 0.12)
        XCTAssertEqual(style.alignment, .center)
    }

    func testTheGridOfAnErasedTableAndItsOCRDump() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: false))
        let words = try Self.words(in: drawing.image)
        let pixels = TableDetection.Pixels(drawing.image)
        let input = TableDetection.input(words: words, pixels: pixels, remembered: nil)
        // The real-OCR dump T pastes into TableOCRDumps.swift (contract §3).
        if let json = try? JSONEncoder().encode(input), let text = String(data: json, encoding: .utf8) { print("TABLE-OCR-DUMP erased \(text)") }
        let grid = try XCTUnwrap(TableDetection.grid(in: drawing.image, words: words, remembered: nil))
        assertGrid(grid, drawing: drawing)
        XCTAssertEqual(grid.emptyDataCells.count, 45, "no ink in an erased cell")
        let style = try XCTUnwrap(grid.style(forDataColumn: 1), "from the row labels")
        XCTAssertEqual(style.relativeSize * Double(Self.height), Double(Self.valueSize), accuracy: Double(Self.valueSize) * 0.12)
    }

    func testTheGridOfADarkFullGrid() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: true, dark: true))
        let words = try Self.words(in: drawing.image)
        let grid = try XCTUnwrap(TableDetection.grid(in: drawing.image, words: words, remembered: nil))
        assertGrid(grid, drawing: drawing)
        let style = try XCTUnwrap(grid.style(forDataColumn: 2))
        XCTAssertLessThan(Self.deltaE(style.color, PSColor(hex: "#EBEBF0")!), 10)
    }

    /// Closed loop (A7): a "1" drawn in every cell at the size measured on the labels of the erased
    /// table reads "1" again through Vision and PixelVerifier.
    func testOnesDrawnAtTheMeasuredSizeReadBack() throws {
        let erased = try XCTUnwrap(Self.drawTable(values: false))
        let rgba = ImageSupport.rgbaBytes(from: erased.image)
        let style = try XCTUnwrap(TableStyleEstimator.style(of: erased.labelBoxes, texts: erased.labelTexts, rgba: rgba, width: Self.width, height: Self.height))
        let size = CGFloat(style.relativeSize * Double(Self.height))
        let canvas = try XCTUnwrap(Canvas(width: Self.width, height: Self.height, paper: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        canvas.context.draw(erased.image, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let font = Self.systemFont(size)
        let ink = CGColor(red: style.color.red, green: style.color.green, blue: style.color.blue, alpha: 1)
        for centre in erased.centres {
            canvas.text("1", font: font, color: ink, x: centre.x, baseline: centre.y + CTFontGetCapHeight(font) / 2, centred: true)
        }
        let filled = try XCTUnwrap(canvas.image)
        let words = try Self.words(in: filled)
        let tableWords = words.map(TableGridBuilder.Word.init)
        var read = 0
        for centre in erased.centres {
            let cell = PSRect(x: Double(centre.x - Self.columnWidth / 2 + 4) / Double(Self.width), y: Double(centre.y - Self.rowHeight / 2 + 4) / Double(Self.height),
                              width: Double(Self.columnWidth - 8) / Double(Self.width), height: Double(Self.rowHeight - 8) / Double(Self.height))
            if PixelVerifier.reads(PixelVerifier.text(in: cell, of: tableWords), as: "1") { read += 1 }
        }
        print("TABLE-CLOSED-LOOP size=\(size) read=\(read)/45")
        XCTAssertGreaterThanOrEqual(read, 43, "Vision read \(read) of 45 ones")
    }

    func testDetectorAndBuilderAreFast() throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: false))
        let words = try Self.words(in: drawing.image).map(TableGridBuilder.Word.init)
        let gray = ImageSupport.grayBytes(from: drawing.image)
        let start = Date()
        let rules = RulingLineDetector.detect(gray: gray, width: Self.width, height: Self.height)
        _ = TableGridBuilder.build(TableGridBuilder.Input(words: words, lines: rules.lines, bands: rules.bands,
                                                         imageSize: PSSize(width: Double(Self.width), height: Double(Self.height))))
        let elapsed = Date().timeIntervalSince(start)
        print("TABLE-TIMING detector+builder \(Int(elapsed * 1000)) ms (debug build)")
        // ≤ 30 ms on an A18 in release; a debug build on a CI runner gets far more room.
        XCTAssertLessThan(elapsed, 3)
    }

    // MARK: Services (A14)

    /// One photo project on disk holding `image` as its base picture.
    private func makeServices(for image: CGImage) throws -> (VisionPhotoServices, PhotoDocument, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picshop-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(rootURL: root)
        let projectID = UUID()
        try store.createPackage(for: projectID)
        let path = "media/table.png"
        try ImageSupport.write(image, to: store.url(for: path, in: projectID), type: .png)
        let document = PhotoDocument(title: "Table", baseImage: MediaAsset(kind: .image, relativePath: path,
                                                                          pixelSize: PSSize(width: Double(image.width), height: Double(image.height))))
        let renderer = PhotoRenderer(store: store, projectID: projectID, inpainting: InpaintingPipeline())
        return (VisionPhotoServices(renderer: renderer, store: store, projectID: projectID), document, root)
    }

    func testTheTableTheSceneMapAndTextQueriesShareOneTextPass() async throws {
        let drawing = try XCTUnwrap(Self.drawTable(values: true))
        _ = try Self.words(in: drawing.image)
        let (services, document, root) = try makeServices(for: drawing.image)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = VisionTextPasses.shared.count
        let grid = try await services.tableGrid(in: document, remembered: nil)
        _ = try await services.textCandidates(VisionTextQuery(kind: .numeric, selectsAll: true, withinTable: true), in: document)
        let map = try await services.sceneMap(in: document)
        XCTAssertEqual(VisionTextPasses.shared.count - before, 1, "one text pass for the table, the text query and the scene map")
        XCTAssertNotNil(grid)
        XCTAssertEqual(map?.table, grid)
        XCTAssertEqual(map?.kind, .table)
        XCTAssertEqual(map?.stateKey, document.baseStateKey)
        XCTAssertFalse(map?.texts.isEmpty ?? true)
        XCTAssertEqual(map?.texts.first?.role, .title)
        // Cached: asking again reads nothing.
        _ = try await services.tableGrid(in: document, remembered: nil)
        XCTAssertEqual(VisionTextPasses.shared.count - before, 1)
    }
}
#endif
