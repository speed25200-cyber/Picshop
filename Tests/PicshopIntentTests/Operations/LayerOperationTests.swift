import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (§8.3): the layer operations through the coercer, the validator, the handlers and the fake host, on the layered
/// poster (`OperationFixtures.photoWithLayers`, refs i0…g1).
final class LayerOperationTests: XCTestCase {
    typealias Run = SelectionOperationTests.Run

    /// The layer a stored ref names (D19). Without a scene: the fixture rebuilds its scene map from the layer order
    /// on every call, where the app carries the map's ids across versions (`SceneMap.carryingIDs`).
    static func layer(_ ref: String, _ document: PhotoDocument) -> Layer? {
        LiveLayerLines.layer(ref: ref, in: document, scene: nil)
    }

    /// The step as a model writes it, on `document` (the layered poster by default).
    static func model(_ id: OpID, _ args: [String: OpValue], on document: PhotoDocument = OperationFixtures.photoWithLayers(),
                      french: Bool = true) async throws -> Run {
        try await SelectionOperationTests.model(id, args, on: document, french: french)
    }

    static func message(_ run: Run) -> String { run.result.outcome.message ?? "" }

    static func spoken(_ run: Run) -> [String] {
        run.result.effects.compactMap { effect in
            if case .message(let text) = effect, text.hasPrefix("speak:") { return String(text.dropFirst(6)) }
            return nil
        }
    }

    static func messages(_ run: Run) -> [String] {
        run.result.effects.compactMap { effect in
            if case .message(let text) = effect { return text }
            return nil
        }
    }

    // MARK: Fill layers

