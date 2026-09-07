import Foundation
import PicshopCore

/// Builds the instructions handed to on-device language models. Kept in one
/// place so the Foundation Models engine and the MLX engine describe the same
/// contract.
public enum IntentPrompt {
    public static let actionList: String = IntentAction.allCases.map(\.rawValue).joined(separator: ", ")
    public static let parameterList: String = AdjustmentParameter.allCases.map(\.rawValue).joined(separator: ", ")
    public static let lookList: String = FilterPreset.allCases.map(\.rawValue).joined(separator: ", ")
    public static let aspectList: String = AspectPreset.allCases.map(\.rawValue).joined(separator: ", ")
    public static let transitionList: String = TransitionKind.allCases.map(\.rawValue).joined(separator: ", ")
    public static let spatialList: String = SpatialHint.allCases.map(\.rawValue).joined(separator: ", ")
    public static let placementList: String = TextElement.Placement.allCases.map(\.rawValue).joined(separator: ", ")

    public static func systemInstructions(context: IntentContext) -> String {
        let modeDescription: String
        switch context.mode {
        case .photo: modeDescription = "The user is editing a PHOTO. Video-only actions are not allowed."
        case .video: modeDescription = "The user is editing a VIDEO timeline with \(context.clipCount) clip(s), total duration \(String(format: "%.1f", context.timelineDuration)) s, playhead at \(String(format: "%.1f", context.playheadSeconds)) s."
        }
        var pending = ""
        if let clarification = context.pendingClarification {
            let options = clarification.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" }.joined(separator: "; ")
            pending = "\nThe app just asked: \"\(clarification.question)\" with options [\(options)]. If the user answers that question, output a single chooseCandidate step with choiceIndex (1-based) or spatialHint, or cancel."
        }
        return """
        You are the command planner inside Picshop, a professional photo and video editor on iPhone. \
        Translate the user's spoken request (French or English) into a JSON plan the app executes. \
        Never chat, never explain, never refuse an editing request: output only the JSON object.

        \(modeDescription)\(pending)

        Output format (JSON, no markdown):
        {"steps":[{...}, ...],"reply":"<one short sentence in the user's language>","clarification":null|"<question if the request is truly ambiguous>","language":"fr"|"en"}

        Each step has "action" (one of: \(actionList)) plus only the fields it needs:
        - removeObject: target (canonical English noun such as dog, person, car, sign, pole, wire, text, blemish, object), spatialHint (\(spatialList)), ordinal, all (bool)
        - adjust: parameter (\(parameterList)), amountMode ("relative" for more/less, "absolute" for "set to"), amount (-100…100 percent). Brighter → brightness +20; darker → -20; a bit → ±10; a lot → ±40; too X → opposite direction.
        - applyLook: look (\(lookList)), amount (0–100 intensity). "noir et blanc"/"black and white" → mono.
        - autoEnhance, removeBackground, blurBackground (amount 0–100), replaceBackground (background: colour name or "transparent")
        - crop/setAspect: aspect (\(aspectList)); rotate: degrees (negative = counter-clockwise); straighten: degrees optional; flip: flipAxis (horizontal|vertical)
        - addText: text (verbatim, keep the user's language and casing), placement (\(placementList)), color; editText/removeText
        - upscale (amount 2|3|4), denoise, sharpen, relight
        - undo, redo, revert, compare, zoom, export, share, help, confirm, cancel
        - VIDEO ONLY: split (seconds), trim (startSeconds,endSeconds = part to KEEP), deleteRange (startSeconds,endSeconds = part to REMOVE), deleteClip (clipNumber 1-based), setSpeed (speed multiplier: 0.5 slow motion, 2 fast), reverse, mute, unmute, setVolume (amount), addTransition (transition: \(transitionList), scope "all" for every cut), removeTransition, addMusic (text: genre), removeMusic, extractFrame (seconds), seek (seconds), play, pause, duplicateClip, moveClip (clipNumber, choiceIndex = destination 1-based), stabilize, freezeFrame
        Several requests in one sentence become several steps, in order. \
        If the request is not an editing command, output {"steps":[{"action":"unknown"}],"reply":"…"}.
        """
    }

    public static let fewShotExamples: [(String, String)] = [
        ("efface le chien à gauche", #"{"steps":[{"action":"removeObject","target":"dog","spatialHint":"left"}],"reply":"J'efface le chien à gauche.","clarification":null,"language":"fr"}"#),
        ("make it a bit brighter and warmer", #"{"steps":[{"action":"adjust","parameter":"brightness","amountMode":"relative","amount":10},{"action":"adjust","parameter":"temperature","amountMode":"relative","amount":20}],"reply":"A touch brighter and warmer.","clarification":null,"language":"en"}"#),
        ("mets un fond blanc", #"{"steps":[{"action":"replaceBackground","background":"white"}],"reply":"Je mets un fond blanc.","clarification":null,"language":"fr"}"#),
        ("coupe les 3 premières secondes et accélère x2", #"{"steps":[{"action":"deleteRange","startSeconds":0,"endSeconds":3},{"action":"setSpeed","speed":2}],"reply":"Je coupe le début et j'accélère.","clarification":null,"language":"fr"}"#),
        ("add the text Summer 2026 at the top in yellow", #"{"steps":[{"action":"addText","text":"Summer 2026","placement":"top","color":"yellow"}],"reply":"Added your title.","clarification":null,"language":"en"}"#),
        ("enlève toutes les personnes en arrière-plan", #"{"steps":[{"action":"removeObject","target":"person","spatialHint":"background","all":true}],"reply":"J'efface les personnes en arrière-plan.","clarification":null,"language":"fr"}"#),
    ]

    public static func userPrompt(for utterance: String, hint: EditPlan?) -> String {
        var prompt = "Request: \"\(utterance)\""
        if let hint, !hint.isEmpty, hint.confidence >= 0.5 {
            let actions = hint.intents.map(\.action.rawValue).joined(separator: ", ")
            prompt += "\n(A fast parser guessed: \(actions). Use it only if it matches the request.)"
        }
        return prompt
    }
}
