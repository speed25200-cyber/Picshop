import XCTest
@testable import PicshopCore

/// D1, D5, D7: the normalisation's invariants on scrambled layouts, the clipping base rules and the effective lock.
final class LayerTreeTests: XCTestCase {
    private typealias W3 = W3Documents

    /// A scrambled layout: the base somewhere, three groups (one nested in another), children anywhere, parents that
    /// name missing layers, a non-group or the layer itself.
    private func scrambled(seed: UInt64) -> [Layer] {
        var random = MaskTestRandom(seed: seed)
        var base = W3.image(1, "Photo", W3.asset, transform: .identity)
        base.parentID = W3.id(50)
        base.isClipped = true
        var layers = [base]
        let groups = [W3.id(50), W3.id(51), W3.id(52)]
        for (offset, id) in groups.enumerated() {
            var group = Layer(id: id, name: "Groupe \(offset + 1)", content: .group(LayerFolder()), fillOpacity: 0.4)
            if offset == 2 { group.parentID = groups[0] }
            layers.append(group)
        }
        let candidates: [UUID?] = [nil, nil, groups[0], groups[1], groups[2], W3.id(999), W3.id(10)]
        for n in 10..<22 {
            var layer = n % 3 == 0 ? W3.text(n, "T\(n)") : W3.image(n, "I\(n)")
            layer.parentID = candidates[Int(random.next() % UInt64(candidates.count))]
            if n == 15 { layer.parentID = layer.id }
            layers.append(layer)
        }
        layers.shuffle(using: &random)
        // The base is the first image layer wherever it sits (groups and texts may come before it).
        let photo = layers.remove(at: layers.firstIndex { $0.id == base.id }!)
        layers.insert(photo, at: layers.firstIndex(where: \.isImage) ?? layers.count)
        return layers
    }

    func testTwelveScrambledLayoutsNormalise() {
        for seed in 1...12 {
            let input = scrambled(seed: UInt64(seed))
            var document = W3.base(60, title: "tree")
            document.layers = input
            document.normalizeLayerTree()
            let output = document.layers
            let message = "seed \(seed)"
            // Nothing lost or added, the base first and never grouped or clipped.
            XCTAssertEqual(Set(output.map(\.id)), Set(input.map(\.id)), message)
            XCTAssertEqual(output[0].id, W3.id(1), message)
            XCTAssertNil(output[0].parentID, message)
            XCTAssertFalse(output[0].isClipped, message)
            let groupIDs = Set(output.filter(\.isGroup).map(\.id))
            for (index, layer) in output.enumerated() {
                if layer.isGroup {
                    // One level: a group has no parent, fill 1, and its children are the run directly below it.
                    XCTAssertNil(layer.parentID, message)
                    XCTAssertEqual(layer.fillOpacity, 1, message)
                    let children = output.filter { $0.parentID == layer.id }
                    XCTAssertEqual(Array(output[(index - children.count)..<index].map(\.id)), children.map(\.id), message)
                } else if let parentID = layer.parentID {
                    XCTAssertTrue(groupIDs.contains(parentID), message)
                    XCTAssertNotEqual(parentID, layer.id, message)
                }
            }
            // Order kept: the top-level layers in their input order, each group's children too.
            let topLevel = output.filter { $0.parentID == nil }.map(\.id)
            let inputOrder = input.map(\.id)
            XCTAssertEqual(Array(topLevel.dropFirst()), inputOrder.filter { topLevel.dropFirst().contains($0) }, message)
            for group in groupIDs {
                let children = output.filter { $0.parentID == group }.map(\.id)
                XCTAssertEqual(children, inputOrder.filter(children.contains), message)
            }
            // The nested group came out to the top level with its children.
            XCTAssertNil(document.layer(id: W3.id(52))?.parentID, message)
            XCTAssertTrue(document.isNormalizedLayerTree, message)
            // Idempotent.
            var again = document
            again.normalizeLayerTree()
            XCTAssertEqual(again.layers, output, message)
        }
    }

    func testNormalisationLeavesANormalisedDocumentAlone() {
        for (name, document) in W3.all {
            XCTAssertTrue(document.isNormalizedLayerTree, name)
            var copy = document
            copy.normalizeLayerTree()
            XCTAssertEqual(copy, document, name)
            XCTAssertEqual(copy.modifiedAt, document.modifiedAt, name)
        }
    }

