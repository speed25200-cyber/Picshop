import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D14 (§8.7): the pixel postconditions, calibrated on a generated set on the fake host: no false "failed" over
/// ≥ 160 correct edits, and ≥ 90 % of ≥ 40 sabotaged edits caught.
final class PixelPostconditionTests: XCTestCase {
    static let regions: [MaskRegion] = [.sky, .subject, .background, .people, .vegetation, .water, .top, .bottom, .left, .right, .center, .edges,
                                        .shadows, .midtones, .highlights]
    static let dials: [(AdjustmentParameter, Double)] = [(.exposure, 20), (.exposure, -20), (.brightness, 15), (.contrast, 25), (.saturation, 20),
                                                         (.saturation, -20), (.temperature, 20), (.temperature, -20), (.clarity, 20), (.vibrance, 25),
                                                         (.shadows, 20)]

    func testCorrectEditsNeverFail() async {
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .english)
        var total = 0
        var falseFailures: [String] = []
        for region in Self.regions {
            for (parameter, amount) in Self.dials {
                let call = OperationCall("maskAdjust", args: ["where": .string(region.rawValue), "parameter": .string(parameter.rawValue), "amount": .number(amount)])
                let document = OperationFixtures.photo()
                let (after, result) = await executor.execute(EditIntent(action: .operation, operation: call), on: document,
                                                             context: OperationFixtures.photoContext(document))
                guard result.outcome.isSuccess else { falseFailures.append("\(region) \(parameter) \(amount): \(result.outcome)"); continue }
                total += 1
                if let report = OperationPostconditions.report(in: result.effects), !report.failed.isEmpty {
                    falseFailures.append("\(region) \(parameter) \(amount): \(report.failed)")
                }
                XCTAssertEqual(after.localAdjustments.count, 1)
            }
        }
        XCTAssertGreaterThanOrEqual(total, 160)
        XCTAssertEqual(falseFailures, [], "false failures")
    }

    /// An edit that did the wrong thing: the dial the wrong way, no dial at all, or a mask over the whole picture.
    func testSabotagedEditsAreCaught() async {
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .english)
        var total = 0, caught = 0
        var missed: [String] = []
        for region in Self.regions {
            let before = OperationFixtures.photo()
            let call = OperationCall("maskAdjust", args: ["where": .string(region.rawValue), "parameter": "exposure", "amount": 20])
            for sabotage in ["wrongWay", "noDial", "wholePicture"] {
                var after = before
                let stack: MaskStack
                if sabotage == "wholePicture" || region.isAI {
                    let coverage = sabotage == "wholePicture" ? 0.995 : 0.3
                    let raster = MaskSimulation.raster(.sky, label: nil, key: "sabotage-\(region)-\(sabotage)", coverage: coverage, document: before)
                    stack = MaskStack.single(MaskComponent(.raster(raster)))
                } else {
                    stack = MaskStack.single(MaskStack.defaultComponent(for: region, aspect: before.localAdjustmentsAspect)!)
                }
                let dials: Adjustments
                switch sabotage {
                case "wrongWay": dials = Adjustments([.exposure: -0.6])
                case "noDial": dials = .neutral
                default: dials = Adjustments([.exposure: 0.6])
                }
                after.setLocalAdjustment(LocalAdjustment(region: region, stack: stack, adjustments: dials), label: "Mask")
                total += 1
                let verdict = await executor.pixelVerdict(PixelPostconditions.plan(for: call, before: before, after: after), before: before, after: after)
                if !verdict.report.failed.isEmpty { caught += 1 } else { missed.append("\(region) \(sabotage)") }
            }
        }
        XCTAssertGreaterThanOrEqual(total, 40)
        XCTAssertGreaterThanOrEqual(Double(caught) / Double(total), 0.9, "missed: \(missed)")
    }

    func testTheThresholdsAreTheContracts() {
        XCTAssertEqual(PixelPostconditions.lightness, 0.8)
        XCTAssertEqual(PixelPostconditions.contrast, 0.4)
        XCTAssertEqual(PixelPostconditions.coverageRange, 0.002...0.98)
        XCTAssertEqual(PixelPostconditions.boxShare, 0.5)
    }

    /// Without probes (a host that measures nothing) a check is unverifiable, never failed.
    func testNoMeasureIsUnverifiableNotFailed() async {
        let before = OperationFixtures.photo()
        var after = before
        let raster = MaskSimulation.raster(.sky, label: nil, key: "none", coverage: 0.3, document: before)
        after.setLocalAdjustment(LocalAdjustment(region: .sky, stack: MaskStack.single(MaskComponent(.raster(raster))), adjustments: Adjustments([.exposure: 0.6])),
                                 label: "Mask")
        let call = OperationCall("maskAdjust", args: ["where": "sky", "parameter": "exposure", "amount": 20])
        let plan = PixelPostconditions.plan(for: call, before: before, after: after)
        XCTAssertFalse(plan.checks.isEmpty)
        let verdict = PixelPostconditions.evaluate(plan, results: nil)
        XCTAssertEqual(verdict.report.failed, [])
        XCTAssertFalse(verdict.reasons.isEmpty)
    }

    /// A step that adds an expensive edit (erase, fill, generate) is not rendered before the verdict.
    func testExpensiveStepsAreUnverifiable() async {
        let document = OperationFixtures.photoWithMasks()
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .english)
        let call = OperationCall("selectionApply", args: ["use": "generate", "prompt": "flowers"])
        let (after, result) = await executor.execute(EditIntent(action: .operation, operation: call), on: document, context: OperationFixtures.photoContext(document))
        guard result.outcome.isSuccess else { return }
        let plan = PixelPostconditions.plan(for: call, before: document, after: after)
        XCTAssertTrue(plan.checks.isEmpty)
        XCTAssertFalse(plan.unverifiable.isEmpty)
    }
}
