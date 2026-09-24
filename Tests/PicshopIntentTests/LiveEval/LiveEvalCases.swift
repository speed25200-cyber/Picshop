import Foundation
@testable import PicshopIntent
@testable import PicshopCore

/// One thing a user might say during Live, and what a good answer does.
struct LiveEvalCase: Sendable {
    enum Category: String, CaseIterable, Sendable { case direct, vague, correction, reference, asr, question }

    enum Setup: Sendable {
        case photo
        case video
        /// Right after an adjustment of this parameter, in this direction.
        case after(AdjustmentParameter, Int)
        /// A "which one?" is pending with two dogs, left and right.
        case choice
    }

    let text: String
    let category: Category
    let setup: Setup
    /// Acceptable first actions; empty means nothing may be edited.
    let expected: Set<IntentAction>
    var parameter: AdjustmentParameter?
    /// +1 more, -1 less, 0 either.
    var direction = 0

    var mode: EditorMode {
        if case .video = setup { return .video }
        return .photo
    }

    var context: IntentContext {
        switch setup {
        case .photo:
            return IntentContext(mode: .photo)
        case .video:
            return IntentContext(mode: .video, clipCount: 3, playheadSeconds: 4, timelineDuration: 30)
        case .after(let parameter, let direction):
            var adjustments = Adjustments()
            adjustments[parameter] = 0.2 * Double(direction)
            return IntentContext(mode: .photo, currentAdjustments: adjustments, canUndo: true, lastParameter: parameter, lastAdjustmentDirection: direction)
        case .choice:
            let dogs = [ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.05, y: 0.4, width: 0.2, height: 0.3), confidence: 0.9),
                        ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.75, y: 0.4, width: 0.2, height: 0.3), confidence: 0.88)]
            let request = ClarificationRequest(question: "Lequel ?", candidates: dogs, pendingIntent: EditIntent(action: .removeObject, target: ObjectTarget(label: "dog")))
            return IntentContext(mode: .photo, pendingClarification: request)
        }
    }
}

private func c(_ text: String, _ category: LiveEvalCase.Category, _ expected: Set<IntentAction>, _ parameter: AdjustmentParameter? = nil,
               _ direction: Int = 0, setup: LiveEvalCase.Setup = .photo) -> LiveEvalCase {
    LiveEvalCase(text: text, category: category, setup: setup, expected: expected, parameter: parameter, direction: direction)
}

private func v(_ text: String, _ category: LiveEvalCase.Category, _ expected: Set<IntentAction>, _ parameter: AdjustmentParameter? = nil, _ direction: Int = 0) -> LiveEvalCase {
    c(text, category, expected, parameter, direction, setup: .video)
}

/// At least 200 French and English cases, seeded from docs/VOICE_COMMANDS.md, the parser
/// tests and the IntentPrompt few-shots. Categories: direct commands, vague wishes,
/// corrections, references, ASR errors, and questions that must not edit.
enum LiveEvalCases {
    static let all: [LiveEvalCase] = direct + vague + corrections + references + asr + questions

