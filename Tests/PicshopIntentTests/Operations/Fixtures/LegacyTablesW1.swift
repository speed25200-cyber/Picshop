import Foundation
@testable import PicshopIntent
@testable import PicshopCore

/// ToolInputValidator's W1 hand-written tables and checks, verbatim (before W2's LegacyStepRules), so
/// LegacyRulesParityTests can run old against new.
enum LegacyTablesW1 {
    static let stepKeys: Set<String> = [
        "action", "target", "spatialHint", "ordinal", "all", "point", "attributes", "parameter", "amountMode", "amount", "look", "aspect",
        "degrees", "flipAxis", "text", "placement", "color", "background", "choiceIndex",
    ]

    /// The enumeration, text and required-field checks of W1's `check(_:path:context:grounding:problems:)`.
    static func problems(_ step: RawIntentStep, action: IntentAction, path: String) -> [String] {
        var problems: [String] = []
        // Enumerations, exactly.
        func member<T: RawRepresentable>(_ value: String?, _ field: String, _ type: T.Type) where T.RawValue == String {
            guard let value else { return }
            if T(rawValue: value) == nil { problems.append("\(path).\(field): '\(value)' is not a valid value") }
        }
        member(step.spatialHint, "spatialHint", SpatialHint.self)
        member(step.parameter, "parameter", AdjustmentParameter.self)
        member(step.look, "look", FilterPreset.self)
        member(step.aspect, "aspect", AspectPreset.self)
        member(step.flipAxis, "flipAxis", FlipAxis.self)
        member(step.placement, "placement", TextElement.Placement.self)
        member(step.transition, "transition", TransitionKind.self)
        if let mode = step.amountMode, !["relative", "absolute", "multiplier"].contains(mode) {
            problems.append("\(path).amountMode: '\(mode)' is not a valid value")
        }
        if let scope = step.scope, !["current", "all", "selection"].contains(scope) {
            problems.append("\(path).scope: '\(scope)' is not a valid value")
        }
        func oneOf(_ value: String?, _ field: String, _ values: [String]) {
            guard let value else { return }
            if !values.contains(value) { problems.append("\(path).\(field): '\(value)' is not one of \(values.joined(separator: ", "))") }
        }
        oneOf(step.cells, "cells", LiveToolSchema.cellsValues)
        oneOf(step.values, "values", LiveToolSchema.valuesValues)
        oneOf(step.weight, "weight", TableGrid.FontWeight.allCases.map(\.rawValue))
        oneOf(step.align, "align", LiveToolSchema.alignValues)
        oneOf(step.font, "font", TableGrid.FontDesign.allCases.map(\.rawValue))

        // Strings: trimmed, non-empty, no control characters, within their limits.
        func checkText(_ value: String?, _ field: String, limit: Int) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { problems.append("\(path).\(field): empty") }
            else if trimmed.count > limit { problems.append("\(path).\(field): longer than \(limit) characters") }
            else if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { problems.append("\(path).\(field): control characters") }
        }
        checkText(step.target, "target", limit: 40)
        checkText(step.text, "text", limit: 200)
        checkText(step.color, "color", limit: 40)
        checkText(step.background, "background", limit: 40)
        checkText(step.row, "row", limit: 40)
        checkText(step.column, "column", limit: 40)
        if let attributes = step.attributes {
            if attributes.count > 3 { problems.append("\(path).attributes: at most 3") }
            for (index, attribute) in attributes.enumerated() { checkText(attribute, "attributes[\(index)]", limit: 24) }
        }

        // Required fields.
        func need(_ present: Bool, _ what: String) {
            if !present { problems.append("\(path): \(action.rawValue) needs \(what)") }
        }
        let hasTarget = !(step.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch action {
        case .removeObject, .moveObject: need(hasTarget || step.point != nil, "target or point")
        case .recolor: need(hasTarget, "target"); need(step.color != nil, "color")
        case .selectiveAdjust: need(hasTarget, "target"); need(step.parameter != nil, "parameter")
        case .adjust: need(step.parameter != nil, "parameter")
        case .applyLook: need(step.look != nil, "look")
        case .addText: need(step.text != nil, "text")
        case .fillCells:
            need(step.text != nil || step.values != nil || step.color != nil || step.weight != nil || step.size != nil,
                 "text or values (or color, weight or size to restyle filled cells)")
        case .clearCells: need(step.row != nil || step.column != nil || step.cells != nil, "row, column or cells")
        case .highlightCells: need(step.row != nil || step.column != nil, "row or column")
        case .eraseRegion: need(step.box != nil || step.ref != nil || step.point != nil, "box or ref")
        case .moveText: need(step.box != nil || step.point != nil || step.placement != nil || step.degrees != nil, "box, point or placement")
        case .trim, .deleteRange: need(step.startSeconds != nil && step.endSeconds != nil, "startSeconds and endSeconds")
        case .seek: need(step.seconds != nil, "seconds")
        case .setSpeed: need(step.speed != nil, "speed")
        case .addTransition: need(step.transition != nil, "transition")
        default: break
        }
        return problems
    }
}
