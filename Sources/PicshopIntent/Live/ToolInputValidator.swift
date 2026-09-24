import Foundation
import PicshopCore

public enum ToolValidationError: Error, Sendable, Equatable { case invalidJSON(raw: String), notAnObject, unknownTool(String), problems([String]) }

/// Strict client-side validation of tool input: eager input streaming turns
/// the server-side checks off, so nothing unchecked may reach the executor.
///
/// Checks, in order: strict JSON, an object at the top, no unknown keys at any
/// level, types, exact enum values (no normalizer aliases), ranges (the
/// AmountUnit table among them), the action allowed in the mode, required
/// fields, and finally IntentNormalizer. A call with any problem runs nothing.
public struct ToolInputValidator: Sendable {
    /// Whether a point Claude gives still lands on the same picture.
    public struct Grounding: Sendable, Equatable {
        /// Width / height of the last image Claude saw; nil when none was sent.
        public var imageAspect: Double?
        /// Width / height of the document now; nil when unknown.
        public var canvasAspect: Double?

        public init(imageAspect: Double? = nil, canvasAspect: Double? = nil) {
            self.imageAspect = imageAspect
            self.canvasAspect = canvasAspect
        }

        /// Points are kept only when the canvas still has the shape of the image they refer to.
        public var keepsPoints: Bool {
            guard let image = imageAspect, let canvas = canvasAspect, image > 0, canvas > 0 else { return false }
            return (image >= 1) == (canvas >= 1) && abs(image - canvas) / canvas < 0.02
        }
    }

    public static let maxProblems = 8
    public static let translationLanguages: Set<String> = ["en", "fr", "es", "de", "it", "pt", "ja", "zh", "ko"]
    static let stepKeys: Set<String> = [
        "action", "target", "spatialHint", "ordinal", "all", "point", "attributes", "parameter", "amountMode", "amount", "look", "aspect",
        "degrees", "flipAxis", "text", "placement", "color", "background", "choiceIndex",
    ]

    private let mode: EditorMode

    public init(mode: EditorMode) {
        self.mode = mode
    }

    // MARK: Entry points

    /// A typed step list (the on-device model, a tapped idea): every check but the JSON ones.
    public func steps(raw: [RawIntentStep], context: IntentContext) -> Result<[EditIntent], ToolValidationError> {
        var problems: [String] = []
        if raw.isEmpty { problems.append("steps: at least 1 step") }
        if raw.count > 6 { problems.append("steps: at most 6 steps") }
        var intents: [EditIntent] = []
        for (index, step) in raw.enumerated() {
            if let intent = check(step, path: "steps[\(index)]", context: context, grounding: nil, problems: &problems) { intents.append(intent) }
        }
        return problems.isEmpty ? .success(intents) : .failure(.problems(Array(problems.prefix(Self.maxProblems))))
    }

    /// One streamed tool call, checked at content_block_stop.
    public func validate(_ use: RawToolUse, context: IntentContext, grounding: Grounding = Grounding()) -> Result<LiveToolCall, ToolValidationError> {
        guard let name = LiveToolName(rawValue: use.name) else { return .failure(.unknownTool(use.name)) }
        let input: JSONValue
        do {
            input = try JSONValue.parse(use.rawInput)
        } catch {
            return .failure(.invalidJSON(raw: use.rawInput))
        }
        guard case .object(let object) = input else { return .failure(.notAnObject) }
        var problems: [String] = []
        let tool: LiveTool?
        switch name {
        case .applyEdits:
            unknownKeys(object, allowed: ["steps"], path: "input", problems: &problems)
            let intents = stepList(object["steps"], path: "steps", range: 1...6, required: true, context: context, grounding: grounding, problems: &problems)
            tool = intents.map { .applyEdits($0) }
        case .undo:
            unknownKeys(object, allowed: ["count", "direction", "to_original"], path: "input", problems: &problems)
            let count = integer(object["count"], path: "count", problems: &problems) ?? 1
            if !(1...20).contains(count) { problems.append("count: \(count) is outside 1...20") }
            let direction = string(object["direction"], path: "direction", problems: &problems) ?? "undo"
            if !["undo", "redo"].contains(direction) { problems.append("direction: '\(direction)' is not one of undo, redo") }
            let toOriginal = boolean(object["to_original"], path: "to_original", problems: &problems) ?? false
            tool = .undo(count: count, redo: direction == "redo", toOriginal: toOriginal)
        case .compareBeforeAfter:
            unknownKeys(object, allowed: ["seconds"], path: "input", problems: &problems)
            let seconds = number(object["seconds"], path: "seconds", problems: &problems) ?? 2
            if !(1...5).contains(seconds) { problems.append("seconds: \(Self.format(seconds)) is outside 1...5") }
            tool = .compare(seconds: seconds)
        case .proposeIdeas:
            unknownKeys(object, allowed: ["ideas"], path: "input", problems: &problems)
            tool = ideaList(object["ideas"], context: context, grounding: grounding, problems: &problems).map { .proposeIdeas($0) }
        }
        guard problems.isEmpty, let tool else { return .failure(.problems(Array(problems.prefix(Self.maxProblems)))) }
        return .success(LiveToolCall(id: use.id, tool: tool))
    }

