import Foundation
import PicshopCore

public enum ToolValidationError: Error, Sendable, Equatable { case invalidJSON(raw: String), notAnObject, unknownTool(String), problems([String]) }

/// Strict client-side validation of tool input: eager input streaming turns
/// the server-side checks off, so nothing unchecked may reach the executor.
public struct ToolInputValidator: Sendable {
    private let mode: EditorMode

    public init(mode: EditorMode) {
        self.mode = mode
    }

    public func steps(raw: [RawIntentStep], context: IntentContext) -> Result<[EditIntent], ToolValidationError> {
        // Phase 0 stub: the normalizer alone, without the strict checks.
        var intents: [EditIntent] = []
        var problems: [String] = []
        for (index, step) in raw.enumerated() {
            if let intent = IntentNormalizer.normalize(step, context: context) {
                intents.append(intent)
            } else {
                problems.append("steps[\(index)]: not executable")
            }
        }
        return problems.isEmpty ? .success(intents) : .failure(.problems(problems))
    }
}
