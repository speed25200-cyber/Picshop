#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// A layer's own mask (W3, D8; §7.6): Ajouter (Tout afficher, Tout masquer, Depuis la sélection, Depuis le sujet),
/// Peindre (the layer-mask brush: Peindre / Effacer, size, hardness, flow), Inverser, Contour progressif, Densité,
/// Étendre, Lié, Désactiver, Appliquer, Supprimer, and the stack's parts as W2's component rows. Every change is one
/// step through `applyLayerEdit`; a slider drag is one step on the `.layerMask` snapshot.
struct LayerMaskControls: View {
    let session: PhotoEditorSession
    let layerID: UUID

    var body: some View {
        let document = session.document
        let layer = document.layer(id: layerID)
        let stack = session.layerMaskStack(layerID)
        let painting = session.layerState.mode == .maskPaint && session.layerState.editingMaskOf == layerID
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            HStack(spacing: PSSpacing.small) {
                Label(L("Layer mask"), systemImage: "circle.rectangle.dashed")
                    .font(PSFontRole.groupHeader)
                    .foregroundStyle(Color.psTextSecondary)
                Spacer(minLength: PSSpacing.small)
                if stack == nil {
                    addMenu
                } else {
                    PanelChip(title: painting ? L("Done") : L("Paint"), symbol: painting ? "checkmark" : "paintbrush.pointed", isActive: painting) {
                        if painting {
                            session.endLayerMaskPaint()
                        } else {
                            session.beginLayerMaskPaint(layerID)
                        }
                    }
                    .accessibilityIdentifier("layers.mask.paint")
                }
            }
            if let stack, let layer {
                if painting {
                    LayerMaskBrushControls(session: session)
                }
                stackRows(stack)
                components(stack)
                HStack(spacing: PSSpacing.small) {
                    PanelChip(title: L("Invert"), symbol: "circle.lefthalf.filled") { session.invertLayerMask(layerID) }
                        .accessibilityIdentifier("layers.mask.invert")
                    PanelChip(title: layer.isMaskEnabled ? L("Disable") : L("Enable"), symbol: layer.isMaskEnabled ? "eye.slash" : "eye") {
                        session.setLayerMaskEnabled(!layer.isMaskEnabled, layerID: layerID)
                    }
                    .accessibilityIdentifier(layer.isMaskEnabled ? "layers.mask.disable" : "layers.mask.enable")
                }
                InspectorToggleRow(label: L("Linked to the layer"), isOn: layer.isMaskLinked, controlID: "layers.mask.link") { linked in
                    session.setLayerMaskLinked(linked, layerID: layerID)
                }
                HStack(spacing: PSSpacing.small) {
                    if layer.isImage {
                        PanelChip(title: L("Apply"), symbol: "checkmark.rectangle") { session.applyLayerMask(layerID) }
                            .accessibilityIdentifier("layers.mask.apply")
                    }
                    PanelChip(title: L("Delete mask"), symbol: "trash", tint: PSTheme.danger) { session.deleteLayerMask(layerID) }
                        .accessibilityIdentifier("layers.mask.delete")
                }
            }
        }
        .animation(PSSpring.quick, value: painting)
    }

    /// Ajouter ▸ Tout afficher · Tout masquer · Depuis la sélection · Depuis le sujet.
    private var addMenu: some View {
        Menu {
            Button {
                session.addLayerMask(.revealAll, to: layerID)
            } label: {
                Label(L("Reveal all"), systemImage: "square")
            }
            .accessibilityIdentifier("layers.mask.add.revealAll")
            Button {
                session.addLayerMask(.hideAll, to: layerID)
            } label: {
                Label(L("Hide all"), systemImage: "square.fill")
            }
            .accessibilityIdentifier("layers.mask.add.hideAll")
            Button {
                session.addLayerMask(.selection, to: layerID)
            } label: {
                Label(L("From the selection"), systemImage: "lasso")
            }
            .disabled(session.document.selection == nil)
            .accessibilityIdentifier("layers.mask.add.selection")
            Button {
                session.addLayerMask(.subject, to: layerID)
            } label: {
                Label(L("From the subject"), systemImage: "person.crop.rectangle")
            }
            .accessibilityIdentifier("layers.mask.add.subject")
        } label: {
            HStack(spacing: PSSpacing.xSmall) {
                Image(systemName: "plus")
                Text(L("Add a mask"))
            }
            .font(.subheadline)
            .foregroundStyle(Color.psTextPrimary)
            .padding(.horizontal, PSSpacing.medium)
            .frame(minHeight: PanelChipStyle.height)
            .background(Capsule().fill(Color.psFillControl))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(PSPressStyle(scale: 0.97))
    }

    /// Contour progressif, Densité, Étendre: one step per drag.
    private func stackRows(_ stack: MaskStack) -> some View {
        VStack(spacing: 0) {
            InspectorSliderRow(label: L("Feather"), value: stack.feather, range: 0...1, neutral: 0, controlID: "layers.mask.feather",
                               format: { "\(Int(($0 * 100).rounded()))" },
                               onBegin: { session.beginLayerMaskSlider(layerID) },
                               onChange: { session.setLayerMaskStack(feather: $0, layerID: layerID) },
                               onEnd: { session.endInteraction() })
            InspectorSliderRow(label: L("Density"), value: stack.density, range: 0...1, neutral: 1, controlID: "layers.mask.density",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onBegin: { session.beginLayerMaskSlider(layerID) },
                               onChange: { session.setLayerMaskStack(density: $0, layerID: layerID) },
                               onEnd: { session.endInteraction() })
            InspectorSliderRow(label: L("Expand / contract"), value: stack.expand, range: -1...1, neutral: 0, controlID: "layers.mask.expand",
                               format: { value in
                                   let percent = Int((value * 100).rounded())
                                   return percent > 0 ? "+\(percent)" : "\(percent)"
                               },
                               onBegin: { session.beginLayerMaskSlider(layerID) },
                               onChange: { session.setLayerMaskStack(expand: $0, layerID: layerID) },
                               onEnd: { session.endInteraction() })
        }
    }

    /// The stack's parts, read-only rows (what each adds, subtracts or intersects).
    private func components(_ stack: MaskStack) -> some View {
        VStack(alignment: .leading, spacing: PSSpacing.xSmall) {
            ForEach(Array(stack.components.enumerated()), id: \.element.id) { index, component in
                HStack(spacing: PSSpacing.small) {
                    Image(systemName: Self.modeSymbol(component.mode, first: index == 0))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.psTextSecondary)
                        .frame(width: 24)
                    Text(Self.kindTitle(component.kind))
                        .font(.footnote)
                        .foregroundStyle(Color.psTextPrimary)
                    Spacer(minLength: 0)
                    if component.isInverted {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.caption2)
                            .foregroundStyle(Color.psTextTertiary)
                    }
                }
                .frame(minHeight: 28)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, PSSpacing.xSmall)
    }

    static func modeSymbol(_ mode: CombineMode, first: Bool) -> String {
        switch mode {
        case .add: return first ? "circle" : "plus.circle"
        case .subtract: return "minus.circle"
        case .intersect: return "circle.circle"
        }
    }

    static func kindTitle(_ kind: MaskComponent.Kind) -> String {
        switch kind {
        case .brush: return L("Brush")
        case .raster(let raster):
            switch raster.origin {
            case .selection: return L("Selection")
            case .subject: return L("Subject")
            case .brush: return L("Brush")
            default: return L("Area")
            }
        case .linear: return L("Linear gradient")
        case .radial: return L("Radial gradient")
        case .colorRange: return L("Colour range")
        case .luminanceRange: return L("Luminance range")
        case .depthRange: return L("Depth range")
        case .unsupported: return L("Newer part")
        }
    }
}

