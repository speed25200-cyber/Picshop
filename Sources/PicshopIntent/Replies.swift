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
        case .flip:
            if intent.flipAxis == .vertical { return fr ? "Image retournée de haut en bas." : "Flipped upside down." }
            return fr ? "Image retournée en miroir." : "Mirrored left to right."
        case .resetOrientation:
            if intent.flipAxis != nil { return fr ? "J'enlève l'effet miroir." : "Taking the mirror off." }
            return fr ? "Je remets l'image à l'endroit." : "Putting it the right way up."
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
        case .addMusic: return fr ? "Choisis un son." : "Pick a sound."
        case .removeMusic: return fr ? "Piste son retirée." : "Sound track removed."
        case .moveAudio: return fr ? "Son déplacé." : "Sound moved."
        case .fadeAudio: return fr ? "Fondu appliqué au son." : "Sound faded."
        case .extractFrame: return fr ? "Image extraite." : "Frame saved."
        case .seek: return fr ? "OK." : "OK."
        case .play: return fr ? "Lecture." : "Playing."
        case .pause: return fr ? "Pause." : "Paused."
        case .moveClip: return fr ? "Clip déplacé." : "Clip moved."
        case .stabilize: return fr ? "Je stabilise la vidéo." : "Stabilizing."
        case .freezeFrame: return fr ? "Arrêt sur image." : "Freeze frame added."
        case .autoCaptions: return fr ? "J'écoute la vidéo et j'écris les sous-titres." : "Listening and writing the captions."
        case .removeCaptions: return fr ? "Sous-titres retirés." : "Captions removed."
        case .removeSilences: return fr ? "J'enlève les blancs." : "Removing the pauses."
        case .removeFillers: return fr ? "J'enlève les hésitations." : "Removing the filler words."
        case .translateCaptions: return fr ? "Je traduis les sous-titres." : "Translating the captions."
        case .autoDuck: return fr ? "La musique va s'effacer sous la voix." : "The music will dip under the voice."
        case .trackSubject: return fr ? "Je suis le sujet." : "Following the subject."
        case .splitScenes: return fr ? "Je cherche les changements de plan." : "Finding the shot changes."
        case .highlights: return fr ? "Je garde les meilleurs moments." : "Keeping the best moments."
        case .speedRamp: return fr ? "Ralenti progressif." : "Speed ramp."
        case .punchIns: return fr ? "Zooms sur les coupes." : "Zoom cuts."
        case .animateText: return fr ? "J'anime le titre." : "Animating the title."
        case .cutWords: return fr ? "Je coupe ce passage." : "Cutting that passage."
        case .syncToBeat: return fr ? "Je cale les coupes sur le rythme." : "Cutting to the beat."
        case .fitMusic: return fr ? "La musique finira avec la vidéo." : "The music will end with the video."
        case .blurFaces: return fr ? "Je floute les visages." : "Blurring the faces."
        case .smartReframe: return fr ? "Je recadre en suivant le sujet." : "Reframing around the subject."
        case .kenBurns: return fr ? "Mouvement de caméra ajouté." : "Camera move added."
        case .enhanceVoice: return fr ? "J'isole la voix." : "Cleaning up the voice."
        case .matchColor: return fr ? "J'harmonise les couleurs." : "Matching the colours."
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
        case .expandCanvas: return fr ? "J'agrandis le cadre et j'invente les bords." : "Expanding the frame and filling in the edges."
        case .moveObject: return fr ? "Je le déplace." : "Moving it."
        case .textBehind: return fr ? "Le texte passe derrière le sujet." : "The words go behind the subject."
        case .cleanUp: return fr ? "J'enlève les passants." : "Removing the passers-by."
        case .autoCrop: return fr ? "Je cherche le meilleur cadrage." : "Finding the best framing."
        case .blurObject: return fr ? "Je floute." : "Blurring it."
        case .fillCells: return tableFillReply(intent.table?.value, scope: tableScope(intent.table, fr: fr), fr: fr)
        case .clearCells: return fr ? "Je vide \(tableScope(intent.table, fr: true))." : "Clearing \(tableScope(intent.table, fr: false))."
        case .highlightCells:
            let scope = tableScope(intent.table, fr: fr)
            return fr ? (scope == "les cases" ? "Je surligne le tableau." : "Je surligne \(scope).") : (scope == "the cells" ? "Highlighting the table." : "Highlighting \(scope).")
        case .eraseRegion: return fr ? "J'efface cette zone." : "Erasing that area."
        case .moveText: return fr ? "Je déplace le texte." : "Moving the text."
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

    /// "Je remplis les cases avec 1." before a fill runs ("la colonne Opus 5" when one is named); the count
    /// line after it comes from Live.
    static func tableFillReply(_ value: CellValue?, scope: String, fr: Bool) -> String {
        switch value {
        case .constant(let text)?: return fr ? "Je remplis \(scope) avec \(text)." : "Filling \(scope) with \(text)."
        case .random?: return fr ? "Je remplis \(scope) avec des nombres au hasard." : "Filling \(scope) with random numbers."
        case .sequence?: return fr ? "Je numérote \(scope)." : "Numbering \(scope)."
        case .list?: return fr ? "Je mets ces valeurs dans \(scope)." : "Putting those values in \(scope)."
        case .plausible?: return fr ? "Je remplis \(scope) avec des valeurs plausibles." : "Filling \(scope) with plausible values."
        case nil: return fr ? "Je remplis \(scope)." : "Filling \(scope)."
        }
    }

    /// What a table step acts on, as said: "la colonne Opus 5", "la ligne Agentic coding", "la case Opus 5 / Agentic coding",
    /// "la dernière colonne", or "les cases".
    static func tableScope(_ spec: TableEditSpec?, fr: Bool) -> String {
        guard let spec else { return fr ? "les cases" : "the cells" }
        func name(_ ref: TableEditSpec.Ref, _ noun: String, _ nounEN: String) -> String {
            switch ref {
            case .name(let name): return fr ? "la \(noun) \(name)" : "the \(name) \(nounEN)"
            case .index(-1): return fr ? "la dernière \(noun)" : "the last \(nounEN)"
            case .index(1): return fr ? "la première \(noun)" : "the first \(nounEN)"
            case .index(let index): return fr ? "la \(noun) \(index)" : "\(nounEN) \(index)"
            }
        }
        switch (spec.rows.count, spec.columns.count) {
        case (0, 0): return fr ? "les cases" : "the cells"
        case (0, 1): return name(spec.columns[0], "colonne", "column")
        case (1, 0): return name(spec.rows[0], "ligne", "row")
        case (1, 1):
            if case .name(let column) = spec.columns[0], case .name(let row) = spec.rows[0] { return fr ? "la case \(column) / \(row)" : "the \(column) / \(row) cell" }
            return fr ? "cette case" : "that cell"
        default: return fr ? "ces cases" : "those cells"
        }
    }

    /// Three concrete things to try, shown when a request was not understood; table examples when the
    /// picture is a table.
    public static func suggestions(for mode: EditorMode, language: NormalizedUtterance.Language, hasTable: Bool) -> String {
        guard hasTable, mode == .photo else { return suggestions(for: mode, language: language) }
        let fr = language == .french
        let examples = fr ? ["Remplis les cases vides avec 0", "Surligne la dernière colonne", "Mets 90 % dans la première case"]
            : ["Fill the empty cells with 0", "Highlight the last column", "Put 90% in the first cell"]
        let joined = examples.map { fr ? "« \($0) »" : "“\($0)”" }.joined(separator: " · ")
        return (fr ? "Essayez : " : "Try: ") + joined
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
