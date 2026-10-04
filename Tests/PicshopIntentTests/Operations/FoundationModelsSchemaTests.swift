import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 (D15, §8.8): the pure schema tree the on-device model is guided with.
final class FoundationModelsSchemaTests: XCTestCase {
    private func properties(_ node: FMSchemaNode) -> [FMSchemaNode.Property] {
        if case .object(_, let properties) = node { return properties }
        return []
    }

    func testEveryStepNamesItsOperationAndKeepsTheValidatorsEnumerations() {
        for spec in OperationCatalog.shared.specs {
            let step = FoundationModelsSchema.stepSchema(spec)
            XCTAssertEqual(step.objectName, spec.id.raw)
            let fields = properties(step)
            XCTAssertEqual(fields.first?.name, "action")
            XCTAssertEqual(fields.first?.node, .constant(spec.id.raw), "\(spec.id): the action is a constant, the op id")
            XCTAssertFalse(fields.first?.optional ?? true)
            for field in fields.dropFirst() {
                let param = try? XCTUnwrap(spec.params.first { $0.key == field.name }, "\(spec.id).\(field.name)")
                guard let param else { continue }
                if case .required = param.presence { XCTAssertFalse(field.optional, "\(spec.id).\(field.name)") }
                XCTAssertLessThanOrEqual(field.description.count, 60)
                switch (param.kind, field.node) {
                case (.enumeration(let values), .string(let anyOf?)): XCTAssertEqual(anyOf, values, "\(spec.id).\(field.name)")
                case (.enumeration(let values), .string(nil)): XCTAssertGreaterThan(values.count, FoundationModelsSchema.longEnumeration)
                case (.number(let range, _), .number(let schemaRange)): XCTAssertEqual(range, schemaRange)
                case (.integer(let range), .integer(let schemaRange)): XCTAssertEqual(range, schemaRange)
                case (.box, .array(.integer(0...1000), 4)), (.point, .array(.integer(0...1000), 2)): break
                case (.boolean, .boolean), (.color, .string(nil)), (.text, .string(nil)), (.ref, .string(nil)), (.list, .array): break
                default: XCTFail("\(spec.id).\(field.name): \(param.kind) as \(field.node)")
                }
            }
            // Every required parameter is offered.
            for param in spec.params {
                if case .required = param.presence { XCTAssertTrue(fields.contains { $0.name == param.key }, "\(spec.id).\(param.key)") }
            }
        }
    }

    func testThePlanIsAnArrayOfAtMostSixStepsOfTheOperations() {
        let specs = Array(OperationGate.core(for: .photo))
        let plan = FoundationModelsSchema.planSchema(specs: specs)
        XCTAssertEqual(plan.objectName, "Plan")
        guard case .array(.anyOf(let steps), let max)? = properties(plan).first(where: { $0.name == "steps" })?.node else { return XCTFail("steps") }
        XCTAssertEqual(max, 6)
        XCTAssertEqual(steps.compactMap(\.objectName), specs.map(\.id.raw))
    }