    static let direct: [LiveEvalCase] = [
        c("efface le chien à gauche", .direct, [.removeObject]),
        c("remove the dog", .direct, [.removeObject]),
        c("get rid of the power lines", .direct, [.removeObject]),
        c("enlève le poteau à droite", .direct, [.removeObject]),
        c("supprime toutes les personnes en arrière-plan", .direct, [.removeObject, .cleanUp]),
        c("remove all the people in the background", .direct, [.removeObject, .cleanUp]),
        c("efface la deuxième voiture", .direct, [.removeObject]),
        c("enlève le fond", .direct, [.removeBackground]),
        c("remove the background", .direct, [.removeBackground]),
        c("détoure le sujet", .direct, [.removeBackground]),
        c("mets un fond blanc", .direct, [.replaceBackground]),
        c("change the background to light blue", .direct, [.replaceBackground]),
        c("floute l'arrière-plan", .direct, [.blurBackground]),
        c("blur the background", .direct, [.blurBackground]),
        c("mode portrait", .direct, [.blurBackground]),
        c("plus lumineux", .direct, [.adjust], .brightness, 1),
        c("make it brighter", .direct, [.adjust], .brightness, 1),
        c("éclaircis un peu", .direct, [.adjust], .brightness, 1),
        c("augmente le contraste de 20", .direct, [.adjust], .contrast, 1),
        c("less contrast", .direct, [.adjust], .contrast, -1),
        c("réchauffe", .direct, [.adjust], .temperature, 1),
        c("warmer", .direct, [.adjust], .temperature, 1),
        c("cooler please", .direct, [.adjust], .temperature, -1),
        c("plus de couleurs", .direct, [.adjust], nil, 1),
        c("desaturate", .direct, [.adjust], .saturation, -1),
        c("débouche les ombres", .direct, [.adjust], .shadows, 1),
        c("recover the highlights", .direct, [.adjust], .highlights, -1),
        c("plus net", .direct, [.adjust, .sharpen]),
        c("reduce the noise", .direct, [.adjust, .denoise]),
        c("ajoute du grain", .direct, [.adjust], .grain, 1),
        c("enlève la vignette", .direct, [.adjust], .vignette),
        c("mets l'exposition à -20", .direct, [.adjust], .exposure),
        c("set brightness to 50", .direct, [.adjust], .brightness),
        c("rends le ciel plus bleu", .direct, [.selectiveAdjust]),
        c("make the sky bluer", .direct, [.selectiveAdjust]),
        c("éclaircis le visage", .direct, [.selectiveAdjust]),
        c("lisse la peau", .direct, [.selectiveAdjust]),
        c("whiten the teeth", .direct, [.selectiveAdjust]),
        c("noir et blanc", .direct, [.applyLook]),
        c("black and white", .direct, [.applyLook]),
        c("apply the cinematic look", .direct, [.applyLook]),
        c("filtre heure dorée", .direct, [.applyLook]),
        c("mets le filtre vintage", .direct, [.applyLook]),
        c("recadre en carré", .direct, [.crop, .setAspect]),
        c("crop to 16:9", .direct, [.crop, .setAspect]),
        c("format 4 par 5", .direct, [.crop, .setAspect]),
        c("tourne de 90 degrés vers la gauche", .direct, [.rotate]),
        c("rotate right", .direct, [.rotate]),
        c("redresse l'horizon", .direct, [.straighten]),
        c("flip it", .direct, [.flip]),
        c("retourne verticalement", .direct, [.flip]),
        c("recadre au mieux", .direct, [.autoCrop]),
        c("ajoute le texte Été 2026 en haut en jaune", .direct, [.addText]),
        c("add text saying Happy Birthday at the bottom", .direct, [.addText]),
        c("change le texte en Hello", .direct, [.editText]),
        c("remove the text", .direct, [.removeText]),
        c("augmente la résolution", .direct, [.upscale]),
        c("upscale it 3 times", .direct, [.upscale]),
        c("enlève les passants", .direct, [.cleanUp, .removeObject]),
        c("floute les visages", .direct, [.blurObject]),
        c("déplace la voiture un peu vers la droite", .direct, [.moveObject]),
        c("make the car red", .direct, [.recolor]),
        v("coupe ici", .direct, [.split]),
        v("split at 10 seconds", .direct, [.split]),
        v("coupe les 3 premières secondes", .direct, [.deleteRange, .trim]),
        v("remove the last 2 seconds", .direct, [.deleteRange, .trim]),
        v("garde seulement de 2 à 8 secondes", .direct, [.trim]),
        v("supprime le clip 2", .direct, [.deleteClip]),
        v("accélère x2", .direct, [.setSpeed]),
        v("slow motion", .direct, [.setSpeed, .speedRamp]),
        v("inverse la vidéo", .direct, [.reverse]),
        v("coupe le son", .direct, [.mute]),
        v("remets le son", .direct, [.unmute]),
        v("baisse le son de 20 %", .direct, [.setVolume]),
        v("ajoute un fondu enchaîné entre tous les clips", .direct, [.addTransition]),
        v("stabilise la vidéo", .direct, [.stabilize]),
        v("ajoute des sous-titres", .direct, [.autoCaptions]),
        v("traduis les sous-titres en anglais", .direct, [.translateCaptions]),
        v("enlève les blancs", .direct, [.removeSilences]),
        v("remove the ums", .direct, [.removeFillers]),
        v("cut to the beat", .direct, [.syncToBeat]),
        v("passe en vertical en suivant le sujet", .direct, [.smartReframe]),
        v("isole la voix", .direct, [.enhanceVoice]),
        v("make a 20 second recap", .direct, [.highlights]),
        v("va à 10 secondes", .direct, [.seek]),
    ]

