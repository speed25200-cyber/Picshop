#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

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

/// A segment of the Outils sheet.
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
///
/// W1 (studioWorkspace): every category, in a bar that scrolls sideways, and a
/// search field over the tool names and their synonyms, matched on the device
/// and never sent to the model. A search that finds nothing offers to ask Live
/// (`onAsk`), which only happens on that tap. Medium and large detents.
struct ToolsSheet: View {
    let catalog: ToolCatalog
    let onPick: (ToolsSheetPick) -> Void
    var onAsk: ((String) -> Void)?
    @AppStorage private var lastCategory: String
    @State private var query = ""
    @State private var isStudio = FeatureFlags.isOn(.studioWorkspace)
    @Environment(\.dynamicTypeSize) private var typeSize

    init(catalog: ToolCatalog, onPick: @escaping (ToolsSheetPick) -> Void, onAsk: ((String) -> Void)? = nil) {
        self.catalog = catalog
        self.onPick = onPick
        self.onAsk = onAsk
        _lastCategory = AppStorage(wrappedValue: "", "tools.lastCategory.\(catalog.editorKind)")
    }

    /// Every category: the W0 cap of five is gone (new categories would have vanished).
    private var categories: [ToolCategory] { catalog.categories }

    private var selected: ToolCategory? {
        categories.first { $0.id == lastCategory && $0.items.count > 1 } ?? categories.first { $0.items.count > 1 } ?? categories.first
    }

