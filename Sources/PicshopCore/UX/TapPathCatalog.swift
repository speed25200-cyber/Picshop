import Foundation

/// One of the top tasks (ux-spec §1.4) as the exact steps the « after » path takes. XCUITest `UXTaskTests` replays
/// each live path through `step()`, counting taps (AC-01); TapPathCatalogTests checks on Linux that every step
/// names an item that is visible on screen (no hidden gesture on a counted path) and that the count meets the target.
public struct TapPath: Sendable, Hashable, Identifiable {
    public enum Step: Sendable, Hashable {
        /// A tap on a visible item, by probe id ("bar.adjust", "strip.crop.format", "panel.ok"). Counted.
        case tap(String)
        /// A tap that is listed but not counted (§1.4: OK where the edit already exists without it).
        case uncounted(String)
        /// Typing into the focused field. Not counted.
        case type(String)
        /// A drag on a visible item (a dial, the crop frame). Not counted.
        case drag(String)

        /// The probe id the step acts on (nil for typing).
        public var itemID: String? {
            switch self {
            case .tap(let id), .uncounted(let id), .drag(let id): return id
            case .type: return nil
            }
        }

        public var isCounted: Bool {
            if case .tap = self { return true }
            return false
        }
    }

    /// "H1", "P3", "S-undo".
    public var id: String
    /// nil: starts on Home.
    public var editor: EditorKind?
    /// What the user wants, in plain English (the test's name).
    public var task: String
    public var steps: [Step]
    /// The « after » count of §1.4.
    public var target: Int
    /// Live paths are replayed; planned and pending ones are listed for the record.
    public var status: ToolLayout.Status

    public init(_ id: String, editor: EditorKind?, task: String, target: Int, status: ToolLayout.Status = .live, steps: [Step]) {
        self.id = id
        self.editor = editor
        self.task = task
        self.steps = steps
        self.target = target
        self.status = status
    }

    /// Counted taps.
    public var taps: Int { steps.filter(\.isCounted).count }
}

/// The catalog of task paths (§1.4) for Home and the photo editor (increment 1). U3 and U4 add video and PDF.
public enum TapPathCatalog {
    public static let paths: [TapPath] = home + photo + secondary

    /// The path with this id.
    public static func path(_ id: String) -> TapPath? { paths.first { $0.id == id } }

    /// Visible items outside the editor's bars, strips, pills and document menu (those are read from ToolLayout):
    /// the probe ids the shared components and the lanes publish (`.uxProbe(id:role:)`).
    public static let knownItems: Set<String> = [
        // Top bar (EditorTopBar).
        "topBar.back", "topBar.title", "topBar.undo", "topBar.redo", "topBar.export",
        // Panel header and row B (InspectorPanel v2).
        "panel.cancel", "panel.ok", "panel.help", "panel.reset", "panel.target",
        // Canvas zones.
        "canvas.compare", "canvas.object", "canvas.text", "canvas.dial",
        // Feedback slot.
        "feedback.undo", "feedback.redo", "feedback.cancel",
        // Panels' own controls (U2).
        "chip.crop.square", "chip.crop.auto", "filters.look", "adjust.dial", "text.format.ok",
        // Context bars (ToolLayout.contextBars ids are accepted too).
        "context.remove.erase",
        // Export sheet (ExportSheetFrame + photo content).
        "sheet.export.primary",
        // Home (U5).
        "home.create.photo", "home.create.video", "home.create.scan", "home.search", "home.search.result", "home.card",
        "card.more", "card.menu.share", "card.menu.rename", "card.menu.delete", "toast.recover", "share.target",
        // System pickers.
        "picker.photo",
    ]

    // MARK: Home (H1–H6)

