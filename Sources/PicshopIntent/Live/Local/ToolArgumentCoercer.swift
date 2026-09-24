import Foundation
import PicshopCore

/// Turns a local model's tool arguments into the strict JSON ToolInputValidator expects.
///
/// A 2–4B model knows what it wants but writes it loosely. The XML-function
/// dialect sends every parameter as text, and small models add their own habits.
/// The coercer repairs the form, never the meaning:
/// - arrays and objects sent as strings are parsed (trailing commas, smart or
///   single quotes and Python literals repaired); a single step or idea is
///   wrapped into its list;
/// - numbers sent as strings ("15", "+15", "15 %", "0,5") become numbers,
///   booleans ("true", "True", "oui", 1) become booleans, per field;
/// - a point in Qwen-VL's 0–1000 grid (or as `[x, y]`, "x,y", or a box) becomes
///   `{"x", "y"}` in 0–1;
/// - enum values that differ only by case or separators ("Temperature",
///   "apply_look", "16:9") become the exact value; anything else is left for
///   the validator to refuse;
/// - nulls are dropped; tool names are normalised (`applyEdits`, `redo`).
/// Unknown fields stay: the validator names them, and the model corrects itself.
public enum ToolArgumentCoercer {
    /// Model arguments (arrays or numbers sent as strings, points in 0...1000, nulls) → the strict JSON ToolInputValidator expects.
    public static func rawToolUse(id: String, name: String, arguments: JSONValue) -> RawToolUse {
        var (tool, object) = normalizedCall(name: name, arguments: arguments)
        switch LiveToolName(rawValue: tool) {
        case .applyEdits?:
            object = applyEdits(object)
        case .undo?:
            object = undo(object)
        case .compareBeforeAfter?:
            object = compare(object)
        case .proposeIdeas?:
            object = proposeIdeas(object)
        case nil:
            break
        }
        return RawToolUse(id: id, name: tool, rawInput: JSONValue.object(object).serialized())
    }

    // MARK: Tools

    /// The tool's canonical name, and its arguments as an object.
    static func normalizedCall(name: String, arguments original: JSONValue) -> (String, [String: JSONValue]) {
        let key = foldedKey(name)
        var arguments = original
        if case .string(let text) = original, let parsed = lenientJSON(text) { arguments = parsed }
        var object = argumentsObject(arguments)
        switch key {
        case "applyedits", "applyedit", "edit", "edits":
            if object["steps"] == nil, case .array = arguments { object = ["steps": arguments] }
            return (LiveToolName.applyEdits.rawValue, object)
        case "undo":
            return (LiveToolName.undo.rawValue, object)
        case "redo":
            if object["direction"] == nil { object["direction"] = "redo" }
            return (LiveToolName.undo.rawValue, object)
        case "comparebeforeafter", "compare", "comparebefore", "showbefore", "beforeafter":
            return (LiveToolName.compareBeforeAfter.rawValue, object)
        case "proposeideas", "proposeidea", "ideas", "suggestideas":
            if object["ideas"] == nil, case .array = arguments { object = ["ideas": arguments] }
            return (LiveToolName.proposeIdeas.rawValue, object)
        default:
            return (name.trimmingCharacters(in: .whitespacesAndNewlines), object)
        }
    }

    private static func argumentsObject(_ arguments: JSONValue) -> [String: JSONValue] {
        switch arguments {
        case .object(let object):
            return dropNulls(object)
        case .string(let text):
            if let parsed = lenientJSON(text), case .object(let object) = parsed { return dropNulls(object) }
            return [:]
        default:
            return [:]
        }
    }

    static func applyEdits(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if object["steps"] == nil, object["action"] != nil {
            // One step written as the arguments themselves.
            object = ["steps": .array([.object(input)])]
        }
        if let steps = object["steps"] { object["steps"] = stepList(steps) }
        return object
    }

    static func undo(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if let count = object["count"] { object["count"] = integer(count) ?? number(count) ?? count }
        if let direction = object["direction"]?.string {
            let folded = foldedKey(direction)
            object["direction"] = .string(["redo", "refaire", "retablir"].contains(folded) ? "redo" : ["undo", "annuler", "back"].contains(folded) ? "undo" : direction)
        }
        if let flag = object["to_original"] { object["to_original"] = boolean(flag) ?? flag }
        return object
    }

    static func compare(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if let seconds = object["seconds"] { object["seconds"] = number(seconds) ?? seconds }
        return object
    }

