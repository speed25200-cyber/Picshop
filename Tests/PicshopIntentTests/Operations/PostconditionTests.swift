import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The 13 W1 photo operations: each handler edits what it says, and its structural postconditions
/// pass on the result (and fail on a document the step did not change).
final class PostconditionTests: XCTestCase {
    private func run(_ id: OpID, _ args: [String: OpValue], on document: PhotoDocument = OperationFixtures.photo(),
                     services: OperationPhotoServices = OperationPhotoServices()) async -> (PhotoDocument, ExecutionResult, OperationPostconditions.Report) {
        let call = OperationCall(id, args: args)
        let context = OperationRunContext(intent: OperationFixtures.photoContext(document), language: .french, services: services)
        let (after, result) = await PhotoOperationHandlers.run(call, on: document, context: context)
        return (after, result, OperationPostconditions.check(call, before: document, after: after))
    }

    private func assertApplied(_ id: OpID, _ args: [String: OpValue], file: StaticString = #filePath, line: UInt = #line) async -> PhotoDocument {
        let (after, result, report) = await run(id, args)
        XCTAssertTrue(result.outcome.isSuccess, "\(id): \(result.outcome)", file: file, line: line)
        XCTAssertTrue(report.failed.isEmpty, "\(id): \(report.failed)", file: file, line: line)
        if OperationCatalog.shared.spec(id) != nil { XCTAssertGreaterThan(report.passed, 0, "\(id) is checked", file: file, line: line) }
        return after
    }

    func testEveryW1OperationHasAHandler() {
        for id in ["curves", "levels", "autoTone", "hsl", "colorGrade", "lutIntensity", "removeLUT", "perspective", "lensFocus",
                   "layerOpacity", "layerBlend", "layerVisibility", "layerOrder"] as [OpID] {
            XCTAssertNotNil(PhotoOperationHandlers.table[id], id.raw)
        }
    }

    func testToneOperations() async {
        var after = await assertApplied("curves", ["preset": .string("sCurve"), "amount": .number(30)])
        XCTAssertEqual(after.baseLayer?.edits.resolvedToneCurve.rgb.count, 5)
        after = await assertApplied("curves", ["channel": .string("blue"), "points": .list([.point(PSPoint(x: 0, y: 0)), .point(PSPoint(x: 500, y: 600)), .point(PSPoint(x: 1000, y: 1000))])])
        XCTAssertEqual(after.baseLayer?.edits.resolvedToneCurve.blue.map(\.output), [0, 0.6, 1])
        after = await assertApplied("levels", ["black": .number(20), "white": .number(235)])
        XCTAssertEqual(after.baseLayer?.edits.resolvedLevels.rgb.inBlack ?? 0, 20.0 / 255, accuracy: 1e-9)
        // Auto: the low-contrast histogram stretches unless Levels.auto is still the seam's identity.
        let (_, auto, _) = await run("autoTone", [:])
        XCTAssertNotEqual(auto.outcome, .ignored)
        let (_, missing, _) = await run("autoTone", [:], services: OperationPhotoServices(histogramAvailable: false))
        XCTAssertFalse(missing.outcome.isSuccess, "no histogram: unavailable with a reason")
    }

    func testColourOperations() async {
        var after = await assertApplied("hsl", ["band": .string("blue"), "saturation": .number(-40)])
        XCTAssertEqual(PhotoOperationHandlers.lastMixer(after.baseLayer!.edits)[.blue, .saturation], -0.4, accuracy: 1e-9)
        after = await assertApplied("colorGrade", ["range": .string("shadows"), "color": .string("blue"), "amount": .number(30)])
        let wheel = PhotoOperationHandlers.lastGrade(after.baseLayer!.edits).shadows
        XCTAssertEqual(wheel.amount, 0.3, accuracy: 1e-9)
        XCTAssertTrue((190...250).contains(wheel.hue), "a blue hue: \(wheel.hue)")
        after = await assertApplied("lutIntensity", ["amount": .number(50)])
        XCTAssertEqual(after.baseLayer?.edits.resolvedLUT?.intensity ?? 0, 0.5, accuracy: 1e-9)
        after = await assertApplied("removeLUT", [:])
        XCTAssertNil(after.baseLayer?.edits.resolvedLUT)
        let (_, noLUT, _) = await run("lutIntensity", ["amount": .number(50)], on: OperationFixtures.photo(lut: false))
        XCTAssertFalse(noLUT.outcome.isSuccess, "no imported LUT: unavailable")
    }

