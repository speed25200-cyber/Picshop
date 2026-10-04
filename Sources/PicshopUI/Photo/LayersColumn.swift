#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore

// The Layers column (W3, §7.1): a 52-point regular-glass capsule on the right edge of the canvas, inset 10 points,
// between the top bar and the inspector; 40-point thumbnails, top layer first, seven visible and scrolling beyond. It
// shows when the document has more than the photo or Calques is open, and steps aside while a brush, a crop or a
// transform drag is under the finger. One of the screen's six glass shapes.
//
// It reads `layerState.rows` (rebuilt only when a step lands) and its own drag state, so a transform or a dial drag on
// the canvas never re-evaluates it; each cell reads its thumbnail.

/// Places the column over the canvas between the bars (the studio's edges), when it shows.
struct LayersColumnHost: View {
    let session: PhotoEditorSession
    @Environment(\.studioEdges) private var edges

    var body: some View {
        let shows = session.showsLayersColumn
        GeometryReader { proxy in
            let insets = edges.insets(over: proxy.frame(in: .global))
            let room = proxy.size.height - insets.top - insets.bottom - 2 * LayersColumn.inset
            ZStack(alignment: .topTrailing) {
                if shows, room > LayersColumn.cell * 2 {
                    LayersColumn(session: session, maxHeight: room)
                        .padding(.top, insets.top + LayersColumn.inset)
                        .padding(.trailing, LayersColumn.inset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .animation(PSSpring.standard, value: shows)
    }
}

/// The column itself.
struct LayersColumn: View {
    let session: PhotoEditorSession
    let maxHeight: CGFloat

    static let width: CGFloat = 52
    static let cell: CGFloat = 40
    static let gap: CGFloat = 6
    static let inset: CGFloat = 10
    static let visibleCells = 7

    private var pitch: CGFloat { Self.cell + Self.gap }
    private var language: OpLanguage { psPrefersFrench ? .fr : .en }

    var body: some View {
        #if DEBUG
        let _ = LayerBodyCounter.noteColumn()
        #endif
        let state = session.layerState
        let all = state.rows
        let rows = all.filter { !$0.model.isCollapsedChild }
        let drag = state.columnDrag
        let height = min(maxHeight, CGFloat(min(rows.count, Self.visibleCells)) * pitch + Self.gap)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Self.gap) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    LayerColumnCell(session: session, row: row, count: Self.childCount(of: row, in: all),
                                    isSelecting: state.isSelecting, isChecked: state.multiSelection.contains(row.id),
                                    isLifted: drag?.id == row.id)
                        .offset(y: offset(for: index, row: row, rows: rows, drag: drag))
                        .zIndex(drag?.id == row.id ? 1 : 0)
                        .gesture(reorderGesture(row: row, index: index, rows: rows))
                }
            }
            .padding(.vertical, Self.gap)
            .frame(width: Self.width)
        }
        .scrollDisabled(rows.count <= Self.visibleCells || drag != nil)
        .frame(width: Self.width, height: height)
        .psGlass(shape: AnyShape(Capsule()))
        .animation(PSSpring.quick, value: drag?.slot)
        .animation(PSSpring.standard, value: rows.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Layers"))
    }

    /// A group's children (its cell shows the count); nil for other rows.
    static func childCount(of row: LayerRowState, in rows: [LayerRowState]) -> Int? {
        guard row.model.isGroup, let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        var count = 0
        for other in rows[(index + 1)...] {
            guard other.model.depth > 0 else { break }
            count += 1
        }
        return count
    }

    /// The lifted cell follows the finger; the cells between it and its slot make room (the quick spring).
    private func offset(for index: Int, row: LayerRowState, rows: [LayerRowState], drag: LayerColumnDrag?) -> CGFloat {
        guard let drag, let from = rows.firstIndex(where: { $0.id == drag.id }) else { return 0 }
        if row.id == drag.id { return drag.offset }
        let target = Self.targetIndex(from: from, offset: drag.offset, pitch: pitch, count: rows.count)
        if target > from, index > from, index <= target { return -pitch }
        if target < from, index >= target, index < from { return pitch }
        return 0
    }

    /// The row index the lifted cell hovers.
    static func targetIndex(from: Int, offset: CGFloat, pitch: CGFloat, count: Int) -> Int {
        let moved = Int((offset / max(1, pitch)).rounded())
        return min(max(0, from + moved), max(0, count - 1))
    }

    /// Long press (0.3 s) lifts the cell (scale 1.06, a shadow, a light impact); the drag reorders live; the drop
    /// commits through `LayerReorder.drop` (one step), a refused slot shakes it back.
    private func reorderGesture(row: LayerRowState, index: Int, rows: [LayerRowState]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard !row.isBase, case .second(true, let drag) = value else { return }
                let state = session.layerState
                if state.columnDrag == nil {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    state.columnDrag = LayerColumnDrag(id: row.id, slot: index, offset: 0)
                }
                let offset = drag?.translation.height ?? 0
                let target = Self.targetIndex(from: index, offset: offset, pitch: pitch, count: rows.count)
                let slot = target > index ? target + 1 : target
                state.columnDrag = LayerColumnDrag(id: row.id, slot: slot, offset: offset)
            }
            .onEnded { _ in
                let state = session.layerState
                guard let drag = state.columnDrag, drag.id == row.id else { return }
                let moved = drag.slot != index && drag.slot != index + 1
                withAnimation(PSSpring.quick) { state.columnDrag = nil }
                guard moved else { return }
                if !session.moveLayer(row.id, toSlot: drag.slot) {
                    session.layerState.columnShake[row.id, default: 0] += 1
                }
            }
    }
}

