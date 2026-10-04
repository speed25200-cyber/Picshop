#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// UX 2.0 (ux-spec §4.3, §4.4): the editor's tool bar at rest, every category named under its glyph (Magie,
/// Ajuster, Filtres, Recadrer…). A category with one panel opens it at once; a category with several shows its
/// tools in the same bar, a leading ‹ going back to the categories. A panel opening puts the categories back;
/// a one-tap action (Magie) keeps its strip, so the next action is one tap away. « Rechercher » ends the bar and
/// opens the tool search (the Outils sheet), so every tool stays reachable by its name.
struct StudioCategoryBar: View {
    /// The categories and their yellow dots (the rail's catalog when it is cheaper to build).
    let categories: () -> ToolCatalog
    /// The full catalog (Magie's ranked actions), read when a category opens.
    let catalog: () -> ToolCatalog
    let onSearch: () -> Void

    @State private var openCategory: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let searchID = "search"

    var body: some View {
        Group {
            if let openCategory, let category = catalog().categories.first(where: { $0.id == openCategory }) {
                PSToolBar(items: category.items.map(Self.item), style: .strip, onDeselect: close) { id in
                    pick(id, in: category)
                }
                .id("strip." + openCategory)
            } else {
                PSToolBar(items: categoryItems(categories())) { id in
                    select(id)
                }
                .id("categories")
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? PSSpring.fade : PSSpring.quick, value: openCategory)
    }

    private func categoryItems(_ built: ToolCatalog) -> [PSToolBarItem] {
        let named = built.categories.map { category in
            PSToolBarItem(id: category.id, title: category.title, systemImage: category.symbol,
                          isModified: category.items.contains { $0.isModified })
        }
        return named + [PSToolBarItem(id: Self.searchID, title: L("Search"), systemImage: "magnifyingglass")]
    }

    private static func item(_ tool: ToolItem) -> PSToolBarItem {
        PSToolBarItem(id: tool.id, title: tool.title, systemImage: tool.symbol, isModified: tool.isModified)
    }

    private func select(_ id: String) {
        guard id != Self.searchID else {
            onSearch()
            return
        }
        guard let category = catalog().categories.first(where: { $0.id == id }) else { return }
        if category.items.count == 1, let only = category.items.first {
            run(only)
        } else {
            openCategory = id
        }
    }

    private func pick(_ id: String, in category: ToolCategory) {
        guard let tool = category.items.first(where: { $0.id == id }) else { return }
        run(tool)
    }

    private func run(_ tool: ToolItem) {
        switch tool {
        case .panel(_, _, _, _, let openPanel):
            openCategory = nil
            openPanel()
        case .action(_, _, _, _, let perform):
            perform()
        }
    }

    private func close() {
        openCategory = nil
    }
}
#endif
