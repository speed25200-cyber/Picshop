#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Objets, in Outils › Magie: what PicShop found in the picture, one tap to
/// erase each, a long press to move it; tap an object on the photo for the
/// same actions beside it. The one-tap Magic actions are tiles of the
/// category itself, and the dock's Ask field is the prompt.
struct MagicPanel: View {
    @Bindable var session: PhotoEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MagicGlyph(size: 17, symbol: "hand.tap")
                Text(L("Tap an object on the photo to erase it, move it or blur it."))
                    .font(.subheadline)
                    .foregroundStyle(PSTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.isFindingObjects && session.sceneObjects.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(PSTheme.textTertiary)
                    Text(L("Looking for objects…")).font(.footnote).foregroundStyle(PSTheme.textTertiary)
                }
                .transition(.opacity)
            } else if !session.sceneObjects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.sceneObjects) { candidate in
                            SceneObjectChip(candidate: candidate, thumbnail: { await session.candidateThumbnail($0) }) {
                                session.erase(candidate)
                            }
                            .contextMenu {
                                Button { session.erase(candidate) } label: { Label(L("Erase"), systemImage: "eraser") }
                                Divider()
                                Button { session.move(candidate, degrees: 180) } label: { Label(L("Move left"), systemImage: "arrow.left") }
                                Button { session.move(candidate, degrees: 0) } label: { Label(L("Move right"), systemImage: "arrow.right") }
                                Button { session.move(candidate, degrees: 90) } label: { Label(L("Move up"), systemImage: "arrow.up") }
                                Button { session.move(candidate, degrees: -90) } label: { Label(L("Move down"), systemImage: "arrow.down") }
                                Button { session.move(candidate, degrees: nil) } label: { Label(L("Centre it"), systemImage: "scope") }
                                Divider()
                                Button { session.blur(candidate) } label: { Label(L("Blur it"), systemImage: "drop.halffull") }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .accessibilityHint(L("Tap to erase · hold to move"))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PSMotion.standard, value: session.sceneObjects.map(\.id))
        .task(id: session.lookThumbnailKey) { await session.loadSceneObjects() }
    }
}
#endif
