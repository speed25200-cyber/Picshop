import Foundation
import PicshopCore

/// Builds the instructions handed to on-device language models. Kept in one
/// place so the Foundation Models engine and the MLX engine describe the same
/// contract. The instructions read like a retoucher's brief: the model is told
/// how photographers talk, how vague wishes map to concrete parameters, and
/// which everyday goals become which sequences of edits.
public enum IntentPrompt {
    public static let actionList: String = IntentAction.allCases.map(\.rawValue).joined(separator: ", ")
    public static let parameterList: String = AdjustmentParameter.allCases.map(\.rawValue).joined(separator: ", ")
    public static let lookList: String = FilterPreset.allCases.map(\.rawValue).joined(separator: ", ")
    public static let aspectList: String = AspectPreset.allCases.map(\.rawValue).joined(separator: ", ")
    public static let transitionList: String = TransitionKind.allCases.map(\.rawValue).joined(separator: ", ")
    public static let spatialList: String = SpatialHint.allCases.map(\.rawValue).joined(separator: ", ")
    public static let placementList: String = TextElement.Placement.allCases.map(\.rawValue).joined(separator: ", ")

    /// Instructions for one editor.
    ///
    /// Deliberately free of anything that changes while the user works: the
    /// clip count, the playhead, the current page and the pending question used
    /// to live here, which meant a reused model session kept answering from
    /// stale numbers. Those facts now travel with every request, and these
    /// instructions stay identical for the whole editing session so the model
    /// only has to read them once.
    public static func systemInstructions(mode: EditorMode) -> String {
        let modeDescription: String
        switch mode {
        case .photo: modeDescription = "The user is editing a PHOTO. Video-only actions are not allowed."
        case .video: modeDescription = "The user is editing a VIDEO timeline. Each request carries the current clip count, duration and playhead."
        case .pdf: modeDescription = "The user is editing a PDF. Each request carries the page count and the current page. Only PDF actions, text, undo/redo/export/help are allowed."
        }
        let photoGuide = mode == .photo ? photoInterpretationGuide : ""
        return """
        You are the command planner inside PicShop, a professional photo and video editor on iPhone. \
        Translate the user's spoken request (French or English) into a JSON plan the app executes. \
        Never chat, never explain, never refuse an editing request: output only the JSON object. \
        Understand what the user wants to achieve, not only the words: a vague wish ("it looks flat", "c'est moche") still becomes concrete steps.

        \(modeDescription)

        Output format (JSON, no markdown):
        {"steps":[{...}, ...],"reply":"<one short sentence in the user's language>","clarification":null|"<question if the request is truly ambiguous>","language":"fr"|"en"}

        Each step has "action" (one of: \(actionList)) plus only the fields it needs:
        - removeObject: target (canonical English noun such as dog, person, car, sign, pole, wire, text, blemish, object), spatialHint (\(spatialList)), ordinal, all (bool)
        - adjust: parameter (\(parameterList)), amountMode ("relative" for more/less, "absolute" for "set to"), amount (-100…100 percent). Brighter → brightness +20; darker → -20; a bit → ±10; a lot → ±40; too X → opposite direction.
        - selectiveAdjust: same as adjust plus target (the region: sky, face, background, eyes, teeth, grass…) when the change applies to one thing only ("make the sky bluer", "éclaircis le visage", "lisse la peau" → face + noiseReduction +50)
        - applyLook: look (\(lookList)), amount (0–100 intensity). "noir et blanc"/"black and white" → mono.
        - autoEnhance, removeBackground, blurBackground (amount 0–100), replaceBackground (background: colour name or "transparent")
        - crop/setAspect: aspect (\(aspectList)); rotate: degrees (negative = counter-clockwise); straighten: degrees optional; flip: flipAxis (horizontal|vertical)
        - addText: text (verbatim, keep the user's language and casing), placement (\(placementList)), color; editText/removeText
        - upscale (amount 2|3|4), denoise, sharpen, relight
        - generativeFill: target (region to replace, optional) + text (what to generate, in English); recolor: target + color ("make the car red")
        - PDF ONLY: deletePage/rotatePage(degrees)/movePage(choiceIndex = destination)/duplicatePage/insertBlankPage/goToPage (clipNumber = page number, -1 = last), highlightText/underlineText/redactText/findText (text), replaceText (text = words to replace, replacement = new words, or "" to erase the words; "remplace monsieur par madame", "efface le mot brouillon"), addSignature, extractPage, addPageNumbers, mergeDocument
        - undo, redo, revert, compare, zoom, export, share, help, confirm, cancel
        - saveVersion / restoreVersion (text = the version name; "enregistre cette version sous brouillon", "go back to version v1"); describe (PHOTO: what is in the picture); readPage (PDF: read the page aloud, clipNumber optional)
        - VIDEO ONLY: split (seconds), trim (startSeconds,endSeconds = part to KEEP), deleteRange (startSeconds,endSeconds = part to REMOVE), deleteClip (clipNumber 1-based), setSpeed (speed multiplier: 0.5 slow motion, 2 fast), reverse, mute, unmute, setVolume (amount), addTransition (transition: \(transitionList), scope "all" for every cut), removeTransition, addMusic (adds ANOTHER sound track — music, voice-over, sound effect; text: what kind, seconds: where it starts, scope "selection" to REPLACE the existing music instead), removeMusic (clipNumber = track number, -1 last, omit for all), moveAudio (clipNumber, seconds), fadeAudio (clipNumber, amount = fade length in seconds, text "in"|"out" or omit for both), mute/unmute with scope "selection" for a sound track (clipNumber) instead of a clip, setVolume with scope "selection" for a sound track (clipNumber, amountMode absolute for "à 50 %"), extractFrame (seconds), seek (seconds), play, pause, duplicateClip, moveClip (clipNumber, choiceIndex = destination 1-based), stabilize, freezeFrame
        Several requests in one sentence become several steps, in order; "but"/"mais" separates two requests ("brighter but less saturated"). \
        Negations and corrections apply to the last thing said ("not the dog, the cat" → the cat). \
        If the request is not an editing command, output {"steps":[{"action":"unknown"}],"reply":"…"}.\(photoGuide)
        """
    }

