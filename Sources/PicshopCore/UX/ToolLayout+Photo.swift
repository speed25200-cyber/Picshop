import Foundation

// The photo editor's tool homes (ux-spec §3.5.1, §3.5.12). Owned by U2 from phase 1; U1 wrote the phase-0 table.
//
// Increment 1 (UX-A phase 1) ships the frame and Home, Ajuster, Filtres, Recadrer, Retirer and Texte redesigned;
// every other tool that works today stays reachable through its legacy panel (`host`, a PhotoEditorSession.Tool raw
// value), opened inside InspectorPanel v2. Spec items that need a later phase are `.planned(phase:)`, W4 ones
// `.pending(wave: 4)`: hidden from the strips until they land, but already given their home, so ToolLayoutTests
// checks them from now on.

extension ToolLayout {
    /// The photo editor's table.
    public static let photo = ToolLayout(
        kind: .photo,
        categories: [photoMagic, photoAdjust, photoFilters, photoCrop, photoRetouch, photoText, photoSelection],
        pills: [photoLayers],
        contextBars: photoContextBars,
        documentMenu: photoDocumentMenu,
        homes: photoHomes,
        legacyTools: photoLegacyTools
    )

    /// Every PhotoEditorSession.Tool raw value, in its declaration order. The UI asserts in DEBUG that this matches
    /// `PhotoEditorSession.Tool.allCases`, so a new legacy panel cannot be forgotten here.
    public static let photoLegacyTools = [
        "magic", "focus", "adjust", "looks", "color", "erase", "precise", "cutout", "crop", "text", "shapes", "layers",
        "curves", "levels", "masks", "select",
    ]

    /// The precise tool's modes (PhotoEditorSession.PreciseMode raw values, as "precise.<mode>"), which move to
    /// three different homes.
    public static let photoPreciseModes = ["precise.wand", "precise.lasso", "precise.generate", "precise.pixelBrush", "precise.clone"]

    /// The W4 tools (their PhotoPanelInventory+W4 uiTool ids), pending until W4 resumes.
    public static let photoW4Tools = ["heal", "clone", "dodgeBurn", "skin", "liquify", "geometry", "detail", "colorPack", "actions", "hdr", "imageSize"]

    // MARK: - Categories (§3.5.1: icon above word, all seven on screen on iPhone SE)

    static let photoMagic = Category("magic", term: "magic", glyph: "sparkles", opensEmpty: true, tools: [
        Tool("magic.enhance", term: "enhance", glyph: "wand.and.stars", kind: .action),
        Tool("magic.removePeople", term: "removePeople", glyph: "person.2.slash", kind: .action),
        Tool("magic.removeBackground", term: "removeBackground", glyph: "person.crop.rectangle", kind: .action),
        Tool("magic.backgroundBlur", term: "backgroundBlur", glyph: "camera.aperture", kind: .action, host: "focus"),
        Tool("magic.autoPortrait", term: "autoPortrait", glyph: "face.smiling", kind: .action),
        Tool("magic.sunsetSky", term: "sunsetSky", glyph: "sun.horizon", kind: .action),
        Tool("magic.relight", term: "relight", glyph: "lightbulb.max", kind: .action),
        Tool("magic.matchColors", term: "matchColors", glyph: "eyedropper.halffull", kind: .action),
        Tool("magic.expand", term: "expand", glyph: "arrow.up.left.and.arrow.down.right", kind: .action),
        Tool("magic.upscale2x", term: "upscale2x", glyph: "plus.magnifyingglass", kind: .action),
        Tool("magic.textBehind", term: "textBehind", glyph: "person.and.background.dotted", kind: .action),
        // Recettes, and until Sélection › Objet lands the legacy Objets panel (tap an object: erase, move, blur).
        Tool("magic.recipes", term: "recipes", glyph: "list.bullet.rectangle", host: "magic"),
    ])

