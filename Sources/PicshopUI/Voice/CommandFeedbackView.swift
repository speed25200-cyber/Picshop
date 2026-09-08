#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Live transcript, last reply and clarification choices above the tool dock.
struct CommandFeedbackView: View {
    @Bindable var voice: VoiceController
    var transcript: String
    var plan: EditPlan?
    var clarification: ClarificationRequest?
    var showsTranscript: Bool
    var onChoose: (Int) -> Void
    var onChooseAll: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if voice.isListening {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true).foregroundStyle(PSTheme.voice)
                    Text(voice.partialTranscript.isEmpty ? L("Listening…") : voice.partialTranscript)
                        .font(PSFont.body(15))
                        .foregroundStyle(PSTheme.textPrimary)
                        .lineLimit(2)
                        .contentTransition(.interpolate)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let clarification {
                clarificationView(clarification)
            } else if showsTranscript, let plan, !transcript.isEmpty {
                HStack(spacing: 8) {
                    Text("“\(transcript)”").font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(plan.engine.displayName).font(PSFont.caption(11)).foregroundStyle(PSTheme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(PSTheme.hairline, in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.3), value: voice.isListening)
        .animation(.spring(duration: 0.3), value: clarification?.id)
    }

    private func clarificationView(_ request: ClarificationRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.question)
                .font(PSFont.body(14))
                .foregroundStyle(PSTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(request.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            Haptics.confirm()
                            onChoose(index)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1)").font(PSFont.headline(13)).foregroundStyle(.black)
                                    .frame(width: 22, height: 22).background(PSTheme.accent, in: Circle())
                                Text(candidate.spokenDescription).font(PSFont.caption(13)).foregroundStyle(PSTheme.textPrimary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psGlass(interactive: true)
                    }
                    if request.candidates.count > 1 {
                        Button { Haptics.confirm(); onChooseAll() } label: {
                            Label(L("All"), systemImage: "checkmark.circle").font(PSFont.caption(13)).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .psGlass(tint: PSTheme.accent, interactive: true)
                    }
                    Button { Haptics.tap(); onCancel() } label: {
                        Image(systemName: "xmark").font(PSFont.caption(13)).padding(8)
                    }
                    .buttonStyle(.plain)
                    .psGlass(interactive: true, shape: AnyShape(Circle()))
                    .accessibilityLabel(L("Cancel"))
                }
            }
        }
        .padding(14)
        .psGlassPanel(cornerRadius: 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

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
            return [(L("PDF"), ["Va à la page 3", "Delete this page", "Supprime les pages 2 à 4", "Tourne la page", "Move page 2 to the end", "Surligne « total »", "Highlight the word invoice everywhere", "Caviarde le nom", "Cherche facture", "Signe en bas à droite", "Ajoute le texte « Approuvé » en haut", "Extrais la page en photo", "Ajoute des numéros de page", "Fusionne avec un autre PDF"]),
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
