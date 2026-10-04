#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore

// One layer as the Layers inspector lists it (W3, §7.6), and the thumbnails the column's cells share. Rows draw from
// `LayerRowState` (Equatable, rebuilt only when a step lands) and the thumbnail store, never from the document, so a
// drag on the canvas re-evaluates none of them.

/// The checkerboard behind a thumbnail's transparent pixels: two of the palette's well greys, 4-point squares.
struct LayerCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.psFillWell))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : square
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: square, height: square)), with: .color(.psFillControl))
                    x += square * 2
                }
                y += square
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// A layer's thumbnail: the layer rendered alone on the canvas (88 px, off the main actor, once its key settles), a
/// solid fill's swatch, or an adjustment layer's kind glyph over its mask. A group and a table bundle carry their
/// glyph and count.
struct LayerThumbnail: View {
    let row: LayerRowState
    let store: LayerThumbnailStore
    let side: CGFloat
    /// Members of a group or a table bundle (the stacked-cards or grid glyph shows the count).
    var count: Int? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous)
        ZStack {
            LayerCheckerboard()
            switch row.look {
            case .rendered:
                if let image = store.images[row.id] {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                } else {
                    Image(systemName: row.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.psTextTertiary)
                }
            case .swatch(let color):
                Color(psColor: color)
            case .glyph:
                ZStack {
                    if let mask = store.masks[row.id] {
                        Image(uiImage: mask).resizable().scaledToFill().opacity(0.35)
                    }
                    Image(systemName: row.symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.psTextPrimary)
                }
            }
            if row.model.isGroup || row.model.bundleCount != nil {
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Image(systemName: row.model.isGroup ? "square.stack.fill" : row.symbol)
                        if let count = count ?? row.model.bundleCount {
                            Text(verbatim: "\(count)").monospacedDigit()
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.psTextPrimary)
                    .padding(.horizontal, PSSpacing.xSmall)
                    .background(Capsule().fill(Color.psBadgeGround))
                    .padding(2)
                }
            }
        }
        .frame(width: side, height: side)
        .background(Color.psElevated)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.psHairline, lineWidth: 1))
        .opacity(row.isVisible ? 1 : 0.4)
        .accessibilityHidden(true)
    }
}

/// The layer mask's thumbnail (content space, white shows): dimmed when the mask is off, with its link glyph.
struct LayerMaskThumbnail: View {
    let row: LayerRowState
    let store: LayerThumbnailStore
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous)
        ZStack {
            Color.psElevated
            if let image = store.masks[row.id] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.rectangle.dashed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.psTextTertiary)
            }
            if !row.isMaskEnabled {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.psDanger)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.psStrokeStrong, lineWidth: 1))
        .opacity(row.isMaskEnabled ? 1 : 0.5)
    }
}

/// How a row's grip drag goes (the inspector's reorder, the same `LayerReorder` maths as the column).
enum LayerReorderPhase {
    case began
    case moved(CGFloat)
    case ended(CGFloat)
    case cancelled
}

/// One 56-point row of the Layers inspector: a 44-point thumbnail, the name and its ref, the blend chip and the
/// opacity, the mask's 28-point thumbnail, the eye and the lock. A group has its chevron, a child is indented, a
/// clipped layer carries ↳. Swipe left to delete; a long press on the grip reorders.
struct LayerRow: View {
    let session: PhotoEditorSession
    let row: LayerRowState
    /// A group's children (nil for other rows).
    var childCount: Int? = nil
    let isSelecting: Bool
    let isChecked: Bool
    /// The row is lifted by its grip.
    var isLifted = false
    /// Bumped by the inspector when a drop is refused: the row shakes back.
    var shakeCount = 0
    var onReorder: (LayerReorderPhase) -> Void = { _ in }

    @State private var swipe: CGFloat = 0
    @State private var revealsDelete = false

    private static let deleteWidth: CGFloat = 88
    private var language: OpLanguage { psPrefersFrench ? .fr : .en }