    static let photoAdjust = Category("adjust", term: "adjust", glyph: "slider.horizontal.3", tools: [
        Tool("adjust.light", term: "light", glyph: "sun.max", host: "adjust"),
        Tool("adjust.color", term: "color", glyph: "drop.halffull", host: "color"),
        Tool("adjust.effects", term: "effects", glyph: "sparkle", host: "adjust"),
        // Netteté and Réduction du bruit leave the carousels for Détail; W4 adds Débruitage IA, Rayon and Masquage.
        Tool("adjust.detail", term: "detail", glyph: "triangle", height: .medium, host: "adjust"),
        Tool("adjust.curves", term: "curves", glyph: "chart.xyaxis.line", host: "curves"),
        Tool("adjust.levels", term: "levels", glyph: "chart.bar.xaxis", host: "levels"),
        Tool("adjust.blur", term: "blur", glyph: "camera.aperture", host: "focus"),
    ])

    static let photoFilters = Category("filters", term: "filters", glyph: "camera.filters", tools: [
        Tool("filters.suggested", term: "suggested", glyph: "sparkles", kind: .mode, host: "looks"),
        Tool("filters.all", term: "allFilters", glyph: "square.grid.2x2", kind: .mode, host: "looks"),
        Tool("filters.portrait", term: "portrait", glyph: "person.crop.square", kind: .mode, status: .planned(phase: 1), host: "looks"),
        Tool("filters.landscape", term: "landscape", glyph: "mountain.2", kind: .mode, status: .planned(phase: 1), host: "looks"),
        Tool("filters.blackAndWhite", term: "blackAndWhite", glyph: "circle.lefthalf.filled", kind: .mode, host: "looks"),
        Tool("filters.myPresets", term: "myPresets", glyph: "bookmark", kind: .mode, status: .planned(phase: 2), host: "looks"),
        // LUTs move here from Couleur (the only home of LUTs, photo and video).
        Tool("filters.lut", term: "lut", glyph: "cube", kind: .mode, host: "color", hostControl: "color.lut.import"),
    ])

    static let photoCrop = Category("crop", term: "crop", glyph: "crop.rotate", tools: [
        Tool("crop.format", term: "format", glyph: "aspectratio", host: "crop"),
        Tool("crop.straighten", term: "straighten", glyph: "level", host: "crop", hostControl: "crop.straighten"),
        Tool("crop.perspective", term: "perspective", glyph: "perspective", host: "crop", hostControl: "crop.perspective.vertical"),
        Tool("crop.document", term: "document", glyph: "doc.viewfinder", status: .pending(wave: 4)),
    ])

    static let photoRetouch = Category("retouch", term: "retouch", glyph: "bandage", tools: [
        Tool("retouch.remove", term: "remove", glyph: "eraser.line.dashed", host: "erase"),
        // Main's portrait retouch is Magie › Portrait auto until W4's Portrait panel (skin, eyes, red eye) lands.
        Tool("retouch.portrait", term: "portrait", glyph: "face.smiling", status: .pending(wave: 4)),
        // Main's pixel brush (and, until Retirer › Cloner, its clone and wand modes) lives in the precise panel.
        Tool("retouch.brushes", term: "brushes", glyph: "paintbrush.pointed", host: "precise", hostControl: "precise.pixelBrush"),
        Tool("retouch.reshape", term: "reshape", glyph: "hand.draw", status: .pending(wave: 4)),
        Tool("retouch.cutout", term: "cutout", glyph: "scissors", host: "cutout"),
    ])

    static let photoText = Category("text", term: "text", glyph: "textformat", tools: [
        Tool("text.text", term: "text", glyph: "textformat", host: "text"),
        Tool("text.shapes", term: "shapes", glyph: "square.on.circle", host: "shapes"),
    ])

