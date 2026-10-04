import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (§8.3, D8): `layerMask`, every action, on the layered poster: i1 « Tasse » has a radial mask, i2 « Logo » none.
final class LayerMaskOperationTests: XCTestCase {
    typealias Run = SelectionOperationTests.Run

    static func model(_ args: [String: OpValue], on document: PhotoDocument = OperationFixtures.photoWithLayers(), french: Bool = true) async throws -> Run {
        try await LayerOperationTests.model("layerMask", args, on: document, french: french)
    }

    static func layer(_ ref: String, _ run: Run) -> Layer? { LayerOperationTests.layer(ref, run.after) }

    func testAddFromTheSubjectOnTheLogo() async throws {
        let run = try await Self.model(["do": "add", "where": "subject", "layer": "i2"])
        SelectionOperationTests.assertVerified(run, "add subject i2")
        let stack = try XCTUnwrap(Self.layer("i2", run)?.maskStack)
        XCTAssertEqual(stack.components.count, 1)
        XCTAssertFalse(stack.isInverted)
        XCTAssertEqual(run.result.label, "Add Layer Mask")
        XCTAssertTrue(LayerOperationTests.spoken(run).contains { $0.contains("i2") }, "\(LayerOperationTests.spoken(run))")
    }

    func testHideTheTopOfTheLogo() async throws {
        let run = try await Self.model(["do": "add", "where": "top", "reveal": false, "layer": "i2"])
        SelectionOperationTests.assertVerified(run, "hide the top")
        XCTAssertEqual(Self.layer("i2", run)?.maskStack?.isInverted, true)
    }

    func testASecondMaskIsRefusedWithTheWayOut() async throws {
        let run = try await Self.model(["do": "add", "where": "subject", "layer": "i1"])
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertTrue((run.result.outcome.message ?? "").contains("déjà un masque"), "\(run.result.outcome)")
        XCTAssertEqual(run.after, run.before)
    }

    func testRevealAllWithoutAnAreaAndTheSelectionWhenThereIsOne() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.setSelection(nil)
        let revealAll = try await Self.model(["do": "add", "layer": "i2"], on: document)
        XCTAssertTrue(revealAll.result.outcome.isSuccess, "\(revealAll.result.outcome)")
        XCTAssertNotNil(Self.layer("i2", revealAll)?.maskStack)
        XCTAssertFalse(revealAll.result.effects.contains(.message("selectionUsed")))