    func testAddFillLayerSolidAndGradientSelectTheNewLayer() async throws {
        let solid = try await Self.model("addFillLayer", ["fill": "solid", "color": "white"])
        SelectionOperationTests.assertVerified(solid, "addFillLayer solid")
        XCTAssertEqual(solid.after.layers.count, solid.before.layers.count + 1)
        let added = try XCTUnwrap(solid.after.layers.first { layer in !solid.before.layers.contains { $0.id == layer.id } })
        XCTAssertEqual(added.content, .fill(.white))
        XCTAssertEqual(solid.after.selectedLayerID, added.id, "the new layer is selected")
        XCTAssertTrue(solid.result.effects.contains(.selectLayer(added.id)))
        XCTAssertTrue(Self.spoken(solid).contains { $0.contains("créé") }, "\(Self.spoken(solid))")

        let gradient = try await Self.model("addFillLayer", ["fill": "gradient", "color": "black", "angle": 90])
        SelectionOperationTests.assertVerified(gradient, "addFillLayer gradient")
        let made = try XCTUnwrap(gradient.after.layers.first { layer in !gradient.before.layers.contains { $0.id == layer.id } })
        guard case .gradientFill(let fill) = made.content else { return XCTFail("\(made.content)") }
        XCTAssertEqual(fill.stops.first?.color.alpha ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(fill.stops.last?.color.alpha ?? 1, 0, accuracy: 1e-9, "black to clear")
    }

    func testAFillBelowThePhotoIsRefused() async throws {
        let run = try await Self.model("addFillLayer", ["fill": "solid", "color": "white", "position": "below", "ref": "i0"])
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertEqual(run.after, run.before)
    }

    func testFillLayerEditsTheSolidAndTheGradient() async throws {
        let solid = try await Self.model("fillLayer", ["ref": "j1", "color": "blue"])
        SelectionOperationTests.assertVerified(solid, "fillLayer j1")
        XCTAssertEqual(Self.layer("j1", solid.after)?.content, .fill(.blue))

        let radial = try await Self.model("fillLayer", ["ref": "j2", "style": "radial"])
        SelectionOperationTests.assertVerified(radial, "fillLayer j2")
        guard case .gradientFill(let fill)? = Self.layer("j2", radial.after)?.content else { return XCTFail() }
        XCTAssertEqual(fill.style, .radial)

        let angle = try await Self.model("fillLayer", ["ref": "j2", "angle": 45])
        guard case .gradientFill(let turned)? = Self.layer("j2", angle.after)?.content else { return XCTFail() }
        XCTAssertEqual(turned.angle, 45, accuracy: 1e-9)

        // A fill edit on a layer that is not a fill names it.
        let wrong = try await Self.model("fillLayer", ["ref": "j3", "color": "red"])
        XCTAssertFalse(wrong.result.outcome.isSuccess)
        XCTAssertEqual(wrong.after, wrong.before)
    }

    // MARK: Adjustment layers

    func testAdjustmentLayersOfEveryKind() async throws {
        let cases: [(AdjustmentLayerKind, [String: OpValue])] = [
            (.curves, ["preset": "sCurve"]), (.light, ["parameter": "brightness", "amount": 20]), (.levels, ["auto": true]),
            (.hsl, ["band": "green", "saturation": -40]), (.colorGrade, ["shadows": "blue", "amount": 30]), (.look, ["look": "mono"]),
            (.lut, ["intensity": 60]),
        ]
        for (kind, extra) in cases {
            var args = extra
            args["kind"] = .string(kind.rawValue)
            let run = try await Self.model("addAdjustmentLayer", args)
            XCTAssertTrue(run.result.outcome.isSuccess, "\(kind): \(run.result.outcome)")
            let made = try XCTUnwrap(run.after.layers.first { layer in !run.before.layers.contains { $0.id == layer.id } }, "\(kind)")
            XCTAssertEqual(made.recipeKind, kind)
            XCTAssertEqual(run.result.label, "Adjustment Layer: " + kind.englishName)
            guard case .adjustment = made.content else { return XCTFail("\(kind): \(made.content)") }
            XCTAssertEqual(run.after.baseLayer?.edits, run.before.baseLayer?.edits, "\(kind): the photo is untouched")
        }
        let light = try await Self.model("addAdjustmentLayer", ["kind": "light", "parameter": "brightness", "amount": 20])
        let made = try XCTUnwrap(light.after.layers.first { layer in !light.before.layers.contains { $0.id == layer.id } })
        guard case .adjustment(let dials) = made.content else { return XCTFail() }
        XCTAssertGreaterThan(dials[.brightness], 0, "a Light layer keeps its dials in its content (D9)")

        let vignette = try await Self.model("addAdjustmentLayer", ["kind": "light", "parameter": "vignette", "amount": 30])
        XCTAssertFalse(vignette.result.outcome.isSuccess, "vignette is not a layer adjustment")
        XCTAssertEqual(vignette.after, vignette.before)
    }

    func testANeutralAdjustmentLayerSaysSo() async throws {
        let run = try await Self.model("addAdjustmentLayer", ["kind": "hsl"])
        XCTAssertTrue(run.result.outcome.isSuccess)
        XCTAssertFalse(Self.spoken(run).isEmpty, "the hint that it changes nothing yet")
    }

    func testAToneOpWithAJRefLandsInThatLayer() async throws {
        let curves = try await Self.model("curves", ["preset": "sCurve", "layer": "j3"])
        SelectionOperationTests.assertVerified(curves, "curves j3")
        let j3 = try XCTUnwrap(Self.layer("j3", curves.after))
        XCTAssertNotNil(PhotoOperationHandlers.userToneCurve(j3.edits))
        XCTAssertEqual(curves.after.baseLayer?.edits, curves.before.baseLayer?.edits, "the photo is untouched")

        let exposure = try await Self.model("adjust", ["parameter": "exposure", "amount": -20, "layer": "j4"])
        XCTAssertTrue(exposure.result.outcome.isSuccess, "\(exposure.result.outcome)")
        guard case .adjustment(let dials)? = Self.layer("j4", exposure.after)?.content else { return XCTFail() }
        XCTAssertLessThan(dials[.exposure], 0, "a Light layer's dial (D9)")
        XCTAssertEqual(exposure.after.baseLayer?.edits, exposure.before.baseLayer?.edits)

        // The wrong family is named, nothing changes.
        let wrong = try await Self.model("curves", ["preset": "sCurve", "layer": "j4"])
        XCTAssertFalse(wrong.result.outcome.isSuccess)
        XCTAssertTrue(Self.message(wrong).contains("j4"), Self.message(wrong))
        XCTAssertEqual(wrong.after, wrong.before)
    }

    func testToneTargetPicksTheSelectedCurvesLayer() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.selectedLayerID = OperationFixtures.curvesID
        XCTAssertEqual(document.toneTarget(for: "curves"), OperationFixtures.curvesID)
        let run = try await Self.model("curves", ["preset": "strongS"], on: document)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertNotNil(PhotoOperationHandlers.userToneCurve(try XCTUnwrap(run.after.layer(id: OperationFixtures.curvesID)).edits))
        XCTAssertEqual(run.after.baseLayer?.edits, document.baseLayer?.edits)
    }