    static let photoSelection = Category("select", term: "selection", glyph: "lasso", opensEmpty: true, tools: [
        Tool("select.subject", term: "subject", glyph: "person.crop.circle", kind: .mode, host: "select", hostControl: "select.mode.subject"),
        Tool("select.sky", term: "sky", glyph: "cloud.sun", kind: .mode, host: "select", hostControl: "select.mode.sky"),
        Tool("select.background", term: "background", glyph: "photo.on.rectangle", kind: .mode, host: "masks", hostControl: "masks.new.background"),
        Tool("select.person", term: "person", glyph: "person", kind: .mode, host: "masks", hostControl: "masks.new.person"),
        Tool("select.object", term: "object", glyph: "cube", kind: .mode, host: "select", hostControl: "select.mode.object"),
        Tool("select.brush", term: "brush", glyph: "paintbrush.pointed", kind: .mode, host: "select", hostControl: "select.mode.quick"),
        Tool("select.linear", term: "linear", glyph: "rectangle.tophalf.inset.filled", kind: .mode, host: "masks", hostControl: "masks.new.linear"),
        Tool("select.radial", term: "radial", glyph: "circle.dashed", kind: .mode, host: "masks", hostControl: "masks.new.radial"),
        Tool("select.byColor", term: "byColor", glyph: "eyedropper.halffull", kind: .mode, host: "select", hostControl: "select.mode.colorRange"),
        Tool("select.byLight", term: "byLight", glyph: "sun.max", kind: .mode, host: "masks", hostControl: "masks.new.luminanceRange"),
        Tool("select.depth", term: "depth", glyph: "square.3.layers.3d.down.right", kind: .mode, host: "masks", hostControl: "masks.new.depthRange"),
        Tool("select.wand", term: "wand", glyph: "wand.and.rays", kind: .mode, host: "select", hostControl: "select.mode.wand"),
        Tool("select.lasso", term: "lasso", glyph: "lasso", kind: .mode, host: "select", hostControl: "select.mode.lasso"),
        Tool("select.all", term: "all", glyph: "rectangle.dashed", kind: .action, host: "select", hostControl: "select.all"),
        // The zones column (§3.5.9) is phase 2; until then the legacy Masques panel lists and edits the zones.
        Tool("select.zones", term: "adjustedAreas", glyph: "circle.rectangle.dashed", height: .full, host: "masks"),
    ])

    /// The « ▤ Calques n » pill (zone B2): Calques is not a category.
    static let photoLayers = Category("layers", term: "layers", glyph: "square.3.layers.3d", opensEmpty: true, tools: [
        Tool("layers.list", term: "layers", glyph: "square.3.layers.3d", height: .full, host: "layers"),
        Tool("layers.addPhoto", term: "photo", glyph: "plus", kind: .action, host: "layers", hostControl: "layers.add.photo"),
        Tool("layers.addFill", term: "fill", glyph: "plus", kind: .action, host: "layers", hostControl: "layers.add.fill.solid"),
        Tool("layers.addAdjustment", term: "adjustment", glyph: "plus", kind: .action, host: "layers", hostControl: "layers.add.adjustment.curves"),
        Tool("layers.addGroup", term: "group", glyph: "plus", kind: .action, host: "layers", hostControl: "layers.add.group"),
    ])

    // MARK: - Context bars (§3.5.2, §3.5.8–§3.5.10)

