#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The privacy badge in the top bar while Live runs on Claude (D13). It says
/// that Claude sees the picture only after an image was actually sent, pulses
/// while one is uploading, and names the iPhone when Live falls back to it.
/// A tap explains what is sent, with the images toggle and 'Continuer sur l'iPhone'.
struct LiveCloudBadge: View {
    let live: LiveSession

    @State private var showsDetails = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(live: LiveSession) {
        self.live = live
    }

    var body: some View {
        let route = live.route
        Button {
            Haptics.tap()
            showsDetails = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: route.brain == .claude ? "cloud.fill" : "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(Self.title(route, mode: live.mode))
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PSTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: PSMetrics.badge)
            .psGlass(interactive: true, variant: .clear)
            .opacity(dim ? 0.5 : 1)
            .frame(minHeight: PSMetrics.barButton)
            .contentShape(Capsule())
        }
        .buttonStyle(PSPressStyle(scale: 0.95))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .popover(isPresented: $showsDetails) {
            LivePrivacyPopover(live: live) { showsDetails = false }
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: route.isUploading) { _, uploading in pulse(uploading) }
        .onAppear { pulse(route.isUploading) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.title(route, mode: live.mode))
        .accessibilityHint(L("Shows what is sent to Claude."))
    }

    /// The badge's words for a route.
    static func title(_ route: LiveRoute, mode: EditorMode) -> String {
        switch route.brain {
        case .claude:
            guard route.sharesMedia else { return "Claude" }
            return mode == .video ? L("Claude can see this image") : L("Claude can see this photo")
        case .onDevice:
            return L("On this iPhone")
        case .commands:
            return L("Commands")
        }
    }

    /// Breathes while an image is uploading.
    private func pulse(_ uploading: Bool) {
        if uploading, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
        } else if dim {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }
}

/// What Live sends, from the badge.
private struct LivePrivacyPopover: View {
    let live: LiveSession
    let onClose: () -> Void
    @Environment(\.picshop) private var app

    var body: some View {
        let isClaude = live.route.brain == .claude
        VStack(alignment: .leading, spacing: 14) {
            Label(isClaude ? L("What Claude receives") : L("Live on this iPhone"), systemImage: isClaude ? "cloud.fill" : "lock.fill")
                .font(.headline)
                .foregroundStyle(PSTheme.textPrimary)
            Text(isClaude
                 ? L("The text of your words and a 1024 px copy of the picture. Never the audio: your voice is transcribed on the iPhone.")
                 : L("Live answers here, on the iPhone: your words and the picture stay on the device."))
                .font(.subheadline)
                .foregroundStyle(PSTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if isClaude {
                Toggle(isOn: Binding(get: { app?.settings.liveSendsImages ?? false },
                                     set: { app?.settings.liveSendsImages = $0 })) {
                    Text(live.mode == .video ? L("Show the frame to Claude") : L("Show the photo to Claude"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PSTheme.textPrimary)
                }
                .tint(PSTheme.success)
                .disabled(app == nil)
                PSPanelPrimaryButton(L("Continue on the iPhone"), systemImage: "lock.fill", height: 44) {
                    live.continueOnDevice()
                    onClose()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }
}
#endif