    var body: some View {
        ZStack(alignment: .trailing) {
            if revealsDelete || swipe < 0 {
                deleteButton
            }
            content
                .offset(x: swipe)
                .simultaneousGesture(swipeGesture, including: row.isBase || isSelecting ? .subviews : .all)
        }
        .clipShape(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
        .scaleEffect(isLifted ? 1.03 : 1)
        .shadow(color: isLifted ? Color.psScrim : .clear, radius: isLifted ? 10 : 0, y: isLifted ? 4 : 0)
        .animation(PSSpring.quick, value: isLifted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
        .accessibilityAction { session.tapLayer(row.id) }
        .accessibilityAction(named: LayerAccessibility.visibilityAction(isVisible: row.isVisible, language: language)) {
            session.toggleVisibility(row.id)
        }
        .accessibilityAction(named: LayerAccessibility.moveUpAction(language: language)) { session.moveLayerStep(row.id, up: true) }
        .accessibilityAction(named: LayerAccessibility.moveDownAction(language: language)) { session.moveLayerStep(row.id, up: false) }
        .accessibilityAction(named: row.lock.isEmpty ? L("Lock") : L("Unlock")) { session.toggleLock(row.id) }
        .accessibilityAction(named: L("Delete")) { session.requestDeleteLayers([row.id]) }
    }

    private var content: some View {
        HStack(spacing: PSSpacing.small) {
            if isSelecting, !row.isBase {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.psActionPrimary : Color.psTextTertiary)
                    .transition(.scale.combined(with: .opacity))
            }
            if row.model.depth > 0 {
                Color.clear.frame(width: PSSpacing.large)
            }
            if row.model.isClipped {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.isClipIgnored ? Color.psTextDisabled : Color.psTextSecondary)
                    .accessibilityHidden(true)
            }
            if row.model.isGroup {
                Button {
                    session.setCollapsed(!row.isCollapsed, groupID: row.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.psTextSecondary)
                        .rotationEffect(.degrees(row.isCollapsed ? 0 : 90))
                        .frame(width: 24, height: PSMetrics.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isCollapsed ? L("Expand") : L("Collapse"))
            }
            LayerThumbnail(row: row, store: session.layerState.thumbnails, side: 44, count: childCount)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PSSpacing.xSmall) {
                    Text(verbatim: row.name)
                        .font(.subheadline.weight(row.isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.psTextPrimary)
                        .lineLimit(1)
                    if let ref = row.ref {
                        Text(verbatim: ref)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.psTextTertiary)
                    }
                }
                HStack(spacing: PSSpacing.xSmall) {
                    if !row.blendLabel.isEmpty {
                        Text(verbatim: row.blendLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.psValueAccent)
                            .padding(.horizontal, PSSpacing.xSmall)
                            .background(Capsule().fill(Color.psValueAccentSoft))
                    }
                    if row.opacityPercent < 100 || row.fillPercent < 100 {
                        Text(verbatim: "\(row.opacityPercent) %")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.psTextSecondary)
                        if row.fillPercent < 100 {
                            Text(verbatim: "· \(L("Fill")) \(row.fillPercent) %")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.psTextTertiary)
                        }
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: PSSpacing.xSmall)
            if row.hasMask {
                LayerMaskThumbnail(row: row, store: session.layerState.thumbnails, side: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tick()
                        session.layerState.maskControlsOf = session.layerState.maskControlsOf == row.id ? nil : row.id
                        if session.document.selectedLayerID != row.id { session.selectLayer(row.id) }
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        session.setLayerMaskEnabled(!row.isMaskEnabled, layerID: row.id)
                    }
            }
            iconButton(row.isVisible ? "eye" : "eye.slash", active: row.isVisible) { session.toggleVisibility(row.id) }
            iconButton(row.lock.isEmpty ? "lock.open" : "lock.fill", active: !row.lock.isEmpty) { session.toggleLock(row.id) }
            if !row.isBase, !isSelecting {
                Image(systemName: "line.3.horizontal")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.psTextTertiary)
                    .frame(width: 28, height: PSMetrics.control)
                    .contentShape(Rectangle())
                    .gesture(gripGesture)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, PSSpacing.small)
        .frame(minHeight: 56)
        .background(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous)
            .fill(row.isSelected ? Color.psFillPressed : Color.psFillWell))
        .overlay {
            if row.isSelected {
                RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous).strokeBorder(Color.psStrokeStrong, lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if revealsDelete {
                closeSwipe()
                return
            }
            session.tapLayer(row.id)
        }
        .modifier(ShakeEffect(shakes: CGFloat(shakeCount)))
        .animation(.linear(duration: 0.3), value: shakeCount)
        .animation(PSSpring.quick, value: row.isSelected)
        .animation(PSSpring.quick, value: isSelecting)
    }

    private func iconButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.medium))
                .foregroundStyle(active ? Color.psTextPrimary : Color.psTextTertiary)
                .frame(width: 32, height: PSMetrics.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .accessibilityHidden(true)
    }

    private var deleteButton: some View {
        Button {
            closeSwipe()
            session.requestDeleteLayers([row.id])
        } label: {
            Label(L("Delete"), systemImage: "trash")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.psTextPrimary)
                .frame(width: Self.deleteWidth)
                .frame(maxHeight: .infinity)
                .background(Color.psDanger)
        }
        .buttonStyle(.plain)
    }

    /// Swipe left: the delete button slides out; a long swipe deletes at once.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = revealsDelete ? -Self.deleteWidth : 0
                swipe = min(0, base + value.translation.width)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(PSSpring.quick) { swipe = revealsDelete ? -Self.deleteWidth : 0 }
                    return
                }
                let travelled = (revealsDelete ? -Self.deleteWidth : 0) + value.predictedEndTranslation.width
                if travelled < -Self.deleteWidth * 2.5 {
                    closeSwipe()
                    session.requestDeleteLayers([row.id])
                } else if travelled < -Self.deleteWidth / 2 {
                    Haptics.tick()
                    withAnimation(PSSpring.standard) {
                        swipe = -Self.deleteWidth
                        revealsDelete = true
                    }
                } else {
                    closeSwipe()
                }
            }
    }

    private func closeSwipe() {
        withAnimation(PSSpring.standard) {
            swipe = 0
            revealsDelete = false
        }
    }

    /// Long press on the grip lifts the row (light impact), then the drag reorders it.
    private var gripGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isLifted { onReorder(.began) }
                if let drag { onReorder(.moved(drag.translation.height)) }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    onReorder(.ended(drag.translation.height))
                } else {
                    onReorder(.cancelled)
                }
            }
    }
}

/// The shake of a refused drop (three horizontal swings).
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(shakes * .pi * 3), y: 0))
    }
}
#endif
