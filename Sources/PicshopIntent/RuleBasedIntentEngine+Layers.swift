import Foundation
import PicshopCore

/// The grammar's W3 rules (§8.4): the signature phrases of the layer operations, the recipes and the export sheet,
/// and nothing looser. Each rule is anchored on the whole clause (the command words, then only the values it reads),
/// so « masque le calque » stays layerVisibility, « détoure » removeBackground, « mode fondu » a blend mode and
/// « corrige la perspective » the photo's. `parseSegment` runs these before the W2 mask rules and the W1 layer rules,
/// and the recipe phrases before `parseGoal`, whose product phrases now mean `recipe productPhoto` (D21). Every other
/// layer request is keywordsOnly: the model reads it, and without a model the honest refusals answer
/// (`UnsupportedLayerRequests`) or « pas encore à la voix sans modèle ».
extension RuleBasedIntentEngine {
    /// The grammar's confidence for the anchored W3 rules.
    static let layerRuleConfidence = 0.9
    /// The operations whose grammar rules match the whole clause, so their plan is never capped by another
    /// operation's trigger inside the phrase (« fusionne les calques visibles », « ajoute un calque de courbes »).
    /// Not `recipe`: its product phrases match anywhere in a clause.
    static let anchoredLayerOps: Set<OpID> = ["layerVia", "mergeLayers", "layerClip", "groupLayers", "addAdjustmentLayer", "addFillLayer", "exportPhoto"]

    static func layerCall(_ id: OpID, _ args: [String: OpValue]) -> EditIntent {
        EditIntent(action: .operation, confidence: layerRuleConfidence, operation: OperationCall(id, args: args, source: .grammar))
    }

    /// The W3 phrases of a clause, nil when none applies.
    func parseLayers(_ u: NormalizedUtterance, context: IntentContext) -> EditIntent? {
        let words = Self.trimmedCommand(u.tokens)
        guard !words.isEmpty else { return nil }
        let phrase = words.joined(separator: " ")
        if let recipe = Self.recipeRule(u, phrase: phrase, context: context) { return recipe }
        guard context.mode == .photo else { return nil }
        // A gesture-only control of a photo panel said aloud (I1 at W3): its tool opens on it.
        if let gesture = Self.photoGestureRule(phrase) { return gesture }
        guard FeatureFlags.isOn(.layerOps) else { return nil }
        if let export = Self.exportRule(words, phrase: phrase) { return export }
        guard FeatureFlags.isOn(.proLayers) else { return nil }
        if let via = Self.viaRule(phrase) { return via }
        if let merge = Self.mergeRule(phrase) { return merge }
        if let clip = Self.clipRule(phrase) { return clip }
        if let group = Self.groupRule(phrase) { return group }
        if let adjustment = Self.adjustmentLayerRule(words) { return adjustment }
        if let fill = Self.fillLayerRule(words) { return fill }
        return nil
    }

    // MARK: Gesture-only controls (I1, PhotoPanelInventory)