    static let photoContextBars: [SelectionKind: [BarItem]] = [
        .text: [
            BarItem("text.edit", term: "edit", glyph: "character.cursor.ibeam"),
            BarItem("text.font", term: "font", glyph: "textformat"),
            BarItem("text.style", term: "style", glyph: "textformat.alt"),
            BarItem("text.color", term: "color", glyph: "paintpalette"),
            BarItem("text.duplicate", term: "duplicate", glyph: "plus.square.on.square"),
            BarItem("text.delete", term: "delete", glyph: "trash", isDestructive: true),
        ],
        .shape: [
            BarItem("shape.fill", term: "fill", glyph: "paintbrush"),
            BarItem("shape.outline", term: "outline", glyph: "square"),
            BarItem("shape.thickness", term: "thickness", glyph: "lineweight"),
            BarItem("shape.opacity", term: "opacity", glyph: "circle.lefthalf.filled"),
            BarItem("shape.duplicate", term: "duplicate", glyph: "plus.square.on.square"),
            BarItem("shape.delete", term: "delete", glyph: "trash", isDestructive: true),
        ],
        .layer: [
            BarItem("layer.transform", term: "transform", glyph: "arrow.up.and.down.and.arrow.left.and.right"),
            BarItem("layer.opacity", term: "opacity", glyph: "circle.lefthalf.filled"),
            BarItem("layer.blend", term: "blend", glyph: "square.on.square.intersection.dashed"),
            BarItem("layer.mask", term: "mask", glyph: "circle.rectangle.dashed"),
            BarItem("layer.more", term: "more", glyph: "ellipsis"),
        ],
        .area: [
            BarItem("area.adjust", term: "adjust", glyph: "slider.horizontal.3"),
            BarItem("area.erase", term: "erase", glyph: "eraser"),
            BarItem("area.fill", term: "fillAction", glyph: "paintbrush"),
            BarItem("area.blur", term: "blurAction", glyph: "drop"),
            BarItem("area.more", term: "more", glyph: "ellipsis"),
        ],
        .zone: [
            BarItem("zone.adjust", term: "adjust", glyph: "slider.horizontal.3"),
            BarItem("zone.edit", term: "edit", glyph: "pencil"),
            BarItem("zone.invert", term: "invert", glyph: "circle.righthalf.filled"),
            BarItem("zone.delete", term: "delete", glyph: "trash", isDestructive: true),
        ],
    ]

    // MARK: - Document menu (title ▾, §4.2)

    static let photoDocumentMenu: [MenuSection] = [
        MenuSection("document", items: [
            MenuItem("rename", term: "rename", glyph: "pencil"),
            MenuItem("duplicate", term: "duplicate", glyph: "plus.square.on.square", status: .planned(phase: 2)),
            MenuItem("info", term: "info", glyph: "info.circle", status: .planned(phase: 2)),
        ]),
        MenuSection("history", items: [
            MenuItem("history", term: "historyMenu", glyph: "clock.arrow.circlepath"),
            MenuItem("revert", term: "revert", glyph: "arrow.counterclockwise", isDestructive: true),
        ]),
        MenuSection("view", term: "view", isSubmenu: true, items: [
            MenuItem("view.fit", term: "fit", glyph: "arrow.down.right.and.arrow.up.left"),
            MenuItem("view.100", term: "zoom100", glyph: "1.magnifyingglass"),
            MenuItem("view.200", term: "zoom200", glyph: "plus.magnifyingglass"),
            MenuItem("view.sideBySide", term: "sideBySide", glyph: "square.split.2x1", isToggle: true),
            MenuItem("view.histogram", term: "histogram", glyph: "chart.bar", isToggle: true),
            MenuItem("view.grid", term: "grid", glyph: "squareshape.split.3x3", status: .planned(phase: 2), isToggle: true),
            MenuItem("view.transparency", term: "transparency", glyph: "checkerboard.rectangle", isToggle: true),
        ]),
        MenuSection("photo", items: [
            MenuItem("imageSize", term: "imageSizeMenu", glyph: "arrow.up.left.and.down.right.magnifyingglass", status: .pending(wave: 4)),
            MenuItem("copyEdits", term: "copyEdits", glyph: "doc.on.doc", status: .planned(phase: 2)),
            MenuItem("pasteEdits", term: "pasteEdits", glyph: "doc.on.clipboard", status: .planned(phase: 2)),
            MenuItem("savePreset", term: "savePreset", glyph: "bookmark", status: .planned(phase: 2)),
            MenuItem("actions", term: "actionsMenu", glyph: "play.rectangle.on.rectangle", status: .pending(wave: 4)),
        ]),
        MenuSection("help", items: [
            MenuItem("allTools", term: "allTools", glyph: "square.grid.2x2"),
            MenuItem("editorHelp", term: "editorHelp", glyph: "questionmark.circle"),
            MenuItem("voiceSettings", term: "voiceSettings", glyph: "waveform", status: .planned(phase: 2)),
        ]),
    ]

