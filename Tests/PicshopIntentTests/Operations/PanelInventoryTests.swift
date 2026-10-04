import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// I1 at W2 (§8.10): every control of the Masques and Sélection UI is reachable by voice or a model.
final class PanelInventoryTests: XCTestCase {
    /// Every `.operation` control names an operation of the catalog, one of its parameters, and a value that
    /// parameter accepts.
    func testEveryOperationControlMapsToAnOperationParameterAndValue() throws {
        let catalog = OperationCatalog.shared
        var problems: [String] = []
        for control in MaskPanelInventory.controls where control.reach == .operation {
            guard let id = control.op, let spec = catalog.spec(id) else { problems.append("\(control.id): no operation"); continue }
            guard let key = control.paramKey else { continue }
            guard let param = spec.params.first(where: { $0.key == key }) else { problems.append("\(control.id): \(id) has no \(key)"); continue }
            guard let value = control.paramValue else { continue }
            switch param.kind {
            case .enumeration(let values):
                if !values.contains(value) { problems.append("\(control.id): \(id).\(key) has no value \(value)") }
            case .boolean:
                if !["true", "false"].contains(value) { problems.append("\(control.id): \(key)=\(value) is not a boolean") }
            case .color:
                if PSColor.named(value) == nil && ColorRangeSpec.Preset(rawValue: value) == nil && ["reds", "oranges", "yellows", "greens", "cyans", "blues", "magentas"].contains(value) == false {
                    problems.append("\(control.id): \(value) is not a colour")
                }
            default:
                if Double(value) == nil { problems.append("\(control.id): \(key)=\(value)") }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// Every `.gestureOnly` control has a grammar rule that opens its tool on it, and that rule's call runs.
    func testEveryGestureControlHasAGrammarRule() async {
        let ruled = Set(RuleBasedIntentEngine.gestureRules.map(\.control))
        let gestures = MaskPanelInventory.controls.filter { $0.reach == .gestureOnly }
        XCTAssertFalse(gestures.isEmpty)
        for control in gestures { XCTAssertTrue(ruled.contains(control.id), control.id) }
        for rule in RuleBasedIntentEngine.gestureRules {
            XCTAssertNotNil(MaskPanelInventory.control(rule.control), rule.control)
            let phrase = try? XCTUnwrap(rule.phrases.first)
            guard let phrase else { continue }
            let plan = RuleBasedIntentEngine().parse(phrase, context: IntentContext(mode: .photo))
            guard let call = plan.intents.first?.operation else { XCTFail("« \(phrase) » → \(plan.intents.map(\.action))"); continue }
            XCTAssertEqual(call.args["openTool"], .string(rule.control), phrase)
            let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .french)
            let document = OperationFixtures.photoWithMasks()
            let (after, result) = await executor.execute(plan.intents[0], on: document, context: OperationFixtures.photoContext(document))
            XCTAssertEqual(after, document, "opening a tool changes nothing")
            XCTAssertTrue(result.effects.contains(.message("openTool:\(rule.control)")), "\(phrase): \(result.effects)")
        }
    }

    /// `.viewOnly` is kept to the overlay's style and colour and the sheets' preview modes.
    func testViewOnlyControlsAreOverlaysAndPreviews() {
        for control in MaskPanelInventory.controls where control.reach == .viewOnly {
            let parts = control.id.split(separator: ".").map(String.init)
            XCTAssertTrue(parts.contains("overlay") || parts.contains("preview") || parts.contains("view"), control.id)
        }
    }

    /// Every photo tool has an operation that opens it (uiTool), masks and select included. Precise (pixel brush,
    /// clone, lasso) and Shapes (tap to place) are gesture tools with no catalog operation yet.
    func testEveryPhotoToolHasAnOperation() {
        let tools = Set(OperationCatalog.shared.specs(in: .photo).compactMap(\.uiTool))
        for tool in CommandPalette.photoTools where !["precise", "shapes"].contains(tool) {
            XCTAssertTrue(tools.contains(tool), tool)
        }
        XCTAssertTrue(tools.isSuperset(of: ["masks", "select"]))
    }
}