    /// The photo panels' gesture-only controls (W3 §8.7, the W2 rule on every photo panel): the words that open each
    /// one's tool in the mode its gesture needs (`openTool:<id>`), and the operation that carries it. Whole-utterance
    /// matches (folded); the Save and Share buttons of the export sheet are W1's `export` and `share` already.
    static let photoGestureRules: [(phrases: [String], control: String, op: OpID)] = [
        (["dessine une forme", "ajoute une forme a la main", "draw a shape", "add a shape by hand"], "layers.add.shape", "selectLayer"),
        (["glisse le calque", "reordonne les calques a la main", "range les calques a la main", "drag the layer", "reorder the layers by hand"],
         "layers.row.reorder", "layerOrder"),
        (["glisse le calque dans la colonne", "drag the layer in the column"], "layers.column.reorder", "layerOrder"),
        (["transforme en gardant les proportions", "garde les proportions", "transformation proportionnelle", "keep the proportions",
          "scale proportionally"], "layers.transform.mode.uniform", "layerTransform"),
        (["poignees de transformation", "montre les poignees", "affiche les poignees", "transform handles", "show the handles"],
         "layers.transform.handles", "layerTransform"),
        (["peins le masque de fusion", "peins sur le masque du calque", "paint the layer mask", "paint on the layer mask"], "layers.mask.paint",
         "layerMask"),
        (["efface le masque de fusion au pinceau", "gomme le masque de fusion", "erase the layer mask with the brush"], "layers.mask.paint.erase",
         "layerMask"),
        (["taille du pinceau du masque de fusion", "layer mask brush size"], "layers.mask.brush.size", "layerMask"),
        (["durete du pinceau du masque de fusion", "layer mask brush hardness"], "layers.mask.brush.hardness", "layerMask"),
        (["flux du pinceau du masque de fusion", "layer mask brush flow"], "layers.mask.brush.flow", "layerMask"),
        (["deplace les poignees du degrade", "regle le degrade a la main", "drag the gradient handles", "move the gradient handles"],
         "layers.fill.handles", "fillLayer"),
        (["modifie les points de la courbe du calque", "drag the curve points of the layer"], "layers.adjustment.curves.points", "curves"),
        (["deplace les points de la courbe", "modifie la courbe a la main", "drag the curve points", "edit the curve by hand"], "curves.points",
         "curves"),
        (["importe un lut", "importe une lut", "charge un lut", "charge une lut", "import a lut", "load a lut"], "color.lut.import", "lutIntensity"),
        (["touche ce qu il faut effacer", "efface ce que je touche", "tap what to erase", "erase what i tap"], "erase.tap", "removeObject"),
        (["efface au pinceau", "gomme au pinceau", "erase with the brush", "brush to erase"], "erase.brush", "removeObject"),
        (["taille de la gomme", "taille du pinceau d effacement", "eraser size", "erase brush size"], "erase.brush.size", "removeObject"),
        (["retouche precise a la baguette", "precise wand"], "precise.wand", "removeObject"),
        (["retouche precise au lasso", "precise lasso"], "precise.lasso", "removeObject"),
        (["pinceau de pixels", "peins des pixels", "pixel brush", "paint pixels"], "precise.pixelBrush", "removeObject"),
        (["outil de clonage", "clone a la main", "clone tool"], "precise.clone", "removeObject"),
        (["taille du pinceau de retouche", "retouch brush size"], "precise.brush.size", "removeObject"),
        (["durete du pinceau de retouche", "retouch brush hardness"], "precise.hardness", "removeObject"),
        (["couleur du pinceau", "brush colour", "brush color"], "precise.paintColor", "removeObject"),
        (["touche ce qui doit etre net", "fais la mise au point ici", "tap to focus", "focus where i tap"], "focus.tap", "lensFocus"),
        (["ajuste le cadre a la main", "deplace le cadre du recadrage", "drag the crop frame", "adjust the crop by hand"], "crop.frame", "crop"),
        (["deplace le texte au doigt", "glisse le texte", "drag the text", "move the text by hand"], "text.move", "moveText"),
        (["place une forme", "pose une forme", "place a shape"], "shapes.place", "selectLayer"),
        (["change de forme", "une autre forme", "another shape"], "shapes.kind", "selectLayer"),
        (["deplace la forme", "glisse la forme", "move the shape", "drag the shape"], "shapes.move", "selectLayer"),
        (["couleur de la forme", "shape colour", "shape color"], "shapes.color", "selectLayer"),
        (["contour de la forme", "shape stroke"], "shapes.outline", "selectLayer"),
        (["touche l objet a modifier", "touche un objet", "tap the object", "tap an object"], "magic.object.tap", "removeObject"),
        (["qualite de l export", "export quality"], "export.quality", "exportPhoto"),
        (["ou enregistrer", "choisis ou enregistrer", "where to save"], "export.location", "exportPhoto"),
        (["annule l export", "cancel the export"], "export.cancel", "exportPhoto"),
        (["touche le calque", "choisis le calque sur la photo", "tap the layer", "pick the layer on the photo"], "canvas.layer.pick", "selectLayer"),
        (["menu du calque", "layer menu"], "canvas.layer.menu", "selectLayer"),
        (["deplace le calque au doigt", "glisse le calque sur la photo", "drag the layer on the photo"], "canvas.layer.drag", "layerTransform"),
    ]

