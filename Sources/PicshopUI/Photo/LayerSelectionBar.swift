#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// The multi-selection action bar (W3, §7.3): under the rows in « Sélectionner » mode, Grouper, Fusionner, Dupliquer,
/// Masquer, Supprimer and Aligner ▸ (the eight `LayerAlignment` cases). Each is one history step on the checked
/// layers, in stacking order; position-locked layers are skipped by Aligner and named in its toast.
struct LayerSelectionBar: View {
    let session: PhotoEditorSession

    var body: some View {
        let chosen = session.actedLayers.filter { $0 != session.document.baseLayerID }
        let pro = session.proLayersEnabled
        VStack(spacing: PSSpacing.small) {
            Text(String(format: L("%d selected"), chosen.count))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.psTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.numericText())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    if pro {
                        IconChip(title: L("Group"), symbol: "folder.badge.plus", isEnabled: !chosen.isEmpty) {
                            session.groupLayers(chosen)
                            session.setSelecting(false)
                        }
                        .accessibilityIdentifier("layers.selection.group")
                        IconChip(title: L("Merge"), symbol: "square.and.arrow.down.on.square", isEnabled: chosen.count >= 2) {
                            session.mergeSelectedLayers(chosen)
                            session.setSelecting(false)
                        }
                        .accessibilityIdentifier("layers.selection.merge")
                    }
                    IconChip(title: L("Duplicate"), symbol: "plus.square.on.square", isEnabled: !chosen.isEmpty) {
                        session.duplicateLayers(chosen)
                    }
                    .accessibilityIdentifier("layers.selection.duplicate")
                    IconChip(title: L("Hide"), symbol: "eye.slash", isEnabled: !chosen.isEmpty) {
                        session.hideLayers(chosen)
                    }
                    .accessibilityIdentifier("layers.selection.hide")
                    IconChip(title: L("Delete"), symbol: "trash", isEnabled: !chosen.isEmpty, tint: PSTheme.danger) {
                        session.requestDeleteLayers(chosen)
                    }
                    .accessibilityIdentifier("layers.selection.delete")
                    Menu {
                        ForEach(LayerAlignment.allCases, id: \.self) { alignment in
                            Button {
                                session.alignLayers(chosen, alignment)
                            } label: {
                                Label(Self.title(alignment), systemImage: Self.symbol(alignment))
                            }
                            .disabled(alignment == .distributeH || alignment == .distributeV ? chosen.count < 3 : chosen.isEmpty)
                            .accessibilityIdentifier("layers.align.\(alignment.rawValue)")
                        }
                    } label: {
                        VStack(spacing: PSSpacing.xSmall) {
                            Image(systemName: "align.horizontal.center")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.psTextPrimary)
                            Text(L("Align"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.psTextSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 68, height: 52)
                        .background(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous).fill(Color.psFillControl))
                        .contentShape(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.4 : 1)
                }
            }
        }
        .animation(PSSpring.quick, value: chosen.count)
    }

    static func title(_ alignment: LayerAlignment) -> String {
        switch alignment {
        case .left: return L("Align left")
        case .centerH: return L("Centre horizontally")
        case .right: return L("Align right")
        case .top: return L("Align top")
        case .centerV: return L("Centre vertically")
        case .bottom: return L("Align bottom")
        case .distributeH: return L("Distribute horizontally")
        case .distributeV: return L("Distribute vertically")
        }
    }

    static func symbol(_ alignment: LayerAlignment) -> String {
        switch alignment {
        case .left: return "align.horizontal.left"
        case .centerH: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .centerV: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .distributeH: return "distribute.horizontal.center"
        case .distributeV: return "distribute.vertical.center"
        }
    }
}
#endif
