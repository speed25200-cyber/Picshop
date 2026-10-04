import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 (§8.1, §8.3): the mask operations through the validator, the handlers and the fake host.
final class MaskOperationTests: XCTestCase {
    static let w2Ops: [OpID] = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"]

    static func isNegative(_ example: OpExample) -> Bool {
        if case .negative = example.role { return true }
        return false
    }

    /// §8.10: every parameter of the six operations appears in a positive example, and every value of `where`,
    /// `what`, `use`, `mode` and `combine` in an example or a held-out case of that operation (by its value or
    /// one of its aliases).
    func testEveryW2ParamHasAnExample() throws {
        let catalog = OperationCatalog.shared
        var missing: [String] = []
        for id in Self.w2Ops {
            let spec = try XCTUnwrap(catalog.spec(id))
            let used = Set(spec.examples.filter { !Self.isNegative($0) }.flatMap(\.args.keys))
            for param in spec.params where !used.contains(param.key) { missing.append("\(id).\(param.key)") }
        }
        let heldOut = HeldOutUtterances.all.filter { $0.domain == .photo }
        func folded(_ text: String) -> String { " " + TextFolding.tokens(text).joined(separator: " ") + " " }
        let enumerated: [(key: String, ops: [OpID])] = [("where", ["maskAdjust", "maskEdit"]), ("what", ["select"]), ("use", ["selectionApply"]),
                                                       ("mode", ["select"]), ("combine", ["maskEdit"])]
        for (key, ops) in enumerated {
            let specs = ops.compactMap { catalog.spec($0) }
            let param = try XCTUnwrap(specs.compactMap { $0.params.first { $0.key == key } }.first, key)
            guard case .enumeration(let values) = param.kind else { return XCTFail(key) }
            let said = Set(specs.flatMap(\.examples).filter { !Self.isNegative($0) }.compactMap { $0.args[key]?.string })
            for value in values where !said.contains(value) {
                let words = [value] + param.valueAliases.filter { $0.value == value }.map(\.key)
                let named = heldOut.contains { utterance in
                    !utterance.gold.isDisjoint(with: ops.map(\.raw)) && words.contains { folded(utterance.text).contains(folded($0)) }
                }
                if !named { missing.append("\(key)=\(value)") }
            }
        }
        XCTAssertEqual(missing, [], "\(missing.count) parameters or values without an example")
    }

    /// §8.9: the catalog's mask chips for a landscape with sky and a portrait, valid steps, not repeated once applied.
    func testIdeaChipsOfferLocalAdjustments() throws {
        var state = LiveEditorState(mode: .photo, version: 1)
        state.scene = SceneDescription(people: 0, labels: ["sky", "mountain", "landscape"], brightness: 0.5, colourfulness: 0.5)
        let candidates = IdeaEngine.photoCandidates(state).map(\.french)
        XCTAssertTrue(candidates.contains("Ciel plus profond"))
        XCTAssertTrue(candidates.contains("Assombrir le bas"))
        XCTAssertTrue(candidates.contains("Vignette douce"))
        state.scene = SceneDescription(people: 1, faces: 1, labels: ["portrait"])
        XCTAssertTrue(IdeaEngine.photoCandidates(state).map(\.french).contains("Faire ressortir le sujet"))
        for template in [IdeaEngine.deeperSky, IdeaEngine.subjectPop, IdeaEngine.darkerBottom, IdeaEngine.softVignette] {
            guard case .success(let intents) = ToolInputValidator(mode: .photo).steps(raw: template.steps, context: IntentContext(mode: .photo)) else {
                return XCTFail(template.french)
            }
            XCTAssertTrue(intents.allSatisfy { $0.operation?.id == "maskAdjust" }, template.french)
            XCTAssertTrue(IdeaEngine.isLookOrColour(template.idea(.french)), "a look idea on documents")
        }
        XCTAssertEqual(IdeaEngine.deeperSky.steps.count, 2)
        // Once applied (its history label), the chip is not offered again.
        state.scene = SceneDescription(labels: ["sky"])
        state.appliedEdits = ["Mask: Sky"]
        XCTAssertFalse(IdeaEngine.heuristic(state, dismissed: [], language: .french).contains { $0.title == "Ciel plus profond" })
    }

    /// §8.5: with `masks` off the three mask operations leave the photo core and selectiveAdjust comes back; with
    /// `aiSelection` off the selection operations are gone (they are never in the core).
    func testTheFlagsGateTheCoreBlock() {
        let on = Set(OperationGate.core(for: .photo, disabled: []).map(\.id.raw))
        XCTAssertTrue(on.contains("maskAdjust"))
        XCTAssertFalse(on.contains("selectiveAdjust"))
        let masksOff = Set(OperationGate.core(for: .photo, disabled: OperationGate.maskOperations).map(\.id.raw))
        XCTAssertFalse(masksOff.contains("maskAdjust"))
        XCTAssertTrue(masksOff.contains("selectiveAdjust"))
        XCTAssertEqual(masksOff.count, on.count)
        let video = Set(OperationGate.core(for: .video, disabled: OperationGate.maskOperations).map(\.id.raw))
        XCTAssertFalse(video.contains("selectiveAdjust"), "selectiveAdjust is photo-only")
    }
}