    // MARK: Lists

    private func stepList(_ value: JSONValue?, path: String, range: ClosedRange<Int>, required: Bool, context: IntentContext,
                          grounding: Grounding?, problems: inout [String]) -> [EditIntent]? {
        validatedSteps(value, path: path, range: range, required: required, context: context, grounding: grounding, problems: &problems)?.map(\.intent)
    }

    /// Each step as given (after a stale point is dropped) with the intent it normalizes to.
    private func validatedSteps(_ value: JSONValue?, path: String, range: ClosedRange<Int>, required: Bool, context: IntentContext,
                                grounding: Grounding?, problems: inout [String]) -> [(raw: RawIntentStep, intent: EditIntent)]? {
        guard let value, value != .null else {
            if required { problems.append("\(path): required") }
            return nil
        }
        guard case .array(let items) = value else {
            problems.append("\(path): must be an array")
            return nil
        }
        if !range.contains(items.count) { problems.append("\(path): \(items.count) steps, expected \(range.lowerBound)...\(range.upperBound)") }
        var result: [(raw: RawIntentStep, intent: EditIntent)] = []
        for (index, item) in items.enumerated() {
            let stepPath = "\(path)[\(index)]"
            guard var step = decodeStep(item, path: stepPath, problems: &problems) else { continue }
            if let grounding, !grounding.keepsPoints { step.point = nil }
            if let intent = check(step, path: stepPath, context: context, grounding: nil, problems: &problems) { result.append((step, intent)) }
        }
        return result
    }

    /// Ideas are checked one by one: an invalid idea comes back with no steps, for the handler to replace.
    private func ideaList(_ value: JSONValue?, context: IntentContext, grounding: Grounding?, problems: inout [String]) -> [LiveIdea]? {
        guard let value, value != .null else {
            problems.append("ideas: required")
            return nil
        }
        guard case .array(let items) = value else {
            problems.append("ideas: must be an array")
            return nil
        }
        guard (1...3).contains(items.count) else {
            problems.append("ideas: \(items.count) ideas, expected 1...3")
            return nil
        }
        return items.enumerated().map { index, item in
            var local: [String] = []
            let path = "ideas[\(index)]"
            guard case .object(let object) = item else {
                return LiveIdea(title: "", why: "", symbol: nil, steps: [], source: .claude)
            }
            unknownKeys(object, allowed: ["title", "why", "symbol", "steps"], path: path, problems: &local)
            // Over-long titles and whys are cut by LiveIdea rather than refused.
            let title = text(object["title"], path: "\(path).title", limit: 80, required: true, problems: &local) ?? ""
            let why = text(object["why"], path: "\(path).why", limit: 240, required: true, problems: &local) ?? ""
            let symbol = string(object["symbol"], path: "\(path).symbol", problems: &local)
            let steps = validatedSteps(object["steps"], path: "\(path).steps", range: 1...4, required: true, context: context, grounding: grounding, problems: &local)
            guard local.isEmpty, let steps else {
                return LiveIdea(title: title, why: why, symbol: symbol, steps: [], source: .claude)
            }
            return LiveIdea(title: title, why: why, symbol: symbol, steps: steps.map(\.raw), source: .claude)
        }
    }

