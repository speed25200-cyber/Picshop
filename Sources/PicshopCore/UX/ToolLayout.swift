import Foundation

// UX 2.0 (ux-spec §3.5.12, §4.3, §6.2): where every tool of an editor lives. One table per editor, read by the
// labelled tool bar, the tool strips, the document menu, the tap-path catalog and ToolLayoutTests. U1 owns the
// types (this file); each editor lane owns its table (`ToolLayout+Photo/Video/PDF.swift`).
//
// Labels are glossary term ids (UXGlossary), never literal text, so one word keeps one meaning everywhere.

/// The three editors that share one frame (EditorShell).
public enum EditorKind: String, CaseIterable, Codable, Sendable {
    case photo, video, pdf
}

/// What is selected in an editor. `.none` shows the category bar; anything else shows that selection's context bar.
public enum SelectionKind: String, CaseIterable, Codable, Sendable {
    case none
    // Photo.
    /// A non-base layer (photo, fill, adjustment, group).
    case layer
    case text
    case shape
    /// The active selection (marching ants).
    case area
    /// A saved zone (a local adjustment).
    case zone
    // Video.
    case clip, title, sound, caption, overlay
    // PDF.
    case mark
}

/// An editor's tool homes: the level-0 categories, their strips, the canvas pills (photo « Calques »), the context
/// bars per selection and the document menu, plus where every legacy tool, panel control and later-wave tool lives.
public struct ToolLayout: Sendable, Equatable {
    /// Whether an entry works in this build.
    public enum Status: Sendable, Hashable {
        /// Shipped: shown in bars and strips.
        case live
        /// Planned for a later UX 2.0 phase (§6.3); hidden until then, and reachable meanwhile through its legacy host.
        case planned(phase: Int)
        /// Waits for its wave (W4 photo retouch, W5 pro video and PDF); hidden until the wave lands.
        case pending(wave: Int)

        public var isLive: Bool {
            if case .live = self { return true }
            return false
        }
    }

    /// A panel's height when its tool opens (§3.5.2).
    public enum Height: String, CaseIterable, Codable, Sendable {
        /// Rows A and B and the primary control (188 points), or less when the content is smaller.
        case compact
        /// Every control, up to 40 % of the screen.
        case medium
        /// To the top bar less 24 points: list tools only (Calques, zones, Actions).
        case full
    }

