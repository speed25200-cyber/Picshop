#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// What a tool acts on (ux-spec §4.5, §3.5.4): the photo, a layer, the active selection, a saved zone, a clip, or a
/// new adjustment layer.
struct PanelTarget: Identifiable, Hashable {
    enum Scope: Hashable {
        /// « Sur : la photo ».
        case whole
        /// « Sur : Calque 2 ».
        case layer
        /// « Dans la sélection : Ciel » (yellow).
        case selection
        /// « Dans la zone : Ciel » (yellow).
        case zone
        /// « Clip 3 ».
        case clip
        /// « Nouveau calque de réglage » (photo).
        case newAdjustmentLayer
    }

    var id: String
    var scope: Scope
    /// « la photo », « Calque 2 », « Ciel », « Clip 3 ».
    var name: String

    init(id: String, scope: Scope, name: String) {
        self.id = id
        self.scope = scope
        self.name = name
    }

    /// « Sur : la photo » (photo, whole image).
    static var photo: PanelTarget { PanelTarget(id: "photo", scope: .whole, name: L("the photo")) }
    /// « Nouveau calque de réglage ».
    static var newAdjustmentLayer: PanelTarget { PanelTarget(id: "newAdjustmentLayer", scope: .newAdjustmentLayer, name: "") }

    /// The pill's words.
    var text: String {
        switch scope {
        case .whole, .layer: return String(format: L("On: %@"), name)
        case .selection: return String(format: L("In the selection: %@"), name)
        case .zone: return String(format: L("In the area: %@"), name)
        case .clip: return name
        case .newAdjustmentLayer: return L("New adjustment layer")
        }
    }

    /// A scoped target turns the pill yellow, and the ants or the zone outline stay on the canvas.
    var isScoped: Bool { scope == .selection || scope == .zone }
}

/// Panel row B's leading target pill (§4.5): « Sur : la photo ▾ », yellow when scoped. A menu of the eligible
/// targets when there are several; plain, without ▾, when there is only one. Flat inside the panel's glass.
struct TargetPill: View {
    let current: PanelTarget
    let targets: [PanelTarget]
    var thumbnail: Image?
    let onSelect: (PanelTarget) -> Void

    init(current: PanelTarget, targets: [PanelTarget], thumbnail: Image? = nil, onSelect: @escaping (PanelTarget) -> Void) {
        self.current = current
        self.targets = targets
        self.thumbnail = thumbnail
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            if targets.count > 1 {
                Menu {
                    ForEach(targets) { target in
                        Button {
                            Haptics.tick()
                            onSelect(target)
                        } label: {
                            if target.id == current.id {
                                Label(target.text, systemImage: "checkmark")
                            } else {
                                Text(target.text)
                            }
                        }
                    }
                } label: {
                    pill(showsChevron: true)
                }
                .menuStyle(.button)
                .buttonStyle(PSPressStyle(scale: 0.97))
            } else {
                pill(showsChevron: false)
            }
        }
        .accessibilityLabel(current.text)
        .accessibilityHint(targets.count > 1 ? L("Choose what the tool changes") : "")
        .uxProbe(id: "panel.target")
    }

    private func pill(showsChevron: Bool) -> some View {
        HStack(spacing: PSSpacing.xSmall + 2) {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous))
            }
            Text(current.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
        }
        .foregroundStyle(current.isScoped ? Color.psOnValueAccent : Color.psTextPrimary)
        .padding(.horizontal, PSSpacing.medium)
        .frame(minHeight: PSMetrics.chipVisual)
        .background(Capsule().fill(current.isScoped ? Color.psValueAccent : Color.psFillControl))
        .psHitArea(visible: PSMetrics.chipVisual)
    }
}
#endif
