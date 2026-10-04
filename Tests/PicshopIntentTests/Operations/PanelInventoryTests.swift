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

    // MARK: W3: every photo panel (PhotoPanelInventory)

    /// The parameter keys the catalog renamed after the inventory was written: `layerMask`'s action is `do` (a step's
    /// own `action` key names the operation, so a parameter cannot share it). L3 is asked to write "do=" (report).
    static let renamedKeys: [String: String] = ["layerMask.action": "do"]

    static func check(_ control: MaskPanelInventory.Control, catalog: OperationCatalog) -> String? {
        guard let id = control.op, let spec = catalog.spec(id) else { return "\(control.id): no operation" }
        guard let written = control.paramKey else { return nil }
        let key = renamedKeys["\(id.raw).\(written)"] ?? written
        guard let param = spec.params.first(where: { $0.key == key }) else { return "\(control.id): \(id) has no \(key)" }
        guard let value = control.paramValue else { return nil }
        switch param.kind {
        case .enumeration(let values):
            return values.contains(value) ? nil : "\(control.id): \(id).\(key) has no value \(value)"
        case .boolean:
            return ["true", "false"].contains(value) ? nil : "\(control.id): \(key)=\(value) is not a boolean"
        default:
            return Double(value) == nil ? "\(control.id): \(key)=\(value)" : nil
        }
    }

    /// I1 at W3: every `.operation` control of the photo panels names a catalog operation, one of its parameters and
    /// a value that parameter accepts.
    func testEveryPhotoPanelOperationControlMapsToAnOperationParameterAndValue() {
        let controls = PhotoPanelInventory.controls.filter { $0.reach == .operation }
        XCTAssertGreaterThan(controls.count, 200)
        XCTAssertEqual(controls.compactMap { Self.check($0, catalog: .shared) }, [])
        XCTAssertEqual(Set(PhotoPanelInventory.controls.map(\.id)).count, PhotoPanelInventory.controls.count, "ids unique")
    }

    /// Every `.gestureOnly` control of the photo panels has a grammar rule that opens its tool (or, for the export
    /// sheet's Save and Share, W1's own words), and that rule's call runs on the editor.
    func testEveryPhotoPanelGestureControlIsReachedByVoice() async {
        let ruled = Set(RuleBasedIntentEngine.photoGestureRules.map(\.control))
        let spoken = Dictionary(RuleBasedIntentEngine.photoGestureActions.map { ($0.control, $0) }, uniquingKeysWith: { first, _ in first })
        let gestures = PhotoPanelInventory.controls.filter { $0.reach == .gestureOnly }
        XCTAssertFalse(gestures.isEmpty)
        for control in gestures { XCTAssertTrue(ruled.contains(control.id) || spoken[control.id] != nil, control.id) }
        for rule in RuleBasedIntentEngine.photoGestureRules {
            XCTAssertNotNil(PhotoPanelInventory.control(rule.control), rule.control)
            XCTAssertNotNil(OperationCatalog.shared.spec(rule.op), rule.control)
        }
        for (control, phrase, action) in RuleBasedIntentEngine.photoGestureActions {
            XCTAssertEqual(RuleBasedIntentEngine().parse(phrase, context: IntentContext(mode: .photo)).intents.first?.action, action, "\(control): « \(phrase) »")
        }
        let executor = PhotoCommandExecutor(services: OperationPhotoServices(), language: .english)
        let document = OperationFixtures.photoWithLayers()
        for rule in RuleBasedIntentEngine.photoGestureRules {
            guard let phrase = rule.phrases.last else { continue }
            let plan = RuleBasedIntentEngine().parse(phrase, context: IntentContext(mode: .photo))
            guard let intent = plan.intents.first, intent.operation?.args["openTool"] == .string(rule.control) else {
                XCTFail("« \(phrase) » → \(plan.intents.map(\.action))")
                continue
            }
            let (after, result) = await executor.execute(intent, on: document, context: OperationFixtures.photoContext(document))
            XCTAssertEqual(after, document, "opening a tool changes nothing: \(rule.control)")
            XCTAssertTrue(result.effects.contains(.message("openTool:\(rule.control)")), "\(phrase): \(result.effects)")
            XCTAssertFalse((result.outcome.message ?? "").isEmpty, "a hint is said: \(rule.control)")
        }
    }

    /// `.viewOnly` in the photo panels: guides, overlays, thumbnails, histograms, previews, the column's visibility
    /// and the transparency checkerboard.
    func testPhotoPanelViewOnlyControlsAreViews() {
        let words = ["guides", "overlay", "thumbnail", "histogram", "preview", "show", "transparency"]
        for control in PhotoPanelInventory.controls where control.reach == .viewOnly {
            XCTAssertTrue(words.contains { control.id.contains($0) }, control.id)
        }
    }

    /// The adjustment-layer and fill-layer panels name an edit operation that takes the layer (`layer` or `ref`),
    /// never a creation one; the recipe rows reach `recipe`.
    func testLayerPanelsNameEditOperationsThatBindTheLayer() throws {
        let creation: Set<OpID> = ["addAdjustmentLayer", "addFillLayer", "addImageLayer", "layerVia"]
        for control in PhotoPanelInventory.controls where control.id.hasPrefix("layers.fill.") || control.id.hasPrefix("layers.adjustment.") {
            let op = try XCTUnwrap(control.op, control.id)
            XCTAssertFalse(creation.contains(op), "\(control.id) names \(op)")
            let spec = try XCTUnwrap(OperationCatalog.shared.spec(op), control.id)
            XCTAssertTrue(spec.params.contains { $0.key == "layer" || $0.key == "ref" }, "\(control.id): \(op) cannot bind the layer")
        }
        for control in PhotoPanelInventory.controls where control.id.hasPrefix("magic.recipe.") {
            XCTAssertEqual(control.op, "recipe", control.id)
        }
    }

    /// Every photo tool's `uiTool` is a tool the palette knows, "export" or "canvas".
    func testPhotoPanelToolsAreKnown() {
        let known = Set(CommandPalette.photoTools + ["export", "canvas"])
        for control in PhotoPanelInventory.controls { XCTAssertTrue(known.contains(control.uiTool), "\(control.id): \(control.uiTool)") }
    }
}