    func testClippingBases() throws {
        let document = W3.clipping
        // Onto an image: the shadow and the text over it.
        XCTAssertEqual(document.clippingBase(of: W3.id(303))?.id, W3.id(302))
        XCTAssertEqual(document.clippingBase(of: W3.id(304))?.id, W3.id(302))
        XCTAssertEqual(document.clippedLayers(onto: W3.id(302)).map(\.id), [W3.id(303), W3.id(304)])
        // At the bottom of a group: no sibling below, no base.
        var bottom = document
        bottom.update(layerID: W3.id(305)) { $0.isClipped = true }
        XCTAssertNil(bottom.clippingBase(of: W3.id(305)))
        XCTAssertEqual(bottom.clippedLayers(onto: W3.id(306)).map(\.id), [W3.id(307)])
        // Above a group: the group is the base, its children are skipped.
        XCTAssertEqual(document.clippingBase(of: W3.id(307))?.id, W3.id(306))
        XCTAssertEqual(document.clippedLayers(onto: W3.id(306)).map(\.id), [W3.id(307)])
        // Over an adjustment layer: invalid.
        XCTAssertNil(document.clippingBase(of: W3.id(309)))
        XCTAssertEqual(document.clippedLayers(onto: W3.id(308)), [])
        // An unclipped layer has no base; neither has the base photo.
        XCTAssertNil(document.clippingBase(of: W3.id(305)))
        XCTAssertNil(document.clippingBase(of: W3.id(301)))
        XCTAssertEqual(document.clippedLayers(onto: W3.id(303)), [], "a clipped layer is no base")
        // A group's own clip flag is kept and ignored: it stays a base.
        var flagged = document
        flagged.update(layerID: W3.id(306)) { $0.isClipped = true }
        XCTAssertNil(flagged.clippingBase(of: W3.id(306)))
        XCTAssertEqual(flagged.clippingBase(of: W3.id(307))?.id, W3.id(306))
        // A newer build's content is no base either.
        var newer = W3.base(61, title: "newer")
        newer.layers += [Layer(id: W3.id(6102), name: "Objet", content: .unsupported(#"{"x":{}}"#)),
                         Layer(id: W3.id(6103), name: "Teinte", content: .fill(.red), isClipped: true)]
        XCTAssertNil(newer.clippingBase(of: W3.id(6103)))
    }

    func testEffectiveLockIsOwnUnionParents() {
        let document = W3.fillAndLocks
        XCTAssertEqual(document.effectiveLock(of: W3.id(403)), [.position])
        XCTAssertEqual(document.effectiveLock(of: W3.id(404)), [.pixels, .transparency])
        // The locked group locks its child entirely.
        XCTAssertEqual(document.effectiveLock(of: W3.id(405)), .all)
        XCTAssertEqual(document.effectiveLock(of: W3.id(406)), .all)
        XCTAssertEqual(document.effectiveLock(of: W3.id(402)), [])
        // A partial group lock adds to the child's own.
        var partial = W3.everything
        partial.update(layerID: W3.id(1002)) { $0.lockOptions = [.transparency] }
        XCTAssertEqual(partial.effectiveLock(of: W3.id(1002)), [.transparency, .position])
        XCTAssertEqual(partial.effectiveLock(of: W3.id(1005)), [])
        XCTAssertEqual(document.effectiveLock(of: W3.id(9999)), [])
    }

    func testParentChildrenAndUnits() {
        let document = W3.refsAndBundles
        XCTAssertEqual(document.children(of: W3.id(920)).map(\.id), (0..<6).map { W3.id(910 + $0) })
        XCTAssertEqual(document.parent(of: W3.id(912))?.id, W3.id(920))
        XCTAssertNil(document.parent(of: W3.id(902)))
        XCTAssertEqual(document.children(of: W3.id(902)), [], "not a group")
        // Base, two images, one bundle, one group.
        XCTAssertEqual(document.layerUnitCount, 5)
        XCTAssertEqual(document.bundles.count, 1)
        XCTAssertEqual(document.bundle(containing: W3.id(913))?.memberIDs.count, 6)
        XCTAssertNil(document.bundle(containing: W3.id(902)))
    }

    func testToneTargets() {
        var document = W3.gradientsAndAdjustments
        let curves = document.layers.first { $0.recipeKind == .curves }!.id
        let light = document.layers.first { $0.recipeKind == .light }!.id
        document.selectedLayerID = curves
        XCTAssertEqual(document.toneTarget(for: OpID("curves")), curves)
        XCTAssertEqual(document.toneTarget(for: OpID("autoTone")), curves)
        XCTAssertEqual(document.toneTarget(for: OpID("adjust")), document.activeImageLayerID, "adjust does not land on a Courbes layer")
        document.selectedLayerID = light
        XCTAssertEqual(document.toneTarget(for: OpID("adjust")), light)
        XCTAssertEqual(document.toneTarget(for: OpID("matchColor")), document.activeImageLayerID)
        // A W2 adjustment layer (no kind) counts as « Lumière ».
        var w2 = W3.base(62, title: "w2")
        w2.layers.append(Layer(id: W3.id(6202), name: "Réglage", content: .adjustment(.neutral)))
        w2.selectedLayerID = W3.id(6202)
        XCTAssertEqual(w2.toneTarget(for: OpID("adjust")), W3.id(6202))
        XCTAssertEqual(w2.toneTarget(for: OpID("curves")), w2.activeImageLayerID)
    }
}
