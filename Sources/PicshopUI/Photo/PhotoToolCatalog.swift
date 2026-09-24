#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// The photo editor's Outils: five categories, every tool of the old dock
/// among them, the yellow dots from the session's `modifiedTools`.
///
/// - Magie: the one-tap actions, in the order the picture suggests, with
///   Flou portrait (the focus panel) where the portrait blur ranks, and
///   Objets (tap an object to erase, move or blur it).
/// - Retoucher: Effacer, Précis, Détourage.
/// - Lumière et couleur: Réglages, Couleur, Filtres.
/// - Cadrer: Recadrer, which opens straight away.
/// - Ajouter: Texte, Formes, Calques.
/// Footer: the side-by-side before/after, 'Que puis-je dire ?' (and
/// Historique, which StudioChrome adds).
@MainActor
enum PhotoToolCatalog {
    typealias Tool = PhotoEditorSession.Tool

    /// Category ids, symbols and the panels each one holds, in order.
    static let layout: [(id: String, symbol: String, panels: [Tool])] = [
        ("magic", "sparkles", [.focus, .magic]),
        ("retouch", "wand.and.rays", [.erase, .precise, .cutout]),
        ("light", "dial.medium", [.adjust, .color, .looks]),
        ("crop", "crop.rotate", [.crop]),
        ("add", "plus.square.on.square", [.text, .shapes, .layers]),
    ]

    static func make(session: PhotoEditorSession) -> ToolCatalog {
        let modified = session.modifiedTools
        func panel(_ tool: Tool) -> ToolItem {
            .panel(id: tool.rawValue, title: title(for: tool), symbol: symbol(for: tool), isModified: modified.contains(tool),
                   open: { session.activeTool = tool })
        }
        var categories: [ToolCategory] = []
        for entry in layout {
            var items: [ToolItem]
            if entry.id == "magic" {
                items = magicItems(session: session, focus: panel(.focus))
                items.append(panel(.magic))
            } else {
                items = entry.panels.map(panel)
            }
            categories.append(ToolCategory(id: entry.id, title: categoryTitle(entry.id), symbol: entry.symbol, items: items))
        }
        var footer: [ToolFooterItem] = []
        if PhotoCanvasView.canSplitCompare(session) {
            footer.append(.toggle(id: "split", title: L("Before and after, side by side"),
                                  isOn: Binding(get: { session.compareSplit != nil },
                                                set: { session.compareSplit = $0 ? 0.5 : nil })))
        }
        footer.append(.button(id: "help", title: L("What can I say?"), systemImage: "questionmark.bubble",
                              action: { session.showsHelp = true }))
        return ToolCatalog(editorKind: "photo", categories: categories, footer: footer)
    }

    /// The Magie actions in the order MagicSuggestions ranks them for this
    /// picture; the portrait blur is the focus panel.
    private static func magicItems(session: PhotoEditorSession, focus: ToolItem) -> [ToolItem] {
        let fr = psPrefersFrench
        func say(_ french: String, _ english: String) -> () -> Void {
            { Task { await session.handleTranscript(fr ? french : english) } }
        }
        func action(_ id: String, _ title: String, _ symbol: String, _ run: @escaping () -> Void) -> ToolItem {
            .action(id: id, title: title, symbol: symbol, isMagic: true, run: run)
        }
        let items: [String: ToolItem] = [
            "enhance": action("enhance", L("Improve"), "wand.and.stars") { session.perform(EditIntent(action: .autoEnhance)) },
            "cleanup": action("cleanup", L("Clean up"), "person.2.slash") { session.perform(EditIntent(action: .cleanUp)) },
            "expand": action("expand", L("Expand"), "arrow.up.left.and.arrow.down.right") { session.expandCanvas() },
            "behind": action("behind", L("Text behind"), "person.and.background.dotted") { Task { await session.textBehindSubject() } },
            "retouch": action("retouch", L("Portrait retouch"), "face.smiling",
                              say("lisse la peau et éclaircis les yeux et blanchis les dents", "smooth the skin and brighten the eyes and whiten the teeth")),
            "portrait": focus,
            "sky": action("sky", L("Sky at sunset"), "sun.horizon", say("remplace le ciel par un coucher de soleil", "replace the sky with a sunset")),
            "match": action("match", L("Match the colours"), "eyedropper.halffull") { session.showsColorReferencePicker = true },
            "relight": action("relight", L("Relight"), "lightbulb.max") { session.perform(EditIntent(action: .relight)) },
            "cutout": action("cutout", L("Cut out"), "person.crop.rectangle") { session.perform(EditIntent(action: .removeBackground)) },
            "upscale": action("upscale", L("Upscale ×2"), "plus.magnifyingglass") { session.perform(EditIntent(action: .upscale, amount: .absolute(2))) },
            "mono": action("mono", L("Black & white"), "circle.lefthalf.filled", say("noir et blanc", "black and white")),
        ]
        let order = MagicSuggestions.ranked(for: session.sceneDescription)
        var ranked = order.compactMap { items[$0] }
        // Anything the ranking does not know goes last, in a stable order.
        for id in MagicSuggestions.all where !order.contains(id) {
            if let item = items[id] { ranked.append(item) }
        }
        return ranked
    }

    /// The category a panel belongs to.
    static func category(of tool: Tool) -> String {
        layout.first { $0.panels.contains(tool) }?.id ?? "magic"
    }

    /// The other panels of the tool's category (the panel's segments).
    static func siblings(of tool: Tool) -> [Tool] {
        layout.first { $0.panels.contains(tool) }?.panels ?? [tool]
    }

    static func categoryTitle(of tool: Tool) -> String {
        categoryTitle(category(of: tool))
    }

    static func categoryTitle(_ id: String) -> String {
        switch id {
        case "magic": return L("Magic")
        case "retouch": return L("Touch up")
        case "light": return L("Light & colour")
        case "crop": return L("Framing")
        default: return L("Add")
        }
    }

    /// A panel's name in the sheet and the panel header.
    static func title(for tool: Tool) -> String {
        switch tool {
        case .focus: return L("Portrait blur")
        case .magic: return L("Objects")
        default: return tool.title
        }
    }

    static func symbol(for tool: Tool) -> String {
        switch tool {
        case .magic: return "hand.tap"
        case .erase: return "eraser"
        default: return tool.symbol
        }
    }
}
#endif