    /// What a strip item does when tapped.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// Opens its panel (Lumière, Recadrer › Format).
        case panel
        /// Runs at once (Magie › Améliorer, Calques › ＋ Photo).
        case action
        /// Switches the open panel's mode (Sélection › Ciel, Filtres › Noir et blanc).
        case mode
    }

    /// One item of a category's strip (« Lumière »).
    public struct Tool: Sendable, Hashable, Identifiable {
        /// "adjust.light": the category id, a dot, the tool. Probe ids are "strip.<id>".
        public var id: String
        /// The UXGlossary term of its label.
        public var term: String
        /// SF Symbol.
        public var glyph: String
        public var kind: Kind
        public var status: Status
        public var defaultHeight: Height
        /// The legacy panel that hosts it until its own panel lands (a PhotoEditorSession.Tool raw value), nil for
        /// an action the editor runs itself.
        public var host: String?
        /// The PanelInventory control that opens `host` in the right mode ("select.mode.wand", "masks.new.linear").
        public var hostControl: String?

        public init(_ id: String, term: String, glyph: String, kind: Kind = .panel, status: Status = .live, height: Height = .compact,
                    host: String? = nil, hostControl: String? = nil) {
            self.id = id
            self.term = term
            self.glyph = glyph
            self.kind = kind
            self.status = status
            self.defaultHeight = height
            self.host = host
            self.hostControl = hostControl
        }
    }

    /// A level-0 category (« Ajuster »), or a canvas pill (« Calques »).
    public struct Category: Sendable, Hashable, Identifiable {
        /// "adjust". Probe ids are "bar.<id>" (or "pill.<id>").
        public var id: String
        public var term: String
        public var glyph: String
        public var tools: [Tool]
        /// Opens with nothing active (Magie, Sélection, Calques): its strip holds actions or modes and nothing runs on
        /// open (§3.5.1). Other categories open their last-used tool (first time: the first one).
        public var opensEmpty: Bool

        public init(_ id: String, term: String, glyph: String, opensEmpty: Bool = false, tools: [Tool]) {
            self.id = id
            self.term = term
            self.glyph = glyph
            self.tools = tools
            self.opensEmpty = opensEmpty
        }

        /// The tools a strip shows in this build.
        public var liveTools: [Tool] { tools.filter(\.status.isLive) }
    }

    /// An item of a bar, a strip or a context bar, as the UI draws it.
    public struct BarItem: Sendable, Hashable, Identifiable {
        public var id: String
        public var term: String
        public var glyph: String
        /// Destructive context-bar items come last, in red (§4.8).
        public var isDestructive: Bool

        public init(_ id: String, term: String, glyph: String, isDestructive: Bool = false) {
            self.id = id
            self.term = term
            self.glyph = glyph
            self.isDestructive = isDestructive
        }
    }

    /// A section of the document menu (title ▾, §4.2).
    public struct MenuSection: Sendable, Hashable, Identifiable {
        public var id: String
        /// A titled section or a submenu (« Affichage ▸ »); nil draws a plain group.
        public var term: String?
        /// Drawn as a submenu rather than an inline section.
        public var isSubmenu: Bool
        public var items: [MenuItem]

        public init(_ id: String, term: String? = nil, isSubmenu: Bool = false, items: [MenuItem]) {
            self.id = id
            self.term = term
            self.isSubmenu = isSubmenu
            self.items = items
        }
    }

    /// An item of the document menu. Probe ids are "menu.<id>".
    public struct MenuItem: Sendable, Hashable, Identifiable {
        public var id: String
        public var term: String
        public var glyph: String
        public var status: Status
        /// A toggle (Grille, Histogramme): drawn with a check when on.
        public var isToggle: Bool
        public var isDestructive: Bool

        public init(_ id: String, term: String, glyph: String, status: Status = .live, isToggle: Bool = false, isDestructive: Bool = false) {
            self.id = id
            self.term = term
            self.glyph = glyph
            self.status = status
            self.isToggle = isToggle
            self.isDestructive = isDestructive
        }
    }

    /// Where something lives, for the reachability check (§3.5.12).
    public struct Home: Sendable, Hashable {
        public enum Place: Sendable, Hashable {
            /// A category's strip: « Ajuster › Lumière ».
            case strip(category: String, tool: String)
            /// A canvas pill's strip: « ▤ Calques › Calques ».
            case pill(String, tool: String)
            /// title ▾ › item.
            case documentMenu(String)
            /// A top-bar control: "back", "title", "undo", "redo", "export".
            case topBar(String)
            /// A gesture on the picture itself, with its visible twin elsewhere.
            case canvas
            /// A selection's context bar item.
            case contextBar(SelectionKind, item: String)
        }

        /// A legacy tool id (PhotoEditorSession.Tool raw value), a panel-inventory control id or uiTool, or a
        /// later-wave tool id.
        public var id: String
        public var place: Place
        /// A listed second way in (Magie › Supprimer l'arrière-plan for Détourer): not counted as a home.
        public var isShortcut: Bool
        public var status: Status

        public init(_ id: String, _ place: Place, shortcut: Bool = false, status: Status = .live) {
            self.id = id
            self.place = place
            self.isShortcut = shortcut
            self.status = status
        }
    }

    public var kind: EditorKind
    /// Level 0, in order. Photo: Magie · Ajuster · Filtres · Recadrer · Retoucher · Texte · Sélection.
    public var categories: [Category]
    /// Categories opened from a canvas pill rather than the bar (photo: « ▤ Calques n »).
    public var pills: [Category]
    /// The context bar of each selection kind.
    public var contextBars: [SelectionKind: [BarItem]]
    /// The document menu's sections, in order.
    public var documentMenu: [MenuSection]
    /// Every legacy tool, panel control group and later-wave tool, with its one home (plus listed shortcuts).
    public var homes: [Home]
    /// Every legacy panel id of the editor (PhotoEditorSession.Tool raw values for photo). Each must be the host
    /// of a live tool, so no tool that works today is lost in the new frame.
    public var legacyTools: [String]

    public init(kind: EditorKind, categories: [Category], pills: [Category] = [], contextBars: [SelectionKind: [BarItem]] = [:],
                documentMenu: [MenuSection] = [], homes: [Home] = [], legacyTools: [String] = []) {
        self.kind = kind
        self.categories = categories
        self.pills = pills
        self.contextBars = contextBars
        self.documentMenu = documentMenu
        self.homes = homes
        self.legacyTools = legacyTools
    }

    // MARK: - Lookup

    /// The table of an editor.
    public static func of(_ kind: EditorKind) -> ToolLayout {
        switch kind {
        case .photo: return .photo
        case .video: return .video
        case .pdf: return .pdf
        }
    }

    /// The level-0 bar (§4.3): the categories when nothing is selected, else the selection's context bar.
    public static func bar(for kind: EditorKind, selection: SelectionKind = .none) -> [BarItem] {
        of(kind).bar(selection: selection)
    }

    /// The level-0 bar of this editor.
    public func bar(selection: SelectionKind = .none) -> [BarItem] {
        guard selection == .none else { return contextBars[selection] ?? [] }
        return categories.map { BarItem($0.id, term: $0.term, glyph: $0.glyph) }
    }

    /// The live tools of a category's (or a pill's) strip, as bar items.
    public func strip(category id: String) -> [BarItem] {
        (self.category(id)?.liveTools ?? []).map { BarItem($0.id, term: $0.term, glyph: $0.glyph) }
    }

    /// A category or a pill by id.
    public func category(_ id: String) -> Category? {
        categories.first { $0.id == id } ?? pills.first { $0.id == id }
    }

    /// The category or pill whose strip holds this tool.
    public func category(containingTool toolID: String) -> Category? {
        (categories + pills).first { category in category.tools.contains { $0.id == toolID } }
    }

    /// A strip tool by id ("adjust.light").
    public func tool(_ id: String) -> Tool? {
        for category in categories + pills {
            if let tool = category.tools.first(where: { $0.id == id }) { return tool }
        }
        return nil
    }

    /// Every strip tool, categories then pills, in order.
    public var allTools: [Tool] { (categories + pills).flatMap(\.tools) }

    /// The live strip tools a legacy panel hosts ("adjust" hosts Lumière, Effets and Détail until they split).
    public func tools(hostedBy legacyTool: String) -> [Tool] {
        allTools.filter { $0.host == legacyTool && $0.status.isLive }
    }

    /// The strip tool that opens when a legacy panel is asked for by id (a voice, a palette row, a receipt's
    /// « Ajuster »): its primary home's tool, else the first live tool it hosts.
    public func tool(forLegacy legacyTool: String) -> Tool? {
        if let home = primaryHome(of: legacyTool) {
            switch home.place {
            case .strip(_, let toolID), .pill(_, let toolID):
                if let tool = tool(toolID) { return tool }
            case .documentMenu, .topBar, .canvas, .contextBar:
                break
            }
        }
        return tools(hostedBy: legacyTool).first
    }

    /// Every home listed for an id, shortcuts included.
    public func homes(of id: String) -> [Home] {
        homes.filter { $0.id == id }
    }

    /// The one home of an id (shortcuts excluded); nil when it has none.
    public func primaryHome(of id: String) -> Home? {
        homes.first { $0.id == id && !$0.isShortcut }
    }

    /// The home of a panel-inventory control: its own entry when the table lists the id, else its tool's.
    public func home(ofControl id: String, uiTool: String) -> Home? {
        primaryHome(of: id) ?? primaryHome(of: uiTool)
    }

    /// A document-menu item by id, submenus included.
    public func menuItem(_ id: String) -> MenuItem? {
        for section in documentMenu {
            if let item = section.items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }
}