    // MARK: One step

    /// JSON object -> RawIntentStep, with the type and unknown-key checks.
    func decodeStep(_ value: JSONValue, path: String, problems: inout [String]) -> RawIntentStep? {
        guard case .object(let object) = value else {
            problems.append("\(path): must be an object")
            return nil
        }
        let allowed = mode == .video ? Self.stepKeys.union(LiveToolSchema.videoFields) : Self.stepKeys
        unknownKeys(object, allowed: allowed, path: path, problems: &problems)
        guard let action = string(object["action"], path: "\(path).action", problems: &problems) else {
            if object["action"] == nil || object["action"] == .null { problems.append("\(path).action: required") }
            return nil
        }
        var step = RawIntentStep(action: action)
        step.target = string(object["target"], path: "\(path).target", problems: &problems)
        step.spatialHint = string(object["spatialHint"], path: "\(path).spatialHint", problems: &problems)
        step.ordinal = integer(object["ordinal"], path: "\(path).ordinal", problems: &problems)
        step.all = boolean(object["all"], path: "\(path).all", problems: &problems)
        step.point = point(object["point"], path: "\(path).point", problems: &problems)
        step.attributes = strings(object["attributes"], path: "\(path).attributes", problems: &problems)
        step.parameter = string(object["parameter"], path: "\(path).parameter", problems: &problems)
        step.amountMode = string(object["amountMode"], path: "\(path).amountMode", problems: &problems)
        step.amount = number(object["amount"], path: "\(path).amount", problems: &problems)
        step.look = string(object["look"], path: "\(path).look", problems: &problems)
        step.aspect = string(object["aspect"], path: "\(path).aspect", problems: &problems)
        step.degrees = number(object["degrees"], path: "\(path).degrees", problems: &problems)
        step.flipAxis = string(object["flipAxis"], path: "\(path).flipAxis", problems: &problems)
        step.text = string(object["text"], path: "\(path).text", problems: &problems)
        step.placement = string(object["placement"], path: "\(path).placement", problems: &problems)
        step.color = string(object["color"], path: "\(path).color", problems: &problems)
        step.background = string(object["background"], path: "\(path).background", problems: &problems)
        step.choiceIndex = integer(object["choiceIndex"], path: "\(path).choiceIndex", problems: &problems)
        if mode == .video {
            step.startSeconds = number(object["startSeconds"], path: "\(path).startSeconds", problems: &problems)
            step.endSeconds = number(object["endSeconds"], path: "\(path).endSeconds", problems: &problems)
            step.seconds = number(object["seconds"], path: "\(path).seconds", problems: &problems)
            step.clipNumber = integer(object["clipNumber"], path: "\(path).clipNumber", problems: &problems)
            step.transition = string(object["transition"], path: "\(path).transition", problems: &problems)
            step.speed = number(object["speed"], path: "\(path).speed", problems: &problems)
            step.scope = string(object["scope"], path: "\(path).scope", problems: &problems)
        }
        return step
    }

