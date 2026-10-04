#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// « Fusion » (W3, §7.6): the layer's blend mode as a chip; opened, a strip of the 27 modes in Photoshop's six families
/// with dividers, and the mode centred in the strip previews live on the picture (an interactive edit per mode on the
/// `.layerPlacement` snapshot, at scroll rate). OK commits one step, Annuler or closing drops it.
struct BlendModePicker: View {
    let session: PhotoEditorSession
    let layerID: UUID
    let mode: PicshopCore.BlendMode

    @State private var isOpen = false
    @State private var centredID: String?

    private struct Item: Identifiable, Hashable {
        var id: String
        var mode: PicshopCore.BlendMode?
    }

    /// The modes in family order, a divider between families.
    private static let items: [Item] = {
        var items: [Item] = []
        for (index, family) in PicshopCore.BlendMode.Group.allCases.enumerated() {
            if index > 0 { items.append(Item(id: "divider.\(family.rawValue)", mode: nil)) }
            for mode in family.modes { items.append(Item(id: "mode.\(mode.rawValue)", mode: mode)) }
        }
        return items
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            HStack(spacing: PSSpacing.small) {
                Text(L("Blend"))
                    .font(PSFontRole.inspectorLabel)
                    .foregroundStyle(Color.psTextSecondary)
                Spacer(minLength: PSSpacing.small)
                if isOpen {
                    PanelChip(title: L("Cancel")) { close(commit: false) }
                    PanelActionButton(title: L("OK")) { close(commit: true) }
                } else {
                    Button(action: open) {
                        HStack(spacing: PSSpacing.xSmall) {
                            Text(BlendModeMenu.name(mode))
                                .font(PSFontRole.inspectorValue)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.psTextTertiary)
                        }
                        .foregroundStyle(mode == .normal ? Color.psTextPrimary : Color.psValueAccent)
                        .padding(.horizontal, PSSpacing.medium)
                        .frame(minHeight: PSMetrics.chip)
                        .background(Capsule().fill(Color.psFillControl))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .accessibilityLabel(L("Blend"))
                    .accessibilityValue(BlendModeMenu.name(mode))
                }
            }
            .frame(minHeight: PSMetrics.inspectorRow)
            if isOpen {
                strip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(PSSpring.standard, value: isOpen)
        .onDisappear {
            if isOpen { session.cancelBlendPreview() }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: PSSpacing.xSmall) {
                ForEach(Self.items) { item in
                    if let itemMode = item.mode {
                        let isCentred = centredID == item.id
                        Button {
                            withAnimation(PSSpring.quick) { centredID = item.id }
                        } label: {
                            Text(BlendModeMenu.name(itemMode))
                                .font(.footnote.weight(isCentred ? .semibold : .regular))
                                .lineLimit(1)
                                .foregroundStyle(isCentred ? Color.psOnAction : Color.psTextPrimary)
                                .padding(.horizontal, PSSpacing.medium)
                                .frame(minHeight: PSMetrics.chip)
                                .background(Capsule().fill(isCentred ? Color.psActionPrimary : Color.psFillControl))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PSPressStyle(scale: 0.95))
                        .id(item.id)
                        .accessibilityAddTraits(isCentred ? [.isSelected] : [])
                        .accessibilityIdentifier("layers.props.blend.\(itemMode.rawValue)")
                    } else {
                        Capsule()
                            .fill(Color.psStrokeStrong)
                            .frame(width: 1, height: PSMetrics.chip * 0.6)
                            .padding(.horizontal, PSSpacing.xSmall)
                            .id(item.id)
                            .accessibilityHidden(true)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 140, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centredID, anchor: .center)
        .frame(height: PSMetrics.control)
        .onChange(of: centredID) { _, id in
            guard let id, let preview = Self.items.first(where: { $0.id == id })?.mode else { return }
            Haptics.tick()
            session.previewBlend(preview, layerID: layerID)
        }
    }

    private func open() {
        guard session.beginBlendPreview(layerID) else { return }
        Haptics.tick()
        centredID = "mode.\(mode.rawValue)"
        isOpen = true
    }

    private func close(commit: Bool) {
        if commit {
            session.commitBlendPreview()
        } else {
            session.cancelBlendPreview()
        }
        isOpen = false
    }
}
#endif