    // MARK: Clipping, groups, merges

    func testClipAndRelease() async throws {
        let clip = try await Self.model("layerClip", ["ref": "l2", "clip": true])
        SelectionOperationTests.assertVerified(clip, "clip l2")
        XCTAssertEqual(Self.layer("l2", clip.after)?.isClipped, true)
        let release = try await Self.model("layerClip", ["ref": "l2", "clip": false], on: clip.after)
        XCTAssertTrue(release.result.outcome.isSuccess)
        XCTAssertEqual(Self.layer("l2", release.after)?.isClipped, false)
    }

    func testGroupAndUngroup() async throws {
        let group = try await Self.model("groupLayers", ["refs": .list(["l1", "s1"])])
        SelectionOperationTests.assertVerified(group, "group l1 s1")
        let made = try XCTUnwrap(group.after.layers.first { layer in !group.before.layers.contains { $0.id == layer.id } })
        XCTAssertEqual(Self.layer("l1", group.after)?.parentID, made.id)
        XCTAssertEqual(Self.layer("s1", group.after)?.parentID, made.id)

        let ungroup = try await Self.model("groupLayers", ["ungroup": true, "ref": "g1"])
        XCTAssertTrue(ungroup.result.outcome.isSuccess, "\(ungroup.result.outcome)")
        XCTAssertNil(ungroup.after.layer(id: OperationFixtures.circleID)?.parentID)
        XCTAssertNil(ungroup.after.layer(id: OperationFixtures.captionID)?.parentID)
    }

    func testMergeModes() async throws {
        let down = try await Self.model("mergeLayers", ["mode": "down", "ref": "i2"])
        SelectionOperationTests.assertVerified(down, "merge down i2")
        XCTAssertLessThan(down.after.layers.count, down.before.layers.count)

        let stamp = try await Self.model("mergeLayers", ["mode": "stamp"])
        SelectionOperationTests.assertVerified(stamp, "stamp")
        XCTAssertEqual(stamp.after.layers.count, stamp.before.layers.count + 1)

        let selected = try await Self.model("mergeLayers", ["mode": "selected", "refs": .list(["l1", "s1"])])
        SelectionOperationTests.assertVerified(selected, "merge selected")
        XCTAssertEqual(selected.after.layers.count, selected.before.layers.count - 1)

        let flatten = try await Self.model("mergeLayers", ["mode": "flatten"])
        SelectionOperationTests.assertVerified(flatten, "flatten")
        XCTAssertEqual(flatten.after.layers.count, 1)
    }

