#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Voice command cheat-sheet.
struct HelpSheet: View {
    let mode: EditorMode
    /// Runs an example as if it had been spoken; the sheet closes first.
    var onSay: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var sections: [(String, [String])] {
        var result: [(String, [String])] = [
            (L("Erase & cut out"), ["Efface le chien à gauche", "Remove the person in the background", "Enlève toutes les voitures", "Remove the background", "Mets un fond blanc", "Blur the background"]),
            (L("Light & colour"), ["Plus lumineux", "Make it warmer", "Augmente le contraste de 20", "Less saturation", "Réduis le bruit", "Set exposure to -10", "C'est un peu jaunâtre", "It looks dull", "Plus chaud mais moins de contraste"]),
            (L("Goals"), ["Transforme-la en photo de profil", "Product photo for Vinted", "Photo d'identité", "Restore this old photo", "C'est une photo de nuit", "Mets-la en fond d'écran", "C'est moche, fais quelque chose"]),
            (L("Follow-ups"), ["Encore un peu", "A bit more", "Trop", "Less", "Non, le chat"]),
            (L("Portrait"), ["Lisse la peau", "Whiten the teeth", "Éclaircis les yeux", "Floute l'arrière-plan", "Lumière de studio"]),
            (L("Looks"), ["Noir et blanc", "Apply the cinematic look", "Filtre heure dorée", "Enlève le filtre"]),
            (L("Frame"), ["Recadre en carré", "Crop for Instagram story", "Tourne de 90 degrés", "Straighten", "Retourne horizontalement"]),
            (L("Text"), ["Ajoute le texte « Été 2026 » en haut", "Add text saying Hello in yellow", "Make the text bigger", "Remove the text"]),
        ]
        if mode == .pdf {
            return [(L("PDF"), ["Va à la page 3", "Delete this page", "Supprime les pages 2 à 4", "Tourne la page", "Move page 2 to the end", "Surligne « total »", "Highlight the word invoice everywhere", "Caviarde le nom", "Cherche facture", "Remplace monsieur par madame", "Replace invoice with receipt everywhere", "Signe en bas à droite", "Ajoute le texte « Approuvé » en haut", "Extrais la page en photo", "Ajoute des numéros de page", "Fusionne avec un autre PDF"]),
                    (L("Control"), ["Annule", "Redo", "Exporte", "Partage", "Aide"])]
        }
        if mode == .video {
            result.insert((L("Video"), ["Coupe ici", "Coupe les 3 premières secondes", "Delete from 5 to 12 seconds", "Accélère x2", "Slow motion", "Coupe le son", "Ajoute un fondu entre tous les clips", "Extract this frame", "Stabilise la vidéo", "Va à 10 secondes", "Ajoute un deuxième son à 10 secondes", "Baisse la musique à 30 %", "Fade out the music over 2 seconds", "Supprime la deuxième piste"]), at: 0)
        }
        result.append((L("Control"), ["Annule", "Redo", "Montre l'original", "Zoom sur le visage", "Enregistre", "Reviens à l'original"]))
        return result
    }

    private func symbol(for section: String) -> String {
        switch section {
        case L("Erase & cut out"): return "eraser.line.dashed"
        case L("Light & colour"): return "sun.max"
        case L("Goals"): return "target"
        case L("Follow-ups"): return "arrow.turn.down.right"
        case L("Portrait"): return "person.crop.circle"
        case L("Looks"): return "camera.filters"
        case L("Frame"): return "crop.rotate"
        case L("Text"): return "textformat"
        case L("Video"): return "film"
        case L("PDF"): return "doc.text"
        default: return "command"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PSSpacing.xLarge) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PSTheme.voiceGradient))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Say it")).font(PSFont.title(22)).foregroundStyle(PSTheme.textPrimary).tracking(-0.4)
                            Text(onSay == nil ? L("French or English, several requests in one breath.") : L("French or English. Tap an example to run it."))
                                .font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                        }
                    }
                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(section.0, systemImage: symbol(for: section.0))
                                .font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                                .symbolRenderingMode(.hierarchical)
                            FlowLayout(spacing: 8) {
                                ForEach(section.1, id: \.self) { example in
                                    Button {
                                        guard let onSay else { return }
                                        Haptics.confirm()
                                        dismiss()
                                        onSay(example)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "quote.opening").font(.system(size: 9, weight: .bold)).foregroundStyle(PSTheme.voice)
                                            Text(example).font(PSFont.body(14)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .psGlass(interactive: onSay != nil)
                                    }
                                    .buttonStyle(PSPressStyle())
                                    .disabled(onSay == nil)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }
}

/// Wraps chips onto as many rows as needed, leading-aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
