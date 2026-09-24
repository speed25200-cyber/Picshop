import Foundation
import PicshopCore

public enum LiveLineKey: String, Sendable, CaseIterable { case greetingLocal, refusal, connectionLost, jobDone, jobCancelled, resume, stopping, running }

/// Every line Live speaks or captions on its own, in the language of the reply.
/// These are not L() keys: they follow the conversation, not the app locale.
public enum LiveLines {
    public static func line(_ key: LiveLineKey, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        switch key {
        case .greetingLocal: return fr ? "Je t'écoute. Dis-moi ce que tu veux changer." : "I'm listening. Tell me what to change."
        case .refusal: return fr ? "Je ne peux pas faire ça. Une autre idée ?" : "I can't do that one. Another idea?"
        case .connectionLost: return fr ? "La connexion a coupé — je continue sur l'iPhone." : "I lost the connection — carrying on on the iPhone."
        case .jobDone: return fr ? "C'est prêt." : "Done."
        case .jobCancelled: return fr ? "J'arrête." : "Stopping."
        case .resume: return fr ? "Touche l'orbe pour reprendre." : "Tap the orb to resume."
        case .stopping: return fr ? "À plus tard." : "See you later."
        case .running: return fr ? "Je m'en occupe, ça prend quelques secondes." : "On it, this takes a few seconds."
        }
    }

    public static func problem(_ problem: LiveProblem, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        switch problem {
        case .noMicrophone: return fr ? "Live a besoin du micro." : "Live needs the microphone."
        case .noSpeechRecognition(let code):
            let name = languageName(code, fr: fr)
            return fr ? "La dictée n'est pas disponible en \(name) — écris ta demande." : "Dictation isn't available in \(name) — type your request."
        case .offline: return fr ? "Pas de réseau — je continue sur l'iPhone." : "No network — carrying on on the iPhone."
        case .refusal: return line(.refusal, language)
        case .keyInvalid: return fr ? "Ta clé Claude est refusée — je continue sur l'iPhone." : "Your Claude key was refused — carrying on on the iPhone."
        case .noCredit: return fr ? "Crédit Anthropic épuisé — je continue sur l'iPhone." : "Your Anthropic credit has run out — carrying on on the iPhone."
        case .noAccess: return fr ? "Cette clé n'a pas accès à Claude Opus 5 — je continue sur l'iPhone." : "This key has no access to Claude Opus 5 — carrying on on the iPhone."
        case .rateLimited: return fr ? "Claude est très demandé — je réponds depuis l'iPhone pour l'instant." : "Claude is very busy — answering from the iPhone for now."
        case .unavailable: return fr ? "Claude ne répond pas — je continue sur l'iPhone." : "Claude isn't answering — carrying on on the iPhone."
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
