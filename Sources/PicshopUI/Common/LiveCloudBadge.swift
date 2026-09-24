#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The privacy badge in the top bar while Live runs on Claude (D13). It says
/// that Claude sees the picture only after an image was actually sent.
///
/// Phase 0: the label. The upload pulse and the popover (what is sent, the
/// images toggle, Continuer sur l'iPhone) follow.
struct LiveCloudBadge: View {
    let live: LiveSession

    init(live: LiveSession) {
        self.live = live
    }

    var body: some View {
        let route = live.route
        HStack(spacing: 6) {
            Image(systemName: route.brain == .claude ? "cloud.fill" : "lock.fill")
            Text(title(route))
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(PSTheme.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: PSMetrics.badge)
        .psGlass(interactive: true, variant: .clear)
        .accessibilityElement(children: .combine)
    }

    private func title(_ route: LiveRoute) -> String {
        guard route.brain == .claude else { return L("On this iPhone") }
        guard route.sharesMedia else { return "Claude" }
        return live.mode == .video ? L("Claude can see this image") : L("Claude can see this photo")
    }
}
#endif
