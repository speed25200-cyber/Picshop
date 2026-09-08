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
            if let plan = try? decoder.decode(RawPlan.self, from: data) { return plan }
            if let step = try? decoder.decode(RawIntentStep.self, from: data) { return RawPlan(steps: [step]) }
            if let loose = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return fromLoose(loose) }
        }
        return nil
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
