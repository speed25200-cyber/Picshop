import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The M lane (§8.10) on Linux: MLaneRunner with the scripted model replaying each case's reference answer
/// through the whole pipeline (filter, coercer, validator, handler, executor, postconditions) on the lake photo.
final class MLaneRunnerTests: XCTestCase {
    func testTheCorpusHasItsShape() {
        let all = MLaneCorpus.all
        XCTAssertGreaterThanOrEqual(all.count, 60)
        XCTAssertGreaterThanOrEqual(all.filter { $0.language == .french }.count, 40)
        XCTAssertGreaterThanOrEqual(all.filter { $0.language == .english }.count, 15)
        XCTAssertEqual(Set(all.map(\.text)).count, all.count, "no duplicates")
        for phrase in MLaneCorpus.signaturePhrases { XCTAssertTrue(all.contains { $0.text == phrase }, phrase) }
        XCTAssertGreaterThanOrEqual(all.filter(\.isRefusal).count, 2, "honest refusals")
        let ops: Set<String> = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"]
        XCTAssertEqual(Set(all.flatMap(\.gold)).intersection(ops), ops)
        for testCase in all {
            for id in testCase.gold { XCTAssertTrue(OperationCatalog.shared.spec(OpID(id)) != nil, "\(testCase.text): \(id)") }
        }
    }

    /// W3 (§8.7): + 80 single-turn layer cases with gold op and args, + 15 unsupported layer requests, on the layered lake.
    func testTheW3CasesHaveTheirShape() {
        let w3 = MLaneCorpus.all.filter { $0.setup == .layers }
        XCTAssertGreaterThanOrEqual(w3.filter { !$0.isRefusal }.count, 80)
        XCTAssertGreaterThanOrEqual(w3.filter(\.isRefusal).count, 15)
        let ops: Set<String> = ["addFillLayer", "fillLayer", "addAdjustmentLayer", "layerVia", "layerMask", "layerClip", "groupLayers", "mergeLayers",
                                "layerTransform", "layerProperties", "exportPhoto", "recipe"]
        XCTAssertEqual(Set(w3.flatMap(\.gold)).intersection(ops), ops)
        for testCase in w3 where testCase.isRefusal {
            XCTAssertNotNil(UnsupportedLayerRequests.match(testCase.text), testCase.text)
        }
    }

    /// None copied from the catalog's examples or triggers (the four signature phrases excepted).
    func testNothingIsCopiedFromTheCatalog() {
        func folded(_ text: String) -> String { TextFolding.tokens(text).joined(separator: " ") }
        var seen = Set<String>()
        for spec in OperationCatalog.shared.specs {
            for example in spec.examples { seen.insert(folded(example.say)) }
            for phrases in spec.triggers.values { for phrase in phrases { seen.insert(folded(phrase)) } }
        }
        let copied = MLaneCorpus.all.filter { !MLaneCorpus.signaturePhrases.contains($0.text) && seen.contains(folded($0.text)) }.map(\.text)
        XCTAssertEqual(copied, [])
    }

    func testTheScriptedModelPassesTheLane() async throws {
        let oracle = DialogueOracle()
        let report = await MLaneRunner.run(label: "scripted", onCase: { testCase in
            oracle.set(DialogueTurn(text: testCase.text, reference: testCase.reference, expect: .any))
        }, onTurn: { oracle.set($0) }, makeBrain: {
            LiveDialogueEvalTests.scriptedBrain(oracle: oracle, seed: 7)
        })
        print("MLANE \(report.json)")
        XCTAssertEqual(report.cases, MLaneCorpus.all.count + LiveDialogueCases.masks.flatMap(\.turns).count)
        XCTAssertEqual(report.opExactMatch, 1, "\(report.failures)")
        XCTAssertEqual(report.argumentF1, 1, "\(report.failures)")
        XCTAssertEqual(report.firstTryValid, 1, "\(report.failures)")
        XCTAssertEqual(report.appliedVerified, 1, "\(report.failures)")
        XCTAssertEqual(report.honestRefusals, 1, "\(report.failures)")
        XCTAssertEqual(report.failures, [])
        // The report round-trips as the device shares it.
        let decoded = try JSONDecoder().decode(MLaneRunner.Report.self, from: Data(report.json.utf8))
        XCTAssertEqual(decoded, report)
    }

    func testTheScoringReadsArgumentsAsTheCorpusWritesThem() {
        let call = EditIntent(action: .operation, operation: OperationCall("maskAdjust", args: ["where": "Sky", "amount": -20, "attributes": .list(["blue", "big"])]))
        XCTAssertEqual(MLaneRunner.arguments(of: call), ["where": "sky", "amount": "-", "attributes": "big,blue"])
        XCTAssertEqual(MLaneRunner.f1(produced: ["where": "sky", "amount": "-"], gold: ["where": "sky", "amount": "-"]), 1)
        XCTAssertEqual(MLaneRunner.f1(produced: ["where": "top"], gold: ["where": "sky", "amount": "-"]), 0)
        XCTAssertEqual(MLaneRunner.f1(produced: ["where": "sky"], gold: ["where": "sky", "amount": "-"]), 2.0 / 3.0, accuracy: 0.001)
        let selective = EditIntent(action: .selectiveAdjust, target: ObjectTarget(label: "sky"), parameter: .exposure, amount: .relative(0.2))
        XCTAssertEqual(MLaneRunner.arguments(of: selective)["where"], "sky")
    }
}