    func testMergeDownOnThePhotoSaysThereIsNothingBelow() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.selectedLayerID = document.baseLayerID
        let run = try await Self.model("mergeLayers", ["mode": "down"], on: document)
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertTrue(Self.message(run).contains("dessous"), Self.message(run))
        XCTAssertEqual(run.after, document)
    }

    func testFlattenWithHiddenLayersAsksFirst() async throws {
        var document = OperationFixtures.photoWithLayers()
        if let index = document.layers.firstIndex(where: { $0.id == OperationFixtures.logoID }) { document.layers[index].isVisible = false }
        let ask = try await Self.model("mergeLayers", ["mode": "flatten"], on: document)
        guard case .needsClarification = ask.result.outcome else { return XCTFail("\(ask.result.outcome)") }
        XCTAssertEqual(ask.after, document)
        let confirmed = try await Self.model("mergeLayers", ["mode": "flatten", "confirm": true], on: document)
        XCTAssertTrue(confirmed.result.outcome.isSuccess, "\(confirmed.result.outcome)")
        XCTAssertEqual(confirmed.after.layers.count, 1)
    }

    // MARK: Transform

    func testLayerTransformBareVerbDefaults() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.selectedLayerID = OperationFixtures.cupID
        let before = try XCTUnwrap(document.layer(id: OperationFixtures.cupID)).transform

        let bigger = try await Self.model("layerTransform", ["scaleBy": 120], on: document)
        SelectionOperationTests.assertVerified(bigger, "scaleBy")
        XCTAssertEqual(try XCTUnwrap(bigger.after.layer(id: OperationFixtures.cupID)).transform.scale, before.scale * 1.2, accuracy: 1e-9)

        let left = try await Self.model("layerTransform", ["dx": -50], on: document)
        SelectionOperationTests.assertVerified(left, "dx")
        XCTAssertEqual(try XCTUnwrap(left.after.layer(id: OperationFixtures.cupID)).transform.center.x, before.center.x - 0.05, accuracy: 1e-9)

        let turned = try await Self.model("layerTransform", ["rotation": 15, "relative": true], on: document)
        SelectionOperationTests.assertVerified(turned, "rotation")
        XCTAssertEqual(try XCTUnwrap(turned.after.layer(id: OperationFixtures.cupID)).transform.rotation, before.rotation + 15, accuracy: 1e-9)

        let flipped = try await Self.model("layerTransform", ["flip": "horizontal"], on: document)
        XCTAssertTrue(flipped.result.outcome.isSuccess, "\(flipped.result.outcome)")
        XCTAssertNotEqual(flipped.after.layer(id: OperationFixtures.cupID)?.transform, before)

        let reset = try await Self.model("layerTransform", ["fit": "reset"], on: document)
        XCTAssertTrue(reset.result.outcome.isSuccess, "\(reset.result.outcome)")
        XCTAssertNotEqual(reset.after.layer(id: OperationFixtures.cupID)?.transform, before)

        // A mode alone opens the handles: nothing changes yet.
        let handles = try await Self.model("layerTransform", ["mode": "perspective"], on: document)
        XCTAssertEqual(handles.after, document)
        XCTAssertTrue(Self.messages(handles).contains("transformLayer:\(OperationFixtures.cupID.uuidString):perspective"), "\(Self.messages(handles))")
    }

    func testValidCornersPlaceTheLayerAndBadOnesAreRefused() async throws {
        let corners: OpValue = .list([.list([200, 200]), .list([800, 250]), .list([780, 800]), .list([220, 760])])
        let run = try await Self.model("layerTransform", ["ref": "i1", "corners": corners])
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertNotEqual(Self.layer("i1", run.after)?.transform, Self.layer("i1", run.before)?.transform)
        // A bow-tie is not a quad: the validator refuses it.
        let crossed: OpValue = .list([.list([200, 200]), .list([800, 800]), .list([800, 200]), .list([200, 800])])
        do {
            _ = try await Self.model("layerTransform", ["ref": "i1", "corners": crossed])
            XCTFail("a crossed quad validated")
        } catch is XCTSkip {}
    }

    func testAlignWithRefs() async throws {
        let run = try await Self.model("layerTransform", ["refs": .list(["i1", "i2"]), "align": "left"])
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let canvas = run.after.canvasSize
        func minX(_ ref: String) throws -> Double {
            let layer = try XCTUnwrap(Self.layer(ref, run.after))
            let size = try XCTUnwrap(LayerPlacement.contentSize(of: layer, canvasSize: canvas))
            return LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: canvas, isBase: false).minX
        }
        XCTAssertEqual(try minX("i1"), try minX("i2"), accuracy: 1e-6)
    }

    // MARK: Properties and locks

    func testLayerPropertiesFillNameAndLock() async throws {
        let fill = try await Self.model("layerProperties", ["ref": "i1", "fill": 40])
        SelectionOperationTests.assertVerified(fill, "fill")
        XCTAssertEqual(Self.layer("i1", fill.after)?.fillOpacity ?? 0, 0.4, accuracy: 1e-9)

        let name = try await Self.model("layerProperties", ["ref": "i1", "name": "Produit"])
        XCTAssertTrue(name.result.outcome.isSuccess)
        XCTAssertEqual(Self.layer("i1", name.after)?.name, "Produit")

        let lock = try await Self.model("layerProperties", ["ref": "i1", "lock": "all"])
        SelectionOperationTests.assertVerified(lock, "lock")
        XCTAssertEqual(lock.after.effectiveLock(of: OperationFixtures.cupID), .all, "« tout » is the W1 lock")

        let pixels = try await Self.model("layerProperties", ["ref": "i1", "lock": "pixels"], on: lock.after)
        XCTAssertTrue(pixels.result.outcome.isSuccess)
        XCTAssertEqual(pixels.after.effectiveLock(of: OperationFixtures.cupID), [.pixels], "a partial lock replaces the full one")

        let unlock = try await Self.model("layerProperties", ["ref": "i1", "lock": "none"], on: lock.after)
        XCTAssertTrue(unlock.result.outcome.isSuccess)
        XCTAssertEqual(unlock.after.effectiveLock(of: OperationFixtures.cupID), [])
    }

    func testLocksRefuseWithTheD7Message() async throws {
        let locked = try await Self.model("layerProperties", ["ref": "i1", "lock": "position"])
        let move = try await Self.model("layerTransform", ["ref": "i1", "dx": 40], on: locked.after)
        XCTAssertFalse(move.result.outcome.isSuccess)
        XCTAssertTrue(Self.message(move).contains("verrouillé"), Self.message(move))
        XCTAssertTrue(move.result.effects.contains(ExecutionReason.locked.effect), "\(move.result.effects)")
        XCTAssertEqual(move.after, locked.after)

        let pixels = try await Self.model("layerProperties", ["ref": "i1", "lock": "all"])
        let tone = try await Self.model("adjust", ["parameter": "exposure", "amount": 20, "layer": "i1"], on: pixels.after)
        XCTAssertFalse(tone.result.outcome.isSuccess)
        XCTAssertTrue(Self.message(tone).contains("verrouillé"), Self.message(tone))
        XCTAssertEqual(tone.after, pixels.after)

        let english = try await Self.model("layerTransform", ["ref": "i1", "dx": 40], on: locked.after, french: false)
        XCTAssertTrue(Self.message(english).contains("locked"), Self.message(english))
    }

    // MARK: Refs

    func testUnknownRefsListTheExistingOnes() async throws {
        let run = try await Self.model("layerClip", ["ref": "l9", "clip": true])
        XCTAssertFalse(run.result.outcome.isSuccess)
        let said = Self.message(run)
        XCTAssertTrue(said.contains("l9"), said)
        XCTAssertTrue(said.contains("l1") && said.contains("i1"), said)
        XCTAssertTrue(run.result.effects.contains(ExecutionReason.unknownRef.effect))
    }

    func testDuplicateDeleteAndSelectWithRefs() async throws {
        let select = try await Self.model("selectLayer", ["ref": "i2"])
        XCTAssertTrue(select.result.effects.contains(.selectLayer(OperationFixtures.logoID)), "\(select.result.effects)")

        let duplicate = try await Self.model("duplicateLayer", ["ref": "i1"])
        XCTAssertTrue(duplicate.result.outcome.isSuccess, "\(duplicate.result.outcome)")
        XCTAssertEqual(duplicate.after.layers.count, duplicate.before.layers.count + 1)
        XCTAssertEqual(duplicate.after.layers.filter { $0.name.hasPrefix("Tasse") }.count, 2)

        let delete = try await Self.model("deleteLayer", ["ref": "j9"])
        XCTAssertTrue(delete.result.outcome.isSuccess, "\(delete.result.outcome)")
        XCTAssertNil(delete.after.layer(id: OperationFixtures.lookID))
        // The refs of the others never shift (D19).
        XCTAssertEqual(Self.layer("j8", delete.after)?.id, OperationFixtures.lutLayerID)
    }

    // MARK: Layer via

    func testLayerViaCopyAndCutOfTheSubject() async throws {
        let copy = try await Self.model("layerVia", ["mode": "copy", "where": "subject"])
        XCTAssertTrue(copy.result.outcome.isSuccess, "\(copy.result.outcome)")
        XCTAssertEqual(copy.after.layers.count, copy.before.layers.count + 1)
        XCTAssertEqual(copy.result.label, "Layer via Copy")
        let cut = try await Self.model("layerVia", ["mode": "cut", "where": "subject"])
        XCTAssertTrue(cut.result.outcome.isSuccess, "\(cut.result.outcome)")
        XCTAssertEqual(cut.result.label, "Layer via Cut")
    }

    /// The selection (made on the photo) is carried into the transformed source's content space: the new layer's
    /// region corners are the selection's through `LayerPlacement.inverseMap` (D8).
    func testLayerViaMapsTheSelectionIntoATransformedSource() async throws {
        let document = OperationFixtures.photoWithLayers()
        let selection = try XCTUnwrap(document.selection)
        let cup = try XCTUnwrap(document.layer(id: OperationFixtures.cupID))
        let size = try XCTUnwrap(LayerPlacement.contentSize(of: cup, canvasSize: document.canvasSize))
        let inverse = try XCTUnwrap(LayerPlacement.inverseMap(for: cup, contentSize: size, canvasSize: document.canvasSize, isBase: false))
        let run = try await Self.model("layerVia", ["mode": "copy", "useSelection": true, "layer": "i1"], on: document)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let made = try XCTUnwrap(run.after.layers.first { layer in !document.layers.contains { $0.id == layer.id } })
        let component = try XCTUnwrap(made.maskStack?.components.first)
        guard case .raster(let raster) = component.kind else { return XCTFail("\(component.kind)") }
        let expected = selection.raster.corners.map(inverse.apply)
        XCTAssertEqual(raster.corners.count, expected.count)
        for (got, want) in zip(raster.corners, expected) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
    }

    func testLayerViaWithoutAnAreaAsksForOne() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.setSelection(nil)
        // The validator wants an area from a model; the grammar's bare « calque par copier » reaches the handler.
        let intent = EditIntent(action: .operation, confidence: 0.9, operation: OperationCall("layerVia", args: ["mode": "copy"], source: .grammar))
        let run = await SelectionOperationTests.execute(intent, on: document, services: SelectionOperationTests.services(), french: true)
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertTrue(run.result.effects.contains(ExecutionReason.needsSelection.effect))
        XCTAssertEqual(run.after, document)
    }

    // MARK: Add image

    func testAddImageLayerOpensThePickerWithItsOptions() async throws {
        let run = try await Self.model("addImageLayer", ["fit": "fill"])
        XCTAssertEqual(run.after, run.before)
        XCTAssertTrue(Self.messages(run).contains("pickImageLayer"))
        XCTAssertTrue(Self.messages(run).contains { $0.hasPrefix("pickImageLayerOptions:") && $0.contains("fill") }, "\(Self.messages(run))")
    }

    // MARK: The flags

    func testTheFlagsGateTheLayerOperations() {
        func flags(off: Set<FeatureFlag>) -> (FeatureFlag) -> Bool { { !off.contains($0) } }
        XCTAssertFalse(OperationGate.isEnabled("addFillLayer", flags: flags(off: [.layerOps])))
        XCTAssertFalse(OperationGate.isEnabled("layerTransform", flags: flags(off: [.layerOps])))
        XCTAssertFalse(OperationGate.isEnabled("exportPhoto", flags: flags(off: [.layerOps])))
        XCTAssertFalse(OperationGate.isEnabled("exportPhoto", flags: flags(off: [.proExport])))
        XCTAssertFalse(OperationGate.isEnabled("layerMask", flags: flags(off: [.proLayers])))
        XCTAssertTrue(OperationGate.isEnabled("layerTransform", flags: flags(off: [.proLayers])), "transforms need only layerOps")
        XCTAssertTrue(OperationGate.isEnabled("addImageLayer", flags: flags(off: [.proLayers])))
        XCTAssertFalse(OperationGate.isEnabled("recipe", flags: flags(off: [.recipes])))
        XCTAssertTrue(OperationGate.isEnabled("curves", flags: flags(off: [.layerOps, .proLayers, .recipes])), "W1 ops stay")
        for id in OperationGate.layerOperations.union(["recipe", "exportPhoto"]) { XCTAssertTrue(OperationGate.isEnabled(id), "W3 flags default on: \(id)") }
    }
}