    /// The budget: ≤ 2,400 characters for 12 operations (the photo core), and every turn's schema within it.
    func testSchemasStayWithinTheirBudget() {
        for domain in OpDomain.allCases {
            let core = Array(OperationGate.core(for: domain).prefix(FoundationModelsSchema.maxOps))
            let size = FoundationModelsSchema.estimatedChars(FoundationModelsSchema.planSchema(specs: core))
            XCTAssertLessThanOrEqual(size, FoundationModelsSchema.budget, "\(domain) core: \(size)")
        }
        for utterance in HeldOutUtterances.all {
            let query = OperationQuery(text: utterance.text, domain: utterance.domain, language: utterance.language == .fr ? .french : .english)
            let (specs, schema) = FoundationModelsSchema.plan(for: query)
            XCTAssertLessThanOrEqual(specs.count, 12)
            XCTAssertLessThanOrEqual(FoundationModelsSchema.estimatedChars(schema), FoundationModelsSchema.budget, utterance.text)
        }
        let fallback = FoundationModelsSchema.fallbackSpecs(domain: .photo).map(\.id.raw)
        for id in ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply", "selectiveAdjust"] {
            XCTAssertTrue(fallback.contains(id), id)
        }
    }

    /// §8.8: the held-out photo utterances find their gold operation in that turn's schema (the 2B's R-lane
    /// target, core + 5).
    func testTheGoldOperationIsInTheTurnsSchema() {
        var total = 0, found = 0
        var misses: [String] = []
        for utterance in HeldOutUtterances.all where utterance.domain == .photo {
            total += 1
            var turn = LiveUserTurn.speech(utterance.text)
            turn.language = utterance.language == .fr ? .french : .english
            let ids = Set(FoundationModelsSchema.turnTool(for: turn, mode: .photo).specs.map(\.id.raw))
            if !ids.isDisjoint(with: utterance.gold) { found += 1 } else { misses.append(utterance.text) }
        }
        XCTAssertGreaterThanOrEqual(Double(found) / Double(total), 0.95, "\(misses)")
    }

    /// Guided generation emits only what the schema lists: the region keys a mask or a selection names its area with
    /// (colour, person number, attributes) are offered while they fit, and never cost a turn its operations.
    func testTheRegionKeysAreOfferedWhileTheyFit() {
        func body(of object: String, in rendered: String) -> Substring? {
            guard let start = rendered.range(of: object + "{") else { return nil }
            return rendered[start.upperBound...].prefix { $0 != "}" }
        }
        let masks = ["maskAdjust", "select"].compactMap { OperationCatalog.shared.spec(OpID($0)) }
        let rendered = FoundationModelsSchema.rendered(FoundationModelsSchema.planSchema(specs: masks))
        for object in ["maskAdjust", "select"] {
            let fields = body(of: object, in: rendered) ?? ""
            for key in ["\"color\"?:string", "\"index\"?:int 1…8", "\"attributes\"?:["] { XCTAssertTrue(fields.contains(key), "\(object): \(key) in \(fields)") }
        }
        let bare = FoundationModelsSchema.rendered(FoundationModelsSchema.planSchema(specs: masks, regionKeys: false))
        XCTAssertFalse(body(of: "select", in: bare)?.contains("\"index\"") ?? true)
        // Never at a turn's operations' expense: whenever the schema without them fits, the turn keeps what it retrieved.
        var withMasks = 0, carried = 0
        for utterance in HeldOutUtterances.all where utterance.domain == .photo {
            let query = OperationQuery(text: utterance.text, domain: .photo, language: utterance.language == .fr ? .french : .english)
            let chosen = FoundationModelsSchema.specs(for: query)
            let (specs, schema) = FoundationModelsSchema.plan(for: query)
            XCTAssertLessThanOrEqual(FoundationModelsSchema.estimatedChars(schema), FoundationModelsSchema.budget, utterance.text)
            if FoundationModelsSchema.estimatedChars(FoundationModelsSchema.planSchema(specs: chosen, regionKeys: false)) <= FoundationModelsSchema.budget {
                XCTAssertEqual(specs.map(\.id), chosen.map(\.id), utterance.text)
            }
            guard specs.contains(where: { $0.id == "maskAdjust" || $0.id == "select" }) else { continue }
            withMasks += 1
            let text = FoundationModelsSchema.rendered(schema)
            if (body(of: "maskAdjust", in: text) ?? body(of: "select", in: text))?.contains("\"index\"") == true { carried += 1 }
        }
        XCTAssertGreaterThan(carried * 2, withMasks, "most mask and selection turns carry the region keys: \(carried) of \(withMasks)")
    }

    func testTheModelsJSONReachesTheValidator() {
        let json: JSONValue = ["steps": [["action": "maskAdjust", "where": "sky", "parameter": "exposure", "amount": -20], ["note": "no action"]], "reply": "Ok"]
        let steps = FoundationModelsSchema.steps(in: json)
        XCTAssertEqual(steps.count, 1)
        let use = ToolArgumentCoercer.rawToolUse(id: "fm", name: "apply_edits", arguments: ["steps": .array(steps)])
        guard case .success(let call) = ToolInputValidator(mode: .photo).validate(use, context: IntentContext(mode: .photo)),
              case .applyEdits(let intents) = call.tool else { return XCTFail("validator") }
        XCTAssertEqual(intents.first?.operation?.id, "maskAdjust")
    }

    func testTheRenderingIsCompactAndDeterministic() {
        let step = FoundationModelsSchema.stepSchema(OperationCatalog.shared.spec("maskDelete")!)
        XCTAssertEqual(FoundationModelsSchema.rendered(step), FoundationModelsSchema.rendered(step))
        XCTAssertTrue(FoundationModelsSchema.rendered(step).hasPrefix("maskDelete{\"action\":\"maskDelete\""))
        XCTAssertEqual(FoundationModelsSchema.node(for: .box), .array(of: .integer(0...1000), max: 4))
        XCTAssertEqual(FoundationModelsSchema.node(for: .point), .array(of: .integer(0...1000), max: 2))
    }
}
