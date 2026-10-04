import Foundation

/// What a tool panel remembers from the moment it opened (ux-spec §4.5 « Sessions », §3.5.2 row A): edits are saved
/// as they happen; ↶ inside the panel stops at the opening step; « Annuler » asks when anything changed, then pushes
/// **one** step back to the open-time document (« Modifications de Lumière abandonnées »), so ↶ brings the work
/// back. History is never trimmed. Pure, so the rule is tested on Linux; the UI's PanelSession drives it.
public struct PanelSessionLedger<State: Hashable & Sendable>: Sendable {
    /// The strip tool's id ("adjust.light").
    public let toolID: String
    /// The document when the panel opened.
    public let openState: State
    /// The number of undo steps when the panel opened.
    public let openDepth: Int

    public init(toolID: String, history: EditHistory<State>) {
        self.toolID = toolID
        openState = history.present
        openDepth = history.count
    }

    /// Something differs from the open-time document: « Annuler » asks first.
    public func hasChanges(_ history: EditHistory<State>) -> Bool {
        history.present != openState
    }

    /// ↶ may act: there is a step newer than the opening one. False at the opening step, where ↶ is dimmed with the
    /// hint « Touchez OK pour annuler les étapes précédentes ». (History trimmed at its limit inside one session
    /// keeps ↶ available only while the count stays above the opening depth.)
    public func canUndoInside(_ history: EditHistory<State>) -> Bool {
        history.count > openDepth
    }

    /// « Abandonner les modifications »: one step back to the open-time document, labelled `label`. False when there
    /// was nothing to abandon (no step is pushed).
    @discardableResult
    public func abandon(_ history: inout EditHistory<State>, label: String) -> Bool {
        history.endTransaction()
        guard hasChanges(history) else { return false }
        history.commit(openState, label: label)
        return true
    }
}
