import Foundation
import PicshopCore

public enum LiveLineKey: String, Sendable, CaseIterable {
    case greetingLocal, greetingLooking, refusal, lostThread, jobDone, jobCancelled, resume, stopping, running, micRestarted, modelLoading
    /// A question the rules alone cannot answer (Live without the model): nothing is edited.
    case cannotAnswerLocal
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
        case .cannotAnswerLocal:
            return fr ? "Sans le modèle, je ne sais pas répondre à ça — dis-moi ce que tu veux changer." : "Without the model I can't answer that — tell me what to change."
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

    // MARK: Outcomes (never the executor's raw text)

    /// What Live says after a step that did not do what was asked, from its reason code alone:
    /// one sentence, and an offer of the closest thing that works.
    public static func outcome(_ reason: ExecutionReason, action: IntentAction, hasTable: Bool, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        let tableAction = LiveTurnRouter.tableActions.contains(action)
        switch reason {
        case .noSubject:
            if hasTable {
                return fr ? "Sur une capture de tableau, il n'y a pas de sujet à détacher. Je remplis les cases à la place ?"
                    : "A table screenshot has no subject to cut out. Shall I fill the cells instead?"
            }
            return fr ? "Je ne vois personne à détacher sur cette photo." : "I can't see anyone to cut out in this photo."
        case .notFound:
            return fr ? "Je ne le trouve pas sur la photo — touche-le ou décris-le autrement." : "I can't find it in the photo — tap it or describe it another way."
        case .noTable:
            return fr ? "Je ne vois pas de tableau ici — recadre dessus et redis-le." : "I can't see a table here — crop to it and say it again."
        case .unknownRow:
            return fr ? "Je ne trouve pas cette ligne — dis-moi son nom tel qu'il est écrit." : "I can't find that row — tell me its name as it's written."
        case .unknownColumn:
            return fr ? "Je ne trouve pas cette colonne — dis-moi son nom tel qu'il est écrit." : "I can't find that column — tell me its name as it's written."
        case .ambiguous:
            return fr ? "Il y en a plusieurs — lequel veux-tu ?" : "There are several — which one do you mean?"
        case .nothingToDo:
            if tableAction { return fr ? "Ces cases sont déjà remplies." : "Those cells are already filled." }
            return fr ? "C'est déjà comme ça." : "It's already like that."
        case .tooMany:
            return fr ? "Ça fait plus de 400 cases — dis-moi une colonne ou une ligne." : "That's more than 400 cells — name a column or a row."
        case .needsSelection:
            return fr ? "Touche la zone ou entoure-la, et je m'en occupe." : "Tap or circle the area, and I'll take care of it."
        case .unsupported:
            return fr ? "Je ne sais pas encore faire ça ici." : "I can't do that here yet."
        case .unknownRef:
            return fr ? "Je ne retrouve plus ce texte — dis-moi lequel." : "I can't find that text any more — tell me which one."
        case .badRegion:
            return fr ? "Cette zone sort de l'image — montre-la-moi du doigt." : "That area is off the picture — point to it."
        case .noText:
            return fr ? "Je ne vois pas de texte à cet endroit." : "I can't see any text there."
        case .verifyFailed:
            return fr ? "C'est fait, mais le résultat ne se lit pas bien — je peux réessayer." : "Done, but the result doesn't read right — I can try again."
        }
    }

    /// The count line after a table step: "J'ai mis un 1 dans les 45 cases. Je peux mettre des chiffres
    /// au hasard à la place." What was kept and what is still empty are said when they matter.
    public static func tableDone(_ report: TableEditReport, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        let total = report.dataRows * report.dataColumns
        let everyCell = report.changed == total && total > 0
        let place: String
        if report.changed == 1 {
            place = fr ? "dans la case" : "in the cell"
        } else if everyCell {
            place = fr ? "dans les \(report.changed) cases" : "in all \(report.changed) cells"
        } else {
            place = fr ? "dans \(cells(report.changed, fr: true))" : "in \(cells(report.changed, fr: false))"
        }
        var line: String
        switch report.action {
        case .clearCells:
            line = fr ? "J'ai vidé \(cells(report.changed, fr: true))." : "I cleared \(cells(report.changed, fr: false))."
        case .highlightCells:
            line = fr ? "C'est surligné." : "Highlighted."
        default:
            if report.value == "style" {
                // A change of look only (fillCells with no value): the words stay.
                return fr ? "J'ai changé le style \(report.changed == 1 ? "de la case" : "des \(report.changed) cases")." : "I restyled \(report.changed == 1 ? "the cell" : "the \(report.changed) cells")."
            }
            if let value = report.value.map(spokenValue) {
                line = fr ? "J'ai mis \(value.french) \(place)." : "I put \(value.english) \(place)."
            } else {
                line = fr ? "J'ai rempli \(cells(report.changed, fr: true))." : "I filled \(cells(report.changed, fr: false))."
            }
            if report.kept > 0 {
                line += fr ? " \(report.kept == 1 ? "Une case était déjà remplie, j'ai gardé sa valeur" : "\(report.kept) cases étaient déjà remplies, j'ai gardé leurs valeurs")."
                    : " \(report.kept == 1 ? "One cell was" : "\(report.kept) cells were") already filled; I kept \(report.kept == 1 ? "its value" : "their values")."
            }
            if report.emptyLeft > 0, !everyCell {
                line += fr ? " Il reste \(cells(report.emptyLeft, fr: true)) \(report.emptyLeft == 1 ? "vide" : "vides")."
                    : " \(cells(report.emptyLeft, fr: false).capitalizedFirst) still empty."
            }
            if let alternative = report.alternative.map(spokenValue) {
                line += fr ? " Je peux mettre \(alternative.french) à la place." : " I can put \(alternative.english) instead."
            }
        }
        return line
    }

