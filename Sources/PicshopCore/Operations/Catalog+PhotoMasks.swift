import Foundation

/// Masks and selections (W2): maskAdjust, maskEdit, maskDelete, select, selectionModify and selectionApply, all
/// lowered through the photo handlers. Mask refs: a1…a16 (`RefKind.mask`, "a1" is the first local adjustment);
/// the selection is singular, so it has no ref. The grammar owns only the signature phrases (keywordsOnly).
enum CatalogPhotoMasks {
    static var all: [OperationSpec] { [maskAdjust, maskEdit, maskDelete, select, selectionModify, selectionApply] }

    // MARK: Shared vocabulary

    /// The regions a voice names (MaskRegion raw values), with the words people say for them, folded.
    static let regionAliases: [String: String] = {
        let table: [(String, [String])] = [
            ("subject", ["sujet", "le sujet", "personnage principal", "main subject"]),
            ("background", ["fond", "le fond", "arriere plan", "l arriere plan", "decor", "backdrop"]),
            ("sky", ["ciel", "le ciel", "cieux", "nuages", "clouds"]),
            ("people", ["personnes", "les personnes", "gens", "les gens", "tout le monde", "everyone"]),
            ("person", ["personne", "la personne", "homme", "femme", "enfant", "man", "woman", "child"]),
            ("object", ["objet", "l objet", "chose", "thing"]),
            ("vegetation", ["la vegetation", "arbres", "les arbres", "herbe", "l herbe", "feuillage", "verdure", "trees", "grass", "foliage", "plants"]),
            ("water", ["eau", "l eau", "mer", "la mer", "lac", "riviere", "ocean", "sea", "lake", "river"]),
            ("face", ["visage", "le visage", "visages", "tete"]),
            ("faceSkin", ["peau du visage", "peau", "la peau", "teint", "skin", "face skin"]),
            ("eyes", ["yeux", "les yeux", "oeil", "regard", "eye"]),
            ("lips", ["levres", "les levres", "bouche", "la bouche", "mouth", "lip"]),
            ("teeth", ["dents", "les dents", "sourire", "smile", "tooth"]),
            ("hair", ["cheveux", "les cheveux", "chevelure", "coiffure"]),
            ("bodySkin", ["peau du corps", "body skin", "bras et jambes"]),
            ("top", ["haut", "le haut", "en haut", "partie haute", "upper part"]),
            ("bottom", ["bas", "le bas", "en bas", "partie basse", "lower part"]),
            ("left", ["gauche", "la gauche", "a gauche", "cote gauche", "le cote gauche", "left side"]),
            ("right", ["droite", "la droite", "a droite", "cote droit", "le cote droit", "right side"]),
            ("center", ["centre", "le centre", "milieu", "le milieu", "au centre", "middle", "centre"]),
            ("edges", ["bords", "les bords", "coins", "les coins", "border", "borders", "corners"]),
            ("color", ["couleur", "une couleur", "plage de couleurs", "colour", "colour range", "color range"]),
            ("shadows", ["ombres", "les ombres", "zones sombres", "zone sombre", "parties sombres", "dark areas"]),
            ("midtones", ["tons moyens", "les tons moyens", "demi teintes", "mids"]),
            ("highlights", ["hautes lumieres", "les hautes lumieres", "lumieres", "zones claires", "zone claire", "parties claires", "bright areas"]),
            ("skinTones", ["tons chair", "les tons chair", "carnation", "skin tones", "skin tone"]),
            ("near", ["premier plan", "le premier plan", "proche", "devant", "foreground", "close"]),
            ("far", ["lointain", "au loin", "arriere", "le lointain", "distance", "far away", "the distance"]),
            ("selection", ["la selection", "zone selectionnee", "selected area"]),
        ]
        var aliases: [String: String] = [:]
        for (value, words) in table { for word in words where aliases[word] == nil { aliases[word] = value } }
        return aliases
    }()

    static var regionValues: [String] { values(MaskRegion.self) }

    /// select's `what`: every region, plus the whole picture and the magic wand.
    static var whatValues: [String] { regionValues + ["all", "wand"] }

    static var whatAliases: [String: String] {
        var aliases = regionAliases
        for (word, value) in ["tout": "all", "toute la photo": "all", "toute l image": "all", "everything": "all", "whole photo": "all",
                              "the whole picture": "all", "baguette": "wand", "baguette magique": "wand", "magic wand": "wand"] {
            aliases[word] = value
        }
        return aliases
    }

