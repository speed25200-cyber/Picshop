import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (D19, §8.5): the stored refs, the `layers:` line (8 documents, the budget, the delta rule), a plan that inserts
/// a layer and still aims at the same UUIDs, bundles as one `g` entry, and the masks line's owners.
final class LayerRefsTests: XCTestCase {
    static func line(_ document: PhotoDocument, _ language: OpLanguage = .fr) -> String? {
        LiveLayerLines.line(for: document, scene: nil, language: language)
    }

    static func image(_ name: String, center: PSPoint = PSPoint(x: 0.5, y: 0.5)) -> Layer {
        var layer = Layer(name: name, content: .image(MediaAsset(kind: .image, relativePath: "media/\(name).png", pixelSize: PSSize(width: 600, height: 400))))
        layer.transform = LayerTransform(center: center, scale: 0.4)
        return layer
    }

    // MARK: The line, eight documents

    /// 1. The photo alone has no line.
    func testThePhotoAloneHasNoLine() {
        XCTAssertNil(Self.line(PhotoDocument(title: "P", baseImage: OperationFixtures.base)))
    }

    /// 2. The poster: texts quoted, the selection flagged, the photo last.
    func testThePosterLine() throws {
        let line = try XCTUnwrap(Self.line(OperationFixtures.photo()))
        XCTAssertEqual(line, "layers: s1 Shape | l2 \"Jusqu'au 31 août\" text | l1 \"SOLDES\" text sel | Photo base")
        let english = try XCTUnwrap(Self.line(OperationFixtures.photo(), .en))
        XCTAssertTrue(english.hasSuffix("| Base photo"), english)
    }

    /// 3. The layered poster: every kind of ref, within the budget (the group's children elided first).
    func testTheLayeredPosterLine() throws {
        let document = OperationFixtures.photoWithLayers()
        let line = try XCTUnwrap(Self.line(document))
        XCTAssertLessThanOrEqual(line.count, LiveLayerLines.budget)
        for piece in ["g1 Groupe 1 [2 calques]", "j9 Look", "j1 Couleur unie 50%", "i2 Logo", "i1 Tasse mask", "l1 \"SOLDES\" text sel", "Photo base"] {
            XCTAssertTrue(line.contains(piece), "\(piece) in \(line)")
        }
        XCTAssertTrue(line.hasPrefix("layers: g1"), "top first: \(line)")
    }

    /// 4. The flags that are not default, in order.
    func testFlags() throws {
        var document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        var logo = Self.image("Logo")
        logo.opacity = 0.8
        logo.fillOpacity = 0.4
        logo.blendMode = .multiply
        logo.isVisible = false
        logo.lockOptions = [.position]
        document.addLayer(logo, select: false)
        var tint = Layer(name: "Teinte", content: .fill(.red))
        tint.isClipped = true
        document.addLayer(tint, select: true)
        let line = try XCTUnwrap(Self.line(document))
        XCTAssertEqual(line, "layers: j1 Teinte clip sel | i1 Logo 80% fill 40% multiply hidden lock pos | Photo base")
    }

    /// 5. A table bundle is one `g` entry, whatever its cell count.
    func testABundleIsOneGEntry() throws {
        var document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        let bundle = UUID()
        for column in 1...3 {
            var cell = Layer(name: "Cell", content: .text(TextElement(text: "\(column * 10)", relativeSize: 0.02, center: PSPoint(x: 0.2 * Double(column), y: 0.5))))
            cell.group = LayerGroup(id: bundle, kind: .tableCells, row: 1, column: column)
            document.addLayer(cell, select: false)
        }
        let line = try XCTUnwrap(Self.line(document))
        XCTAssertEqual(line.components(separatedBy: "Tableau").count - 1, 1, line)
        XCTAssertTrue(line.contains("Tableau 3 cases"), line)
        let refs = LiveLayerLines.refs(in: document, scene: nil)
        let ref = try XCTUnwrap(refs[document.layers[1].id])
        XCTAssertTrue(ref.hasPrefix("g"), ref)
        XCTAssertEqual(Set(document.layers.dropFirst().map { refs[$0.id] }).count, 1, "the members share their ref")
        XCTAssertEqual(LiveLayerLines.layerIDs(ref: ref, in: document, scene: nil)?.count, 3)
    }

    /// 6. Over the budget: the lowest rows go, counted.
    func testTheBudgetDropsTheLowestRows() throws {
        var document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        for index in 1...40 { document.addLayer(Self.image("Calque numéro \(index)"), select: false) }
        let line = try XCTUnwrap(Self.line(document))
        XCTAssertLessThanOrEqual(line.count, LiveLayerLines.budget)
        XCTAssertTrue(line.contains("… +"), line)
        XCTAssertTrue(line.hasPrefix("layers: i40 "), "the top stays: \(line)")
    }

    /// 7. A collapsed group's children are elided before any row is dropped.
    func testACollapsedGroupIsElidedFirst() throws {
        var document = PhotoDocument(title: "P", baseImage: OperationFixtures.base)
        let a = Self.image("Premier calque assez long"), b = Self.image("Deuxième calque assez long")
        for index in 1...6 { document.addLayer(Self.image("Image de fond numéro \(index)"), select: false) }
        document.addLayer(a, select: false)
        document.addLayer(b, select: false)
        let grouped = document.applyStructureEdit(.group([a.id, b.id], name: "Groupe"))
        let groupID = try XCTUnwrap(grouped.layerID)
        _ = document.applyLayerEdit(.folder(LayerFolder(passThrough: false, isCollapsed: true)), to: groupID, contentSize: nil)
        let line = try XCTUnwrap(Self.line(document))
        XCTAssertLessThanOrEqual(line.count, LiveLayerLines.budget)
        if line.contains("[2 calques]") { XCTAssertFalse(line.contains("… +"), line) }
    }

