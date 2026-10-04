#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Actions on the selection (ux-spec §4.8): a floating glass capsule, 44 points tall, with text items in the
/// UIEditMenu style and a leading ‹ (VoiceOver « Désélectionner »). Wider than the screen less 32 points, it
/// scrolls. Items are never white (the screen's one primary stays « OK » or « Exporter », AC-04); destructive
/// items come last, in red.
///
/// Place it above the selection's bounding box with `ContextBar.origin(...)`, or dock it in zone C through
/// EditorShell's `dockedContextBar` when the panel would cover it.
struct ContextBar: View {
    struct Item: Identifiable {
        /// Probe id ("text.edit", "context.remove.erase").
        var id: String
        var title: String
        var systemImage: String?
        var isDestructive = false
        var isEnabled = true
        var action: () -> Void

        init(id: String, title: String, systemImage: String? = nil, isDestructive: Bool = false, isEnabled: Bool = true,
             action: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.isDestructive = isDestructive
            self.isEnabled = isEnabled
            self.action = action
        }
    }

    let items: [Item]
    /// The leading ‹; nil hides it (Retirer's « Effacer · Ignorer » bar).
    var onDeselect: (() -> Void)?

    init(items: [Item], onDeselect: (() -> Void)? = nil) {
        self.items = items
        self.onDeselect = onDeselect
    }

    /// A selection kind's bar from the editor's ToolLayout: labels from the glossary, `perform` gets the item id.
    init(layout: ToolLayout, selection: SelectionKind, onDeselect: (() -> Void)? = nil, isEnabled: (String) -> Bool = { _ in true },
         perform: @escaping (String) -> Void) {
        let items = layout.bar(selection: selection).map { item in
            Item(id: item.id, title: UXGlossary.label(item.term), isDestructive: item.isDestructive, isEnabled: isEnabled(item.id)) {
                perform(item.id)
            }
        }
        self.init(items: items, onDeselect: onDeselect)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let onDeselect {
                Button {
                    Haptics.tick()
                    onDeselect()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(PSFont.glyph(.chip, weight: .semibold))
                        .foregroundStyle(Color.psTextPrimary)
                        .frame(width: PSMetrics.hitMinimum, height: PSMetrics.contextBar)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PSPressStyle(scale: 0.92))
                .accessibilityLabel(L("Deselect"))
                .uxProbe(id: "context.deselect", role: .back)
            }
            ViewThatFits(in: .horizontal) {
                row
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .frame(height: PSMetrics.contextBar)
        .psGlass(shape: AnyShape(Capsule()))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Selection actions"))
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                ContextBarButton(item: item)
            }
        }
        .padding(.horizontal, onDeselect == nil ? PSSpacing.xSmall : 0)
        .padding(.trailing, onDeselect == nil ? 0 : PSSpacing.xSmall)
    }

    /// Where the bar's top-left corner goes: centred above `selection` with an 8-point gap, below it when there is
    /// no room above, kept inside `canvas` and above `reservedBottom` (the feedback slot and the panel). All in the
    /// same coordinate space.
    static func origin(for size: CGSize, above selection: CGRect, in canvas: CGRect, reservedBottom: CGFloat) -> CGPoint {
        let gap = PSSpacing.small
        let margin = PSSpacing.large
        var x = selection.midX - size.width / 2
        x = min(max(x, canvas.minX + margin), max(canvas.minX + margin, canvas.maxX - margin - size.width))
        var y = selection.minY - gap - size.height
        if y < canvas.minY + margin {
            y = selection.maxY + gap
        }
        let floor = min(canvas.maxY, reservedBottom) - margin - size.height
        y = min(max(y, canvas.minY + margin), max(canvas.minY + margin, floor))
        return CGPoint(x: x, y: y)
    }
}

private struct ContextBarButton: View {
    let item: ContextBar.Item

    var body: some View {
        Button {
            Haptics.tap()
            item.action()
        } label: {
            HStack(spacing: PSSpacing.xSmall + 2) {
                if let symbol = item.systemImage {
                    Image(systemName: symbol)
                        .font(PSFont.glyph(.micro, weight: .semibold))
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(item.isDestructive ? Color.psDanger : Color.psTextPrimary)
            .padding(.horizontal, PSSpacing.medium)
            .frame(minWidth: PSMetrics.hitMinimum, minHeight: PSMetrics.contextBar)
            .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.95))
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.4)
        .uxProbe(id: item.id, role: .contextBar)
    }
}
#endif
