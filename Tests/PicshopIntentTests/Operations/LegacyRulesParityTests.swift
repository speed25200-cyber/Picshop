import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// W2 (§8.10): ToolInputValidator's legacy tables, now generated from the catalog's legacy specs
/// (LegacyStepRules), against W1's hand-written ones (Fixtures/LegacyTablesW1.swift): the same accept/reject
/// decision and the same problem field paths over the Live eval cases, the dialogue corpus, every catalog
/// example and ≥ 400 generated boundary steps. The wording is W1's too (LegacyStepRules keeps its lines); the
/// test still tolerates a reworded required-field line for the actions listed.
final class LegacyRulesParityTests: XCTestCase {
    static let rewordedActions: Set<IntentAction> = [.eraseRegion, .moveText, .fillCells, .clearCells, .trim, .deleteRange]

    static func newProblems(_ step: RawIntentStep, action: IntentAction, path: String) -> [String] {
        LegacyStepRules.enumerationProblems(step, path: path) + LegacyStepRules.textProblems(step, path: path)
            + LegacyStepRules.requiredProblems(step, action: action, path: path)
    }

    static func fieldPath(_ problem: String) -> String {
        String(problem.prefix { $0 != ":" })
    }

    struct Mismatch: CustomStringConvertible {
        var source: String
        var old: [String]
        var new: [String]
        var description: String { "\(source)\n  old: \(old)\n  new: \(new)" }
    }

    /// Old against new on one step: decision and field paths; message wording only where listed.
    static func compare(_ step: RawIntentStep, source: String, into mismatches: inout [Mismatch]) -> Bool {
        guard let action = IntentAction(rawValue: step.action) else { return false }
        let old = LegacyTablesW1.problems(step, action: action, path: "s")
        let new = newProblems(step, action: action, path: "s")
        let samePaths = Set(old.map(fieldPath)) == Set(new.map(fieldPath))
        let sameDecision = old.isEmpty == new.isEmpty
        let sameWords = Set(old) == Set(new) || rewordedActions.contains(action)
        if !(samePaths && sameDecision && sameWords) { mismatches.append(Mismatch(source: source, old: old, new: new)) }
        return true
    }

    // MARK: Tables

