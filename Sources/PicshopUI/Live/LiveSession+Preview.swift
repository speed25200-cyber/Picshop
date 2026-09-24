#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import PicshopCore
import PicshopIntent

extension LiveSession {
    public enum PreviewScenario: CaseIterable, Sendable { case resting, listening, hearing, thinking, speaking, acting, choices, problem, cycle }

    /// A scripted session for previews: no AppEnvironment, no audio, only timers.
    ///
    /// Each scenario holds one state, with a moving meter where it makes sense.
    /// `.cycle` goes through every state, a transcript, an activity with progress,
    /// three ideas, a choice request, a notice, an undo offer and the route badge.
    public static func preview(_ scenario: PreviewScenario, mode: EditorMode = .photo) -> LiveSession {
        let script = LivePreviewScript(mode: mode)
        return scripted(mode: mode) { elapsed in script.frame(scenario, at: elapsed) }
    }
}

/// Everything a scripted session shows at one instant.
struct LivePreviewFrame: Equatable {
    var state: LiveState = .off
    var isRunning = false
    var transcript = LiveTranscript()
    var ideas: LiveIdeasState = .loading
    var choices: LiveChoiceRequest?
    var activityTitle: String?
    var progress: Double?
    var route = LiveRoute()
    var isMuted = false
    var undoOffer: LiveUndoOffer?
    var reply: LiveReply?
    var notice: LiveNotice?
    var input: Double = 0
    var output: Double = 0
}

/// The preview's content: French, like the app's default language.
struct LivePreviewScript: Sendable {
    let mode: EditorMode
    let heuristicIdeas: [LiveIdea]
    let claudeIdeas: [LiveIdea]

    init(mode: EditorMode) {
        self.mode = mode
        switch mode {
        case .photo:
            heuristicIdeas = [
                LiveIdea(title: "Ciel plus vif", why: "Le ciel occupe le haut de la photo et manque de couleur.", symbol: "cloud.sun",
                         steps: [RawIntentStep(action: "adjust", parameter: "vibrance", amountMode: "relative", amount: 20)], source: .heuristic),
                LiveIdea(title: "Portrait doux", why: "Une personne au centre : un fond flou la détacherait.", symbol: "person.crop.circle",
                         steps: [RawIntentStep(action: "blurBackground", amount: 40)], source: .heuristic),
                LiveIdea(title: "Recadrage 4:5", why: "Le format idéal pour un post.", symbol: "crop",
                         steps: [RawIntentStep(action: "setAspect", aspect: "4:5")], source: .heuristic),
            ]
            claudeIdeas = [
                LiveIdea(title: "Lumière dorée", why: "Une fin de journée : un peu de chaleur la rendrait plus douce.", symbol: "sun.max",
                         steps: [RawIntentStep(action: "adjust", parameter: "temperature", amountMode: "relative", amount: 15)], source: .claude),
                LiveIdea(title: "Noir et blanc", why: "Les contrastes forts s'y prêtent bien.", symbol: "circle.lefthalf.filled",
                         steps: [RawIntentStep(action: "applyLook", look: "mono")], source: .claude),
                LiveIdea(title: "Plus de relief", why: "Les textures du mur ressortiraient.", symbol: "wand.and.stars",
                         steps: [RawIntentStep(action: "adjust", parameter: "clarity", amountMode: "relative", amount: 20)], source: .claude),
            ]
        case .video:
            heuristicIdeas = [
                LiveIdea(title: "Sous-titres", why: "On entend quelqu'un parler.", symbol: "captions.bubble",
                         steps: [RawIntentStep(action: "autoCaptions")], source: .heuristic),
                LiveIdea(title: "Format vertical", why: "Pour les stories et les reels.", symbol: "rectangle.portrait",
                         steps: [RawIntentStep(action: "smartReframe", aspect: "9:16")], source: .heuristic),
                LiveIdea(title: "Couper les blancs", why: "Quelques silences ralentissent le rythme.", symbol: "scissors",
                         steps: [RawIntentStep(action: "removeSilences")], source: .heuristic),
            ]
            claudeIdeas = [
                LiveIdea(title: "Musique douce", why: "Le montage n'a pas encore de musique.", symbol: "music.note",
                         steps: [RawIntentStep(action: "addMusic", text: "calm")], source: .claude),
                LiveIdea(title: "Look cinéma", why: "Des couleurs plus denses pour ces plans de coucher de soleil.", symbol: "film.stack",
                         steps: [RawIntentStep(action: "applyLook", look: "cinematic")], source: .claude),
                LiveIdea(title: "Ralenti final", why: "Le dernier plan mérite de durer.", symbol: "camera.aperture",
                         steps: [RawIntentStep(action: "speedRamp", amount: 0.5)], source: .claude),
            ]
        case .pdf:
            heuristicIdeas = [
                LiveIdea(title: "Surligner", why: "Mettre en valeur un passage.", symbol: "highlighter",
                         steps: [RawIntentStep(action: "highlightText")], source: .heuristic),
                LiveIdea(title: "Signer", why: "Le document a une ligne de signature.", symbol: "signature",
                         steps: [RawIntentStep(action: "addSignature")], source: .heuristic),
                LiveIdea(title: "Numéroter les pages", why: "Plusieurs pages sans numéro.", symbol: "textformat",
                         steps: [RawIntentStep(action: "addPageNumbers")], source: .heuristic),
            ]
            claudeIdeas = heuristicIdeas
        }
    }

