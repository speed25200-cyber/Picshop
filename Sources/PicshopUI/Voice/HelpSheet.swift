#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Voice command cheat-sheet.
struct HelpSheet: View {
    let mode: EditorMode
    @Environment(\.dismiss) private var dismiss

    private var sections: [(String, [String])] {
        var result: [(String, [String])] = [
            (L("Erase & cut out"), ["Efface le chien à gauche", "Remove the person in the background", "Enlève toutes les voitures", "Remove the background", "Mets un fond blanc", "Blur the background"]),
            (L("Light & colour"), ["Plus lumineux", "Make it warmer", "Augmente le contraste de 20", "Less saturation", "Réduis le bruit", "Set exposure to -10"]),
            (L("Looks"), ["Noir et blanc", "Apply the cinematic look", "Filtre heure dorée", "Enlève le filtre"]),
            (L("Frame"), ["Recadre en carré", "Crop for Instagram story", "Tourne de 90 degrés", "Straighten", "Retourne horizontalement"]),
            (L("Text"), ["Ajoute le texte « Été 2026 » en haut", "Add text saying Hello in yellow", "Make the text bigger", "Remove the text"]),
        ]
        if mode == .pdf {
            return [(L("PDF"), ["Va à la page 3", "Delete this page", "Supprime les pages 2 à 4", "Tourne la page", "Move page 2 to the end", "Surligne « total »", "Highlight the word invoice everywhere", "Caviarde le nom", "Cherche facture", "Remplace monsieur par madame", "Replace invoice with receipt everywhere", "Signe en bas à droite", "Ajoute le texte « Approuvé » en haut", "Extrais la page en photo", "Ajoute des numéros de page", "Fusionne avec un autre PDF"]),
                    (L("Control"), ["Annule", "Redo", "Exporte", "Partage", "Aide"])]
        }
        if mode == .video {
            result.insert((L("Video"), ["Coupe ici", "Coupe les 3 premières secondes", "Delete from 5 to 12 seconds", "Accélère x2", "Slow motion", "Coupe le son", "Ajoute un fondu entre tous les clips", "Extract this frame", "Stabilise la vidéo", "Va à 10 secondes"]), at: 0)
        }
        result.append((L("Control"), ["Annule", "Redo", "Montre l'original", "Zoom sur le visage", "Enregistre", "Reviens à l'original"]))
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1, id: \.self) { example in
                            Label(example, systemImage: "quote.opening").font(PSFont.body(15))
                        }
                    }
                }
            }
            .navigationTitle(L("Say it"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
