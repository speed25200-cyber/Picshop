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

    // MARK: Parameter-aware readings (the real renders: PixelProbeRenderTests)

    private func judged(_ parameter: AdjustmentParameter, direction: Int, before: PixelStats.Regions, after: PixelStats.Regions) -> PixelPostconditions.Verdict {
        let request = PixelProbeRequest(.maskedParameter, region: .localAdjustment(UUID()))
        let check = PixelPostconditions.Check(request, .parameter(parameter, direction: direction, amount: 60))
        return PixelPostconditions.evaluate(PixelPostconditions.Plan(checks: [check]),
                                            results: [PixelProbeResult(request: request, before: before, after: after)])
    }

    private func regions(_ inside: PixelStats, outside: PixelStats = PixelStats(meanL: 40, stdL: 10, meanChroma: 12, meanA: 2, meanB: 8, weight: 1000)) -> PixelStats.Regions {
        PixelStats.Regions(inside: inside, outside: outside, coverage: 0.3)
    }

    func testWhitesAreReadOnTheHighlights() {
        // Whites moved the brightest quarter by 1.8 and the mean by 0.45 (they leave the rest alone): passed.
        let bright = PixelStats(meanL: 45, stdL: 20, meanChroma: 12, weight: 500, highL: 75, lowL: 12)
        var lifted = bright
        lifted.meanL += 0.45
        lifted.highL += 1.8
        XCTAssertEqual(judged(.whites, direction: 1, before: regions(bright), after: regions(lifted)).report.passed, 1)
        // The wrong way: failed.
        XCTAssertEqual(judged(.whites, direction: -1, before: regions(bright), after: regions(lifted)).report.failed.count, 1)
        // A region with highlights that whites did not move: failed.
        XCTAssertEqual(judged(.whites, direction: 1, before: regions(bright), after: regions(bright)).report.failed.count, 1)
        // A region without highlights (brightest quarter at L* 50) barely moves: unverifiable, not failed.
        let dark = PixelStats(meanL: 27, stdL: 15, meanChroma: 12, weight: 500, highL: 50, lowL: 8)
        var nudged = dark
        nudged.highL += 0.1
        let verdict = judged(.whites, direction: 1, before: regions(dark), after: regions(nudged))
        XCTAssertEqual(verdict.report.failed, [])
        XCTAssertEqual(verdict.report.unverifiable, 1)
        // Moved the wrong way by the bar there: still failed.
        nudged.highL = dark.highL - 1
        XCTAssertEqual(judged(.whites, direction: 1, before: regions(dark), after: regions(nudged)).report.failed.count, 1)
        // Exposure is read on the whole region as before.
        XCTAssertEqual(judged(.exposure, direction: 1, before: regions(bright), after: regions(lifted)).report.failed.count, 1)
    }

    func testALeakIsReadOnWhatTheParameterMoves() {
        // Warmth applied to the whole picture: b* moved outside as much as inside, L* barely.
        let inside = PixelStats(meanL: 50, stdL: 18, meanChroma: 20, meanA: 4, meanB: 12, weight: 500)
        let outside = PixelStats(meanL: 40, stdL: 10, meanChroma: 12, meanA: 2, meanB: 8, weight: 1000)
        var warmIn = inside, warmOut = outside
        warmIn.meanB += 7
        warmOut.meanB += 7
        let leak = judged(.temperature, direction: 1, before: regions(inside, outside: outside), after: regions(warmIn, outside: warmOut))
        XCTAssertEqual(leak.report.failed.count, 1)
        XCTAssertTrue(leak.report.failed[0].contains("b*"), "\(leak.report.failed)")
        // Inside only: passed.
        XCTAssertEqual(judged(.temperature, direction: 1, before: regions(inside, outside: outside), after: regions(warmIn, outside: outside)).report.passed, 1)
    }

    func testVibranceThatMovedLittleIsUnverifiable() {
        let inside = PixelStats(meanL: 50, stdL: 18, meanChroma: 20, weight: 500)
        var spared = inside
        spared.meanChroma -= 0.7
        let little = judged(.vibrance, direction: -1, before: regions(inside), after: regions(spared))
        XCTAssertEqual(little.report.failed, [])
        XCTAssertEqual(little.report.unverifiable, 1)
        // Not at all, or the wrong way: failed.
        XCTAssertEqual(judged(.vibrance, direction: -1, before: regions(inside), after: regions(inside)).report.failed.count, 1)
        XCTAssertEqual(judged(.vibrance, direction: 1, before: regions(inside), after: regions(spared)).report.failed.count, 1)
        // Saturation is not spared: the same move fails.
        XCTAssertEqual(judged(.saturation, direction: -1, before: regions(inside), after: regions(spared)).report.failed.count, 1)
    }
}
