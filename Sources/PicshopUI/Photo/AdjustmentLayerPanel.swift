#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// An adjustment layer's recipe (W3, D9; §7.7), by its kind: Lumière as generated rows of `adjust` (its own dials),
/// Courbes and Niveaux as their panels (the selected adjustment layer is their tone target), Teinte/Saturation and
/// Étalonnage as the colour controls, LUT its intensity, Look its strip and intensity. Every control writes to this
/// layer; a drag is one undo step on the `.adjustmentLayer` snapshot.
struct AdjustmentLayerPanel: View {
    let session: PhotoEditorSession
    let layer: Layer

    var body: some View {
        let kind = layer.recipeKind ?? .light
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            InspectorGroupHeader(title: LayerAddMenu.name(kind))
            switch kind {
            case .light:
                ParamInspectorRows(rows: session.lightRows, binding: session.layerRowBinding(layer.id))
            case .curves:
                CurvesPanel(session: session)
            case .levels:
                LevelsPanel(session: session)
            case .hsl, .colorGrade:
                ColorControls(mixer: layer.edits.resolvedColorMixer ?? .neutral, grade: layer.edits.resolvedColorGrade ?? .neutral,
                              onMixer: { session.setAdjustmentLayerColor(.colorMixer($0), label: "Colour Mixer", layerID: layer.id) },
                              onGrade: { session.setAdjustmentLayerColor(.colorGrade($0), label: "Colour Grading", layerID: layer.id) },
                              onBegin: { session.beginAdjustmentLayerDrag(layer.id, label: $0) },
                              onEnd: { session.endInteraction() })
            case .lut:
                lutRows
            case .look:
                AdjustmentLookStrip(session: session, layer: layer)
            }
        }
    }

    @ViewBuilder
    private var lutRows: some View {
        if let lut = layer.edits.resolvedLUT {
            InspectorSliderRow(label: lut.title, value: lut.intensity, range: 0...1, neutral: 1, controlID: "layers.adjustment.lut.intensity",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onBegin: { session.beginAdjustmentLayerDrag(layer.id, label: "LUT Intensity") },
                               onChange: { value in
                                   var reference = lut
                                   reference.intensity = value.clamped(to: 0...1)
                                   session.setAdjustmentLayerColor(.lut(reference), label: "LUT Intensity", layerID: layer.id)
                               },
                               onEnd: { session.endInteraction() })
        } else {
            Text(L("Import a LUT in Colour first."))
                .font(.footnote)
                .foregroundStyle(Color.psTextSecondary)
        }
    }
}

/// A « Look » adjustment layer: the looks as chips, and the chosen one's intensity.
struct AdjustmentLookStrip: View {
    let session: PhotoEditorSession
    let layer: Layer

    var body: some View {
        let current = layer.edits.resolvedLook
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(FilterPreset.gallery) { preset in
                        PanelChip(title: psPrefersFrench ? preset.frenchName : preset.englishName,
                                  isActive: (current?.preset ?? .original) == preset) {
                            session.setAdjustmentLayerLook(preset, intensity: current?.intensity ?? 1, layerID: layer.id)
                        }
                    }
                }
            }
            if let current {
                InspectorSliderRow(label: L("Intensity"), value: current.intensity, range: 0...1, neutral: 1,
                                   controlID: "layers.adjustment.look.intensity",
                                   format: { "\(Int(($0 * 100).rounded())) %" },
                                   onBegin: { session.beginAdjustmentLayerDrag(layer.id, label: "Look Intensity") },
                                   onChange: { session.setAdjustmentLayerLook(current.preset, intensity: $0, layerID: layer.id) },
                                   onEnd: { session.endInteraction() })
            }
        }
    }
}

extension PhotoEditorSession {
    /// A drag on an adjustment layer's control: one step on its snapshot; a content lock refuses it.
    func beginAdjustmentLayerDrag(_ layerID: UUID, label: String) {
        guard layerAllows(.content, on: layerID) else { return }
        beginInteraction(label: label, scope: .adjustmentLayer(layerID))
    }

    /// A colour op (mixer, grade, LUT) in an adjustment layer's recipe, on the dragged copy during a drag.
    func setAdjustmentLayerColor(_ kind: EditOperation.Kind, label: String, layerID: UUID) {
        guard document.layer(id: layerID)?.isAdjustment == true else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        interactiveEdit(label: label) { document in
            document.update(layerID: layerID) { $0.edits.setColor(kind) }
        }
    }

    /// A « Look » adjustment layer's look and intensity (its last look replaced, so a drag is one step).
    func setAdjustmentLayerLook(_ preset: FilterPreset, intensity: Double, layerID: UUID) {
        guard document.layer(id: layerID)?.isAdjustment == true else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        let amount = intensity.clamped(to: 0...1)
        interactiveEdit(label: "Look") { document in
            document.update(layerID: layerID) { layer in
                let index = layer.edits.operations.lastIndex { operation in
                    if case .look = operation.kind { return true }
                    return false
                }
                if let index {
                    let old = layer.edits.operations[index]
                    layer.edits.operations[index] = EditOperation(id: old.id, kind: .look(preset, intensity: amount), createdAt: old.createdAt, label: old.label)
                } else {
                    layer.edits.append(.look(preset, intensity: amount))
                }
            }
        }
    }
}
/// « Sur : Courbes 1 (j1) » / « Sur : Photo de fond » (W3, D9): what a tone or colour panel edits, in its header; the
/// menu lists the eligible layers (the image layers, and the adjustment layers of the panel's family), and picking one
/// selects it. Shown when there is more than one such layer.
struct ToneTargetChip: View {
    let session: PhotoEditorSession
    let op: OpID
    /// The PhotoPanelInventory id (« adjust.target », « curves.target »…).
    let controlID: String

    var body: some View {
        if session.showsToneTargetChip(for: op) {
            let current = session.toneTargetID(for: op)
            Menu {
                ForEach(session.toneTargetChoices(for: op), id: \.self) { id in
                    Button {
                        session.chooseToneTarget(id)
                    } label: {
                        if id == current {
                            Label(session.layerChoiceName(id), systemImage: "checkmark")
                        } else {
                            Text(session.layerChoiceName(id))
                        }
                    }
                }
            } label: {
                HStack(spacing: PSSpacing.xSmall) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.psTextSecondary)
                    Text(session.toneTargetLabel(for: op))
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.psTextTertiary)
                }
                .foregroundStyle(Color.psTextPrimary)
                .padding(.horizontal, PSSpacing.medium)
                .frame(minHeight: PSMetrics.chip)
                .background(Capsule().fill(Color.psFillControl))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(PSPressStyle(scale: 0.97))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(controlID)
        }
    }
}
#endif
