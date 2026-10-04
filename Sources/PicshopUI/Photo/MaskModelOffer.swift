#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// The download card for a mask model (W2): « Sélection d'objets IA · 80 Mo · Wi‑Fi » (SAM 2.1 tiny) or
/// « Profondeur IA · 50 Mo · Wi‑Fi » (Depth Anything V2 Small). Télécharger starts the install (Wi‑Fi, verified,
/// compiled on the iPhone); the progress comes from `app.modelStates`. Meanwhile the Vision fallback runs, and its
/// result says so. Shown on the canvas whenever a tool or a voice command needs the model.
struct MaskModelOffer: View {
    let session: PhotoEditorSession
    let modelID: String

    private var isDepth: Bool { modelID == MaskModelCatalog.depthSmall.id }

    private var title: String {
        isDepth ? L("AI depth") : L("AI object selection")
    }

    /// Megabytes, from the pinned files.
    private var megabytes: Int {
        let set = isDepth ? MaskModelCatalog.depthSmall : MaskModelCatalog.samTiny
        return Int((Double(set.totalBytes) / 1_000_000).rounded())
    }

    var body: some View {
        let state = session.app.modelStates[modelID]
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: PSSpacing.small) {
                Image(systemName: isDepth ? "square.3.layers.3d.down.right" : "cube.transparent")
                    .font(PSFont.glyph(.chip))
                    .foregroundStyle(Color.psTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.psTextPrimary)
                    Text(String(format: L("%d MB · Wi‑Fi · stays on this iPhone"), megabytes))
                        .font(.footnote)
                        .foregroundStyle(Color.psTextSecondary)
                }
                Spacer(minLength: PSSpacing.small)
                Button {
                    Haptics.tap()
                    session.dismissModelOffer()
                } label: {
                    Image(systemName: "xmark")
                        .font(PSFont.glyph(.micro, weight: .semibold))
                        .foregroundStyle(Color.psTextSecondary)
                        .frame(width: PSMetrics.chip, height: PSMetrics.chip)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(L("Not now"))
            }
            switch state {
            case .downloading(let progress)?:
                ProgressView(value: progress)
                    .tint(Color.psActionPrimary)
                    .accessibilityLabel(String(format: L("Downloading, %d percent"), Int((progress * 100).rounded())))
            case .compiling?:
                HStack(spacing: PSSpacing.small) {
                    ProgressView().controlSize(.small).tint(Color.psTextSecondary)
                    Text(L("Preparing the model…")).font(.footnote).foregroundStyle(Color.psTextSecondary)
                }
            case .installed?:
                Label(L("Installed"), systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.psSuccess)
            case .failed(let message)?:
                Text(message).font(.footnote).foregroundStyle(Color.psWarning).lineLimit(2)
                download
            default:
                Text(isDepth ? L("Near and far need the depth model. Without it, nothing is guessed.")
                             : L("Without it, the selection is approximate (Vision)."))
                    .font(.footnote)
                    .foregroundStyle(Color.psTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                download
            }
        }
        .padding(PSSpacing.medium)
        .frame(maxWidth: 360, alignment: .leading)
        .psCard(cornerRadius: PSRadius.card)
        .accessibilityElement(children: .contain)
    }

    private var download: some View {
        PSPanelPrimaryButton(L("Download"), systemImage: "arrow.down.circle", height: 36) {
            session.installMaskModel(modelID)
        }
    }
}
#endif
