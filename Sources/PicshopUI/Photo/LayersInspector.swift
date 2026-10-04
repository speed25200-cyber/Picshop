#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore

// Calques' panel (W3, §7.6): the rows (LayerRow) top first, the multi-selection bar in « Sélectionner » mode, then the
// selected layer's properties as generated rows (D18, behind `paramInspector`; W1's LayerBlendControls otherwise), its
// fill or adjustment panel, its transform rows and its mask. In transform mode the panel is the transform's: the mode
// chips, the numeric rows bound to the readout, Réinitialiser, Ajuster, Remplir, Retourner.
//
// The body reads the rows (rebuilt when a step lands), the document and the layer modes, never per-frame state: the
// transform rows read the readout in their own leaves, the thumbnails are read by each row.

struct LayersInspector: View {
    let session: PhotoEditorSession
    @Environment(\.studioInspector) private var inspector
    @State private var rowDrag: RowDrag?
    @State private var shakes: [UUID: Int] = [:]
    @State private var renaming: UUID?
    @State private var draft = ""

    private struct RowDrag: Equatable {
        var id: UUID
        var from: Int
        var offset: CGFloat
    }

    private static let rowPitch: CGFloat = 56 + PSSpacing.xSmall

    var body: some View {
        #if DEBUG
        let _ = LayerBodyCounter.noteInspector()
        #endif
        let state = session.layerState
        VStack(alignment: .leading, spacing: PSSpacing.medium) {
            if let working = state.workingTitle {
                HStack(spacing: PSSpacing.small) {
                    ProgressView()
                    Text(working)
                        .font(.subheadline)
                        .foregroundStyle(Color.psTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: PSMetrics.control, alignment: .leading)
                .transition(.opacity)
            }
            if state.mode == .transform, let id = state.transformTarget {
                LayerTransformSection(session: session, layerID: id)
            } else {
                rowsList(state)
                if state.isSelecting {
                    LayerSelectionBar(session: session)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let selected = session.document.selectedLayer {
                    properties(selected)
                        .id(selected.id)
                }
            }
        }
        .animation(PSSpring.standard, value: state.isSelecting)
        .animation(PSSpring.standard, value: state.mode)
        .onAppear(perform: applyDetentRequest)
        .onChange(of: state.inspectorDetentRequest) { _, _ in applyDetentRequest() }
        .alert(L("Rename layer"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $draft)
            Button(L("Rename")) {
                if let id = renaming { session.renameLayer(id, to: draft) }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }

    // MARK: Rows

    private func rowsList(_ state: PhotoLayerState) -> some View {
        let all = state.rows
        let rows = all.filter { !$0.model.isCollapsedChild }
        return VStack(spacing: PSSpacing.xSmall) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                LayerRow(session: session, row: row, childCount: LayersColumn.childCount(of: row, in: all),
                         isSelecting: state.isSelecting, isChecked: state.multiSelection.contains(row.id),
                         isLifted: rowDrag?.id == row.id, shakeCount: shakes[row.id] ?? 0) { phase in
                    reorder(phase, row: row, index: index, count: rows.count)
                }
                .offset(y: offset(for: index, row: row, count: rows.count))
                .zIndex(rowDrag?.id == row.id ? 1 : 0)
            }
        }
        .animation(PSSpring.quick, value: rowDrag)
        .animation(PSSpring.standard, value: rows.map(\.id))
        .accessibilityIdentifier("layers.row.select")
    }

    private func offset(for index: Int, row: LayerRowState, count: Int) -> CGFloat {
        guard let drag = rowDrag else { return 0 }
        if row.id == drag.id { return drag.offset }
        let target = LayersColumn.targetIndex(from: drag.from, offset: drag.offset, pitch: Self.rowPitch, count: count)
        if target > drag.from, index > drag.from, index <= target { return -Self.rowPitch }
        if target < drag.from, index >= target, index < drag.from { return Self.rowPitch }
        return 0
    }

    private func reorder(_ phase: LayerReorderPhase, row: LayerRowState, index: Int, count: Int) {
        switch phase {
        case .began:
            guard rowDrag == nil, !row.isBase else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            rowDrag = RowDrag(id: row.id, from: index, offset: 0)
        case .moved(let offset):
            guard var drag = rowDrag, drag.id == row.id else { return }
            drag.offset = offset
            rowDrag = drag
        case .ended(let offset):
            guard let drag = rowDrag, drag.id == row.id else { return }
            rowDrag = nil
            let target = LayersColumn.targetIndex(from: drag.from, offset: offset, pitch: Self.rowPitch, count: count)
            guard target != drag.from else { return }
            let slot = target > drag.from ? target + 1 : target
            if !session.moveLayer(row.id, toSlot: slot) { shakes[row.id, default: 0] += 1 }
        case .cancelled:
            rowDrag = nil
        }
    }

    // MARK: Properties

    @ViewBuilder
    private func properties(_ layer: Layer) -> some View {
        let isBase = layer.id == session.document.baseLayerID
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            HStack(spacing: PSSpacing.small) {
                InspectorGroupHeader(title: L("Properties"))
                if !isBase {
                    Button {
                        draft = layer.name
                        renaming = layer.id
                    } label: {
                        Label(L("Rename"), systemImage: "pencil")
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.psTextSecondary)
                            .frame(width: PSMetrics.control, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("layers.props.name")
                }
            }
            if FeatureFlags.isOn(.paramInspector) {
                ParamInspectorRows(rows: session.layerPropertyRows(for: layer), binding: session.layerRowBinding(layer.id)) { row in
                    guard row.op.raw == "layerBlend" else { return nil }
                    return AnyView(BlendModePicker(session: session, layerID: layer.id, mode: layer.blendMode))
                }
            } else if !isBase {
                LayerBlendControls(session: session, layer: layer)
            }
            switch layer.content {
            case .fill, .gradientFill:
                FillLayerPanel(session: session, layer: layer)
            case .adjustment:
                AdjustmentLayerPanel(session: session, layer: layer)
            case .image, .text, .shape:
                if !isBase, FeatureFlags.isOn(.freeTransform) {
                    transformEntry(layer)
                }
            case .group, .unsupported:
                EmptyView()
            }
            if session.proLayersEnabled {
                LayerMaskControls(session: session, layerID: layer.id)
                    .padding(.top, PSSpacing.xSmall)
            }
        }
    }

    /// « Transformer » and the transform rows of an image, text or shape layer.
    private func transformEntry(_ layer: Layer) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            HStack(spacing: PSSpacing.small) {
                InspectorGroupHeader(title: L("Transform"))
                PanelChip(title: L("Transform"), symbol: "skew") { session.beginTransformMode(layer.id) }
                    .accessibilityIdentifier("layers.more.transform")
            }
            ParamInspectorRows(rows: session.transformRows, binding: session.layerRowBinding(layer.id))
        }
    }

