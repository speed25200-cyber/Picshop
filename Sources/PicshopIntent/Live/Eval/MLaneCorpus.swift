import Foundation
import PicshopCore

/// One single-turn W2 photo request of the M lane (§8.10): what a right answer runs (`gold`: catalog ids, a legacy
/// action by its raw value; empty: an honest refusal, nothing may change), the arguments it carries (values
/// normalised: numbers by their sign, text lower-cased, lists sorted), the editor state before the turn, and a
/// good answer in Qwen3.5's format for the scripted replay on Linux.
public struct MLaneCase: Sendable {
    public enum Setup: String, Sendable {
        case none
        /// Two masks: a1 the sky (exposure −10), a2 the bottom (exposure −20).
        case masks
        /// The subject selected.
        case selection
    }

    public var text: String
    public var gold: Set<String>
    public var args: [String: String]
    public var setup: Setup
    public var reference: String

    public init(_ text: String, gold: Set<String>, args: [String: String], setup: Setup, reference: String) {
        self.text = text
        self.gold = gold
        self.args = args
        self.setup = setup
        self.reference = reference
    }

    public var language: NormalizedUtterance.Language { NormalizedUtterance(text).language }
    /// Nothing may change: the right answer says why.
    public var isRefusal: Bool { gold.isEmpty }
}

/// The M lane's corpus (W2): mask and selection requests written apart from the catalog's examples (the four
/// signature phrases excepted), on the lake photo, French and English, with honest refusals.
public enum MLaneCorpus {
    /// The four signature phrases (§8 acceptance), which are also catalog examples.
    public static let signaturePhrases = ["éclaircis le ciel", "assombris le bas", "plus de contraste sur le sujet", "sélectionne la tasse bleue"]

    static func answer(_ sentence: String, _ steps: String?) -> String {
        guard let steps else { return sentence }
        return LiveDialogueCases.edit(sentence, steps)
    }

