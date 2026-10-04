#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// A fill layer's panel (W3, D9; §7.7): a solid fill's colour well, or a gradient's stops (GradientEditor) and its
/// style, colours, angle, scale, reverse and dither as generated rows of `fillLayer`, the edit op with the layer bound
/// (never `addFillLayer`, which would add a layer per slider tick). A solid fill can become a gradient.
struct FillLayerPanel: View {
    let session: PhotoEditorSession
    let layer: Layer

    var body: some View {
        let rows = session.fillLayerRows(for: layer)
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            InspectorGroupHeader(title: layer.content.isGradientFill ? L("Gradient") : L("Solid colour"))
            ParamInspectorRows(rows: rows, binding: session.layerRowBinding(layer.id)) { row in
                guard case .custom("gradientStops") = row.control else { return nil }
                guard case .gradientFill(let gradient) = layer.content else { return AnyView(EmptyView()) }
                return AnyView(GradientEditor(session: session, layerID: layer.id, gradient: gradient)
                    .padding(.vertical, PSSpacing.xSmall))
            }
            if case .fill(let color) = layer.content, session.proLayersEnabled {
                PanelChip(title: L("Make it a gradient"), symbol: "square.bottomhalf.filled") {
                    let gradient = GradientFill.twoColor(color, PSColor(red: color.red, green: color.green, blue: color.blue, alpha: 0))
                    session.applyLayerEdit(.gradient(gradient), to: layer.id, label: "Fill Layer")
                }
                .accessibilityIdentifier("layers.fill.style")
            }
        }
    }
}

extension Layer.Content {
    /// A gradient fill (the panel's title).
    var isGradientFill: Bool {
        if case .gradientFill = self { return true }
        return false
    }
}
#endif
