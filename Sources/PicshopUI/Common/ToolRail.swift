#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One tool on the rail: a panel of the editor's Outils, in category order.
struct ToolRailItem: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    /// The tool's edits are in the picture (the yellow dot).
    let isModified: Bool
}

extension ToolCatalog {
    /// Every panel of the catalog, in category order, once each. Actions (the
    /// one-tap Magie) stay in Outils: the rail opens panels only.
    var railItems: [ToolRailItem] {
        var seen = Set<String>()
        var items: [ToolRailItem] = []
        for category in categories {
            for item in category.items {
                guard case .panel(let id, let title, let symbol, let isModified, _) = item, seen.insert(id).inserted else { continue }
                items.append(ToolRailItem(id: id, title: title, symbol: symbol, isModified: isModified))
            }
        }
        return items
    }

    /// The panel with this id, to open from the rail.
    func panel(id: String) -> ToolItem? {
        for category in categories {
            if let item = category.items.first(where: { $0.id == id }), case .panel = item { return item }
        }
        return nil
    }
}

/// The tool rail: a 44-point horizontal strip of tools in one regular-glass
/// capsule above the dock, one tap per tool. The open tool is a white disc
/// with a black glyph; a 5-point yellow dot marks a tool whose edits are in
/// the picture; the last item, 'Tous les outils', opens Outils. Items inside
/// the glass are flat (no glass on glass). It scrolls sideways and keeps the
/// open tool in view.
struct ToolRail: View {
    let items: [ToolRailItem]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onAllTools: () -> Void

    @Environment(\.studioToolsNamespace) private var toolsNamespace

    init(items: [ToolRailItem], selectedID: String?, onSelect: @escaping (String) -> Void, onAllTools: @escaping () -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onAllTools = onAllTools
    }

    /// The id of the last item.
    static let allToolsID = "rail.allTools"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.xSmall) {
                    ForEach(items) { item in
                        ToolRailButton(item: item, isSelected: item.id == selectedID) {
                            guard item.id != selectedID else { return }
                            onSelect(item.id)
                        }
                        .id(item.id)
                    }
                    Rectangle()
                        .fill(Color.psHairline)
                        .frame(width: 1, height: PSMetrics.railItem - 20)
                        .padding(.horizontal, PSSpacing.xSmall)
                        .accessibilityHidden(true)
                    allTools
                        .id(Self.allToolsID)
                }
                .padding(.horizontal, PSSpacing.xSmall)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(height: PSMetrics.railHeight)
            .clipShape(Capsule())
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(PSSpring.standard) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .psGlass(shape: AnyShape(Capsule()))
        .sensoryFeedback(.selection, trigger: selectedID)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Tools"))
    }

    private var allTools: some View {
        Button(action: onAllTools) {
            Image(systemName: "square.grid.2x2")
                .font(PSFont.glyph(.dock))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: PSMetrics.railItem, height: PSMetrics.railItem)
                .contentShape(Circle())
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .modifier(ToolsTransitionSource(namespace: toolsNamespace))
        .accessibilityLabel(L("All tools"))
        .accessibilityShowsLargeContentViewer {
            Label(L("All tools"), systemImage: "square.grid.2x2")
        }
    }
}

/// A 44-point rail item: the symbol, white disc and black glyph when open.
private struct ToolRailButton: View {
    let item: ToolRailItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: item.symbol)
                .font(PSFont.glyph(.dock))
                .foregroundStyle(isSelected ? Color.psOnAction : Color.psTextPrimary)
                .frame(width: PSMetrics.railItem, height: PSMetrics.railItem)
                .background { if isSelected { Circle().fill(Color.psActionPrimary) } }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.psValueAccent)
                        .frame(width: PSMetrics.modifiedDot, height: PSMetrics.modifiedDot)
                        .padding(5)
                        .opacity(item.isModified ? 1 : 0)
                }
                .contentShape(Circle())
                .animation(PSSpring.quick, value: isSelected)
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isModified ? L("Edited") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.symbol)
        }
    }
}

#if DEBUG
private struct ToolRailPreview: View {
    @State private var selected: String? = "adjust"

    var body: some View {
        VStack {
            Spacer()
            ToolRail(items: ToolCatalog.preview(open: {}).railItems, selectedID: selected,
                     onSelect: { selected = $0 }, onAllTools: {})
                .padding(.horizontal, PSSpacing.editorSide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.psCanvas)
    }
}

#Preview("ToolRail") {
    ToolRailPreview()
}
#endif
#endif
