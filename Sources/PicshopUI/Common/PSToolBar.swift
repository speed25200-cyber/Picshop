#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// UX 2.0 (ux-spec §4.3, §4.4): the labelled tool bar (level 0: categories, or a selection's context bar) and the
// tool strip that replaces it while a panel is open. Icon above word, never truncated: an item widens instead,
// and the bar scrolls only when its items do not fit (the photo category bar always fits at default text size,
// AC-17). They replace the icon-only ToolRail, the sibling ModeSegments and the Outils grid. U1 owns this file.

/// One bar or strip item.
struct PSToolBarItem: Identifiable, Equatable {
    /// "adjust" (bar) or "adjust.light" (strip): the ToolLayout id.
    var id: String
    var title: String
    var systemImage: String
    /// The yellow dot: the category or tool has edits.
    var isModified = false
    var isEnabled = true
    /// Why it is disabled (« Ajoutez d'abord un calque »), said by VoiceOver.
    var disabledReason: String?
    /// « Suggéré » on Magie's two ranked tiles.
    var badge: String?
    /// An inline progress ring replaces the glyph; the label keeps its width.
    var isBusy = false

    init(id: String, title: String, systemImage: String, isModified: Bool = false, isEnabled: Bool = true,
         disabledReason: String? = nil, badge: String? = nil, isBusy: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isModified = isModified
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.badge = badge
        self.isBusy = isBusy
    }

    /// A ToolLayout entry, its label from the glossary.
    init(_ item: ToolLayout.BarItem, isModified: Bool = false, isEnabled: Bool = true, badge: String? = nil) {
        self.init(id: item.id, title: UXGlossary.label(item.term), systemImage: item.glyph, isModified: isModified, isEnabled: isEnabled,
                  badge: badge)
    }

    /// The category bar of an editor (nothing selected); `modified` holds category ids.
    static func categories(of layout: ToolLayout, modified: Set<String> = []) -> [PSToolBarItem] {
        layout.bar().map { PSToolBarItem($0, isModified: modified.contains($0.id)) }
    }

    /// A category's (or a pill's) live tools; `modified` holds tool ids, `badges` « Suggéré » by tool id.
    static func strip(of layout: ToolLayout, category: String, modified: Set<String> = [], badges: [String: String] = [:]) -> [PSToolBarItem] {
        layout.strip(category: category).map { PSToolBarItem($0, isModified: modified.contains($0.id), badge: badges[$0.id]) }
    }
}

/// How a bar draws its items.
enum PSToolBarStyle: Sendable {
    /// Level 0, 56 points: categories, or a selection's context bar.
    case bar
    /// A tool strip, 52 points, in place of the bar while a panel is open.
    case strip
    /// Magie's action tiles: up to 96 points wide, the label on two lines.
    case tiles

    var height: CGFloat {
        switch self {
        case .bar: return PSMetrics.toolBar
        case .strip: return PSMetrics.toolStrip
        case .tiles: return PSMetrics.toolBar + PSSpacing.small
        }
    }

    /// The probe id's prefix ("bar.adjust", "strip.adjust.light").
    var probePrefix: String {
        switch self {
        case .bar: return "bar."
        case .strip, .tiles: return "strip."
        }
    }
}

/// The labelled tool bar. Items: a 22-point glyph over a caption2 semibold label, at least 48 points wide (label
/// plus 4) with a 44 × 56 hit area; selected = white fill, black glyph and label; modified = yellow dot; disabled =
/// 24 % with its reason. Equal flexible gaps when everything fits; otherwise a horizontal scroll that keeps the
/// selected item in view. A context bar adds a leading ‹ (VoiceOver « Désélectionner »).
struct PSToolBar: View {
    let items: [PSToolBarItem]
    var selectedID: String?
    var style: PSToolBarStyle
    /// A context bar's leading ‹; nil hides it (categories, photo strips: « OK » goes up).
    var onDeselect: (() -> Void)?
    let onSelect: (String) -> Void

