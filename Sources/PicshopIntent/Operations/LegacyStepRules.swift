import Foundation
import PicshopCore

/// The legacy steps' validation rules, generated from the catalog's legacy specs (W2, §8.10): which values the
/// enumerated fields accept, which fields an action needs (its `.required` params and `oneOf` groups), how long
/// a text field may be, and the base step keys. ToolInputValidator reads them instead of its W1 hand-written
/// tables (kept verbatim in Tests/…/Fixtures/LegacyTablesW1.swift; LegacyRulesParityTests proves the two agree).
///
/// Not migrated (state-dependent, not catalog data): ranges from the context (timeline seconds, clip and choice
/// counts), table row and column prefixes, scene-ref grounding and `keepsPoints`, the translateCaptions language
/// set, and the mode-specific field bans.
public enum LegacyStepRules {
    /// The legacy specs Live's editors run (photo and video; PDF steps go through the planner's normaliser).
    static var liveSpecs: [OperationSpec] {
        OperationCatalog.shared.specs.filter { spec in
            guard case .intent = spec.lowering else { return false }
            return spec.domains.contains(.photo) || spec.domains.contains(.video)
        }
    }

    // MARK: Enumerations

    /// The fields checked against an enumeration, in the order problems are reported.
    public static let enumeratedFields = ["spatialHint", "parameter", "look", "aspect", "flipAxis", "placement", "transition", "amountMode", "scope",
                                          "cells", "values", "weight", "align", "font"]
    /// Fields whose problem lists the accepted values (short lists); the others say "is not a valid value".
    static let listedFields: Set<String> = ["cells", "values", "weight", "align", "font"]

    /// field → the accepted values: the union of the values of that param across the legacy specs, in first-seen order.
    public static let enumerations: [String: [String]] = {
        var table: [String: [String]] = [:]
        for spec in liveSpecs {
            for param in spec.params where enumeratedFields.contains(param.key) {
                guard case .enumeration(let values) = param.kind else { continue }
                var known = table[param.key] ?? []
                for value in values where !known.contains(value) { known.append(value) }
                table[param.key] = known
            }
        }
        return table
    }()

    // MARK: Text

    /// The free-text fields and their limits: the longest `.text(maxLength:)` of that key across the legacy specs.
    public static let textFields = ["target", "text", "color", "background", "row", "column"]
    /// A colour is a `.color` param (a name or #RRGGBB): its text is as long as a target's.
    public static let colorNameLimit = 40

    public static let textLimits: [String: Int] = {
        var limits: [String: Int] = ["color": colorNameLimit]
        for spec in liveSpecs {
            for param in spec.params where textFields.contains(param.key) {
                if case .text(let maxLength) = param.kind { limits[param.key] = max(limits[param.key] ?? 0, maxLength) }
            }
        }
        return limits
    }()

    /// `attributes`: a list of short texts (its element limit and count).
    public static let attributeLimits: (length: Int, count: Int) = {
        for spec in liveSpecs {
            if let param = spec.params.first(where: { $0.key == "attributes" }), case .list(.text(let length), let count) = param.kind {
                return (length, count)
            }
        }
        return (24, 3)
    }()

    // MARK: Keys

    /// The keys any legacy step may carry in every editor: the legacy specs' param keys, without the
    /// video-only and photo-only fields (the validator adds those per mode). Key aliases are not listed: the
    /// coercer maps them, and a key the decoder does not read must stay an unknown field.
    public static let stepKeys: Set<String> = {
        var keys: Set<String> = ["action"]
        for spec in liveSpecs { for param in spec.params { keys.insert(param.key) } }
        return keys.subtracting(LiveToolSchema.videoFields).subtracting(LiveToolSchema.photoFields)
    }()

    // MARK: Required fields

    /// The actions whose required fields the validator checks before the normaliser (W1's switch).
    public static let checkedActions: [IntentAction] = [.removeObject, .moveObject, .recolor, .selectiveAdjust, .adjust, .applyLook, .addText, .fillCells,
                                                        .clearCells, .highlightCells, .eraseRegion, .moveText, .trim, .deleteRange, .seek, .setSpeed,
                                                        .addTransition]

    /// What the action needs, as groups of fields: each group is satisfied by any one of its fields (a required
    /// param is a group of one; a `oneOf` group is one group).
    public static func requirements(for action: IntentAction) -> [[String]] {
        guard checkedActions.contains(action), let spec = OperationCatalog.shared.spec(lowering: action) else { return [] }
        var groups: [[String]] = []
        var byName: [String: Int] = [:]
        for param in spec.params {
            switch param.presence {
            case .required: groups.append([param.key])
            case .oneOf(let group):
                if let index = byName[group] { groups[index].append(param.key) } else {
                    byName[group] = groups.count
                    groups.append([param.key])
                }
            case .optional: continue
            }
        }
        return groups
    }