    /// Enums, ranges, strings, the mode, required fields, then IntentNormalizer.
    /// grounding nil keeps points as given (typed callers have no stale image).
    func check(_ original: RawIntentStep, path: String, context: IntentContext, grounding: Grounding?, problems: inout [String]) -> EditIntent? {
        let before = problems.count
        var step = original
        if let grounding, !grounding.keepsPoints { step.point = nil }

        // The action: exact, allowed in this editor, not a meta action.
        guard let action = IntentAction(rawValue: step.action) else {
            problems.append("\(path).action: '\(step.action)' is not a valid action")
            return nil
        }
        if LiveToolSchema.excluded.contains(action) {
            switch action {
            case .undo, .redo, .revert: problems.append("\(path).action: use the undo tool for \(action.rawValue)")
            case .compare: problems.append("\(path).action: use the compare_before_after tool")
            default: problems.append("\(path).action: \(action.rawValue) is not an editing step")
            }
            return nil
        }
        if !action.isAllowed(in: mode) {
            problems.append("\(path).action: \(action.rawValue) is not available for a \(mode.rawValue)")
            return nil
        }
        if mode != .video {
            let videoOnly: [(String, Bool)] = [
                ("startSeconds", step.startSeconds != nil), ("endSeconds", step.endSeconds != nil), ("seconds", step.seconds != nil),
                ("clipNumber", step.clipNumber != nil), ("transition", step.transition != nil), ("speed", step.speed != nil), ("scope", step.scope != nil),
            ]
            for (field, present) in videoOnly where present { problems.append("\(path).\(field): not available for a \(mode.rawValue)") }
        }
        if step.replacement != nil { problems.append("\(path).replacement: unknown field") }

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
        if let attributes = step.attributes {
            if attributes.count > 3 { problems.append("\(path).attributes: at most 3") }
            for (index, attribute) in attributes.enumerated() { checkText(attribute, "attributes[\(index)]", limit: 24) }
        }

        // Ranges.
        func within(_ value: Double?, _ field: String, _ range: ClosedRange<Double>) {
            guard let value else { return }
            if !range.contains(value) { problems.append("\(path).\(field): \(Self.format(value)) is outside \(Self.format(range.lowerBound))...\(Self.format(range.upperBound))") }
        }
        if let amount = step.amount {
            let amountMode: AmountSpec.Mode = step.amountMode == "absolute" ? .absolute : step.amountMode == "multiplier" ? .multiplier : .relative
            if AmountUnit.removesAtZero(action), amount == 0 {
                // punchIns 0 takes the zoom cuts off.
            } else if let unit = AmountUnit.for(action) {
                within(amount, "amount", unit.acceptedRange(mode: amountMode))
            } else {
                within(amount, "amount", amountMode == .multiplier ? 0...10 : -100...100)
            }
        }
        within(step.degrees, "degrees", -360...360)
        within(step.speed, "speed", 0.1...8)
        for (field, value) in [("seconds", step.seconds), ("startSeconds", step.startSeconds), ("endSeconds", step.endSeconds)] {
            if context.timelineDuration > 0 {
                within(value, field, 0...(context.timelineDuration + 0.5))
            } else if let value, value < 0 {
                problems.append("\(path).\(field): must be at least 0")
            }
        }
        if let start = step.startSeconds, let end = step.endSeconds, end <= start {
            problems.append("\(path).endSeconds: must be after startSeconds")
        }
        if let clip = step.clipNumber {
            let isTrack = [.removeMusic, .moveAudio, .fadeAudio].contains(action) || step.scope == "selection"
            let limit = isTrack ? max(context.clipCount, 8) : max(context.clipCount, 1)
            if clip != -1, !(1...limit).contains(clip) { problems.append("\(path).clipNumber: \(clip) is outside 1...\(limit) (or -1 for the last)") }
        }
        if let choice = step.choiceIndex {
            let limit = max(context.pendingClarification?.candidates.count ?? 0, context.clipCount, 1)
            if !(1...limit).contains(choice) { problems.append("\(path).choiceIndex: \(choice) is outside 1...\(limit)") }
        }
        if let ordinal = step.ordinal, !(1...20).contains(ordinal) { problems.append("\(path).ordinal: \(ordinal) is outside 1...20") }
        if let point = step.point, !(0...1).contains(point.x) || !(0...1).contains(point.y) {
            problems.append("\(path).point: x and y must be within 0...1")
        }
        if let color = step.color, PSColor.named(color) == nil, PSColor(hex: color) == nil {
            problems.append("\(path).color: '\(color)' is not a colour name or #RRGGBB")
        }
        if let background = step.background?.lowercased(), !["transparent", "none"].contains(background), !background.hasPrefix("blur"),
           PSColor.named(background) == nil, PSColor(hex: background) == nil {
            problems.append("\(path).background: '\(background)' is not a colour, transparent or blur")
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
        case .trim, .deleteRange: need(step.startSeconds != nil && step.endSeconds != nil, "startSeconds and endSeconds")
        case .seek: need(step.seconds != nil, "seconds")
        case .setSpeed: need(step.speed != nil, "speed")
        case .addTransition: need(step.transition != nil, "transition")
        case .translateCaptions:
            if let code = step.text?.trimmingCharacters(in: .whitespaces).lowercased(), Self.translationLanguages.contains(code) {} else {
                problems.append("\(path).text: translateCaptions needs one of \(Self.translationLanguages.sorted().joined(separator: ", "))")
            }
        default: break
        }

        guard problems.count == before else { return nil }
        guard let intent = IntentNormalizer.normalize(step, context: context) else {
            problems.append("\(path): not executable")
            return nil
        }
        return intent
    }

