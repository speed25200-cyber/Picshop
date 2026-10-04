#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// The masks of the photo, in order (W2): a thumbnail of each mask, its name, its eye, and a menu (Renommer,
/// Dupliquer, Inverser, Mettre à jour when its AI raster was made for another state of the picture, Supprimer).
/// A tap selects the mask (its tint flashes on the canvas). VoiceOver reads « Ciel, masque, visible, exposition
/// plus 0,3 ».
struct MaskListView: View {
    let session: PhotoEditorSession

    @State private var renaming: LocalAdjustment?
    @State private var draft = ""

    var body: some View {
        let masks = session.document.localAdjustments
        let names = MaskAccessibility.displayNames(for: masks, language: psPrefersFrench ? .fr : .en)
        let selectedID = session.maskState.selectedID
        VStack(spacing: PSSpacing.xSmall) {
            ForEach(Array(masks.enumerated()), id: \.element.id) { index, adjustment in
                row(adjustment, name: names[index], isSelected: adjustment.id == selectedID)
            }
        }
        .alert(L("Rename the mask"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $draft)
            Button(L("Cancel"), role: .cancel) { renaming = nil }
            Button(L("OK")) {
                if let adjustment = renaming { session.renameMask(adjustment.id, to: draft) }
                renaming = nil
            }
        }
    }

    private func row(_ adjustment: LocalAdjustment, name: String, isSelected: Bool) -> some View {
        let stale = session.isStale(adjustment)
        return HStack(spacing: PSSpacing.medium) {
            MaskThumbnail(image: session.maskState.thumbnails[adjustment.id])
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.psTextPrimary)
                    .lineLimit(1)
                Text(summary(adjustment))
                    .font(.caption2)
                    .foregroundStyle(stale ? Color.psWarning : Color.psTextTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: PSSpacing.small)
            LayerRowButton(symbol: adjustment.isVisible ? "eye" : "eye.slash", enabled: true) {
                session.toggleMaskVisibility(adjustment.id)
            }
            .accessibilityLabel(adjustment.isVisible ? L("Hide the mask") : L("Show the mask"))
            .accessibilityIdentifier("masks.list.visible")
            Menu {
                Button { draft = adjustment.name ?? name; renaming = adjustment } label: { Label(L("Rename"), systemImage: "pencil") }
                    .accessibilityIdentifier("masks.list.rename")
                Button { session.duplicateMask(adjustment.id) } label: { Label(L("Duplicate"), systemImage: "plus.square.on.square") }
                    .disabled(!session.canAddMask)
                    .accessibilityIdentifier("masks.list.duplicate")
                Button { session.invertMask(adjustment.id) } label: { Label(L("Invert"), systemImage: "circle.lefthalf.filled") }
                    .accessibilityIdentifier("masks.list.invert")
                if stale {
                    Button { session.refreshAIMask(adjustment.id) } label: { Label(L("Update"), systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("masks.list.refresh")
                }
                Divider()
                Button(role: .destructive) { session.deleteMask(adjustment.id) } label: { Label(L("Delete"), systemImage: "trash") }
                    .accessibilityIdentifier("masks.list.delete")
            } label: {
                Image(systemName: "ellipsis")
                    .font(PSFont.glyph(.micro, weight: .semibold))
                    .foregroundStyle(Color.psTextPrimary)
                    .frame(width: 30, height: 30)
                    .background(Color.psFillControl, in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel(String(format: L("Actions for %@"), name))
        }
        .padding(.horizontal, PSSpacing.small)
        .padding(.vertical, PSSpacing.xSmall)
        .background(isSelected ? Color.psFillPressed : Color.psFillWell, in: RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
        .opacity(adjustment.isVisible ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { session.selectMask(adjustment.id) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MaskAccessibility.label(for: adjustment, language: psPrefersFrench ? .fr : .en))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction(named: Text(adjustment.isVisible ? L("Hide the mask") : L("Show the mask"))) {
            session.toggleMaskVisibility(adjustment.id)
        }
        .accessibilityAction(named: Text(L("Rename"))) {
            draft = adjustment.name ?? name
            renaming = adjustment
        }
        .accessibilityAction(named: Text(L("Duplicate"))) { session.duplicateMask(adjustment.id) }
        .accessibilityAction(named: Text(L("Delete"))) { session.deleteMask(adjustment.id) }
        .accessibilityIdentifier("masks.list.select")
        .animation(PSSpring.quick, value: isSelected)
    }

    /// The second line: the first dials it moves, « À mettre à jour », or what it is made of.
    private func summary(_ adjustment: LocalAdjustment) -> String {
        if session.isStale(adjustment) { return L("Made for an earlier version: update it") }
        let dials = MaskAccessibility.dialOrder.filter { abs(adjustment.adjustments[$0]) > 0.0005 }.prefix(2)
        if !dials.isEmpty {
            return dials.map { parameter in
                "\(AdjustPanel.name(parameter)) \(ValueRing.formatted(adjustment.adjustments[parameter]))"
            }.joined(separator: " · ")
        }
        let parts = adjustment.stack.components.count
        return parts == 1 ? L("1 part, no adjustment yet") : String(format: L("%d parts, no adjustment yet"), parts)
    }
}

/// A mask's 36-point thumbnail (the mask in gray, white selected), or a placeholder while it renders.
struct MaskThumbnail: View {
    let image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous)
        ZStack {
            Color.psFillControl
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "circle.rectangle.dashed")
                    .font(PSFont.glyph(.micro))
                    .foregroundStyle(Color.psTextTertiary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.psHairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
#endif