    // MARK: Detent

    private func applyDetentRequest() {
        guard let request = session.layerState.inspectorDetentRequest else { return }
        session.layerState.inspectorDetentRequest = nil
        guard let inspector, inspector.detent != request else { return }
        withAnimation(PSSpring.standard) { inspector.detent = request }
    }
}

/// Transform mode's section: the mode chips (Libre, Proportionnel, Incliner, Déformer, Perspective), the numeric rows
/// bound to the readout, and Réinitialiser, Ajuster, Remplir, Retourner.
struct LayerTransformSection: View {
    let session: PhotoEditorSession
    let layerID: UUID

    var body: some View {
        let current = session.layerState.transformMode
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(TransformMode.allCases, id: \.self) { mode in
                        PanelChip(title: Self.title(mode), symbol: Self.symbol(mode), isActive: current == mode) {
                            session.setTransformMode(mode)
                        }
                        .accessibilityIdentifier("layers.transform.mode.\(mode.rawValue)")
                    }
                }
            }
            Text(Self.hint(current))
                .font(.footnote)
                .foregroundStyle(Color.psTextTertiary)
            ParamInspectorRows(rows: session.transformRows, binding: session.layerRowBinding(layerID))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise") { session.resetTransform(layerID) }
                        .accessibilityIdentifier("layers.transform.reset")
                    PanelChip(title: L("Fit"), symbol: "arrow.down.right.and.arrow.up.left") { session.fitLayer(layerID, fill: false) }
                        .accessibilityIdentifier("layers.transform.fit")
                    PanelChip(title: L("Fill the canvas"), symbol: "arrow.up.left.and.arrow.down.right") { session.fitLayer(layerID, fill: true) }
                        .accessibilityIdentifier("layers.transform.fill")
                    PanelChip(title: L("Flip horizontally"), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        session.flipLayer(layerID, horizontal: true)
                    }
                    .accessibilityIdentifier("layers.transform.flip.horizontal")
                    PanelChip(title: L("Flip vertically"), symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        session.flipLayer(layerID, horizontal: false)
                    }
                    .accessibilityIdentifier("layers.transform.flip.vertical")
                }
            }
            InspectorToggleRow(label: L("Smart guides"), isOn: session.layerState.guidesEnabled, controlID: "layers.guides.show") { on in
                session.layerState.guidesEnabled = on
                session.layerState.snapTargets = on ? session.snapTargets(excluding: layerID) : SnapTargets()
            }
        }
    }

    static func title(_ mode: TransformMode) -> String {
        switch mode {
        case .free: return L("Free")
        case .uniform: return L("Proportional")
        case .skew: return L("Skew")
        case .distort: return L("Distort")
        case .perspective: return L("Perspective")
        }
    }

    static func symbol(_ mode: TransformMode) -> String {
        switch mode {
        case .free: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .uniform: return "lock.rectangle"
        case .skew: return "skew"
        case .distort: return "perspective"
        case .perspective: return "rectangle.portrait.arrowtriangle.2.outward"
        }
    }

    static func hint(_ mode: TransformMode) -> String {
        switch mode {
        case .free: return L("Drag the corners to resize, the knob to turn, the inside to move.")
        case .uniform: return L("The corners keep the proportions.")
        case .skew: return L("Drag an edge to slant the layer.")
        case .distort: return L("Drag each corner freely.")
        case .perspective: return L("Drag a corner: its neighbour follows, as in perspective.")
        }
    }
}

/// The Calques header's accessory: « Sélectionner », ＋ and ⋯; in transform mode « Annuler » (OK is the panel's Done).
struct LayersInspectorAccessory: View {
    let session: PhotoEditorSession

    var body: some View {
        let state = session.layerState
        HStack(spacing: PSSpacing.xSmall) {
            switch state.mode {
            case .transform:
                PanelChip(title: L("Cancel")) { session.cancelTransformMode() }
            case .maskPaint:
                EmptyView()
            case .select:
                PanelChip(title: state.isSelecting ? L("Done") : L("Select"), isActive: state.isSelecting) {
                    session.setSelecting(!state.isSelecting)
                }
                .accessibilityIdentifier("layers.select.many")
                if !state.isSelecting {
                    LayerAddMenu(session: session)
                    LayerMoreMenu(session: session)
                }
            }
        }
    }
}

#if DEBUG
extension LayersInspector {
    @MainActor static var bodyCount: Int { LayerBodyCounter.inspector }
    @MainActor static func resetBodyCount() { LayerBodyCounter.inspector = 0 }
}
#endif
#endif