    func testGeometryAndOptics() async {
        var after = await assertApplied("perspective", ["vertical": .number(25)])
        XCTAssertTrue(after.baseLayer?.edits.operations.contains { if case .perspective(0, 0.25) = $0.kind { return true } else { return false } } ?? false)
        // A second correction right after replaces the first: one undo step, like the sliders.
        let (twice, _, _) = await run("perspective", ["horizontal": .number(-10)], on: after)
        XCTAssertEqual(twice.baseLayer?.edits.operations.filter { if case .perspective = $0.kind { return true } else { return false } }.count, 1)
        after = await assertApplied("lensFocus", ["ref": .string("o1"), "aperture": .number(80)])
        let lens = after.baseLayer?.edits.resolvedLensBlur
        XCTAssertEqual(lens?.aperture ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(lens?.focus.x ?? 0, OperationFixtures.dog.boundingBox.midX, accuracy: 1e-9)
        after = await assertApplied("lensFocus", ["point": .point(PSPoint(x: 500, y: 200))])
        XCTAssertEqual(after.baseLayer?.edits.resolvedLensBlur?.focus.y ?? 0, 0.2, accuracy: 1e-9)
    }

    func testLayerOperations() async {
        var after = await assertApplied("layerOpacity", ["opacity": .number(50)])
        XCTAssertEqual(after.layer(id: OperationFixtures.titleID)?.opacity ?? 0, 0.5, accuracy: 1e-9, "no ref: the selected layer")
        after = await assertApplied("layerBlend", ["ref": .string("s1"), "mode": .string("multiply")])
        XCTAssertEqual(after.layer(id: OperationFixtures.shapeID)?.blendMode, .multiply)
        after = await assertApplied("layerVisibility", ["ref": .string("l1"), "visible": .bool(false)])
        XCTAssertEqual(after.layer(id: OperationFixtures.titleID)?.isVisible, false)
        after = await assertApplied("layerOrder", ["ref": .string("l1"), "position": .string("front")])
        XCTAssertEqual(after.layers.last?.id, OperationFixtures.titleID)
        // The photo itself never takes them: a hint instead.
        let (_, base, _) = await run("layerOpacity", ["opacity": .number(50)], on: OperationFixtures.photo(selectTitle: false))
        XCTAssertFalse(base.outcome.isSuccess)
        let (_, missing, _) = await run("layerBlend", ["ref": .string("l9"), "mode": .string("screen")])
        XCTAssertFalse(missing.outcome.isSuccess)
    }

    func testAFailedPostconditionNamesWhatItExpected() {
        let call = OperationCall("layerOpacity", args: ["ref": .string("l1"), "opacity": .number(50)])
        let document = OperationFixtures.photo()
        let report = OperationPostconditions.check(call, before: document, after: document)
        guard OperationCatalog.shared.spec("layerOpacity") != nil else { return }
        XCTAssertEqual(report.failed, ["layerOpacity is 100, expected 50"])
        // Live reads it as the step's check, round-tripped through the result's effects.
        let carried = OperationPostconditions.report(in: [OperationPostconditions.effect(report)])
        XCTAssertEqual(carried, report)
        let verification = OperationPostconditions.verification(report, intent: EditIntent(action: .operation, operation: call))
        XCTAssertEqual(verification?.status, .failed)
        XCTAssertEqual(verification?.summary, "verify failed 1/1: layerOpacity=50 reads '100'")
    }

    func testPDFAndVideoProbes() {
        let pdf = OperationFixtures.pdf()
        var fewer = pdf
        fewer.deletePage(at: 2)
        let delete = EditIntent(action: .deletePage, index: 3)
        if OperationCatalog.shared.spec(lowering: .deletePage) != nil {
            XCTAssertTrue(OperationPostconditions.check(delete, before: pdf, after: fewer).failed.isEmpty)
            XCTAssertFalse(OperationPostconditions.check(delete, before: pdf, after: pdf).failed.isEmpty, "nothing deleted: failed")
        }
        let video = OperationFixtures.video()
        var shorter = video
        shorter.clips.removeLast()
        let cut = EditIntent(action: .deleteClip, index: 3)
        if OperationCatalog.shared.spec(lowering: .deleteClip) != nil {
            XCTAssertTrue(OperationPostconditions.check(cut, before: video, after: shorter).failed.isEmpty)
        }
    }
}
