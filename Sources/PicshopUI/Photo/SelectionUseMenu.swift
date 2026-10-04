#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// « Utiliser la sélection pour » (W2): Réglage local, Masque, Effacer, Remplir…, Recolorer…, Flouter, Détourer,
/// Générer…, and (W3) Nouveau calque (copier) / (couper). Each item runs the selectionApply handler, exactly what « remplis la sélection de rouge » runs, so the
/// panel and the voice give the same document. Générer… asks for a prompt and needs the generative engine.
struct SelectionUseMenu: View {
    let session: PhotoEditorSession

    @State private var asksPrompt = false
    @State private var prompt = ""

    static let colors: [PSColor] = [.white, .black, .red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .gray, .brown]

    var body: some View {
        Menu {
            Button { session.useSelection(for: .adjust) } label: { Label(L("Local adjustment"), systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("select.use.adjust")
            Button { session.useSelection(for: .mask) } label: { Label(L("Mask"), systemImage: "circle.rectangle.dashed") }
                .accessibilityIdentifier("select.use.mask")
            Button { session.useSelection(for: .erase) } label: { Label(L("Erase the area"), systemImage: "eraser") }
                .accessibilityIdentifier("select.use.erase")
            Menu {
                colorItems { session.useSelection(for: .fill($0)) }
            } label: {
                Label(L("Fill…"), systemImage: "paintbrush")
            }
            .accessibilityIdentifier("select.use.fill")
            Menu {
                colorItems { session.useSelection(for: .recolor($0)) }
            } label: {
                Label(L("Recolor…"), systemImage: "paintpalette")
            }
            .accessibilityIdentifier("select.use.recolor")
            Menu {
                Button(L("Slight")) { session.useSelection(for: .blur(0.3)) }
                Button(L("Medium")) { session.useSelection(for: .blur(0.6)) }
                Button(L("Strong")) { session.useSelection(for: .blur(0.9)) }
            } label: {
                Label(L("Blur"), systemImage: "drop.halffull")
            }
            .accessibilityIdentifier("select.use.blur")
            Button { session.useSelection(for: .cutout) } label: { Label(L("Cut out"), systemImage: "person.crop.rectangle") }
                .accessibilityIdentifier("select.use.cutout")
            if FeatureFlags.isOn(.proLayers) {
                // W3 (D17): the selection's pixels of the active image layer on a new layer, the single selectionApply path.
                Button { session.useSelection(for: .copyToLayer) } label: { Label(L("New layer (copy)"), systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("select.use.copyToLayer")
                Button { session.useSelection(for: .cutToLayer) } label: { Label(L("New layer (cut)"), systemImage: "scissors") }
                    .accessibilityIdentifier("select.use.cutToLayer")
            }
            Button {
                prompt = ""
                asksPrompt = true
            } label: {
                Label(L("Generate…"), systemImage: "sparkles")
            }
            .disabled(!session.hasGenerativeEngine)
            .accessibilityIdentifier("select.use.generate")
        } label: {
            Label(L("Use the selection for"), systemImage: "arrow.turn.down.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.psOnAction)
                .padding(.horizontal, PSSpacing.large)
                .frame(minHeight: PanelChipStyle.height)
                .background(Capsule().fill(Color.psActionPrimary))
        }
        .alert(L("Generate in the selection"), isPresented: $asksPrompt) {
            TextField(L("Describe what to generate…"), text: $prompt)
                .accessibilityIdentifier("select.use.generate.prompt")
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Generate")) {
                let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                session.useSelection(for: .generate(text))
            }
        } message: {
            Text(L("Generative Fill paints it into the selection, on this iPhone."))
        }
    }

    @ViewBuilder
    private func colorItems(_ pick: @escaping (PSColor) -> Void) -> some View {
        ForEach(Self.colors, id: \.self) { color in
            Button {
                pick(color)
            } label: {
                Label(Self.name(color), systemImage: "circle.fill")
            }
        }
    }

    /// The colour's name in the menu (the hex for one without a name).
    static func name(_ color: PSColor) -> String {
        switch color {
        case .white: return L("White")
        case .black: return L("Black")
        case .red: return L("Red")
        case .orange: return L("Orange")
        case .yellow: return L("Yellow")
        case .green: return L("Green")
        case .teal: return L("Teal")
        case .blue: return L("Blue")
        case .purple: return L("Purple")
        case .pink: return L("Pink")
        case .gray: return L("Grey")
        case .brown: return L("Brown")
        default: return color.hexString
        }
    }
}
#endif