    static let vague: [LiveEvalCase] = [
        c("c'est terne", .vague, [.adjust, .autoEnhance, .applyLook]),
        c("it looks dull", .vague, [.adjust, .autoEnhance, .applyLook]),
        c("it looks kind of flat and washed out", .vague, [.adjust, .autoEnhance]),
        c("c'est délavé", .vague, [.adjust, .autoEnhance]),
        c("la lumière est trop dure", .vague, [.adjust]),
        c("too harsh", .vague, [.adjust]),
        c("c'est jaunâtre", .vague, [.adjust], .temperature, -1),
        c("it's too blue", .vague, [.adjust], .temperature, 1),
        c("c'est tout bouché", .vague, [.adjust]),
        c("c'est trop sombre", .vague, [.adjust], nil, 1),
        c("it's too dark", .vague, [.adjust], nil, 1),
        c("c'est cramé", .vague, [.adjust], nil, -1),
        c("the colors are lifeless", .vague, [.adjust, .autoEnhance]),
        c("donne-lui du peps", .vague, [.adjust, .autoEnhance, .applyLook]),
        c("make it pop", .vague, [.adjust, .autoEnhance, .applyLook]),
        c("c'est moche", .vague, [.autoEnhance, .adjust]),
        c("fix it", .vague, [.autoEnhance]),
        c("do your magic", .vague, [.autoEnhance]),
        c("fais quelque chose", .vague, [.autoEnhance]),
        c("rends-la plus belle", .vague, [.autoEnhance, .adjust]),
        c("améliore la photo", .vague, [.autoEnhance]),
        c("c'est pour ma photo de profil LinkedIn", .vague, [.autoEnhance, .crop, .setAspect]),
        c("I need it for my profile picture", .vague, [.autoEnhance, .crop, .setAspect]),
        c("je veux la vendre sur vinted", .vague, [.replaceBackground, .autoEnhance]),
        c("product photo for ebay", .vague, [.replaceBackground, .autoEnhance]),
        c("photo d'identité", .vague, [.replaceBackground, .crop, .setAspect]),
        c("c'est pour mon fond d'écran", .vague, [.crop, .setAspect]),
        c("restaure cette vieille photo", .vague, [.autoEnhance, .adjust, .denoise]),
        c("photo de nuit, on ne voit rien", .vague, [.adjust, .autoEnhance]),
        c("le visage est trop sombre à contre-jour", .vague, [.adjust, .selectiveAdjust]),
        c("effet HDR", .vague, [.adjust]),
        c("rends-la plus esthétique", .vague, [.applyLook, .adjust, .autoEnhance]),
        c("un look plus cinéma", .vague, [.applyLook]),
        c("the sky is boring, do something about it", .vague, [.generativeFill, .selectiveAdjust]),
        c("un peu plus chaleureux", .vague, [.adjust], .temperature, 1),
        c("plus doux", .vague, [.adjust, .applyLook]),
        c("dreamy", .vague, [.adjust, .applyLook]),
        c("moody please", .vague, [.applyLook, .adjust]),
        v("la vidéo est trop longue", .vague, [.highlights, .removeSilences, .trim]),
        v("make it snappier", .vague, [.removeSilences, .setSpeed, .removeFillers]),
        v("c'est pour TikTok", .vague, [.smartReframe, .crop, .setAspect]),
        v("le son est pourri", .vague, [.enhanceVoice]),
    ]

