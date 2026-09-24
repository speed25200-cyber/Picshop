#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One tile of the Outils sheet: a panel to open, or an action to run.
enum ToolItem: Identifiable {
    case panel(id: String, title: String, symbol: String, isModified: Bool, open: () -> Void)
    case action(id: String, title: String, symbol: String, isMagic: Bool, run: () -> Void)

    var id: String {
        switch self {
        case .panel(let id, _, _, _, _), .action(let id, _, _, _, _): return id
        }
    }
}

/// A segment of the Outils sheet (at most 5 per editor).
struct ToolCategory: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var items: [ToolItem]
}

/// A row under the grid: a toggle or a button.
enum ToolFooterItem: Identifiable {
    case toggle(id: String, title: String, isOn: Binding<Bool>)
    case button(id: String, title: String, systemImage: String, action: () -> Void)

    var id: String {
        switch self {
        case .toggle(let id, _, _), .button(let id, _, _, _): return id
        }
    }
}

/// Everything an editor offers behind Outils. Built on demand when the sheet opens.
struct ToolCatalog {
    /// photo | video | pdf: keys the remembered category.
    var editorKind: String
    var categories: [ToolCategory]
    var footer: [ToolFooterItem]
}

/// The Outils sheet: a category bar, a grid of tiles and footer rows. A panel
/// tile closes the sheet and opens its panel 0.15 s later, so the panel rises
/// as the sheet leaves; an action tile closes the sheet, then runs.
///
/// Phase 0: the bar, the grid and the footer. The zoom transition from the
/// Outils button and the tile polish follow.
struct ToolsSheet: View {
    let catalog: ToolCatalog
    let onDismiss: () -> Void
    @AppStorage private var lastCategory: String

    init(catalog: ToolCatalog, onDismiss: @escaping () -> Void) {
        self.catalog = catalog
        self.onDismiss = onDismiss
        _lastCategory = AppStorage(wrappedValue: "", "tools.lastCategory.\(catalog.editorKind)")
    }

    private var selected: ToolCategory? {
        catalog.categories.first { $0.id == lastCategory } ?? catalog.categories.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if catalog.categories.count > 1 {
                    categoryBar
                }
                if let selected {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: PSMetrics.toolTile), spacing: 12)], spacing: 12) {
                        ForEach(selected.items) { item in
                            tile(item)
                        }
                    }
                }
                if !catalog.footer.isEmpty {
                    footer
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
    }

    private var categoryBar: some View {
        HStack(spacing: 4) {
            ForEach(catalog.categories.prefix(5)) { category in
                let isSelected = category.id == selected?.id
                Button {
                    Haptics.tick()
                    lastCategory = category.id
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: category.symbol).font(.system(size: 20, weight: .medium))
                        Text(category.title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? PSTheme.onPrimary : PSTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isSelected ? PSTheme.primary : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    private func tile(_ item: ToolItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.toolTile, style: .continuous)
        let title: String
        let symbol: String
        let isMagic: Bool
        let isModified: Bool
        switch item {
        case .panel(_, let panelTitle, let panelSymbol, let modified, _):
            title = panelTitle; symbol = panelSymbol; isMagic = false; isModified = modified
        case .action(_, let actionTitle, let actionSymbol, let magic, _):
            title = actionTitle; symbol = actionSymbol; isMagic = magic; isModified = false
        }
        return Button {
            Haptics.tap()
            choose(item)
        } label: {
            VStack(spacing: 6) {
                Group {
                    if isMagic {
                        MagicGlyph(size: 22, symbol: symbol)
                    } else {
                        Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(PSTheme.textPrimary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(shape.fill(PSTheme.fill))
                .overlay(alignment: .topTrailing) {
                    Circle().fill(PSTheme.accent).frame(width: 5, height: 5)
                        .padding(8)
                        .opacity(isModified ? 1 : 0)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PSTheme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 84, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityLabel(title)
        .accessibilityValue(isModified ? L("Edited") : "")
    }

    private var footer: some View {
        VStack(spacing: 0) {
            ForEach(catalog.footer) { item in
                switch item {
                case .toggle(_, let title, let isOn):
                    Toggle(title, isOn: isOn)
                        .font(.body)
                        .foregroundStyle(PSTheme.textPrimary)
                        .frame(minHeight: 44)
                case .button(_, let title, let systemImage, let action):
                    Button {
                        Haptics.tap()
                        action()
                    } label: {
                        Label(title, systemImage: systemImage)
                            .font(.body)
                            .foregroundStyle(PSTheme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.98))
                }
            }
        }
    }

    private func choose(_ item: ToolItem) {
        onDismiss()
        switch item {
        case .panel(_, _, _, _, let open):
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                open()
            }
        case .action(_, _, _, _, let run):
            run()
        }
    }
}

#if DEBUG
extension ToolCatalog {
    /// A small photo-like catalog for previews.
    static func preview(open: @escaping () -> Void) -> ToolCatalog {
        ToolCatalog(editorKind: "preview", categories: [
            ToolCategory(id: "magic", title: "Magie", symbol: "sparkles", items: [
                .action(id: "enhance", title: "Améliorer", symbol: "wand.and.stars", isMagic: true, run: {}),
                .action(id: "cleanup", title: "Nettoyer", symbol: "eraser", isMagic: true, run: {}),
                .panel(id: "focus", title: "Flou portrait", symbol: "camera.aperture", isModified: true, open: open),
            ]),
            ToolCategory(id: "light", title: "Lumière et couleur", symbol: "dial.medium", items: [
                .panel(id: "adjust", title: "Réglages", symbol: "slider.horizontal.3", isModified: true, open: open),
                .panel(id: "looks", title: "Filtres", symbol: "camera.filters", isModified: false, open: open),
            ]),
        ], footer: [
            .button(id: "help", title: "Que puis-je dire ?", systemImage: "questionmark.circle", action: {}),
        ])
    }
}

private struct ToolsSheetPreview: View {
    var body: some View {
        PSTheme.canvas
            .sheet(isPresented: .constant(true)) {
                ToolsSheet(catalog: .preview(open: {}), onDismiss: {})
            }
    }
}

#Preview("ToolsSheet") {
    ToolsSheetPreview()
}
#endif
#endif
