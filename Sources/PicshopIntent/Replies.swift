import Foundation
import PicshopCore

/// Short confirmations spoken/displayed after a command is understood.
public enum Replies {
    public static func reply(for intent: EditIntent, language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        switch intent.action {
        case .removeObject:
            let what = intent.target?.originalPhrase ?? (fr ? "l'objet" : "the object")
            return fr ? "J'efface \(what)." : "Removing \(what)."
        case .removeBackground: return fr ? "Je détoure le sujet." : "Cutting out the subject."
        case .replaceBackground: return fr ? "Je change le fond." : "Changing the background."
        case .blurBackground: return fr ? "Je floute l'arrière-plan." : "Blurring the background."
        case .adjust:
            let name = fr ? intent.parameter?.frenchName ?? "Réglage" : intent.parameter?.englishName ?? "Adjustment"
            guard let amount = intent.amount else { return fr ? "\(name) ajusté." : "\(name) adjusted." }
            switch amount.mode {
            case .absolute: return fr ? "\(name) réglé à \(Int((amount.value * 100).rounded()))." : "\(name) set to \(Int((amount.value * 100).rounded()))."
            case .relative: return fr ? (amount.value >= 0 ? "Plus de \(name.lowercased())." : "Moins de \(name.lowercased()).") : (amount.value >= 0 ? "More \(name.lowercased())." : "Less \(name.lowercased()).")
            case .multiplier: return fr ? "\(name) modifié." : "\(name) changed."
            }
        case .selectiveAdjust: return fr ? "Réglage appliqué sur la sélection." : "Adjusting the selection."
        case .applyLook: return fr ? "Look \(intent.look?.frenchName ?? "") appliqué." : "Applied the \(intent.look?.englishName ?? "") look."
        case .autoEnhance: return fr ? "Amélioration automatique." : "Auto-enhancing."
        case .crop, .setAspect: return fr ? "Recadrage \(intent.aspect?.displayName ?? "")." : "Cropping \(intent.aspect?.displayName ?? "")."
        case .rotate: return fr ? "Rotation de \(Int(intent.degrees ?? 90))°." : "Rotating \(Int(intent.degrees ?? 90))°."
        case .straighten: return fr ? "Je redresse l'horizon." : "Straightening."
        case .flip: return fr ? "Image retournée." : "Flipped."
        case .addText: return fr ? "Texte ajouté." : "Text added."
        case .editText: return fr ? "Texte modifié." : "Text updated."
        case .removeText: return fr ? "Texte supprimé." : "Text removed."
        case .upscale: return fr ? "J'augmente la résolution." : "Upscaling."
        case .denoise: return fr ? "Je réduis le bruit." : "Reducing noise."
        case .sharpen: return fr ? "Plus de netteté." : "Sharpening."
        case .relight: return fr ? "Je rééclaire la scène." : "Relighting."
        case .generativeFill: return fr ? "Je génère « \(intent.text ?? "") »." : "Generating “\(intent.text ?? "")”."
        case .recolor: return fr ? "Je recolore \(intent.target?.originalPhrase ?? "la zone")." : "Recolouring \(intent.target?.originalPhrase ?? "the area")."
        case .deletePage: return fr ? "Page supprimée." : "Page deleted."
        case .rotatePage: return fr ? "Page pivotée." : "Page rotated."
        case .movePage: return fr ? "Page déplacée." : "Page moved."
        case .duplicatePage: return fr ? "Page dupliquée." : "Page duplicated."
        case .insertBlankPage: return fr ? "Page ajoutée." : "Page added."
        case .goToPage: return fr ? "Page \(intent.index ?? 1)." : "Page \(intent.index ?? 1)."
        case .highlightText: return fr ? "Surligné." : "Highlighted."
        case .underlineText: return fr ? "Souligné." : "Underlined."
        case .redactText: return fr ? "Caviardé." : "Redacted."
        case .findText: return fr ? "Je cherche « \(intent.text ?? "") »." : "Searching for “\(intent.text ?? "")”."
        case .replaceText:
            if (intent.replacement ?? "").isEmpty { return fr ? "J'efface « \(intent.text ?? "") »." : "Erasing “\(intent.text ?? "")”." }
            return fr ? "Je remplace « \(intent.text ?? "") » par « \(intent.replacement ?? "") »." : "Replacing “\(intent.text ?? "")” with “\(intent.replacement ?? "")”."
        case .addSignature: return fr ? "Signature ajoutée." : "Signature added."
        case .extractPage: return fr ? "Page exportée en photo." : "Page saved as a photo."
        case .addPageNumbers: return fr ? "Numéros de page ajoutés." : "Page numbers added."
        case .mergeDocument: return fr ? "Choisis le PDF à fusionner." : "Pick the PDF to merge."
        case .undo: return fr ? "Annulé." : "Undone."
        case .redo: return fr ? "Rétabli." : "Redone."
        case .revert: return fr ? "Retour à l'original." : "Back to the original."
        case .compare: return fr ? "Voici l'original." : "Showing the original."
        case .zoom: return fr ? "Zoom." : "Zooming."
        case .export: return fr ? "J'exporte." : "Exporting."
        case .share: return fr ? "Je prépare le partage." : "Preparing to share."
        case .selectLayer: return fr ? "Sélectionné." : "Selected."
        case .duplicateLayer, .duplicateClip: return fr ? "Dupliqué." : "Duplicated."
        case .deleteLayer: return fr ? "Calque supprimé." : "Layer deleted."
        case .trim: return fr ? "Vidéo raccourcie." : "Trimmed."
        case .split: return fr ? "Clip coupé." : "Clip split."
        case .deleteClip: return fr ? "Clip supprimé." : "Clip deleted."
        case .deleteRange: return fr ? "Passage supprimé." : "Section deleted."
        case .setSpeed: return fr ? "Vitesse ×\(formatted(intent.amount?.value ?? 1))." : "Speed ×\(formatted(intent.amount?.value ?? 1))."
        case .reverse: return fr ? "Lecture inversée." : "Reversed."
        case .mute: return fr ? "Son coupé." : "Muted."
        case .unmute: return fr ? "Son rétabli." : "Unmuted."
        case .setVolume: return fr ? "Volume ajusté." : "Volume adjusted."
        case .addTransition: return fr ? "Transition ajoutée." : "Transition added."
        case .removeTransition: return fr ? "Transition retirée." : "Transition removed."
        case .addMusic: return fr ? "Choisis une musique." : "Pick a track."
        case .removeMusic: return fr ? "Musique retirée." : "Music removed."
        case .extractFrame: return fr ? "Image extraite." : "Frame saved."
        case .seek: return fr ? "OK." : "OK."
        case .play: return fr ? "Lecture." : "Playing."
        case .pause: return fr ? "Pause." : "Paused."
        case .moveClip: return fr ? "Clip déplacé." : "Clip moved."
        case .stabilize: return fr ? "Je stabilise la vidéo." : "Stabilizing."
        case .freezeFrame: return fr ? "Arrêt sur image." : "Freeze frame added."
        case .chooseCandidate: return fr ? "Compris." : "Got it."
        case .confirm: return fr ? "OK." : "OK."
        case .cancel: return fr ? "Annulé." : "Cancelled."
        case .help: return fr ? "Dis par exemple : « efface le chien », « plus lumineux », « recadre en carré »." : "Try: “remove the dog”, “make it brighter”, “crop to square”."
        case .describe: return fr ? "Je regarde la photo…" : "Looking at the photo…"
        case .readPage: return fr ? "Je lis la page." : "Reading the page."
        case .saveVersion: return fr ? "Version « \(intent.text ?? "") » enregistrée." : "Saved version “\(intent.text ?? "")”."
        case .restoreVersion: return fr ? "Je reviens à la version « \(intent.text ?? "") »." : "Back to version “\(intent.text ?? "")”."
        case .saveStyle: return fr ? "Style « \(intent.text ?? "") » enregistré." : "Saved the “\(intent.text ?? "")” style."
        case .applyStyle:
            if intent.text == "last" { return fr ? "J'applique le style de la dernière photo." : "Applying the last photo's style." }
            return fr ? "J'applique le style « \(intent.text ?? "") »." : "Applying the “\(intent.text ?? "")” style."
        case .summarizeEdits: return fr ? "Voici ce que tu as modifié." : "Here is what you changed."
        case .unknown: return fr ? "Je n'ai pas compris. Tu peux reformuler ?" : "I didn't catch that. Could you rephrase?"
        }
    }

