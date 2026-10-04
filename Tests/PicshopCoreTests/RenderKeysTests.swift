import XCTest
@testable import PicshopCore

/// D12 content-hash keys: a dial drag keeps every operation key, reordering two crops changes the later keys only,
/// visibility and placement reach the document and composite keys but not the content key, and every key is a
/// stable FNV-1a hash (no Hasher), equal across runs.
final class RenderKeysTests: XCTestCase {
    private typealias W3 = W3Documents

    private func op(_ n: Int, _ kind: EditOperation.Kind) -> EditOperation {
        EditOperation(id: W3.id(n), kind: kind, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testADialDragKeepsEveryOperationKey() {
        var edits = EditStack(operations: [op(1, .crop(PSRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))), op(2, .adjust(.exposure, value: 0.2)),
                                           op(3, .rotate(degrees: 90)), op(4, .toneCurve(.sCurve(strength: 0.3))), op(5, .denoise(amount: 0.4))])
        let before = RenderKeys.operationKeys(source: W3.asset, edits: edits)
        XCTAssertEqual(Set(before.keys), [W3.id(1), W3.id(3), W3.id(5)], "tonal kinds get no key")
        edits.operations[1] = op(2, .adjust(.exposure, value: 0.9))
        edits.operations[3] = op(4, .toneCurve(.sCurve(strength: 0.8)))
        edits.operations.append(op(6, .localAdjust(LocalAdjustment(stack: W3.stack))))
        XCTAssertEqual(RenderKeys.operationKeys(source: W3.asset, edits: edits), before)
        // The develop recipe moved, so the layer's content key did change.
        var layer = W3.image(7, "Tasse")
        layer.edits = EditStack(operations: Array(edits.operations.prefix(5)))
        let dragged = RenderKeys.layerContentKey(layer)
        layer.edits.operations[1] = op(2, .adjust(.exposure, value: 0.1))
        XCTAssertNotEqual(RenderKeys.layerContentKey(layer), dragged)
    }

    func testReorderingTwoCropsChangesTheLaterKeysOnly() {
        let first = op(1, .rotate(degrees: 90)), cropA = op(2, .crop(PSRect(x: 0.1, y: 0, width: 0.8, height: 1))),
            cropB = op(3, .crop(PSRect(x: 0, y: 0.2, width: 1, height: 0.6))), last = op(4, .upscale(factor: 2))
        let before = RenderKeys.operationKeys(source: W3.asset, edits: EditStack(operations: [first, cropA, cropB, last]))
        let after = RenderKeys.operationKeys(source: W3.asset, edits: EditStack(operations: [first, cropB, cropA, last]))
        XCTAssertEqual(before[first.id], after[first.id])
        XCTAssertNotEqual(before[cropA.id], after[cropA.id])
        XCTAssertNotEqual(before[cropB.id], after[cropB.id])
        XCTAssertNotEqual(before[last.id], after[last.id])
        // Another source changes them all; the operation's own id, label and date change none.
        let other = MediaAsset(kind: .image, relativePath: "media/other.heic", pixelSize: W3.asset.pixelSize)
        XCTAssertNotEqual(RenderKeys.operationKeys(source: other, edits: EditStack(operations: [first]))[first.id], before[first.id])
        let relabelled = EditOperation(id: W3.id(9), kind: first.kind, createdAt: Date(), label: "Pivoter")
        XCTAssertEqual(RenderKeys.operationKeys(source: W3.asset, edits: EditStack(operations: [relabelled]))[relabelled.id], before[first.id])
    }

    func testVisibilityAndPlacementReachTheDocumentButNotTheContent() throws {
        var document = W3.everything
        let text = W3.id(1005)
        let layer = try XCTUnwrap(document.layer(id: text))
        let content = RenderKeys.layerContentKey(layer)
        let composite = RenderKeys.layerCompositeKey(layer)
        let key = RenderKeys.documentKey(document)
        // Toggling visibility.
        document.applyLayerEdit(.visible(false), to: text)
        XCTAssertNotEqual(RenderKeys.documentKey(document), key)
        XCTAssertEqual(RenderKeys.layerContentKey(document.layer(id: text)!), content)
        document.applyLayerEdit(.visible(true), to: text)
        XCTAssertEqual(RenderKeys.documentKey(document), key)
        // Moving the text (its element's centre): the composite key changes, the content key does not.
        document.applyLayerEdit(.transform(LayerTransform(center: PSPoint(x: 0.2, y: 0.8))), to: text)
        let moved = try XCTUnwrap(document.layer(id: text))
        XCTAssertEqual(RenderKeys.layerContentKey(moved), content)
        XCTAssertNotEqual(RenderKeys.layerCompositeKey(moved), composite)
        XCTAssertNotEqual(RenderKeys.documentKey(document), key)
        // Opacity, name and ref number: opacity is in the composite key only; name and number in none.
        var renamed = moved
        renamed.name = "Autre"
        renamed.refNumber = 42
        XCTAssertEqual(RenderKeys.layerCompositeKey(renamed), RenderKeys.layerCompositeKey(moved))
        renamed.opacity = 0.3
        XCTAssertEqual(RenderKeys.layerContentKey(renamed), content)
        XCTAssertNotEqual(RenderKeys.layerCompositeKey(renamed), RenderKeys.layerCompositeKey(moved))
        // A mask edit reaches the content key.
        var masked = moved
        masked.maskStack = W3.stack
        XCTAssertNotEqual(RenderKeys.layerContentKey(masked), content)
    }

    func testBelowKeysAndStructure() {
        let document = W3.everything
        // Below the base nothing; below the top layer, everything else drawn.
        let empty = RenderKeys.belowKey(document, layerID: document.baseLayerID!)
        XCTAssertEqual(empty, RenderKeys.belowKey(W3.groupsIsolated, layerID: W3.groupsIsolated.baseLayerID!))
        // The text sits below the group: a change inside the group is above it, a change of the text is below the group.
        var changedAbove = document
        changedAbove.applyLayerEdit(.opacity(0.1), to: W3.id(1002))
        XCTAssertEqual(RenderKeys.belowKey(changedAbove, layerID: W3.id(1005)), RenderKeys.belowKey(document, layerID: W3.id(1005)))
        XCTAssertEqual(RenderKeys.belowKey(changedAbove, layerID: W3.id(1002)), RenderKeys.belowKey(document, layerID: W3.id(1006)),
                       "a child's below key is its group's top-level node's")
        var changedBelow = document
        changedBelow.applyLayerEdit(.opacity(0.1), to: W3.id(1005))
        XCTAssertNotEqual(RenderKeys.belowKey(changedBelow, layerID: W3.id(1006)), RenderKeys.belowKey(document, layerID: W3.id(1006)))
        // A group switched to pass-through changes the document key (the structure is in it).
        var through = document
        through.applyLayerEdit(.folder(LayerFolder(passThrough: true)), to: W3.id(1006))
        XCTAssertNotEqual(RenderKeys.documentKey(through), RenderKeys.documentKey(document))
    }

    func testKeysAreStableHashesEqualAcrossRuns() {
        // FNV-1a 64 of "abc" is e71fa2190541574b: no per-process seed.
        XCTAssertEqual(StableHash.hex("abc"), "e71fa2190541574b")
        XCTAssertEqual(RenderKeys.kindKey(.rotate(degrees: 90)), StableHash.hex(bytes: Data(#"{"rotate":{"degrees":90}}"#.utf8)))
        // Two documents built separately give the same keys.
        let a = W3.everything, b = W3.everything
        XCTAssertEqual(RenderKeys.documentKey(a), RenderKeys.documentKey(b))
        for (x, y) in zip(a.layers, b.layers) {
            XCTAssertEqual(RenderKeys.layerContentKey(x), RenderKeys.layerContentKey(y))
            XCTAssertEqual(RenderKeys.layerCompositeKey(x), RenderKeys.layerCompositeKey(y))
        }
        XCTAssertEqual(RenderKeys.documentKey(a).count, 16)
    }
}