    /// add, subtract, intersect (CombineMode), in French too.
    static let combineAliases: [String: String] = [
        "ajoute": "add", "ajouter": "add", "ajout": "add", "plus": "add", "union": "add", "retire": "subtract", "retirer": "subtract",
        "enleve": "subtract", "soustrais": "subtract", "soustraire": "subtract", "moins": "subtract", "remove": "subtract",
        "intersection": "intersect", "intersecte": "intersect", "croise": "intersect",
    ]

    /// The area params maskAdjust names a mask with, which maskEdit's `combine` and select read too. In
    /// maskAdjust `where`, `target`, `box` and `point` form the "where" group (one of them names the area).
    static func regionParams(group: String?) -> [ParamSpec] {
        let presence: Presence = group.map { .oneOf(group: $0) } ?? .optional(nil)
        return [
            enumParam("where", regionValues, presence, doc: "area: sky, subject, bottom, shadows…").aliases(regionAliases).keys("region", "area"),
            Step.target(presence, doc: "object or face part noun: cup, teeth"),
            Step.attributes,
            integer("index", 1...8, doc: "person 1, 2… from the left").offCard.keys("person"),
            // Off the card: the prompt's rule teaches `box` (the grounded thing in the last image), the card keeps its room.
            ParamSpec("box", .box, presence, doc: "[x1,y1,x2,y2] 0-1000 of the thing").offCard,
            ParamSpec("point", .point, presence, doc: "[x,y] 0-1000 on the thing").offCard,
            Step.color(doc: "colour for where=color").offCard,
            percent("fuzziness", doc: "colour range width, 0 exact").offCard,
        ]
    }

    /// Linear and radial gradients' handles, in 0…1000 (off the card).
    static func shapeParams(group: String?) -> [ParamSpec] {
        let presence: Presence = group.map { .oneOf(group: $0) } ?? .optional(nil)
        return [
            ParamSpec("start", .point, presence, doc: "linear: full effect from [x,y]").offCard,
            ParamSpec("end", .point, presence, doc: "linear: no effect from [x,y]").offCard,
            ParamSpec("center", .point, presence, doc: "radial: centre [x,y]").offCard,
            percent("radius", 1...100, presence, doc: "radial: size, % of the long side").offCard,
            number("rotation", -180...180, .degrees, presence, doc: "radial: tilt in degrees").offCard,
            percent("roundness", 0...100, presence, doc: "radial: 100 a circle").offCard,
        ]
    }

    // MARK: Masks