    static let corrections: [LiveEvalCase] = [
        c("encore un peu", .correction, [.adjust], .brightness, 1, setup: .after(.brightness, 1)),
        c("a bit more", .correction, [.adjust], .brightness, 1, setup: .after(.brightness, 1)),
        c("encore", .correction, [.adjust], .contrast, 1, setup: .after(.contrast, 1)),
        c("beaucoup plus", .correction, [.adjust], .temperature, 1, setup: .after(.temperature, 1)),
        c("trop", .correction, [.adjust, .undo], nil, 0, setup: .after(.brightness, 1)),
        c("c'est trop", .correction, [.adjust, .undo], nil, 0, setup: .after(.saturation, 1)),
        c("too much", .correction, [.adjust, .undo], nil, 0, setup: .after(.contrast, 1)),
        c("way too much", .correction, [.adjust, .undo], nil, 0, setup: .after(.vibrance, 1)),
        c("pas assez", .correction, [.adjust], .brightness, 1, setup: .after(.brightness, 1)),
        c("less", .correction, [.adjust], .brightness, -1, setup: .after(.brightness, 1)),
        c("un peu moins", .correction, [.adjust], .temperature, -1, setup: .after(.temperature, 1)),
        c("non, moins", .correction, [.adjust], .contrast, -1, setup: .after(.contrast, 1)),
        c("annule", .correction, [.undo], setup: .after(.brightness, 1)),
        c("undo that", .correction, [.undo], setup: .after(.brightness, 1)),
        c("reviens en arrière", .correction, [.undo], setup: .after(.brightness, 1)),
        c("remets comme avant", .correction, [.undo, .revert], setup: .after(.brightness, 1)),
        c("go back to the original", .correction, [.revert], setup: .after(.brightness, 1)),
        c("refais", .correction, [.redo], setup: .after(.brightness, 1)),
        c("non, le chat", .correction, [.removeObject, .chooseCandidate], setup: .choice),
        c("the lamp instead", .correction, [.removeObject, .chooseCandidate], setup: .choice),
        c("plutôt en noir et blanc", .correction, [.applyLook]),
        c("non pas le chien, le chat", .correction, [.removeObject]),
        c("finalement plus froid", .correction, [.adjust], .temperature, -1),
        c("montre-moi l'avant", .correction, [.compare]),
        c("compare avec l'original", .correction, [.compare]),
    ]

    static let references: [LiveEvalCase] = [
        c("le deuxième", .reference, [.chooseCandidate], setup: .choice),
        c("celui de gauche", .reference, [.chooseCandidate], setup: .choice),
        c("the one on the right", .reference, [.chooseCandidate], setup: .choice),
        c("number 2", .reference, [.chooseCandidate], setup: .choice),
        c("les deux", .reference, [.chooseCandidate], setup: .choice),
        c("both", .reference, [.chooseCandidate], setup: .choice),
        c("le premier", .reference, [.chooseCandidate], setup: .choice),
        c("the first one", .reference, [.chooseCandidate], setup: .choice),
        c("un peu plus", .reference, [.adjust], .brightness, 1, setup: .after(.brightness, 1)),
        c("la même chose sur le ciel", .reference, [.selectiveAdjust], setup: .after(.saturation, 1)),
        c("comme tout à l'heure", .reference, [.adjust, .redo], setup: .after(.brightness, 1)),
        c("pareil en plus fort", .reference, [.adjust], .contrast, 1, setup: .after(.contrast, 1)),
        c("enlève-le", .reference, [.removeObject], setup: .choice),
        c("efface ça", .reference, [.removeObject]),
        c("remove this", .reference, [.removeObject]),
        v("ce clip", .reference, [.selectLayer, .seek, .deleteClip, .duplicateClip, .unknown]),
        v("supprime ce clip", .reference, [.deleteClip]),
        v("duplique le clip", .reference, [.duplicateClip]),
        v("move clip 2 to the beginning", .reference, [.moveClip]),
        v("mets la musique à 30 %", .reference, [.setVolume]),
    ]