    /// The export sheet's Save and Share buttons, reached by W1's `export` and `share` words.
    static let photoGestureActions: [(control: String, phrase: String, action: IntentAction)] = [
        ("export.save.photos", "enregistre dans photos", .export), ("export.save.files", "enregistre la photo", .export),
        ("export.share", "partage la photo", .share),
    ]

    static func photoGestureRule(_ phrase: String) -> EditIntent? {
        guard let rule = photoGestureRules.first(where: { $0.phrases.contains(phrase) }),
              PhotoOperationHandlers.toolFlag(of: rule.control).map(FeatureFlags.isOn) ?? true, OperationGate.isEnabled(rule.op) else { return nil }
        return call(rule.op, ["openTool": .string(rule.control)])
    }

    // MARK: Recipes (D21)

    /// The recipe phrases, anchored; the product phrases of the W1 `parseGoal` (« photo produit », vinted, etsy…)
    /// mean `recipe productPhoto` (`productRecipeRule`, which runs where parseGoal did, after the export, text,
    /// scene and mask rules).
    static let instagramPhrases = ["prepare pour instagram", "prepare la pour instagram", "prepare la photo pour instagram", "pret pour instagram",
                                   "prete pour instagram", "post instagram", "fais un post instagram", "prepare un post instagram",
                                   "make it instagram ready", "instagram post", "make an instagram post", "ready for instagram", "prep for instagram"]
    static let productPhrases = ["photo produit", "product photo", "product shot", "product picture", "product image", "e commerce", "ecommerce", "vinted",
                                 "leboncoin", "ebay", "etsy", "amazon", "pour vendre", "to sell", "for sale", "shop listing", "listing photo", "fiche produit",
                                 "catalogue", "catalog"]
    static let portraitPhrases = ["retouche portrait", "retouche le portrait", "retouche du portrait", "embellis le portrait", "portrait retouch",
                                  "retouch the portrait", "retouch portrait"]
    static let vlogPhrases = ["nettoie mon vlog", "nettoie le vlog", "nettoyage vlog", "nettoyage du vlog", "clean up my vlog", "clean up the vlog",
                              "vlog cleanup"]

    static func recipeRule(_ u: NormalizedUtterance, phrase: String, context: IntentContext) -> EditIntent? {
        guard FeatureFlags.isOn(.recipes) else { return nil }
        func anchored(_ phrases: [String]) -> Bool { phrases.contains(phrase) }
        switch context.mode {
        case .photo:
            if anchored(instagramPhrases) || u.contains(["pour instagram en story", "instagram ready"]) {
                var args: [String: OpValue] = ["name": .string(RecipeName.instagramPost.rawValue)]
                if u.contains(["story", "stories", "reel", "reels", "9 16"]) { args["format"] = .string("story9x16") }
                if u.contains(["carre", "square", "1 1"]) { args["format"] = .string("square") }
                return layerCall(RecipeExecution.recipeID, args)
            }
            // « retouche portrait légère », "portrait retouch, strong": the phrase, then at most its strength words.
            let strengthWords: Set<String> = ["legere", "leger", "subtile", "light", "subtle", "naturelle", "natural", "forte", "fort", "strong", "marquee",
                                              "tres", "very", "plus", "un", "peu"]
            let modified = portraitPhrases.contains { base in
                phrase.hasPrefix(base + " ") && phrase.dropFirst(base.count + 1).split(separator: " ").allSatisfy { strengthWords.contains(String($0)) }
            }
            if anchored(portraitPhrases) || modified {
                var args: [String: OpValue] = ["name": .string(RecipeName.portraitRetouch.rawValue)]
                if u.contains(["legere", "leger", "subtile", "light", "subtle", "naturelle", "natural"]) { args["strength"] = .number(30) }
                if u.contains(["forte", "fort", "strong", "marquee"]) { args["strength"] = .number(80) }
                return layerCall(RecipeExecution.recipeID, args)
            }
        case .video:
            if anchored(vlogPhrases) || phrase.hasPrefix("nettoie mon vlog ") || phrase.hasPrefix("clean up my vlog ") {
                var args: [String: OpValue] = ["name": .string(RecipeName.vlogCleanup.rawValue)]
                if u.contains(["sans sous titres", "without captions", "no captions"]) { args["captions"] = .bool(false) }
                return layerCall(RecipeExecution.recipeID, args)
            }
        case .pdf:
            break
        }
        return nil
    }