    static func proposeIdeas(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var object = input
        if object["ideas"] == nil, object["title"] != nil { object = ["ideas": .array([.object(input)])] }
        guard let ideas = object["ideas"] else { return object }
        object["ideas"] = list(ideas).map { items in
            .array(items.map { item -> JSONValue in
                guard case .object(var idea) = item else { return item }
                idea = dropNulls(idea)
                for key in ["title", "why", "symbol"] {
                    if let value = idea[key], let text = scalarText(value) { idea[key] = .string(text) }
                }
                if let steps = idea["steps"] { idea["steps"] = stepList(steps) }
                return .object(idea)
            })
        } ?? ideas
        return object
    }

    // MARK: Steps

    static let numberFields = ["amount", "degrees", "startSeconds", "endSeconds", "seconds", "speed"]
    static let integerFields = ["ordinal", "choiceIndex", "clipNumber"]
    static let booleanFields = ["all"]
    static let textFields = ["target", "text", "color", "background"]

    private static func stepList(_ value: JSONValue) -> JSONValue {
        guard let items = list(value) else { return value }
        return .array(items.map { item in
            guard case .object(let step) = item else { return item }
            return .object(coerceStep(step))
        })
    }

    /// One apply_edits step: types, enums, point, aliases.
    static func coerceStep(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var step = dropNulls(input)
        // Unambiguous aliases small models use.
        for (alias, field) in [("value", "amount"), ("param", "parameter"), ("preset", "look"), ("filter", "look")] where step[field] == nil {
            if let value = step.removeValue(forKey: alias) { step[field] = value }
        }
        for field in numberFields { if let value = step[field] { step[field] = number(value) ?? value } }
        // A number that is not whole stays a number, so the validator says "must be an integer".
        for field in integerFields { if let value = step[field] { step[field] = integer(value) ?? number(value) ?? value } }
        for field in booleanFields { if let value = step[field] { step[field] = boolean(value) ?? value } }
        for field in textFields { if let value = step[field], let text = scalarText(value) { step[field] = .string(text) } }
        for (field, values) in enumFields {
            if let text = step[field]?.string { step[field] = .string(canonical(text, among: values, field: field)) }
        }
        if let attributes = step["attributes"] {
            switch attributes {
            case .string(let text):
                let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                step["attributes"] = .array(parts.map { .string($0) })
            case .array(let items):
                step["attributes"] = .array(items.map { scalarText($0).map { .string($0) } ?? $0 })
            default:
                break
            }
        }
        if let point = step["point"] {
            step["point"] = self.point(point) ?? point
        } else if let box = ["bbox_2d", "bbox", "box"].lazy.compactMap({ step[$0] }).first, let center = boxCenter(box) {
            step["point"] = center
        }
        if step["point"] != nil { for key in ["bbox_2d", "bbox", "box"] { step[key] = nil } }
        return step
    }

    static let enumFields: [(String, [String])] = [
        ("action", IntentAction.allCases.map(\.rawValue)),
        ("parameter", AdjustmentParameter.allCases.map(\.rawValue)),
        ("look", FilterPreset.allCases.map(\.rawValue)),
        ("aspect", AspectPreset.allCases.map(\.rawValue)),
        ("spatialHint", SpatialHint.allCases.map(\.rawValue)),
        ("flipAxis", FlipAxis.allCases.map(\.rawValue)),
        ("placement", TextElement.Placement.allCases.map(\.rawValue)),
        ("transition", TransitionKind.allCases.map(\.rawValue)),
        ("amountMode", ["relative", "absolute", "multiplier"]),
        ("scope", ["current", "all", "selection"]),
    ]

    /// The exact enum value that `text` spells with another case or separators.
    static func canonical(_ text: String, among values: [String], field: String) -> String {
        if values.contains(text) { return text }
        var key = foldedKey(text)
        if field == "aspect" {
            // "16:9", "16/9", "16 x 9" → ratio16x9; "carré" → square.
            let digits = text.split(whereSeparator: { !$0.isNumber })
            if digits.count == 2 { key = "ratio\(digits[0])x\(digits[1])" }
            if ["carre", "square", "11", "ratio1x1"].contains(key) { key = "square" }
        }
        return values.first { foldedKey($0) == key } ?? text
    }

    // MARK: Points