    /// 8. Refs are stored: deleting one never renumbers the others, and a new layer takes a new number.
    func testStoredRefsNeverShift() throws {
        var document = OperationFixtures.photoWithLayers()
        XCTAssertNotNil(document.removeLayer(id: OperationFixtures.cupID))
        let refs = LiveLayerLines.refs(in: document, scene: nil)
        XCTAssertEqual(refs[OperationFixtures.logoID], "i2")
        let added = Self.image("Nouveau")
        document.addLayer(added, select: false)
        XCTAssertEqual(LiveLayerLines.ref(of: added.id, in: document, scene: nil), "i3")
        XCTAssertNil(LiveLayerLines.layer(ref: "i1", in: document, scene: nil), "i1 is gone, not reused")
        XCTAssertEqual(LiveLayerLines.layer(ref: "I2", in: document, scene: nil)?.id, OperationFixtures.logoID, "case and # are forgiven")
        XCTAssertEqual(LiveLayerLines.layer(ref: "#i0", in: document, scene: nil)?.id, document.baseLayerID)
    }

    func testUnknownRefsListTheExistingOnes() {
        let document = OperationFixtures.photoWithLayers()
        let all = LiveLayerLines.existingRefs(in: document, scene: nil)
        XCTAssertTrue(all.hasPrefix("g1, "), all)
        XCTAssertLessThanOrEqual(all.count, 125)
        let images = LiveLayerLines.existingRefs(in: document, scene: nil, kinds: [.imageLayer])
        XCTAssertEqual(images, "i2, i1, i0")
    }

    // MARK: The delta rule

    func testTheLayersLineFollowsTheDeltaRule() {
        var state = LiveEditorState(mode: .photo, version: 1)
        state.layers = "layers: i1 Logo sel | Photo base"
        let turn = LiveUserTurn(id: 1, kind: .speech, text: "plus clair", language: .french, image: nil, editorState: state)
        let first = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: false)
        XCTAssertTrue(first.contains("layers: i1 Logo sel | Photo base"), first)
        let same = LocalLivePrompt.userMessage(turn, previous: state, imageAttached: false)
        XCTAssertFalse(same.contains("layers:"), "unchanged: not repeated")
        var gone = state
        gone.layers = nil
        let goneTurn = LiveUserTurn(id: 2, kind: .speech, text: "plus clair", language: .french, image: nil, editorState: gone)
        XCTAssertTrue(LocalLivePrompt.userMessage(goneTurn, previous: state, imageAttached: false).contains("layers: photo only"))
    }

    // MARK: Plans keep their targets

    /// A 3-step plan that inserts a layer below i1, then names i1 and j1: the refs are stored, so the later steps still
    /// target the same UUIDs.
    func testAPlanThatInsertsALayerKeepsItsTargets() async throws {
        let document = OperationFixtures.photoWithLayers()
        let steps = [
            OperationCall("addFillLayer", args: ["fill": "solid", "color": "white", "position": "below", "ref": "i1"], source: .model),
            OperationCall("layerProperties", args: ["ref": "i1", "name": "Produit"], source: .model),
            OperationCall("fillLayer", args: ["ref": "j1", "color": "blue"], source: .model),
        ].map { EditIntent(action: .operation, confidence: 0.9, operation: $0) }
        let executor = PhotoCommandExecutor(services: SelectionOperationTests.services(), language: .french)
        let (after, results) = await executor.execute(steps: steps, on: document, context: OperationFixtures.photoContext(document))
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy(\.outcome.isSuccess), "\(results.map(\.outcome))")
        XCTAssertEqual(after.layer(id: OperationFixtures.cupID)?.name, "Produit")
        XCTAssertEqual(after.layer(id: OperationFixtures.solidID)?.content, .fill(.blue))
        let cupIndex = try XCTUnwrap(after.layers.firstIndex { $0.id == OperationFixtures.cupID })
        XCTAssertEqual(after.layers[cupIndex - 1].content, .fill(.white), "the new fill sits right below i1")
        XCTAssertEqual(LiveLayerLines.ref(of: after.layers[cupIndex - 1].id, in: after, scene: nil), "j10", "a new number, none reused")
    }

    // MARK: The masks line's owners

    func testTheMasksLineNamesEachOwner() throws {
        let document = OperationFixtures.photoWithLayers()
        let lines = LiveMaskLines.lines(for: document, language: .fr)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("(sky, i0)"), lines[0])
        XCTAssertTrue(lines[2].hasPrefix("a3 ") && lines[2].contains("i1"), lines[2])
        let a3 = try XCTUnwrap(LiveMaskLines.mask(ref: "a3", in: document))
        XCTAssertEqual(a3.layerID, OperationFixtures.cupID)
        XCTAssertEqual(a3.adjustmentID, OperationFixtures.cupMaskID)
        let a2 = try XCTUnwrap(LiveMaskLines.mask(ref: "a2", in: document))
        XCTAssertEqual(a2.layerID, document.baseLayerID)
        XCTAssertEqual(a2.adjustmentID, OperationFixtures.bottomMaskID)
        XCTAssertNil(LiveMaskLines.mask(ref: "a4", in: document))
        XCTAssertEqual(LiveMaskLines.ref(of: OperationFixtures.cupMaskID, in: document), "a3")
    }

    /// Only the photo's masks: no owner is printed (the W2 line, unchanged).
    func testOwnersOnlyWhenAnotherLayerHasMasks() {
        let lines = LiveMaskLines.lines(for: OperationFixtures.photoWithMasks(), language: .fr)
        XCTAssertFalse(lines.joined().contains("i0"), "\(lines)")
    }
}
