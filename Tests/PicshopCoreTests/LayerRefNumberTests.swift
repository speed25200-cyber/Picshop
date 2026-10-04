import XCTest
@testable import PicshopCore

/// D19: ref numbers are given at creation and never change through reorder, deleting another layer, grouping, merge
/// down (the lower layer keeps its number) and undo; `migrated` gives W2's positional numbering.
final class LayerRefNumberTests: XCTestCase {
    private typealias W3 = W3Documents

    private func refs(_ document: PhotoDocument) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for layer in document.layers {
            if let prefix = layer.refPrefix, let number = layer.refNumber { result[layer.id] = "\(prefix)\(number)" }
        }
        return result
    }

    /// The W2 resolver (PhotoOperationHandlers.layer(ref:) at e043f81, without the scene map), written out.
    private func w2Layer(_ ref: String, in document: PhotoDocument) -> Layer? {
        guard let kind = ref.first, let number = Int(ref.dropFirst()), number >= 1 else { return nil }
        switch kind {
        case "l":
            let free = document.layers.filter { $0.group == nil && $0.textElement != nil }
            let shown = free.filter(\.isVisible)
            if number <= shown.count { return shown[number - 1] }
            return number <= free.count ? free[number - 1] : nil
        case "s":
            let shapes = document.layers.filter(\.isShape)
            return number <= shapes.count ? shapes[number - 1] : nil
        case "i":
            let images = document.layers.filter { $0.isImage && $0.id != document.baseLayerID }
            return number <= images.count ? images[number - 1] : nil
        default:
            return nil
        }
    }

    private var sample: PhotoDocument {
        var document = W3.base(98, title: "refs")
        document.layers += [W3.image(9802, "Tasse"), W3.text(9803, "Titre"), W3.image(9804, "Logo", W3.logo),
                            Layer(id: W3.id(9805), name: "Forme", content: .shape(ShapeElement(kind: .ellipse))),
                            W3.text(9806, "Prix"), Layer(id: W3.id(9807), name: "Lumière", content: .adjustment(.neutral), recipeKind: .light)]
        return DocumentCodec.migrated(document)
    }

    func testMigrationGivesTheW2PositionalNumbers() throws {
        let document = sample
        XCTAssertEqual(refs(document)[document.baseLayerID!], "i0")
        XCTAssertEqual(refs(document)[W3.id(9802)], "i1")
        XCTAssertEqual(refs(document)[W3.id(9804)], "i2")
        XCTAssertEqual(refs(document)[W3.id(9803)], "l1")
        XCTAssertEqual(refs(document)[W3.id(9806)], "l2")
        XCTAssertEqual(refs(document)[W3.id(9805)], "s1")
        XCTAssertEqual(refs(document)[W3.id(9807)], "j1")
        // Every W2 ref of every W1/W2 document resolves to the same layer under both numberings.
        for original in try W2Documents.decoded() + W2Documents.built() + [sample] {
            let migrated = DocumentCodec.migrated(original)
            for layer in migrated.layers where layer.id != migrated.baseLayerID && layer.group == nil {
                guard let prefix = layer.refPrefix, "ils".contains(prefix), let number = layer.refNumber else { continue }
                XCTAssertEqual(w2Layer("\(prefix)\(number)", in: migrated)?.id, layer.id, "\(prefix)\(number) in \(original.title)")
            }
            XCTAssertEqual(migrated.positionalRefNumbers, Dictionary(uniqueKeysWithValues: migrated.layers.compactMap { layer in
                layer.refNumber.map { (layer.id, $0) }
            }))
        }
    }

    func testNumbersNeverChange() throws {
        var document = sample
        let start = refs(document)
        // Reorder.
        XCTAssertEqual(document.applyStructureEdit(.move(W3.id(9802), to: .top)).outcome, .applied)
        XCTAssertTrue(document.moveLayer(id: W3.id(9805), to: 1))
        XCTAssertEqual(refs(document), start)
        // Delete another layer: nobody renumbers, the gap stays.
        XCTAssertEqual(document.applyStructureEdit(.remove(W3.id(9803))).outcome, .applied)
        var expected = start
        expected[W3.id(9803)] = nil
        XCTAssertEqual(refs(document), expected)
        // Group: the members keep theirs, the group takes g1.
        let grouped = document.applyStructureEdit(.group([W3.id(9804), W3.id(9806)], name: nil))
        let groupID = try XCTUnwrap(grouped.layerID)
        expected[groupID] = "g1"
        XCTAssertEqual(refs(document), expected)
        // A new image takes the next number after the highest (i3), not the lowest free one.
        let added = document.applyStructureEdit(.addImage(W3.cup, name: "Nouveau", fit: .fit, placement: .top))
        let addedID = try XCTUnwrap(added.layerID)
        XCTAssertEqual(refs(document)[addedID], "i3")
        expected[addedID] = "i3"
        // Merge down onto « Tasse » (i1, right below): it keeps i1, the merged layer's i3 is gone.
        let merged = document.applyStructureEdit(.mergeDown(addedID, raster: W3.cup))
        XCTAssertEqual(merged.layerID, W3.id(9802))
        expected[addedID] = nil
        XCTAssertEqual(refs(document), expected)
        // Undo is a snapshot: the numbers come back as they were, and the next new image still takes i4.
        let snapshot = document
        document.applyStructureEdit(.remove(W3.id(9802)))
        document = snapshot
        XCTAssertEqual(refs(document), expected)
        let again = document.applyStructureEdit(.addImage(W3.logo, name: "Encore", fit: .fit, placement: .top))
        XCTAssertEqual(again.layerID.flatMap { refs(document)[$0] }, "i3", "i3 was merged away and no higher image number exists")
    }

    func testMergeDownKeepsTheLowerNumberAndCopiesGetNewOnes() throws {
        var document = sample
        let lower = W3.id(9804)
        // The shape sits right above the logo: merged down, the logo keeps i2 (a move there changes nothing).
        XCTAssertEqual(document.applyStructureEdit(.move(W3.id(9805), to: .above(lower))).outcome, .unchanged)
        XCTAssertEqual(document.applyStructureEdit(.mergeDown(W3.id(9805), raster: W3.logo)).layerID, lower)
        XCTAssertEqual(refs(document)[lower], "i2")
        // Duplicate, via copy, stamp: new numbers.
        let duplicate = try XCTUnwrap(document.applyStructureEdit(.duplicate(lower)).layerID)
        XCTAssertEqual(refs(document)[duplicate], "i3")
        let via = try XCTUnwrap(document.applyStructureEdit(.viaCopy(source: lower, region: W3.stack, name: nil)).layerID)
        XCTAssertEqual(refs(document)[via], "i4")
        let stamp = try XCTUnwrap(document.applyStructureEdit(.stamp(raster: W3.cup, name: "Tampon")).layerID)
        XCTAssertEqual(refs(document)[stamp], "i5")
        let fill = Layer(name: "Couleur", content: .fill(.red))
        XCTAssertEqual(document.applyStructureEdit(.add(fill, placement: .top)).outcome, .applied)
        XCTAssertEqual(refs(document)[fill.id], "j2")
        // Plain decoding never assigns numbers.
        var bare = W3.base(99, title: "bare")
        bare.layers.append(W3.image(9902, "Tasse"))
        let decoded = try W3.reloaded(bare)
        XCTAssertTrue(decoded.layers.allSatisfy { $0.refNumber == nil })
    }
}
