import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Act-then-verify, the document side: which checks a step gets, what the structural check says,
/// and the summary the model reads.
final class VerificationTests: XCTestCase {
    func testAddedTextIsCheckedWhereItLanded() async throws {
        let services = SceneFixtures.posterServices()
        let executor = PhotoCommandExecutor(services: services)
        let before = SceneFixtures.posterDocument()
        let intent = EditIntent(action: .addText, text: "Nouveau", placement: .top)
        let (after, result) = await executor.execute(intent, on: before, context: .photo)
        let request = try XCTUnwrap(EditVerifier.request(for: intent, before: before, after: after, result: result, scene: services.scene))
        XCTAssertEqual(request.checks.map(\.kind), [.textPresent])
        XCTAssertEqual(request.checks.first?.text, "Nouveau")
        XCTAssertTrue(request.checks[0].region.contains(TextElement.Placement.top.center))

        let report = try await services.verify([request], in: after)
        XCTAssertEqual(report.first?.status, .passed)
        XCTAssertEqual(report.first?.summary, "verified 1/1")

        let broken = SceneFixtures.posterServices(failingChecks: ["text"])
        let failed = try await broken.verify([request], in: after)
        XCTAssertEqual(failed.first?.status, .failed)
        XCTAssertEqual(failed.first?.summary, "verify failed 1/1: text missing")
    }

    func testEveryCellOfAFillIsChecked() throws {
        let grid = TableFixtures.benchmark()
        let before = TableFixtures.document()
        var after = before
        let group = UUID()
        for column in 1...3 {
            let cell = try XCTUnwrap(grid.cell(dataRow: 1, dataColumn: column))
            let element = TextElement(text: "1", fontName: "SFProDigits-Regular", relativeSize: 0.0156, color: .black, style: .plain, center: cell.contentRect.center)
            after.addLayer(Layer(name: "cell", content: .text(element), group: LayerGroup(id: group, kind: .tableCells, row: 1, column: column)), select: false)
        }
        let intent = EditIntent(action: .fillCells, table: TableEditSpec(rows: [.index(1)], columns: [.index(1), .index(2), .index(3)], value: .constant("1")))
        let result = ExecutionResult(outcome: .applied(label: "Fill Cells"), label: "Fill Cells")
        let request = try XCTUnwrap(EditVerifier.request(for: intent, before: before, after: after, result: result, scene: nil))
        XCTAssertEqual(request.checks.map(\.tag), ["r1c1", "r1c2", "r1c3"])

        XCTAssertEqual(EditVerifier.structural(request, in: after).summary, "verified 3/3")
        var report = EditVerifier.structural(request, in: after)
        report.items[1].outcome = .failed
        report.items[1].observed = "7"
        XCTAssertEqual(report.summary, "verify failed 1/3: r1c2 reads '7'")
        XCTAssertEqual(EditVerifier.structural(request, in: before).status, .failed, "no layer, no text")
    }

    /// « mets le titre en rouge »: the same words, rewritten in red where they were. No check wants the old words
    /// gone, so the restyle passes (and the rewrite's line never says it erased something).
    func testARestyleOfPrintedTextKeepsItsWords() async throws {
        let services = SceneFixtures.posterServices()
        let scene = SceneFixtures.posterScene()
        let before = SceneFixtures.posterDocument()
        for intent in [EditIntent(action: .editText, color: .red, ref: .text(1)),
                       EditIntent(action: .editText, confidence: 0.9, ref: .text(1), textStyle: TextStyleSpec(size: .scale(1.35)))] {
            let (after, result) = await PhotoCommandExecutor(services: services).execute(intent, on: before, context: IntentContext(mode: .photo, scene: scene))
            let request = try XCTUnwrap(EditVerifier.request(for: intent, before: before, after: after, result: result, scene: scene))
            XCTAssertFalse(request.checks.contains { $0.kind == .textAbsent }, "no check for the old words")
            XCTAssertEqual(EditVerifier.structural(request, in: after).status, .passed)
        }
        // A rewrite with new words still checks the old ones are gone, and its failure line says what happened.
        let rewrite = EditIntent(action: .editText, text: "PROMO", ref: .text(1))
        let (after, result) = await PhotoCommandExecutor(services: services).execute(rewrite, on: before, context: IntentContext(mode: .photo, scene: scene))
        let request = try XCTUnwrap(EditVerifier.request(for: rewrite, before: before, after: after, result: result, scene: scene))
        XCTAssertTrue(request.checks.contains { $0.kind == .textAbsent && $0.tag == "t1" })
        let still = VerificationReport(intentID: rewrite.id, action: .editText,
                                       items: request.checks.map { .init(check: $0, outcome: $0.kind == .textAbsent ? .failed : .passed) }, method: .pixels)
        XCTAssertEqual(LiveLines.verification(still, .french), "J'ai réécrit le texte, mais l'ancien se voit encore.")
        let erased = VerificationReport(intentID: rewrite.id, action: .removeText, items: still.items, method: .pixels)
        XCTAssertEqual(LiveLines.verification(erased, .french), "J'ai effacé, mais il reste du texte visible.")
    }