    static let home: [TapPath] = [
        TapPath("H1", editor: nil, task: "Edit a photo from the library", target: 2,
                steps: [.tap("home.create.photo"), .tap("picker.photo")]),
        TapPath("H2", editor: nil, task: "Resume the last project", target: 1, steps: [.tap("home.card")]),
        TapPath("H3", editor: nil, task: "Find and open a project by name", target: 2,
                steps: [.tap("home.search"), .type("plage"), .tap("home.search.result")]),
        TapPath("H4", editor: nil, task: "Share a project from Home", target: 3,
                steps: [.tap("card.more"), .tap("card.menu.share"), .tap("share.target")]),
        TapPath("H5", editor: nil, task: "Rename a project", target: 2,
                steps: [.tap("card.more"), .tap("card.menu.rename"), .type("Plage Biarritz")]),
        TapPath("H6", editor: nil, task: "Delete a project, then get it back", target: 3,
                steps: [.tap("card.more"), .tap("card.menu.delete"), .tap("toast.recover")]),
    ]

    // MARK: Photo (P1–P12)

    static let photo: [TapPath] = [
        TapPath("P1", editor: .photo, task: "Auto-enhance a photo", target: 2, steps: [.tap("bar.magic"), .tap("strip.magic.enhance")]),
        TapPath("P2", editor: .photo, task: "Brighten the photo", target: 1,
                steps: [.tap("bar.adjust"), .drag("adjust.dial"), .uncounted("panel.ok")]),
        TapPath("P3", editor: .photo, task: "Crop to a square", target: 3,
                steps: [.tap("bar.crop"), .tap("chip.crop.square"), .tap("panel.ok")]),
        TapPath("P4", editor: .photo, task: "Apply a filter", target: 2,
                steps: [.tap("bar.filters"), .tap("filters.look"), .uncounted("panel.ok")]),
        TapPath("P5", editor: .photo, task: "Remove one person", target: 3,
                steps: [.tap("bar.retouch"), .tap("canvas.object"), .tap("context.remove.erase")]),
        TapPath("P6", editor: .photo, task: "Remove the background", target: 2,
                steps: [.tap("bar.magic"), .tap("strip.magic.removeBackground")]),
        TapPath("P7", editor: .photo, task: "Brighten only the sky", target: 3, status: .planned(phase: 2),
                steps: [.tap("bar.select"), .tap("strip.select.sky"), .tap("area.adjust"), .drag("adjust.dial")]),
        TapPath("P8", editor: .photo, task: "Add a caption to the photo", target: 2,
                steps: [.tap("bar.text"), .type("Été 2026"), .tap("text.format.ok")]),
        TapPath("P9", editor: .photo, task: "Fix a typo in a text", target: 3,
                steps: [.tap("canvas.text"), .tap("text.edit"), .type("Été 2026"), .tap("text.format.ok")]),
        TapPath("P10", editor: .photo, task: "Straighten the horizon", target: 3,
                steps: [.tap("bar.crop"), .tap("chip.crop.auto"), .tap("panel.ok")]),
        TapPath("P11", editor: .photo, task: "Compare before and after", target: 1, steps: [.tap("canvas.compare")]),
        TapPath("P12", editor: .photo, task: "Save to Photos", target: 2, steps: [.tap("topBar.export"), .tap("sheet.export.primary")]),
    ]

    // MARK: Secondary paths (§1.4, extended set)

    static let secondary: [TapPath] = [
        TapPath("S-redo", editor: .photo, task: "Redo more than 8 s after an undo", target: 1, steps: [.tap("topBar.redo")]),
        TapPath("S-help", editor: .photo, task: "Help for the open tool", target: 1, steps: [.tap("panel.help")]),
        TapPath("S-undoReceipt", editor: .photo, task: "Undo a mistake and see what was undone", target: 1, steps: [.tap("topBar.undo")]),
        TapPath("S-cancelJob", editor: .photo, task: "Cancel a long AI job", target: 1, steps: [.tap("feedback.cancel")]),
        TapPath("S-history", editor: .photo, task: "Show the history", target: 2, steps: [.tap("topBar.title"), .tap("menu.history")]),
        TapPath("S-allTools", editor: .photo, task: "Find any tool by name", target: 2,
                steps: [.tap("topBar.title"), .tap("menu.allTools"), .type("courbes")]),
        TapPath("S-toPhotos", editor: .photo, task: "Get a retouched photo into Photos", target: 2,
                steps: [.tap("topBar.export"), .tap("sheet.export.primary")]),
    ]
}