    init(items: [PSToolBarItem], selectedID: String? = nil, style: PSToolBarStyle = .bar, onDeselect: (() -> Void)? = nil,
         onSelect: @escaping (String) -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.style = style
        self.onDeselect = onDeselect
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if let onDeselect {
                    PSToolBarDeselectButton(height: style.height, action: onDeselect)
                }
                ViewThatFits(in: .horizontal) {
                    fittedRow
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: PSSpacing.xSmall) { cells }
                            .padding(.trailing, PSSpacing.large)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    // More items to the right: the edge fades instead of cutting a label in half.
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: PSSpacing.large * 2)
                        }
                    }
                }
            }
            .padding(.horizontal, PSMetrics.toolBarInset)
            .frame(height: style.height)
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(PSSpring.standard) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
    }

    /// Everything fits: equal flexible gaps between the items.
    private var fittedRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Spacer(minLength: 2) }
                cell(item)
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        ForEach(items) { item in
            cell(item)
        }
    }

    private func cell(_ item: PSToolBarItem) -> some View {
        PSToolBarCell(item: item, isSelected: item.id == selectedID, style: style) {
            onSelect(item.id)
        }
        .id(item.id)
    }
}

/// A tool strip (§4.4): the bar's look at 52 points, in place of the bar while a panel is open. No leading ‹ in
/// photo strips (« OK » goes up). It scrolls to keep the current item visible; switching tools keeps changes.
struct PSToolStrip: View {
    let items: [PSToolBarItem]
    let selectedID: String?
    /// Magie's wider two-line action tiles.
    var showsTiles = false
    let onSelect: (String) -> Void

    init(items: [PSToolBarItem], selectedID: String?, showsTiles: Bool = false, onSelect: @escaping (String) -> Void) {
        self.items = items
        self.selectedID = selectedID
        self.showsTiles = showsTiles
        self.onSelect = onSelect
    }

    var body: some View {
        PSToolBar(items: items, selectedID: selectedID, style: showsTiles ? .tiles : .strip, onSelect: onSelect)
    }
}

private struct PSToolBarCell: View {
    let item: PSToolBarItem
    let isSelected: Bool
    let style: PSToolBarStyle
    let action: () -> Void

    var body: some View {
        Button {
            guard item.isEnabled else { return }
            action()
        } label: {
            VStack(spacing: PSSpacing.xSmall) {
                glyph
                    .frame(height: 24)
                label
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 2)
            .frame(minWidth: PSMetrics.toolBarItemMinWidth, minHeight: style.height - PSSpacing.xSmall)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous).fill(Color.psActionPrimary)
                }
            }
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color.psValueAccent)
                    .frame(width: PSMetrics.modifiedDot, height: PSMetrics.modifiedDot)
                    .padding(PSSpacing.xSmall)
                    .opacity(item.isModified ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isModified ? L("Edited") : "")
        .accessibilityHint(item.isEnabled ? "" : (item.disabledReason ?? ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.systemImage)
        }
        .uxProbe(id: style.probePrefix + item.id, role: .tool)
    }

    private var foreground: Color {
        if isSelected { return Color.psOnAction }
        return item.isEnabled ? Color.psTextPrimary : Color.psTextDisabled
    }

    @ViewBuilder
    private var glyph: some View {
        if item.isBusy {
            ProgressView()
                .controlSize(.small)
                .tint(foreground)
        } else {
            Image(systemName: item.systemImage)
                .font(PSFont.glyph(.tile))
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .bar, .strip:
            Text(item.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        case .tiles:
            VStack(spacing: 2) {
                Text(item.title)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge = item.badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.psOnAction : Color.psTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: PSMetrics.toolTileMaxWidth - PSSpacing.small)
        }
    }
}

private struct PSToolBarDeselectButton: View {
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tick()
            action()
        } label: {
            Image(systemName: "chevron.backward")
                .font(PSFont.glyph(.bar, weight: .semibold))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: PSMetrics.hitMinimum, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(L("Deselect"))
        .uxProbe(id: "context.deselect", role: .back)
    }
}
#endif
