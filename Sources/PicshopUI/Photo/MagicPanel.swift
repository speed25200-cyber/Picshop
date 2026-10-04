#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Objets, in Outils › Magie: what PicShop found in the picture, one tap to
/// erase each, a long press to move it; tap an object on the photo for the
/// same actions beside it. The one-tap Magic actions are tiles of the
/// category itself, and the dock's Ask field is the prompt. W3 (D21): « Recettes », ready-made sequences of edits,
/// each one history step.
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
            if FeatureFlags.isOn(.recipes) {
                RecipesRow(session: session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(PSMotion.standard, value: session.sceneObjects.map(\.id))
        .task(id: session.lookThumbnailKey) { await session.loadSceneObjects() }
    }
}

/// « Recettes » (W3, D21; §7.14): Post Instagram (4:5, 1:1 or 9:16), Photo produit (a background colour), Retouche
/// portrait (a strength). Each runs `OperationCall(recipe, args, source: .ui)` through the photo executor, one history
/// step « Recette : <titre> »; Instagram's last step opens the export sheet on its preset.
struct RecipesRow: View {
    let session: PhotoEditorSession
    @State private var background = PSColor.white
    @State private var strength = 50.0
    @State private var opens: RecipeName?

    var body: some View {
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            Text(L("Recipes"))
                .font(PSFontRole.groupHeader)
                .textCase(.uppercase)
                .foregroundStyle(Color.psTextSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    Menu {
                        ForEach(PhotoPanelInventory.instagramFormats, id: \.self) { format in
                            Button(Self.formatTitle(format)) { run(.instagramPost, ["format": .string(format)]) }
                                .accessibilityIdentifier("magic.recipe.instagram.\(format)")
                        }
                    } label: {
                        RecipeChipLabel(title: L("Instagram post"), symbol: "camera.aperture")
                    }
                    .accessibilityIdentifier("magic.recipe.instagram")
                    Button {
                        opens = opens == .productPhoto ? nil : .productPhoto
                    } label: {
                        RecipeChipLabel(title: L("Product photo"), symbol: "bag", isActive: opens == .productPhoto)
                    }
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .accessibilityIdentifier("magic.recipe.product")
                    Button {
                        opens = opens == .portraitRetouch ? nil : .portraitRetouch
                    } label: {
                        RecipeChipLabel(title: L("Portrait retouch"), symbol: "person.crop.circle", isActive: opens == .portraitRetouch)
                    }
                    .buttonStyle(PSPressStyle(scale: 0.97))
                    .accessibilityIdentifier("magic.recipe.portrait")
                }
            }
            switch opens {
            case .productPhoto?:
                HStack(spacing: PSSpacing.small) {
                    InspectorColorRow(label: L("Background"), color: background, supportsOpacity: false, controlID: "magic.recipe.product.background") {
                        background = $0
                    }
                    PanelActionButton(title: L("Apply")) { run(.productPhoto, ["background": .string(background.hexString)]) }
                }
                .transition(.opacity)
            case .portraitRetouch?:
                HStack(spacing: PSSpacing.small) {
                    InspectorSliderRow(label: L("Strength"), value: strength, range: 0...100, neutral: 50, controlID: "magic.recipe.portrait.strength",
                                       format: { "\(Int($0.rounded()))" }, onChange: { strength = $0 })
                    PanelActionButton(title: L("Apply")) { run(.portraitRetouch, ["strength": .number(strength.rounded())]) }
                }
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
        .animation(PSSpring.standard, value: opens)
        .disabled(session.isProcessing)
    }

    private func run(_ name: RecipeName, _ args: [String: OpValue]) {
        Haptics.magic()
        var all = args
        all["name"] = .string(name.rawValue)
        opens = nil
        session.perform(EditIntent(action: .operation, operation: OperationCall("recipe", args: all, source: .ui)))
    }

    static func formatTitle(_ format: String) -> String {
        switch format {
        case "portrait4x5": return L("Portrait 4:5")
        case "square": return L("Square 1:1")
        case "story9x16": return L("Story 9:16")
        default: return format
        }
    }
}

/// A recipe's chip: the AI's glyph and its title.
private struct RecipeChipLabel: View {
    let title: String
    let symbol: String
    var isActive = false

    var body: some View {
        HStack(spacing: PSSpacing.xSmall) {
            MagicGlyph(size: 15, symbol: symbol)
            Text(title).lineLimit(1)
        }
        .font(.subheadline)
        .foregroundStyle(isActive ? Color.psOnAction : Color.psTextPrimary)
        .padding(.horizontal, PSSpacing.medium)
        .frame(minHeight: PanelChipStyle.height)
        .background(Capsule().fill(isActive ? Color.psActionPrimary : Color.psFillControl))
        .contentShape(Capsule())
    }
}
#endif
