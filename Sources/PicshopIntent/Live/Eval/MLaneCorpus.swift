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
        /// W3: the lake with layers: l1 « SOLDES », j1 a black gradient at the bottom, j2 Courbes, j3 Lumière, i1 the
        /// person on a layer of their own (selected).
        case layers
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
        // W3 (§8.7): layer operations, stored refs (i1 the subject copy, j1 a black gradient, j2 Courbes, j3 Lumière, l1
        // « SOLDES »), recipes, export, fill edits, tone operations on j-refs; then the unsupported layer requests.
        MLaneCase("rajoute un calque courbes en S", gold: ["addAdjustmentLayer"], args: ["kind": "curves"], setup: .layers, reference: answer("J'ajoute un calque Courbes.", #"[{"action":"addAdjustmentLayer","kind":"curves","preset":"sCurve"}]"#)),
        MLaneCase("un calque de réglage luminosité un peu plus fort", gold: ["addAdjustmentLayer"], args: ["kind": "light"], setup: .layers, reference: answer("J'ajoute un calque Lumière.", #"[{"action":"addAdjustmentLayer","kind":"light","parameter":"brightness","amount":20}]"#)),
        MLaneCase("calque niveaux automatiques par-dessus tout", gold: ["addAdjustmentLayer"], args: ["kind": "levels"], setup: .layers, reference: answer("Un calque Niveaux automatique.", #"[{"action":"addAdjustmentLayer","kind":"levels","auto":true}]"#)),
        MLaneCase("un calque teinte saturation qui calme les rouges", gold: ["addAdjustmentLayer"], args: ["kind": "hsl"], setup: .layers, reference: answer("Je calme les rouges sur un calque.", #"[{"action":"addAdjustmentLayer","kind":"hsl","band":"red","saturation":-30}]"#)),
        MLaneCase("calque d'étalonnage pour bleuir les ombres", gold: ["addAdjustmentLayer"], args: ["kind": "colorgrade"], setup: .layers, reference: answer("Un calque d'étalonnage.", #"[{"action":"addAdjustmentLayer","kind":"colorGrade","shadows":"blue","amount":30}]"#)),
        MLaneCase("un calque de look noir et blanc par-dessus", gold: ["addAdjustmentLayer"], args: ["kind": "look"], setup: .layers, reference: answer("Un calque noir et blanc.", #"[{"action":"addAdjustmentLayer","kind":"look","look":"mono"}]"#)),
        MLaneCase("add a curves adjustment layer with a gentle S", gold: ["addAdjustmentLayer"], args: ["kind": "curves"], setup: .layers, reference: answer("Adding a Curves layer.", #"[{"action":"addAdjustmentLayer","kind":"curves","preset":"sCurve"}]"#)),
        MLaneCase("add a levels layer on auto", gold: ["addAdjustmentLayer"], args: ["kind": "levels"], setup: .layers, reference: answer("Adding an auto Levels layer.", #"[{"action":"addAdjustmentLayer","kind":"levels","auto":true}]"#)),
        MLaneCase("a hue saturation layer that mutes the greens", gold: ["addAdjustmentLayer"], args: ["kind": "hsl"], setup: .layers, reference: answer("Muting the greens on a layer.", #"[{"action":"addAdjustmentLayer","kind":"hsl","band":"green","saturation":-30}]"#)),
        MLaneCase("ajoute un aplat blanc à 30 % par-dessus", gold: ["addFillLayer"], args: ["fill": "solid", "color": "white"], setup: .layers, reference: answer("Un aplat blanc à 30 %.", #"[{"action":"addFillLayer","fill":"solid","color":"white","opacity":30}]"#)),
        MLaneCase("un dégradé noir en bas pour poser le titre", gold: ["addFillLayer"], args: ["fill": "gradient", "color": "black"], setup: .layers, reference: answer("Un dégradé noir en bas.", #"[{"action":"addFillLayer","fill":"gradient","color":"black","angle":90}]"#)),
        MLaneCase("un voile rose léger sur toute la photo", gold: ["addFillLayer"], args: ["fill": "solid", "color": "pink"], setup: .layers, reference: answer("Un voile rose.", #"[{"action":"addFillLayer","fill":"solid","color":"pink","opacity":25}]"#)),
        MLaneCase("add a solid blue color layer at 20 percent", gold: ["addFillLayer"], args: ["fill": "solid", "color": "blue"], setup: .layers, reference: answer("A blue layer at 20 percent.", #"[{"action":"addFillLayer","fill":"solid","color":"blue","opacity":20}]"#)),
        MLaneCase("add a radial gradient from orange to purple", gold: ["addFillLayer"], args: ["fill": "gradient", "color": "orange"], setup: .layers, reference: answer("An orange to purple gradient.", #"[{"action":"addFillLayer","fill":"gradient","color":"orange","color2":"purple","style":"radial"}]"#)),
        MLaneCase("passe le dégradé j1 en radial", gold: ["fillLayer"], args: ["ref": "j1", "style": "radial"], setup: .layers, reference: answer("Le dégradé devient radial.", #"[{"action":"fillLayer","ref":"j1","style":"radial"}]"#)),
        MLaneCase("tourne le dégradé j1 à 45 degrés", gold: ["fillLayer"], args: ["ref": "j1", "angle": "+"], setup: .layers, reference: answer("Je le tourne.", #"[{"action":"fillLayer","ref":"j1","angle":45}]"#)),
        MLaneCase("inverse le sens du dégradé j1", gold: ["fillLayer"], args: ["ref": "j1", "reverse": "true"], setup: .layers, reference: answer("Je l'inverse.", #"[{"action":"fillLayer","ref":"j1","reverse":true}]"#)),
        MLaneCase("make the gradient j1 reflected", gold: ["fillLayer"], args: ["ref": "j1", "style": "reflected"], setup: .layers, reference: answer("Reflected it is.", #"[{"action":"fillLayer","ref":"j1","style":"reflected"}]"#)),
        MLaneCase("mets la personne sur un calque à elle", gold: ["layerVia"], args: ["mode": "copy", "where": "person"], setup: .layers, reference: answer("Je mets la personne sur un calque.", #"[{"action":"layerVia","mode":"copy","where":"person"}]"#)),
        MLaneCase("coupe le ciel sur son propre calque", gold: ["layerVia"], args: ["mode": "cut", "where": "sky"], setup: .layers, reference: answer("Le ciel passe sur un calque.", #"[{"action":"layerVia","mode":"cut","where":"sky"}]"#)),
        MLaneCase("copie l'eau sur un nouveau calque", gold: ["layerVia"], args: ["mode": "copy", "where": "water"], setup: .layers, reference: answer("L'eau sur un calque.", #"[{"action":"layerVia","mode":"copy","where":"water"}]"#)),
        MLaneCase("lift the person onto a layer of their own", gold: ["layerVia"], args: ["mode": "copy", "where": "person"], setup: .layers, reference: answer("The person on a new layer.", #"[{"action":"layerVia","mode":"copy","where":"person"}]"#)),
        MLaneCase("cut the water out to a separate layer", gold: ["layerVia"], args: ["mode": "cut", "where": "water"], setup: .layers, reference: answer("The water on its own layer.", #"[{"action":"layerVia","mode":"cut","where":"water"}]"#)),
        MLaneCase("ajoute au calque de courbes j2 un masque qui garde le ciel", gold: ["layerMask"], args: ["do": "add", "layer": "j2", "where": "sky"], setup: .layers, reference: answer("Le calque Courbes ne touche plus que le ciel.", #"[{"action":"layerMask","do":"add","layer":"j2","where":"sky"}]"#)),
        MLaneCase("inverse le masque du sujet i1", gold: ["layerMask"], args: ["do": "invert", "layer": "i1"], setup: .layers, reference: answer("J'inverse le masque.", #"[{"action":"layerMask","do":"invert","layer":"i1"}]"#)),
        MLaneCase("coupe le masque de fusion de i1 un instant", gold: ["layerMask"], args: ["do": "disable", "layer": "i1"], setup: .layers, reference: answer("Masque désactivé.", #"[{"action":"layerMask","do":"disable","layer":"i1"}]"#)),
        MLaneCase("rends le bord du masque de i1 plus doux", gold: ["layerMask"], args: ["do": "edit", "layer": "i1", "feather": "+"], setup: .layers, reference: answer("Je l'adoucis.", #"[{"action":"layerMask","do":"edit","layer":"i1","feather":60}]"#)),
        MLaneCase("applique pour de bon le masque de i1", gold: ["layerMask"], args: ["do": "apply", "layer": "i1"], setup: .layers, reference: answer("J'applique le masque.", #"[{"action":"layerMask","do":"apply","layer":"i1"}]"#)),
        MLaneCase("enlève le masque de fusion du sujet i1", gold: ["layerMask"], args: ["do": "delete", "layer": "i1"], setup: .layers, reference: answer("Masque supprimé.", #"[{"action":"layerMask","do":"delete","layer":"i1"}]"#)),
        MLaneCase("give j2 a layer mask that hides the top", gold: ["layerMask"], args: ["do": "add", "layer": "j2", "where": "top", "reveal": "false"], setup: .layers, reference: answer("The top is hidden on j2.", #"[{"action":"layerMask","do":"add","layer":"j2","where":"top","reveal":false}]"#)),
        MLaneCase("flip the mask on i1", gold: ["layerMask"], args: ["do": "invert", "layer": "i1"], setup: .layers, reference: answer("Inverting the mask.", #"[{"action":"layerMask","do":"invert","layer":"i1"}]"#)),
        MLaneCase("throw away the layer mask of i1", gold: ["layerMask"], args: ["do": "delete", "layer": "i1"], setup: .layers, reference: answer("Mask deleted.", #"[{"action":"layerMask","do":"delete","layer":"i1"}]"#)),
        MLaneCase("écrête le calque de courbes j2 au calque du dessous", gold: ["layerClip"], args: ["ref": "j2", "clip": "true"], setup: .layers, reference: answer("Les courbes ne touchent plus que le calque du dessous.", #"[{"action":"layerClip","ref":"j2","clip":true}]"#)),
        MLaneCase("accroche le dégradé j1 à celui du dessous", gold: ["layerClip"], args: ["ref": "j1", "clip": "true"], setup: .layers, reference: answer("Le dégradé est écrêté.", #"[{"action":"layerClip","ref":"j1","clip":true}]"#)),
        MLaneCase("clip the curves layer j2 to the one below", gold: ["layerClip"], args: ["ref": "j2", "clip": "true"], setup: .layers, reference: answer("Clipped.", #"[{"action":"layerClip","ref":"j2","clip":true}]"#)),
        MLaneCase("regroupe le titre et le sujet", gold: ["groupLayers"], args: ["refs": "i1,l1"], setup: .layers, reference: answer("Je les groupe.", #"[{"action":"groupLayers","refs":["l1","i1"]}]"#)),
        MLaneCase("mets j1 et j2 ensemble dans un groupe", gold: ["groupLayers"], args: ["refs": "j1,j2"], setup: .layers, reference: answer("Groupe créé.", #"[{"action":"groupLayers","refs":["j1","j2"]}]"#)),
        MLaneCase("group the gradient with the curves layer", gold: ["groupLayers"], args: ["refs": "j1,j2"], setup: .layers, reference: answer("Grouped.", #"[{"action":"groupLayers","refs":["j1","j2"]}]"#)),
        MLaneCase("range tous les calques dans un même groupe", gold: ["groupLayers"], args: ["all": "true"], setup: .layers, reference: answer("Tout est dans un groupe.", #"[{"action":"groupLayers","all":true}]"#)),
        MLaneCase("fusionne le sujet avec ce qu'il y a en dessous", gold: ["mergeLayers"], args: ["mode": "down", "ref": "i1"], setup: .layers, reference: answer("Je fusionne vers le bas.", #"[{"action":"mergeLayers","mode":"down","ref":"i1"}]"#)),
        MLaneCase("fusionne tout ce qui se voit", gold: ["mergeLayers"], args: ["mode": "visible"], setup: .layers, reference: answer("Les calques visibles sont fusionnés.", #"[{"action":"mergeLayers","mode":"visible"}]"#)),
        MLaneCase("fais une copie fusionnée de ce qui est visible", gold: ["mergeLayers"], args: ["mode": "stamp"], setup: .layers, reference: answer("Un tampon des calques visibles.", #"[{"action":"mergeLayers","mode":"stamp"}]"#)),
        MLaneCase("écrase tous les calques en un seul", gold: ["mergeLayers"], args: ["mode": "flatten"], setup: .layers, reference: answer("J'aplatis l'image.", #"[{"action":"mergeLayers","mode":"flatten"}]"#)),
        MLaneCase("merge the subject layer down", gold: ["mergeLayers"], args: ["mode": "down", "ref": "i1"], setup: .layers, reference: answer("Merging down.", #"[{"action":"mergeLayers","mode":"down","ref":"i1"}]"#)),
        MLaneCase("stamp everything visible onto a new layer", gold: ["mergeLayers"], args: ["mode": "stamp"], setup: .layers, reference: answer("Stamped.", #"[{"action":"mergeLayers","mode":"stamp"}]"#)),
        MLaneCase("agrandis le sujet de 20 %", gold: ["layerTransform"], args: ["ref": "i1", "scaleBy": "+"], setup: .layers, reference: answer("Je l'agrandis.", #"[{"action":"layerTransform","ref":"i1","scaleBy":120}]"#)),
        MLaneCase("fais pivoter le calque i1 de 10 degrés", gold: ["layerTransform"], args: ["ref": "i1", "rotation": "+"], setup: .layers, reference: answer("Je le tourne.", #"[{"action":"layerTransform","ref":"i1","rotation":10,"relative":true}]"#)),
        MLaneCase("pousse le sujet vers la gauche", gold: ["layerTransform"], args: ["ref": "i1", "dx": "-"], setup: .layers, reference: answer("Je le décale.", #"[{"action":"layerTransform","ref":"i1","dx":-50}]"#)),
        MLaneCase("mets le sujet en miroir", gold: ["layerTransform"], args: ["ref": "i1", "flip": "horizontal"], setup: .layers, reference: answer("En miroir.", #"[{"action":"layerTransform","ref":"i1","flip":"horizontal"}]"#)),
        MLaneCase("penche le sujet de 10 degrés", gold: ["layerTransform"], args: ["ref": "i1", "skewX": "+"], setup: .layers, reference: answer("Je l'incline.", #"[{"action":"layerTransform","ref":"i1","skewX":10}]"#)),
        MLaneCase("aligne le titre et le sujet sur la gauche", gold: ["layerTransform"], args: ["refs": "i1,l1", "align": "left"], setup: .layers, reference: answer("Alignés à gauche.", #"[{"action":"layerTransform","refs":["l1","i1"],"align":"left"}]"#)),
        MLaneCase("scale the subject layer to 150 percent", gold: ["layerTransform"], args: ["ref": "i1", "scale": "+"], setup: .layers, reference: answer("Scaled.", #"[{"action":"layerTransform","ref":"i1","scale":150}]"#)),
        MLaneCase("turn the subject 15 degrees", gold: ["layerTransform"], args: ["ref": "i1", "rotation": "+"], setup: .layers, reference: answer("Rotated.", #"[{"action":"layerTransform","ref":"i1","rotation":15,"relative":true}]"#)),
        MLaneCase("shift the subject layer to the right", gold: ["layerTransform"], args: ["ref": "i1", "dx": "+"], setup: .layers, reference: answer("Moved right.", #"[{"action":"layerTransform","ref":"i1","dx":50}]"#)),
        MLaneCase("move the subject layer up a bit", gold: ["layerTransform"], args: ["ref": "i1", "dy": "-"], setup: .layers, reference: answer("Moved up.", #"[{"action":"layerTransform","ref":"i1","dy":-40}]"#)),
        MLaneCase("baisse le fond du sujet à 50 %", gold: ["layerProperties"], args: ["ref": "i1", "fill": "+"], setup: .layers, reference: answer("Fond à 50 %.", #"[{"action":"layerProperties","ref":"i1","fill":50}]"#)),
        MLaneCase("bloque la position du titre", gold: ["layerProperties"], args: ["ref": "l1", "lock": "position"], setup: .layers, reference: answer("La position du titre est verrouillée.", #"[{"action":"layerProperties","ref":"l1","lock":"position"}]"#)),
        MLaneCase("appelle le dégradé Ombre", gold: ["layerProperties"], args: ["ref": "j1", "name": "ombre"], setup: .layers, reference: answer("Renommé.", #"[{"action":"layerProperties","ref":"j1","name":"Ombre"}]"#)),
        MLaneCase("verrouille tout sur le calque j2", gold: ["layerProperties"], args: ["ref": "j2", "lock": "all"], setup: .layers, reference: answer("Verrouillé.", #"[{"action":"layerProperties","ref":"j2","lock":"all"}]"#)),
        MLaneCase("lock the subject's pixels", gold: ["layerProperties"], args: ["ref": "i1", "lock": "pixels"], setup: .layers, reference: answer("Pixels locked.", #"[{"action":"layerProperties","ref":"i1","lock":"pixels"}]"#)),
        MLaneCase("set the fill of j1 to 40 percent", gold: ["layerProperties"], args: ["ref": "j1", "fill": "+"], setup: .layers, reference: answer("Fill at 40.", #"[{"action":"layerProperties","ref":"j1","fill":40}]"#)),
        MLaneCase("sors-moi un PNG en 16 bits", gold: ["exportPhoto"], args: ["format": "png", "bitDepth": "16"], setup: .layers, reference: answer("J'ouvre l'export en PNG 16 bits.", #"[{"action":"exportPhoto","format":"png","bitDepth":"16"}]"#)),
        MLaneCase("un PSD avec tous les calques stp", gold: ["exportPhoto"], args: ["format": "psd", "layers": "true"], setup: .layers, reference: answer("J'ouvre l'export en PSD.", #"[{"action":"exportPhoto","format":"psd","layers":true}]"#)),
        MLaneCase("prépare un TIFF pour l'imprimeur", gold: ["exportPhoto"], args: ["preset": "print"], setup: .layers, reference: answer("Export pour l'impression.", #"[{"action":"exportPhoto","preset":"print"}]"#)),
        MLaneCase("give me a HEIC in 10 bit", gold: ["exportPhoto"], args: ["format": "heic", "bitDepth": "10"], setup: .layers, reference: answer("HEIC 10-bit.", #"[{"action":"exportPhoto","format":"heic","bitDepth":"10"}]"#)),
        MLaneCase("save a layered photoshop file", gold: ["exportPhoto"], args: ["format": "psd", "layers": "true"], setup: .layers, reference: answer("A layered PSD.", #"[{"action":"exportPhoto","format":"psd","layers":true}]"#)),
        MLaneCase("rends-la prête pour un post Instagram", gold: ["recipe"], args: ["name": "instagrampost"], setup: .layers, reference: answer("Je la prépare pour Instagram.", #"[{"action":"recipe","name":"instagramPost"}]"#)),
        MLaneCase("un post Instagram format carré", gold: ["recipe"], args: ["name": "instagrampost", "format": "square"], setup: .layers, reference: answer("Un post carré.", #"[{"action":"recipe","name":"instagramPost","format":"square"}]"#)),
        MLaneCase("fais-en une photo produit sur fond noir", gold: ["recipe"], args: ["name": "productphoto", "background": "black"], setup: .layers, reference: answer("Photo produit sur fond noir.", #"[{"action":"recipe","name":"productPhoto","background":"black"}]"#)),
        MLaneCase("une retouche portrait toute douce", gold: ["recipe"], args: ["name": "portraitretouch"], setup: .layers, reference: answer("Retouche portrait légère.", #"[{"action":"recipe","name":"portraitRetouch","strength":30}]"#)),
        MLaneCase("turn this into a product shot", gold: ["recipe"], args: ["name": "productphoto"], setup: .layers, reference: answer("Product photo.", #"[{"action":"recipe","name":"productPhoto"}]"#)),
        MLaneCase("make it ready for an Instagram story", gold: ["recipe"], args: ["name": "instagrampost", "format": "story9x16"], setup: .layers, reference: answer("An Instagram story.", #"[{"action":"recipe","name":"instagramPost","format":"story9x16"}]"#)),
        MLaneCase("baisse l'exposition du calque Lumière j3", gold: ["adjust"], args: ["parameter": "exposure", "amount": "-", "layer": "j3"], setup: .layers, reference: answer("Je baisse l'exposition du calque.", #"[{"action":"adjust","parameter":"exposure","amount":-20,"layer":"j3"}]"#)),
        MLaneCase("plus de contraste dans le calque j3", gold: ["adjust"], args: ["parameter": "contrast", "amount": "+", "layer": "j3"], setup: .layers, reference: answer("Plus de contraste dans le calque.", #"[{"action":"adjust","parameter":"contrast","amount":15,"layer":"j3"}]"#)),
        MLaneCase("une courbe en S plus marquée sur j2", gold: ["curves"], args: ["preset": "strongs", "layer": "j2"], setup: .layers, reference: answer("La courbe de j2 est plus marquée.", #"[{"action":"curves","preset":"strongS","layer":"j2"}]"#)),
        MLaneCase("éclaircis le sujet i1", gold: ["adjust"], args: ["parameter": "brightness", "amount": "+", "layer": "i1"], setup: .layers, reference: answer("J'éclaircis le sujet.", #"[{"action":"adjust","parameter":"brightness","amount":20,"layer":"i1"}]"#)),
        MLaneCase("warm up the light layer j3", gold: ["adjust"], args: ["parameter": "temperature", "amount": "+", "layer": "j3"], setup: .layers, reference: answer("Warming that layer.", #"[{"action":"adjust","parameter":"temperature","amount":15,"layer":"j3"}]"#)),
        MLaneCase("a stronger S curve on j2", gold: ["curves"], args: ["preset": "strongs", "layer": "j2"], setup: .layers, reference: answer("Stronger curve on j2.", #"[{"action":"curves","preset":"strongS","layer":"j2"}]"#)),
        MLaneCase("duplique le sujet i1", gold: ["duplicateLayer"], args: ["ref": "i1"], setup: .layers, reference: answer("Je duplique le sujet.", #"[{"action":"duplicateLayer","ref":"i1"}]"#)),
        MLaneCase("supprime le dégradé j1", gold: ["deleteLayer"], args: ["ref": "j1"], setup: .layers, reference: answer("Dégradé supprimé.", #"[{"action":"deleteLayer","ref":"j1"}]"#)),
        MLaneCase("mets une ombre portée sous le sujet", gold: [], args: [:], setup: .layers, reference: answer("L'ombre portée n'est pas encore possible sur un calque.", nil)),
        MLaneCase("un contour blanc autour du sujet", gold: [], args: [:], setup: .layers, reference: answer("Le contour d'un calque n'est pas encore possible.", nil)),
        MLaneCase("une lueur externe sur le titre stp", gold: [], args: [:], setup: .layers, reference: answer("La lueur et le biseau ne sont pas encore possibles sur un calque.", nil)),
        MLaneCase("applique un style de calque au titre", gold: [], args: [:], setup: .layers, reference: answer("Les styles de calque ne sont pas encore là.", nil)),
        MLaneCase("mets une courbe de transfert de dégradé", gold: [], args: [:], setup: .layers, reference: answer("La courbe de transfert de dégradé n'est pas encore là.", nil)),
        MLaneCase("un calque de motif à pois", gold: [], args: [:], setup: .layers, reference: answer("Les motifs ne sont pas encore là.", nil)),
        MLaneCase("pixellise le titre", gold: [], args: [:], setup: .layers, reference: answer("Pixelliser un texte n'est pas encore possible.", nil)),
        MLaneCase("fais un groupe dans le groupe", gold: [], args: [:], setup: .layers, reference: answer("Un groupe ne peut pas contenir un autre groupe.", nil)),
        MLaneCase("ouvre mon fichier PSD", gold: [], args: [:], setup: .layers, reference: answer("Picshop exporte en PSD mais n'ouvre pas les PSD.", nil)),
        MLaneCase("transforme le sujet en objet dynamique", gold: [], args: [:], setup: .layers, reference: answer("Pas besoin d'objet dynamique : chaque calque garde sa source.", nil)),
        MLaneCase("ajoute un deuxième plan de travail", gold: [], args: [:], setup: .layers, reference: answer("Les plans de travail ne sont pas encore là.", nil)),
        MLaneCase("add a drop shadow under the subject", gold: [], args: [:], setup: .layers, reference: answer("A drop shadow on a layer isn't possible yet.", nil)),
        MLaneCase("put a glow around the title", gold: [], args: [:], setup: .layers, reference: answer("Glow and bevel aren't possible on a layer yet.", nil)),
        MLaneCase("save a layer comp of this", gold: [], args: [:], setup: .layers, reference: answer("Layer comps aren't here yet.", nil)),
        MLaneCase("open the advanced blending options", gold: [], args: [:], setup: .layers, reference: answer("Advanced blending options aren't here yet.", nil)),
    ]
}