    /// `{"x": 512, "y": 300}`, `[512, 300]` or "512, 300": 0–1000 (Qwen-VL) or already 0–1.
    static func point(_ value: JSONValue) -> JSONValue? {
        var pair: (Double, Double)?
        switch value {
        case .object(let object):
            if let x = object["x"].flatMap(number)?.double, let y = object["y"].flatMap(number)?.double { pair = (x, y) }
        case .array(let items) where items.count == 2:
            if let x = number(items[0])?.double, let y = number(items[1])?.double { pair = (x, y) }
        case .string(let text):
            if let parsed = lenientJSON(text), parsed != value { return point(parsed) }
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).compactMap { number(.string(String($0)))?.double }
            if parts.count == 2 { pair = (parts[0], parts[1]) }
        default:
            break
        }
        guard let (x, y) = pair else { return nil }
        let scale = max(x, y) > 1 ? 1_000.0 : 1
        func unit(_ value: Double) -> Double {
            let scaled = value / scale
            // Within the grid (a hair outside is rounding): clamped; far outside stays for the validator.
            return (-0.01...1.01).contains(scaled) ? min(max(scaled, 0), 1) : scaled
        }
        return ["x": .number(round4(unit(x))), "y": .number(round4(unit(y)))]
    }

    /// A box `[x1, y1, x2, y2]` (0–1000 or 0–1): its centre.
    static func boxCenter(_ value: JSONValue) -> JSONValue? {
        var box = value
        if case .string(let text) = value, let parsed = lenientJSON(text) { box = parsed }
        guard let items = box.array, items.count == 4 else { return nil }
        let numbers = items.compactMap { number($0)?.double }
        guard numbers.count == 4 else { return nil }
        return point(.array([.number((numbers[0] + numbers[2]) / 2), .number((numbers[1] + numbers[3]) / 2)]))
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    // MARK: Scalars

    /// A number, or a string that is one ("15", "+15", "15 %", "0,5", "-20°").
    static func number(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .number:
            return value
        case .string(let text):
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in ["%", "°", "s", "x", "×"] where cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            if cleaned.hasPrefix("+") { cleaned.removeFirst() }
            if cleaned.contains(","), !cleaned.contains(".") { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
            guard !cleaned.isEmpty, let parsed = Double(cleaned), parsed.isFinite else { return nil }
            return .number(parsed)
        case .bool(let flag):
            return .number(flag ? 1 : 0)
        default:
            return nil
        }
    }

    /// A whole number (2, 2.0, "2").
    static func integer(_ value: JSONValue) -> JSONValue? {
        guard let parsed = number(value)?.double, let whole = Int(exactly: parsed.rounded()), abs(parsed - parsed.rounded()) < 1e-9 else { return nil }
        return .number(Double(whole))
    }

    static func boolean(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .bool:
            return value
        case .number(let number):
            if number == 1 { return .bool(true) }
            if number == 0 { return .bool(false) }
            return nil
        case .string(let text):
            switch foldedKey(text) {
            case "true", "yes", "oui", "vrai", "1": return .bool(true)
            case "false", "no", "non", "faux", "0": return .bool(false)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A number written where text is expected ("2024" for addText) becomes its text.
    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number: return value.serialized()
        default: return nil
        }
    }

    private static func list(_ value: JSONValue) -> [JSONValue]? {
        switch value {
        case .array(let items):
            return items
        case .object:
            return [value]
        case .string(let text):
            guard let parsed = lenientJSON(text) else { return nil }
            if case .string = parsed { return nil }
            return list(parsed)
        default:
            return nil
        }
    }

    private static func dropNulls(_ object: [String: JSONValue]) -> [String: JSONValue] {
        object.filter { $0.value != .null }
    }

    /// Lowercased, without accents, spaces, dashes or underscores.
    static func foldedKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Lenient JSON

    /// Strict JSON, else the same text with smart quotes, trailing commas, Python
    /// literals and single quotes repaired. Nil when it is still not JSON.
    static func lenientJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let strict = try? JSONValue.parse(trimmed) { return strict }
        guard trimmed.first == "[" || trimmed.first == "{" else { return nil }
        var repaired = LLMResponseParser.repair(trimmed)
        if let parsed = try? JSONValue.parse(repaired) { return parsed }
        if !repaired.contains("\"") {
            repaired = repaired.replacingOccurrences(of: "'", with: "\"")
            if let parsed = try? JSONValue.parse(repaired) { return parsed }
        }
        return nil
    }
}