    /// `recipe productPhoto` for a product word anywhere in the clause (« photo produit », vinted, « pour vendre »…),
    /// after the export, text, scene and mask rules have had their turn (« exporte la photo pour vendre » is an
    /// export); never for a clause that writes text or edits something « de la photo produit ».
    static func productRecipeRule(_ u: NormalizedUtterance) -> EditIntent? {
        guard FeatureFlags.isOn(.recipes), u.contains(productPhrases) else { return nil }
        if u.contains(["ecris", "ecrire", "texte", "titre", "legende", "write", "text", "title", "caption", "de la photo produit",
                       "sur la photo produit", "of the product photo", "on the product photo"]) { return nil }
        var args: [String: OpValue] = ["name": .string(RecipeName.productPhoto.rawValue)]
        if let colour = backgroundColour(u) { args["background"] = .string(colour) }
        return layerCall(RecipeExecution.recipeID, args)
    }

    /// « sur fond noir », "on a black background": the product photo's background colour.
    static func backgroundColour(_ u: NormalizedUtterance) -> String? {
        let tokens = u.tokens
        for (index, token) in tokens.enumerated() where token == "fond" || token == "background" {
            let around = tokens[max(0, index - 2)..<min(tokens.count, index + 3)]
            for word in around where PSColor.named(word) != nil && word != "fond" { return englishColour(word) }
        }
        return nil
    }

    /// A colour word as the catalog writes it (English names; PSColor reads French too).
    static func englishColour(_ word: String) -> String {
        let french: [String: String] = ["blanc": "white", "blanche": "white", "noir": "black", "noire": "black", "rouge": "red", "bleu": "blue",
                                        "bleue": "blue", "vert": "green", "verte": "green", "jaune": "yellow", "rose": "pink", "violet": "purple",
                                        "violette": "purple", "gris": "gray", "grise": "gray", "marron": "brown", "beige": "beige", "orange": "orange"]
        return french[word] ?? word
    }

    // MARK: Layer via copy and cut

    static func viaRule(_ phrase: String) -> EditIntent? {
        let copy = ["calque par copier", "calque par copie", "calque via copier", "layer via copy", "new layer via copy"]
        let cut = ["calque par couper", "calque par coupe", "calque via couper", "layer via cut", "new layer via cut"]
        let fromSelection = ["depuis la selection", "de la selection", "a partir de la selection", "from the selection", "from selection"]
        for (phrases, mode) in [(copy, "copy"), (cut, "cut")] {
            for base in phrases {
                if phrase == base { return layerCall("layerVia", ["mode": .string(mode)]) }
                for tail in fromSelection where phrase == base + " " + tail {
                    return layerCall("layerVia", ["mode": .string(mode), "useSelection": .bool(true)])
                }
            }
        }
        return nil
    }

    // MARK: Merges

