import Foundation
import PicshopCore

/// Tool results in the shapes each brain reads: one JSON text block for
/// Claude, a short sentence for the on-device model.
public enum ToolResultEncoder {
    public static let invalidInputHint = "Fix these fields and call the tool again."

    /// apply_edits: `{"ok":true,"results":[...],"can_undo":true,"version":13}`.
    /// is_error only when every step that ran failed (invalid input is `invalid(_:)`).
    public static func applyEdits(_ execution: LiveExecution) -> LiveToolResult {
        let ran = execution.steps.filter { $0.status != .skipped }
        let everyStepFailed = !ran.isEmpty && ran.allSatisfy { $0.status == .failed }
        let payload: JSONValue = [
            "ok": .bool(!everyStepFailed),
            "results": .array(execution.steps.map(stepJSON)),
            "can_undo": .bool(execution.canUndo),
            "version": .number(Double(execution.version)),
        ]
        return LiveToolResult(isError: everyStepFailed, payload: payload, changedDocument: execution.anyApplied, execution: execution)
    }

    static func stepJSON(_ step: LiveStepResult) -> JSONValue {
        var object: [String: JSONValue] = [
            "step": .number(Double(step.index + 1)),
            "action": .string(step.action.rawValue),
            "status": .string(step.status.rawValue),
        ]
        if let label = step.label { object["label"] = .string(label) }
        switch step.status {
        case .info, .failed:
            if let message = step.message { object["message"] = .string(message) }
        case .needsClarification:
            if let message = step.message { object["question"] = .string(message) }
            object["candidates"] = .array(step.candidates.enumerated().map { ["index": .number(Double($0.offset + 1)), "label": .string($0.element)] })
        case .needsUser:
            if let needs = step.needsUser { object["needs"] = .string(needs) }
            if let message = step.message { object["message"] = .string(message) }
        case .skipped:
            object["reason"] = "a previous step did not apply"
        case .running:
            object["job"] = .string(step.action.rawValue)
        case .applied, .ignored, .queued:
            break
        }
        return .object(object)
    }

    /// undo: `{"ok":true,"undone":[labels],"version":n}` (or "redone"). Nothing to undo is not an error.
    public static func undo(labels: [String], redo: Bool, version: Int, language: NormalizedUtterance.Language = .english) -> LiveToolResult {
        guard !labels.isEmpty else {
            let message = redo ? "There is nothing to redo." : "There is nothing to undo."
            return LiveToolResult(isError: false, payload: ["ok": false, "message": .string(message), "version": .number(Double(version))], changedDocument: false)
        }
        let payload: JSONValue = ["ok": true, redo ? "redone" : "undone": .array(labels.map { .string($0) }), "version": .number(Double(version))]
        return LiveToolResult(isError: false, payload: payload, changedDocument: true)
    }

    public static func compare() -> LiveToolResult {
        LiveToolResult(isError: false, payload: ["ok": true], changedDocument: false)
    }

    public static func ideas(shown: Int, replaced: Int) -> LiveToolResult {
        LiveToolResult(isError: false, payload: ["ok": true, "shown": .number(Double(shown)), "replaced": .number(Double(replaced))], changedDocument: false)
    }

    /// The error result for input that failed validation. Built with JSONValue, so quotes in the raw input are escaped.
    public static func invalid(_ error: ToolValidationError) -> LiveToolResult {
        let payload: JSONValue
        switch error {
        case .invalidJSON(let raw):
            payload = ["INVALID_JSON": .string(raw)]
        case .notAnObject:
            payload = ["error": "invalid_input", "problems": ["input: must be an object"], "hint": .string(invalidInputHint)]
        case .unknownTool(let name):
            payload = ["error": "unknown_tool", "name": .string(name), "hint": "Use apply_edits, undo, compare_before_after or propose_ideas."]
        case .problems(let problems):
            payload = ["error": "invalid_input", "problems": .array(problems.prefix(ToolInputValidator.maxProblems).map { .string($0) }), "hint": .string(invalidInputHint)]
        }
        return LiveToolResult(isError: true, payload: payload, changedDocument: false)
    }

    /// Past the per-turn limits: nothing ran.
    public static func loopLimit() -> LiveToolResult {
        LiveToolResult(isError: true, payload: ["error": "loop_limit", "hint": "Stop calling tools this turn; tell the user in one sentence."], changedDocument: false)
    }

    /// The tool_result block Claude reads: one text block, serialized with JSONValue.
    public static func block(_ result: LiveToolResult, toolUseID: String) -> ClaudeContentBlock {
        .toolResult(toolUseID: toolUseID, content: [.text(result.payload.serialized())], isError: result.isError)
    }

    /// At most 300 characters, for the on-device model.
    public static func compactText(_ result: LiveToolResult) -> String {
        let text: String
        if let execution = result.execution {
            text = execution.steps.map { step in
                var part = "\(step.index + 1) \(step.action.rawValue) \(step.status.rawValue)"
                if let label = step.label, step.status == .applied { part += ": \(label)" }
                if let message = step.message, step.status != .applied { part += ": \(message)" }
                if step.status == .needsClarification, !step.candidates.isEmpty {
                    part += " [" + step.candidates.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: ", ") + "]"
                }
                return part
            }.joined(separator: "; ")
        } else if let problems = result.payload["problems"]?.array {
            text = "Invalid input: " + problems.compactMap(\.string).joined(separator: "; ")
        } else if result.payload["INVALID_JSON"] != nil {
            text = "Invalid JSON input."
        } else if let undone = (result.payload["undone"] ?? result.payload["redone"])?.array {
            text = (result.payload["undone"] != nil ? "Undone: " : "Redone: ") + undone.compactMap(\.string).joined(separator: ", ")
        } else if let message = result.payload["message"]?.string {
            text = message
        } else if result.payload["error"]?.string == "loop_limit" {
            text = "Too many tool calls; answer the user now."
        } else {
            text = result.payload["ok"]?.bool == false ? "Not done." : "Done."
        }
        return text.count <= 300 ? text : String(text.prefix(299)) + "…"
    }
}
