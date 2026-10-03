import Foundation
import PicshopCore

/// Extracts a `RawPlan` from free-form model output. Tolerates markdown fences,
/// leading chatter, trailing commas and single-object responses.
public enum LLMResponseParser {
    public static func parse(_ text: String) -> RawPlan? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenced = extractFenced(candidate) { candidate = fenced }
        guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        var json = String(candidate[start...end])
        json = repair(json)
        let decoder = JSONDecoder()
        if let data = json.data(using: .utf8) {
            if let plan = try? decoder.decode(RawPlan.self, from: data) { return withExtras(plan, json: json) }
            if let step = try? decoder.decode(RawIntentStep.self, from: data) { return withExtras(RawPlan(steps: [step]), json: json) }
            if let loose = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return fromLoose(loose) }
        }
        return nil
    }

    /// Catalog operations ("curves", "layerBlend") carry their own arguments, which RawIntentStep has no
    /// field for: they are kept in `extra` (every key but action; nested arguments lifted) for the normalizer.
    static func withExtras(_ plan: RawPlan, json: String) -> RawPlan {
        guard plan.steps.contains(where: { IntentAction(rawValue: $0.action) == nil }), let value = try? JSONValue.parse(json),
              case .object(let top) = value else { return plan }
        let items: [JSONValue]
        if case .array(let steps)? = top["steps"] ?? top["actions"] ?? top["intents"] {
            items = steps
        } else if top["action"] != nil {
            items = [value]
        } else {
            return plan
        }
        var result = plan
        for index in result.steps.indices where index < items.count && IntentAction(rawValue: result.steps[index].action) == nil {
            guard case .object(let object) = items[index] else { continue }
            result.steps[index].extra = arguments(of: object)
        }
        return result
    }

    /// A step object's arguments: nested "arguments"/"params"/"parameters" lifted, "action" left out.
    static func arguments(of step: [String: JSONValue]) -> [String: JSONValue]? {
        var object = step
        for key in ["arguments", "params", "parameters"] {
            guard case .object(let nested)? = object[key] else { continue }
            for (name, value) in nested where object[name] == nil { object[name] = value }
            object[key] = nil
        }
        object["action"] = nil
        return object.isEmpty ? nil : object
    }

    static func extractFenced(_ text: String) -> String? {
        guard let range = text.range(of: "```") else { return nil }
        var body = String(text[range.upperBound...])
        if body.lowercased().hasPrefix("json") { body = String(body.dropFirst(4)) }
        if let close = body.range(of: "```") { body = String(body[..<close.lowerBound]) }
        return body
    }

    /// Removes trailing commas and normalises smart quotes.
    static func repair(_ json: String) -> String {
        var s = json.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        s = s.replacingOccurrences(of: ",\\s*\\}", with: "}", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*\\]", with: "]", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\bNone\\b", with: "null", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\bTrue\\b", with: "true", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\bFalse\\b", with: "false", options: .regularExpression)
        return s
    }

    /// Handles slightly off schema (numbers as strings, nested "arguments" objects…).
    static func fromLoose(_ object: [String: Any]) -> RawPlan? {
        var stepsArray: [[String: Any]] = []
        if let steps = object["steps"] as? [[String: Any]] { stepsArray = steps }
        else if let steps = object["actions"] as? [[String: Any]] { stepsArray = steps }
        else if let steps = object["intents"] as? [[String: Any]] { stepsArray = steps }
        else if object["action"] != nil { stepsArray = [object] }
        let steps: [RawIntentStep] = stepsArray.compactMap { dict in
            var merged = dict
            let nested = (dict["arguments"] as? [String: Any]) ?? (dict["params"] as? [String: Any]) ?? (dict["parameters"] as? [String: Any])
            if let args = nested {
                for (key, value) in args where merged[key] == nil { merged[key] = value }
            }
            let actionName = (merged["action"] as? String) ?? (merged["name"] as? String) ?? (merged["type"] as? String)
            guard let action = actionName else { return nil }
            func string(_ key: String) -> String? {
                if let value = merged[key] as? String { return value }
                if let value = merged[key] as? NSNumber { return value.stringValue }
                return nil
            }
            func double(_ key: String) -> Double? {
                if let value = merged[key] as? NSNumber { return value.doubleValue }
                if let value = merged[key] as? String { return Double(value.replacingOccurrences(of: "%", with: "")) }
                return nil
            }
            func int(_ key: String) -> Int? { double(key).map { Int($0) } }
            func bool(_ key: String) -> Bool? {
                if let value = merged[key] as? Bool { return value }
                if let value = merged[key] as? String { return value.lowercased() == "true" }
                return nil
            }
            if IntentAction(rawValue: action) == nil, OperationCatalog.shared.spec(OpID(action))?.lowering == .handler,
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let text = String(data: data, encoding: .utf8), case .object(let object)? = try? JSONValue.parse(text) {
                // A catalog operation: its arguments as given.
                var step = RawIntentStep(action: action)
                step.extra = arguments(of: object)
                return step
            }
            return RawIntentStep(action: action, target: string("target") ?? string("object"), spatialHint: string("spatialHint") ?? string("position"),
                                 ordinal: int("ordinal"), all: bool("all"), parameter: string("parameter") ?? string("param"),
                                 amountMode: string("amountMode") ?? string("mode"), amount: double("amount") ?? double("value"), look: string("look") ?? string("filter"),
                                 aspect: string("aspect") ?? string("ratio"), degrees: double("degrees") ?? double("angle"), flipAxis: string("flipAxis") ?? string("axis"),
                                 text: string("text"), placement: string("placement"), color: string("color") ?? string("colour"), background: string("background"),
                                 startSeconds: double("startSeconds") ?? double("start"), endSeconds: double("endSeconds") ?? double("end"),
                                 seconds: double("seconds") ?? double("time"), clipNumber: int("clipNumber") ?? int("clip"), transition: string("transition"),
                                 speed: double("speed"), choiceIndex: int("choiceIndex") ?? int("index"), scope: string("scope"),
                                 replacement: string("replacement") ?? string("newText") ?? string("with"))
        }
        return RawPlan(steps: steps, reply: object["reply"] as? String, clarification: object["clarification"] as? String, language: object["language"] as? String)
    }
}
