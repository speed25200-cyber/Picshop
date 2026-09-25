import Foundation
import PicshopCore

/// What the model reads after a step that did not do what was asked: one English sentence toward the
/// closest action that can work (a subject action on a table → fillCells; an unknown id → the ids
/// the scene lines show). Model-only, never spoken; `ToolResultEncoder.compactText` appends it as
/// "Hint: …". Nil when there is nothing better to suggest than asking the user.
public enum ToolHints {
    /// The actions that need a person or a main subject to cut out.
    public static let subjectActions: Set<IntentAction> = [.textBehind, .removeBackground, .replaceBackground, .blurBackground]

    public static func hint(for reason: ExecutionReason, action: IntentAction, hasTable: Bool) -> String? {
        let tableAction = LiveTurnRouter.tableActions.contains(action)
        switch reason {
        case .noSubject:
            if hasTable { return "To write in the table use fillCells; to mark a row or column use highlightCells." }
            if action == .textBehind { return "Use addText with a placement or a box instead." }
            return "Offer a look, a crop or addText instead; this picture has nothing to cut out."
        case .notFound:
            return "Use a point from the last image or an id from the objects line, or ask the user to tap it."
        case .noTable:
            return tableAction ? "Ask the user to crop to the table; never write cells with addText." : nil
        case .unknownRow:
            return "Use a row name or number exactly as the rows line prints it."
        case .unknownColumn:
            return "Use a column name or number exactly as the cols line prints it."
        case .ambiguous:
            return "Ask the user which one, naming the candidates."
        case .nothingToDo:
            return tableAction ? "Use cells all to overwrite your own values, or tell the user it is already done." : "Tell the user it is already done."
        case .tooMany:
            return "Name a column or a row to fill fewer cells."
        case .needsSelection:
            return "Ask the user to tap or circle the area, or give a box."
        case .unsupported:
            return hasTable ? "For table cells use fillCells, clearCells or highlightCells." : nil
        case .unknownRef:
            return "Use an id printed in the texts, objects or free lines of the editor state."
        case .badRegion:
            return "Give box as [x1, y1, x2, y2] from 0 to 1000 inside the picture, at least 20 wide and high."
        case .noText:
            return "Use a text id (t or l) from the texts line."
        case .verifyFailed:
            switch action {
            case .fillCells: return "Fill only the failing cells again with cells all, or tell the user which cells did not come out."
            case .addText, .editText, .moveText: return "Try once with a larger size or a clearer spot (a free area), or tell the user."
            case .removeObject, .eraseRegion, .removeText, .clearCells: return "Erase a slightly larger box once, or tell the user what is left."
            default: return "Tell the user in one sentence what did not come out."
            }
        }
    }

    /// The problem the validator gives a subject action on a picture that has no subject to cut out.
    public static let noSubjectProblem = "this picture is a table screenshot with no subject; use fillCells, highlightCells or clearCells"
    /// The same on a screenshot or document without people.
    public static let noSubjectScreenshotProblem = "this picture is a screenshot or document with no person or subject; use addText, editText or eraseRegion"
}
