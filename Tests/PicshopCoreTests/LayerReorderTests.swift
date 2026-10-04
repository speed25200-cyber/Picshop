import XCTest
@testable import PicshopCore

/// D17 rows and drops: a drop into a group sets the parent, a group never goes into a group, the base slot is
/// refused, a clip base moves with its run, a collapsed group's children are skipped, a bundle is one row.
final class LayerReorderTests: XCTestCase {
    private typealias W3 = W3Documents

    private func apply(_ spec: LayerPlacementSpec?, _ dragged: UUID, to document: inout PhotoDocument,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let placement = try XCTUnwrap(spec, "a drop that should land", file: file, line: line)
        XCTAssertEqual(document.applyStructureEdit(.move(dragged, to: placement)).outcome, .applied, file: file, line: line)
    }

    func testRowsTopToBottom() {
        let document = W3.groupsIsolated
        let rows = LayerReorder.rows(for: document)
        XCTAssertEqual(rows.map(\.id), [W3.id(104), W3.id(103), W3.id(102), W3.id(101)])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(rows.map(\.isGroup), [true, false, false, false])
        XCTAssertTrue(rows.allSatisfy { !$0.isCollapsedChild && $0.bundleCount == nil })
        // A bundle is one row at its topmost member, with its size.
        let bundled = LayerReorder.rows(for: W3.refsAndBundles)
        XCTAssertEqual(bundled.count, 5)
        XCTAssertEqual(bundled[1].id, W3.id(915))
        XCTAssertEqual(bundled[1].bundleCount, 6)
        XCTAssertEqual(bundled[1].depth, 1)
    }

    func testADropIntoAGroupSetsTheParent() throws {
        var document = W3.groupsIsolated
        let title = W3.text(105, "Titre")
        XCTAssertEqual(document.applyStructureEdit(.add(title, placement: .top)).outcome, .applied)
        // Rows: Titre, Groupe 1, Tasse, Logo, Photo. Slot 3 is above « Logo », inside the group.
        let spec = LayerReorder.drop(title.id, atRowSlot: 3, in: document)
        XCTAssertEqual(spec, .above(W3.id(102)))
        try apply(spec, title.id, to: &document)
        XCTAssertEqual(document.layer(id: title.id)?.parentID, W3.id(104))
        XCTAssertEqual(document.children(of: W3.id(104)).map(\.id), [W3.id(102), title.id, W3.id(103)])
        // And out again to the top.
        try apply(LayerReorder.drop(title.id, atRowSlot: 0, in: document), title.id, to: &document)
        XCTAssertNil(document.layer(id: title.id)?.parentID)
        // Right under an expanded empty group's row: into it.
        var empty = W3.layerMasks
        let group = W3.id(607)
        let rows = LayerReorder.rows(for: empty)
        let slot = try XCTUnwrap(rows.firstIndex { $0.id == group }) + 1
        let dragged = W3.id(602)
        let into = LayerReorder.drop(dragged, atRowSlot: slot, in: empty)
        XCTAssertEqual(into, .into(groupID: group))
        try apply(into, dragged, to: &empty)
        XCTAssertEqual(empty.layer(id: dragged)?.parentID, group)
    }

    func testAGroupIntoAGroupIsRefused() {
        var document = W3.groupsIsolated
        document.applyStructureEdit(.add(W3.text(111, "Seul"), placement: .top))
        document.applyStructureEdit(.group([W3.id(111)], name: nil))
        let rows = LayerReorder.rows(for: document)
        let groupID = rows[0].id
        XCTAssertTrue(document.layer(id: groupID)?.isGroup == true)
        // Dragging the new group above « Tasse » (a child of « Groupe 1 »): refused.
        let slot = rows.firstIndex { $0.id == W3.id(103) }!
        XCTAssertNil(LayerReorder.drop(groupID, atRowSlot: slot, in: document))
        // Above « Groupe 1 »'s row is fine (top level).
        let above = rows.firstIndex { $0.id == W3.id(104) }!
        XCTAssertEqual(LayerReorder.drop(groupID, atRowSlot: above, in: document), nil, "its own place: nothing moves")
        XCTAssertNotNil(LayerReorder.drop(W3.id(104), atRowSlot: 0, in: document))
    }

