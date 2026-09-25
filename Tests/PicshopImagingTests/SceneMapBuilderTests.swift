import XCTest
import PicshopCore
@testable import PicshopImaging

/// The scene map the model reads, built from synthetic OCR, detections and bitmaps. Runs on Linux.
final class SceneMapBuilderTests: XCTestCase {
    /// A flat bitmap of one colour.
    private func bitmap(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> SceneMapBuilder.Bitmap {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            rgba[pixel * 4] = red
            rgba[pixel * 4 + 1] = green
            rgba[pixel * 4 + 2] = blue
        }
        return SceneMapBuilder.Bitmap(rgba: rgba, width: width, height: height)
    }

    func testNothingReadGivesAnEmptyMapOfThatState() {
        let map = SceneMapBuilder.build(SceneMapBuilder.Input(stateKey: "0123456789abcdef", canvasSize: PSSize(width: 1080, height: 1350)))
        XCTAssertEqual(map.stateKey, "0123456789abcdef")
        XCTAssertEqual(map.canvasSize, PSSize(width: 1080, height: 1350))
        XCTAssertTrue(map.isEmpty)
        XCTAssertEqual(map.kind, .photo)
        XCTAssertTrue(map.freeAreas.isEmpty)
        XCTAssertNil(map.background)
    }

    func testATableCoveringThePictureMakesATableMap() {
        let grid = TableGrid(id: "t", bounds: PSRect(x: 0.02, y: 0.1, width: 0.96, height: 0.8), title: nil, rows: [], columns: [], cells: [],
                             headerRowCount: 1, labelColumnCount: 1, ruling: .horizontal, bodyStyle: nil, confidence: 0.9, source: .detected)
        let map = SceneMapBuilder.build(SceneMapBuilder.Input(stateKey: "k", canvasSize: PSSize(width: 1709, height: 2048), table: grid))
        XCTAssertEqual(map.table, grid)
        XCTAssertEqual(map.kind, .table)
    }