        let fromSelection = try await Self.model(["do": "add", "layer": "i2"])
        XCTAssertTrue(fromSelection.result.outcome.isSuccess, "\(fromSelection.result.outcome)")
        XCTAssertTrue(fromSelection.result.effects.contains(.message("selectionUsed")), "the selection is consumed")
    }

    func testInvertDisableEnableDelete() async throws {
        let invert = try await Self.model(["do": "invert", "layer": "i1"])
        SelectionOperationTests.assertVerified(invert, "invert")
        XCTAssertEqual(Self.layer("i1", invert)?.maskStack?.isInverted, true)

        let disable = try await Self.model(["do": "disable", "layer": "i1"])
        SelectionOperationTests.assertVerified(disable, "disable")
        XCTAssertEqual(Self.layer("i1", disable)?.isMaskEnabled, false)
        let enable = try await Self.model(["do": "enable", "layer": "i1"], on: disable.after)
        XCTAssertTrue(enable.result.outcome.isSuccess)
        XCTAssertEqual(Self.layer("i1", enable)?.isMaskEnabled, true)
        let again = try await Self.model(["do": "enable", "layer": "i1"])
        XCTAssertFalse(again.result.outcome.isSuccess, "already enabled: said, not a history step")

        let delete = try await Self.model(["do": "delete", "layer": "i1"])
        SelectionOperationTests.assertVerified(delete, "delete")
        XCTAssertNil(Self.layer("i1", delete)?.maskStack)
    }

    func testActionsOtherThanAddNeedAMask() async throws {
        let run = try await Self.model(["do": "invert", "layer": "i2"])
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertTrue((run.result.outcome.message ?? "").contains("n'a pas de masque"), "\(run.result.outcome)")
    }

    func testEditFeatherAndCombine() async throws {
        let feather = try await Self.model(["do": "edit", "feather": 60, "layer": "i1"])
        SelectionOperationTests.assertVerified(feather, "feather")
        XCTAssertEqual(Self.layer("i1", feather)?.maskStack?.feather ?? 0, 0.6, accuracy: 1e-9)

        let before = try XCTUnwrap(OperationFixtures.photoWithLayers().layer(id: OperationFixtures.cupID)?.maskStack)
        let combine = try await Self.model(["do": "edit", "combine": "add", "where": "sky", "layer": "i1"])
        XCTAssertTrue(combine.result.outcome.isSuccess, "\(combine.result.outcome)")
        XCTAssertEqual(Self.layer("i1", combine)?.maskStack?.components.count, before.components.count + 1)
    }

    /// Apply bakes the mask into the layer's pixels through `rasterizeLayers` (the fake host's synthetic asset).
    func testApplyRasterizesTheLayer() async throws {
        let run = try await Self.model(["do": "apply", "layer": "i1"])
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let cup = try XCTUnwrap(Self.layer("i1", run))
        XCTAssertTrue(cup.imageAsset?.relativePath.hasPrefix("media/raster-") ?? false, "\(String(describing: cup.imageAsset))")
        XCTAssertNil(cup.maskStack)
        XCTAssertEqual(run.result.label, "Apply Layer Mask")
        // Apply on a layer that is not a photo is refused.
        let fill = try await Self.model(["do": "apply", "layer": "j1"])
        XCTAssertFalse(fill.result.outcome.isSuccess)
    }

    func testPaintOpensTheBrushAndChangesNothing() async throws {
        var document = OperationFixtures.photoWithLayers()
        document.selectedLayerID = OperationFixtures.logoID
        let run = try await Self.model(["do": "paint"], on: document)
        XCTAssertEqual(run.after, document)
        XCTAssertTrue(LayerOperationTests.messages(run).contains("paintLayerMask:\(OperationFixtures.logoID.uuidString)"))
        XCTAssertTrue(LayerOperationTests.spoken(run).contains { $0.contains("blanc révèle") })
    }

    /// The coverage gate: an area the picture does not show is said, and no mask is made.
    func testAnAreaThatIsNotThereIsSaidSo() async throws {
        var services = SelectionOperationTests.services()
        services.masks.absent = [.sky]
        let run = try await SelectionOperationTests.model("layerMask", ["do": "add", "where": "sky", "layer": "i2"], on: OperationFixtures.photoWithLayers(),
                                                          services: services)
        XCTAssertFalse(run.result.outcome.isSuccess, "\(run.result.outcome)")
        XCTAssertTrue((run.result.outcome.message ?? "").contains("ciel"), "\(run.result.outcome)")
        XCTAssertEqual(run.after, run.before)
    }

    /// D8: a mask made on the photo (canvas space) for a placed, scaled layer lands in the layer's content space.
    func testAMaskFromTheSelectionLandsInTheLayersContentSpace() async throws {
        let document = OperationFixtures.photoWithLayers()
        let selection = try XCTUnwrap(document.selection)
        let logo = try XCTUnwrap(document.layer(id: OperationFixtures.logoID))
        let size = try XCTUnwrap(LayerPlacement.contentSize(of: logo, canvasSize: document.canvasSize))
        let inverse = try XCTUnwrap(LayerPlacement.inverseMap(for: logo, contentSize: size, canvasSize: document.canvasSize, isBase: false))
        let run = try await Self.model(["do": "add", "useSelection": true, "layer": "i2"], on: document)
        XCTAssertTrue(run.result.outcome.isSuccess, "\(run.result.outcome)")
        let component = try XCTUnwrap(Self.layer("i2", run)?.maskStack?.components.first)
        guard case .raster(let raster) = component.kind else { return XCTFail("\(component.kind)") }
        for (got, want) in zip(raster.corners, selection.raster.corners.map(inverse.apply)) {
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
    }

    /// A lock on the layer refuses mask edits (D7: masks ← all).
    func testALockedLayerKeepsItsMask() async throws {
        let locked = try await LayerOperationTests.model("layerProperties", ["ref": "i1", "lock": "all"])
        let run = try await Self.model(["do": "delete", "layer": "i1"], on: locked.after)
        XCTAssertFalse(run.result.outcome.isSuccess)
        XCTAssertTrue((run.result.outcome.message ?? "").contains("verrouillé"), "\(run.result.outcome)")
        XCTAssertEqual(run.after, locked.after)
    }
}
