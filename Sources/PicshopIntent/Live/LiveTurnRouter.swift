import Foundation
import PicshopCore

public enum LiveControlCommand: Sendable, Equatable { case stopTalking, endLive, repeatLast, startOver, cancelJob, chooseIdea(Int) }

public enum LiveLane: Sendable, Equatable { case control(LiveControlCommand), local(EditPlan), brain(isQuestion: Bool) }

/// Decides where a committed turn goes, in order: a control phrase; the local
/// grammar when it is the only brain; an answer to a pending choice; the brain
/// for a question or an opinion; the local fast lane for a confident, simple
/// command; else the brain.
public enum LiveTurnRouter {
    /// What the local lane may run without asking the brain.
    public static let instantActions: Set<IntentAction> = [
        .adjust, .applyLook, .autoEnhance, .rotate, .flip, .crop, .setAspect, .straighten, .resetOrientation, .undo, .redo, .revert, .compare,
        .zoom, .play, .pause, .seek, .setSpeed, .mute, .unmute, .setVolume,
    ]

    /// Table steps the grammar owns (D9): they take the local lane even with the model loaded, on
    /// longer sentences ("remplis les cases vides avec des nombres au hasard entre 50 et 90").
    public static let tableActions: Set<IntentAction> = [.fillCells, .clearCells, .highlightCells]
    /// The most words a table plan may have on the local lane.
    static let tableTokenLimit = 24

    public static func route(_ text: String, grammar: EditPlan, brain: LiveBrainKind, ideasOnScreen: Int, jobRunning: Bool, fastLane: Bool) -> LiveLane {
        let utterance = NormalizedUtterance(text)
        let tokens = utterance.tokens
        if let command = control(tokens, ideasOnScreen: ideasOnScreen, jobRunning: jobRunning) { return .control(command) }
        if brain == .local { return .local(grammar) }
        if answersPendingChoice(grammar) { return .local(grammar) }
        if isQuestion(text, tokens: tokens) { return .brain(isQuestion: true) }
        if fastLane, !grammar.isEmpty, grammar.confidence >= 0.9, grammar.clarification == nil, tokens.count <= 10,
           grammar.intents.allSatisfy({ instantActions.contains($0.action) }) {
            return .local(grammar)
        }
        if fastLane, !grammar.isEmpty, grammar.confidence >= 0.9, grammar.clarification == nil, tokens.count <= tableTokenLimit,
           grammar.intents.contains(where: { tableActions.contains($0.action) }),
           grammar.intents.allSatisfy({ tableActions.contains($0.action) || instantActions.contains($0.action) }),
           !namesOneCellLoosely(utterance, grammar) {
            return .local(grammar)
        }
        return .brain(isQuestion: false)
    }

    /// "le deuxième", "les deux": the grammar reads candidates only while a choice is
    /// pending, and no brain can pick one.
    public static func answersPendingChoice(_ grammar: EditPlan) -> Bool {
        !grammar.isEmpty && grammar.intents.allSatisfy { $0.action == .chooseCandidate }
    }

    /// "annule", "aucun" while a choice is pending: the host drops it; no brain can.
    /// The grammar also reads "laisse tomber" as cancel with nothing pending, so the caller checks.
    public static func dismissesPendingChoice(_ grammar: EditPlan) -> Bool {
        !grammar.isEmpty && grammar.intents.allSatisfy { $0.action == .cancel }
    }

    // MARK: Control phrases

    static func control(_ tokens: [String], ideasOnScreen: Int, jobRunning: Bool) -> LiveControlCommand? {
        guard !tokens.isEmpty else { return nil }
        let text = " " + tokens.joined(separator: " ") + " "
        func has(_ phrase: String) -> Bool { text.contains(" " + phrase + " ") }
        let short = tokens.count <= 4

        if has("arrete le mode live") || has("arrete live") || has("quitte le mode live") || has("ferme le mode live") || has("end live")
            || has("stop live") || has("exit live") || (short && (has("au revoir") || has("bye") || has("goodbye") || has("bye bye"))) {
            return .endLive
        }
        if has("on recommence") || has("recommencons") || has("start over") || has("nouvelle conversation") || has("new conversation") {
            return .startOver
        }
        if jobRunning, short, has("annule") || has("annuler") || has("cancel") || has("laisse tomber") || has("arrete ca") {
            return .cancelJob
        }
        if short, has("tais toi") || has("chut") || has("stop") || has("silence") || has("be quiet") || has("shut up") || tokens.allSatisfy({ $0 == "arrete" }) {
            return .stopTalking
        }
        if short || tokens.count <= 6, has("repete") || has("repeter") || has("repetes") || has("say that again") || has("repeat") || has("come again") {
            return .repeatLast
        }
        if ideasOnScreen > 0, let index = ideaReference(tokens, count: ideasOnScreen) {
            return .chooseIdea(index)
        }
        return nil
    }