    // MARK: - Homes (§3.5.12): one per legacy tool, precise mode, inventory tool and W4 tool

    static let photoHomes: [Home] = [
        // The legacy panels (PhotoEditorSession.Tool).
        Home("magic", .strip(category: "magic", tool: "magic.recipes")),
        Home("focus", .strip(category: "adjust", tool: "adjust.blur")),
        Home("focus", .strip(category: "magic", tool: "magic.backgroundBlur"), shortcut: true),
        Home("adjust", .strip(category: "adjust", tool: "adjust.light")),
        Home("looks", .strip(category: "filters", tool: "filters.suggested")),
        Home("color", .strip(category: "adjust", tool: "adjust.color")),
        Home("erase", .strip(category: "retouch", tool: "retouch.remove")),
        Home("precise", .strip(category: "retouch", tool: "retouch.brushes")),
        Home("cutout", .strip(category: "retouch", tool: "retouch.cutout")),
        Home("cutout", .strip(category: "magic", tool: "magic.removeBackground"), shortcut: true),
        Home("crop", .strip(category: "crop", tool: "crop.format")),
        Home("text", .strip(category: "text", tool: "text.text")),
        Home("shapes", .strip(category: "text", tool: "text.shapes")),
        Home("layers", .pill("layers", tool: "layers.list")),
        Home("curves", .strip(category: "adjust", tool: "adjust.curves")),
        Home("levels", .strip(category: "adjust", tool: "adjust.levels")),
        Home("masks", .strip(category: "select", tool: "select.zones")),
        Home("select", .strip(category: "select", tool: "select.subject")),
        // The precise modes, split between Sélection, Retoucher and the zone bar.
        Home("precise.wand", .strip(category: "select", tool: "select.wand")),
        Home("precise.lasso", .strip(category: "select", tool: "select.lasso")),
        Home("precise.generate", .contextBar(.area, item: "area.fill"), status: .planned(phase: 2)),
        Home("precise.pixelBrush", .strip(category: "retouch", tool: "retouch.brushes")),
        Home("precise.clone", .strip(category: "retouch", tool: "retouch.remove"), status: .planned(phase: 2)),
        // Inventory tools that are not panels.
        Home("export", .topBar("export")),
        Home("canvas", .canvas),
        // W4 (paused): built directly as InspectorPanel v2 content when it resumes (UX-B).
        Home("heal", .strip(category: "retouch", tool: "retouch.remove"), status: .pending(wave: 4)),
        Home("clone", .strip(category: "retouch", tool: "retouch.remove"), status: .pending(wave: 4)),
        Home("dodgeBurn", .strip(category: "retouch", tool: "retouch.brushes"), status: .pending(wave: 4)),
        Home("skin", .strip(category: "retouch", tool: "retouch.portrait"), status: .pending(wave: 4)),
        Home("liquify", .strip(category: "retouch", tool: "retouch.reshape"), status: .pending(wave: 4)),
        Home("geometry", .strip(category: "crop", tool: "crop.perspective"), status: .pending(wave: 4)),
        Home("detail", .strip(category: "adjust", tool: "adjust.detail"), status: .pending(wave: 4)),
        Home("colorPack", .strip(category: "adjust", tool: "adjust.color"), status: .pending(wave: 4)),
        Home("actions", .documentMenu("actions"), status: .pending(wave: 4)),
        Home("hdr", .strip(category: "adjust", tool: "adjust.light"), status: .pending(wave: 4)),
        Home("imageSize", .strip(category: "crop", tool: "crop.format"), status: .pending(wave: 4)),
        Home("imageSize", .documentMenu("imageSize"), shortcut: true, status: .pending(wave: 4)),
    ]
}
