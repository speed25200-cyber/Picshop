#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// The selected layer's opacity dial and blend menu: W3's Layers inspector shows them when its generated rows are off
/// (`paramInspector`). The dial owns the dragged value (one undo step per drag, through `applyLayerEdit`, so locks
/// refuse it); the menu lists the 27 blend modes in Photoshop's sections (Normal, Darken, Lighten, Contrast,
/// Inversion, Component), or the 12 of before with pro tone off.
struct LayerBlendControls: View {
    let session: PhotoEditorSession
    let layer: Layer
    @State private var opacity: Double = 1
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 10) {
            DialSlider(value: $opacity, range: 0...1, neutral: 1, label: L("Opacity"), format: { "\(Int(($0 * 100).rounded()))%" }) { editing in
                isDragging = editing
                // W3: through the layer path (locks, the `.layerPlacement` snapshot).
                if editing { session.beginLayerPropertyDrag(layer.id, label: "Opacity") } else { session.endInteraction() }
            }
            .onChange(of: opacity) { _, value in
                // Every frame of a drag goes to the session (back to the start too); a tap only when it changes.
                if isDragging || abs(value - layer.opacity) > 0.0005 { session.setLayerOpacity(value, layerID: layer.id) }
            }
            BlendModeMenu(selection: layer.blendMode) { session.setLayerBlend($0, layerID: layer.id) }
        }
        .onAppear { opacity = layer.opacity }
        .onChange(of: layer.id) { _, _ in opacity = layer.opacity }
        .onChange(of: layer.opacity) { _, value in
            // Undo, a voice edit: follow the document unless a drag is under way.
            if !isDragging, abs(value - opacity) > 0.0005 { opacity = value }
        }
    }
}

/// The blend mode as a chip that opens the menu of modes, a check on the current one.
struct BlendModeMenu: View {
    let selection: PicshopCore.BlendMode
    let onSelect: (PicshopCore.BlendMode) -> Void

    static func name(_ mode: PicshopCore.BlendMode) -> String {
        psPrefersFrench ? mode.frenchName : mode.displayName
    }

    var body: some View {
        Menu {
            if FeatureFlags.isOn(.proTone) {
                ForEach(PicshopCore.BlendMode.Group.allCases) { group in
                    Section {
                        ForEach(group.modes) { mode in item(mode) }
                    }
                }
            } else {
                ForEach(PhotoEditorSession.offeredBlendModes) { mode in item(mode) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.2.layers.3d").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.psTextSecondary)
                Text(Self.name(selection)).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.psTextTertiary)
            }
            .font(.subheadline)
            .foregroundStyle(selection == .normal ? Color.psTextPrimary : Color.psValueAccent)
            .padding(.horizontal, 12)
            .frame(minHeight: PanelChipStyle.height)
            .background(Capsule().fill(PanelChipStyle.fill))
            .contentShape(Capsule())
        }
        .fixedSize()
        .accessibilityLabel(L("Blend"))
        .accessibilityValue(Self.name(selection))
    }

    @ViewBuilder
    private func item(_ mode: PicshopCore.BlendMode) -> some View {
        Button {
            onSelect(mode)
        } label: {
            if mode == selection {
                Label(Self.name(mode), systemImage: "checkmark")
            } else {
                Text(Self.name(mode))
            }
        }
    }
}
#endif
