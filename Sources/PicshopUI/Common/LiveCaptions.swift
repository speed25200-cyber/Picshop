#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// The caption zone above the chips while Live runs: what the user says, in
/// lighter text as it streams, then the chunk the assistant is speaking; the
/// running action with its progress, the inline Annuler and the notice line.
///
/// A leaf: it is the only view that reads `transcript`, `activity`,
/// `undoOffer` and `notice`, so a caption update never re-evaluates the dock.
///
/// Phase 0: the lines, stacked. The fixed-height reserve, the per-turn fade,
/// the voice hint card and the combined accessibility element follow.
struct LiveCaptions: View {
    let live: LiveSession

    init(live: LiveSession) {
        self.live = live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let transcript = live.transcript
            if !transcript.user.isEmpty {
                // Phase 1 draws the volatile tail in captionVolatile.
                Text(transcript.user.text)
                    .font(.body)
                    .foregroundStyle(PSTheme.captionSecondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            if !transcript.assistant.isEmpty {
                Text(transcript.assistant)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(PSTheme.captionPrimary)
                    .lineSpacing(3)
                    .lineLimit(3)
            }
            if let activity = live.activity {
                HStack(spacing: 8) {
                    ShimmerText(activity.title, font: .subheadline)
                    if let progress = activity.progress {
                        Text(verbatim: "\(Int((progress * 100).rounded())) %")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(PSTheme.textSecondary)
                    }
                }
            }
            if let offer = live.undoOffer {
                Button {
                    Haptics.tap()
                    live.undoLastAction()
                } label: {
                    Label(L("Undo"), systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PSTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .psChipFill(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .accessibilityHint(offer.label)
            }
            if let notice = live.notice {
                HStack(spacing: 8) {
                    Image(systemName: notice.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(notice.isProblem ? PSTheme.warning : PSTheme.textSecondary)
                    Text(notice.text)
                        .font(.subheadline)
                        .foregroundStyle(PSTheme.textPrimary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
private struct LiveCaptionsPreview: View {
    @State private var live: LiveSession?

    var body: some View {
        VStack {
            Spacer()
            if let live {
                LiveCaptions(live: live).padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PSTheme.canvas)
        .onAppear { if live == nil { live = LiveSession.preview(.cycle) } }
        .onDisappear { live?.teardown() }
    }
}

#Preview("LiveCaptions") {
    LiveCaptionsPreview()
}
#endif
#endif