    static var maskAdjust: OperationSpec {
        op("maskAdjust", .handler, in: [.photo], .light, .tone,
           title: t("Mask adjustment", "Réglage par masque"), summary: t("A setting on one area, through a mask", "Un réglage sur une zone, par un masque")) { s in
            s.coreIn = [.photo]
            let area = regionParams(group: "where")
            s.params = [area[0], ref("ref", [.mask, .object], .oneOf(group: "where"), doc: "a1 a mask, o1 an object").keys("mask")]
                + area.dropFirst() + shapeParams(group: nil) + [
                    Step.parameter(.oneOf(group: "effect")),
                    enumParam("curve", CatalogPhotoTone.curvePresets, .oneOf(group: "effect"), doc: "a curve shape on the area").offCard,
                    enumParam("band", CatalogPhotoColor.bandValues, .oneOf(group: "effect"), doc: "a colour band (HSL)").aliases(CatalogPhotoColor.bandAliases).offCard,
                    signedPercent("hue", doc: "HSL: shift the band's hue").offCard,
                    signedPercent("saturation", doc: "HSL: the band's saturation").offCard,
                    signedPercent("luminance", doc: "HSL: the band's lightness").offCard,
                    ParamSpec("localColor", .color, .oneOf(group: "effect"), doc: "tint the area: colour name").offCard,
                    percent("localColorAmount", doc: "tint strength").offCard,
                    Step.amount(-100...100, .signedPercent, doc: "relative ±; a bit 10, a lot 40"),
                    enumParam("amountMode", ["relative", "absolute"], .optional("relative"), doc: "relative adds, absolute sets").offCard,
                    percent("feather", doc: "mask edge softness").offCard,
                ]
            s.triggers = [
                .fr: ["le ciel", "éclaircis le ciel", "assombris le bas", "le haut", "en bas de la photo", "dégradé", "sur le sujet", "le fond plus sombre",
                      "l'arrière-plan", "les ombres seulement", "les tons chair", "au premier plan", "au loin", "masque", "filtre gradué", "filtre radial",
                      "seulement le sujet", "assombris le haut", "réglage local", "par zone", "sur les bords", "le bas de la photo", "plus de contraste sur",
                      "sur la personne", "sur l'eau", "sur la végétation"],
                .en: ["darken the bottom", "brighten the sky", "on the subject", "graduated filter", "radial filter", "only the sky", "the background darker",
                      "local adjustment", "the top of the photo", "the bottom of the photo", "more contrast on", "on the edges", "in the shadows only",
                      "the foreground", "in the distance", "through a mask"],
            ]
            s.avoid = [
                .fr: ["remplace le ciel", "supprime le fond", "enlève le fond", "change le ciel", "floute le fond"],
                .en: ["replace the sky", "remove the background", "blur the background"],
            ]
            s.examples = [
                fr("assombris le bas de la photo", ["where": "bottom", "parameter": "exposure", "amount": -20]),
                fr("plus de contraste sur le sujet", ["where": "subject", "parameter": "contrast", "amount": 20]),
                fr("rends le ciel plus profond", ["where": "sky", "parameter": "saturation", "amount": 25]),
                fr("éclaircis les ombres seulement", ["where": "shadows", "parameter": "exposure", "amount": 20]),
                fr("réchauffe un peu les tons chair", ["where": "skinTones", "parameter": "temperature", "amount": 10]),
                fr("un dégradé sombre en haut", ["where": "top", "start": pt(500, 0), "end": pt(500, 450), "parameter": "exposure", "amount": -30]),
                fr("éclaircis la tasse bleue", ["where": "object", "target": "cup", "attributes": .list(["blue"]), "parameter": "exposure", "amount": 20]),
                fr("plus de clarté sur la deuxième personne", ["where": "person", "index": 2, "parameter": "clarity", "amount": 20]),
                fr("assombris tout ce qui est vert", ["where": "color", "color": "green", "fuzziness": 40, "parameter": "exposure", "amount": -20]),
                fr("courbe en S sur le ciel", ["where": "sky", "curve": "sCurve"]),
                fr("sature les bleus du ciel", ["where": "sky", "band": "blue", "saturation": 30]),
                fr("teinte orangée au premier plan", ["where": "near", "localColor": "orange", "localColorAmount": 30]),
                fr("filtre radial lumineux au centre", ["where": "center", "center": pt(500, 500), "radius": 30, "roundness": 80, "parameter": "exposure", "amount": 15]),
                fr("mets l'exposition du ciel à -30", ["where": "sky", "parameter": "exposure", "amountMode": "absolute", "amount": -30]),
                fr("éclaircis encore le masque a1", ["ref": "a1", "parameter": "exposure", "amount": 15]),
                fr("assombris doucement les bords", ["where": "edges", "parameter": "exposure", "amount": -20, "feather": 80]),
                en("darken the bottom", ["where": "bottom", "parameter": "exposure", "amount": -20]),
                en("more contrast on the subject", ["where": "subject", "parameter": "contrast", "amount": 20]),
                en("graduated filter at the top, a bit darker", ["where": "top", "parameter": "exposure", "amount": -15]),
                en("warm up the water", ["where": "water", "parameter": "temperature", "amount": 20]),
                en("make the greens of the trees lighter", ["where": "vegetation", "band": "green", "luminance": 20]),
                en("brighten the thing I'm pointing at", ["point": pt(420, 610), "parameter": "exposure", "amount": 15]),
                en("tilted radial filter on the left, brighter", ["where": "center", "center": pt(300, 450), "radius": 25, "rotation": 30, "parameter": "exposure", "amount": 15]),
                para("le ciel un peu plus sombre stp", .fr, ["where": "sky", "parameter": "exposure", "amount": -15]),
                para("assombrit le bas", .fr, ["where": "bottom", "parameter": "exposure", "amount": -20]),
                para("monte la luminosité de l'objet o1", .fr, ["ref": "o1", "parameter": "brightness", "amount": 20]),
                para("décale la teinte des verts de la végétation", .fr, ["where": "vegetation", "band": "green", "hue": -20]),
                para("brighten this cup", .en, ["where": "object", "target": "cup", "box": box(380, 420, 560, 700), "parameter": "exposure", "amount": 20]),
                fr("éclaircis les personnes", ["where": "people", "parameter": "exposure", "amount": 20]),
                fr("fais ressortir les yeux", ["where": "eyes", "parameter": "clarity", "amount": 20]),
                fr("des lèvres un peu plus rouges", ["where": "lips", "parameter": "saturation", "amount": 20]),
                en("make the teeth less yellow", ["where": "teeth", "parameter": "saturation", "amount": -30]),
                fr("plus de brillance dans les cheveux", ["where": "hair", "parameter": "clarity", "amount": 15]),
                en("warm the skin on the arms", ["where": "bodySkin", "parameter": "temperature", "amount": 15]),
                fr("assombris le côté droit", ["where": "right", "parameter": "exposure", "amount": -20]),
                en("more contrast in the midtones only", ["where": "midtones", "parameter": "contrast", "amount": 15]),
                fr("calme les zones claires", ["where": "highlights", "parameter": "exposure", "amount": -15]),
                near("ajoute un vignettage", .fr, expected: "adjust"),
                near("remplace le ciel par un coucher de soleil", .fr, expected: "generativeFill"),
                near("désature les bleus", .fr, expected: "hsl"),
                near("make it brighter", .en, expected: "adjust"),
                near("éclaircis", .fr, expected: "adjust"),
            ]
            s.verify = [.structural(.localAdjustments, .changed), .pixels(PixelProbe.maskedParameter.rawValue, .changed),
                        .pixels(PixelProbe.maskCoverageInRange.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "masks"
        }
    }

    static var maskEdit: OperationSpec {
        op("maskEdit", .handler, in: [.photo], .selection, .tone,
           title: t("Edit mask", "Modifier le masque"), summary: t("Changes a mask's shape or strength", "Change la forme ou la force d'un masque")) { s in
            let area = regionParams(group: nil).map { param -> ParamSpec in
                // The area a `combine` adds, subtracts or intersects, as maskAdjust names it; `fuzziness` also edits a colour part.
                param.key == "fuzziness" ? param.inGroup("change").offCard : param.offCard
            }
            s.params = [
                ref("ref", [.mask], doc: "a1; none: the last edited").keys("mask"),
                enumParam("combine", CombineMode.self, .oneOf(group: "change"), doc: "add, subtract or intersect an area").aliases(combineAliases),
                boolean("invert", .oneOf(group: "change"), doc: "invert the whole mask"),
                percent("feather", 0...100, .oneOf(group: "change"), doc: "edge softness"),
                signedPercent("expand", .oneOf(group: "change"), doc: "grow +, shrink −").keys("grow"),
                percent("amount", 0...100, .oneOf(group: "change"), doc: "adjustment strength").keys("strength", "opacity"),
                percent("density", 0...100, .oneOf(group: "change"), doc: "mask strength").offCard,
                boolean("visible", .oneOf(group: "change"), doc: "false hides the adjustment").offCard,
                boolean("refresh", .oneOf(group: "change"), doc: "recompute AI masks").offCard,
                text("name", max: 30, .oneOf(group: "change"), doc: "rename the mask").offCard,
                boolean("duplicate", .oneOf(group: "change"), doc: "copy the mask").offCard,
                boolean("show", .oneOf(group: "change"), doc: "show the mask overlay").offCard,
                integer("component", 1...12, doc: "the part of the mask, 1-based").offCard,
                enumParam("componentMode", CombineMode.self, .oneOf(group: "change"), doc: "that part's mode").aliases(combineAliases).offCard,
                boolean("componentInvert", .oneOf(group: "change"), doc: "invert that part").offCard,
                boolean("componentDelete", .oneOf(group: "change"), doc: "remove that part").offCard,
                percent("low", 0...100, .oneOf(group: "change"), doc: "range: low end").offCard,
                percent("high", 0...100, .oneOf(group: "change"), doc: "range: high end").offCard,
                percent("smoothness", 0...100, .oneOf(group: "change"), doc: "range: soft ends").offCard,
            ] + area + shapeParams(group: "change") + [
                ParamSpec("localColor", .color, .oneOf(group: "change"), doc: "tint the area: colour name").offCard,
                percent("localColorAmount", doc: "tint strength").offCard,
            ]
            s.requires = needs(localMask: true)
            s.triggers = [
                .fr: ["ajoute au masque", "retire du masque", "inverse le masque", "adoucis le masque", "étends le masque", "contour du masque",
                      "agrandis le masque", "réduis le masque", "masque plus doux", "renomme le masque", "duplique le masque", "montre le masque",
                      "cache le réglage", "intensité du masque", "le masque 2", "sur le masque"],
                .en: ["subtract from the mask", "add to the mask", "invert the mask", "feather the mask", "expand the mask", "contract the mask",
                      "rename the mask", "duplicate the mask", "show the mask", "mask strength", "soften the mask"],
            ]
            s.examples = [
                fr("inverse le masque", ["invert": true]),
                fr("adoucis le masque a1", ["ref": "a1", "feather": 60]),
                fr("étends un peu le masque", ["expand": 20]),
                fr("retire le sujet du masque a1", ["ref": "a1", "combine": "subtract", "where": "subject"]),
                fr("ajoute le ciel au masque", ["combine": "add", "where": "sky"]),
                fr("garde seulement les ombres dans le masque", ["combine": "intersect", "where": "shadows"]),
                fr("le masque a1 à moitié moins fort", ["ref": "a1", "amount": 50]),
                fr("cache le réglage du masque a1", ["ref": "a1", "visible": false]),
                fr("renomme le masque a1 en Ciel du soir", ["ref": "a1", "name": "Ciel du soir"]),
                fr("duplique le masque a1", ["ref": "a1", "duplicate": true]),
                fr("montre-moi le masque a1", ["ref": "a1", "show": true]),
                fr("mets à jour le masque du ciel", ["ref": "a1", "refresh": true]),
                fr("baisse la densité du masque à 60", ["density": 60]),
                fr("passe la deuxième partie du masque en soustraction", ["component": 2, "componentMode": "subtract"]),
                fr("inverse la première partie du masque", ["component": 1, "componentInvert": true]),
                fr("supprime la deuxième partie du masque", ["component": 2, "componentDelete": true]),
                fr("ne garde que les tons entre 20 et 70 dans le masque", ["low": 20, "high": 70, "smoothness": 30]),
                fr("élargis la plage de couleur du masque", ["fuzziness": 60]),
                fr("descends le dégradé jusqu'au milieu", ["start": pt(500, 0), "end": pt(500, 500)]),
                fr("agrandis le filtre radial", ["center": pt(500, 500), "radius": 45, "rotation": 0, "roundness": 100]),
                fr("teinte bleue dans le masque a1", ["ref": "a1", "localColor": "blue", "localColorAmount": 25]),
                en("subtract the subject from the mask", ["combine": "subtract", "where": "subject"]),
                en("invert the mask", ["invert": true]),
                en("feather the mask a lot", ["feather": 80]),
                en("add this cup to the mask", ["combine": "add", "where": "object", "target": "cup", "attributes": .list(["white"]), "box": box(380, 420, 560, 700)]),
                en("add the second person to the mask", ["combine": "add", "where": "person", "index": 2]),
                en("add the spot I'm pointing at to the mask", ["combine": "add", "point": pt(420, 610)]),
                en("add the reds to the mask", ["combine": "add", "where": "color", "color": "red"]),
                para("rétrécis le masque", .fr, ["expand": -20]),
                para("make the mask weaker", .en, ["amount": 50]),
                near("inverse la sélection", .fr, expected: "selectionModify"),
                near("masque le calque", .fr, expected: "layerVisibility"),
            ]
            s.verify = [.structural(.localAdjustments, .changed), .pixels(PixelProbe.maskCoverage.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "masks"
        }
    }

    static var maskDelete: OperationSpec {
        op("maskDelete", .handler, in: [.photo], .selection, .tone,
           title: t("Delete mask", "Supprimer le masque"), summary: t("Removes a mask and its adjustment", "Supprime un masque et son réglage")) { s in
            s.params = [
                ref("ref", [.mask], doc: "a1; none: the last edited").keys("mask"),
                boolean("all", doc: "every mask"),
            ]
            s.requires = needs(localMask: true, destructive: true)
            s.triggers = [
                .fr: ["supprime le masque", "enlève le masque", "efface le masque", "retire le masque", "supprime tous les masques", "plus de masque"],
                .en: ["delete the mask", "remove the mask", "delete all masks", "remove every mask"],
            ]
            s.examples = [
                fr("supprime le masque"),
                fr("enlève le masque a2", ["ref": "a2"]),
                fr("supprime tous les masques", ["all": true]),
                en("delete the mask"),
                en("remove all the masks", ["all": true]),
                para("vire le masque a1", .fr, ["ref": "a1"]),
                near("supprime le calque", .fr, expected: "deleteLayer"),
                near("supprime le fond", .fr, expected: "removeBackground"),
            ]
            s.verify = [.structural(.localAdjustments, .decreased)]
            s.grammar = .keywordsOnly
            s.uiTool = "masks"
        }
    }

    // MARK: Selections

    static var select: OperationSpec {
        op("select", .handler, in: [.photo], .selection, .refDependent,
           title: t("Select", "Sélectionner"), summary: t("Selects part of the photo", "Sélectionne une partie de la photo")) { s in
            // target, box and point name the thing as `what` would (an object); the rest of the area params as maskAdjust.
            let area = regionParams(group: "what").dropFirst()
            s.params = [
                enumParam("what", whatValues, .oneOf(group: "what"), doc: "what: subject, sky, object, color…").aliases(whatAliases),
                ref("ref", [.object, .mask], .oneOf(group: "what"), doc: "o1 an object, a1 a mask"),
            ] + area + [
                // « la personne à droite », "the left person": where the thing is (also read from `target`'s words).
                Step.spatialHint,
                percent("tolerance", doc: "wand: how alike, 0 exact").offCard,
                boolean("contiguous", doc: "wand: touching pixels only").offCard,
                integer("sampleSize", 1...5, doc: "wand: sample 1, 3 or 5 px").offCard,
                enumParam("mode", ["new", "add", "subtract", "intersect"], .optional("new"), doc: "new, or add, subtract, intersect")
                    .aliases(combineAliases.merging(["nouvelle": "new", "remplace": "new", "replace": "new"]) { first, _ in first }),
            ]
            s.triggers = [
                .fr: ["sélectionne", "sélection", "choisis la tasse", "à la baguette magique", "sélectionne cette couleur", "sélectionne le sujet",
                      "sélectionne le ciel", "sélectionne la tasse", "sélectionne tout", "ajoute à la sélection", "retire de la sélection",
                      "sélectionne les personnes", "sélectionne l'arrière-plan", "détoure la sélection de"],
                .en: ["select the", "select subject", "select sky", "magic wand", "select everything", "add to the selection", "subtract from the selection",
                      "select this colour", "select the people"],
            ]
            s.avoid = [
                .fr: ["calque", "sélectionne le calque", "sélectionne le texte"],
                .en: ["layer", "select the layer", "select the text layer"],
            ]
            s.examples = [
                fr("sélectionne le sujet", ["what": "subject"]),
                fr("sélectionne tous les gens", ["what": "people"]),
                fr("sélectionne le ciel", ["what": "sky"]),
                fr("sélectionne la tasse bleue", ["what": "object", "target": "cup", "attributes": .list(["blue"]), "box": box(380, 420, 560, 700)]),
                fr("sélectionne tout", ["what": "all"]),
                fr("ajoute les personnes à la sélection", ["what": "people", "mode": "add"]),
                fr("retire le ciel de la sélection", ["what": "sky", "mode": "subtract"]),
                fr("garde seulement la partie commune avec le sujet", ["what": "subject", "mode": "intersect"]),
                fr("sélectionne cette couleur", ["what": "color", "point": pt(300, 400), "fuzziness": 30]),
                fr("baguette magique ici", ["what": "wand", "point": pt(620, 380), "tolerance": 25, "contiguous": true, "sampleSize": 3]),
                fr("sélectionne l'objet o1", ["ref": "o1"]),
                fr("sélectionne la deuxième personne", ["what": "person", "index": 2]),
                fr("sélectionne la personne de droite", ["what": "object", "target": "person", "spatialHint": "right"]),
                fr("sélectionne tout ce qui est rouge", ["what": "color", "color": "red"]),
                en("select the subject", ["what": "subject"]),
                en("select the sky", ["what": "sky"]),
                en("select the blue cup", ["what": "object", "target": "cup", "attributes": .list(["blue"])]),
                en("magic wand on the wall", ["what": "wand", "point": pt(150, 300)]),
                en("select the masked area a1", ["ref": "a1"]),
                para("selectione la tasse bleu", .fr, ["what": "object", "target": "cup", "attributes": .list(["blue"])]),
                para("prends le sujet en sélection", .fr, ["what": "subject"]),
                para("select the shadows", .en, ["what": "shadows"]),
                fr("sélectionne la végétation", ["what": "vegetation"]),
                en("select the water", ["what": "water"]),
                fr("sélectionne le visage", ["what": "face"]),
                en("select the skin of the face", ["what": "faceSkin"]),
                fr("sélectionne les yeux", ["what": "eyes"]),
                fr("sélectionne les lèvres", ["what": "lips"]),
                en("select the teeth", ["what": "teeth"]),
                fr("sélectionne les cheveux", ["what": "hair"]),
                en("select the skin of the arms and legs", ["what": "bodySkin"]),
                fr("sélectionne le haut de l'image", ["what": "top"]),
                fr("sélectionne le bas", ["what": "bottom"]),
                en("select the right side", ["what": "right"]),
                fr("sélectionne les bords", ["what": "edges"]),
                en("select the midtones", ["what": "midtones"]),
                fr("sélectionne les tons chair", ["what": "skinTones"]),
                fr("sélectionne le premier plan", ["what": "near"]),
                fr("nouvelle sélection avec le ciel", ["what": "sky", "mode": "new"]),
                near("sélectionne le calque 2", .fr, expected: "selectLayer"),
                near("détoure le sujet", .fr, expected: "removeBackground"),
            ]
            s.verify = [.structural(.selection, .changed), .pixels(PixelProbe.selectionCoverageInRange.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "select"
        }
    }

    static var selectionModify: OperationSpec {
        op("selectionModify", .handler, in: [.photo], .selection, .refDependent,
           title: t("Modify selection", "Modifier la sélection"), summary: t("Inverts, grows, softens or refines it", "L'inverse, l'agrandit, l'adoucit ou l'affine")) { s in
            s.params = [
                boolean("invert", .oneOf(group: "change"), doc: "select the rest"),
                number("grow", 1...500, .none, .oneOf(group: "change"), doc: "grow by pixels").keys("expand"),
                number("shrink", 1...500, .none, .oneOf(group: "change"), doc: "shrink by pixels").keys("contract"),
                number("feather", 0...500, .none, .oneOf(group: "change"), doc: "soft edge, pixels"),
                percent("smooth", 0...100, .oneOf(group: "change"), doc: "smooth the outline").offCard,
                boolean("refine", .oneOf(group: "change"), doc: "refine the edges (Select & Mask)"),
                percent("radius", 0...100, .oneOf(group: "change"), doc: "refine: edge radius").offCard,
                signedPercent("shiftEdge", .oneOf(group: "change"), doc: "refine: move the edge in − out +").offCard,
                percent("contrast", 0...100, .oneOf(group: "change"), doc: "refine: harder edge").offCard,
                percent("decontaminate", 0...100, .oneOf(group: "change"), doc: "refine: remove colour fringes").offCard,
                boolean("deselect", .oneOf(group: "change"), doc: "drop the selection"),
            ]
            s.requires = needs(selection: true)
            s.triggers = [
                .fr: ["inverse la sélection", "agrandis la sélection", "réduis la sélection", "contour progressif", "adoucis les bords de la sélection",
                      "affine les bords", "désélectionne", "lisse la sélection", "étends la sélection", "décontamine les couleurs", "sélectionner et masquer",
                      "plus de sélection", "contracter la sélection", "dilater la sélection", "rétrécis la sélection"],
                .en: ["deselect", "feather the selection", "refine edges", "invert the selection", "grow the selection", "shrink the selection",
                      "smooth the selection", "select and mask", "select none"],
            ]
            s.examples = [
                fr("inverse la sélection", ["invert": true]),
                fr("agrandis la sélection de 10 pixels", ["grow": 10]),
                fr("réduis la sélection de 5 pixels", ["shrink": 5]),
                fr("contour progressif de 20 pixels", ["feather": 20]),
                fr("lisse la sélection", ["smooth": 40]),
                fr("affine les bords", ["refine": true]),
                fr("affine les bords avec un rayon plus large et décale-les vers l'extérieur", ["refine": true, "radius": 50, "shiftEdge": 20]),
                fr("des bords plus nets et décontamine les couleurs", ["contrast": 40, "decontaminate": 60]),
                fr("désélectionne", ["deselect": true]),
                en("deselect", ["deselect": true]),
                en("feather the selection by 30 pixels", ["feather": 30]),
                en("refine edges", ["refine": true]),
                en("invert the selection", ["invert": true]),
                para("tout désélectionner", .fr, ["deselect": true]),
                para("adoucis les bords de la sélection", .fr, ["feather": 15]),
                near("inverse le masque", .fr, expected: "maskEdit"),
                near("affine le visage", .fr, expected: nil),
            ]
            s.verify = [.structural(.selection, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "select"
        }
    }

    /// « Utiliser la sélection pour », in menu order.
    static let useValues = ["adjust", "mask", "erase", "fill", "recolor", "blur", "cutout", "generate"]

    static var selectionApply: OperationSpec {
        op("selectionApply", .handler, in: [.photo], .selection, .composition,
           title: t("Use selection", "Utiliser la sélection"), summary: t("Uses the selection for an edit", "Se sert de la sélection pour une retouche")) { s in
            s.params = [
                enumParam("use", useValues, .required, doc: "what to do with the selection")
                    .aliases(["efface": "erase", "effacer": "erase", "supprime": "erase", "remplis": "fill", "remplir": "fill", "recolore": "recolor",
                              "change la couleur": "recolor", "recolorer": "recolor", "floute": "blur", "flouter": "blur", "detoure": "cutout",
                              "detourer": "cutout", "masque": "mask", "un masque": "mask", "regle": "adjust", "eclaircis": "adjust", "reglage": "adjust",
                              "genere": "generate", "remplace par": "generate", "remove": "erase", "delete": "erase", "cut out": "cutout"])
                    .keys("for"),
                Step.parameter(.optional(nil)),
                Step.amount(-100...100, .signedPercent, doc: "adjust ±; blur 0-100"),
                Step.color(doc: "fill or recolour colour"),
                text("prompt", max: 80, doc: "generate: what to put there").keys("text"),
                boolean("keep", doc: "keep the selection afterwards").offCard,
            ]
            s.requires = needs(selection: true)
            s.triggers = [
                .fr: ["efface la sélection", "remplis la sélection", "floute la sélection", "recolore la sélection", "fais-en un masque",
                      "éclaircis la sélection", "remplace la sélection par", "détoure la sélection", "utilise la sélection", "dans la sélection",
                      "assombris la sélection", "supprime la sélection", "ce qui est sélectionné"],
                .en: ["fill the selection", "erase the selection", "blur the selection", "recolour the selection", "make it a mask",
                      "brighten the selection", "use the selection", "cut out the selection", "replace the selection with"],
            ]
            s.examples = [
                fr("efface la sélection", ["use": "erase"]),
                fr("remplis la sélection de rouge", ["use": "fill", "color": "red"]),
                fr("floute la sélection", ["use": "blur", "amount": 60]),
                fr("recolore la sélection en vert", ["use": "recolor", "color": "green"]),
                fr("fais-en un masque", ["use": "mask"]),
                fr("éclaircis la sélection", ["use": "adjust", "parameter": "exposure", "amount": 20]),
                fr("remplace la sélection par un chapeau", ["use": "generate", "prompt": "un chapeau"]),
                fr("détoure la sélection", ["use": "cutout"]),
                fr("assombris la sélection mais garde-la", ["use": "adjust", "parameter": "exposure", "amount": -20, "keep": true]),
                en("fill the selection with blue", ["use": "fill", "color": "blue"]),
                en("erase the selection", ["use": "erase"]),
                en("blur the selection", ["use": "blur", "amount": 60]),
                en("make it a mask", ["use": "mask"]),
                para("efface ce qui est sélectionné", .fr, ["use": "erase"]),
                para("put a hat where the selection is", .en, ["use": "generate", "prompt": "a hat"]),
                near("efface le chien", .fr, expected: "removeObject"),
                near("floute le fond", .fr, expected: "blurBackground"),
            ]
            s.verify = [.pixels(PixelProbe.selectionUse.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "select"
        }
    }
}

/// A box in 0…1000: [x1, y1, x2, y2].
func box(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> OpValue {
    .box(PSRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
}
