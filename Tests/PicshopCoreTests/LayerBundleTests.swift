import XCTest
@testable import PicshopCore

/// D1 table bundles: a 120-cell table fill is one row and one unit toward maxLayers (a fill never refuses), and the
/// row's visibility, opacity, blend, move, duplicate and delete act on every cell in one step.
final class LayerBundleTests: XCTestCase {
    private typealias W3 = W3Documents

    /// The base, `singles` fill layers, then a 12 × 10 table filled through the W1 path (`addLayer`, no cap).
    private func table(singles: Int) -> (document: PhotoDocument, bundle: UUID, cells: [UUID]) {
        var document = W3.base(97, title: "table")
        for n in 0..<singles { document.addLayer(Layer(name: "F\(n)", content: .fill(.black)), select: false) }
        let bundle = UUID()
        var cells: [UUID] = []
        for row in 1...12 {
            for column in 1...10 {
                var layer = Layer(name: "\(row)·\(column)", content: .text(TextElement(text: "\(row * column)",
                                                                                   center: PSPoint(x: Double(column) / 11, y: Double(row) / 13))))
                layer.group = LayerGroup(id: bundle, kind: .tableCells, row: row, column: column)
                document.addLayer(layer, select: false)
                cells.append(layer.id)
            }
        }
        return (document, bundle, cells)
    }

    func testA120CellTableIsOneRowAndOneUnitAndAFillNeverRefuses() throws {
        // 62 singles + the base = 63 units: the table is the 64th, all 120 cells go in.
        let (document, bundle, cells) = table(singles: 62)
        XCTAssertEqual(document.layers.count, 1 + 62 + 120)
        XCTAssertEqual(document.layerUnitCount, PhotoDocument.maxLayers)
        XCTAssertEqual(document.bundles.map(\.id), [bundle])
        XCTAssertEqual(document.bundles.first?.memberIDs, cells)
        let rows = LayerReorder.rows(for: document)
        XCTAssertEqual(rows.count, 64)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, cells.last)
        XCTAssertEqual(row.bundleCount, 120)
        // A fill past the cap still lands (W1 path); a structure edit is refused.
        var over = document
        var extra = Layer(name: "Encore", content: .text(TextElement(text: "x")))
        extra.group = LayerGroup(id: UUID(), kind: .tableCells, row: 1, column: 1)
        over.addLayer(extra)
        XCTAssertEqual(over.layerUnitCount, 65)
        var capped = document
        XCTAssertEqual(capped.applyStructureEdit(.add(Layer(name: "Non", content: .fill(.red)), placement: .top)).outcome, .refused(.tooManyLayers))
        // Every cell shares the bundle's ref number.
        XCTAssertEqual(Set(cells.compactMap { document.layer(id: $0)?.refNumber }).count, 1)
        XCTAssertEqual(document.layer(id: cells[0])?.refPrefix, "g")
    }

    func testHidingTheRowHidesEveryCellInOneStep() throws {
        let made = table(singles: 2)
        var document = made.document
        let cells = made.cells
        // One call: every cell hidden.
        XCTAssertEqual(document.applyLayerEdit(.visible(false), to: try XCTUnwrap(cells.last)), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.isVisible == false })
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.6), to: cells[40]), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.opacity == 0.6 })
        XCTAssertEqual(document.applyLayerEdit(.blendMode(.multiply), to: cells[7]), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.blendMode == .multiply })
        // A locked cell refuses the whole row's change.
        document.update(layerID: cells[3]) { $0.isLocked = true }
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.2), to: cells[0]), .refused(.locked))
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.opacity == 0.6 })
        // Visibility is never refused.
        XCTAssertEqual(document.applyLayerEdit(.visible(true), to: cells[0]), .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0)?.isVisible == true })
    }

    func testMoveDuplicateGroupAndDeleteActOnTheWholeBundle() throws {
        let made = table(singles: 2)
        var document = made.document
        let bundle = made.bundle, cells = made.cells
        let firstSingle = document.layers[1].id
        // Move the row under the singles: the cells stay together, in order.
        XCTAssertEqual(document.applyStructureEdit(.move(cells[50], to: .above(document.baseLayerID!))).outcome, .applied)
        XCTAssertEqual(Array(document.layers[1...120].map(\.id)), cells)
        XCTAssertEqual(document.layers[121].id, firstSingle)
        // Duplicate: 120 new cells with a fresh bundle id, one more unit.
        let units = document.layerUnitCount
        let copy = document.applyStructureEdit(.duplicate(cells[0]))
        XCTAssertEqual(copy.outcome, .applied)
        XCTAssertEqual(document.layerUnitCount, units + 1)
        XCTAssertEqual(document.bundles.count, 2)
        let fresh = try XCTUnwrap(document.bundles.first { $0.id != bundle })
        XCTAssertEqual(fresh.memberIDs.count, 120)
        XCTAssertTrue(Set(fresh.memberIDs).isDisjoint(with: cells))
        XCTAssertEqual(document.layer(id: fresh.memberIDs[0])?.name, "1·1", "cells keep their names")
        // Group the row: every cell joins the group.
        let grouped = document.applyStructureEdit(.group([cells[9]], name: "Tableau"))
        let groupID = try XCTUnwrap(grouped.layerID)
        XCTAssertEqual(document.children(of: groupID).map(\.id), cells)
        XCTAssertTrue(document.isNormalizedLayerTree)
        // Delete the group: the row goes with it.
        XCTAssertEqual(document.applyStructureEdit(.remove(groupID)).outcome, .applied)
        XCTAssertTrue(cells.allSatisfy { document.layer(id: $0) == nil })
        // Delete the copy's row by one of its cells.
        XCTAssertEqual(document.applyStructureEdit(.remove(fresh.memberIDs[77])).outcome, .applied)
        XCTAssertTrue(document.bundles.isEmpty)
        XCTAssertEqual(document.layers.count, 3)
    }
}