    // MARK: Content

    private var request: String {
        mode == .video ? "Ajoute des sous-titres et coupe les silences" : "Enlève le chien à gauche et réchauffe un peu la lumière"
    }

    private var answer: [String] {
        mode == .video
            ? ["D'accord, j'ajoute les sous-titres.", "Ensuite je coupe les silences."]
            : ["Bonne idée, je retire le chien.", "Et je réchauffe la lumière d'un cran."]
    }

    private var activityTitle: String { mode == .video ? "Sous-titres automatiques" : "Suppression du chien" }

    private var undoLabel: String { mode == .video ? "Sous-titres" : "Supprimer le chien" }

    private var choiceRequest: LiveChoiceRequest {
        if mode == .video {
            return LiveChoiceRequest(question: "Quel clip ?", candidates: [.init(id: 1, label: "clip 1"), .init(id: 2, label: "clip 2"), .init(id: 3, label: "clip 3")], allowsAll: true)
        }
        return LiveChoiceRequest(question: "Quel chien ?", candidates: [.init(id: 1, label: "chien (gauche)"), .init(id: 2, label: "chien (centre)"), .init(id: 3, label: "chien (droite)")], allowsAll: true)
    }

    private let dictation = "Plus de contraste"

    // MARK: Frames

    func frame(_ scenario: LiveSession.PreviewScenario, at t: Double) -> LivePreviewFrame {
        var frame = LivePreviewFrame()
        frame.ideas = .ready(heuristicIdeas)
        switch scenario {
        case .resting:
            frame.ideas = t < 1.2 ? .loading : .ready(heuristicIdeas)
        case .listening:
            live(&frame, .listening, t)
        case .hearing:
            live(&frame, .hearing, t)
            frame.transcript = userTranscript(turn: 1, words: t.truncatingRemainder(dividingBy: 4) / 2.4, final: false, pausedAfter: 1)
            frame.input = speechLevel(t)
        case .thinking:
            live(&frame, .thinking, t)
            frame.transcript = userTranscript(turn: 1, words: 1, final: true)
            frame.route.isUploading = true
        case .speaking:
            live(&frame, .speaking, t)
            frame.transcript = userTranscript(turn: 1, words: 1, final: true)
            frame.transcript.assistant = answer[Int(t / 2.5) % answer.count]
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
            frame.output = voiceLevel(t)
        case .acting:
            live(&frame, .acting, t)
            frame.activityTitle = activityTitle
            frame.progress = min(1, t.truncatingRemainder(dividingBy: 4.5) / 4)
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
        case .choices:
            live(&frame, .listening, t)
            frame.choices = choiceRequest
        case .problem:
            frame.state = .problem(.noMicrophone)
            frame.notice = LiveNotice(id: 1, text: LiveLines.problem(.noMicrophone, .french), isProblem: true, action: .allowMicrophone)
        case .cycle:
            return mode == .pdf ? pdfCycle(t.truncatingRemainder(dividingBy: 9)) : cycle(t.truncatingRemainder(dividingBy: 37))
        }
        return frame
    }

