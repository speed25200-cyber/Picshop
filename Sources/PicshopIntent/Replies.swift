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
        case .flip: return fr ? "Image retournée." : "Flipped."
        case .addText: return fr ? "Texte ajouté." : "Text added."
        case .editText: return fr ? "Texte modifié." : "Text updated."
        case .removeText: return fr ? "Texte supprimé." : "Text removed."
        case .upscale: return fr ? "J'augmente la résolution." : "Upscaling."
        case .denoise: return fr ? "Je réduis le bruit." : "Reducing noise."
        case .sharpen: return fr ? "Plus de netteté." : "Sharpening."
        case .relight: return fr ? "Je rééclaire la scène." : "Relighting."
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
        case .addMusic: return fr ? "Choisis une musique." : "Pick a track."
        case .removeMusic: return fr ? "Musique retirée." : "Music removed."
        case .extractFrame: return fr ? "Image extraite." : "Frame saved."
        case .seek: return fr ? "OK." : "OK."
        case .play: return fr ? "Lecture." : "Playing."
        case .pause: return fr ? "Pause." : "Paused."
        case .moveClip: return fr ? "Clip déplacé." : "Clip moved."
        case .stabilize: return fr ? "Je stabilise la vidéo." : "Stabilizing."
        case .freezeFrame: return fr ? "Arrêt sur image." : "Freeze frame added."
        case .chooseCandidate: return fr ? "Compris." : "Got it."
        case .confirm: return fr ? "OK." : "OK."
        case .cancel: return fr ? "Annulé." : "Cancelled."
        case .help: return fr ? "Dis par exemple : « efface le chien », « plus lumineux », « recadre en carré »." : "Try: “remove the dog”, “make it brighter”, “crop to square”."
        case .unknown: return fr ? "Je n'ai pas compris. Tu peux reformuler ?" : "I didn't catch that. Could you rephrase?"
        }
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