    public static let all: [MLaneCase] = [
        MLaneCase("éclaircis le ciel", gold: ["maskAdjust", "selectiveAdjust"], args: ["where": "sky"], setup: .none, reference: answer("J'éclaircis le ciel.", #"[{"action":"maskAdjust","where":"sky","parameter":"exposure","amount":20}]"#)),
        MLaneCase("assombris le bas", gold: ["maskAdjust"], args: ["where": "bottom", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("J'assombris le bas.", #"[{"action":"maskAdjust","where":"bottom","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("plus de contraste sur le sujet", gold: ["maskAdjust"], args: ["where": "subject", "parameter": "contrast", "amount": "+"], setup: .none, reference: answer("Plus de contraste sur le sujet.", #"[{"action":"maskAdjust","where":"subject","parameter":"contrast","amount":20}]"#)),
        MLaneCase("sélectionne la tasse bleue", gold: ["select"], args: ["what": "object", "target": "cup", "attributes": "blue"], setup: .none, reference: answer("Je sélectionne la tasse.", #"[{"action":"select","what":"object","target":"cup","attributes":["blue"],"box":[620,620,740,780]}]"#)),
        MLaneCase("baisse un peu la lumière du ciel", gold: ["maskAdjust", "selectiveAdjust"], args: ["where": "sky", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("Je baisse le ciel.", #"[{"action":"maskAdjust","where":"sky","parameter":"exposure","amount":-10}]"#)),
        MLaneCase("le haut est trop clair", gold: ["maskAdjust"], args: ["where": "top", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("J'assombris le haut.", #"[{"action":"maskAdjust","where":"top","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("réchauffe juste la personne", gold: ["maskAdjust"], args: ["where": "person", "parameter": "temperature", "amount": "+"], setup: .none, reference: answer("Je réchauffe la personne.", #"[{"action":"maskAdjust","where":"person","parameter":"temperature","amount":20}]"#)),
        MLaneCase("donne du peps à l'eau", gold: ["maskAdjust"], args: ["where": "water", "parameter": "saturation", "amount": "+"], setup: .none, reference: answer("Je ravive l'eau.", #"[{"action":"maskAdjust","where":"water","parameter":"saturation","amount":20}]"#)),
        MLaneCase("refroidis le fond de la photo", gold: ["maskAdjust"], args: ["where": "background", "parameter": "temperature", "amount": "-"], setup: .none, reference: answer("Je refroidis le fond.", #"[{"action":"maskAdjust","where":"background","parameter":"temperature","amount":-20}]"#)),
        MLaneCase("fonce un peu les coins de l'image", gold: ["maskAdjust"], args: ["where": "edges", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("J'assombris les coins.", #"[{"action":"maskAdjust","where":"edges","parameter":"exposure","amount":-10}]"#)),
        MLaneCase("plus de clarté au centre", gold: ["maskAdjust"], args: ["where": "center", "parameter": "clarity", "amount": "+"], setup: .none, reference: answer("Plus de clarté au centre.", #"[{"action":"maskAdjust","where":"center","parameter":"clarity","amount":20}]"#)),
        MLaneCase("éclaircis les ombres du sujet", gold: ["maskAdjust"], args: ["where": "subject", "parameter": "shadows", "amount": "+"], setup: .none, reference: answer("Je débouche les ombres du sujet.", #"[{"action":"maskAdjust","where":"subject","parameter":"shadows","amount":20}]"#)),
        MLaneCase("les tons chair un peu plus chauds", gold: ["maskAdjust"], args: ["where": "skintones", "parameter": "temperature", "amount": "+"], setup: .none, reference: answer("Je réchauffe les tons chair.", #"[{"action":"maskAdjust","where":"skinTones","parameter":"temperature","amount":10}]"#)),
        MLaneCase("calme les hautes lumières dans le ciel", gold: ["maskAdjust", "selectiveAdjust"], args: ["where": "sky", "parameter": "highlights", "amount": "-"], setup: .none, reference: answer("Je calme les hautes lumières du ciel.", #"[{"action":"maskAdjust","where":"sky","parameter":"highlights","amount":-20}]"#)),
        MLaneCase("mets un filtre gradué sombre en bas", gold: ["maskAdjust"], args: ["where": "bottom", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("Un dégradé sombre en bas.", #"[{"action":"maskAdjust","where":"bottom","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("un filtre radial lumineux sur la personne", gold: ["maskAdjust"], args: ["parameter": "exposure", "amount": "+"], setup: .none, reference: answer("Un filtre radial sur la personne.", #"[{"action":"maskAdjust","where":"center","center":[240,610],"radius":30,"parameter":"exposure","amount":20}]"#)),
        MLaneCase("désature le premier plan", gold: ["maskAdjust"], args: ["where": "near", "parameter": "saturation", "amount": "-"], setup: .none, reference: answer("Je désature le premier plan.", #"[{"action":"maskAdjust","where":"near","parameter":"saturation","amount":-20}]"#)),
        MLaneCase("assombris ce qui est loin", gold: ["maskAdjust"], args: ["where": "far", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("J'assombris le lointain.", #"[{"action":"maskAdjust","where":"far","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("fais briller les yeux", gold: ["maskAdjust", "selectiveAdjust"], args: ["where": "eyes", "parameter": "exposure", "amount": "+"], setup: .none, reference: answer("J'éclaire les yeux.", #"[{"action":"maskAdjust","where":"eyes","parameter":"exposure","amount":15}]"#)),
        MLaneCase("rends les lèvres plus roses", gold: ["maskAdjust"], args: ["where": "lips", "parameter": "saturation", "amount": "+"], setup: .none, reference: answer("Je ravive les lèvres.", #"[{"action":"maskAdjust","where":"lips","parameter":"saturation","amount":20}]"#)),
        MLaneCase("sur le masque 2 mets plus de contraste", gold: ["maskAdjust"], args: ["ref": "a2", "parameter": "contrast", "amount": "+"], setup: .masks, reference: answer("Plus de contraste en bas.", #"[{"action":"maskAdjust","ref":"a2","parameter":"contrast","amount":20}]"#)),
        MLaneCase("le premier masque encore plus sombre", gold: ["maskAdjust"], args: ["ref": "a1", "parameter": "exposure", "amount": "-"], setup: .masks, reference: answer("Encore plus sombre.", #"[{"action":"maskAdjust","ref":"a1","parameter":"exposure","amount":-10}]"#)),
        MLaneCase("inverse le deuxième masque", gold: ["maskEdit"], args: ["ref": "a2", "invert": "true"], setup: .masks, reference: answer("J'inverse ce masque.", #"[{"action":"maskEdit","ref":"a2","invert":true}]"#)),
        MLaneCase("adoucis bien la transition du masque du ciel", gold: ["maskEdit"], args: ["ref": "a1", "feather": "+"], setup: .masks, reference: answer("J'adoucis le masque du ciel.", #"[{"action":"maskEdit","ref":"a1","feather":70}]"#)),
        MLaneCase("retire la personne du masque du bas", gold: ["maskEdit"], args: ["ref": "a2", "combine": "subtract", "where": "person"], setup: .masks, reference: answer("J'enlève la personne du masque.", #"[{"action":"maskEdit","ref":"a2","combine":"subtract","where":"person"}]"#)),
        MLaneCase("ajoute l'eau au masque du ciel", gold: ["maskEdit"], args: ["ref": "a1", "combine": "add", "where": "water"], setup: .masks, reference: answer("J'ajoute l'eau au masque.", #"[{"action":"maskEdit","ref":"a1","combine":"add","where":"water"}]"#)),
        MLaneCase("masque le masque 1 un moment", gold: ["maskEdit"], args: ["ref": "a1", "visible": "false"], setup: .masks, reference: answer("Je le cache.", #"[{"action":"maskEdit","ref":"a1","visible":false}]"#)),
        MLaneCase("baisse l'effet du masque 2 à moitié", gold: ["maskEdit"], args: ["ref": "a2", "amount": "+"], setup: .masks, reference: answer("À moitié.", #"[{"action":"maskEdit","ref":"a2","amount":50}]"#)),
        MLaneCase("jette le masque du ciel", gold: ["maskDelete"], args: ["ref": "a1"], setup: .masks, reference: answer("Je le supprime.", #"[{"action":"maskDelete","ref":"a1"}]"#)),
        MLaneCase("enlève tous mes masques", gold: ["maskDelete"], args: ["all": "true"], setup: .masks, reference: answer("Je les supprime tous.", #"[{"action":"maskDelete","all":true}]"#)),
        MLaneCase("mets le sujet en sélection", gold: ["select"], args: ["what": "subject"], setup: .none, reference: answer("Je sélectionne le sujet.", #"[{"action":"select","what":"subject"}]"#)),
        MLaneCase("sélectionne toute l'eau", gold: ["select"], args: ["what": "water"], setup: .none, reference: answer("Je sélectionne l'eau.", #"[{"action":"select","what":"water"}]"#)),
        MLaneCase("choisis le ciel", gold: ["select"], args: ["what": "sky"], setup: .none, reference: answer("Je sélectionne le ciel.", #"[{"action":"select","what":"sky"}]"#)),
        MLaneCase("sélectionne la personne de gauche", gold: ["select"], args: ["what": "person"], setup: .none, reference: answer("Je sélectionne la personne.", #"[{"action":"select","what":"person","index":1}]"#)),
        MLaneCase("ajoute le ciel à ce qui est sélectionné", gold: ["select"], args: ["what": "sky", "mode": "add"], setup: .selection, reference: answer("J'ajoute le ciel.", #"[{"action":"select","what":"sky","mode":"add"}]"#)),
        MLaneCase("enlève l'eau de ma sélection", gold: ["select"], args: ["what": "water", "mode": "subtract"], setup: .selection, reference: answer("J'enlève l'eau.", #"[{"action":"select","what":"water","mode":"subtract"}]"#)),
        MLaneCase("sélectionne ce qui est bleu", gold: ["select"], args: ["what": "color", "color": "blue"], setup: .none, reference: answer("Je sélectionne les bleus.", #"[{"action":"select","what":"color","color":"blue"}]"#)),
        MLaneCase("prends les zones sombres", gold: ["select"], args: ["what": "shadows"], setup: .none, reference: answer("Je sélectionne les ombres.", #"[{"action":"select","what":"shadows"}]"#)),
        MLaneCase("inverse ce que j'ai sélectionné", gold: ["selectionModify"], args: ["invert": "true"], setup: .selection, reference: answer("J'inverse.", #"[{"action":"selectionModify","invert":true}]"#)),
        MLaneCase("élargis la sélection de 15 pixels", gold: ["selectionModify"], args: ["grow": "+"], setup: .selection, reference: answer("Je l'élargis.", #"[{"action":"selectionModify","grow":15}]"#)),
        MLaneCase("un contour progressif de 20 pixels sur la sélection", gold: ["selectionModify"], args: ["feather": "+"], setup: .selection, reference: answer("Contour progressif de 20 pixels.", #"[{"action":"selectionModify","feather":20}]"#)),
        MLaneCase("affine le bord de la sélection", gold: ["selectionModify"], args: ["refine": "true"], setup: .selection, reference: answer("J'affine le bord.", #"[{"action":"selectionModify","refine":true}]"#)),
        MLaneCase("enlève la sélection", gold: ["selectionModify"], args: ["deselect": "true"], setup: .selection, reference: answer("C'est désélectionné.", #"[{"action":"selectionModify","deselect":true}]"#)),
        MLaneCase("supprime ce qui est sélectionné", gold: ["selectionApply"], args: ["use": "erase"], setup: .selection, reference: answer("Je l'efface.", #"[{"action":"selectionApply","use":"erase"}]"#)),
        MLaneCase("floute un peu la zone sélectionnée", gold: ["selectionApply"], args: ["use": "blur"], setup: .selection, reference: answer("Je la floute.", #"[{"action":"selectionApply","use":"blur","amount":40}]"#)),
        MLaneCase("remplis la zone en noir", gold: ["selectionApply"], args: ["use": "fill", "color": "black"], setup: .selection, reference: answer("Je la remplis de noir.", #"[{"action":"selectionApply","use":"fill","color":"black"}]"#)),
        MLaneCase("passe la sélection en vert", gold: ["selectionApply"], args: ["use": "recolor", "color": "green"], setup: .selection, reference: answer("Je la passe en vert.", #"[{"action":"selectionApply","use":"recolor","color":"green"}]"#)),
        MLaneCase("fais un masque de la sélection", gold: ["selectionApply"], args: ["use": "mask"], setup: .selection, reference: answer("J'en fais un masque.", #"[{"action":"selectionApply","use":"mask","parameter":"exposure","amount":10}]"#)),
        MLaneCase("détoure ce qui est sélectionné", gold: ["selectionApply"], args: ["use": "cutout"], setup: .selection, reference: answer("Je la détoure.", #"[{"action":"selectionApply","use":"cutout"}]"#)),
        MLaneCase("sélectionne le violet", gold: [], args: [:], setup: .none, reference: answer("Je ne vois pas de violet ici.", #"[{"action":"select","what":"color","color":"purple"}]"#)),
        MLaneCase("assombris le masque 5", gold: [], args: [:], setup: .masks, reference: answer("Il n'y a que deux masques.", nil)),
        MLaneCase("darken the sky a bit", gold: ["maskAdjust", "selectiveAdjust"], args: ["where": "sky", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("Darkening the sky.", #"[{"action":"maskAdjust","where":"sky","parameter":"exposure","amount":-10}]"#)),
        MLaneCase("the bottom is too bright", gold: ["maskAdjust"], args: ["where": "bottom", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("Darkening the bottom.", #"[{"action":"maskAdjust","where":"bottom","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("warm up just the person", gold: ["maskAdjust"], args: ["where": "person", "parameter": "temperature", "amount": "+"], setup: .none, reference: answer("Warming the person.", #"[{"action":"maskAdjust","where":"person","parameter":"temperature","amount":20}]"#)),
        MLaneCase("give the water more colour", gold: ["maskAdjust"], args: ["where": "water", "parameter": "saturation", "amount": "+"], setup: .none, reference: answer("More colour in the water.", #"[{"action":"maskAdjust","where":"water","parameter":"saturation","amount":20}]"#)),
        MLaneCase("add a dark graduated filter at the top", gold: ["maskAdjust"], args: ["where": "top", "parameter": "exposure", "amount": "-"], setup: .none, reference: answer("A dark gradient at the top.", #"[{"action":"maskAdjust","where":"top","parameter":"exposure","amount":-20}]"#)),
        MLaneCase("cool down the far background", gold: ["maskAdjust"], args: ["where": "far", "parameter": "temperature", "amount": "-"], setup: .none, reference: answer("Cooling the distance.", #"[{"action":"maskAdjust","where":"far","parameter":"temperature","amount":-20}]"#)),
        MLaneCase("more contrast on mask 2", gold: ["maskAdjust"], args: ["ref": "a2", "parameter": "contrast", "amount": "+"], setup: .masks, reference: answer("More contrast there.", #"[{"action":"maskAdjust","ref":"a2","parameter":"contrast","amount":20}]"#)),
        MLaneCase("invert the sky mask", gold: ["maskEdit"], args: ["ref": "a1", "invert": "true"], setup: .masks, reference: answer("Inverting it.", #"[{"action":"maskEdit","ref":"a1","invert":true}]"#)),
        MLaneCase("soften the edge of the second mask", gold: ["maskEdit"], args: ["ref": "a2", "feather": "+"], setup: .masks, reference: answer("Softening it.", #"[{"action":"maskEdit","ref":"a2","feather":60}]"#)),
        MLaneCase("get rid of the bottom mask", gold: ["maskDelete"], args: ["ref": "a2"], setup: .masks, reference: answer("Deleting it.", #"[{"action":"maskDelete","ref":"a2"}]"#)),
        MLaneCase("select the blue mug please", gold: ["select"], args: ["what": "object", "target": "cup", "attributes": "blue"], setup: .none, reference: answer("Selecting the mug.", #"[{"action":"select","what":"object","target":"cup","attributes":["blue"]}]"#)),
        MLaneCase("select all the water", gold: ["select"], args: ["what": "water"], setup: .none, reference: answer("Selecting the water.", #"[{"action":"select","what":"water"}]"#)),
        MLaneCase("add the sky to what I selected", gold: ["select"], args: ["what": "sky", "mode": "add"], setup: .selection, reference: answer("Adding the sky.", #"[{"action":"select","what":"sky","mode":"add"}]"#)),
        MLaneCase("flip my selection", gold: ["selectionModify"], args: ["invert": "true"], setup: .selection, reference: answer("Inverting it.", #"[{"action":"selectionModify","invert":true}]"#)),
        MLaneCase("expand the selection by 10 pixels", gold: ["selectionModify"], args: ["grow": "+"], setup: .selection, reference: answer("Expanding it.", #"[{"action":"selectionModify","grow":10}]"#)),
        MLaneCase("clear the selection", gold: ["selectionModify"], args: ["deselect": "true"], setup: .selection, reference: answer("Deselected.", #"[{"action":"selectionModify","deselect":true}]"#)),
        MLaneCase("blur what's selected a little", gold: ["selectionApply"], args: ["use": "blur"], setup: .selection, reference: answer("Blurring it.", #"[{"action":"selectionApply","use":"blur","amount":40}]"#)),
        MLaneCase("paint the selected area white", gold: ["selectionApply"], args: ["use": "fill", "color": "white"], setup: .selection, reference: answer("Filling it with white.", #"[{"action":"selectionApply","use":"fill","color":"white"}]"#)),
        MLaneCase("turn the selected area red", gold: ["selectionApply"], args: ["use": "recolor", "color": "red"], setup: .selection, reference: answer("Making it red.", #"[{"action":"selectionApply","use":"recolor","color":"red"}]"#)),
        MLaneCase("select the purple", gold: [], args: [:], setup: .none, reference: answer("I can't see any purple here.", #"[{"action":"select","what":"color","color":"purple"}]"#)),
    ]
}