    func testTheBaseSlotAndTheBaseAreRefused() {
        let document = W3.clipping
        let rows = LayerReorder.rows(for: document).filter { !$0.isCollapsedChild }
        XCTAssertEqual(rows.last?.id, document.baseLayerID)
        XCTAssertNil(LayerReorder.drop(W3.id(309), atRowSlot: rows.count, in: document), "under the base photo")
        XCTAssertNil(LayerReorder.drop(document.baseLayerID!, atRowSlot: 0, in: document), "the base photo itself")
        XCTAssertNil(LayerReorder.drop(W3.id(309), atRowSlot: rows.count + 1, in: document))
        XCTAssertNil(LayerReorder.drop(W3.id(309), atRowSlot: -1, in: document))
        XCTAssertNotNil(LayerReorder.drop(W3.id(309), atRowSlot: rows.count - 1, in: document), "just above the base")
    }

    func testAClipBaseMovesWithItsRun() throws {
        var document = W3.clipping
        let base = W3.id(302)
        XCTAssertEqual(document.clippedLayers(onto: base).map(\.id), [W3.id(303), W3.id(304)])
        try apply(LayerReorder.drop(base, atRowSlot: 0, in: document), base, to: &document)
        let order = document.layers.map(\.id)
        XCTAssertEqual(Array(order.suffix(3)), [base, W3.id(303), W3.id(304)])
        XCTAssertEqual(document.clippedLayers(onto: base).map(\.id), [W3.id(303), W3.id(304)])
        XCTAssertTrue(document.isNormalizedLayerTree)
        // Dropping inside its own run changes nothing.
        let rows = LayerReorder.rows(for: document)
        let own = rows.firstIndex { $0.id == W3.id(303) }!
        XCTAssertNil(LayerReorder.drop(base, atRowSlot: own, in: document))
    }

    func testACollapsedGroupsChildrenAreSkipped() throws {
        var document = W3.groupsPassThrough
        document.applyStructureEdit(.add(W3.text(205, "Titre"), placement: .top))
        let rows = LayerReorder.rows(for: document)
        XCTAssertEqual(rows.filter(\.isCollapsedChild).map(\.id), [W3.id(203), W3.id(202)])
        let visible = rows.filter { !$0.isCollapsedChild }
        XCTAssertEqual(visible.map(\.id), [W3.id(205), W3.id(204), document.baseLayerID!])
        // Slot 2 is above the base photo (the collapsed children are not slots): the title lands under the group.
        let spec = LayerReorder.drop(W3.id(205), atRowSlot: 2, in: document)
        XCTAssertEqual(spec, .above(document.baseLayerID!))
        try apply(spec, W3.id(205), to: &document)
        XCTAssertEqual(document.index(of: W3.id(205)), 1)
        XCTAssertNil(document.layer(id: W3.id(205))?.parentID)
        XCTAssertNil(LayerReorder.drop(W3.id(205), atRowSlot: 3, in: document))
    }

    func testAnOrderLockRefusesTheDrop() {
        var document = W3.groupsIsolated
        document.applyStructureEdit(.add(W3.text(105, "Titre"), placement: .top))
        XCTAssertNotNil(LayerReorder.drop(W3.id(104), atRowSlot: 0, in: document))
        document.applyLayerEdit(.lockAll(true), to: W3.id(104))
        XCTAssertNil(LayerReorder.drop(W3.id(102), atRowSlot: 0, in: document), "a child of a locked group")
        XCTAssertNil(LayerReorder.drop(W3.id(104), atRowSlot: 0, in: document), "the locked group")
        XCTAssertNotNil(LayerReorder.drop(W3.id(105), atRowSlot: 4, in: document), "others still move")
    }
}