    func testTheGeneratedTablesEqualW1s() {
        XCTAssertEqual(LegacyStepRules.stepKeys, LegacyTablesW1.stepKeys)
        let enums = LegacyStepRules.enumerations
        XCTAssertEqual(Set(enums["spatialHint"] ?? []), Set(SpatialHint.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["parameter"] ?? []), Set(AdjustmentParameter.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["look"] ?? []), Set(FilterPreset.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["aspect"] ?? []), Set(AspectPreset.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["flipAxis"] ?? []), Set(FlipAxis.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["placement"] ?? []), Set(TextElement.Placement.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["transition"] ?? []), Set(TransitionKind.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(enums["amountMode"] ?? []), ["relative", "absolute", "multiplier"])
        XCTAssertEqual(Set(enums["scope"] ?? []), ["current", "all", "selection"])
        XCTAssertEqual(enums["cells"], LiveToolSchema.cellsValues)
        XCTAssertEqual(enums["values"], LiveToolSchema.valuesValues)
        XCTAssertEqual(enums["weight"], TableGrid.FontWeight.allCases.map(\.rawValue))
        XCTAssertEqual(enums["align"], LiveToolSchema.alignValues)
        XCTAssertEqual(enums["font"], TableGrid.FontDesign.allCases.map(\.rawValue))
        XCTAssertEqual(LegacyStepRules.textLimits, ["target": 40, "text": 200, "color": 40, "background": 40, "row": 40, "column": 40])
        XCTAssertEqual(LegacyStepRules.attributeLimits.length, 24)
        XCTAssertEqual(LegacyStepRules.attributeLimits.count, 3)
        XCTAssertEqual(LegacyStepRules.requirements(for: .removeObject), [["target", "point"]])
        XCTAssertEqual(LegacyStepRules.requirements(for: .recolor), [["target"], ["color"]])
        XCTAssertEqual(LegacyStepRules.requirements(for: .trim), [["startSeconds"], ["endSeconds"]])
        XCTAssertEqual(LegacyStepRules.requirements(for: .generativeFill), [], "only W1's checked actions")
    }

    // MARK: Corpora

    func testTheLiveEvalCasesAgree() {
        var mismatches: [Mismatch] = []
        var steps = 0
        for evalCase in LiveEvalCases.all {
            for intent in RuleBasedIntentEngine().parse(evalCase.text, context: evalCase.context).intents where intent.action != .operation {
                if Self.compare(RawIntentStep(intent: intent), source: evalCase.text, into: &mismatches) { steps += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(LiveEvalCases.all.count, 200)
        XCTAssertGreaterThan(steps, 150)
        XCTAssertEqual(mismatches.map(\.description), [])
    }

    func testTheDialogueCorpusAgrees() {
        var mismatches: [Mismatch] = []
        var steps = 0
        for dialogue in LiveDialogueCases.all {
            for turn in dialogue.turns {
                for reference in [turn.reference, turn.afterResult, turn.closing].compactMap({ $0 }) {
                    for step in Self.steps(in: reference, mode: .photo) where Self.compare(step, source: "\(dialogue.name): \(turn.text)", into: &mismatches) {
                        steps += 1
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(LiveDialogueCases.all.count, 186)
        XCTAssertGreaterThan(steps, 150)
        XCTAssertEqual(mismatches.map(\.description), [])
    }

    /// The apply_edits steps of a reply in Qwen3.5's format, decoded as the validator decodes them.
    static func steps(in reference: String, mode: EditorMode) -> [RawIntentStep] {
        var found: [RawIntentStep] = []
        var rest = Substring(reference)
        while let open = rest.range(of: "<parameter=steps>\n"), let close = rest[open.upperBound...].range(of: "\n</parameter>") {
            let json = String(rest[open.upperBound..<close.lowerBound])
            if case .array(let items)? = try? JSONValue.parse(json) {
                for item in items {
                    var problems: [String] = []
                    if let step = ToolInputValidator(mode: mode).decodeStep(item, path: "s", problems: &problems) { found.append(step) }
                }
            }
            rest = rest[close.upperBound...]
        }
        return found
    }

    func testEveryCatalogExampleAgrees() {
        var mismatches: [Mismatch] = []
        var steps = 0
        for spec in OperationCatalog.shared.specs {
            guard case .intent = spec.lowering else { continue }
            for example in spec.examples {
                if case .negative = example.role { continue }
                for mode in [EditorMode.photo, .video] where spec.domains.contains(mode.opDomain) {
                    var problems: [String] = []
                    let object = OperationArguments.json(OperationCall(spec.id, args: example.args))
                    guard let step = ToolInputValidator(mode: mode).decodeStep(object, path: "s", problems: &problems) else { continue }
                    if Self.compare(step, source: "\(spec.id) « \(example.say) »", into: &mismatches) { steps += 1 }
                }
            }
        }
        XCTAssertGreaterThan(steps, 150)
        XCTAssertEqual(mismatches.map(\.description), [])
    }

    // MARK: Boundaries

    /// Every enumeration value, its typo and its capitalised form; each text limit and one past it; each required
    /// field missing; the range edges and one past them.
    static func boundarySteps() -> [RawIntentStep] {
        var steps: [RawIntentStep] = []
        let fields: [(String, [String], IntentAction, WritableKeyPath<RawIntentStep, String?>)] = [
            ("spatialHint", SpatialHint.allCases.map(\.rawValue), .removeObject, \.spatialHint),
            ("parameter", AdjustmentParameter.allCases.map(\.rawValue), .adjust, \.parameter),
            ("look", FilterPreset.allCases.map(\.rawValue), .applyLook, \.look),
            ("aspect", AspectPreset.allCases.map(\.rawValue), .crop, \.aspect),
            ("flipAxis", FlipAxis.allCases.map(\.rawValue), .flip, \.flipAxis),
            ("placement", TextElement.Placement.allCases.map(\.rawValue), .addText, \.placement),
            ("transition", TransitionKind.allCases.map(\.rawValue), .addTransition, \.transition),
            ("amountMode", ["relative", "absolute", "multiplier"], .adjust, \.amountMode),
            ("scope", ["current", "all", "selection"], .setSpeed, \.scope),
            ("cells", LiveToolSchema.cellsValues, .clearCells, \.cells),
            ("values", LiveToolSchema.valuesValues, .fillCells, \.values),
            ("weight", TableGrid.FontWeight.allCases.map(\.rawValue), .editText, \.weight),
            ("align", LiveToolSchema.alignValues, .editText, \.align),
            ("font", TableGrid.FontDesign.allCases.map(\.rawValue), .editText, \.font),
        ]
        for (_, values, action, path) in fields {
            for value in values {
                for said in [value, value + "x", value.uppercased()] {
                    var step = complete(action)
                    step[keyPath: path] = said
                    steps.append(step)
                }
            }
        }
        let texts: [(WritableKeyPath<RawIntentStep, String?>, Int, IntentAction)] = [
            (\.target, 40, .removeObject), (\.text, 200, .addText), (\.color, 40, .recolor), (\.background, 40, .replaceBackground),
            (\.row, 40, .highlightCells), (\.column, 40, .highlightCells),
        ]
        for (path, limit, action) in texts {
            for length in [limit, limit + 1] {
                var step = complete(action)
                step[keyPath: path] = String(repeating: "a", count: length)
                steps.append(step)
            }
            var empty = complete(action)
            empty[keyPath: path] = "  "
            steps.append(empty)
        }
        for count in [3, 4] {
            var step = complete(.removeObject)
            step.attributes = Array(repeating: "blue", count: count)
            steps.append(step)
        }
        var long = complete(.removeObject)
        long.attributes = [String(repeating: "b", count: 25)]
        steps.append(long)
        // Each required field missing (and every field of a group).
        for action in LegacyStepRules.checkedActions {
            steps.append(complete(action))
            steps.append(RawIntentStep(action: action.rawValue))
            for field in ["target", "point", "color", "parameter", "look", "text", "values", "weight", "size", "row", "column", "cells", "box", "ref",
                          "placement", "degrees", "startSeconds", "endSeconds", "seconds", "speed", "transition"] {
                var step = complete(action)
                clear(field, in: &step)
                steps.append(step)
            }
        }
        // Range edges (not migrated: the decision must not change either).
        for amount in [-101.0, -100, 100, 101] { var step = complete(.adjust); step.amount = amount; steps.append(step) }
        for degrees in [-361.0, -360, 360, 361] { var step = complete(.rotate); step.degrees = degrees; steps.append(step) }
        for ordinal in [0, 1, 20, 21] { var step = complete(.removeObject); step.ordinal = ordinal; steps.append(step) }
        for decimals in [-1, 0, 3, 4] { var step = complete(.fillCells); step.decimals = decimals; steps.append(step) }
        return steps
    }

    /// A step of that action with every field its W1 check needs.
    static func complete(_ action: IntentAction) -> RawIntentStep {
        var step = RawIntentStep(action: action.rawValue)
        switch action {
        case .removeObject, .moveObject: step.target = "dog"
        case .recolor: step.target = "car"; step.color = "red"
        case .selectiveAdjust: step.target = "sky"; step.parameter = "exposure"
        case .adjust: step.parameter = "exposure"
        case .applyLook: step.look = "vivid"
        case .addText: step.text = "Hello"
        case .fillCells: step.text = "1"
        case .clearCells: step.column = "Total"
        case .highlightCells: step.row = "2"
        case .eraseRegion: step.ref = "t1"
        case .moveText: step.placement = "top"
        case .trim, .deleteRange: step.startSeconds = 1; step.endSeconds = 3
        case .seek: step.seconds = 2
        case .setSpeed: step.speed = 2
        case .addTransition: step.transition = "crossDissolve"
        default: break
        }
        return step
    }

    static func clear(_ field: String, in step: inout RawIntentStep) {
        switch field {
        case "target": step.target = nil
        case "point": step.point = nil
        case "color": step.color = nil
        case "parameter": step.parameter = nil
        case "look": step.look = nil
        case "text": step.text = nil
        case "values": step.values = nil
        case "weight": step.weight = nil
        case "size": step.size = nil
        case "row": step.row = nil
        case "column": step.column = nil
        case "cells": step.cells = nil
        case "box": step.box = nil
        case "ref": step.ref = nil
        case "placement": step.placement = nil
        case "degrees": step.degrees = nil
        case "startSeconds": step.startSeconds = nil
        case "endSeconds": step.endSeconds = nil
        case "seconds": step.seconds = nil
        case "speed": step.speed = nil
        case "transition": step.transition = nil
        default: break
        }
    }

    func testGeneratedBoundaryStepsAgree() {
        let steps = Self.boundarySteps()
        XCTAssertGreaterThanOrEqual(steps.count, 400)
        var mismatches: [Mismatch] = []
        for (index, step) in steps.enumerated() { _ = Self.compare(step, source: "boundary \(index) \(step.action)", into: &mismatches) }
        XCTAssertEqual(mismatches.map(\.description), [])
    }
}