    var body: some View {
        if isStudio {
            NavigationStack {
                sheetContent
                    .navigationTitle(L("Tools"))
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(L("Search tools")))
                    .autocorrectionDisabled()
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        } else {
            sheetContent
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var sheetContent: some View {
        ScrollView {
            VStack(spacing: PSSpacing.large) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if isStudio, !trimmed.isEmpty {
                    searchResults(trimmed)
                } else {
                    if categories.count > 1 {
                        categoryBar
                    }
                    if let selected {
                        tiles(selected.items)
                    }
                }
                if !catalog.footer.isEmpty, query.isEmpty {
                    footer
                }
            }
            .padding(.horizontal, PSSpacing.page)
            .padding(.top, PSSpacing.small)
            .padding(.bottom, PSSpacing.page)
            .animation(PSSpring.quick, value: selected?.id)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func tiles(_ items: [ToolItem]) -> some View {
        if typeSize.isAccessibilitySize {
            list(items)
        } else {
            grid(items)
        }
    }

    // MARK: Search

    /// Every tile whose name or synonyms hold every word typed, once each, in catalog order.
    @ViewBuilder
    private func searchResults(_ text: String) -> some View {
        let found = ToolSearch.matches(text, in: catalog)
        if found.isEmpty {
            VStack(spacing: PSSpacing.medium) {
                Image(systemName: "magnifyingglass")
                    .font(.title.weight(.light))
                    .foregroundStyle(Color.psTextTertiary)
                Text(L("No tool by that name."))
                    .font(PSFont.control(selected: true))
                    .foregroundStyle(Color.psTextSecondary)
                    .multilineTextAlignment(.center)
                if let onAsk {
                    PSPanelPrimaryButton(String(format: L("Ask PicShop: “%@”"), text), systemImage: "arrow.up", height: PSMetrics.control) {
                        onPick(.action({ onAsk(text) }))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PSSpacing.xLarge)
        } else {
            tiles(found)
        }
    }

    // MARK: Categories

    @ViewBuilder
    private var categoryBar: some View {
        if isStudio {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PSSpacing.xSmall) {
                        ForEach(categories) { category in
                            categoryButton(category)
                                .frame(minWidth: PSMetrics.toolTile)
                                .id(category.id)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onAppear {
                    if let id = selected?.id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        } else {
            HStack(spacing: PSSpacing.xSmall) {
                ForEach(categories) { category in
                    categoryButton(category)
                        .frame(maxWidth: .infinity)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }

    private func categoryButton(_ category: ToolCategory) -> some View {
        let isSelected = category.id == selected?.id
        let shape = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
        return Button {
            choose(category)
        } label: {
            VStack(spacing: PSSpacing.xSmall) {
                Image(systemName: category.symbol)
                    .font(PSFont.glyph(.dock))
                Text(category.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.psOnAction : Color.psTextSecondary)
            .padding(.horizontal, PSSpacing.small)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(shape.fill(isSelected ? Color.psActionPrimary : Color.clear))
            .contentShape(shape)
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: PSMetrics.toolTile), spacing: PSSpacing.medium)], spacing: PSSpacing.medium) {
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
        let shape = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items) { item in
                Button {
                    Haptics.tap()
                    pick(item)
                } label: {
                    HStack(spacing: 10) {
                        ToolGlyph(item: item, size: .dock)
                        Text(item.title)
                            .font(.body)
                            .foregroundStyle(Color.psTextPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(PSSpacing.medium)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(shape.fill(Color.psFillControl))
                    .overlay(alignment: .topTrailing) { ModifiedDot(isOn: item.isModified) }
                    .contentShape(shape)
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
                    Rectangle().fill(Color.psHairline).frame(height: 1)
                }
                switch item {
                case .toggle(_, let title, let isOn):
                    Toggle(isOn: isOn) {
                        Text(title).font(.body).foregroundStyle(Color.psTextPrimary)
                    }
                    .tint(Color.psSuccess)
                    .frame(minHeight: PSMetrics.control)
                    .sensoryFeedback(.selection, trigger: isOn.wrappedValue)
                case .button(_, let title, let systemImage, let action):
                    Button {
                        Haptics.tap()
                        onPick(.action(action))
                    } label: {
                        HStack(spacing: PSSpacing.medium) {
                            Image(systemName: systemImage)
                                .font(PSFont.glyph(.bar))
                                .foregroundStyle(Color.psTextSecondary)
                                .frame(width: 24)
                            Text(title).font(.body).foregroundStyle(Color.psTextPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.psTextTertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: PSMetrics.control, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.98))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous).fill(Color.psFillWell))
    }
}

/// The Outils search: tool names plus a few synonyms per tool, in both
/// languages, folded (lowercase, no accents). Local only.
enum ToolSearch {
    /// Extra words by tool id (photo, video and PDF panels and actions).
    static let synonyms: [String: [String]] = [
        "adjust": ["exposition", "exposure", "luminosite", "brightness", "contraste", "contrast", "reglages", "lumiere", "light", "ombres", "shadows", "hautes lumieres", "highlights"],
        "curves": ["courbe", "curve", "tone curve", "courbe de tonalite", "s curve"],
        "levels": ["niveau", "level", "histogramme", "histogram", "noir", "blanc", "black point", "white point"],
        "color": ["couleur", "colour", "teinte", "hue", "saturation", "tsl", "hsl", "etalonnage", "grade", "lut"],
        "looks": ["filtre", "filter", "look", "preset", "style"],
        "crop": ["recadrer", "cadrer", "rogner", "redresser", "straighten", "rotate", "pivoter", "perspective", "format"],
        "erase": ["effacer", "gomme", "supprimer", "remove", "clean", "nettoyer"],
        "precise": ["precis", "pinceau", "brush", "lasso"],
        "cutout": ["detourage", "detourer", "fond", "background", "sujet", "subject"],
        "text": ["texte", "titre", "title", "ecrire", "write", "typo", "font", "police"],
        "shapes": ["forme", "shape", "rectangle", "cercle", "circle", "fleche", "arrow"],
        "layers": ["calque", "layer", "fusion", "blend", "opacite", "opacity", "mode",
                   // W3: the layer tools.
                   "groupe", "group", "ecretage", "clipping", "masque de fusion", "layer mask", "remplissage", "fill", "degrade", "gradient",
                   "calque de reglage", "adjustment layer", "transformer", "transform", "perspective", "aligner", "align", "fusionner", "merge",
                   "aplatir", "flatten", "tampon", "stamp", "photo par-dessus", "image layer", "verrou", "lock"],
        "focus": ["flou", "blur", "portrait", "bokeh", "profondeur", "depth"],
        "magic": ["objet", "object", "deplacer", "move"],
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Tiles whose title, id or synonyms contain every word of `query`, once each, in catalog order.
    static func matches(_ query: String, in catalog: ToolCatalog) -> [ToolItem] {
        let words = fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        var found: [ToolItem] = []
        for category in catalog.categories {
            for item in category.items where !seen.contains(item.id) {
                let haystack = ([item.title, item.id, category.title] + (synonyms[item.id] ?? [])).map(fold).joined(separator: " ")
                if words.allSatisfy({ haystack.contains($0) }) {
                    seen.insert(item.id)
                    found.append(item)
                }
            }
        }
        return found
    }
}

/// A 76 × 84 tile: the symbol on a 76 × 60 plate, the name under it.
private struct ToolTile: View {
    let item: ToolItem

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
        VStack(spacing: 6) {
            ToolGlyph(item: item, size: .tile)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(plate.fill(Color.psFillControl))
                .overlay(alignment: .topTrailing) { ModifiedDot(isOn: item.isModified) }
            Text(item.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.psTextSecondary)
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
    let size: PSGlyph

    var body: some View {
        if item.isMagic {
            MagicGlyph(size: size.rawValue, symbol: item.symbol)
        } else {
            Image(systemName: item.symbol)
                .font(PSFont.glyph(size))
                .foregroundStyle(Color.psTextPrimary)
        }
    }
}

/// Photos' 5-point yellow dot: this tool's edits are in the picture.
private struct ModifiedDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(Color.psValueAccent)
            .frame(width: PSMetrics.modifiedDot, height: PSMetrics.modifiedDot)
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
        Color.psCanvas
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
