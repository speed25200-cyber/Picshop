import Foundation
import PicshopCore

public enum LiveLineKey: String, Sendable, CaseIterable {
    case greetingLocal, greetingLooking, refusal, lostThread, jobDone, jobCancelled, resume, stopping, running, micRestarted, modelLoading
}

/// Every line Live speaks or captions on its own, in the language of the reply.
/// These are not L() keys: they follow the conversation, not the app locale.
/// No line names a key, a network, a connection or a cloud service: Live runs on the iPhone.
public enum LiveLines {
    public static func line(_ key: LiveLineKey, _ language: NormalizedUtterance.Language) -> String {
        line(key, language, mode: .photo)
    }

    /// The same line, worded for the open editor (only greetingLooking differs).
    public static func line(_ key: LiveLineKey, _ language: NormalizedUtterance.Language, mode: EditorMode) -> String {
        let fr = language == .french
        switch key {
        case .greetingLocal: return fr ? "Je t'écoute. Dis-moi ce que tu veux changer." : "I'm listening. Tell me what to change."
        case .greetingLooking:
            if mode == .video { return fr ? "Je regarde ta vidéo…" : "Looking at your video…" }
            return fr ? "Je regarde ta photo…" : "Looking at your photo…"
        case .refusal: return fr ? "Je ne peux pas faire ça. Une autre idée ?" : "I can't do that one. Another idea?"
        case .lostThread: return fr ? "Je perds le fil — tu peux redire ?" : "I lost the thread — can you say that again?"
        case .jobDone: return fr ? "C'est prêt." : "Done."
        case .jobCancelled: return fr ? "J'arrête." : "Stopping."
        case .resume: return fr ? "Touche l'orbe pour reprendre." : "Tap the orb to resume."
        case .stopping: return fr ? "À plus tard." : "See you later."
        case .running: return fr ? "Je m'en occupe, ça prend quelques secondes." : "On it, this takes a few seconds."
        case .micRestarted: return fr ? "J'ai relancé le micro, je t'écoute." : "Mic restarted, I'm listening."
        case .modelLoading: return fr ? "Mon cerveau local se prépare — je fais au plus simple en attendant." : "My on-device brain is still loading — keeping it simple meanwhile."
        }
    }

    public static func problem(_ problem: LiveProblem, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        switch problem {
        case .noMicrophone: return fr ? "Live a besoin du micro." : "Live needs the microphone."
        case .noSpeechRecognition(let code):
            let name = languageName(code, fr: fr)
            return fr ? "La dictée n'est pas disponible en \(name) — écris ta demande." : "Dictation isn't available in \(name) — type your request."
        case .refusal: return line(.refusal, language)
        case .audioFailed: return fr ? "Le micro a décroché — je le relance." : "The microphone dropped — restarting it."
        case .voiceFailed: return fr ? "Ma voix ne sort pas — je t'écris mes réponses." : "My voice isn't coming out — I'll write my answers."
        case .notHearing: return fr ? "Je ne t'entends pas — parle plus près, ou touche l'orbe." : "I can't hear you — come closer, or tap the orb."
        case .brainTimeout: return fr ? "Je n'ai pas trouvé — tu peux le redire autrement ?" : "I couldn't work that out — can you say it another way?"
        case .modelUnavailable: return fr ? "Le modèle local n'a pas pu démarrer — je continue sans lui." : "The on-device model couldn't start — carrying on without it."
        case .unavailable: return fr ? "Un souci technique — réessaie ou écris ta demande." : "Something went wrong — try again or type it."
        }
    }

    public static func ideaApplied(_ title: String, _ language: NormalizedUtterance.Language) -> String {
        language == .french ? "« \(title) » appliqué." : "\(title) applied."
    }

    /// A short line while the brain thinks: the one after `last` in the list, so it never repeats twice in a row.
    public static func filler(_ language: NormalizedUtterance.Language, avoiding last: String?) -> String {
        let lines = language == .french ? frenchFillers : englishFillers
        guard let last, let index = lines.firstIndex(of: last) else { return lines[0] }
        return lines[(index + 1) % lines.count]
    }

    private static let frenchFillers = ["Mmh, voyons…", "Je regarde…", "Bonne question…", "Attends, je regarde la photo…", "Voyons voir…", "D'accord…"]
    private static let englishFillers = ["Hmm, let me see…", "Let me look…", "Good question…", "One sec, looking at the photo…", "Let's see…", "Okay…"]

    private static func languageName(_ code: String, fr: Bool) -> String {
        switch code.prefix(2).lowercased() {
        case "fr": return fr ? "français" : "French"
        case "en": return fr ? "anglais" : "English"
        case "es": return fr ? "espagnol" : "Spanish"
        case "de": return fr ? "allemand" : "German"
        case "it": return fr ? "italien" : "Italian"
        case "pt": return fr ? "portugais" : "Portuguese"
        default: return code
        }
    }
}
