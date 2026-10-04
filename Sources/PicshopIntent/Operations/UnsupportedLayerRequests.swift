import Foundation
import PicshopCore

/// W3 (§8.4): honest answers for the layer requests W3 does not do (layer styles, smart objects, artboards, a PSD
/// opened…). Each family says what is not possible and offers the nearest operation; a few have an operation that
/// does the same job (« calque noir et blanc » is a Lumière layer at saturation −100), which the grammar runs.
/// The families cap a grammar plan that names them (OperationAbstention), answer without a model
/// (HybridIntentRouter) and feed the G lane and the M lane (15 unsupported cases).
public enum UnsupportedLayerRequests {
    public struct Family: Sendable, Equatable {
        /// A stable name (the M lane and the logs).
        public let id: String
        /// The words that name it (folded: lower case, no accents, apostrophes as spaces), matched as runs.
        public let phrases: [String]
        /// The operation closest to what was asked, nil when there is none.
        public let nearest: OpID?
        public let french: String
        public let english: String
        /// An operation that does the job, run when the person asks it this way.
        public let offer: OperationCall?

        init(_ id: String, _ phrases: [String], nearest: OpID?, french: String, english: String, offer: OperationCall? = nil) {
            self.id = id
            self.phrases = phrases
            self.nearest = nearest
            self.french = french
            self.english = english
            self.offer = offer
        }

        public func reply(french isFrench: Bool) -> String { isFrench ? french : english }
    }

    /// The families, most specific first (« calque noir et blanc » before a looser match).
    public static let families: [Family] = [
        Family("blackWhiteLayer", ["calque noir et blanc", "calque de noir et blanc", "calque n b", "black and white layer", "black and white adjustment layer",
                                   "black white adjustment layer"],
               nearest: "addAdjustmentLayer",
               french: "Je mets un calque de réglage Lumière avec la saturation à zéro : c'est le noir et blanc en calque.",
               english: "I'm adding a Light adjustment layer with saturation at zero: black and white as a layer.",
               offer: OperationCall("addAdjustmentLayer", args: ["kind": .string("light"), "parameter": .string("saturation"), "amount": .number(-100)],
                                    source: .grammar)),
        Family("dropShadow", ["ombre portee", "ombre douce", "ombre sous le calque", "ombre sous le logo", "drop shadow", "soft shadow", "shadow under the layer"],
               nearest: "editText",
               french: "L'ombre portée n'est pas encore possible sur un calque. Sur un texte, je peux mettre le style « ombre ».",
               english: "A drop shadow on a layer isn't possible yet. On a text, I can use the shadow style."),
        Family("stroke", ["contour autour du", "contour autour de", "contour au logo", "contour du logo", "contour au calque", "ajoute un contour", "contour blanc autour", "contour noir autour", "contour de couleur autour", "liseré",
                          "lisere", "add a stroke", "stroke around", "outline around the", "outline the logo", "outline the layer"],
               nearest: nil,
               french: "Le contour d'un calque n'est pas encore possible : il arrive avec les styles de calque.",
               english: "A stroke around a layer isn't possible yet: it comes with layer styles."),
        Family("glowBevel", ["lueur", "lueur externe", "lueur interne", "biseau", "estampage", "outer glow", "inner glow", "glow", "bevel", "emboss"],
               nearest: nil,
               french: "La lueur et le biseau ne sont pas encore possibles sur un calque.",
               english: "Glow and bevel aren't possible on a layer yet."),
        Family("layerStyle", ["style de calque", "styles de calque", "effets de calque", "layer style", "layer styles", "layer effects"],
               nearest: "layerProperties",
               french: "Les styles de calque ne sont pas encore là. Je peux régler l'opacité, le fond, le mode de fusion ou le verrou du calque.",
               english: "Layer styles aren't here yet. I can set the layer's opacity, fill, blend mode or lock."),
        Family("gradientMap", ["courbe de transfert de degrade", "mappe de degrade", "carte de degrade", "gradient map"],
               nearest: "colorGrade",
               french: "La courbe de transfert de dégradé n'est pas encore là. L'étalonnage teinte les ombres et les hautes lumières.",
               english: "Gradient maps aren't here yet. Color grading tints the shadows and the highlights."),
        Family("selectiveColor", ["correction selective", "melangeur de couches", "selective color", "selective colour", "channel mixer"],
               nearest: "hsl",
               french: "La correction sélective n'est pas encore là. Teinte/Saturation règle chaque couleur une à une.",
               english: "Selective color isn't here yet. Hue/Saturation sets each colour one by one."),
        Family("pattern", ["calque de motif", "remplis avec un motif", "remplissage motif", "motif repete", "pattern layer", "pattern fill", "pattern overlay"],
               nearest: "addFillLayer",
               french: "Les motifs ne sont pas encore là. Je peux faire un calque de couleur unie ou de dégradé.",
               english: "Patterns aren't here yet. I can make a solid colour or a gradient layer."),
        Family("warp", ["deforme en vague", "deforme en vagues", "deforme le calque en vague", "en forme de vague", "deformation en vague", "fluidite",
                        "marionnette", "deformation de la marionnette", "warp the layer", "warp it", "puppet warp", "warp"],
               nearest: "layerTransform",
               french: "La déformation libre n'est pas encore possible. Je peux ouvrir la déformation par les quatre coins.",
               english: "Free-form warping isn't possible yet. I can open distort by the four corners.",
               offer: OperationCall("layerTransform", args: ["mode": .string("distort")], source: .grammar)),
        Family("rasterizeText", ["pixellise le texte", "pixelise le texte", "pixellise le titre", "pixelise le titre", "rasterise", "rasterize",
                                  "pixellise le calque", "rasterize the text"],
               nearest: "editText",
               french: "Pixelliser un texte n'est pas encore possible : il reste modifiable, et l'export garde son rendu.",
               english: "Rasterizing a text isn't possible yet: it stays editable, and the export keeps its look."),
        Family("nestedGroup", ["groupe dans le groupe", "groupe dans un groupe", "un groupe dans le groupe", "sous groupe", "nested group",
                               "group inside a group", "group within a group"],
               nearest: "groupLayers",
               french: "Un groupe ne peut pas contenir un autre groupe : un seul niveau de groupes.",
               english: "A group can't contain another group: groups are one level deep."),
        Family("openPSD", ["ouvre ce psd", "ouvre un psd", "ouvre le psd", "ouvre mon psd", "ouvre mon fichier psd", "ouvre le fichier psd", "importe un psd",
                           "importe le psd", "importer un psd", "open this psd", "open a psd", "open my psd",
                           "import a psd", "import the psd"],
               nearest: "exportPhoto",
               french: "Picshop exporte en PSD mais n'ouvre pas les PSD. Je peux ajouter une image en calque.",
               english: "Picshop exports PSD files but doesn't open them. I can add a picture as a layer."),
        Family("smartObject", ["objet dynamique", "objets dynamiques", "convertis en objet dynamique", "smart object", "smart objects"],
               nearest: "layerTransform",
               french: "Pas besoin d'objet dynamique : chaque calque garde déjà sa source et ses réglages, rien n'est perdu en le transformant.",
               english: "No need for a smart object: every layer already keeps its source and settings, so transforming it loses nothing."),
        Family("artboard", ["plan de travail", "plans de travail", "artboard", "artboards"],
               nearest: nil,
               french: "Les plans de travail ne sont pas encore là : une photo, c'est un seul plan.",
               english: "Artboards aren't here yet: a photo is one canvas."),
        Family("layerComps", ["composition de calques", "compositions de calques", "layer comp", "layer comps"],
               nearest: nil,
               french: "Les compositions de calques ne sont pas encore là. Les versions enregistrées gardent un état de la photo.",
               english: "Layer comps aren't here yet. Saved versions keep a state of the photo."),
        Family("transformTogether", ["transforme ces calques ensemble", "transforme les calques ensemble", "deplace ces calques ensemble",
                                     "agrandis ces calques ensemble", "transform these layers together", "move these layers together", "scale these layers together"],
               nearest: "layerTransform",
               french: "Je transforme un calque à la fois. Pour plusieurs, je peux les aligner, ou les grouper puis les déplacer un par un.",
               english: "I transform one layer at a time. For several, I can align them, or group them and move them one by one."),
        Family("blendIf", ["blend if", "options de fusion avancees", "fusion avancee", "advanced blending", "blending options"],
               nearest: "layerBlend",
               french: "Les options de fusion avancées ne sont pas encore là. Je peux changer le mode de fusion ou l'opacité.",
               english: "Advanced blending options aren't here yet. I can change the blend mode or the opacity."),
    ]

