import XCTest
@testable import PicshopCore

/// Local adjustments in the edit stack (D2): one operation per id, replaced in place, tonal for every cache key,
/// invisible to the develop recipe's resolved values, and the base layer's in W2.
final class LocalAdjustmentStackTests: XCTestCase {
    private func document(width: Double = 4000, height: Double = 3000) -> PhotoDocument {
        PhotoDocument(title: "Masks", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: width, height: height)))
    }

    private func sky(_ exposure: Double = 0.3) -> LocalAdjustment {
        LocalAdjustment(region: .sky, stack: .single(MaskComponent(.linear(LinearGradientSpec(start: PSPoint(x: 0.5, y: 0), end: PSPoint(x: 0.5, y: 0.5))))),
                        adjustments: Adjustments([.exposure: exposure]))
    }

    func testSettingTwiceKeepsOneOperationInPlace() {
        var stack = EditStack()
        stack.append(.adjust(.contrast, value: 0.1))
        var adjustment = sky()
        stack.setLocalAdjustment(adjustment, label: "Mask: Ciel")
        stack.append(.adjust(.saturation, value: 0.2))
        let operationID = stack.operations[1].id
        adjustment.adjustments[.exposure] = 0.6
        stack.setLocalAdjustment(adjustment)
        XCTAssertEqual(stack.operations.count, 3)
        XCTAssertEqual(stack.operations[1].id, operationID)
        // The label stays unless a new one is given.
        XCTAssertEqual(stack.operations[1].label, "Mask: Ciel")
        XCTAssertEqual(stack.localAdjustment(id: adjustment.id), adjustment)
        stack.setLocalAdjustment(adjustment, label: "Mask: Sky")
        XCTAssertEqual(stack.operations[1].label, "Mask: Sky")
        XCTAssertEqual(stack.resolvedLocalAdjustments, [adjustment])
    }

    func testApplyKeepsOneOperationPerID() {
        var document = self.document()
        var adjustment = sky()
        document.apply(.localAdjust(adjustment), label: "Mask: Ciel")
        let operationID = document.baseLayer?.edits.operations.last?.id
        document.apply(.adjust(.contrast, value: 0.2))
        adjustment.amount = 0.5
        document.apply(.localAdjust(adjustment))
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 2)
        XCTAssertEqual(document.baseLayer?.edits.operations.first?.id, operationID)
        XCTAssertEqual(document.baseLayer?.edits.operations.first?.label, "Mask: Ciel")
        XCTAssertEqual(document.localAdjustments, [adjustment])
    }

    func testALegacyFileWithTwoOperationsOfOneID() {
        // A file written with two operations for one id: the last wins, in operation order; removal takes both.
        let first = sky(0.1)
        var second = first
        second.adjustments[.exposure] = 0.5
        let other = LocalAdjustment(region: .bottom, stack: MaskStack())
        var stack = EditStack()
        stack.append(.localAdjust(first))
        stack.append(.localAdjust(other))
        stack.append(.localAdjust(second))
        XCTAssertEqual(stack.resolvedLocalAdjustments, [other, second])
        XCTAssertEqual(stack.localAdjustment(id: first.id), second)
        // An in-place set replaces the last one.
        var third = second
        third.amount = 0.4
        stack.setLocalAdjustment(third)
        XCTAssertEqual(stack.operations.count, 3)
        XCTAssertEqual(stack.localAdjustment(id: first.id), third)
        XCTAssertTrue(stack.removeLocalAdjustment(id: first.id))
        XCTAssertEqual(stack.operations.count, 1)
        XCTAssertFalse(stack.removeLocalAdjustment(id: first.id))
    }

    func testTheDevelopRecipeIgnoresLocalAdjustments() {
        var stack = EditStack()
        stack.append(.adjust(.exposure, value: 0.2))
        stack.append(.toneCurve(.sCurve(strength: 0.5)))
        let before = (stack.resolvedAdjustments, stack.removingToneTable(), stack.hasGeometry, stack.resolvedToneCurve, stack.pixelOperations)
        stack.setLocalAdjustment(sky())
        XCTAssertEqual(stack.resolvedAdjustments, before.0)
        XCTAssertEqual(stack.removingToneTable().operations.filter { if case .localAdjust = $0.kind { return false } else { return true } }, before.1.operations)
        XCTAssertEqual(stack.hasGeometry, before.2)
        XCTAssertEqual(stack.resolvedToneCurve, before.3)
        XCTAssertEqual(stack.pixelOperations, before.4)
        XCTAssertEqual(stack.netOrientation, .upright)
    }

    func testALocalAdjustmentIsTonalForEveryCacheKey() {
        XCTAssertTrue(PhotoDocument.isTonal(.localAdjust(sky())))
        XCTAssertTrue(PhotoDocument.isRebaseTonal(.localAdjust(sky())))
        var document = self.document()
        let base = (document.baseStateKey, document.tableGeometryKey)
        var adjustment = sky()
        document.setLocalAdjustment(adjustment)
        XCTAssertEqual(document.baseStateKey, base.0)
        XCTAssertEqual(document.tableGeometryKey, base.1)
        adjustment.adjustments[.exposure] = -0.4
        XCTAssertTrue(document.applyLocalEdit(.setDial(.exposure, -0.4), to: adjustment.id))
        XCTAssertEqual(document.baseStateKey, base.0)
        XCTAssertTrue(document.removeLocalAdjustment(id: adjustment.id))
        XCTAssertEqual(document.baseStateKey, base.0)
    }

    func testLocalAdjustmentsAreTheBaseLayers() {
        var document = self.document()
        let text = Layer(name: "Title", content: .text(TextElement(text: "Hello")))
        document.addLayer(text)
        XCTAssertEqual(document.localAdjustmentsLayerID, document.baseLayerID)
        let adjustment = sky()
        document.setLocalAdjustment(adjustment)
        // Even with another layer selected.
        XCTAssertEqual(document.selectedLayerID, text.id)
        XCTAssertEqual(document.localAdjustments, [adjustment])
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 1)
        XCTAssertTrue(document.layer(id: text.id)!.edits.isEmpty)
        XCTAssertEqual(document.localAdjustment(id: adjustment.id), adjustment)
        XCTAssertNil(document.localAdjustment(id: UUID()))
        // No base layer: nothing to adjust.
        var empty = PhotoDocument(title: "Empty", canvasSize: PSSize(width: 10, height: 10))
        empty.setLocalAdjustment(adjustment)
        XCTAssertTrue(empty.localAdjustments.isEmpty)
        XCTAssertFalse(empty.removeLocalAdjustment(id: adjustment.id))
    }

    /// W3: a selected image layer owns its own local adjustments; `a<n>` numbers them all, the base first; a lock
    /// refuses an edit; a crop of that layer remaps its masks and leaves the base's alone.
    func testASelectedImageLayerOwnsItsLocalAdjustments() throws {
        var document = self.document()
        let cup = Layer(name: "Tasse", content: .image(MediaAsset(kind: .image, relativePath: "media/cup.png", pixelSize: PSSize(width: 1200, height: 1600))))
        document.addLayer(cup)
        XCTAssertEqual(document.localAdjustmentsLayerID, cup.id, "the selected image layer")
        let onBase = sky(0.2), onCup = sky(0.5)
        document.setLocalAdjustment(onBase, on: document.baseLayerID!)
        document.setLocalAdjustment(onCup)
        XCTAssertEqual(document.localAdjustments, [onCup])
        XCTAssertEqual(document.localAdjustments(on: document.baseLayerID!), [onBase])
        XCTAssertEqual(document.allLocalAdjustments.map(\.adjustment.id), [onBase.id, onCup.id], "the base first")
        XCTAssertEqual(document.localAdjustmentOwner(of: onCup.id), cup.id)
        XCTAssertEqual(document.localAdjustmentOwner(of: onBase.id), document.baseLayerID)
        XCTAssertNil(document.localAdjustmentOwner(of: UUID()))
        XCTAssertEqual(document.localAdjustmentsAspect(on: cup.id), 0.75, accuracy: 1e-12)
        // Edits go to the owner; a text layer owns none.
        XCTAssertTrue(document.applyLocalEdit(.setDial(.exposure, -0.2), to: onCup.id, on: cup.id))
        XCTAssertEqual(document.localAdjustment(id: onCup.id, on: cup.id)?.adjustments[.exposure], -0.2)
        XCTAssertFalse(document.applyLocalEdit(.setDial(.exposure, -0.2), to: onCup.id, on: document.baseLayerID!))
        let text = Layer(name: "Titre", content: .text(TextElement(text: "Titre")))
        document.addLayer(text, select: false)
        document.setLocalAdjustment(onBase, on: text.id)
        XCTAssertEqual(document.localAdjustments(on: text.id), [])
        // A lock refusing pixels refuses the edit, a new adjustment and a removal.
        document.update(layerID: cup.id) { $0.lockOptions = [.pixels] }
        XCTAssertFalse(document.applyLocalEdit(.setDial(.exposure, 0.4), to: onCup.id, on: cup.id))
        document.setLocalAdjustment(sky(0.9), on: cup.id)
        XCTAssertEqual(document.localAdjustments(on: cup.id).count, 1)
        XCTAssertFalse(document.removeLocalAdjustment(id: onCup.id, on: cup.id))
        document.update(layerID: cup.id) { $0.lockOptions = [] }
        // Cropping the layer's left half remaps its mask; the base's stays.
        let before = try XCTUnwrap(document.localAdjustment(id: onCup.id, on: cup.id))
        XCTAssertTrue(document.apply(.crop(PSRect(x: 0.5, y: 0, width: 0.5, height: 1)), to: cup.id))
        let after = try XCTUnwrap(document.localAdjustment(id: onCup.id, on: cup.id))
        XCTAssertNotEqual(after.stack, before.stack)
        XCTAssertEqual(document.localAdjustment(id: onBase.id, on: document.baseLayerID!), onBase)
        XCTAssertEqual(document.localAdjustmentsAspect(on: cup.id), 0.375, accuracy: 1e-12)
        // Removal on the owner only.
        XCTAssertFalse(document.removeLocalAdjustment(id: onCup.id, on: document.baseLayerID!))
        XCTAssertTrue(document.removeLocalAdjustment(id: onCup.id, on: cup.id))
        XCTAssertEqual(document.allLocalAdjustments.map(\.adjustment.id), [onBase.id])
    }

    func testSettingAndRemovingTouchTheDocument() {
        var document = self.document()
        document.modifiedAt = Date(timeIntervalSince1970: 0)
        let adjustment = sky()
        document.setLocalAdjustment(adjustment)
        XCTAssertGreaterThan(document.modifiedAt, Date(timeIntervalSince1970: 0))
        document.modifiedAt = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(document.removeLocalAdjustment(id: adjustment.id))
        XCTAssertGreaterThan(document.modifiedAt, Date(timeIntervalSince1970: 0))
        // Removing what is not there does not touch it.
        document.modifiedAt = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(document.removeLocalAdjustment(id: adjustment.id))
        XCTAssertEqual(document.modifiedAt, Date(timeIntervalSince1970: 0))
    }

    func testSixteenPerLayer() {
        var document = self.document()
        for index in 0..<LocalAdjustment.maxPerLayer {
            XCTAssertTrue(document.canAddLocalAdjustment)
            document.setLocalAdjustment(LocalAdjustment(name: "m\(index)", stack: MaskStack()))
        }
        XCTAssertEqual(document.localAdjustments.count, 16)
        XCTAssertFalse(document.canAddLocalAdjustment)
        // A 17th is refused; the existing ones still update in place.
        document.setLocalAdjustment(LocalAdjustment(name: "m16", stack: MaskStack()))
        XCTAssertEqual(document.localAdjustments.count, 16)
        var first = document.localAdjustments[0]
        first.amount = 0.5
        document.setLocalAdjustment(first)
        XCTAssertEqual(document.localAdjustments[0].amount, 0.5)
    }

    func testTheMaskSpaceAspectFollowsTheGeometry() {
        var document = self.document()
        XCTAssertEqual(document.localAdjustmentsAspect, 4.0 / 3, accuracy: 1e-12)
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)))
        XCTAssertEqual(document.localAdjustmentsAspect, 1, accuracy: 1e-12)
        document.apply(.rotate(degrees: 90))
        XCTAssertEqual(document.localAdjustmentsAspect, 1, accuracy: 1e-12)
        document.apply(.crop(PSRect(x: 0, y: 0, width: 1, height: 0.5)))
        XCTAssertEqual(document.localAdjustmentsAspect, 2, accuracy: 1e-12)
        // Straighten does not change canvasSize in apply; the aspect still comes out right from the chain.
        document.apply(.straighten(degrees: 5))
        XCTAssertEqual(document.localAdjustmentsAspect, 2, accuracy: 1e-12)
    }

    func testNeutralityAndIdentity() {
        XCTAssertTrue(LocalAdjustment(stack: MaskStack()).isNeutral)
        XCTAssertFalse(sky().isNeutral)
        var faded = sky()
        faded.amount = 0
        XCTAssertTrue(faded.isNeutral)
        XCTAssertFalse(LocalAdjustment(stack: MaskStack(), curve: .sCurve(strength: 1)).isNeutral)
        XCTAssertTrue(LocalAdjustment(stack: MaskStack(), curve: .identity).isNeutral)
        XCTAssertTrue(LocalAdjustment(stack: MaskStack(), adjustments: Adjustments([.vignette: 0.5])).isNeutral)
        XCTAssertFalse(LocalAdjustment(stack: MaskStack(), mixer: ColorMixer(saturation: [0.3])).isNeutral)
        XCTAssertFalse(LocalAdjustment(stack: MaskStack(), grade: ColorGrade(midtones: ColorWheel(hue: 30, amount: 0.2))).isNeutral)
        // Find-or-create: region and, for objects and people, the label.
        let cup = LocalAdjustment(region: .object, label: "cup", stack: .single(MaskComponent(.radial(RadialGradientSpec(center: .zero, radiusX: 0.1, radiusY: 0.1)))))
        XCTAssertTrue(cup.matches(region: .object, label: "cup"))
        XCTAssertFalse(cup.matches(region: .object, label: "mug"))
        XCTAssertFalse(cup.matches(region: .object, label: nil))
        XCTAssertTrue(sky().matches(region: .sky, label: nil))
        XCTAssertFalse(sky().matches(region: .bottom, label: nil))
        var refined = sky()
        refined.stack.components.append(MaskComponent(.luminanceRange(LuminanceRangeSpec(low: 0.5, high: 1)), mode: .intersect))
        XCTAssertFalse(refined.matches(region: .sky, label: nil))
    }
}
