import Foundation
import PicshopCore

/// Tool results in the shapes Live's brains read: a JSON payload for the
/// session and the log, and compactText(_:) (at most 300 characters) as the
/// tool response the local model and the Foundation Models bridge read.
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
        case .blocked:
            object["reason"] = "repeat"
        case .applied, .ignored, .queued:
            break
        }
        // The machine channel, for the log and the Foundation Models bridge: codes and facts, never spoken.
        if let reason = step.reason, step.status != .skipped, step.status != .blocked { object["code"] = .string(reason.rawValue) }
        if let report = step.report { object["facts"] = .string(LiveSceneLines.reportFacts(report)) }
        if let verification = step.verification { object["verification"] = .string(verification.summary) }
        if let created = step.createdRef { object["id"] = .string(created) }
        if let hint = step.hint { object["hint"] = .string(hint) }
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

    /// At most 300 characters: the tool response a local model reads (v2). English, never spoken:
    /// - `1 fillCells applied: Fill Cells; filled 44, kept 1, empty left 0`
    /// - `1 textBehind failed[no_subject]: no person or main subject here. Do not retry this step. Hint: …`
    /// - `1 fillCells info[no_table]: no table found. Hint: Ask the user to crop to the table; …`
    /// - `1 textBehind blocked[repeat]: already failed this turn. Say one sentence or ask one question.`
    /// - `1 addText applied: Add Text; verify failed 1/1: text missing. Hint: …`
    /// A step with a reason never carries the executor's French message; one without keeps it.
    public static func compactText(_ result: LiveToolResult) -> String {
        let text: String
        if let execution = result.execution {
            var detail = Detail.full
            var rendered = execution.steps.map { stepText($0, detail: detail) }.joined(separator: "; ")
            while rendered.count > 300, let lighter = detail.lighter {
                detail = lighter
                rendered = execution.steps.map { stepText($0, detail: detail) }.joined(separator: "; ")
            }
            text = rendered
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

    /// How much of a step a result can afford, from everything down to the codes.
    enum Detail: Int {
        case full, noAppliedLabels, noHints, codes

        var lighter: Detail? { Detail(rawValue: rawValue + 1) }
    }

    static func stepText(_ step: LiveStepResult, detail: Detail = .full) -> String {
        var part = "\(step.index + 1) \(step.action.rawValue) \(step.status.rawValue)"
        switch step.status {
        case .blocked:
            return part + "[repeat]: already failed this turn. Say one sentence or ask one question."
        case .applied:
            var facts: [String] = []
            // "Add Text (l1)", "Edit Text (now l2)": the id of the layer the step wrote, for a repair or a follow-up.
            if let label = step.label, detail == .full || step.report == nil {
                if let created = step.createdRef {
                    // A rewrite or a move of printed text leaves a new layer in its place: "now l2".
                    let renamed = step.action == .editText || step.action == .moveText
                    facts.append("\(label) (\(renamed ? "now " : "")\(created))")
                } else {
                    facts.append(label)
                }
            } else if let created = step.createdRef {
                facts.append(created)
            }
            if let report = step.report { facts.append(LiveSceneLines.reportFacts(report)) }
            if let verification = step.verification, verification.status != .unverified {
                facts.append(detail == .codes ? (verification.status == .failed ? "verify failed" : "verified") : verification.summary)
            }
            if !facts.isEmpty { part += ": " + facts.joined(separator: "; ") }
            if step.verification?.status == .failed, let hint = step.hint, detail.rawValue < Detail.noHints.rawValue { part += ". Hint: " + hint }
            return part
        default:
            break
        }
        if let reason = step.reason, step.status != .skipped {
            part += "[\(reason.rawValue)]: " + reasonText(reason, step: step)
            if step.status == .failed, detail != .codes { part += " Do not retry this step." }
            if let hint = step.hint, detail.rawValue < Detail.noHints.rawValue { part += " Hint: " + hint }
        } else if let message = step.message, !message.isEmpty {
            part += ": \(message)"
        }
        if step.status == .needsClarification, !step.candidates.isEmpty {
            part += " [" + step.candidates.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: ", ") + "]"
        }
        return part
    }

    /// What a reason code means, in the model's English.
    static func reasonText(_ reason: ExecutionReason, step: LiveStepResult) -> String {
        switch reason {
        case .noSubject: return "no person or main subject here."
        case .notFound: return "not found in the picture."
        case .noTable: return "no table found."
        case .unknownRow: return "no such row."
        case .unknownColumn: return "no such column."
        case .ambiguous: return "several match; ask which one."
        case .nothingToDo: return LiveTurnRouter.tableActions.contains(step.action) ? "those cells are already filled." : "nothing to change."
        case .tooMany: return "more than 400 cells in one step."
        case .needsSelection: return "the user must tap or circle the area."
        case .unsupported: return "not possible on this picture."
        case .unknownRef: return "that id is not on the picture."
        case .badRegion: return "the box is off the picture or too small."
        case .noText: return "no text there."
        case .verifyFailed: return step.verification?.summary ?? "the result does not read as asked."
        }
    }
}