    /// Whether the step carries that field. A target counts once trimmed (an empty one is no target).
    static func has(_ field: String, in step: RawIntentStep) -> Bool {
        switch field {
        case "target": return !(step.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case "point": return step.point != nil
        case "parameter": return step.parameter != nil
        case "color": return step.color != nil
        case "look": return step.look != nil
        case "text": return step.text != nil
        case "values": return step.values != nil
        case "weight": return step.weight != nil
        case "size": return step.size != nil
        case "row": return step.row != nil
        case "column": return step.column != nil
        case "cells": return step.cells != nil
        case "box": return step.box != nil
        case "ref": return step.ref != nil
        case "placement": return step.placement != nil
        case "degrees": return step.degrees != nil
        case "startSeconds": return step.startSeconds != nil
        case "endSeconds": return step.endSeconds != nil
        case "seconds": return step.seconds != nil
        case "speed": return step.speed != nil
        case "transition": return step.transition != nil
        case "amount": return step.amount != nil
        case "aspect": return step.aspect != nil
        case "clipNumber": return step.clipNumber != nil
        case "choiceIndex": return step.choiceIndex != nil
        default: return step.extra?[field] != nil
        }
    }

    static func value(_ field: String, in step: RawIntentStep) -> String? {
        switch field {
        case "spatialHint": return step.spatialHint
        case "parameter": return step.parameter
        case "look": return step.look
        case "aspect": return step.aspect
        case "flipAxis": return step.flipAxis
        case "placement": return step.placement
        case "transition": return step.transition
        case "amountMode": return step.amountMode
        case "scope": return step.scope
        case "cells": return step.cells
        case "values": return step.values
        case "weight": return step.weight
        case "align": return step.align
        case "font": return step.font
        case "target": return step.target
        case "text": return step.text
        case "color": return step.color
        case "background": return step.background
        case "row": return step.row
        case "column": return step.column
        default: return nil
        }
    }

    // MARK: Checks

    /// The enumeration problems of a step, in field order.
    public static func enumerationProblems(_ step: RawIntentStep, path: String) -> [String] {
        enumeratedFields.compactMap { field in
            guard let value = value(field, in: step), let accepted = enumerations[field], !accepted.contains(value) else { return nil }
            return listedFields.contains(field)
                ? "\(path).\(field): '\(value)' is not one of \(accepted.joined(separator: ", "))"
                : "\(path).\(field): '\(value)' is not a valid value"
        }
    }

    /// The text problems: trimmed, non-empty, no control characters, within the field's limit.
    public static func textProblems(_ step: RawIntentStep, path: String) -> [String] {
        var problems: [String] = []
        func check(_ value: String?, _ field: String, limit: Int) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { problems.append("\(path).\(field): empty") }
            else if trimmed.count > limit { problems.append("\(path).\(field): longer than \(limit) characters") }
            else if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { problems.append("\(path).\(field): control characters") }
        }
        for field in textFields { check(value(field, in: step), field, limit: textLimits[field] ?? colorNameLimit) }
        if let attributes = step.attributes {
            if attributes.count > attributeLimits.count { problems.append("\(path).attributes: at most \(attributeLimits.count)") }
            for (index, attribute) in attributes.enumerated() { check(attribute, "attributes[\(index)]", limit: attributeLimits.length) }
        }
        return problems
    }

    /// How W1 worded what a few actions need (the model reads it in its repair round): one line for all of the
    /// action's unmet groups. Wording only; which fields count comes from the specs.
    static let wording: [IntentAction: String] = [
        .fillCells: "text or values (or color, weight or size to restyle filled cells)", .eraseRegion: "box or ref",
        .moveText: "box, point or placement", .trim: "startSeconds and endSeconds", .deleteRange: "startSeconds and endSeconds",
    ]

    /// The required-field problems: one per unmet group, "needs target or point" (W1's line where it had one).
    public static func requiredProblems(_ step: RawIntentStep, action: IntentAction, path: String) -> [String] {
        let unmet = requirements(for: action).filter { group in !group.contains(where: { has($0, in: step) }) }
        guard !unmet.isEmpty else { return [] }
        if let said = wording[action] { return ["\(path): \(action.rawValue) needs \(said)"] }
        return unmet.map { group in
            let said = group.count == 1 ? group[0] : group.dropLast().joined(separator: ", ") + " or " + (group.last ?? "")
            return "\(path): \(action.rawValue) needs \(said)"
        }
    }
}
