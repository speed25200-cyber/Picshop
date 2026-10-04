import XCTest
@testable import PicshopCore

/// D3 at the document level: every path that changes the base geometry leaves masks and the selection on the
/// same pixels, and the session's rebase (`PhotoDocument.rebased`) carries a command's masks, selection and
/// geometry over what was committed while it ran.
final class DocumentRebaseTests: XCTestCase {
    private let asset = MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000))

    private func document() -> PhotoDocument {
        PhotoDocument(title: "Rebase", baseImage: asset)
    }

    private func radial(at center: PSPoint, radius: Double = 0.05, region: MaskRegion? = .center) -> LocalAdjustment {
        LocalAdjustment(region: region, stack: .single(MaskComponent(.radial(RadialGradientSpec(center: center, radiusX: radius, radiusY: radius * 0.6, rotation: 15)))),
                        adjustments: Adjustments([.exposure: 0.4]))
    }

    private func radialSpec(_ document: PhotoDocument, _ id: UUID) -> RadialGradientSpec? {
        guard case .radial(let spec)? = document.localAdjustment(id: id)?.stack.components.first?.kind else { return nil }
        return spec
    }

    private func selection(in document: PhotoDocument, box: PSRect = PSRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), coverage: Double = 0.05) -> PhotoSelection {
        PhotoSelection(mask: MaskReference(source: .region("selection"), boundingBox: box, feather: 0.003), layerID: document.baseLayerID!,
                       steps: [SelectionStep(.subject)], coverage: coverage, pixelWidth: 1536, pixelHeight: 1152)
    }

    /// The point of the photo (source normalised space) under an output point of the base layer.
    private func sourcePoint(_ point: PSPoint, in document: PhotoDocument) -> PSPoint {
        document.baseLayer!.edits.geometryChain(sourceAspect: 4.0 / 3).map.inverse!.apply(point)
    }

    private func outputPoint(_ point: PSPoint, in document: PhotoDocument) -> PSPoint {
        document.baseLayer!.edits.geometryChain(sourceAspect: 4.0 / 3).map.apply(point)
    }

    private func assertClose(_ p: PSPoint?, _ q: PSPoint, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("missing point", file: file, line: line) }
        XCTAssertEqual(p.x, q.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(p.y, q.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: The four geometry paths

    /// Path 1: `apply`. A crop that changes the aspect (left 75 % of a 4:3 photo) keeps the radial on its pixels
    /// and its pixel radius within 1e-6; the selection's corners follow the same map.
    func testApplyRemapsMasksAndTheSelection() {
        var document = self.document()
        let adjustment = radial(at: PSPoint(x: 0.3, y: 0.4))
        document.setLocalAdjustment(adjustment)
        document.setSelection(selection(in: document))
        let pixelRadius = 0.05 * 4000
        let source = sourcePoint(PSPoint(x: 0.3, y: 0.4), in: document)
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)))
        let spec = radialSpec(document, adjustment.id)
        assertClose(spec?.center, outputPoint(source, in: document))
        assertClose(spec?.center, PSPoint(x: 0.4, y: 0.4))
        XCTAssertEqual((spec?.radiusX ?? 0) * 3000, pixelRadius, accuracy: 1e-6)
        XCTAssertEqual(spec?.rotation ?? 0, 15, accuracy: 1e-9)
        // The selection's raster now spans 4/3 of the canvas width.
        assertClose(document.selection?.corners[1], PSPoint(x: 4.0 / 3, y: 0))
        assertClose(document.selection?.corners[2], PSPoint(x: 4.0 / 3, y: 1))
        XCTAssertFalse(document.selection?.isAligned ?? true)
        // Its coverage grows with the zoom (the box is fully inside): 0.05 × 4/3.
        XCTAssertEqual(document.selection?.coverage ?? 0, 0.05 * 4 / 3, accuracy: 1e-9)
        // A quarter turn: the mask turns with the picture.
        let before = document.localAdjustment(id: adjustment.id)!
        let turnSource = sourcePoint(radialSpec(document, adjustment.id)!.center, in: document)
        document.apply(.rotate(degrees: 90))
        assertClose(radialSpec(document, adjustment.id)?.center, outputPoint(turnSource, in: document))
        XCTAssertEqual(radialSpec(document, adjustment.id)?.rotation ?? 0, 105, accuracy: 1e-9)
        XCTAssertNotEqual(document.localAdjustment(id: adjustment.id), before)
    }

    func testNonGeometricAndOtherLayerEditsLeaveMasksAlone() {
        var document = self.document()
        let adjustment = radial(at: PSPoint(x: 0.3, y: 0.4))
        document.setLocalAdjustment(adjustment)
        document.setSelection(selection(in: document))
        let snapshot = (document.localAdjustments, document.selection)
        document.apply(.adjust(.exposure, value: 0.2))
        document.apply(.upscale(factor: 2))
        let text = Layer(name: "Title", content: .image(asset))
        document.addLayer(text, select: false)
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 0.5)), to: text.id)
        XCTAssertEqual(document.localAdjustments, snapshot.0)
        XCTAssertEqual(document.selection, snapshot.1)
    }

    /// Path 2: the perspective handler replaces the last perspective in place and reconciles with the edits
    /// from before its change.
    func testAnInPlacePerspectiveReplacementRemaps() {
        var document = self.document()
        document.apply(.perspective(horizontal: 0.3, vertical: 0))
        let adjustment = radial(at: PSPoint(x: 0.6, y: 0.3))
        document.setLocalAdjustment(adjustment)
        document.setSelection(selection(in: document))
        let source = sourcePoint(PSPoint(x: 0.6, y: 0.3), in: document)
        let selectionSource = document.selection!.corners.map { sourcePoint($0, in: document) }
        let previous = document.baseLayer!.edits
        document.update(layerID: document.baseLayerID!) { layer in
            let index = layer.edits.operations.lastIndex { if case .perspective = $0.kind { return true } else { return false } }!
            let last = layer.edits.operations[index]
            layer.edits.operations[index] = EditOperation(id: last.id, kind: .perspective(horizontal: -0.2, vertical: 0.4), createdAt: last.createdAt)
        }
        document.reconcileMasks(previousBaseEdits: previous)
        assertClose(radialSpec(document, adjustment.id)?.center, outputPoint(source, in: document), accuracy: 1e-9)
        for (corner, original) in zip(document.selection!.corners, selectionSource) {
            assertClose(corner, outputPoint(original, in: document), accuracy: 1e-9)
        }
    }

    /// Path 3: aspect « original » removes every crop and resets the canvas, then reconciles.
    func testRemovingTheCropsRemaps() {
        var document = self.document()
        document.apply(.crop(PSRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)))
        document.apply(.flip(.horizontal))
        let adjustment = radial(at: PSPoint(x: 0.5, y: 0.5))
        document.setLocalAdjustment(adjustment)
        let source = sourcePoint(PSPoint(x: 0.5, y: 0.5), in: document)
        let previous = document.baseLayer!.edits
        document.update(layerID: document.baseLayerID!) { layer in
            layer.edits.operations.removeAll { if case .crop = $0.kind { return true } else { return false } }
        }
        document.canvasSize = asset.pixelSize
        document.reconcileMasks(previousBaseEdits: previous)
        let spec = radialSpec(document, adjustment.id)
        assertClose(spec?.center, outputPoint(source, in: document))
        // The whole photo again: the radius shrinks back to the source's longest side (2000 px crop → 4000 px).
        XCTAssertEqual((spec?.radiusX ?? 0) * 4000, 0.05 * 2000, accuracy: 1e-6)
    }

    /// Path 4: restoring the import drops the selection with the edits.
    func testRestoringToImportDropsTheSelectionAndTheMasks() {
        var document = self.document()
        document.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 1)))
        document.setLocalAdjustment(radial(at: PSPoint(x: 0.5, y: 0.5)))
        document.setSelection(selection(in: document))
        let restored = document.restoredToImport()
        XCTAssertNil(restored.selection)
        XCTAssertTrue(restored.localAdjustments.isEmpty)
        XCTAssertEqual(restored.canvasSize, asset.pixelSize)
    }

    func testACropThatLosesTheSelectionDropsIt() {
        var document = self.document()
        // A selection in the top-left 10 % box.
        document.setSelection(selection(in: document, box: PSRect(x: 0, y: 0, width: 0.1, height: 0.1), coverage: 0.01))
        var kept = document
        kept.apply(.crop(PSRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)))
        XCTAssertNotNil(kept.selection)
        // The crop leaves 0.04 % of the canvas to the box: below 0.2 %, dropped.
        document.apply(.crop(PSRect(x: 0.098, y: 0.098, width: 0.9, height: 0.9)))
        XCTAssertNil(document.selection)
        // A selection on another layer is not the base's to move.
        var other = self.document()
        let layer = Layer(name: "Copy", content: .image(asset))
        other.addLayer(layer, select: false)
        var foreign = selection(in: other)
        foreign.layerID = layer.id
        other.setSelection(foreign)
        other.apply(.crop(PSRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)), to: other.baseLayerID)
        XCTAssertEqual(other.selection, foreign)
    }

    // MARK: The rebase

    func testASelectResultCarriesOver() {
        let base = document()
        var updated = base
        updated.setSelection(selection(in: base))
        var current = base
        current.apply(.adjust(.contrast, value: 0.3))
        let rebased = current.rebased(updated, from: base)
        XCTAssertEqual(rebased?.selection, updated.selection)
        XCTAssertEqual(rebased?.baseLayer?.edits.resolvedAdjustments[.contrast], 0.3)
        // Deselecting carries over the same way.
        var withSelection = base
        withSelection.setSelection(selection(in: base))
        var deselected = withSelection
        deselected.setSelection(nil)
        var meanwhile = withSelection
        meanwhile.apply(.adjust(.exposure, value: 0.1))
        XCTAssertNil(meanwhile.rebased(deselected, from: withSelection)?.selection)
        XCTAssertNotNil(meanwhile.rebased(deselected, from: withSelection))
    }

    func testBothSidesChangingTheSelectionGiveNil() {
        let base = document()
        var updated = base
        updated.setSelection(selection(in: base))
        var current = base
        current.setSelection(selection(in: base, box: PSRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)))
        XCTAssertNil(current.rebased(updated, from: base))
        // A flip committed meanwhile would misplace the command's selection: nil too.
        var flipped = base
        flipped.apply(.flip(.horizontal))
        XCTAssertNil(flipped.rebased(updated, from: base))
    }

    func testAnInPlaceMaskEditRebasesOverMovedDials() {
        var base = document()
        let adjustment = radial(at: PSPoint(x: 0.3, y: 0.3))
        let other = radial(at: PSPoint(x: 0.7, y: 0.7), region: .edges)
        base.setLocalAdjustment(adjustment, label: "Mask: Centre")
        base.setLocalAdjustment(other)
        // The command edits the first mask in place.
        var updated = base
        XCTAssertTrue(updated.applyLocalEdit(.setDial(.exposure, 0.9), to: adjustment.id))
        // Meanwhile a global dial and the other mask's dial moved.
        var current = base
        current.apply(.adjust(.contrast, value: 0.2))
        XCTAssertTrue(current.applyLocalEdit(.setAmount(0.5), to: other.id))
        let rebased = current.rebased(updated, from: base)
        XCTAssertNotNil(rebased)
        XCTAssertEqual(rebased?.localAdjustment(id: adjustment.id)?.adjustments[.exposure], 0.9)
        XCTAssertEqual(rebased?.localAdjustment(id: other.id)?.amount, 0.5)
        XCTAssertEqual(rebased?.baseLayer?.edits.resolvedAdjustments[.contrast], 0.2)
        // Still one operation per id, in place, with its label.
        XCTAssertEqual(rebased?.baseLayer?.edits.operations.count, 3)
        XCTAssertEqual(rebased?.baseLayer?.edits.operations.first?.id, base.baseLayer?.edits.operations.first?.id)
        XCTAssertEqual(rebased?.baseLayer?.edits.operations.first?.label, "Mask: Centre")
        // The command's version wins over a concurrent edit of the same mask.
        var racing = base
        XCTAssertTrue(racing.applyLocalEdit(.setDial(.exposure, -0.5), to: adjustment.id))
        XCTAssertEqual(racing.rebased(updated, from: base)?.localAdjustment(id: adjustment.id)?.adjustments[.exposure], 0.9)
        // A mask the command edited but that was deleted meanwhile: nil.
        var deleted = base
        XCTAssertTrue(deleted.removeLocalAdjustment(id: adjustment.id))
        XCTAssertNil(deleted.rebased(updated, from: base))
    }

    func testANewMaskAndADeletedMaskCarryOver() {
        var base = document()
        let old = radial(at: PSPoint(x: 0.5, y: 0.5))
        base.setLocalAdjustment(old)
        var updated = base
        let added = radial(at: PSPoint(x: 0.2, y: 0.8), region: .bottom)
        updated.setLocalAdjustment(added, label: "Mask: Bas")
        XCTAssertTrue(updated.removeLocalAdjustment(id: old.id))
        var current = base
        let mine = radial(at: PSPoint(x: 0.9, y: 0.1), region: .top)
        current.setLocalAdjustment(mine)
        let rebased = current.rebased(updated, from: base)
        XCTAssertEqual(rebased?.localAdjustments.map(\.id), [mine.id, added.id])
        XCTAssertEqual(rebased?.baseLayer?.edits.operations.last?.label, "Mask: Bas")
    }

    func testACommandsCropRemapsAMaskAddedMeanwhile() throws {
        let base = document()
        var updated = base
        updated.apply(.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)), label: "Crop")
        var current = base
        let mine = radial(at: PSPoint(x: 0.3, y: 0.4))
        current.setLocalAdjustment(mine)
        current.setSelection(selection(in: current))
        let rebased = try XCTUnwrap(current.rebased(updated, from: base))
        // The crop carried over with its id, the canvas followed, the new mask and the selection moved with it.
        XCTAssertEqual(rebased.baseLayer?.edits.operations.last?.id, updated.baseLayer?.edits.operations.last?.id)
        XCTAssertEqual(rebased.canvasSize, updated.canvasSize)
        XCTAssertEqual(rebased.canvasSize, PSSize(width: 3000, height: 3000))
        assertClose(radialSpec(rebased, mine.id)?.center, PSPoint(x: 0.4, y: 0.4))
        assertClose(rebased.selection?.corners[1], PSPoint(x: 4.0 / 3, y: 0))
    }

    func testACommandsCropDoesNotOverrideDialsMovedMeanwhile() throws {
        var base = document()
        let adjustment = radial(at: PSPoint(x: 0.3, y: 0.4))
        base.setLocalAdjustment(adjustment)
        // The command crops (the mask moves with it in its result).
        var updated = base
        updated.apply(.crop(PSRect(x: 0, y: 0, width: 0.75, height: 1)))
        // Meanwhile the person changed the mask's amount.
        var current = base
        XCTAssertTrue(current.applyLocalEdit(.setAmount(0.3), to: adjustment.id))
        let rebased = try XCTUnwrap(current.rebased(updated, from: base))
        let result = try XCTUnwrap(rebased.localAdjustment(id: adjustment.id))
        XCTAssertEqual(result.amount, 0.3)
        assertClose(radialSpec(rebased, adjustment.id)?.center, PSPoint(x: 0.4, y: 0.4))
    }

    func testTheW1RulesStillHold() {
        var base = document()
        base.apply(.adjust(.exposure, value: 0.1))
        var updated = base
        updated.apply(.removeObject(MaskReference(source: .object(label: "dog", boundingBox: .unit))))
        // A crop meanwhile: nil (the canvas changed under the command).
        var cropped = base
        cropped.apply(.crop(PSRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertNil(cropped.rebased(updated, from: base))
        // A flip meanwhile under a command that appended a step: nil (its mask would be misplaced).
        var flipped = base
        flipped.apply(.flip(.horizontal))
        XCTAssertNil(flipped.rebased(updated, from: base))
        // A different structural history meanwhile (an undo, then a flip): nil.
        var undone = document()
        undone.apply(.flip(.vertical))
        XCTAssertNil(undone.rebased(updated, from: base))
        // A command that rewrote an earlier step in place: nil.
        var rewritten = base
        rewritten.update(layerID: rewritten.baseLayerID!) { $0.edits.operations[0] = EditOperation(kind: .adjust(.exposure, value: 0.5)) }
        rewritten.apply(.flip(.horizontal))
        XCTAssertNil(base.rebased(rewritten, from: base))
        // A command that added a layer is not replayed (W1).
        var layered = base
        layered.addLayer(Layer(name: "Fill", content: .image(asset)))
        var meanwhile = base
        meanwhile.apply(.adjust(.contrast, value: 0.2))
        XCTAssertNil(meanwhile.rebased(layered, from: base))
        // Nothing changed by the command: the current document as it is.
        XCTAssertEqual(meanwhile.rebased(base, from: base), meanwhile)
    }

    func testTheCanvasMustFollowTheReplayedSteps() {
        let base = document()
        var updated = base
        // A command that changed the canvas without a step to replay it.
        updated.canvasSize = PSSize(width: 100, height: 100)
        updated.apply(.adjust(.exposure, value: 0.1))
        var current = base
        current.apply(.adjust(.contrast, value: 0.1))
        XCTAssertNil(current.rebased(updated, from: base))
    }
}
