import XCTest
@testable import PicshopCore

/// D7: the lock table (7 mutations × 5 lock states), the edits each mutation stands for, and the document refusing a
/// locked layer through every entry point (apply, removeLayer, moveLayer, layer edits, structure edits).
final class LayerLockTests: XCTestCase {
    private typealias W3 = W3Documents

    /// The five lock states and, for each, the mutations it refuses (D7's table written out by hand).
    static let table: [(name: String, lock: LayerLockOptions, refused: Set<LayerMutation>)] = [
        ("none", [], []),
        ("transparency", [.transparency], [.alpha]),
        ("pixels", [.pixels], [.content, .alpha]),
        ("position", [.position], [.placement]),
        ("all", .all, Set(LayerMutation.allCases)),
    ]

    func testTheTable() {
        XCTAssertEqual(LayerMutation.allCases.count, 7)
        for row in Self.table {
            for mutation in LayerMutation.allCases {
                XCTAssertEqual(LayerLockPolicy.allows(mutation, lock: row.lock), !row.refused.contains(mutation), "\(row.name) \(mutation)")
            }
        }
        // Unknown bits from a newer build lock nothing on their own.
        XCTAssertTrue(LayerMutation.allCases.allSatisfy { LayerLockPolicy.allows($0, lock: LayerLockOptions(rawValue: 64)) })
    }

    func testTheMutationOfEachEdit() {
        let cases: [(LayerEdit, LayerMutation?)] = [
            (.opacity(0.5), .properties), (.fillOpacity(0.5), .properties), (.blendMode(.multiply), .properties), (.clipped(true), .properties),
            (.folder(LayerFolder()), .properties), (.transform(.identity), .placement), (.maskStack(nil), .mask),
            (.maskEdit(.removeComponent(UUID())), .mask), (.maskEnabled(false), .mask), (.maskLinked(false), .mask),
            (.solidFill(.red), .content), (.gradient(.blackToTransparent), .content), (.adjustments(.neutral), .content),
            (.visible(false), nil), (.lock([]), nil), (.lockAll(true), nil), (.rename("x"), nil), (.recipeKind(.curves), nil),
        ]
        for (edit, mutation) in cases { XCTAssertEqual(LayerLockPolicy.mutation(for: edit), mutation, "\(edit)") }
        XCTAssertEqual(LayerLockPolicy.mutation(for: .removeBackground(nil)), .alpha)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .expand(PSRect(x: 0, y: 0, width: 1, height: 1))), .alpha)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .replaceBackground(.transparent, mask: nil)), .alpha)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .replaceBackground(.solid(.white), mask: nil)), .content)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .adjust(.exposure, value: 0.2)), .content)
        XCTAssertEqual(LayerLockPolicy.mutation(for: .crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5))), .content)
    }

    func testIsLockedIsAllAndAMissingLayerAllowsNothing() {
        var document = W3.base(70, title: "lock")
        let layer = W3.image(7002, "Tasse")
        document.layers.append(layer)
        document.update(layerID: layer.id) { $0.isLocked = true }
        XCTAssertEqual(document.effectiveLock(of: layer.id), .all)
        XCTAssertFalse(LayerLockPolicy.allows(.properties, on: layer.id, in: document))
        XCTAssertFalse(LayerLockPolicy.allows(.properties, on: W3.id(7099), in: document))
    }

    func testTheDocumentRefusesALockedLayerEverywhere() {
        var document = W3.base(71, title: "lock")
        let locked = W3.image(7102, "Tasse")
        document.layers += [locked, W3.text(7103, "Haut")]
        let local = LocalAdjustment(id: W3.id(7180), stack: W3.stack, adjustments: Adjustments([.exposure: 0.2]))
        document.setLocalAdjustment(local, on: locked.id)
        XCTAssertEqual(document.localAdjustments(on: locked.id).map(\.id), [local.id])
        document.update(layerID: locked.id) { $0.isLocked = true }
        let before = document
        XCTAssertFalse(document.apply(.adjust(.exposure, value: 0.3), to: locked.id))
        XCTAssertNil(document.removeLayer(id: locked.id))
        XCTAssertFalse(document.moveLayer(id: locked.id, to: 2))
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.2), to: locked.id), .refused(.locked))
        XCTAssertEqual(document.applyStructureEdit(.remove(locked.id)).outcome, .refused(.locked))
        XCTAssertEqual(document.applyStructureEdit(.move(locked.id, to: .top)).outcome, .refused(.locked))
        XCTAssertEqual(document.applyStructureEdit(.group([locked.id], name: nil)).outcome, .refused(.locked))
        XCTAssertEqual(document.applyStructureEdit(.applyMask(locked.id, raster: W3.cup)).outcome, .refused(.locked))
        XCTAssertEqual(document.applyLocalEdit(.setStack(feather: 0.2, expand: nil, density: nil, isInverted: nil), to: local.id, on: locked.id), false)
        XCTAssertEqual(document, before, "nothing changed")
        // Visibility, rename and the lock itself are never refused.
        XCTAssertEqual(document.applyLayerEdit(.visible(false), to: locked.id), .applied)
        XCTAssertEqual(document.applyLayerEdit(.rename("Verrou"), to: locked.id), .applied)
        XCTAssertEqual(document.applyLayerEdit(.lockAll(false), to: locked.id), .applied)
        XCTAssertTrue(document.apply(.adjust(.exposure, value: 0.3), to: locked.id))
    }

    func testAPositionLockedSubjectStillTakesItsPixels() {
        var document = W3.base(72, title: "subject")
        let subject = Layer(id: W3.id(7202), name: PhotoDocument.subjectLayerName, content: .image(W3.cup), lockOptions: [.position])
        document.layers.append(subject)
        XCTAssertTrue(document.apply(.adjust(.contrast, value: 0.2), to: subject.id))
        XCTAssertEqual(document.applyLayerEdit(.transform(LayerTransform(scale: 0.3)), to: subject.id), .refused(.locked))
        XCTAssertEqual(document.applyLayerEdit(.opacity(0.4), to: subject.id), .applied)
    }
}
