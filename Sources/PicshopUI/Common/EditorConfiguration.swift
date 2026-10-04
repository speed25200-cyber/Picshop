#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// UX 2.0 (ux-spec §3.4, §4.1, §4.2): what an editor tells the shared frame. EditorConfiguration replaces W1's
// StudioContext; EditorBarState and EditorShellActions replace StudioBar and StudioActions. U1 owns this file.

/// The words under the title (§3.4): « Enregistré dans PicShop » in the first three editor sessions, then
/// « Enregistré »; « Enregistrement… » while a save runs; « Modifié » until it starts.
enum EditorSaveState: Equatable, Sendable {
    case savedInPicShop
    case saved
    case saving
    case edited

    var text: String {
        switch self {
        case .savedInPicShop: return L("Saved in PicShop")
        case .saved: return L("Saved")
        case .saving: return L("Saving…")
        case .edited: return L("Edited")
        }
    }
}

/// What the top bar shows: coarse values from the session's stored mirrors, so a pinch or a dial drag never
/// re-evaluates the frame.
struct EditorBarState: Equatable {
    var canUndo: Bool
    var canRedo: Bool
    /// A job runs: ↶ and ↷ are disabled (the feedback slot's « Annuler » cancels the job, §4.1).
    var isBusy: Bool = false
    var saveState: EditorSaveState = .saved
    /// ↶ stops at an open panel's opening step: dimmed, with « Touchez OK pour annuler les étapes précédentes ».
    var undoStopsAtPanel: Bool = false
    /// Revenir à l'original would change something ↶ cannot reach (edits from an earlier session).
    var canRevert: Bool = false
    /// False on a locked PDF.
    var isExportEnabled: Bool = true
    /// Past steps' labels, oldest first: Historique… lists them; the last is what ↶ undoes (VoiceOver value).
    var undoLabels: [String] = []
}

/// What the frame does. ‹ (Projets) and « Exporter » act as OK on open work first (§2.2 rule 2): the shell calls
/// `commitOpenWork` before `close` and before `export`.
struct EditorShellActions {
    /// Back to Projets (the project is already saved).
    var close: () -> Void
    var undo: () -> Void
    var redo: () -> Void
    /// Opens the export sheet.
    var export: () -> Void
    /// OK on whatever is open (a panel keeps its changes, a crop session commits as one step).
    var commitOpenWork: () -> Void = {}
    /// Historique: go back this many steps.
    var undoSteps: (Int) -> Void = { _ in }
    /// Revenir à l'original (after its confirmation); nil hides the item.
    var revert: (() -> Void)? = nil
    /// Renommer (title ▾ › Renommer); nil hides the item.
    var rename: ((String) -> Void)? = nil
}

/// The document menu's editor-specific behaviour (§4.2). The shell handles Renommer, Historique…, Revenir à
/// l'original and Tous les outils… itself; every other item id ("view.fit", "view.histogram", "editorHelp" …)
/// comes here.
struct DocumentMenuHandler {
    var perform: (String) -> Void = { _ in }
    var isEnabled: (String) -> Bool = { _ in true }
    /// A toggle item's state (Grille, Histogramme, Transparence, Avant/après côte à côte).
    var isOn: (String) -> Bool = { _ in false }
}

/// An editor's description to the frame.
struct EditorConfiguration {
    var kind: EditorKind
    /// The project's title (title ▾).
    var title: String
    /// The editor's tool homes: bar, strips, document menu (ToolLayout.photo, .video, .pdf).
    var layout: ToolLayout
    /// « ◐ Avant » in zone B; nil hides it.
    var compare: BeforeAfterControl?
    var menu: DocumentMenuHandler
    /// The Outils catalog behind title ▾ › « Tous les outils… »: every tool, findable by name, so nothing that
    /// works today is lost while the new strips land.
    var catalog: (() -> ToolCatalog)?
    /// What is selected, in words (« Clip 3 », « Ciel »), for the Ask row (§6.2).
    var selectionSummary: String?

    init(kind: EditorKind, title: String, layout: ToolLayout? = nil, compare: BeforeAfterControl? = nil,
         menu: DocumentMenuHandler = DocumentMenuHandler(), catalog: (() -> ToolCatalog)? = nil, selectionSummary: String? = nil) {
        self.kind = kind
        self.title = title
        self.layout = layout ?? ToolLayout.of(kind)
        self.compare = compare
        self.menu = menu
        self.catalog = catalog
        self.selectionSummary = selectionSummary
    }
}

/// Whether the UX 2.0 frame and Home are on (the `ux2` flag), read once per screen: a screen never switches
/// frames while open.
enum UX2 {
    static var isEnabled: Bool { FeatureFlags.isOn(.ux2) }
}

private struct EditorPanelOpenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by EditorShell: a tool panel is open (zone B2's pills hide, « Exporter » turns secondary).
    var editorPanelOpen: Bool {
        get { self[EditorPanelOpenKey.self] }
        set { self[EditorPanelOpenKey.self] = newValue }
    }
}
#endif