    static func mergeRule(_ phrase: String) -> EditIntent? {
        let table: [(phrases: [String], mode: String)] = [
            (["fusionne avec le calque du dessous", "fusionne vers le bas", "fusionne le calque vers le bas", "fusionne avec le calque en dessous",
              "merge down", "merge with the layer below"], "down"),
            (["fusionne les calques visibles", "fusionner les calques visibles", "merge visible", "merge the visible layers"], "visible"),
            (["aplatis l image", "aplatis", "aplatir l image", "aplatis la photo", "flatten the image", "flatten image", "flatten"], "flatten"),
            (["tampon des calques visibles", "fais un tampon des calques visibles", "tampon visible", "stamp visible", "stamp the visible layers"], "stamp"),
        ]
        guard let entry = table.first(where: { $0.phrases.contains(phrase) }) else { return nil }
        return layerCall("mergeLayers", ["mode": .string(entry.mode)])
    }

    // MARK: Clipping and groups

    static func clipRule(_ phrase: String) -> EditIntent? {
        let on = ["masque d ecretage", "cree un masque d ecretage", "ajoute un masque d ecretage", "ecrete au calque du dessous", "ecrete le calque",
                  "ecrete le calque au calque du dessous", "clipping mask", "create a clipping mask", "clip to the layer below", "clip the layer"]
        let off = ["libere le masque d ecretage", "enleve le masque d ecretage", "supprime le masque d ecretage", "detache l ecretage", "release clipping mask",
                   "release the clipping mask", "release the clipping"]
        if on.contains(phrase) { return layerCall("layerClip", ["clip": .bool(true)]) }
        if off.contains(phrase) { return layerCall("layerClip", ["clip": .bool(false)]) }
        return nil
    }

    static func groupRule(_ phrase: String) -> EditIntent? {
        if ["groupe les calques", "groupe tous les calques", "mets les calques dans un groupe", "group the layers", "group all layers", "group all the layers"]
            .contains(phrase) {
            return layerCall("groupLayers", ["all": .bool(true)])
        }
        if ["dissocie le groupe", "degroupe", "degroupe le groupe", "dissocie les calques", "ungroup", "ungroup the layers", "ungroup the group"].contains(phrase) {
            return layerCall("groupLayers", ["ungroup": .bool(true)])
        }
        return nil
    }

    // MARK: Adjustment and fill layers

    /// « ajoute un calque de <kind> », « calque de réglage <kind> », "add a <kind> adjustment layer", "add a <kind> layer".
    static let adjustmentKinds: [(words: [String], kind: AdjustmentLayerKind)] = [
        (["courbes", "courbe", "curves"], .curves), (["niveaux", "levels"], .levels),
        (["luminosite", "lumiere", "exposition", "brightness", "light"], .light),
        (["teinte saturation", "teinte et saturation", "tsl", "hue saturation", "hsl"], .hsl),
        (["etalonnage", "color grading", "colour grading", "color grade", "colour grade"], .colorGrade), (["lut"], .lut), (["look", "filtre"], .look),
    ]

    static func adjustmentLayerRule(_ words: [String]) -> EditIntent? {
        let phrase = words.joined(separator: " ")
        let prefixes = ["ajoute un calque de reglage", "ajoute un calque d ajustement", "ajoute un calque de", "ajoute un calque d", "calque de reglage",
                        "nouveau calque de reglage", "nouveau calque de", "add a", "add an"]
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where phrase.hasPrefix(prefix + " ") {
            var rest = String(phrase.dropFirst(prefix.count + 1))
            for suffix in [" adjustment layer", " layer"] where rest.hasSuffix(suffix) { rest = String(rest.dropLast(suffix.count)) }
            if prefix.hasPrefix("add"), !phrase.hasSuffix(" layer") { return nil }
            if rest.hasPrefix("de ") { rest = String(rest.dropFirst(3)) }
            guard let entry = adjustmentKinds.first(where: { $0.words.contains(rest) }) else { return nil }
            return layerCall("addAdjustmentLayer", ["kind": .string(entry.kind.rawValue)])
        }
        return nil
    }