    /// How a retoucher reads everyday photo requests. Only sent in photo mode.
    static let photoInterpretationGuide: String = """


    How to read photo requests:
    - Subjective words map to parameters: dull/flat/terne/plat → contrast +15 and vibrance +20; washed out/délavé → contrast +20, saturation +15; \
    harsh light/lumière dure/blown out → highlights -30; muddy/bouché → blacks -15, shadows +15; noisy/grainy/bruité → noiseReduction +40; \
    soft/blurry/flou → sharpness +30, clarity +15; yellowish/jaunâtre/too warm → temperature -20; bluish/cold/froid → temperature +20; \
    greenish/verdâtre → tint +15; gloomy/morne/dark/sombre → brightness +20, shadows +15; too bright/cramé → exposure -20, highlights -20; \
    pale/pâle/lifeless/sans vie → vibrance +25; pop/punchy/peps → vibrance +20, contrast +10; moody → cinematic look; dreamy/doux → fade +20, clarity -15.
    - Photography vocabulary: golden hour → goldenHour look; bokeh/depth/portrait mode → blurBackground; high-key → brightness +20, highlights +10, contrast -10; \
    low-key → brightness -15, blacks -20, vignette +30; matte/faded film → matte look or fade +30; HDR → shadows +35, highlights -35, clarity +30; \
    backlit/contre-jour → shadows +40, highlights -20; night shot/low light → brightness +20, shadows +30, noiseReduction +30; skin smoothing/lisser la peau → selectiveAdjust face noiseReduction +50; \
    whiten teeth/blanchir les dents → selectiveAdjust teeth brightness +20; brighten eyes/éclaircir les yeux → selectiveAdjust eyes brightness +15.
    - Everyday goals become the sequence a retoucher would do: profile picture/photo de profil/avatar/LinkedIn → autoEnhance then crop square; \
    Instagram post → autoEnhance then crop ratio4x5; story/reel/TikTok/wallpaper → crop ratio9x16; product photo/photo produit/Vinted/eBay → replaceBackground white then autoEnhance; \
    ID or passport photo/photo d'identité → replaceBackground white then crop ratio3x4; restore an old photo/restaurer une vieille photo → autoEnhance, noiseReduction +40, sharpness +20; \
    "c'est moche"/"fix it"/"do your magic" → autoEnhance.
    - "Change the sky" without saying what → generativeFill target sky, text "a clear blue sky with soft white clouds". "Add a hat" → generativeFill with the object as text and the person as target. \
    A colour after "make the X" → recolor ("make the shirt red"). "Remove everything except X" → removeBackground.
    - Prefer selectiveAdjust when the user names a region (sky, face, background, hair, eyes, grass); prefer adjust when they talk about the whole picture. \
    Keep amounts modest unless the user says a lot / beaucoup / à fond.
    """

