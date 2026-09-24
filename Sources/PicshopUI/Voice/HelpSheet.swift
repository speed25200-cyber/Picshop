#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// 'Que puis-je dire ?': examples as plain chips, grouped by what they do,
/// with Live's conversational ones first; the spectrum marks only the voice
/// glyph at the top.
struct HelpSheet: View {
    let mode: EditorMode
    /// Runs an example as if it had been spoken; the sheet closes first.
    var onSay: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var sections: [(String, [String])] {
        var result: [(String, [String])] = [
            (L("Magic"), ["Déplace le chien vers la gauche", "Étends l'image en 16:9", "Mets-moi sur une plage au coucher du soleil", "Remplace le ciel par un ciel étoilé", "Écris « Paris » derrière la personne", "Prends les couleurs d'une autre photo"]),
            (L("Erase & cut out"), ["Efface le chien à gauche", "Remove the person in the background", "Enlève toutes les voitures", "Efface les chiffres du tableau", "Remove the watermark", "Remove the background", "Mets un fond blanc", "Blur the background"]),
            (L("Light & colour"), ["Plus lumineux", "Make it warmer", "Augmente le contraste de 20", "Less saturation", "Réduis le bruit", "Set exposure to -10", "C'est un peu jaunâtre", "It looks dull", "Plus chaud mais moins de contraste"]),
            (L("Goals"), ["Transforme-la en photo de profil", "Product photo for Vinted", "Photo d'identité", "Restore this old photo", "C'est une photo de nuit", "Mets-la en fond d'écran", "C'est moche, fais quelque chose"]),
            (L("Follow-ups"), ["Encore un peu", "A bit more", "Trop", "Less", "Non, le chat"]),
            (L("Portrait"), ["Lisse la peau", "Whiten the teeth", "Éclaircis les yeux", "Floute l'arrière-plan", "Lumière de studio"]),
            (L("Looks"), ["Noir et blanc", "Apply the cinematic look", "Filtre heure dorée", "Enlève le filtre"]),
            (L("Frame"), ["Recadre en carré", "Crop for Instagram story", "Tourne de 90 degrés", "Straighten", "Retourne horizontalement", "C'est à l'envers", "Put it the right way up"]),
            (L("Text"), ["Ajoute le texte « Été 2026 » en haut", "Add text saying Hello in yellow", "Make the text bigger", "Remove the text"]),
        ]
        if mode == .pdf {
            return [(L("PDF"), ["Va à la page 3", "Delete this page", "Supprime les pages 2 à 4", "Tourne la page", "Move page 2 to the end", "Surligne « total »", "Highlight the word invoice everywhere", "Caviarde le nom", "Cherche facture", "Remplace monsieur par madame", "Replace invoice with receipt everywhere", "Signe en bas à droite", "Ajoute le texte « Approuvé » en haut", "Extrais la page en photo", "Ajoute des numéros de page", "Fusionne avec un autre PDF"]),
                    (L("Control"), ["Annule", "Redo", "Exporte", "Partage", "Aide"])]
        }
        if mode == .video {
            result.insert((L("Video magic"), ["Ajoute des sous-titres", "Enlève les euh", "Coupe le passage où je dis bonjour", "Fais un résumé de 30 secondes", "Coupe à chaque changement de plan",
                                                "Fais suivre le texte à la personne", "Baisse la musique quand je parle", "Ralenti progressif ici", "Anime le titre avec un rebond", "Coupe sur le rythme", "Passe en vertical en suivant le sujet"]), at: 0)
            result.removeAll { $0.0 == L("Magic") }
            result.insert((L("Video"), ["Coupe ici", "Coupe les 3 premières secondes", "Delete from 5 to 12 seconds", "Accélère x2", "Slow motion", "Coupe le son", "Ajoute un fondu entre tous les clips", "Extract this frame", "Stabilise la vidéo", "Va à 10 secondes", "Ajoute un deuxième son à 10 secondes", "Baisse la musique à 30 %", "Fade out the music over 2 seconds", "Supprime la deuxième piste"]), at: 0)
        }
        // Live: talk it through; the editor's orb starts it.
        result.insert((L("Live"), [mode == .video ? "Qu'est-ce que tu ferais sur cette vidéo ?" : "Qu'est-ce que tu ferais sur cette photo ?", "Enlève le truc à côté de la lampe", "Un peu moins", "Montre-moi l'avant", "La deuxième idée", "Stop"]), at: 0)
        result.append((L("Control"), ["Annule", "Redo", "Montre l'original", "Zoom sur le visage", "Enregistre", "Reviens à l'original", "Enregistre cette version sous brouillon", "Reviens à la version brouillon", "Qu'est-ce que j'ai modifié ?", "Décris la photo", "Enregistre ce style sous plage", "Applique le même style que la dernière photo"]))
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
        case L("Magic"), L("Video magic"): return "sparkles"
        case L("PDF"): return "doc.text"
        case L("Live"): return "bubble.left.and.text.bubble.right"
        default: return "command"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PSSpacing.section) {
                    HStack(spacing: PSSpacing.medium) {
                        MagicGlyph(size: 20, symbol: "waveform")
                            .frame(width: 48, height: 48)
                            .background(PSTheme.fill, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("What can I say?")).font(.title2.weight(.bold)).foregroundStyle(PSTheme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text(onSay == nil ? L("French or English, several requests in one breath.") : L("French or English. Tap an example to run it."))
                                .font(PSFont.footnote()).foregroundStyle(PSTheme.textSecondary)
                        }
                    }
                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: PSSpacing.medium) {
                            Label(section.0, systemImage: symbol(for: section.0))
                                .font(PSFont.headline()).foregroundStyle(PSTheme.textPrimary)
                                .symbolRenderingMode(.hierarchical)
                            FlowLayout(spacing: 8) {
                                ForEach(section.1, id: \.self) { example in
                                    Button {
                                        guard let onSay else { return }
                                        Haptics.confirm()
                                        dismiss()
                                        onSay(example)
                                    } label: {
                                        Text(example).font(PSFont.control()).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                                            .padding(.horizontal, PSMetrics.chipPadding)
                                            .frame(minHeight: PSMetrics.chip)
                                            .psChipFill(Capsule())
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(PSPressStyle(scale: 0.97))
                                    .disabled(onSay == nil)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.vertical, PSSpacing.medium)
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