/// One 40-point cell: the selected layer has a 2-point white ring; hidden ones are dimmed with an eye badge; a clipped
/// one has its ↳ notch, a masked one its dot, a locked one its padlock; in « Sélectionner » a check circle.
struct LayerColumnCell: View {
    let session: PhotoEditorSession
    let row: LayerRowState
    let count: Int?
    let isSelecting: Bool
    let isChecked: Bool
    let isLifted: Bool

    private var language: OpLanguage { psPrefersFrench ? .fr : .en }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous)
        LayerThumbnail(row: row, store: session.layerState.thumbnails, side: LayersColumn.cell, count: count)
            .overlay {
                if row.isSelected {
                    shape.strokeBorder(Color.psActionPrimary, lineWidth: 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !row.isVisible {
                    badge("eye.slash")
                }
            }
            .overlay(alignment: .topTrailing) {
                if !row.lock.isEmpty {
                    badge("lock.fill")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if row.hasMask {
                    Circle()
                        .fill(row.isMaskEnabled ? Color.psTextPrimary : Color.psTextDisabled)
                        .overlay(Circle().strokeBorder(Color.psBadgeGround, lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .offset(x: -2, y: 2)
                }
            }
            .overlay(alignment: .leading) {
                if row.model.isClipped {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                        .foregroundStyle(row.isClipIgnored ? Color.psTextDisabled : Color.psTextPrimary)
                        .frame(width: 6)
                        .offset(x: -5)
                }
            }
            .overlay {
                if isSelecting, !row.isBase {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.psActionPrimary)
                        .shadow(color: Color.psScrim, radius: 2)
                }
            }
            .padding(.leading, row.model.depth > 0 ? 4 : 0)
            .scaleEffect(isLifted ? 1.06 : 1)
            .shadow(color: isLifted ? Color.psScrim : .clear, radius: isLifted ? 8 : 0, y: isLifted ? 4 : 0)
            .modifier(ShakeEffect(shakes: CGFloat(session.layerState.columnShake[row.id] ?? 0)))
            .animation(.linear(duration: 0.3), value: session.layerState.columnShake[row.id] ?? 0)
            .animation(PSSpring.quick, value: isLifted)
            .frame(width: LayersColumn.width, height: LayersColumn.cell)
            .contentShape(Rectangle())
            .onTapGesture { session.tapLayer(row.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { session.openLayersInspector(selecting: row.id) })
            .simultaneousGesture(swipeToHide)
            .gesture(TwoFingerTap { session.toggleMultiSelection(row.id) })
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
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .imageScale(.small)
            .foregroundStyle(Color.psTextPrimary)
            .padding(2)
            .background(Circle().fill(Color.psBadgeGround))
            .offset(x: 3, y: symbol == "lock.fill" ? -3 : 3)
    }

    /// Swipe left on a cell: shown ↔ hidden.
    private var swipeToHide: some Gesture {
        DragGesture(minimumDistance: 14)
            .onEnded { value in
                guard value.translation.width < -24, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                session.toggleVisibility(row.id)
            }
    }
}

/// A two-finger tap (UIKit's recogniser): toggles a cell in the multi-selection outside « Sélectionner ».
struct TwoFingerTap: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.numberOfTouchesRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    /// Recognises alongside the cell's taps and its long-press drag.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        Haptics.tick()
        action()
    }
}

#if DEBUG
/// Body evaluations of the column and the inspector, for the `freeTransform` scenario's re-render budget (§7.2:
/// ≤ 3 each over a 120-frame drag; L5's ios-build step reads the logged counts).
@MainActor
enum LayerBodyCounter {
    static var column = 0
    static var inspector = 0

    static func noteColumn() -> Bool {
        column += 1
        return true
    }

    static func noteInspector() -> Bool {
        inspector += 1
        return true
    }
}

extension LayersColumn {
    @MainActor static var bodyCount: Int { LayerBodyCounter.column }
    @MainActor static func resetBodyCount() { LayerBodyCounter.column = 0 }
}
#endif
#endif
