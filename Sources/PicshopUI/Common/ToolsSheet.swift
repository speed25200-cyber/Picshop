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

    var title: String {
        switch self {
        case .panel(_, let title, _, _, _), .action(_, let title, _, _, _): return title
        }
    }

    var symbol: String {
        switch self {
        case .panel(_, _, let symbol, _, _), .action(_, _, let symbol, _, _): return symbol
        }
    }

    var isMagic: Bool {
        if case .action(_, _, _, let isMagic, _) = self { return isMagic }
        return false
    }

    var isModified: Bool {
        if case .panel(_, _, _, let isModified, _) = self { return isModified }
        return false
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

/// What a tap in the sheet asks StudioChrome to do once it closes the sheet.
enum ToolsSheetPick {
    /// Open a panel 0.15 s after the sheet starts leaving, so the panel rises as it goes.
    case panel(() -> Void)
    /// Run once the sheet has gone (it may present something itself).
    case action(() -> Void)
}

/// The Outils sheet: a category bar, a grid of tiles and footer rows. A panel
/// tile closes the sheet and opens its panel as the sheet leaves; an action
/// tile or a footer button closes the sheet, then runs. A category holding a
/// single panel opens it straight away. At accessibility text sizes the tiles
/// become a two-column list.
struct ToolsSheet: View {
    let catalog: ToolCatalog
    let onPick: (ToolsSheetPick) -> Void
    @AppStorage private var lastCategory: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(catalog: ToolCatalog, onPick: @escaping (ToolsSheetPick) -> Void) {
        self.catalog = catalog
        self.onPick = onPick
        _lastCategory = AppStorage(wrappedValue: "", "tools.lastCategory.\(catalog.editorKind)")
    }

    private var categories: [ToolCategory] { Array(catalog.categories.prefix(5)) }

    private var selected: ToolCategory? {
        categories.first { $0.id == lastCategory && $0.items.count > 1 } ?? categories.first { $0.items.count > 1 } ?? categories.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if categories.count > 1 {
                    categoryBar
                }
                if let selected {
                    if typeSize.isAccessibilitySize {
                        list(selected.items)
                    } else {
                        grid(selected.items)
                    }
                }
                if !catalog.footer.isEmpty {
                    footer
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .animation(PSMotion.quick, value: selected?.id)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: Categories

    private var categoryBar: some View {
        HStack(spacing: 4) {
            ForEach(categories) { category in
                let isSelected = category.id == selected?.id
                Button {
                    choose(category)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 20, weight: .medium))
                        Text(category.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isSelected ? PSTheme.onPrimary : PSTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isSelected ? PSTheme.primary : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// A single-panel category opens its panel; the others show their tiles.
    private func choose(_ category: ToolCategory) {
        if category.items.count == 1, let only = category.items.first {
            Haptics.tap()
            pick(only)
            return
        }
        Haptics.tick()
        lastCategory = category.id
    }

    // MARK: Tiles

    private func grid(_ items: [ToolItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: PSMetrics.toolTile), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
                Button {
                    Haptics.tap()
                    pick(item)
                } label: {
                    ToolTile(item: item)
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .accessibilityLabel(item.title)
                .accessibilityValue(item.isModified ? L("Edited") : "")
            }
        }
    }

    private func list(_ items: [ToolItem]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                Button {
                    Haptics.tap()
                    pick(item)
                } label: {
                    HStack(spacing: 10) {
                        ToolGlyph(item: item, size: 20)
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(PSTheme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: PSRadius.toolTile, style: .continuous).fill(PSTheme.fill))
                    .overlay(alignment: .topTrailing) { ModifiedDot(isOn: item.isModified) }
                    .contentShape(RoundedRectangle(cornerRadius: PSRadius.toolTile, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
                .accessibilityValue(item.isModified ? L("Edited") : "")
            }
        }
    }

    private func pick(_ item: ToolItem) {
        switch item {
        case .panel(_, _, _, _, let open): onPick(.panel(open))
        case .action(_, _, _, _, let run): onPick(.action(run))
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            ForEach(Array(catalog.footer.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(PSTheme.hairline).frame(height: 1)
                }
                switch item {
                case .toggle(_, let title, let isOn):
                    Toggle(isOn: isOn) {
                        Text(title).font(.body).foregroundStyle(PSTheme.textPrimary)
                    }
                    .tint(PSTheme.success)
                    .frame(minHeight: 44)
                    .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
                case .button(_, let title, let systemImage, let action):
                    Button {
                        Haptics.tap()
                        onPick(.action(action))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: systemImage)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(PSTheme.textSecondary)
                                .frame(width: 24)
                            Text(title).font(.body).foregroundStyle(PSTheme.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(PSTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.98))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(PSTheme.fill.opacity(0.6)))
    }
}

/// A 76 × 84 tile: the symbol on a 76 × 60 plate, the name under it.
private struct ToolTile: View {
    let item: ToolItem

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: PSRadius.toolTile, style: .continuous)
        VStack(spacing: 6) {
            ToolGlyph(item: item, size: 22)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(plate.fill(PSTheme.fill))
                .overlay(alignment: .topTrailing) { ModifiedDot(isOn: item.isModified) }
            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(PSTheme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
        .frame(minWidth: PSMetrics.toolTile, minHeight: 84, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// A MagicGlyph for AI actions, a white symbol for manual tools.
private struct ToolGlyph: View {
    let item: ToolItem
    let size: CGFloat

    var body: some View {
        if item.isMagic {
            MagicGlyph(size: size, symbol: item.symbol)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(PSTheme.textPrimary)
        }
    }
}

/// Photos' 5-point yellow dot: this tool's edits are in the picture.
private struct ModifiedDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(PSTheme.accent)
            .frame(width: 5, height: 5)
            .padding(8)
            .opacity(isOn ? 1 : 0)
            .accessibilityHidden(true)
    }
}

#if DEBUG
extension ToolCatalog {
    /// A small photo-like catalog for previews.
    static func preview(open: @escaping () -> Void) -> ToolCatalog {
        ToolCatalog(editorKind: "preview", categories: [
            ToolCategory(id: "magic", title: "Magie", symbol: "sparkles", items: [
                .action(id: "enhance", title: "Améliorer", symbol: "wand.and.stars", isMagic: true, run: {}),
                .action(id: "cleanup", title: "Nettoyer", symbol: "person.2.slash", isMagic: true, run: {}),
                .action(id: "expand", title: "Étendre", symbol: "arrow.up.left.and.arrow.down.right", isMagic: true, run: {}),
                .action(id: "sky", title: "Ciel coucher de soleil", symbol: "sun.horizon", isMagic: true, run: {}),
                .panel(id: "focus", title: "Flou portrait", symbol: "camera.aperture", isModified: true, open: open),
            ]),
            ToolCategory(id: "light", title: "Lumière et couleur", symbol: "dial.medium", items: [
                .panel(id: "adjust", title: "Réglages", symbol: "slider.horizontal.3", isModified: true, open: open),
                .panel(id: "color", title: "Couleur", symbol: "paintpalette", isModified: false, open: open),
                .panel(id: "looks", title: "Filtres", symbol: "camera.filters", isModified: false, open: open),
            ]),
            ToolCategory(id: "crop", title: "Cadrer", symbol: "crop.rotate", items: [
                .panel(id: "crop", title: "Recadrer", symbol: "crop.rotate", isModified: false, open: open),
            ]),
        ], footer: [
            .toggle(id: "split", title: "Avant/après côte à côte", isOn: .constant(false)),
            .button(id: "help", title: "Que puis-je dire ?", systemImage: "questionmark.circle", action: {}),
        ])
    }
}

private struct ToolsSheetPreview: View {
    var body: some View {
        PSTheme.canvas
            .sheet(isPresented: .constant(true)) {
                ToolsSheet(catalog: .preview(open: {}), onPick: { _ in })
            }
    }
}

#Preview("ToolsSheet") {
    ToolsSheetPreview()
}

#Preview("ToolsSheet, accessibility size") {
    ToolsSheetPreview().dynamicTypeSize(.accessibility2)
}
#endif
#endif
