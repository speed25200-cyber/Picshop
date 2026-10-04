#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// A tool panel's session (ux-spec §4.5 « Sessions », §3.5.2 row A), for InspectorPanel v2. The editor session
/// conforms (or a PanelSessionAdapter stands in), usually with a PicshopCore `PanelSessionLedger` over its history:
/// - edits are saved as they happen; « OK » only closes (`commitPanel`);
/// - ↶ inside the panel stops at the opening step (`panelCanUndo`; the top bar dims ↶ there through
///   `EditorBarState.undoStopsAtPanel`);
/// - « Annuler » asks « Abandonner les modifications de … ? » whenever `panelHasChanges`, then `abandonPanel`
///   pushes **one** history step back to the open-time document and closes the panel; the session posts the
///   receipt « Modifications de … abandonnées · (↶) ». History is never trimmed;
/// - ‹ (Projets) and « Exporter » act as OK (`EditorShellActions.commitOpenWork`).
@MainActor
protocol PanelSession: AnyObject {
    /// The open tool's name (« Lumière »), as the header shows it.
    var panelTitle: String { get }
    /// Something changed since the panel opened.
    var panelHasChanges: Bool { get }
    /// ↶ may act inside the panel (false at the opening step).
    var panelCanUndo: Bool { get }
    /// « OK »: keeps the changes and closes the panel (back to the category bar).
    func commitPanel()
    /// « Abandonner les modifications »: one restoring step, the receipt, then the panel closes. With no change, it
    /// only closes.
    func abandonPanel()
}

/// A PanelSession from closures: hosts a legacy panel (or any panel whose owner is not a session) in InspectorPanel
/// v2 without a conformance.
@MainActor
final class PanelSessionAdapter: PanelSession {
    let panelTitle: String
    private let hasChanges: () -> Bool
    private let canUndo: () -> Bool
    private let commit: () -> Void
    private let abandon: () -> Void

    init(title: String, hasChanges: @escaping () -> Bool = { false }, canUndo: @escaping () -> Bool = { true },
         commit: @escaping () -> Void, abandon: @escaping () -> Void) {
        panelTitle = title
        self.hasChanges = hasChanges
        self.canUndo = canUndo
        self.commit = commit
        self.abandon = abandon
    }

    var panelHasChanges: Bool { hasChanges() }
    var panelCanUndo: Bool { canUndo() }
    func commitPanel() { commit() }
    func abandonPanel() { abandon() }
}

extension PanelSession {
    /// The receipt's words after « Abandonner les modifications » (« Modifications de Lumière abandonnées »), and
    /// the history step's label.
    var abandonedLabel: String { String(format: L("Changes to %@ discarded"), panelTitle) }
}
#endif
