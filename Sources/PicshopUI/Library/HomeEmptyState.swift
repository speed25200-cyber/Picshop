#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import PicshopIntent

/// W0: no projects yet: the orb at rest, one line of invitation, two ways in,
/// and the promise that everything stays on the iPhone. The dock stays below,
/// so 'sous-titre une vidéo' works from here too.
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
                .padding(.bottom, PSSpacing.xLarge)
            Text(L("Show me a photo."))
                .font(.title.bold())
                .foregroundStyle(Color.psTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, PSSpacing.small)
            Text(L("Open a photo, a video or a PDF, then talk to me: I'll take care of the rest."))
                .font(.body)
                .foregroundStyle(Color.psTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
                .padding(.bottom, PSSpacing.section)
            Button {
                Haptics.tap()
                onOpenMedia()
            } label: {
                Text(L("Open a photo or a video"))
                    .font(.headline)
                    .foregroundStyle(Color.psOnAction)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.psActionPrimary)
            .controlSize(.large)
            .frame(width: 280)
            .padding(.bottom, PSSpacing.medium)
            Button {
                Haptics.tap()
                onImportPDF()
            } label: {
                Text(L("Import a PDF"))
                    .font(.headline)
                    .foregroundStyle(Color.psTextPrimary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(width: 280)
            Label(L("Everything stays on the iPhone."), systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.psTextTertiary)
                .padding(.top, PSSpacing.xLarge)
        }
        .padding(.horizontal, PSSpacing.page)
        .frame(maxWidth: .infinity)
    }
}

/// What the empty Home's cards start.
struct HomeStartActions {
    var pickVideo: () -> Void
    var importPDF: () -> Void
    var magicMovie: () -> Void
}

/// W1: no projects yet. The mark, 'Montre-moi une photo.', the photo library
/// strip as the first way in (one tap starts a project), then Vidéo, PDF and
/// Magic Movie as three cards, and the lock line. The orb stays in the dock.
struct HomeStudioEmptyState: View {
    @Binding var selection: PhotosPickerItem?
    let actions: HomeStartActions

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
            PSMark(size: 44)
                .padding(.bottom, PSSpacing.mediumLarge)
            Text(L("Show me a photo."))
                .font(.title2.bold())
                .foregroundStyle(Color.psTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, PSSpacing.small)
            Text(L("Open a photo, a video or a PDF, then talk to me: I'll take care of the rest."))
                .font(.subheadline)
                .foregroundStyle(Color.psTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
                .padding(.bottom, PSSpacing.xLarge)
            HomeLibraryStrip(selection: $selection)
                .padding(.bottom, PSSpacing.mediumLarge)
            HStack(spacing: PSSpacing.small) {
                HomeStartCard(title: L("Video"), symbol: "film", action: actions.pickVideo)
                HomeStartCard(title: L("PDF"), symbol: "doc.richtext", action: actions.importPDF)
                HomeStartCard(title: L("Magic Movie"), symbol: "film.stack", isMagic: true, action: actions.magicMovie)
            }
            Label(L("Everything stays on the iPhone."), systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Color.psTextTertiary)
                .padding(.top, PSSpacing.xLarge)
        }
        .padding(.horizontal, PSSpacing.page)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

/// 'Depuis la photothèque': the system photo picker inline, one compact row,
/// no search, albums or staging. A tap on a photo or a video starts a project
/// with it straight away (Home's import path, as for the '+' menu). The picker
/// runs out of process: PicShop sees only the item picked.
struct HomeLibraryStrip: View {
    @Binding var selection: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Text(L("From your library"))
                .font(PSFont.section())
                .foregroundStyle(Color.psTextPrimary)
                .accessibilityAddTraits(.isHeader)
            PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current,
                         photoLibrary: .shared()) {
                Text(L("From your library"))
            }
            .photosPickerStyle(.compact)
            .photosPickerDisabledCapabilities([.search, .collectionNavigation, .stagingArea, .selectionActions])
            .photosPickerAccessoryVisibility(.hidden, edges: .all)
            .frame(height: PSMetrics.stripThumbnail + PSSpacing.xxLarge)
            .clipShape(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
            .accessibilityHint(L("Opens the photo or the video you tap."))
        }
    }
}

/// A 96-point start card: a symbol on a quiet plate and its name. Content, not
/// chrome: a flat fill, never glass.
private struct HomeStartCard: View {
    let title: String
    let symbol: String
    var isMagic = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.card, style: .continuous)
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: PSSpacing.small) {
                if isMagic {
                    MagicGlyph(size: PSGlyph.tile.rawValue, symbol: symbol)
                } else {
                    Image(systemName: symbol)
                        .font(PSFont.glyph(.tile))
                        .foregroundStyle(Color.psTextPrimary)
                }
                Text(title)
                    .font(PSFont.control(selected: true))
                    .foregroundStyle(Color.psTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
            }
            .padding(PSSpacing.small)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(shape.fill(Color.psFillWell))
            .overlay(shape.strokeBorder(Color.psHairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
    }
}
#endif