    /// « calque de remplissage <couleur> », « ajoute un calque de remplissage <couleur> », "add a <colour> fill layer".
    static func fillLayerRule(_ words: [String]) -> EditIntent? {
        let phrase = words.joined(separator: " ")
        for prefix in ["ajoute un calque de remplissage", "nouveau calque de remplissage", "calque de remplissage"] where phrase.hasPrefix(prefix) {
            let rest = phrase.dropFirst(prefix.count).split(separator: " ").map(String.init)
            if rest.isEmpty { return layerCall("addFillLayer", ["fill": .string("solid")]) }
            guard rest.count == 1, PSColor.named(rest[0]) != nil else { return nil }
            return layerCall("addFillLayer", ["fill": .string("solid"), "color": .string(englishColour(rest[0]))])
        }
        for prefix in ["add a", "add"] where phrase.hasPrefix(prefix + " ") && phrase.hasSuffix(" fill layer") {
            let middle = phrase.dropFirst(prefix.count + 1).dropLast(" fill layer".count).split(separator: " ").map(String.init)
            if middle.isEmpty || middle == ["solid"] { return layerCall("addFillLayer", ["fill": .string("solid")]) }
            guard middle.count == 1, PSColor.named(middle[0]) != nil else { return nil }
            return layerCall("addFillLayer", ["fill": .string("solid"), "color": .string(middle[0])])
        }
        return nil
    }

    // MARK: Export

    /// « exporte en <format> [<n> bits] [avec les calques] », "export as <format> [<n>-bit]".
    static func exportRule(_ words: [String], phrase: String) -> EditIntent? {
        guard FeatureFlags.isOn(.proExport) else { return nil }
        let leads = [["exporte", "en"], ["exporte", "la", "photo", "en"], ["enregistre", "en"], ["export", "as"], ["export", "to"], ["export", "as", "a"],
                     ["save", "as"], ["exporte", "au", "format"], ["export", "in"]]
        guard let lead = leads.sorted(by: { $0.count > $1.count }).first(where: { words.count > $0.count && Array(words.prefix($0.count)) == $0 }) else { return nil }
        var rest = Array(words.dropFirst(lead.count))
        let formats: [String: ExportFileFormat] = ["png": .png, "jpeg": .jpeg, "jpg": .jpeg, "tiff": .tiff, "tif": .tiff, "psd": .psd, "photoshop": .psd,
                                                   "pdf": .pdf, "heic": .heic, "heif": .heic]
        var args: [String: OpValue] = [:]
        // "16-bit PNG": the depth may come first.
        if rest.count >= 2, ["8", "10", "16"].contains(rest[0]), ["bits", "bit"].contains(rest[1]) {
            args["bitDepth"] = .string(rest[0])
            rest.removeFirst(2)
        }
        guard let first = rest.first, let format = formats[first] else { return nil }
        args["format"] = .string(format.rawValue)
        rest.removeFirst()
        if rest.count >= 2, ["8", "10", "16"].contains(rest[0]), ["bits", "bit"].contains(rest[1]) {
            args["bitDepth"] = .string(rest[0])
            rest.removeFirst(2)
        }
        let layered = [["avec", "les", "calques"], ["avec", "calques"], ["with", "layers"], ["with", "the", "layers"], ["layered"]]
        if let tail = layered.first(where: { rest == $0 }) {
            args["layers"] = .bool(true)
            rest.removeFirst(tail.count)
        }
        if rest == ["sans", "les", "calques"] || rest == ["flattened"] || rest == ["without", "layers"] {
            args["layers"] = .bool(false)
            rest = []
        }
        guard rest.isEmpty else { return nil }
        return layerCall("exportPhoto", args)
    }
}
