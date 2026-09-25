import XCTest
@testable import PicshopCore

/// Scene-map ids stay on the same things from one version to the next, so "t3" the model read a
/// turn ago still names that block, and a layer keeps its "l" id however often the map is overlaid.
final class SceneMapTests: XCTestCase {
    private func block(_ id: String, _ text: String, x: Double, y: Double) -> SceneMap.TextBlock {
        SceneMap.TextBlock(id: id, text: text, box: PSRect(x: x, y: y, width: 0.2, height: 0.05))
    }

    func testIDsCarryOverVersions() {
        let before = SceneMap(stateKey: "a", canvasSize: PSSize(width: 1000, height: 1000),
                              texts: [block("t1", "SOLDES", x: 0.1, y: 0.1), block("t2", "-50%", x: 0.1, y: 0.2), block("t3", "29,99 €", x: 0.1, y: 0.8)],
                              objects: [SceneMap.Object(id: "o1", label: "person", box: PSRect(x: 0.3, y: 0.3, width: 0.3, height: 0.5), confidence: 0.9),
                                        SceneMap.Object(id: "o2", label: "dog", box: PSRect(x: 0.7, y: 0.6, width: 0.2, height: 0.2), confidence: 0.8)],
                              freeAreas: [SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.6, y: 0.05, width: 0.35, height: 0.2))])
        // "-50%" was erased; OCR now reads "SOLDES" slightly moved, "29,99 €" as "29,99€", and finds a new word.
        let after = SceneMap(stateKey: "b", canvasSize: PSSize(width: 1000, height: 1000),
                             texts: [block("t1", "SOLDES", x: 0.105, y: 0.1), block("t2", "29,99€", x: 0.1, y: 0.8), block("t3", "Nouveau", x: 0.5, y: 0.5)],
                             objects: [SceneMap.Object(id: "o1", label: "dog", box: PSRect(x: 0.71, y: 0.6, width: 0.2, height: 0.2), confidence: 0.8)],
                             freeAreas: [SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
                                         SceneMap.FreeArea(id: "f2", box: PSRect(x: 0.6, y: 0.06, width: 0.35, height: 0.2))])
        let carried = after.carryingIDs(from: before)
        XCTAssertEqual(carried.texts.map(\.id), ["t1", "t3", "t4"], "the same text keeps its id; a new one comes after the highest")
        XCTAssertEqual(carried.text(id: "t3")?.text, "29,99€")
        XCTAssertNil(carried.text(id: "t2"), "an erased block's id is not reused")
        XCTAssertEqual(carried.objects.map(\.id), ["o2"], "the dog stays o2 after the person went")
        XCTAssertEqual(carried.freeAreas.map(\.id), ["f2", "f1"])
    }

    func testLayerIDsAreStable() {
        let map = SceneMap(stateKey: "a", canvasSize: PSSize(width: 1000, height: 1000), texts: [block("t1", "Title", x: 0.1, y: 0.1)])
        let first = Layer(name: "A", content: .text(TextElement(text: "A", center: PSPoint(x: 0.5, y: 0.3))))
        let second = Layer(name: "B", content: .text(TextElement(text: "B", center: PSPoint(x: 0.5, y: 0.6))))
        let overlaid = map.overlaying([first, second])
        XCTAssertEqual(overlaid.texts.compactMap { $0.isLayer ? $0.id : nil }, ["l1", "l2"])
        // Overlaid again after A was deleted: B stays l2.
        XCTAssertEqual(overlaid.overlaying([second]).block(.layer(2))?.layerID, second.id)
        XCTAssertNil(overlaid.overlaying([second]).block(.layer(1)))
        // The raw map overlaid afresh numbers from 1; carrying the ids over restores l2.
        let fresh = map.overlaying([second]).carryingIDs(from: overlaid)
        XCTAssertEqual(fresh.block(.layer(2))?.layerID, second.id)
        let third = Layer(name: "C", content: .text(TextElement(text: "C")))
        XCTAssertEqual(overlaid.overlaying([first, second, third]).block(.layer(3))?.layerID, third.id)
    }
}