    /// « vide la colonne GPT-6 Astra » on the printed table: one check per printed cell, its old value gone; the one
    /// printed cell a fill writes over is checked too, unless the new value holds the old one.
    func testClearedCellsAreCheckedOneByOne() throws {
        let grid = TableFixtures.benchmark(withValues: true)
        let scene = SceneFixtures.benchmarkScene(withValues: true)
        let before = TableFixtures.document()
        var after = before
        after.apply(.removeObject(MaskReference(source: .object(label: "text", boundingBox: grid.dataColumns[4].rect), boundingBox: grid.dataColumns[4].rect)))
        let clear = EditIntent(action: .clearCells, table: TableEditSpec(columns: [.name("GPT-6 Astra")]))
        let cleared = ExecutionResult(outcome: .applied(label: "Clear Cells"), label: "Clear Cells")
        let request = try XCTUnwrap(EditVerifier.request(for: clear, before: before, after: after, result: cleared, scene: scene))
        let cells = request.checks.filter { $0.tag.hasPrefix("r") && $0.tag.hasSuffix("c5") }
        XCTAssertEqual(cells.count, 9)
        XCTAssertTrue(cells.allSatisfy { $0.kind == .textAbsent && $0.text?.isEmpty == false })
        let first = try XCTUnwrap(grid.cell(dataRow: 1, dataColumn: 5))
        XCTAssertEqual(cells.first { $0.tag == "r1c5" }?.region, first.contentRect)
        XCTAssertEqual(cells.first { $0.tag == "r1c5" }?.text, first.text)

        let replace = EditIntent(action: .fillCells, table: TableEditSpec(rows: [.index(1)], columns: [.index(5)], value: .constant("12")))
        let filled = ExecutionResult(outcome: .applied(label: "Fill Cells"), label: "Fill Cells")
        let replaced = try XCTUnwrap(EditVerifier.request(for: replace, before: before, after: after, result: filled, scene: scene))
        XCTAssertEqual(replaced.checks.filter { $0.kind == .textAbsent }.map(\.tag), ["r1c5"])
        let same = EditIntent(action: .fillCells, table: TableEditSpec(rows: [.index(1)], columns: [.index(5)], value: .constant(first.text + " *")))
        XCTAssertNil(EditVerifier.request(for: same, before: before, after: after, result: filled, scene: scene)?.checks.first { $0.kind == .textAbsent },
                     "the new value holds the old one")
    }

    func testNothingToCheckForAFailedOrUncheckedStep() {
        let document = SceneFixtures.posterDocument()
        let failed = ExecutionResult.failed("x")
        XCTAssertNil(EditVerifier.request(for: EditIntent(action: .addText, text: "a"), before: document, after: document, result: failed, scene: nil))
        let applied = ExecutionResult.applied("Brightness +20")
        XCTAssertNil(EditVerifier.request(for: EditIntent(action: .adjust, parameter: .brightness), before: document, after: document, result: applied, scene: nil))
    }

    func testRemovedObjectsNeedThePixelCheck() throws {
        let before = SceneFixtures.posterDocument()
        var after = before
        let mask = MaskReference(source: .object(label: "person", boundingBox: PSRect(x: 0.3, y: 0.24, width: 0.4, height: 0.7)),
                                 boundingBox: PSRect(x: 0.3, y: 0.24, width: 0.4, height: 0.7))
        after.apply(.removeObject(mask))
        let intent = EditIntent(action: .removeObject, target: ObjectTarget(label: "person"))
        let request = try XCTUnwrap(EditVerifier.request(for: intent, before: before, after: after, result: .applied("Remove person"), scene: nil))
        XCTAssertEqual(request.checks.map(\.kind), [.objectAbsent])
        let report = EditVerifier.structural(request, in: after)
        XCTAssertEqual(report.status, .unverified)
        XCTAssertEqual(report.summary, "not verified")
    }

    func testSummaryStaysShort() {
        let checks = (1...60).map { VerificationCheck(kind: .textPresent, region: .unit, text: "1", tag: "r\($0)c\($0)") }
        let report = VerificationReport(intentID: UUID(), action: .fillCells, items: checks.map { .init(check: $0, outcome: .failed, observed: "something long here") },
                                        method: .pixels)
        XCTAssertLessThanOrEqual(report.summary.count, 200)
        XCTAssertTrue(report.summary.hasPrefix("verify failed 60/60:"))
        XCTAssertTrue(report.summary.contains("more"))
    }
}
