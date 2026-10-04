import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W3 (§8.3): which postconditions a layer call answers for, the new structural probes, and the pixel probe requests
/// chosen per call.
final class LayerPostconditionTests: XCTestCase {
    static func conditions(_ id: OpID, _ args: [String: OpValue]) throws -> [Postcondition] {
        let spec = try XCTUnwrap(OperationCatalog.shared.spec(id))
        return LayerPostconditions.conditions(for: OperationCall(id, args: args, source: .model), spec: spec)
    }

    static func probes(_ conditions: [Postcondition]) -> [String] {
        conditions.map { condition in
            switch condition {
            case .structural(let probe, let expectation): return "\(probe):\(expectation)"
            case .pixels(let name, let expectation): return "pixels.\(name):\(expectation)"
            case .unverifiable: return "unverifiable"
            }
        }
    }

    func testMergeModesPickTheirCountDirection() throws {
        let stamp = Self.probes(try Self.conditions("mergeLayers", ["mode": "stamp"]))
        XCTAssertTrue(stamp.contains("layerCount:increased"), "\(stamp)")
        XCTAssertFalse(stamp.contains("layerCount:decreased"))
        let down = Self.probes(try Self.conditions("mergeLayers", ["mode": "down"]))
        XCTAssertTrue(down.contains("layerCount:decreased"), "\(down)")
        XCTAssertFalse(down.contains("layerCount:increased"))
    }

    func testLayerMaskActions() throws {
        XCTAssertEqual(Self.probes(try Self.conditions("layerMask", ["do": "paint"])), ["unverifiable"])
        let add = Self.probes(try Self.conditions("layerMask", ["do": "add", "where": "subject"]))
        XCTAssertTrue(add.contains { $0.hasPrefix("layerMasks:") } && add.contains { $0.hasPrefix("pixels.layerMaskCoverageInRange") }, "\(add)")
        let apply = Self.probes(try Self.conditions("layerMask", ["do": "apply"]))
        XCTAssertTrue(apply.contains { $0.hasPrefix("pixels.compositeUnchanged") }, "\(apply)")
        let invert = Self.probes(try Self.conditions("layerMask", ["do": "invert"]))
        XCTAssertFalse(invert.contains { $0.hasPrefix("pixels.") }, "\(invert)")
    }

    func testPropertiesAndTransformsCheckWhatTheyChange() throws {
        XCTAssertEqual(Self.probes(try Self.conditions("layerProperties", ["fill": 40])).filter { !$0.hasPrefix("unverifiable") }.count, 1)
        XCTAssertTrue(Self.probes(try Self.conditions("layerProperties", ["lock": "all"])).contains { $0.hasPrefix("layerLock") })
        XCTAssertEqual(Self.probes(try Self.conditions("layerProperties", ["name": "Produit"])), ["unverifiable"])
        XCTAssertTrue(Self.probes(try Self.conditions("layerTransform", ["dx": 40])).contains { $0.hasPrefix("layerTransform") })
        XCTAssertEqual(Self.probes(try Self.conditions("layerTransform", ["mode": "distort"])), ["unverifiable"], "the handles: the person drags")
        XCTAssertEqual(Self.probes(try Self.conditions("groupLayers", ["ref": "g1", "collapse": true])), ["unverifiable"])
    }

    /// The pixel probes requested per call (§8.3): composite unchanged after merges and applies, changed after a new
    /// fill or a non-neutral adjustment layer, coverage for a new mask.
    /// §4.8: compositeUnchanged is per pixel. A square that moved keeps the frame's mean colour and spread, so only
    /// the per-pixel delta catches it; an identical frame passes both ways.
    func testCompositeUnchangedIsJudgedPerPixel() {
        let side = 32
        func frame(squareAt origin: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: side * side * 4)
            for y in 0..<side {
                for x in 0..<side {
                    let i = (y * side + x) * 4
                    let inside = (origin..<(origin + 8)).contains(x) && (origin..<(origin + 8)).contains(y)
                    bytes[i] = inside ? 220 : 128
                    bytes[i + 1] = inside ? 30 : 128
                    bytes[i + 2] = inside ? 40 : 128
                    bytes[i + 3] = 255
                }
            }
            return bytes
        }
        let before = frame(squareAt: 4), moved = frame(squareAt: 20)
        let whole = [Float](repeating: 1, count: side * side)
        let request = PixelProbeRequest(.compositeUnchanged, region: .whole)
        let plan = PixelPostconditions.Plan(checks: [PixelPostconditions.Check(request, .composite(changed: false))])
        let regionsBefore = PixelStats.regions(rgba: before, width: side, height: side, mask: whole)
        let regionsMoved = PixelStats.regions(rgba: moved, width: side, height: side, mask: whole)