    // MARK: Typed readers

    private func unknownKeys(_ object: [String: JSONValue], allowed: Set<String>, path: String, problems: inout [String]) {
        for key in object.keys.sorted() where !allowed.contains(key) { problems.append("\(path).\(key): unknown field") }
    }

    private func string(_ value: JSONValue?, path: String, problems: inout [String]) -> String? {
        guard let value, value != .null else { return nil }
        guard case .string(let text) = value else {
            problems.append("\(path): must be a string")
            return nil
        }
        return text
    }

    private func text(_ value: JSONValue?, path: String, limit: Int, required: Bool, problems: inout [String]) -> String? {
        guard let text = string(value, path: path, problems: &problems) else {
            if required, value == nil || value == .null { problems.append("\(path): required") }
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { problems.append("\(path): empty") }
        if trimmed.count > limit { problems.append("\(path): longer than \(limit) characters") }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { problems.append("\(path): control characters") }
        return trimmed
    }

    private func number(_ value: JSONValue?, path: String, problems: inout [String]) -> Double? {
        guard let value, value != .null else { return nil }
        guard case .number(let number) = value, number.isFinite else {
            problems.append("\(path): must be a number")
            return nil
        }
        return number
    }

    private func integer(_ value: JSONValue?, path: String, problems: inout [String]) -> Int? {
        guard let number = number(value, path: path, problems: &problems) else { return nil }
        guard let integer = Int(exactly: number) else {
            problems.append("\(path): must be an integer")
            return nil
        }
        return integer
    }

    private func boolean(_ value: JSONValue?, path: String, problems: inout [String]) -> Bool? {
        guard let value, value != .null else { return nil }
        guard case .bool(let flag) = value else {
            problems.append("\(path): must be true or false")
            return nil
        }
        return flag
    }

    private func strings(_ value: JSONValue?, path: String, problems: inout [String]) -> [String]? {
        guard let value, value != .null else { return nil }
        guard case .array(let items) = value else {
            problems.append("\(path): must be an array of strings")
            return nil
        }
        var result: [String] = []
        for (index, item) in items.enumerated() {
            if let text = string(item, path: "\(path)[\(index)]", problems: &problems) { result.append(text) }
        }
        return result
    }

    private func point(_ value: JSONValue?, path: String, problems: inout [String]) -> PSPoint? {
        guard let value, value != .null else { return nil }
        guard case .object(let object) = value else {
            problems.append("\(path): must be an object with x and y")
            return nil
        }
        unknownKeys(object, allowed: ["x", "y"], path: path, problems: &problems)
        let x = number(object["x"], path: "\(path).x", problems: &problems)
        let y = number(object["y"], path: "\(path).y", problems: &problems)
        guard let x, let y else {
            if object["x"] == nil || object["y"] == nil { problems.append("\(path): needs x and y") }
            return nil
        }
        return PSPoint(x: x, y: y)
    }

    /// Numbers in problem lines read like the JSON they came from.
    static func format(_ value: Double) -> String {
        JSONValue.number(value).serialized()
    }
}