    /// 37 s through every state of a Live conversation, then dictation outside Live.
    private func cycle(_ t: Double) -> LivePreviewFrame {
        var frame = LivePreviewFrame()
        frame.ideas = .ready(heuristicIdeas)
        switch t {
        case ..<2:
            frame.ideas = t < 1.2 ? .loading : .ready(heuristicIdeas)
        case ..<3:
            frame.state = .connecting
            frame.isRunning = true
        case ..<5:
            live(&frame, .listening, t)
        case ..<8:
            live(&frame, .hearing, t)
            frame.transcript = userTranscript(turn: 1, words: (t - 5) / 2.2, final: false, pausedAfter: 2.4 / 2.2)
            frame.input = t < 7.4 ? speechLevel(t) : 0.05
        case ..<9.5:
            live(&frame, .thinking, t)
            frame.transcript = userTranscript(turn: 1, words: 1, final: true)
            frame.route.isUploading = t < 8.9
        case ..<13.5:
            live(&frame, .speaking, t)
            frame.transcript = userTranscript(turn: 1, words: 1, final: true)
            frame.transcript.assistant = t < 11.5 ? answer[0] : answer[1]
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
            frame.output = voiceLevel(t)
        case ..<17:
            live(&frame, .acting, t)
            frame.activityTitle = activityTitle
            frame.progress = min(1, (t - 13.5) / 3.2)
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
        case ..<21:
            live(&frame, .listening, t)
            frame.ideas = .ready(claudeIdeas)
            frame.undoOffer = LiveUndoOffer(id: 1, label: undoLabel)
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
        case ..<25:
            live(&frame, .listening, t)
            frame.ideas = .ready(claudeIdeas)
            frame.choices = choiceRequest
            frame.route = LiveRoute(brain: .claude, sharesMedia: true, imagesSent: 1)
        case ..<26.6:
            frame.state = .problem(.offline)
            frame.isRunning = true
            frame.ideas = .ready(claudeIdeas)
            frame.notice = LiveNotice(id: 2, text: LiveLines.problem(.offline, .french), isProblem: true)
        case ..<28.6:
            live(&frame, .listening, t)
            frame.route = LiveRoute(brain: .onDevice)
            frame.isMuted = true
            frame.input = 0
        case ..<30:
            break
        case ..<33:
            frame.state = .dictating
            frame.transcript.turnID = 2
            frame.transcript.user = caption(dictation, words: (t - 30) / 1.6)
            frame.input = speechLevel(t)
        default:
            frame.reply = LiveReply(id: 1, text: "Contraste +15")
        }
        return frame
    }

    /// PDF cannot go Live: the orb dictates and the reply comes back in the capsule.
    private func pdfCycle(_ t: Double) -> LivePreviewFrame {
        var frame = LivePreviewFrame()
        frame.ideas = t < 1.2 ? .loading : .ready(heuristicIdeas)
        switch t {
        case ..<2:
            break
        case ..<5:
            frame.state = .dictating
            frame.transcript.user = caption("Surligne le titre", words: (t - 2) / 1.6)
            frame.input = speechLevel(t)
        default:
            frame.reply = LiveReply(id: 1, text: "Titre surligné")
        }
        return frame
    }

    // MARK: Helpers

    /// A running conversation on Claude, listening quietly.
    private func live(_ frame: inout LivePreviewFrame, _ state: LiveState, _ t: Double) {
        frame.state = state
        frame.isRunning = true
        frame.route = LiveRoute(brain: .claude)
        frame.input = state == .listening ? 0.06 + 0.03 * abs(sin(t * 2.1)) : 0.04
    }

    /// `words` 0...1: the share of the request heard so far. Past `pausedAfter`, the user is silent but not committed.
    private func userTranscript(turn: Int, words: Double, final: Bool, pausedAfter: Double = .infinity) -> LiveTranscript {
        var transcript = LiveTranscript()
        transcript.turnID = turn
        transcript.user = final ? LiveCaption(stable: request) : caption(request, words: words)
        transcript.userIsFinal = final
        transcript.userPaused = !final && words >= pausedAfter
        return transcript
    }

    /// The first `words` share of `text`: settled words, then a two-word volatile tail.
    private func caption(_ text: String, words: Double) -> LiveCaption {
        let all = text.split(separator: " ").map(String.init)
        let count = max(1, min(all.count, Int((Double(all.count) * max(0, words)).rounded(.up))))
        let heard = Array(all.prefix(count))
        guard count < all.count else { return LiveCaption(stable: heard.joined(separator: " ")) }
        let stable = heard.dropLast(min(2, heard.count))
        return LiveCaption(stable: stable.joined(separator: " "), volatile: heard.suffix(min(2, heard.count)).joined(separator: " "))
    }

    private func speechLevel(_ t: Double) -> Double {
        min(1, 0.3 + 0.45 * abs(sin(t * 7.3)) * abs(sin(t * 1.9)))
    }

    private func voiceLevel(_ t: Double) -> Double {
        min(1, 0.25 + 0.4 * abs(sin(t * 6.1)) * (0.6 + 0.4 * abs(sin(t * 1.4))))
    }
}
#endif
