#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// UX 2.0 (ux-spec §3.2): « Créer » at the top of Home, one named tile per kind of project — Photo, Vidéo, PDF,
/// Film magique — so starting something is one tap and says what it does. It replaces the resume hero, the library
/// strip and the bottom dock.
struct HomeCreateRow: View {
    let pickPhoto: () -> Void
    let pickVideo: () -> Void
    let importPDF: () -> Void
    let magicMovie: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Text(L("Create"))
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.psTextPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, PSSpacing.page)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    HomeCreateTile(title: L("Photo"), systemImage: "photo", tint: Color.psValueAccent, action: pickPhoto)
                    HomeCreateTile(title: L("Video"), systemImage: "video", tint: Color.psWarning, action: pickVideo)
                    HomeCreateTile(title: L("PDF"), systemImage: "doc.text", tint: Color.psDanger, action: importPDF)
                    HomeCreateTile(title: L("Magic movie"), systemImage: "sparkles.tv", tint: Color.psSuccess, action: magicMovie)
                }
                .padding(.horizontal, PSSpacing.page)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

private struct HomeCreateTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: PSSpacing.small) {
                Image(systemName: systemImage)
                    .font(PSFont.glyph(.tile))
                    .foregroundStyle(tint)
                    .frame(height: 28)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.psTextPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 92, minHeight: 84)
            .padding(.horizontal, PSSpacing.small)
            .background(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous).fill(Color.psElevated))
            .contentShape(RoundedRectangle(cornerRadius: PSRadius.tile, style: .continuous))
        }
        .buttonStyle(PSPressStyle(scale: 0.96))
        .accessibilityLabel(title)
        .accessibilityHint(L("Creates a new project"))
        .uxProbe(id: "home.create." + systemImage)
    }
}
#endif
