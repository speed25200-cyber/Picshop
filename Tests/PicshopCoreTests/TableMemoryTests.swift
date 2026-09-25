import XCTest
@testable import PicshopCore

/// Phase 0: the new stored fields decode from older projects, the keys are stable, the small pure
/// pieces (refs, styles, formats) behave.
final class TableMemoryTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, absentKeys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let json = String(decoding: data, as: UTF8.self)
        for key in absentKeys {
            XCTAssertFalse(json.contains("\"\(key)\""), "\(key) should be absent when nil", file: file, line: line)
        }
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func testNewFieldsAreOptionalAndAbsentFromOlderJSON() throws {
        let element = TextElement(text: "Hello")
        try roundTrip(element, absentKeys: ["frameWidth"])
        let layer = Layer(name: "Hello", content: .text(element))
        try roundTrip(layer, absentKeys: ["group"])
        let intent = EditIntent(action: .addText, text: "Hello")
        try roundTrip(intent, absentKeys: ["table", "ref", "region", "textStyle"])
        let document = PhotoDocument(title: "Old", canvasSize: PSSize(width: 100, height: 100), layers: [layer])
        try roundTrip(document, absentKeys: ["tableMemory"])
    }

    func testNewFieldsSurviveARoundTrip() throws {
        var element = TextElement(text: "1", frameWidth: 0.1)
        element.fontName = "SFProDigits-Regular"
        let group = LayerGroup(id: UUID(), kind: .tableCells, row: 6, column: 3)
        let layer = Layer(name: "cell", content: .text(element), group: group)
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(Layer.self, from: data)
        XCTAssertEqual(decoded.group, group)
        XCTAssertEqual(decoded.textElement?.frameWidth, 0.1)

        let intent = EditIntent(action: .fillCells, table: TableEditSpec(rows: [.index(-1)], columns: [.name("Opus 5")], value: .random(min: 50, max: 90, decimals: 1),
                                                                         alternative: .constant("1")),
                                ref: .text(3), region: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                                textStyle: TextStyleSpec(size: .scale(1.35), weight: .bold, match: .ref(.text(2))))
        XCTAssertEqual(try JSONDecoder().decode(EditIntent.self, from: try JSONEncoder().encode(intent)), intent)
    }

    func testGeometryKeyIsStableFNVAndFollowsGeometry() {
        let document = PhotoDocument(title: "T", canvasSize: PSSize(width: 1709, height: 2048))
        // FNV-1a of "canvas,1709,2048": the same on every launch, never Hasher.
        XCTAssertEqual(document.tableGeometryKey, "7d3f86da9b7e33ee")
        XCTAssertEqual(StableHash.hex(""), "cbf29ce484222325")

        var cropped = PhotoDocument(title: "T", baseImage: MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: PSSize(width: 1709, height: 2048)))
        let before = cropped.tableGeometryKey
        cropped.apply(.adjust(.exposure, value: 0.2))
        XCTAssertEqual(cropped.tableGeometryKey, before, "a colour edit keeps the cells where they are")
        let baseBefore = cropped.baseStateKey
        cropped.apply(.crop(PSRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)))
        XCTAssertNotEqual(cropped.tableGeometryKey, before)
        XCTAssertNotEqual(cropped.baseStateKey, baseBefore)
    }

    /// Tonal edits leave the scene where it was (no new text pass while a slider moves); what moves or
    /// erases things does not. An expanded canvas moves every cell, so the memory no longer applies.
    func testBaseStateKeyIgnoresTonalEditsAndExpandInvalidatesTheMemory() {
        var document = PhotoDocument(title: "T", baseImage: MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: PSSize(width: 1000, height: 1000)))
        let key = document.baseStateKey
        document.apply(.adjust(.exposure, value: 0.3))
        document.apply(.look(.vivid, intensity: 0.8))
        document.apply(.autoEnhance(strength: 0.5))
        XCTAssertEqual(document.baseStateKey, key)
        document.apply(.removeObject(MaskReference(source: .subject, boundingBox: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))))
        XCTAssertNotEqual(document.baseStateKey, key)

        let grid = TableGrid(id: "g", bounds: .unit, title: nil, rows: [], columns: [], cells: [], headerRowCount: 0, labelColumnCount: 0,
                             ruling: .none, bodyStyle: nil, confidence: 1, source: .detected)
        document.tableMemory = TableMemory(grid: grid, geometryKey: document.tableGeometryKey)
        XCTAssertNotNil(document.rememberedTable, "an erase keeps the cells where they are")
        document.apply(.expand(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
        XCTAssertNil(document.rememberedTable)
    }

    func testRememberedTableNeedsTheSameGeometry() {
        var document = PhotoDocument(title: "T", baseImage: MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: PSSize(width: 1000, height: 1000)))
        let grid = TableGrid(id: "g", bounds: .unit, title: nil, rows: [], columns: [], cells: [], headerRowCount: 0, labelColumnCount: 0,
                             ruling: .none, bodyStyle: nil, confidence: 1, source: .detected)
        document.tableMemory = TableMemory(grid: grid, geometryKey: document.tableGeometryKey)
        XCTAssertEqual(document.rememberedTable?.source, .remembered)
        document.apply(.rotate(degrees: 90))
        XCTAssertNil(document.rememberedTable)
    }

    func testGroupsRemoveTogether() {
        var document = PhotoDocument(title: "T", baseImage: MediaAsset(kind: .image, relativePath: "media/a.png", pixelSize: PSSize(width: 1000, height: 1000)))
        let id = UUID()
        for column in 1...3 {
            document.addLayer(Layer(name: "c\(column)", content: .text(TextElement(text: "1")), group: LayerGroup(id: id, kind: .tableCells, row: 1, column: column)), select: false)
        }
        document.addLayer(Layer(name: "own", content: .text(TextElement(text: "own"))))
        XCTAssertEqual(document.layers(inGroup: id).count, 3)
        XCTAssertEqual(document.removeLayers(inGroup: id), 3)
        XCTAssertEqual(document.textLayers.map(\.name), ["own"])
    }

    func testSceneRefsAreStrict() {
        XCTAssertEqual(SceneRef("t3"), .text(3))
        XCTAssertEqual(SceneRef(" T12 "), .text(12))
        XCTAssertEqual(SceneRef("#l2"), .layer(2))
        XCTAssertEqual(SceneRef("o1"), .object(1))
        XCTAssertEqual(SceneRef("f 4"), .area(4))
        XCTAssertNil(SceneRef("title"))
        XCTAssertNil(SceneRef("t0"))
        XCTAssertNil(SceneRef("x3"))
        XCTAssertEqual(SceneRef.text(7).id, "t7")
        XCTAssertTrue(SceneRef.layer(1).isText)
        XCTAssertFalse(SceneRef.object(1).isText)
    }

    func testTextStyleSpecAppliesOnTopOfAStyle() {
        let base = TableGrid.Style(relativeSize: 0.02, color: .black)
        let bigger = TextStyleSpec(size: .scale(1.5), weight: .bold, alignment: .leading).applied(to: base)
        XCTAssertEqual(bigger.relativeSize, 0.03, accuracy: 1e-9)
        XCTAssertEqual(bigger.fontName, "SFProDigits-Bold")
        XCTAssertEqual(bigger.alignment, .leading)
        XCTAssertEqual(TextStyleSpec(size: .relative(9)).applied(to: base).relativeSize, TextStyleSpec.relativeSizeRange.upperBound)
        XCTAssertEqual(TextStyleSpec(size: .preset(.title)).applied(to: base).relativeSize, SceneMap.SizeClass.title.relativeSize)
    }

    func testFontNamesFollowTheGrammar() {
        XCTAssertEqual(TableGrid.Style(relativeSize: 0.02, color: .black).fontName, "SFProDigits-Regular")
        XCTAssertEqual(TableGrid.Style(relativeSize: 0.02, color: .black, weight: .semibold, design: .serif).fontName, "SFProSerif-Semibold")
        XCTAssertEqual(TableGrid.Style(relativeSize: 0.02, color: .black, weight: .medium, design: .mono).fontName, "SFMono-Medium")
        XCTAssertEqual(SceneMap.weight(ofFontNamed: "SFProRounded-Bold"), .bold)
        XCTAssertEqual(SceneMap.design(ofFontNamed: "SFMono-Regular"), .mono)
    }

    func testNumberFormatInfersAndFormats() {
        let percent = TableGrid.NumberFormat.infer(from: ["80.9%", "77.2%", "—"])
        XCTAssertEqual(percent?.decimals, 1)
        XCTAssertEqual(percent?.suffix, "%")
        XCTAssertEqual(percent?.range, 77.2...80.9)
        XCTAssertEqual(percent?.format(64.24), "64.2%")
        let comma = TableGrid.NumberFormat.infer(from: ["87,3", "12,5"])
        XCTAssertEqual(comma?.decimalSeparator, ",")
        XCTAssertEqual(comma?.format(3.14159), "3,1")
        XCTAssertNil(TableGrid.NumberFormat.infer(from: ["Opus", "Gemini", "12"]))
    }

    func testSceneMapLooksUpAndOverlaysLayers() {
        let title = SceneMap.TextBlock(id: "t1", text: "Soldes d'été", box: PSRect(x: 0.1, y: 0.05, width: 0.8, height: 0.08),
                                       style: TableGrid.Style(relativeSize: 0.07, color: .white, weight: .bold), role: .title)
        let price = SceneMap.TextBlock(id: "t2", text: "29,99 €", box: PSRect(x: 0.1, y: 0.85, width: 0.2, height: 0.05),
                                       style: TableGrid.Style(relativeSize: 0.04, color: .red))
        let map = SceneMap(stateKey: "k", canvasSize: PSSize(width: 1000, height: 1000), texts: [title, price])
        XCTAssertEqual(map.title?.id, "t1")
        XCTAssertEqual(map.texts(matching: "SOLDES D ETE").first?.id, "t1")
        XCTAssertEqual(map.nearestText(to: PSPoint(x: 0.2, y: 0.9))?.id, "t2")
        XCTAssertEqual(map.block(.text(2))?.text, "29,99 €")
        XCTAssertEqual(title.sizeClass, .large)
        XCTAssertEqual(price.colorClass, "red")
        XCTAssertEqual(map.style(near: PSRect(x: 0.1, y: 0.8, width: 0.1, height: 0.05))?.color, .red)

        let layer = Layer(name: "New", content: .text(TextElement(text: "Nouveau", relativeSize: 0.05, center: PSPoint(x: 0.5, y: 0.5))))
        let grouped = Layer(name: "cell", content: .text(TextElement(text: "1")), group: LayerGroup(id: UUID(), kind: .tableCells, row: 1, column: 1))
        let overlaid = map.overlaying([layer, grouped])
        XCTAssertEqual(overlaid.texts.count, 3, "table cells stay in the table")
        XCTAssertEqual(overlaid.block(.layer(1))?.layerID, layer.id)
        XCTAssertEqual(overlaid.overlaying([]).texts.count, 2, "overlaying again replaces the layer blocks")
    }
}