    public static let fewShotExamples: [(String, String)] = [
        ("efface le chien à gauche", #"{"steps":[{"action":"removeObject","target":"dog","spatialHint":"left"}],"reply":"J'efface le chien à gauche.","clarification":null,"language":"fr"}"#),
        ("make it a bit brighter and warmer", #"{"steps":[{"action":"adjust","parameter":"brightness","amountMode":"relative","amount":10},{"action":"adjust","parameter":"temperature","amountMode":"relative","amount":20}],"reply":"A touch brighter and warmer.","clarification":null,"language":"en"}"#),
        ("mets un fond blanc", #"{"steps":[{"action":"replaceBackground","background":"white"}],"reply":"Je mets un fond blanc.","clarification":null,"language":"fr"}"#),
        ("coupe les 3 premières secondes et accélère x2", #"{"steps":[{"action":"deleteRange","startSeconds":0,"endSeconds":3},{"action":"setSpeed","speed":2}],"reply":"Je coupe le début et j'accélère.","clarification":null,"language":"fr"}"#),
        ("add the text Summer 2026 at the top in yellow", #"{"steps":[{"action":"addText","text":"Summer 2026","placement":"top","color":"yellow"}],"reply":"Added your title.","clarification":null,"language":"en"}"#),
        ("enlève toutes les personnes en arrière-plan", #"{"steps":[{"action":"removeObject","target":"person","spatialHint":"background","all":true}],"reply":"J'efface les personnes en arrière-plan.","clarification":null,"language":"fr"}"#),
        ("it looks kind of flat and washed out", #"{"steps":[{"action":"adjust","parameter":"contrast","amountMode":"relative","amount":20},{"action":"adjust","parameter":"vibrance","amountMode":"relative","amount":20}],"reply":"Adding contrast and life to the colours.","clarification":null,"language":"en"}"#),
        ("j'en ai besoin pour ma photo de profil LinkedIn", #"{"steps":[{"action":"autoEnhance","amount":70},{"action":"crop","aspect":"square"}],"reply":"J'améliore la photo et je la recadre en carré.","clarification":null,"language":"fr"}"#),
        ("the sky is boring, do something about it", #"{"steps":[{"action":"generativeFill","target":"sky","text":"a dramatic sky with golden sunset clouds"}],"reply":"Giving you a dramatic sunset sky.","clarification":null,"language":"en"}"#),
        ("lisse un peu la peau et blanchis les dents", #"{"steps":[{"action":"selectiveAdjust","target":"face","parameter":"noiseReduction","amountMode":"relative","amount":30},{"action":"selectiveAdjust","target":"teeth","parameter":"brightness","amountMode":"relative","amount":20}],"reply":"Peau adoucie et dents éclaircies.","clarification":null,"language":"fr"}"#),
        ("brighter but less saturated", #"{"steps":[{"action":"adjust","parameter":"brightness","amountMode":"relative","amount":20},{"action":"adjust","parameter":"saturation","amountMode":"relative","amount":-20}],"reply":"Brighter, with calmer colours.","clarification":null,"language":"en"}"#),
        ("je veux la vendre sur vinted", #"{"steps":[{"action":"replaceBackground","background":"white"},{"action":"autoEnhance","amount":70}],"reply":"Fond blanc et photo améliorée pour l'annonce.","clarification":null,"language":"fr"}"#),
        ("ajoute un deuxième son à 10 secondes et baisse la musique à 30 %", #"{"steps":[{"action":"addMusic","seconds":10},{"action":"setVolume","scope":"selection","clipNumber":1,"amountMode":"absolute","amount":30}],"reply":"Deuxième piste à 10 s, musique à 30 %.","clarification":null,"language":"fr"}"#),
    ]

    /// The facts that change between two requests, sent with each one so a
    /// reused session never answers from a stale playhead or page number.
    public static func stateSummary(context: IntentContext) -> String {
        switch context.mode {
        case .photo:
            return ""
        case .video:
            return "Timeline: \(context.clipCount) clip(s), duration \(String(format: "%.1f", context.timelineDuration)) s, playhead at \(String(format: "%.1f", context.playheadSeconds)) s."
        case .pdf:
            return "Document: \(context.pageCount) page(s), currently on page \(context.currentPage)."
        }
    }

    public static func userPrompt(for utterance: String, context: IntentContext, hint: EditPlan?) -> String {
        var lines: [String] = []
        let state = stateSummary(context: context)
        if !state.isEmpty { lines.append(state) }
        if let clarification = context.pendingClarification {
            let options = clarification.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" }.joined(separator: "; ")
            lines.append("You just asked: \"\(clarification.question)\" with options [\(options)]. If the user answers that question, output a single chooseCandidate step with choiceIndex (1-based) or spatialHint, or cancel. If they name a different object instead, output the original action on that object.")
        }
        if let last = context.lastParameter {
            let direction = context.lastAdjustmentDirection < 0 ? "decreased" : "increased"
            lines.append("The previous edit \(direction) \(last.rawValue). Bare follow-ups such as \"more\", \"a bit more\", \"encore\", \"less\", \"too much\", \"trop\" refer to \(last.rawValue): \"too much\" means undo part of it (opposite direction, about 12), \"more\"/\"encore\" means the same direction again.")
        }
        lines.append("Request: \"\(utterance)\"")
        if let hint, !hint.isEmpty, hint.confidence >= 0.5 {
            let actions = hint.intents.map(\.action.rawValue).joined(separator: ", ")
            lines.append("(A fast parser guessed: \(actions). Use it only if it matches the request.)")
        }
        return lines.joined(separator: "\n")
    }
}
