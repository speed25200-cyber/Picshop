import Foundation
@testable import PicshopIntent
@testable import PicshopCore

/// A French conversational prompt for the local model, with its rubric: the tool
/// a good answer calls (or none), the acceptable first edits, and whether idea
/// chips are expected. `reference` is one good answer in Qwen3.5's own output
/// format: the oracle the Linux run replays through LocalModelLiveBrain; the
/// real-model run on a device or a Mac scores the model's own answers instead.
struct LiveConversationCase: Sendable {
    enum Category: String, CaseIterable, Sendable { case vagueEdit, preciseEdit, undo, compare, opinion, question, offTopic }

    let text: String
    let category: Category
    /// The tool a good answer calls first; nil: it answers in words only.
    let tool: LiveToolName?
    /// Acceptable first actions of apply_edits (empty: any).
    var actions: Set<IntentAction> = []
    let expectsIdeas: Bool
    var mode: EditorMode = .photo
    let reference: String

    /// The longest spoken answer that still sounds like Live: 1–2 sentences.
    static let maxWords = 20

    var context: IntentContext {
        mode == .video ? IntentContext(mode: .video, clipCount: 3, playheadSeconds: 4, timelineDuration: 30) : IntentContext(mode: .photo, canUndo: true)
    }
}

/// What a rubric found wrong with one answer; empty means it passed.
enum LiveRubric {
    static func failures(_ testCase: LiveConversationCase, _ outcome: LiveEvalHarness.Outcome) -> [String] {
        var failures: [String] = []
        if let error = outcome.error { failures.append("error \(error)") }
        if outcome.end == nil { failures.append("never completed") }
        let spoken = outcome.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { failures.append("silent") }
        if spoken.contains(where: { "<>{}[]".contains($0) }) { failures.append("markup spoken: \(spoken)") }
        let words = spoken.split(whereSeparator: \.isWhitespace).count
        if words > LiveConversationCase.maxWords { failures.append("\(words) words") }
        switch testCase.tool {
        case nil:
            if !outcome.calls.isEmpty { failures.append("called \(outcome.firstTool?.rawValue ?? "?") for a \(testCase.category.rawValue)") }
        case let expected?:
            if outcome.firstTool != expected { failures.append("expected \(expected.rawValue), got \(outcome.firstTool?.rawValue ?? "no tool")") }
            if expected == .applyEdits, !testCase.actions.isEmpty {
                let action = outcome.firstIntent?.action
                if action.map({ !testCase.actions.contains($0) }) ?? true { failures.append("first edit \(action?.rawValue ?? "none")") }
            }
        }
        if testCase.expectsIdeas {
            if outcome.ideas.isEmpty || outcome.ideas.contains(where: { $0.steps.isEmpty || $0.source != .model }) { failures.append("no usable ideas") }
        } else if !outcome.ideas.isEmpty {
            failures.append("unasked ideas")
        }
        return failures
    }
}

/// 40 things a French speaker says to Live beyond plain commands.
enum LiveConversationCases {
    private static func call(_ name: String, _ parameters: [(String, String)] = []) -> String {
        "<tool_call>\n<function=\(name)>\n" + parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined() + "</function>\n</tool_call>"
    }

    private static func edit(_ sentence: String, _ steps: String) -> String {
        sentence + "\n\n" + call("apply_edits", [("steps", steps)])
    }

    private static func ideas(_ sentence: String) -> String {
        sentence + "\n\n" + call("propose_ideas", [("ideas", """
        [{"title": "Ciel plus dense", "why": "Le ciel est un peu pâle.", "symbol": "cloud.sun", "steps": [{"action": "selectiveAdjust", "target": "sky", "parameter": "saturation", "amount": 25}]}, \
        {"title": "Lumière dorée", "why": "Une ambiance de fin de journée.", "symbol": "sun.max", "steps": [{"action": "applyLook", "look": "goldenHour", "amount": 50}]}, \
        {"title": "Noir et blanc", "why": "Les contrastes s'y prêtent.", "symbol": "circle.lefthalf.filled", "steps": [{"action": "applyLook", "look": "mono", "amount": 100}]}]
        """)])
    }