    func testObjectsAreDedupedAndNumberedLargestFirst() {
        let detections = [
            SceneMap.Object(id: "x", label: "dog", box: PSRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2), confidence: 0.8, kind: .animal),
            SceneMap.Object(id: "y", label: "person", box: PSRect(x: 0.1, y: 0.1, width: 0.4, height: 0.8), confidence: 0.9, kind: .person),
            // The same person, seen again by the instance masks.
            SceneMap.Object(id: "z", label: "person", box: PSRect(x: 0.11, y: 0.1, width: 0.39, height: 0.79), confidence: 0.6, kind: .person),
            // Too unsure, and a speck.
            SceneMap.Object(id: "w", label: "cup", box: PSRect(x: 0.8, y: 0.1, width: 0.1, height: 0.1), confidence: 0.2),
            SceneMap.Object(id: "v", label: "cup", box: PSRect(x: 0.8, y: 0.1, width: 0.01, height: 0.01), confidence: 0.9),
        ]
        let objects = SceneMapBuilder.objects(from: detections)
        XCTAssertEqual(objects.map(\.id), ["o1", "o2"])
        XCTAssertEqual(objects.map(\.label), ["person", "dog"])
        XCTAssertEqual(objects[0].confidence, 0.9)
        XCTAssertEqual(SceneMapBuilder.objects(from: detections, limit: 1).map(\.label), ["person"])
    }

    func testTilesReadAFlatPicture() throws {
        let tiles = try XCTUnwrap(SceneMapBuilder.Tiles(bitmap: bitmap(width: 96, height: 120, red: 255, green: 255, blue: 255), columns: 12, rows: 10))
        XCTAssertEqual(tiles.means.count, 120)
        XCTAssertEqual(tiles.spreads.count, 120)
        XCTAssertEqual(tiles.flatShare, 1)
        XCTAssertEqual(tiles.rect(column: 11, row: 9).maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(tiles.rect(column: 11, row: 9).maxY, 1, accuracy: 1e-9)
        let background = try XCTUnwrap(SceneMapBuilder.background(of: tiles))
        XCTAssertEqual(background.red, 1, accuracy: 0.01)
        XCTAssertEqual(background.blue, 1, accuracy: 0.01)
        XCTAssertNil(SceneMapBuilder.Tiles(bitmap: SceneMapBuilder.Bitmap(rgba: [1, 2, 3], width: 10, height: 10)))
    }

    func testANoisyPictureHasNoDominantColour() throws {
        let width = 64, height = 64
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) where (pixel + pixel / width) % 2 == 0 {
            rgba[pixel * 4] = 0
            rgba[pixel * 4 + 1] = 0
            rgba[pixel * 4 + 2] = 0
        }
        let tiles = try XCTUnwrap(SceneMapBuilder.Tiles(bitmap: SceneMapBuilder.Bitmap(rgba: rgba, width: width, height: height), columns: 8, rows: 8))
        XCTAssertEqual(tiles.flatShare, 0)
        XCTAssertNil(SceneMapBuilder.background(of: tiles))
    }

    // MARK: Text blocks

    private func word(_ text: String, x: Double, y: Double, width: Double? = nil, height: Double = 0.02, line: Int) -> TableGridBuilder.Word {
        TableGridBuilder.Word(text: text, box: PSRect(x: x, y: y, width: width ?? Double(text.count) * height * 0.5, height: height), line: line, confidence: 0.9)
    }

    func testLinesOfAParagraphMakeOneBlockAndTheTitleIsFound() {
        let words = [
            word("SOLDES", x: 0.2, y: 0.05, height: 0.06, line: 0), word("D'ÉTÉ", x: 0.45, y: 0.05, height: 0.06, line: 0),
            word("Tout", x: 0.1, y: 0.4, line: 1), word("le", x: 0.16, y: 0.4, line: 1), word("magasin", x: 0.2, y: 0.4, line: 1),
            word("jusqu'à", x: 0.1, y: 0.425, line: 2), word("dimanche", x: 0.2, y: 0.425, line: 2),
            word("Offre", x: 0.6, y: 0.9, height: 0.012, line: 3), word("limitée", x: 0.635, y: 0.9, height: 0.012, line: 3),
        ]
        let blocks = SceneMapBuilder.blocks(from: words, table: nil)
        XCTAssertEqual(blocks.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(blocks.map(\.text), ["SOLDES D'ÉTÉ", "Tout le magasin\njusqu'à dimanche", "Offre limitée"])
        XCTAssertEqual(blocks.map(\.role), [.title, .body, .caption])
        XCTAssertEqual(blocks[1].lineCount, 2)
        XCTAssertEqual(blocks[1].wordBoxes.count, 5)
        XCTAssertEqual(blocks[1].box.minY, 0.4, accuracy: 1e-9)
        XCTAssertEqual(blocks[1].confidence, 0.9, accuracy: 1e-9)
        XCTAssertEqual(blocks[0].source, .printed)
    }

    func testAWideGapSplitsALineIntoTwoBlocksReadLeftToRight() {
        let words = [word("Price", x: 0.7, y: 0.3, line: 0), word("Name", x: 0.1, y: 0.3, line: 0), word("Total", x: 0.1, y: 0.5, line: 1)]
        let blocks = SceneMapBuilder.blocks(from: words, table: nil)
        XCTAssertEqual(blocks.map(\.text), ["Name", "Price", "Total"])
    }

    /// A 3-row, 3-column table (header row, label column) from x 0.1 to 0.9 and y 0.2 to 0.8.
    private func table(title: String? = nil) -> TableGrid {
        let xs = [0.1, 0.4, 0.65, 0.9], ys = [0.2, 0.4, 0.6, 0.8]
        var rows: [TableGrid.Row] = [], columns: [TableGrid.Column] = [], cells: [TableGrid.Cell] = []
        for r in 0..<3 { rows.append(TableGrid.Row(index: r, rect: PSRect(x: 0.1, y: ys[r], width: 0.8, height: 0.2), label: r == 0 ? "" : "Row \(r)", isHeader: r == 0)) }
        for c in 0..<3 {
            columns.append(TableGrid.Column(index: c, rect: PSRect(x: xs[c], y: 0.2, width: xs[c + 1] - xs[c], height: 0.6), header: c == 0 ? "" : "Col \(c)", isLabel: c == 0))
        }
        for r in 0..<3 {
            for c in 0..<3 {
                let rect = PSRect(x: xs[c], y: ys[r], width: xs[c + 1] - xs[c], height: 0.2)
                let kind: TableGrid.CellKind = r == 0 ? (c == 0 ? .corner : .header) : (c == 0 ? .label : .data)
                cells.append(TableGrid.Cell(row: r, column: c, rect: rect, contentRect: rect, text: kind == .data && r == 1 ? "12" : "", kind: kind,
                                            state: kind == .data && r == 1 ? .printed : .empty))
            }
        }
        return TableGrid(id: "g", bounds: PSRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6), title: title, rows: rows, columns: columns, cells: cells,
                         headerRowCount: 1, labelColumnCount: 1, ruling: .horizontal, bodyStyle: nil, confidence: 0.9, source: .detected)
    }

    func testTablePartsGetTheirOwnBlocksAfterTheTextAbove() {
        let words = [
            word("Scores", x: 0.1, y: 0.05, height: 0.05, line: 0),
            word("Col", x: 0.45, y: 0.28, line: 1), word("1", x: 0.5, y: 0.28, line: 1), word("Col", x: 0.7, y: 0.28, line: 1), word("2", x: 0.75, y: 0.28, line: 1),
            word("Row", x: 0.12, y: 0.48, line: 2), word("1", x: 0.17, y: 0.48, line: 2), word("12", x: 0.5, y: 0.48, line: 2), word("12", x: 0.75, y: 0.48, line: 2),
            word("Row", x: 0.12, y: 0.68, line: 3), word("2", x: 0.17, y: 0.68, line: 3),
            word("Source:", x: 0.1, y: 0.9, height: 0.012, line: 4), word("tests", x: 0.147, y: 0.9, height: 0.012, line: 4),
        ]
        let blocks = SceneMapBuilder.blocks(from: words, table: table())
        XCTAssertEqual(blocks.map(\.text), ["Scores", "Col 1", "Col 2", "Row 1", "Row 2", "Source: tests", "12", "12"])
        XCTAssertEqual(blocks.map(\.role), [.title, .tableHeader, .tableHeader, .tableLabel, .tableLabel, .caption, .tableCell, .tableCell],
                       "the footnote is smaller than the table's text")
        XCTAssertEqual(blocks.map(\.id), (1...8).map { "t\($0)" })
    }

    func testALoneHeadingOverATableIsItsTitle() {
        let words = [
            word("Benchmarks", x: 0.1, y: 0.05, height: 0.03, line: 0),
            word("Col", x: 0.45, y: 0.28, line: 1), word("1", x: 0.5, y: 0.28, line: 1), word("Col", x: 0.7, y: 0.28, line: 1), word("2", x: 0.75, y: 0.28, line: 1),
            word("Row", x: 0.12, y: 0.48, line: 2), word("1", x: 0.17, y: 0.48, line: 2), word("Row", x: 0.12, y: 0.68, line: 3), word("2", x: 0.17, y: 0.68, line: 3),
        ]
        let blocks = SceneMapBuilder.blocks(from: words, table: table())
        XCTAssertEqual(blocks.first?.text, "Benchmarks")
        XCTAssertEqual(blocks.first?.role, .title)
    }

    func testCellsGoFirstWhenThereAreTooManyBlocks() {
        var words = [word("Title", x: 0.1, y: 0.05, height: 0.05, line: 0)]
        // 100 printed cells in a 10 × 10 data grid.
        var rows: [TableGrid.Row] = [], columns: [TableGrid.Column] = [], cells: [TableGrid.Cell] = []
        for r in 0..<11 { rows.append(TableGrid.Row(index: r, rect: PSRect(x: 0.1, y: 0.15 + Double(r) * 0.07, width: 0.8, height: 0.07), label: "", isHeader: r == 0)) }
        for c in 0..<11 { columns.append(TableGrid.Column(index: c, rect: PSRect(x: 0.1 + Double(c) * 0.07, y: 0.15, width: 0.07, height: 0.77), header: "", isLabel: c == 0)) }
        var line = 1
        for r in 0..<11 {
            for c in 0..<11 {
                let rect = PSRect(x: 0.1 + Double(c) * 0.07, y: 0.15 + Double(r) * 0.07, width: 0.07, height: 0.07)
                let kind: TableGrid.CellKind = r == 0 ? (c == 0 ? .corner : .header) : (c == 0 ? .label : .data)
                cells.append(TableGrid.Cell(row: r, column: c, rect: rect, contentRect: rect, text: "\(r)\(c)", kind: kind, state: .printed))
                words.append(word("\(r)\(c)", x: rect.minX + 0.01, y: rect.minY + 0.02, height: 0.02, line: line))
            }
            line += 1
        }
        let grid = TableGrid(id: "g", bounds: PSRect(x: 0.1, y: 0.15, width: 0.77, height: 0.77), title: nil, rows: rows, columns: columns, cells: cells,
                             headerRowCount: 1, labelColumnCount: 1, ruling: .full, bodyStyle: nil, confidence: 0.9, source: .detected)
        let blocks = SceneMapBuilder.blocks(from: words, table: grid)
        XCTAssertEqual(blocks.count, SceneMapBuilder.maxTexts)
        XCTAssertEqual(blocks.filter { $0.role != .tableCell }.count, 1 + 11 + 10, "title, headers and corner, labels all kept")
        XCTAssertEqual(blocks.last?.role, .tableCell)
    }

    func testAColumnOfCentredLinesIsCentred() {
        let block = SceneMap.TextBlock(id: "t1", text: "a\nbbbbbb\ncc", box: .unit, lineCount: 3,
                                       wordBoxes: [PSRect(x: 0.45, y: 0.1, width: 0.1, height: 0.02), PSRect(x: 0.3, y: 0.13, width: 0.4, height: 0.02),
                                                   PSRect(x: 0.42, y: 0.16, width: 0.16, height: 0.02)])
        XCTAssertEqual(SceneMapBuilder.alignment(of: block), .center)
        var left = block
        left.wordBoxes = [PSRect(x: 0.1, y: 0.1, width: 0.1, height: 0.02), PSRect(x: 0.1, y: 0.13, width: 0.4, height: 0.02)]
        XCTAssertEqual(SceneMapBuilder.alignment(of: left), .leading)
    }

    func testBlocksAreMeasuredOnThePixels() throws {
        var picture = SyntheticPicture(width: 600, height: 400)
        // "11" drawn 20 px tall in #1C1C1E at (100, 100).
        picture.fill(x: 100, y: 100, width: 3, height: 20, level: 0x1C)
        picture.fill(x: 112, y: 100, width: 3, height: 20, level: 0x1C)
        let words = [TableGridBuilder.Word(text: "11", box: picture.box(x: 98, y: 97, width: 20, height: 26), line: 0)]
        let bitmap = SceneMapBuilder.Bitmap(rgba: picture.rgba, width: 600, height: 400)
        let blocks = SceneMapBuilder.measured(SceneMapBuilder.blocks(from: words, table: nil), on: bitmap)
        let style = try XCTUnwrap(blocks.first?.style)
        XCTAssertEqual(style.relativeSize * 400, 20 * TableStyleEstimator.Calibration.capHeightToFontSize, accuracy: 1)
        XCTAssertEqual(blocks.first?.colorClass, "dark")
        XCTAssertEqual(blocks.first?.sizeClass, .large, "28 px type on a 400 px canvas")
    }

    // MARK: Free areas and kind

    func testFreeAreasAvoidTextAndSplitByColour() throws {
        // Left half white, right half blue; a text block top left.
        let width = 240, height = 240
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in (width / 2)..<width {
                let index = (y * width + x) * 4
                rgba[index] = 40
                rgba[index + 1] = 90
                rgba[index + 2] = 200
            }
        }
        let tiles = try XCTUnwrap(SceneMapBuilder.Tiles(bitmap: SceneMapBuilder.Bitmap(rgba: rgba, width: width, height: height)))
        let text = PSRect(x: 0.05, y: 0.05, width: 0.3, height: 0.1)
        let areas = SceneMapBuilder.freeAreas(in: tiles, avoiding: [text])
        XCTAssertFalse(areas.isEmpty)
        XCTAssertLessThanOrEqual(areas.count, SceneMapBuilder.maxFreeAreas)
        XCTAssertEqual(areas.map(\.id), (1...areas.count).map { "f\($0)" })
        for area in areas {
            XCTAssertEqual(area.box.intersection(text).area, 0, accuracy: 1e-12)
            XCTAssertTrue(area.box.maxX <= 0.5 + 1e-9 || area.box.minX >= 0.5 - 1e-9, "one colour per area: \(area.box)")
            XCTAssertTrue(area.isUniform)
            XCTAssertGreaterThanOrEqual(area.box.area, 0.02)
        }
        let blue = try XCTUnwrap(areas.first { $0.box.minX >= 0.5 - 1e-9 })
        XCTAssertEqual(blue.box.area, 0.5, accuracy: 0.01, "the whole right half")
        XCTAssertEqual(try XCTUnwrap(blue.background).blue, 200 / 255, accuracy: 0.01)
        XCTAssertEqual(SceneMapBuilder.freeAreas(in: tiles, avoiding: [], limit: 1).count, 1)
    }

    func testANoisyPictureHasNoFreeArea() throws {
        let width = 64, height = 64
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) where (pixel + pixel / width) % 2 == 0 { rgba[pixel * 4] = 0; rgba[pixel * 4 + 1] = 0; rgba[pixel * 4 + 2] = 0 }
        let tiles = try XCTUnwrap(SceneMapBuilder.Tiles(bitmap: SceneMapBuilder.Bitmap(rgba: rgba, width: width, height: height), columns: 8, rows: 8))
        XCTAssertTrue(SceneMapBuilder.freeAreas(in: tiles, avoiding: []).isEmpty)
    }

    func testKinds() throws {
        let flat = try XCTUnwrap(SceneMapBuilder.Tiles(bitmap: bitmap(width: 96, height: 96, red: 255, green: 255, blue: 255)))
        let clock = SceneMap.TextBlock(id: "t1", text: "9:41", box: PSRect(x: 0.05, y: 0.01, width: 0.08, height: 0.02))
        XCTAssertEqual(SceneMapBuilder.kind(texts: [clock], objects: [], table: nil, tiles: nil), .screenshot)
        let ui = (0..<4).map { SceneMap.TextBlock(id: "t\($0)", text: "Settings", box: PSRect(x: 0.1, y: 0.2 + Double($0) * 0.1, width: 0.2, height: 0.03)) }
        XCTAssertEqual(SceneMapBuilder.kind(texts: ui, objects: [], table: nil, tiles: flat), .screenshot)
        let page = (0..<12).map { SceneMap.TextBlock(id: "t\($0)", text: "Lorem ipsum dolor sit amet", box: PSRect(x: 0.1, y: 0.05 + Double($0) * 0.07, width: 0.8, height: 0.05)) }
        XCTAssertEqual(SceneMapBuilder.kind(texts: page, objects: [], table: nil, tiles: flat), .document)
        let person = SceneMap.Object(id: "o1", label: "person", box: PSRect(x: 0.3, y: 0.2, width: 0.4, height: 0.7), confidence: 0.9, kind: .person)
        XCTAssertEqual(SceneMapBuilder.kind(texts: ui, objects: [person], table: nil, tiles: flat), .photo)
        XCTAssertEqual(SceneMapBuilder.kind(texts: [], objects: [], table: nil, tiles: nil), .photo)
        XCTAssertTrue(SceneMapBuilder.isClock("14h05"))
        XCTAssertFalse(SceneMapBuilder.isClock("25:00"))
        XCTAssertFalse(SceneMapBuilder.isClock("87.3"))
    }

    func testBuildPutsEverythingTogether() {
        var picture = SyntheticPicture(width: 400, height: 500)
        picture.fill(x: 40, y: 40, width: 3, height: 30, level: 0x10)
        picture.fill(x: 52, y: 40, width: 3, height: 30, level: 0x10)
        let words = [TableGridBuilder.Word(text: "11", box: picture.box(x: 38, y: 36, width: 20, height: 38), line: 0)]
        let detections = [SceneMap.Object(id: "", label: "cup", box: PSRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), confidence: 0.8)]
        let map = SceneMapBuilder.build(SceneMapBuilder.Input(stateKey: "k", canvasSize: PSSize(width: 400, height: 500), words: words, detections: detections,
                                                              bitmap: SceneMapBuilder.Bitmap(rgba: picture.rgba, width: 400, height: 500)))
        XCTAssertEqual(map.texts.map(\.id), ["t1"])
        XCTAssertNotNil(map.texts.first?.style)
        XCTAssertEqual(map.objects.map(\.id), ["o1"])
        XCTAssertFalse(map.freeAreas.isEmpty)
        for area in map.freeAreas {
            XCTAssertEqual(area.box.intersection(detections[0].box).area, 0, accuracy: 1e-12)
            XCTAssertEqual(area.box.intersection(map.texts[0].box).area, 0, accuracy: 1e-12)
        }
        XCTAssertEqual(map.background?.red ?? 0, 1, accuracy: 0.01)
    }
}