    /// Sentence for "décris la photo".
    public static func describe(_ scene: SceneDescription, language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        guard !scene.isEmpty else { return fr ? "Je ne reconnais rien de précis sur cette photo." : "I can't make out anything specific in this photo." }
        var parts: [String] = []
        if scene.people > 0 {
            parts.append(fr ? (scene.people == 1 ? "une personne" : "\(scene.people) personnes") : (scene.people == 1 ? "one person" : "\(scene.people) people"))
        } else if scene.faces > 0 {
            parts.append(fr ? (scene.faces == 1 ? "un visage" : "\(scene.faces) visages") : (scene.faces == 1 ? "a face" : "\(scene.faces) faces"))
        }
        let animalNames: [String: (String, String)] = ["dog": ("un chien", "a dog"), "cat": ("un chat", "a cat")]
        for animal in scene.animals {
            let names = animalNames[animal] ?? (fr ? "un animal" : "an animal", "an animal")
            parts.append(fr ? names.0 : names.1)
        }
        if scene.hasText { parts.append(fr ? "du texte" : "some text") }
        var sentence = ""
        if !parts.isEmpty {
            let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + (fr ? " et " : " and ") + parts.last! : parts[0]
            sentence = fr ? "Je vois \(list)." : "I see \(list)."
        }
        if !scene.labels.isEmpty {
            let labels = scene.labels.prefix(3).map { fr ? ObjectVocabulary.frenchSceneLabel($0) : $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")
            sentence += (sentence.isEmpty ? "" : " ") + (fr ? "Ambiance : \(labels)." : "Scene: \(labels).")
        }
        if scene.brightness < 0.3 { sentence += fr ? " La photo est assez sombre." : " The photo is quite dark." }
        else if scene.brightness > 0.8 { sentence += fr ? " La photo est très claire." : " The photo is very bright." }
        if scene.colourfulness < 0.12 { sentence += fr ? " Les couleurs sont ternes." : " The colours are muted." }
        return sentence
    }

    /// Three concrete things to try, shown when a request was not understood.
    public static func suggestions(for mode: EditorMode, language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        let examples: [String]
        switch mode {
        case .photo: examples = fr ? ["Efface la personne à gauche", "Plus lumineux", "Fond blanc"] : ["Remove the person on the left", "Brighter", "White background"]
        case .video: examples = fr ? ["Coupe les 3 premières secondes", "Accélère x2", "Coupe le son"] : ["Cut the first 3 seconds", "Speed up 2x", "Mute"]
        case .pdf: examples = fr ? ["Remplace monsieur par madame", "Surligne « total »", "Signe en bas à droite"] : ["Replace invoice with receipt", "Highlight “total”", "Sign at the bottom right"]
        }
        let joined = examples.map { fr ? "« \($0) »" : "“\($0)”" }.joined(separator: " · ")
        return (fr ? "Essayez : " : "Try: ") + joined
    }

    static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    public static func combined(for intents: [EditIntent], language: NormalizedUtterance.Language) -> String {
        let meaningful = intents.filter { $0.action != .unknown }
        if meaningful.isEmpty {
            return reply(for: EditIntent(action: .unknown), language: language)
        }
        if meaningful.count == 1 {
            return reply(for: meaningful[0], language: language)
        }
        let parts = meaningful.map { reply(for: $0, language: language).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return parts.joined(separator: ", ") + "."
    }
}