    private static func e(_ text: String, _ category: LiveConversationCase.Category, _ actions: Set<IntentAction>, mode: EditorMode = .photo, _ reference: String) -> LiveConversationCase {
        LiveConversationCase(text: text, category: category, tool: .applyEdits, actions: actions, expectsIdeas: false, mode: mode, reference: reference)
    }

    private static func t(_ text: String, _ category: LiveConversationCase.Category, _ tool: LiveToolName, _ reference: String) -> LiveConversationCase {
        LiveConversationCase(text: text, category: category, tool: tool, expectsIdeas: tool == .proposeIdeas, reference: reference)
    }

    private static func say(_ text: String, _ category: LiveConversationCase.Category, _ reference: String) -> LiveConversationCase {
        LiveConversationCase(text: text, category: category, tool: nil, expectsIdeas: false, reference: reference)
    }

    static let all: [LiveConversationCase] = [
        // Vague wishes: the model picks 1–3 reasonable steps.
        e("donne-lui une ambiance cinéma un peu mélancolique", .vagueEdit, [.applyLook, .adjust],
          edit("Je lui donne un ton cinéma, un peu froid.", "[{\"action\": \"applyLook\", \"look\": \"cinematic\", \"amount\": 60}, {\"action\": \"adjust\", \"parameter\": \"temperature\", \"amount\": -10}]")),
        e("rends-la plus douce", .vagueEdit, [.adjust, .applyLook],
          edit("Je l'adoucis un peu.", "[{\"action\": \"adjust\", \"parameter\": \"contrast\", \"amount\": -15}, {\"action\": \"adjust\", \"parameter\": \"clarity\", \"amount\": -10}]")),
        e("je la trouve un peu terne", .vagueEdit, [.adjust, .applyLook, .autoEnhance],
          edit("Je lui redonne un peu d'éclat.", "[{\"action\": \"adjust\", \"parameter\": \"vibrance\", \"amount\": 20}]")),
        e("plus pop s'il te plaît", .vagueEdit, [.applyLook, .adjust],
          "C'est parti pour du peps.\n<tool_call>\n{\"name\": \"apply_edits\", \"arguments\": {\"steps\": [{\"action\": \"applyLook\", \"look\": \"punch\", \"amount\": 60}]}}\n</tool_call>"),
        e("fais quelque chose de plus chaleureux", .vagueEdit, [.adjust, .applyLook],
          edit("Je la réchauffe.", "[{\"action\": \"adjust\", \"parameter\": \"temperature\", \"amount\": 20}]")),
        e("un style plus rétro", .vagueEdit, [.applyLook],
          edit("Je lui donne un air vintage.", "[{\"action\": \"applyLook\", \"look\": \"vintage\", \"amount\": 70}]")),
        e("elle est trop sombre", .vagueEdit, [.adjust, .autoEnhance],
          edit("J'éclaircis un peu.", "[{\"action\": \"adjust\", \"parameter\": \"exposure\", \"amount\": 20}]")),
        e("un peu moins saturée", .vagueEdit, [.adjust],
          edit("Je baisse un peu les couleurs.", "[{\"action\": \"adjust\", \"parameter\": \"saturation\", \"amount\": \"-10\"}]")),
        e("ça manque de peps", .vagueEdit, [.adjust, .applyLook],
          edit("J'ajoute du contraste et des couleurs.", "[{\"action\": \"adjust\", \"parameter\": \"contrast\", \"amount\": 15}, {\"action\": \"adjust\", \"parameter\": \"vibrance\", \"amount\": 15}]")),
        e("donne-lui un côté coucher de soleil", .vagueEdit, [.applyLook, .adjust],
          "<think>\n\n</think>\n\n" + edit("Je lui donne une lumière dorée.", "[{\"action\": \"applyLook\", \"look\": \"goldenHour\", \"amount\": 60}]")),
        // Precise requests.
        e("passe-la en noir et blanc", .preciseEdit, [.applyLook],
          edit("Je la passe en noir et blanc.", "[{\"action\": \"applyLook\", \"look\": \"mono\", \"amount\": 100}]")),
        e("recadre-la en carré", .preciseEdit, [.crop, .setAspect],
          edit("Je la recadre en carré.", "[{\"action\": \"setAspect\", \"aspect\": \"square\"}]")),
        e("enlève le poteau à gauche", .preciseEdit, [.removeObject],
          edit("J'enlève le poteau.", "[{\"action\": \"removeObject\", \"target\": \"pole\", \"spatialHint\": \"left\"}]")),
        e("floute l'arrière-plan", .preciseEdit, [.blurBackground],
          edit("Je floute le fond.", "[{\"action\": \"blurBackground\", \"amount\": 50}]")),
        e("ajoute le titre « Été 2026 » en bas", .preciseEdit, [.addText],
          edit("J'ajoute le titre en bas.", "[{\"action\": \"addText\", \"text\": \"Été 2026\", \"placement\": \"bottom\"}]")),
        e("coupe les deux premières secondes", .preciseEdit, [.deleteRange, .trim], mode: .video,
          edit("Je coupe le début.", "[{\"action\": \"deleteRange\", \"startSeconds\": 0, \"endSeconds\": 2}]")),
        e("accélère un peu la vidéo", .preciseEdit, [.setSpeed], mode: .video,
          edit("J'accélère un peu.", "[{\"action\": \"setSpeed\", \"speed\": 1.5}]")),
        // Corrections.
        t("c'est trop", .undo, .undo, "Je reviens en arrière.\n" + call("undo")),
        t("non, annule ça", .undo, .undo, "D'accord, j'annule.\n" + call("undo", [("count", "1")])),
        t("reviens à l'original", .undo, .undo, "Je remets l'original.\n" + call("undo", [("to_original", "true")])),
        t("finalement remets-le", .undo, .undo, "Je le remets.\n" + call("undo", [("direction", "redo")])),
        // Before and after.
        t("montre-moi l'avant", .compare, .compareBeforeAfter, "Voici l'original.\n" + call("compare_before_after", [("seconds", "2")])),
        t("je peux voir la différence ?", .compare, .compareBeforeAfter, "Regarde, voici l'avant.\n" + call("compare_before_after")),
        t("c'était comment avant ?", .compare, .compareBeforeAfter, "Je te montre.\n" + call("compare_before_after", [("seconds", "3")])),
        // Opinions: one sentence, then ideas.
        t("tu en penses quoi ?", .opinion, .proposeIdeas, ideas("Belle lumière douce, mais le ciel manque de relief.")),
        t("qu'est-ce que tu ferais à ma place ?", .opinion, .proposeIdeas, ideas("Je densifierais le ciel, voici trois pistes.")),
        t("tu as des idées pour la rendre plus belle ?", .opinion, .proposeIdeas, ideas("Oui, trois idées pour elle.")),
        t("propose-moi quelque chose d'original", .opinion, .proposeIdeas, ideas("Tente le noir et blanc, ou une lumière dorée.")),
        t("elle te plaît ma photo ?", .opinion, .proposeIdeas, ideas("Oui, la composition est réussie ; on peut encore l'affiner.")),
        t("comment je pourrais l'améliorer ?", .opinion, .proposeIdeas, ideas("Le ciel pourrait être plus dense.")),
        t("quel style irait bien ?", .opinion, .proposeIdeas, ideas("Un style doré irait bien avec cette lumière.")),
        t("inspire-moi", .opinion, .proposeIdeas, ideas("Voici trois directions possibles.")),
        // Questions about the picture or editing: words only.
        say("c'est quoi la clarté ?", .question, "C'est le contraste des détails : l'image paraît plus nette ou plus douce."),
        say("pourquoi le ciel est tout blanc ?", .question, "Il est surexposé : la lumière y a tout brûlé."),
        say("tu vois combien de personnes ?", .question, "J'en vois deux, au centre de la photo."),
        say("ça sert à quoi le vignettage ?", .question, "Il assombrit les bords pour guider l'œil vers le sujet."),
        // Off topic: one friendly sentence, back to the picture.
        say("quel temps fait-il demain ?", .offTopic, "Je ne connais pas la météo, mais je peux ensoleiller ta photo !"),
        say("raconte-moi une blague", .offTopic, "Pourquoi l'appareil photo est zen ? Il garde toujours le déclic !"),
        say("tu t'appelles comment ?", .offTopic, "Je suis Picshop Live, ton assistant photo."),
        say("merci beaucoup !", .offTopic, "Avec plaisir ! Autre chose ?"),
    ]
}