    static let asr: [LiveEvalCase] = [
        c("plus lumineu", .asr, [.adjust], .brightness, 1),
        c("rend la plus chaude", .asr, [.adjust], .temperature, 1),
        c("met en noir est blanc", .asr, [.applyLook]),
        c("enlèv le chien", .asr, [.removeObject]),
        c("éfface le chien", .asr, [.removeObject]),
        c("floute larrière plan", .asr, [.blurBackground]),
        c("récadre en carré", .asr, [.crop, .setAspect]),
        c("plus de contraste euh", .asr, [.adjust], .contrast, 1),
        c("euh plus lumineux", .asr, [.adjust], .brightness, 1),
        c("mets un fond blanc s'il te plait", .asr, [.replaceBackground]),
        c("make it brighter please uh", .asr, [.adjust], .brightness, 1),
        c("remove the dog on the left side please", .asr, [.removeObject]),
        c("blur the back ground", .asr, [.blurBackground]),
        c("black and white filter", .asr, [.applyLook]),
        c("rotate it to the right", .asr, [.rotate]),
        c("tourne la à droite", .asr, [.rotate]),
        c("plus saturé", .asr, [.adjust], .saturation, 1),
        c("moin de saturation", .asr, [.adjust], .saturation, -1),
        c("réchauffe un peu la photo", .asr, [.adjust], .temperature, 1),
        c("ok alors enlève le poteau", .asr, [.removeObject]),
        v("coupe les trois premières secondes", .asr, [.deleteRange, .trim]),
        v("accélère deux fois", .asr, [.setSpeed]),
        v("enlève les heu", .asr, [.removeFillers]),
        v("sous titres", .asr, [.autoCaptions]),
        v("met la en vertical", .asr, [.smartReframe, .crop, .setAspect]),
    ]

    static let questions: [LiveEvalCase] = [
        c("tu penses quoi de la lumière ?", .question, []),
        c("qu'est-ce que tu ferais ?", .question, []),
        c("pourquoi c'est flou ?", .question, []),
        c("à ton avis, le ciel est trop bleu ?", .question, []),
        c("tu trouves que c'est trop saturé ?", .question, []),
        c("quel filtre irait bien ?", .question, []),
        c("comment je pourrais rendre ça plus pro ?", .question, []),
        c("t'as une idée pour le fond ?", .question, []),
        c("donne-moi un conseil", .question, []),
        c("propose-moi quelque chose", .question, []),
        c("what would you do?", .question, []),
        c("do you think it's too dark?", .question, []),
        c("should I crop it?", .question, []),
        c("which look fits best?", .question, []),
        c("why does it look grainy?", .question, []),
        c("any advice for the colours?", .question, []),
        c("how could I make this pop?", .question, []),
        c("what do you think of the composition?", .question, []),
        c("would you blur the background?", .question, []),
        c("suggest something for the sky", .question, []),
        c("c'est quoi la différence entre contraste et clarté ?", .question, []),
        c("est-ce que le recadrage est bien ?", .question, []),
        v("tu penses que la vidéo est trop longue ?", .question, []),
        v("which part should I cut?", .question, []),
        v("quelle musique irait bien ?", .question, []),
    ]
}
