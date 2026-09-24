#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopPDF

/// The PDF editor's Outils: Pages; Annoter (Surligner, Dessiner); Ajouter
/// (Texte, Signature, Image). Footer: 'Que puis-je dire ?' (and Historique,
/// which StudioChrome adds).
@MainActor
enum PDFToolCatalog {
    typealias Tool = PDFEditorSession.Tool

    /// Category ids, symbols and the panels each one holds, in order.
    static let layout: [(id: String, symbol: String, panels: [Tool])] = [
        ("pages", "doc.on.doc", [.pages]),
        ("markup", "highlighter", [.highlight, .draw]),
        ("add", "plus.square.on.square", [.text, .signature, .image]),
    ]

    static func make(session: PDFEditorSession) -> ToolCatalog {
        let modified = modifiedTools(in: session.document)
        var categories: [ToolCategory] = []
        for entry in layout {
            let items: [ToolItem] = entry.panels.map { tool -> ToolItem in
                // A tool that opens with a sheet of its own runs once Outils has gone:
                // a sheet asked for while another is still leaving may never show.
                if presentsSheet(tool) {
                    return .action(id: tool.rawValue, title: title(for: tool), symbol: tool.symbol, isMagic: false,
                                   run: { session.activeTool = tool })
                }
                return .panel(id: tool.rawValue, title: title(for: tool), symbol: tool.symbol, isModified: modified.contains(tool),
                              open: { session.activeTool = tool })
            }
            categories.append(ToolCategory(id: entry.id, title: categoryTitle(entry.id), symbol: entry.symbol, items: items))
        }
        let footer: [ToolFooterItem] = [
            .button(id: "help", title: L("What can I say?"), systemImage: "questionmark.bubble", action: { session.showsHelp = true }),
        ]
        return ToolCatalog(editorKind: "pdf", categories: categories, footer: footer)
    }

    /// Which tools' marks are on the pages: the sheet's yellow dots.
    static func modifiedTools(in document: PDFDocumentModel) -> Set<Tool> {
        var tools: Set<Tool> = []
        for (_, markup) in document.allMarkups {
            switch markup.kind {
            case .highlight, .underline: tools.insert(.highlight)
            case .ink: tools.insert(.draw)
            case .text, .replacement: tools.insert(.text)
            case .signature: tools.insert(.signature)
            case .image: tools.insert(.image)
            default: break
            }
        }
        return tools
    }

    /// Whether opening the tool presents a sheet at once: the photo picker, or
    /// the signature pad while no signature is saved (PDFEditorView presents them).
    static func presentsSheet(_ tool: Tool) -> Bool {
        switch tool {
        case .image: return true
        case .signature: return SignatureStore.currentAsset() == nil
        default: return false
        }
    }

    static func category(of tool: Tool) -> String {
        layout.first { $0.panels.contains(tool) }?.id ?? "pages"
    }

    /// The other tools of the tool's category (the panel's segments).
    static func siblings(of tool: Tool) -> [Tool] {
        layout.first { $0.panels.contains(tool) }?.panels ?? [tool]
    }

    static func categoryTitle(of tool: Tool) -> String {
        categoryTitle(category(of: tool))
    }

    static func categoryTitle(_ id: String) -> String {
        switch id {
        case "pages": return L("Pages")
        case "markup": return L("Mark up")
        default: return L("Add")
        }
    }

    static func title(for tool: Tool) -> String {
        switch tool {
        case .signature: return L("Signature")
        default: return tool.title
        }
    }
}
#endif
