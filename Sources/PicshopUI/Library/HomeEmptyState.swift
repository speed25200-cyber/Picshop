#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PicshopIntent

/// No projects yet: the orb at rest, one line of invitation and two ways in.
/// The dock stays below, so 'sous-titre une vidéo' works from here too.
struct HomeEmptyState: View {
    let onOpenMedia: () -> Void
    let onImportPDF: () -> Void

    var body: some View {
        // At the largest text sizes the invitation scrolls rather than clips.
        ViewThatFits(in: .vertical) {
            invitation.frame(maxHeight: .infinity)
            ScrollView { invitation.padding(.vertical, PSSpacing.xLarge) }
                .scrollIndicators(.hidden)
        }
    }

    private var invitation: some View {
        VStack(spacing: 0) {
            LiveOrb(size: PSMetrics.orbHero, state: .off, meter: nil)
                .padding(.bottom, 24)
            Text(L("Show me a photo."))
                .font(.title.bold())
                .foregroundStyle(PSTheme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, PSSpacing.small)
            Text(L("Open a photo, a video or a PDF, then talk to me: I'll take care of the rest."))
                .font(.body)
                .foregroundStyle(PSTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.bottom, 28)
            Button {
                Haptics.tap()
                onOpenMedia()
            } label: {
                Text(L("Open a photo or a video"))
                    .font(.headline)
                    .foregroundStyle(PSTheme.onPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(PSTheme.primary)
            .controlSize(.large)
            .frame(width: 280)
            .padding(.bottom, PSSpacing.medium)
            Button {
                Haptics.tap()
                onImportPDF()
            } label: {
                Text(L("Import a PDF"))
                    .font(.headline)
                    .foregroundStyle(PSTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(width: 280)
        }
        .padding(.horizontal, PSSpacing.page)
        .frame(maxWidth: .infinity)
    }
}
#endif
