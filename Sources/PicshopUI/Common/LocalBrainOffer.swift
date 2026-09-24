#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The Live dock's brain pill: which brain answers this conversation, the
/// local model by name, Apple Intelligence, or the commands. A leaf, so the
/// route never re-evaluates the dock.
///
/// Phase 0: the name only. The download offer, the progress ring and
/// 'Chargement du cerveau…' arrive with the local brain.
struct LocalBrainPill: View {
    let live: LiveSession

    var body: some View {
        let route = live.route
        HStack(spacing: 5) {
            Image(systemName: Self.symbol(route.brain))
                .font(.system(size: 10, weight: .semibold))
            Text(Self.title(route))
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(PSTheme.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: PSMetrics.badge)
        .background(Capsule().fill(PSTheme.fill))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .combine)
    }

    static func title(_ route: LiveRoute) -> String {
        switch route.brain {
        case .model: return route.modelName ?? L("Local brain")
        case .onDevice: return "Apple Intelligence"
        case .commands: return L("Commands")
        }
    }

    static func symbol(_ brain: LiveRoute.Brain) -> String {
        switch brain {
        case .model: return "brain"
        case .onDevice: return "apple.intelligence"
        case .commands: return "text.bubble"
        }
    }
}

/// Offered from the Live dock when this iPhone can run the local brain and it
/// is not downloaded yet. Wi‑Fi by default; cellular only after a confirmation
/// that shows the size (phase 1).
struct LocalBrainOfferSheet: View {
    let onClose: () -> Void
    private let hub = LocalBrainHub.shared

    var body: some View {
        let status = hub.status
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 40, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PSTheme.textPrimary)
                .accessibilityHidden(true)
            Text(L("Download the local brain?"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(PSTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(L("PicShop Live works entirely on your iPhone. The local brain lets it look at the picture and talk more naturally."))
                .font(.subheadline)
                .foregroundStyle(PSTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let model = status.model, status.downloadBytes > 0 {
                Text(verbatim: "\(model.displayName) · \(LocalBrainText.size(status.downloadBytes))")
                    .font(PSFont.mono(12))
                    .foregroundStyle(PSTheme.textTertiary)
            }
            PSPanelPrimaryButton(L("Download over Wi‑Fi"), systemImage: "wifi", height: 50) {
                hub.download(allowCellular: false)
                onClose()
            }
            .frame(maxWidth: .infinity)
            Button(L("Later"), action: onClose)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PSTheme.textSecondary)
        }
        .padding(24)
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
#endif