    /// How a value reads in a sentence: "1" → "un 1" / "a 1"; "random 50–90" → "des nombres au hasard entre 50 et 90".
    static func spokenValue(_ value: String) -> (french: String, english: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "random" { return ("des chiffres au hasard", "random numbers") }
        if trimmed.hasPrefix("random ") {
            let bounds = trimmed.dropFirst("random ".count).split(whereSeparator: { $0 == "–" || $0 == "-" }).map(String.init)
            if bounds.count == 2 { return ("des nombres au hasard entre \(bounds[0]) et \(bounds[1])", "random numbers between \(bounds[0]) and \(bounds[1])") }
            return ("des nombres au hasard", "random numbers")
        }
        switch trimmed {
        case "sequence": return ("des numéros qui se suivent", "numbers in sequence")
        case "list": return ("tes valeurs", "your values")
        case "plausible": return ("des valeurs crédibles", "plausible values")
        default: break
        }
        if trimmed.count <= 3, trimmed.allSatisfy(\.isNumber) {
            let an = trimmed.hasPrefix("8") || trimmed == "11" || trimmed == "18"
            return ("un \(trimmed)", "\(an ? "an" : "a") \(trimmed)")
        }
        return ("« \(trimmed) »", "“\(trimmed)”")
    }

    /// The honest sentence once a result still fails its check after the repair round, in the user's words:
    /// "C'est fait en partie : 3 cases sur 45 ne se lisent pas bien."
    public static func verification(_ report: VerificationReport, _ language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        guard report.status == .failed else { return fr ? "C'est fait." : "Done." }
        let failures = report.failures
        let cellsFailing = failures.filter { $0.check.tag.hasPrefix("r") && $0.check.tag.contains("c") }.count
        if cellsFailing > 0 {
            let cellTotal = report.items.filter { $0.check.tag.hasPrefix("r") && $0.check.tag.contains("c") }.count
            if report.action == .clearCells {
                return fr ? "J'ai vidé les cases, mais \(cellsFailing) sur \(cellTotal) montrent encore du texte — vérifie-les."
                    : "I cleared the cells, but \(cellsFailing) of \(cellTotal) still show some text — worth a check."
            }
            return fr ? "C'est fait en partie : \(cells(cellsFailing, fr: true)) sur \(cellTotal) ne se \(cellsFailing == 1 ? "lit" : "lisent") pas bien — vérifie-\(cellsFailing == 1 ? "la" : "les")."
                : "Partly done: \(cellsFailing) of \(cellTotal) cells don't read right — worth a check."
        }
        switch failures.first?.check.kind {
        case .textPresent?:
            return fr ? "J'ai écrit le texte, mais il ne se lit pas bien à cet endroit." : "I wrote the text, but it doesn't read well there."
        case .textAbsent?:
            // A rewrite or a move left the old words showing; an erase left some text.
            if report.action == .editText || report.action == .moveText {
                return fr ? "J'ai réécrit le texte, mais l'ancien se voit encore." : "I rewrote the text, but the old one still shows."
            }
            return fr ? "J'ai effacé, mais il reste du texte visible." : "I erased it, but some text still shows."
        case .objectAbsent?:
            return fr ? "Je l'ai retiré, mais on le voit encore un peu." : "I removed it, but it still shows a little."
        case nil:
            return fr ? "C'est fait, mais le résultat ne se lit pas comme prévu." : "Done, but the result doesn't read as planned."
        }
    }

    static func cells(_ count: Int, fr: Bool) -> String {
        if fr { return count == 1 ? "1 case" : "\(count) cases" }
        return count == 1 ? "1 cell" : "\(count) cells"
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

extension String {
    /// "3 cells" → "3 cells", "one" → "One".
    var capitalizedFirst: String { String(self.prefix(1)).uppercased() + self.dropFirst() }
}