        let means = PixelPostconditions.evaluate(plan, results: [PixelProbeResult(request: request, before: regionsBefore, after: regionsMoved)])
        XCTAssertEqual(means.report.passed, 1, "the means alone cannot see the move")

        let delta = PixelStats.compositeDelta(before: before, after: moved, width: side, height: side)
        XCTAssertNotNil(delta)
        let perPixel = PixelPostconditions.evaluate(plan, results: [PixelProbeResult(request: request, before: regionsBefore, after: regionsMoved, compositeDelta: delta)])
        XCTAssertEqual(perPixel.report.passed, 0)
        XCTAssertEqual(perPixel.report.failures.count, 1, "\(perPixel.report)")

        let same = PixelStats.compositeDelta(before: before, after: before, width: side, height: side)
        XCTAssertEqual(same?.mean, 0)
        XCTAssertEqual(same?.p99, 0)
        let unchanged = PixelPostconditions.evaluate(plan, results: [PixelProbeResult(request: request, before: regionsBefore, after: regionsBefore, compositeDelta: same)])
        XCTAssertEqual(unchanged.report.passed, 1)
        XCTAssertNil(PixelStats.compositeDelta(before: before, after: Array(moved.prefix(10)), width: side, height: side))
    }

    func testPixelRequestsPerCall() async throws {
        let fill = try await LayerOperationTests.model("addFillLayer", ["fill": "solid", "color": "white"])
        let fillPlan = try XCTUnwrap(PixelPostconditions.plan(for: OperationCall("addFillLayer", args: ["fill": "solid", "color": "white"], source: .model),
                                                              before: fill.before, after: fill.after))
        XCTAssertEqual(fillPlan.requests.map(\.probe), [.compositeChanged])

        let neutral = try await LayerOperationTests.model("addAdjustmentLayer", ["kind": "hsl"])
        let neutralPlan = try XCTUnwrap(PixelPostconditions.plan(for: OperationCall("addAdjustmentLayer", args: ["kind": "hsl"], source: .model),
                                                                 before: neutral.before, after: neutral.after))
        XCTAssertTrue(neutralPlan.requests.isEmpty)
        XCTAssertFalse(neutralPlan.unverifiable.isEmpty, "a neutral adjustment layer changes nothing yet")

        let stamp = try await LayerOperationTests.model("mergeLayers", ["mode": "stamp"])
        let stampPlan = try XCTUnwrap(PixelPostconditions.plan(for: OperationCall("mergeLayers", args: ["mode": "stamp"], source: .model),
                                                               before: stamp.before, after: stamp.after))
        XCTAssertEqual(stampPlan.requests.map(\.probe), [.compositeUnchanged])

        let mask = try await LayerOperationTests.model("layerMask", ["do": "add", "where": "subject", "layer": "i2"])
        let maskPlan = try XCTUnwrap(PixelPostconditions.plan(for: OperationCall("layerMask", args: ["do": "add", "where": "subject", "layer": "i2"], source: .model),
                                                              before: mask.before, after: mask.after))
        XCTAssertEqual(maskPlan.requests.map(\.probe), [.layerMaskCoverageInRange])
    }

    /// The structural probes read the call's own layer: a fill change on j1, a lock on i1, a transform on i1.
    func testStructuralProbesReadTheCallsLayer() async throws {
        let fill = try await LayerOperationTests.model("layerProperties", ["ref": "j1", "fill": 30])
        XCTAssertEqual(OperationPostconditions.check(fill.intent, before: fill.before, after: fill.after).failed, [])
        let lock = try await LayerOperationTests.model("layerProperties", ["ref": "i1", "lock": "position"])
        XCTAssertEqual(OperationPostconditions.check(lock.intent, before: lock.before, after: lock.after).failed, [])
        // The same call checked against an unchanged document fails: the probe reads the right layer.
        XCTAssertFalse(OperationPostconditions.check(lock.intent, before: lock.before, after: lock.before).failed.isEmpty)
        let move = try await LayerOperationTests.model("layerTransform", ["ref": "i1", "dx": 40])
        XCTAssertEqual(OperationPostconditions.check(move.intent, before: move.before, after: move.after).failed, [])
        XCTAssertFalse(OperationPostconditions.check(move.intent, before: move.before, after: move.before).failed.isEmpty)
    }
}
