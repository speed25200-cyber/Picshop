import Foundation
import PicshopCore

/// The line under the orb while a tool runs ("Je retire le chien…" /
/// "Removing the dog…"), built from validated steps in the reply language.
public enum LiveActivityTitles {
    public static func title(for tool: LiveTool, language: NormalizedUtterance.Language) -> String? {
        let fr = language == .french
        switch tool {
        case .applyEdits(let intents):
            guard let first = intents.first else { return nil }
            return title(for: first, language: language)
        case .undo(_, let redo, let toOriginal):
            if toOriginal { return fr ? "Je reviens à l'original…" : "Back to the original…" }
            return redo ? (fr ? "Je rétablis…" : "Redoing…") : (fr ? "J'annule…" : "Undoing…")
        case .compare:
            return fr ? "Voici l'avant…" : "Here's the before…"
        case .proposeIdeas:
            return nil
        }
    }

    public static func title(for intent: EditIntent, language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        let thing = intent.target.map { object(for: $0.label, french: fr) }
        switch intent.action {
        case .removeObject: return fr ? "Je retire \(thing ?? "l'objet")…" : "Removing \(thing ?? "the object")…"
        case .moveObject: return fr ? "Je déplace \(thing ?? "l'objet")…" : "Moving \(thing ?? "the object")…"
        case .blurObject: return fr ? "Je floute \(thing ?? "les visages")…" : "Blurring \(thing ?? "the faces")…"
        case .recolor: return fr ? "Je recolore \(thing ?? "la zone")…" : "Recolouring \(thing ?? "the area")…"
        case .selectiveAdjust: return fr ? "Je retouche \(thing ?? "la zone")…" : "Retouching \(thing ?? "the area")…"
        case .adjust:
            let name = fr ? intent.parameter?.frenchName.lowercased() ?? "le réglage" : intent.parameter?.englishName.lowercased() ?? "the settings"
            return fr ? "Je règle \(name)…" : "Adjusting \(name)…"
        case .applyLook: return fr ? "J'applique le look \(intent.look?.frenchName ?? "")…" : "Applying the \(intent.look?.englishName ?? "") look…"
        case .autoEnhance: return fr ? "J'améliore l'image…" : "Enhancing…"
        case .removeBackground: return fr ? "Je détoure le sujet…" : "Cutting out the subject…"
        case .replaceBackground: return fr ? "Je change le fond…" : "Changing the background…"
        case .blurBackground: return fr ? "Je floute le fond…" : "Blurring the background…"
        case .crop, .setAspect, .autoCrop: return fr ? "Je recadre…" : "Cropping…"
        case .rotate, .straighten, .flip, .resetOrientation: return fr ? "Je redresse l'image…" : "Turning the picture…"
        case .addText, .editText, .textBehind: return fr ? "J'ajoute le texte…" : "Adding the text…"
        case .generativeFill: return fr ? "Je génère la zone…" : "Generating…"
        case .expandCanvas: return fr ? "J'agrandis le cadre…" : "Expanding the frame…"
        case .cleanUp: return fr ? "J'enlève les passants…" : "Removing passers-by…"
        case .upscale: return fr ? "J'augmente la résolution…" : "Upscaling…"
        case .relight: return fr ? "Je rééclaire la scène…" : "Relighting…"
        case .autoCaptions, .translateCaptions: return fr ? "Je sous-titre…" : "Captioning…"
        case .removeSilences: return fr ? "Je coupe les blancs…" : "Cutting the pauses…"
        case .removeFillers: return fr ? "J'enlève les « euh »…" : "Cutting the ums…"
        case .highlights: return fr ? "Je monte le résumé…" : "Building the highlights…"
        case .smartReframe: return fr ? "Je recadre en suivant le sujet…" : "Reframing on the subject…"
        case .enhanceVoice: return fr ? "Je nettoie la voix…" : "Cleaning the voice…"
        case .syncToBeat, .fitMusic, .addMusic, .autoDuck: return fr ? "Je cale la musique…" : "Fitting the music…"
        case .trim, .split, .deleteRange, .deleteClip: return fr ? "Je coupe…" : "Cutting…"
        default: return fr ? "Je m'en occupe…" : "On it…"
        }
    }

    /// "the dog" / "le chien" for the canonical labels Claude uses.
    static func object(for label: String, french: Bool) -> String {
        let table: [String: (String, String)] = [
            "person": ("la personne", "the person"), "people": ("les personnes", "the people"), "dog": ("le chien", "the dog"), "cat": ("le chat", "the cat"),
            "car": ("la voiture", "the car"), "sky": ("le ciel", "the sky"), "face": ("le visage", "the face"), "eyes": ("les yeux", "the eyes"),
            "teeth": ("les dents", "the teeth"), "text": ("le texte", "the text"), "sign": ("le panneau", "the sign"), "pole": ("le poteau", "the pole"),
            "wire": ("les fils", "the wires"), "background": ("le fond", "the background"), "tree": ("l'arbre", "the tree"), "bird": ("l'oiseau", "the bird"),
            "bag": ("le sac", "the bag"), "bottle": ("la bouteille", "the bottle"), "hair": ("les cheveux", "the hair"), "shirt": ("la chemise", "the shirt"),
            "grass": ("l'herbe", "the grass"), "water": ("l'eau", "the water"), "blemish": ("l'imperfection", "the blemish"), "object": ("l'objet", "the object"),
            "licence plate": ("la plaque", "the plate"), "screen": ("l'écran", "the screen"), "lamp": ("la lampe", "the lamp"), "trash": ("la poubelle", "the bin"),
        ]
        let key = label.lowercased()
        if let names = table[key] { return french ? names.0 : names.1 }
        return french ? "« \(label) »" : "the \(label)"
    }
}