    /// "la deuxième (idée)", "idea two", "the last one": a 1-based chip index.
    static func ideaReference(_ tokens: [String], count: Int) -> Int? {
        guard tokens.count <= 6 else { return nil }
        let ordinals: [String: Int] = [
            "premiere": 1, "premier": 1, "1ere": 1, "1er": 1, "deuxieme": 2, "seconde": 2, "second": 2, "2e": 2, "2eme": 2, "troisieme": 3, "3e": 3, "3eme": 3,
            "first": 1, "third": 3,
        ]
        let cardinals: [String: Int] = ["un": 1, "une": 1, "deux": 2, "trois": 3, "one": 1, "two": 2, "three": 3, "1": 1, "2": 2, "3": 3]
        let last: Set<String> = ["derniere", "dernier", "last"]
        let fillers: Set<String> = [
            "la", "le", "l", "the", "one", "idee", "idea", "option", "choix", "chip", "prends", "prend", "choisis", "choisir", "je", "veux", "voudrais",
            "take", "pick", "choose", "i", "want", "ll", "go", "with", "for", "avec", "celle", "celle-la", "ca", "number", "numero", "please", "stp",
            "ok", "oui", "yes", "vas", "y", "fais", "do", "applique", "apply", "let", "s", "on", "part", "pour", "c", "est", "that", "it", "is", "go", "alors",
        ]
        var index: Int?
        var namesAnIdea = false
        for token in tokens {
            if let value = ordinals[token] {
                index = value
            } else if last.contains(token) {
                index = count
            } else if let value = cardinals[token], tokens.contains(where: { ["idee", "idea", "option", "numero", "number"].contains($0) }) {
                index = value
            } else if !fillers.contains(token) {
                return nil
            }
            if ["idee", "idea", "option", "numero", "number"].contains(token) { namesAnIdea = true }
        }
        guard let index, (1...count).contains(index) else { return nil }
        // A bare cardinal ("deux") is too vague; an ordinal or a named idea is not.
        if !namesAnIdea, !tokens.contains(where: { ordinals[$0] != nil || last.contains($0) }) { return nil }
        return index
    }

    /// "la case …" said, but a table step that does not name one row and one column: the words and the plan
    /// disagree, so the model (or a question) decides, never the fast lane (the wrong cells are never filled
    /// silently).
    static func namesOneCellLoosely(_ utterance: NormalizedUtterance, _ grammar: EditPlan) -> Bool {
        guard RuleBasedIntentEngine.namesOneCellNoun(utterance) else { return false }
        return grammar.intents.contains { intent in
            guard tableActions.contains(intent.action), let spec = intent.table else { return false }
            return spec.rows.count != 1 || spec.columns.count != 1
        }
    }

    // MARK: Questions

    static let questionWords: Set<String> = [
        "pourquoi", "comment", "quel", "quelle", "quels", "quelles", "propose", "proposes", "proposer", "idee", "idees", "conseil", "conseils", "conseille",
        "aide", "aider", "why", "how", "what", "which", "suggest", "suggestion", "suggestions", "idea", "ideas", "advice", "think",
    ]
    static let questionPhrases = ["qu est ce", "est ce que", "tu penses", "tu trouves", "a ton avis", "do you", "should i", "would you", "what s", "t en penses"]

    static func isQuestion(_ text: String, tokens: [String]) -> Bool {
        // "tu peux mettre des 1 partout ?", "can you fill every cell?": a request, which the recognizer ends with "?".
        if PoliteRequest.isRequest(tokens) { return false }
        if text.contains("?") { return true }
        if tokens.contains(where: { questionWords.contains($0) }) { return true }
        let joined = " " + tokens.joined(separator: " ") + " "
        return questionPhrases.contains { joined.contains(" " + $0 + " ") }
    }
}