    static let lexicon: [(family: Family, tokens: [String])] = families.flatMap { family in
        family.phrases.map { (family, TextFolding.tokens($0)) }.filter { !$0.1.isEmpty }
    }

    /// The family the words name, nil when none (photo only: these are layer requests).
    public static func match(_ utterance: String, domain: OpDomain = .photo) -> Family? {
        guard domain == .photo else { return nil }
        let tokens = TextFolding.tokens(utterance)
        var best: (family: Family, length: Int)?
        for entry in lexicon where OperationIndex.Document.contains(tokens, entry.tokens) {
            if best == nil || entry.tokens.count > best!.length { best = (entry.family, entry.tokens.count) }
        }
        return best?.family
    }

    /// The families a turn names, in the whole sentence and in each clause, once each (« … ombre douce, export PNG »):
    /// what the model brains are told is not possible (D20). Empty with the layer operations off.
    public static func named(in text: String, domain: OpDomain) -> [Family] {
        guard FeatureFlags.isOn(.layerOps) else { return [] }
        var seen: Set<String> = []
        return ([text] + GoalOutline.clauses(text)).compactMap { match($0, domain: domain) }.filter { seen.insert($0.id).inserted }
    }

    /// The prompt lines for those families: what is not possible yet (said in one short sentence, never done with
    /// another operation, the rest of the request done), and the call that does the job for those that have one.
    /// Empty when there is none.
    public static func promptHint(_ families: [Family]) -> String {
        let notYet = families.filter { $0.offer == nil }.map(\.english)
        let offers = families.compactMap { family in
            family.offer.map { "for \"\(family.phrases.last ?? family.id)\" use " + OperationArguments.json($0).serialized() }
        }
        var parts: [String] = []
        if !notYet.isEmpty {
            parts.append("Not possible yet (say it in one short sentence, never use another operation for it, do the rest): " + notYet.joined(separator: " "))
        }
        if !offers.isEmpty { parts.append("Do it this way: " + offers.joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }

    /// The plan the grammar answers with when no model reads the turn: the family's operation when it has one, else
    /// the honest sentence (no step).
    public static func plan(_ family: Family, utterance: String, language: NormalizedUtterance.Language) -> EditPlan {
        let french = language == .french
        if let offer = family.offer, OperationGate.isEnabled(offer.id) {
            let intent = EditIntent(action: .operation, confidence: 0.9, operation: offer)
            return EditPlan(utterance: utterance, intents: [intent], confidence: 0.9, language: language.rawValue, reply: family.reply(french: french),
                            engine: .rules)
        }
        var plan = EditPlan.unknown(utterance)
        plan.language = language.rawValue
        plan.reply = family.reply(french: french)
        return plan
    }
}