/// The layer-mask brush (the accessory row's controls): « Peindre / Effacer » (X swaps them on a hardware keyboard),
/// size, hardness and flow, shared with Masques' brush.
struct LayerMaskBrushControls: View {
    let session: PhotoEditorSession

    var body: some View {
        let hides = session.layerState.maskPaintHides
        let brush = session.maskState.brush
        VStack(spacing: 0) {
            Picker(L("Brush"), selection: Binding(get: { hides }, set: { session.setLayerMaskHides($0) })) {
                Text(L("Paint")).tag(false)
                Text(L("Erase")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("layers.mask.paint.erase")
            .padding(.bottom, PSSpacing.xSmall)
            InspectorSliderRow(label: L("Size"), value: brush.size, range: 0.005...0.25, neutral: 0.04, controlID: "layers.mask.brush.size",
                               format: { "\(Int(($0 * 1000).rounded()))" },
                               onChange: { session.maskState.brush.size = $0 })
            InspectorSliderRow(label: L("Hardness"), value: 1 - brush.feather, range: 0...1, neutral: 0.5, controlID: "layers.mask.brush.hardness",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onChange: { session.maskState.brush.feather = 1 - $0 })
            InspectorSliderRow(label: L("Flow"), value: brush.flow, range: 0.05...1, neutral: 1, controlID: "layers.mask.brush.flow",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onChange: { session.maskState.brush.flow = $0 })
        }
        .background {
            // X on a hardware keyboard swaps Peindre and Effacer.
            Button(L("Swap paint and erase")) { session.swapLayerMaskPaint() }
                .keyboardShortcut("x", modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
/// The layer-mask brush's cursor on the canvas (Calques › Peindre): the brush's circle under the finger, its hardness
/// inside, a minus when it hides. Reads the stroke in progress only.
struct LayerMaskBrushCursor: View {
    let session: PhotoEditorSession
    let stroke: StrokeInProgress
    let frame: CGRect

    var body: some View {
        if session.paintsLayerMask, let cursor = stroke.cursor {
            let settings = session.maskState.brush
            let hides = session.layerState.maskPaintHides
            let radius = max(3, CGFloat(MaskHandleGeometry.brushCursorRadius(settings.size, in: MaskHandleGeometry.Placement(frame: PSRect(frame)))))
            Canvas { context, _ in
                let outer = Path(ellipseIn: CGRect(x: cursor.x - radius, y: cursor.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(outer, with: .color(Color.psScrim), lineWidth: 2.5)
                context.stroke(outer, with: .color(hides ? Color.psDanger : Color.psActionPrimary), lineWidth: 1.5)
                let inner = radius * CGFloat(settings.hardness)
                if inner > 2, inner < radius - 1 {
                    let circle = Path(ellipseIn: CGRect(x: cursor.x - inner, y: cursor.y - inner, width: inner * 2, height: inner * 2))
                    context.stroke(circle, with: .color(Color.psActionPrimary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if hides {
                    var minus = Path()
                    minus.move(to: CGPoint(x: cursor.x - 5, y: cursor.y))
                    minus.addLine(to: CGPoint(x: cursor.x + 5, y: cursor.y))
                    context.stroke(minus, with: .color(Color.psActionPrimary), lineWidth: 1.5)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
