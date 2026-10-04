#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// The transform readout (W3, §7.4): during a transform or a pick-drag, at the top of the canvas on a scrim (not
/// glass, so the six-glass rule holds): « L 120 % · H 80 % · 15° » or « X 412 · Y 96 px », and the snap when the
/// layer sits on a guide. Bound to `layerState.transform`, which the drag updates at ≤ 15 Hz.
struct TransformHUD: View {
    let session: PhotoEditorSession

    var body: some View {
        let readout = session.layerState.transform
        if readout.isVisible {
            let language: OpLanguage = psPrefersFrench ? .fr : .en
            let figures = readout.figures
            HStack(spacing: PSSpacing.small) {
                Text(verbatim: readout.showsPosition ? figures.positionLine(language: language) : figures.sizeLine(language: language))
                    .contentTransition(.numericText())
                if readout.snapDistance != nil {
                    Image(systemName: "magnet")
                        .foregroundStyle(Color.psValueAccent)
                        .accessibilityLabel(L("Snapped"))
                }
            }
            .font(.footnote.monospaced().weight(.medium))
            .foregroundStyle(Color.psTextPrimary)
            .padding(.horizontal, PSSpacing.medium)
            .padding(.vertical, PSSpacing.xSmall)
            .background(Capsule().fill(Color.psBadgeGround))
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}
#endif
