import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (D19, §8.5): after a step that changes the photo's geometry, later steps aim where their targets went:
/// M = inverse(old chain) ∘ new chain, the map the masks and the layers move with (MaskGeometry).
final class RegroundingTests: XCTestCase {
    /// 4:3 photo → 4:5 crop (the middle 60 %), a quarter turn, a horizontal flip.
    static let steps: [EditOperation.Kind] = [.crop(PSRect(x: 0.2, y: 0, width: 0.6, height: 1)), .rotate(degrees: 90), .flip(.horizontal)]

    static func edited(_ kinds: [EditOperation.Kind], on document: PhotoDocument = OperationFixtures.photoWithLayers()) -> PhotoDocument {
        var copy = document
        guard let base = copy.baseLayerID else { return copy }
        copy.update(layerID: base) { layer in for kind in kinds { layer.edits.append(kind) } }
        return copy
    }

    /// The chain step by step, as MaskGeometry defines each edit.
    static func expectedMap(_ kinds: [EditOperation.Kind], aspect: Double) -> PSHomography {
        var map = PSHomography.identity
        var current = aspect
        for kind in kinds {
            if let step = kind.geometryMap(aspectBefore: current) { map = map.then(step) }
            current = kind.aspect(after: current)
        }
        return map
    }

    func testTheMapIsTheGeometryChain() throws {
        let before = OperationFixtures.photoWithLayers()
        let after = Self.edited(Self.steps, on: before)
        let map = try XCTUnwrap(RefRegrounder.geometryMap(from: before, to: after))
        let expected = Self.expectedMap(Self.steps, aspect: 4.0 / 3.0)
        for point in [PSPoint(x: 0.3, y: 0.2), PSPoint(x: 0.5, y: 0.5), PSPoint(x: 0.75, y: 0.9)] {
            let got = map.apply(point), want = expected.apply(point)
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
        XCTAssertNil(RefRegrounder.geometryMap(from: before, to: before), "no geometry change, no map")
        var toned = before
        if let base = toned.baseLayerID { toned.update(layerID: base) { $0.edits.append(.adjust(.exposure, value: 0.2)) } }
        XCTAssertNil(RefRegrounder.geometryMap(from: before, to: toned), "a tone edit moves nothing")
    }

    /// A box after the crop, the turn and the flip lands where the chain maps its corners (1e-9).
    func testABoxLandsWhereTheChainMapsIt() throws {
        let before = OperationFixtures.photoWithLayers()
        let after = Self.edited(Self.steps, on: before)
        let map = try XCTUnwrap(RefRegrounder.geometryMap(from: before, to: after))
        let expected = Self.expectedMap(Self.steps, aspect: 4.0 / 3.0)
        let call = OperationCall("layerMask", args: ["do": "add", "box": .list([400, 300, 500, 450]), "layer": "i2"], source: .model)
        let moved = try XCTUnwrap(RefRegrounder.regrounded(call, by: map))
        let corners = [PSPoint(x: 0.4, y: 0.3), PSPoint(x: 0.5, y: 0.3), PSPoint(x: 0.5, y: 0.45), PSPoint(x: 0.4, y: 0.45)].map(expected.apply)
        let want = PSRect(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!, width: corners.map(\.x).max()! - corners.map(\.x).min()!,
                          height: corners.map(\.y).max()! - corners.map(\.y).min()!)
        guard case .box(let got)? = moved.args["box"] else { return XCTFail("\(String(describing: moved.args["box"]))") }
        XCTAssertEqual(got.minX / 1000, want.minX, accuracy: 1e-9)
        XCTAssertEqual(got.minY / 1000, want.minY, accuracy: 1e-9)
        XCTAssertEqual(got.width / 1000, want.width, accuracy: 1e-9)
        XCTAssertEqual(got.height / 1000, want.height, accuracy: 1e-9)
        XCTAssertEqual(moved.args["layer"], .string("i2"), "refs name things, not places: untouched")
    }

    func testPointsAndRegionsMoveCurvesDoNot() throws {
        let before = OperationFixtures.photoWithLayers()
        let map = try XCTUnwrap(RefRegrounder.geometryMap(from: before, to: Self.edited([.flip(.horizontal)], on: before)))
        let center = try XCTUnwrap(RefRegrounder.regrounded(OperationCall("layerTransform", args: ["center": .list([200, 500])], source: .model), by: map))
        XCTAssertEqual(center.args["center"], .point(PSPoint(x: 800, y: 500)))
        let curve = OperationCall("curves", args: ["points": .list([.list([0, 0]), .list([250, 300]), .list([1000, 1000])])], source: .model)
        XCTAssertEqual(RefRegrounder.regrounded(curve, by: map), curve, "a curve's points are tones")
        var intent = EditIntent(action: .removeObject, target: ObjectTarget(label: "dog", point: PSPoint(x: 0.25, y: 0.5)))
        intent.region = PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let moved = try XCTUnwrap(RefRegrounder.regrounded(intent, by: map))
        XCTAssertEqual(moved.target?.point?.x ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(moved.region?.minX ?? 0, 0.7, accuracy: 1e-9)
    }

    /// What was cropped out answers honestly, and the run stops there.
    func testABoxCroppedOutAnswersHonestly() async throws {
        let before = OperationFixtures.photoWithLayers()
        let map = try XCTUnwrap(RefRegrounder.geometryMap(from: before, to: Self.edited([Self.steps[0]], on: before)))
        let outside = OperationCall("layerMask", args: ["do": "add", "box": .list([20, 100, 150, 300]), "layer": "i2"], source: .model)
        XCTAssertNil(RefRegrounder.regrounded(outside, by: map))
        XCTAssertEqual(RefRegrounder.leftTheCanvas(french: true), "Ce que tu visais n'est plus dans le cadre.")

        let crop = EditIntent(action: .crop, aspect: .ratio4x5)
        let mask = EditIntent(action: .operation, confidence: 0.9, operation: outside)
        let executor = PhotoCommandExecutor(services: SelectionOperationTests.services(), language: .french)
        let (after, results) = await executor.execute(steps: [crop, mask], on: before, context: OperationFixtures.photoContext(before))
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].outcome.isSuccess, "\(results[0].outcome)")
        XCTAssertEqual(results[1].outcome.message, "Ce que tu visais n'est plus dans le cadre.")
        XCTAssertTrue(results[1].effects.contains(ExecutionReason.badRegion.effect))
        XCTAssertNil(after.layer(id: OperationFixtures.logoID)?.maskStack, "nothing was masked")
    }

    /// The plan's later step aims at the moved place: a box inside the kept part lands inside the new canvas.
    func testAPlanAfterACropAimsWhereTheTargetWent() async throws {
        let before = OperationFixtures.photoWithLayers()
        let crop = EditIntent(action: .crop, aspect: .ratio4x5)
        let inside = EditIntent(action: .operation, confidence: 0.9,
                                operation: OperationCall("layerMask", args: ["do": "add", "box": .list([450, 300, 550, 600]), "layer": "i2"], source: .model))
        let executor = PhotoCommandExecutor(services: SelectionOperationTests.services(), language: .french)
        let (after, results) = await executor.execute(steps: [crop, inside], on: before, context: OperationFixtures.photoContext(before))
        XCTAssertTrue(results.allSatisfy(\.outcome.isSuccess), "\(results.map(\.outcome))")
        XCTAssertNotNil(after.layer(id: OperationFixtures.logoID)?.maskStack)
    }
}
