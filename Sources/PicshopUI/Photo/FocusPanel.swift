#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Focus after the shot: tap the picture where it should be sharp, set the
/// aperture like a lens (f/1.4 … f/16).
struct FocusPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var aperture: Double = 0.55

    /// Aperture control value (0…1) to an f-number, wide open at 1.
    static func fNumber(_ value: Double) -> String {
        let stops: [Double] = [16, 11, 8, 5.6, 4, 2.8, 2, 1.4]
        let index = Int((value.clamped(to: 0...1) * Double(stops.count - 1)).rounded())
        let f = stops[index]
        return f == f.rounded() ? "f/\(Int(f))" : String(format: "f/%.1f", f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: session.hasDepthMap ? "cube.transparent" : "person.crop.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .psIntelligenceForeground()
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.focusPoint == nil ? L("Tap where the picture should be sharp.") : L("Tap again to move the focus."))
                        .font(.subheadline.weight(.medium)).foregroundStyle(PSTheme.textPrimary)
                    Text(session.hasDepthMap ? L("Using the depth captured by the camera.") : L("Estimated from the subject."))
                        .font(.footnote).foregroundStyle(PSTheme.textTertiary)
                }
                Spacer()
                if session.focusPoint != nil {
                    PanelChip(title: L("Remove"), symbol: "xmark") { session.removeFocusBlur() }
                }
            }
            DialSlider(value: $aperture, range: 0.05...1, neutral: 0.55, label: L("Aperture"), format: { Self.fNumber($0) }, onEditingChanged: { editing in
                if editing { session.beginApertureInteraction() } else { session.endApertureInteraction() }
            })
            .disabled(session.focusPoint == nil)
            .opacity(session.focusPoint == nil ? 0.4 : 1)
        }
        .onAppear { aperture = session.focusAperture }
        .onChange(of: aperture) { _, value in
            if session.focusPoint != nil, abs(value - session.focusAperture) > 0.001 { session.setAperture(value) }
        }
    }
}
#endif
