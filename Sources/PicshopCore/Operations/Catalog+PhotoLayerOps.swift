import Foundation

/// W3 layer operations (§8.1): layer via copy and cut, fill and adjustment layers, fill edits, layer masks, clipping,
/// groups, merges, transform, properties, photo layers and the export sheet. All lowered through the photo handlers
/// (PhotoOperationHandlers+Layers, +LayerMasks), never on the fast lane, keywordsOnly: the grammar owns only their
/// signature phrases (RuleBasedIntentEngine+Layers).
///
/// Layer refs are stored and never renumber (D19): i image (the photo is i0), j adjustment and fill, s shape, l text,
/// g group and table bundle. With no ref, a call acts on the selected layer when it fits, else the only candidate.
enum CatalogPhotoLayerOps {
    static var all: [OperationSpec] {
        [addImageLayer, layerVia, addFillLayer, fillLayer, addAdjustmentLayer, layerMask, layerClip, groupLayers, mergeLayers, layerTransform,
         layerProperties, exportPhoto]
    }

    // MARK: Shared vocabulary

    /// Every kind of layer a ref may name.
    static let anyLayer: Set<RefKind> = [.textLayer, .shape, .imageLayer, .adjustmentLayer, .layerGroup]
    /// The layers a tone or colour op may target (D9): image layers and adjustment layers.
    static let toneLayers: Set<RefKind> = [.imageLayer, .adjustmentLayer]

    /// The `layer` param of the tone and colour ops (§8.1): off the card and out of the inspector rows, alias key "ref".
    static func toneLayer(_ doc: String = "i1 or j1; none: the selected") -> ParamSpec {
        ref("layer", toneLayers, doc: doc).keys("ref").offCard.noInspector
    }

    /// The `layer` param that names which layer a mask call creates its mask on (§8.1, D19): an `a<n>` ref carries
    /// its owner, which wins.
    static var maskOwnerLayer: ParamSpec {
        ref("layer", [.imageLayer], doc: "i1 owner of a new mask; none: active").offCard.noInspector
    }

    /// The region fields of layerVia, layerMask and the adjustment layers' masks: the W2 area params (§8.3 order:
    /// `ref a<n>` → `ref o<n>` → `box` → `point` → `where` → `useSelection`). `group` makes them a one-of group.
    static func regionParams(group: String?, whereOnCard: Bool = true) -> [ParamSpec] {
        let presence: Presence = group.map { .oneOf(group: $0) } ?? .optional(nil)
        var whereParam = enumParam("where", CatalogPhotoMasks.regionValues, presence, doc: "area: subject, sky, bottom…")
            .aliases(CatalogPhotoMasks.regionAliases).keys("region", "area").noInspector
        if !whereOnCard { whereParam = whereParam.offCard }
        return [
            whereParam,
            ref("ref", [.mask, .object], presence, doc: "a1 a mask, o1 an object").keys("mask").offCard.noInspector,
            Step.target(presence, doc: "object noun: cup, dog").offCard.noInspector,
            ParamSpec("box", .box, presence, doc: "[x1,y1,x2,y2] 0-1000 of the thing").offCard.noInspector,
            ParamSpec("point", .point, presence, doc: "[x,y] 0-1000 on the thing").offCard.noInspector,
            boolean("useSelection", presence, doc: "the current selection").offCard.noInspector,
        ]
    }

    /// copy / cut, in French too (folded).
    static let viaAliases: [String: String] = [
        "copier": "copy", "copie": "copy", "dupliquer": "copy", "couper": "cut", "coupe": "cut", "decoupe": "cut", "decouper": "cut",
    ]

    // MARK: Photo layers

    static var addImageLayer: OperationSpec {
        op("addImageLayer", .handler, in: [.photo], .layers, .composition,
           title: t("Add a photo layer", "Ajouter une photo en calque"), summary: t("Places another photo over this one", "Place une autre photo par-dessus")) { s in
            s.params = [
                enumParam("fit", ImageLayerFit.self, doc: "fit 80 %, fill, original size").offCard
                    .aliases(["ajuste": "fit", "ajustee": "fit", "remplis": "fill", "remplir": "fill", "couvre": "fill", "taille reelle": "original",
                              "taille d origine": "original", "originale": "original"]),
                enumParam("position", ["top", "aboveSelected"], doc: "on top or above the selected").offCard
                    .aliases(["tout en haut": "top", "en haut": "top", "au dessus": "aboveSelected"]),
            ]
            s.triggers = [
                .fr: ["ajoute une photo", "ajoute une image en calque", "importe une image", "place une photo par-dessus", "insère une image",
                      "photo en calque", "image par-dessus", "ajoute une autre photo", "incruste une photo", "une deuxième image", "pose une image",
                      "depuis ma galerie", "mon logo depuis"],
                .en: ["add a photo as a layer", "place an image", "import a picture", "insert an image", "image layer", "add another photo",
                      "photo on top", "drop in a picture", "from my photos", "my logo in", "a second photo"],
            ]
            s.avoid = [.fr: ["remplace le fond par"], .en: ["replace the background with"]]
            s.examples = [
                fr("ajoute une photo en calque"),
                fr("importe une image par-dessus tout", ["position": "top"]),
                fr("insère une image qui remplit toute la photo", ["fit": "fill"]),
                fr("place une autre photo à sa taille d'origine", ["fit": "original"]),
                en("add a photo as a layer"),
                en("place an image at its original size", ["fit": "original"]),
                para("rajoute une image par dessus", .fr),
                near("ajoute du texte", .fr, expected: "addText"),
                near("remplace le fond par une plage", .fr, expected: "replaceBackground"),
            ]
            s.verify = [.unverifiable("the person picks the photo")]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Layer via copy and cut

    static var layerVia: OperationSpec {
        op("layerVia", .handler, in: [.photo], .layers, .composition,
           title: t("Layer via copy or cut", "Calque par copier ou couper"), summary: t("Puts an area on a layer of its own", "Met une zone sur un calque à part")) { s in
            s.params = [enumParam("mode", ["copy", "cut"], .required, doc: "copy keeps it, cut takes it out").aliases(viaAliases)]
                + regionParams(group: "region")
                + [
                    ref("layer", [.imageLayer], doc: "i1 source; none: active image").offCard.noInspector,
                    text("name", max: 30, doc: "the new layer's name").offCard.noInspector,
                ]
            s.triggers = [
                .fr: ["calque par copier", "calque par couper", "copie la sélection sur un nouveau calque", "mets le sujet sur un calque",
                      "coupe le ciel sur un nouveau calque", "isole le sujet sur son propre calque", "sur un nouveau calque", "sur son propre calque",
                      "sur un calque à part", "nouveau calque avec", "calque séparé", "sur un calque séparé", "sors le sujet"],
                .en: ["layer via copy", "layer via cut", "put the subject on its own layer", "copy the selection to a new layer", "on a new layer",
                      "on its own layer", "cut to a new layer"],
            ]
            s.avoid = [.fr: ["détoure", "duplique le calque"], .en: ["remove the background", "duplicate the layer"]]
            s.examples = [
                fr("mets le sujet sur un calque", ["mode": "copy", "where": "subject"]),
                fr("calque par copier de la sélection", ["mode": "copy", "useSelection": true]),
                fr("coupe le ciel sur un nouveau calque", ["mode": "cut", "where": "sky"]),
                fr("isole la tasse sur son propre calque", ["mode": "copy", "where": "object", "target": "cup"]),
                fr("calque par copier du masque a1", ["mode": "copy", "ref": "a1"]),
                fr("calque par couper du chien, nomme-le Chien", ["mode": "cut", "ref": "o1", "name": "Chien"]),
                en("put the subject on its own layer", ["mode": "copy", "where": "subject"]),
                en("layer via cut from the selection", ["mode": "cut", "useSelection": true]),
                en("copy the dog to a new layer", ["mode": "copy", "ref": "o1"]),
                para("duplique le sujet sur un calque à part", .fr, ["mode": "copy", "where": "subject"]),
                near("détoure le sujet", .fr, expected: "removeBackground"),
                near("duplique le calque", .fr, expected: "duplicateLayer"),
            ]
            s.verify = [.structural(.layerCount, .increased), .pixels(PixelProbe.layerMaskCoverageInRange.rawValue, .changed),
                        .pixels(PixelProbe.compositeUnchanged.rawValue, .unchanged)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Fill layers

    static var fillStyleAliases: [String: String] {
        ["lineaire": "linear", "circulaire": "radial", "rond": "radial", "reflete": "reflected", "miroir": "reflected", "symetrique": "reflected",
         "mirror": "reflected"]
    }

    static var addFillLayer: OperationSpec {
        op("addFillLayer", .handler, in: [.photo], .layers, .composition,
           title: t("Fill layer", "Calque de remplissage"), summary: t("A solid colour or a gradient layer", "Un calque de couleur unie ou de dégradé")) { s in
            s.params = [
                enumParam("fill", ["solid", "gradient"], .required, doc: "solid colour or gradient")
                    .aliases(["couleur": "solid", "unie": "solid", "couleur unie": "solid", "uni": "solid", "degrade": "gradient", "degradee": "gradient"]),
                Step.color(doc: "colour name or #RRGGBB"),
                ParamSpec("color2", .color, doc: "gradient: second colour (none: clear)").keys("to").offCard,
                enumParam("style", GradientFill.Style.self, doc: "gradient: linear, radial, reflected").aliases(fillStyleAliases).offCard,
                number("angle", -180...180, .degrees, doc: "gradient angle, 90 bottom → top").offCard,
                percent("opacity", doc: "layer opacity").offCard,
                enumParam("blend", BlendMode.self, doc: "blend mode").aliases(CatalogPhotoLayers.blendAliases).keys("mode", "blendMode").offCard,
                enumParam("position", ["top", "below", "above"], doc: "where: top, below or above a ref")
                    .aliases(["tout en haut": "top", "en haut": "top", "en dessous": "below", "dessous": "below", "sous": "below",
                              "au dessus": "above", "dessus": "above"]),
                ref("ref", anyLayer, doc: "the layer below/above which").noInspector,
                boolean("useSelection", doc: "masked by the selection").offCard.noInspector,
            ]
            s.triggers = [
                .fr: ["calque de remplissage", "couleur unie", "ajoute un fond blanc en calque", "ajoute un dégradé", "dégradé du noir vers transparent",
                      "dégradé radial", "calque de couleur", "dégradé noir en bas", "voile de couleur"],
                .en: ["fill layer", "solid color layer", "solid colour layer", "add a gradient", "gradient overlay", "gradient layer", "colour overlay",
                      "color overlay", "backdrop layer", "white backdrop", "color layer"],
            ]
            s.avoid = [.fr: ["remplace le fond", "remplis la sélection"], .en: ["replace the background", "fill the selection"]]
            s.examples = [
                fr("ajoute un calque de remplissage blanc", ["fill": "solid", "color": "white"]),
                fr("ajoute un dégradé noir vers transparent en bas", ["fill": "gradient", "color": "black", "angle": 90]),
                fr("dégradé radial bleu et rose", ["fill": "gradient", "color": "blue", "color2": "pink", "style": "radial"]),
                fr("couleur unie rouge à 30 % en mode produit", ["fill": "solid", "color": "red", "opacity": 30, "blend": "multiply"]),
                fr("ajoute un fond blanc en calque sous la tasse", ["fill": "solid", "color": "white", "position": "below", "ref": "i1"]),
                fr("dégradé reflété orange", ["fill": "gradient", "color": "orange", "style": "reflected"]),
                en("add a solid white fill layer", ["fill": "solid", "color": "white"]),
                en("add a black to transparent gradient", ["fill": "gradient", "color": "black"]),
                en("gradient overlay from orange to purple", ["fill": "gradient", "color": "orange", "color2": "purple"]),
                en("blue colour overlay through the selection", ["fill": "solid", "color": "blue", "useSelection": true]),
                para("mets un voile de couleur jaune", .fr, ["fill": "solid", "color": "yellow", "opacity": 40]),
                near("remplace l'arrière-plan par du blanc", .fr, expected: "replaceBackground"),
                near("remplis la sélection de rouge", .fr, expected: "selectionApply"),
            ]
            s.verify = [.structural(.layerCount, .increased), .pixels(PixelProbe.compositeChanged.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    static var fillLayer: OperationSpec {
        op("fillLayer", .handler, in: [.photo], .layers, .composition,
           title: t("Edit fill layer", "Modifier le remplissage"), summary: t("Colour or gradient of a fill layer", "Couleur ou dégradé d'un calque de remplissage")) { s in
            s.params = [
                ref("ref", [.adjustmentLayer], doc: "j1; none: the selected").keys("layer").noInspector,
                ParamSpec("color", .color, .oneOf(group: "change"), doc: "colour (gradient: first stop)").keys("colour", "couleur")
                    .labelled("Colour", "Couleur"),
                ParamSpec("color2", .color, .oneOf(group: "change"), doc: "gradient: last stop").keys("to").offCard.labelled("Second colour", "Couleur 2"),
                ParamSpec("stops", .list(.text(maxLength: 24), max: 8), .oneOf(group: "change"), doc: "[\"red@0\",\"blue@100\"] 2-8").offCard,
                enumParam("style", GradientFill.Style.self, .oneOf(group: "change"), doc: "linear, radial, reflected").aliases(fillStyleAliases)
                    .labelled("Style", "Style"),
                number("angle", -180...180, .degrees, .oneOf(group: "change"), doc: "angle, 90 bottom → top").labelled("Angle", "Angle"),
                percent("scale", 10...150, .oneOf(group: "change"), doc: "gradient length, %").offCard.labelled("Scale", "Échelle"),
                ParamSpec("center", .point, .oneOf(group: "change"), doc: "gradient centre [x,y] 0-1000").offCard,
                boolean("reverse", .oneOf(group: "change"), doc: "true flips the direction").offCard.labelled("Reverse", "Inverser"),
                boolean("dither", .oneOf(group: "change"), doc: "smooth banding").offCard.labelled("Dither", "Tramage"),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["change la couleur du calque de remplissage", "passe le dégradé en radial", "inverse le dégradé", "angle du dégradé",
                      "adoucis le dégradé", "couleur du remplissage", "modifie le dégradé", "dégradé en radial"],
                .en: ["make the fill blue", "make the gradient radial", "reverse the gradient", "gradient angle", "change the fill colour",
                      "change the fill color", "softer gradient"],
            ]
            s.avoid = [.fr: ["ajoute un dégradé", "remplace le fond"], .en: ["add a gradient", "replace the background"]]
            s.examples = [
                fr("change la couleur du calque de remplissage j1 en bleu", ["ref": "j1", "color": "blue"]),
                fr("passe le dégradé j2 en radial", ["ref": "j2", "style": "radial"]),
                fr("inverse le dégradé j2", ["ref": "j2", "reverse": true]),
                fr("mets l'angle du dégradé j2 à 45 degrés", ["ref": "j2", "angle": 45]),
                fr("adoucis le dégradé j2", ["ref": "j2", "scale": 150]),
                fr("le dégradé j2 du bleu au violet", ["ref": "j2", "stops": .list(["blue@0", "purple@100"])]),
                en("make the fill j1 blue", ["ref": "j1", "color": "blue"]),
                en("make the gradient j2 radial", ["ref": "j2", "style": "radial"]),
                en("reverse the gradient j2", ["ref": "j2", "reverse": true]),
                para("le remplissage j1 en vert", .fr, ["ref": "j1", "color": "green"]),
                near("ajoute un dégradé", .fr, expected: "addFillLayer"),
                near("remplace le fond par du bleu", .fr, expected: "replaceBackground"),
            ]
            s.verify = [.pixels(PixelProbe.compositeChanged.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Adjustment layers

    static var adjustmentKindAliases: [String: String] {
        ["lumiere": "light", "luminosite": "light", "exposition": "light", "reglages": "light", "courbes": "curves", "courbe": "curves",
         "niveaux": "levels", "tsl": "hsl", "teinte saturation": "hsl", "teinte saturation luminance": "hsl", "teinte et saturation": "hsl",
         "hue saturation": "hsl", "etalonnage": "colorGrade", "roues": "colorGrade", "roues chromatiques": "colorGrade", "color grade": "colorGrade",
         "colour grade": "colorGrade", "filtre": "look"]
    }

    static var addAdjustmentLayer: OperationSpec {
        op("addAdjustmentLayer", .handler, in: [.photo], .layers, .tone,
           title: t("Adjustment layer", "Calque de réglage"), summary: t("A tone or colour edit on its own layer", "Un réglage de ton ou de couleur sur un calque")) { s in
            s.params = [
                enumParam("kind", AdjustmentLayerKind.self, .required, doc: "the kind of adjustment").aliases(adjustmentKindAliases).keys("type"),
                enumParam("parameter", AdjustmentParameter.self, doc: "light: the setting")
                    .keys("param", "setting"),
                signedPercent("amount", doc: "light ±, colorGrade strength").keys("value"),
                enumParam("preset", CatalogPhotoTone.curvePresets, doc: "curves: a ready-made shape").offCard
                    .aliases(["courbe en s": "sCurve", "en s": "sCurve", "s": "sCurve", "mate": "matte", "mat": "matte"]),
                boolean("auto", doc: "levels: automatic").offCard,
                enumParam("band", CatalogPhotoColor.bandValues, doc: "hsl: the colour").aliases(CatalogPhotoColor.bandAliases).offCard,
                signedPercent("hue", doc: "hsl: the band's hue").offCard,
                signedPercent("saturation", doc: "hsl: the band's saturation").offCard,
                signedPercent("luminance", doc: "hsl: the band's lightness").offCard,
                ParamSpec("shadows", .color, doc: "colorGrade: shadows tint").offCard,
                ParamSpec("midtones", .color, doc: "colorGrade: midtones tint").offCard,
                ParamSpec("highlights", .color, doc: "colorGrade: highlights tint").offCard,
                enumParam("look", FilterPreset.self, doc: "look: the look").offCard.keys("filter"),
                percent("intensity", doc: "look or lut strength").offCard,
                boolean("clip", doc: "clip to the layer below").offCard,
                percent("opacity", doc: "layer opacity").offCard,
                enumParam("blend", BlendMode.self, doc: "blend mode").aliases(CatalogPhotoLayers.blendAliases).keys("mode", "blendMode").offCard,
            ] + regionParams(group: nil, whereOnCard: false)
            s.triggers = [
                .fr: ["calque de réglage", "calque d'ajustement", "ajoute un calque de courbes", "calque de niveaux", "calque teinte saturation",
                      "calque de luminosité", "calque d'étalonnage", "calque de look", "calque LUT", "calque de courbes"],
                .en: ["adjustment layer", "curves layer", "levels adjustment layer", "hue saturation layer", "brightness layer", "levels layer",
                      "colour grade layer", "color grade layer", "LUT layer", "look layer"],
            ]
            s.avoid = [.fr: ["mets les courbes en S"], .en: ["apply an S curve"]]
            s.examples = [
                fr("ajoute un calque de courbes en S", ["kind": "curves", "preset": "sCurve"]),
                fr("calque de réglage luminosité plus 20", ["kind": "light", "parameter": "brightness", "amount": 20]),
                fr("ajoute un calque de niveaux automatiques", ["kind": "levels", "auto": true]),
                fr("calque teinte saturation qui désature les verts", ["kind": "hsl", "band": "green", "saturation": -40]),
                fr("calque d'étalonnage avec des ombres bleues", ["kind": "colorGrade", "shadows": "blue", "amount": 30]),
                fr("ajoute un calque de look noir et blanc", ["kind": "look", "look": "mono"]),
                fr("un calque de courbes écrêté au calque du dessous", ["kind": "curves", "preset": "sCurve", "clip": true]),
                fr("calque de luminosité qui assombrit seulement le ciel", ["kind": "light", "parameter": "exposure", "amount": -20, "where": "sky"]),
                en("add a curves adjustment layer", ["kind": "curves", "preset": "sCurve"]),
                en("levels adjustment layer", ["kind": "levels", "auto": true]),
                en("hue saturation layer with less saturated reds", ["kind": "hsl", "band": "red", "saturation": -30]),
                en("add a LUT layer at 60", ["kind": "lut", "intensity": 60]),
                para("ajoute un calque de réglage pour réchauffer", .fr, ["kind": "light", "parameter": "temperature", "amount": 20]),
                near("mets les courbes en S", .fr, expected: "curves"),
            ]
            s.verify = [.structural(.layerCount, .increased), .pixels(PixelProbe.compositeChanged.rawValue, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Layer masks

    static var layerMaskActionAliases: [String: String] {
        ["ajoute": "add", "ajouter": "add", "cree": "add", "creer": "add", "modifie": "edit", "inverse": "invert", "inverser": "invert",
         "active": "enable", "activer": "enable", "reactive": "enable", "desactive": "disable", "desactiver": "disable", "supprime": "delete",
         "supprimer": "delete", "enleve": "delete", "applique": "apply", "appliquer": "apply", "peins": "paint", "peindre": "paint",
         "dessine": "paint", "pinceau": "paint"]
    }

    static var layerMask: OperationSpec {
        op("layerMask", .handler, in: [.photo], .layers, .composition,
           title: t("Layer mask", "Masque de fusion"), summary: t("Hides parts of a layer with a mask", "Cache des parties d'un calque par un masque")) { s in
            s.params = [
                enumParam("do", ["add", "edit", "invert", "enable", "disable", "delete", "apply", "paint"], .required, doc: "what to do with the mask")
                    .aliases(layerMaskActionAliases),
                boolean("reveal", doc: "add: true shows only the area").offCard.labelled("Reveal", "Révéler"),
            ] + regionParams(group: nil) + [
                enumParam("combine", CombineMode.self, doc: "edit: add, subtract, intersect").aliases(CatalogPhotoMasks.combineAliases).offCard,
                percent("feather", doc: "edge softness").offCard.labelled("Feather", "Contour progressif"),
                percent("density", doc: "mask strength").offCard.labelled("Density", "Densité"),
                signedPercent("expand", doc: "grow +, shrink −").offCard.labelled("Expand", "Étendre"),
                ref("layer", anyLayer, doc: "i1, j1, g1; none: the selected").noInspector,
            ]
            s.triggers = [
                .fr: ["masque de fusion", "ajoute un masque au calque", "masque le calque sauf le sujet", "cache le haut du calque", "inverse le masque du calque",
                      "désactive le masque", "applique le masque", "peins le masque du calque", "masque du calque", "réactive le masque"],
                .en: ["layer mask", "add a layer mask", "hide the top of the layer", "invert the layer mask", "apply the mask", "disable the layer mask",
                      "paint the layer mask"],
            ]
            s.avoid = [.fr: ["masque le calque", "éclaircis le ciel"], .en: ["hide the layer"]]
            s.examples = [
                fr("ajoute un masque de fusion qui garde le sujet", ["do": "add", "where": "subject", "reveal": true]),
                fr("cache le haut du logo i2", ["do": "add", "where": "top", "reveal": false, "layer": "i2"]),
                fr("inverse le masque du calque i1", ["do": "invert", "layer": "i1"]),
                fr("désactive le masque de fusion de i1", ["do": "disable", "layer": "i1"]),
                fr("réactive le masque de fusion de i1", ["do": "enable", "layer": "i1"]),
                fr("applique le masque du calque i1", ["do": "apply", "layer": "i1"]),
                fr("supprime le masque de fusion de i1", ["do": "delete", "layer": "i1"]),
                fr("peins le masque du calque", ["do": "paint"]),
                fr("adoucis le bord du masque de fusion de i1", ["do": "edit", "feather": 60, "layer": "i1"]),
                fr("ajoute le ciel au masque de fusion de i1", ["do": "edit", "combine": "add", "where": "sky", "layer": "i1"]),
                en("add a layer mask from the selection", ["do": "add", "useSelection": true]),
                en("invert the layer mask of i1", ["do": "invert", "layer": "i1"]),
                en("apply the layer mask of i1", ["do": "apply", "layer": "i1"]),
                para("masque de fusion qui cache le bas", .fr, ["do": "add", "where": "bottom", "reveal": false]),
                near("masque le calque", .fr, expected: "layerVisibility"),
                near("éclaircis le ciel", .fr, expected: "selectiveAdjust"),
            ]
            s.verify = [.structural(.layerMasks, .changed), .pixels(PixelProbe.layerMaskCoverageInRange.rawValue, .changed),
                        .pixels(PixelProbe.compositeUnchanged.rawValue, .unchanged), .unverifiable("the person paints")]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Clipping, groups, merges

    static var layerClip: OperationSpec {
        op("layerClip", .handler, in: [.photo], .layers, .composition,
           title: t("Clipping mask", "Masque d'écrêtage"), summary: t("Clips a layer to the one below", "Écrête un calque sur celui du dessous")) { s in
            s.params = [
                ref("ref", anyLayer, doc: "l1, i1, j1; none: the selected").keys("layer").noInspector,
                boolean("clip", .required, doc: "true clips, false releases")
                    .aliases(["ecrete": "true", "ecreter": "true", "attache": "true", "clippe": "true", "libere": "false", "detache": "false",
                              "relache": "false", "release": "false"])
                    .labelled("Clip to the layer below", "Écrêter au calque du dessous"),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["masque d'écrêtage", "écrête au calque du dessous", "attache le calque au calque du dessous", "détache l'écrêtage", "clipping",
                      "écrêtage", "écrête le calque"],
                .en: ["clipping mask", "clip to the layer below", "release clipping mask", "clip the layer", "release the clipping", "unclip",
                      "unclip it"],
            ]
            s.avoid = [.fr: ["recadre"], .en: ["crop"]]
            s.examples = [
                fr("écrête le titre au calque du dessous", ["ref": "l1", "clip": true]),
                fr("masque d'écrêtage sur le calque l2", ["ref": "l2", "clip": true]),
                fr("attache la forme au calque du dessous", ["ref": "s1", "clip": true]),
                fr("détache l'écrêtage du calque l2", ["ref": "l2", "clip": false]),
                en("clip the text to the layer below", ["ref": "l1", "clip": true]),
                en("release the clipping mask of l2", ["ref": "l2", "clip": false]),
                para("clippe le texte sur la photo", .fr, ["ref": "l1", "clip": true]),
                near("recadre", .fr, expected: "crop"),
            ]
            s.verify = [.structural(.layerClipping, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    static var groupLayers: OperationSpec {
        op("groupLayers", .handler, in: [.photo], .layers, .composition,
           title: t("Group layers", "Grouper les calques"), summary: t("Puts layers in a group, or ungroups", "Met des calques dans un groupe, ou dissocie")) { s in
            s.params = [
                ParamSpec("refs", .list(.ref(anyLayer), max: 16), doc: "the layers: l1, s1, i1…").keys("layers").noInspector,
                boolean("all", doc: "every layer above the photo").offCard,
                boolean("ungroup", doc: "dissolve the group ref"),
                ref("ref", [.layerGroup], doc: "g1: the group").noInspector,
                text("name", max: 30, doc: "the group's name").offCard.noInspector,
                boolean("collapse", doc: "fold the group in the list").offCard.labelled("Collapsed", "Replié"),
            ]
            s.requires = needs(layerAboveBase: true)
            s.triggers = [
                .fr: ["groupe les calques", "mets dans un groupe", "regroupe", "dissocie le groupe", "crée un groupe", "dégroupe", "nouveau groupe",
                      "replie le groupe", "dans un dossier", "range les calques", "nouveau dossier"],
                .en: ["group layers", "put these layers in a group", "ungroup", "make a group", "new group", "collapse the group", "in a group",
                      "into one folder", "layer folder", "put in a folder"],
            ]
            s.avoid = [.fr: ["fusionne les calques"], .en: ["merge the layers"]]
            s.examples = [
                fr("groupe les calques l1 et s1", ["refs": .list(["l1", "s1"])]),
                fr("mets le titre et le sous-titre dans un groupe", ["refs": .list(["l1", "l2"])]),
                fr("groupe tous les calques", ["all": true]),
                fr("dissocie le groupe g1", ["ungroup": true, "ref": "g1"]),
                fr("crée un groupe Textes avec l1 et l2", ["refs": .list(["l1", "l2"]), "name": "Textes"]),
                fr("replie le groupe g1", ["ref": "g1", "collapse": true]),
                en("group layers l1 and s1", ["refs": .list(["l1", "s1"])]),
                en("ungroup g1", ["ungroup": true, "ref": "g1"]),
                para("regroupe le texte et la forme", .fr, ["refs": .list(["l1", "s1"])]),
                near("fusionne les calques", .fr, expected: "mergeLayers"),
            ]
            s.verify = [.structural(.layerStructure, .changed)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    static var mergeLayers: OperationSpec {
        op("mergeLayers", .handler, in: [.photo], .layers, .composition,
           title: t("Merge layers", "Fusionner les calques"), summary: t("Merge down, merge visible, flatten, stamp", "Fusionne vers le bas, aplatit, tamponne")) { s in
            s.params = [
                enumParam("mode", ["down", "visible", "flatten", "stamp", "selected"], .required, doc: "down, visible, flatten, stamp, selected")
                    .aliases(["vers le bas": "down", "avec le calque du dessous": "down", "en dessous": "down", "visibles": "visible", "aplatis": "flatten",
                              "aplatir": "flatten", "tout": "flatten", "tampon": "stamp", "sur un nouveau calque": "stamp", "ces calques": "selected",
                              "ensemble": "selected", "merge down": "down"]),
                ref("ref", anyLayer, doc: "down: the upper layer; none: selected").noInspector,
                ParamSpec("refs", .list(.ref(anyLayer), max: 16), doc: "selected: the layers to merge").offCard.noInspector,
                boolean("confirm", doc: "flatten: hidden layers may go").offCard.noInspector,
            ]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["fusionne avec le calque du dessous", "fusionne vers le bas", "fusionne les calques visibles", "aplatis l'image", "fusionne tout",
                      "tampon des calques visibles", "aplatis", "fusionne ces calques", "fusionner les calques"],
                .en: ["merge down", "merge visible", "flatten image", "stamp visible", "flatten", "merge these layers", "merge layers"],
            ]
            s.avoid = [.fr: ["groupe les calques", "mode fondu"], .en: ["group the layers"]]
            s.examples = [
                fr("fusionne avec le calque du dessous", ["mode": "down"]),
                fr("fusionne les calques visibles", ["mode": "visible"]),
                fr("aplatis l'image", ["mode": "flatten"]),
                fr("tampon des calques visibles", ["mode": "stamp"]),
                fr("fusionne l1 et s1 ensemble", ["mode": "selected", "refs": .list(["l1", "s1"])]),
                fr("fusionne le sous-titre vers le bas", ["mode": "down", "ref": "l2"]),
                en("merge down", ["mode": "down"]),
                en("flatten the image", ["mode": "flatten"]),
                en("stamp visible", ["mode": "stamp"]),
                para("aplatis tout", .fr, ["mode": "flatten"]),
                near("groupe les calques", .fr, expected: "groupLayers"),
            ]
            s.verify = [.structural(.layerCount, .decreased), .structural(.layerCount, .increased),
                        .pixels(PixelProbe.compositeUnchanged.rawValue, .unchanged)]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Transform and properties

    static var layerTransform: OperationSpec {
        op("layerTransform", .handler, in: [.photo], .layers, .composition,
           title: t("Transform layer", "Transformer le calque"), summary: t("Moves, scales, rotates, skews a layer", "Déplace, redimensionne, tourne, incline un calque")) { s in
            s.params = [
                ref("ref", anyLayer, doc: "l1, s1, i1; none: the selected").keys("layer").noInspector,
                ParamSpec("refs", .list(.ref(anyLayer), max: 16), doc: "align: the layers").offCard.noInspector,
                ParamSpec("center", .point, doc: "new centre [x,y] 0-1000").offCard.noInspector,
                number("x", 0...1000, .none, doc: "bounds centre x 0-1000").offCard.labelled("X", "X"),
                number("y", 0...1000, .none, doc: "bounds centre y 0-1000").offCard.labelled("Y", "Y"),
                number("dx", -1000...1000, .none, doc: "move right +, left − (0-1000)").noInspector,
                number("dy", -1000...1000, .none, doc: "move down +, up − (0-1000)").noInspector,
                percent("scale", 1...1000, doc: "% of the natural size").offCard.labelled("Scale", "Échelle"),
                percent("scaleBy", 10...1000, doc: "multiplies the scale, %").noInspector
                    .aliases(["de moitie": "50", "moitie": "50", "half": "50", "double": "200", "deux fois plus grand": "200", "twice": "200"]),
                percent("scaleX", 1...1000, doc: "width, % of natural").offCard.labelled("Width", "Largeur"),
                percent("scaleY", 1...1000, doc: "height, % of natural").offCard.labelled("Height", "Hauteur"),
                number("rotation", -360...360, .degrees, doc: "degrees, clockwise").labelled("Rotation", "Rotation"),
                boolean("relative", doc: "rotation and scales add up").offCard.noInspector,
                number("skewX", -60...60, .degrees, doc: "horizontal skew").labelled("Skew X", "Inclinaison X"),
                number("skewY", -60...60, .degrees, doc: "vertical skew").offCard.labelled("Skew Y", "Inclinaison Y"),
                ParamSpec("corners", .list(.point, max: 4), doc: "4 corners TL,TR,BR,BL 0-1000").offCard,
                enumParam("mode", ["free", "skew", "distort", "perspective"], doc: "handles: free, skew, distort…").offCard.noInspector
                    .aliases(["libre": "free", "incline": "skew", "inclinaison": "skew", "deforme": "distort", "deformation": "distort"]),
                enumParam("flip", ["horizontal", "vertical"], doc: "mirror the layer").offCard.noInspector
                    .aliases(["miroir": "horizontal", "horizontalement": "horizontal", "verticalement": "vertical", "a l envers": "vertical"]),
                enumParam("fit", ["fit", "fill", "reset"], doc: "fit, fill the canvas, or reset").offCard.noInspector
                    .aliases(["ajuste": "fit", "remplis": "fill", "couvre": "fill", "reinitialise": "reset", "annule": "reset"]),
                enumParam("align", LayerAlignment.allCases.map(\.rawValue) + ["center"], doc: "align or distribute").offCard.noInspector
                    .aliases(["centre": "center", "au milieu": "center", "au centre": "center", "a gauche": "left", "gauche": "left", "a droite": "right",
                              "droite": "right", "en haut": "top", "haut": "top", "en bas": "bottom", "bas": "bottom", "centre horizontal": "centerH",
                              "centre vertical": "centerV", "repartis horizontalement": "distributeH", "repartis verticalement": "distributeV"]),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["agrandis le calque", "réduis le logo", "déplace le calque à gauche", "tourne le calque de 15 degrés", "incline le calque",
                      "déforme le calque", "mets en perspective le calque", "centre le calque", "étire en largeur", "transforme le calque",
                      "aligne les calques", "retourne le calque", "décale le calque", "décale vers la droite", "pousse le calque"],
                .en: ["scale the layer", "move the layer left", "rotate the layer", "skew the layer", "distort the layer", "center the layer",
                      "stretch it wider", "transform the layer", "align the layers", "flip the layer", "nudge the layer", "layer bigger",
                      "make the layer smaller", "shift the layer"],
            ]
            s.avoid = [.fr: ["tourne la photo", "corrige la perspective"], .en: ["rotate the photo", "fix the perspective"]]
            s.examples = [
                fr("agrandis le calque", ["scaleBy": 120]),
                fr("réduis le logo i1 de moitié", ["ref": "i1", "scaleBy": 50]),
                fr("déplace le calque à gauche", ["dx": -50]),
                fr("tourne le calque de 15 degrés", ["rotation": 15, "relative": true]),
                fr("incline le calque de 10 degrés", ["skewX": 10]),
                fr("mets le calque en perspective", ["mode": "perspective"]),
                fr("centre le calque", ["align": "center"]),
                fr("étire le calque en largeur", ["scaleX": 20, "relative": true]),
                fr("aligne l1 et s1 à gauche", ["refs": .list(["l1", "s1"]), "align": "left"]),
                fr("retourne le calque horizontalement", ["flip": "horizontal"]),
                fr("mets le logo i1 à 150 %", ["ref": "i1", "scale": 150]),
                fr("place les coins du logo i1", ["ref": "i1", "corners": .list([pt(200, 200), pt(800, 250), pt(780, 800), pt(220, 760)])]),
                fr("réinitialise la transformation du calque", ["fit": "reset"]),
                en("scale the layer to 150 %", ["scale": 150]),
                en("move the layer left", ["dx": -50]),
                en("rotate the layer 30 degrees", ["rotation": 30, "relative": true]),
                en("center the layer", ["align": "center"]),
                en("distort the layer", ["mode": "distort"]),
                para("rapetisse le calque", .fr, ["scaleBy": 83]),
                near("tourne la photo", .fr, expected: "rotate"),
                near("corrige la perspective", .fr, expected: "perspective"),
            ]
            s.verify = [.structural(.layerTransform, .changed), .unverifiable("the person drags the corners")]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    static var layerProperties: OperationSpec {
        op("layerProperties", .handler, in: [.photo], .layers, .composition,
           title: t("Layer fill, lock and name", "Fond, verrou et nom du calque"), summary: t("Fill opacity, locks and the layer's name", "Opacité du fond, verrous et nom du calque")) { s in
            s.params = [
                ref("ref", anyLayer, doc: "l1, i1, g1; none: the selected").keys("layer").noInspector,
                percent("fill", 0...100, .oneOf(group: "change"), doc: "fill opacity, %").keys("fillOpacity").labelled("Fill", "Fond"),
                enumParam("lock", ["all", "position", "pixels", "transparency", "none"], .oneOf(group: "change"), doc: "what is locked")
                    .aliases(["tout": "all", "verrouille": "all", "transparence": "transparency", "rien": "none", "deverrouille": "none", "aucun": "none",
                              "unlock": "none"])
                    .labelled("Lock", "Verrou"),
                text("name", max: 40, .oneOf(group: "change"), doc: "rename the layer").keys("rename").noInspector,
                boolean("passThrough", .oneOf(group: "change"), doc: "group: pass through").offCard.labelled("Pass through", "Transfert"),
                boolean("maskLinked", .oneOf(group: "change"), doc: "mask moves with the layer").offCard.labelled("Mask linked", "Masque lié"),
            ]
            s.triggers = [
                .fr: ["fond du calque à 50 %", "opacité du fond", "verrouille le calque", "déverrouille", "verrouille la position", "renomme le calque",
                      "mode transfert", "fond du calque", "nom du calque", "lie le masque"],
                .en: ["fill opacity", "lock the layer", "unlock", "rename the layer", "pass through", "lock position", "layer name"],
            ]
            s.avoid = [.fr: ["opacité du calque"], .en: ["layer opacity"]]
            s.examples = [
                fr("fond du calque à 50 %", ["fill": 50]),
                fr("verrouille le calque", ["lock": "all"]),
                fr("verrouille la position du titre", ["ref": "l1", "lock": "position"]),
                fr("déverrouille le calque", ["lock": "none"]),
                fr("renomme le calque en Titre principal", ["name": "Titre principal"]),
                fr("mets le groupe g1 en mode transfert", ["ref": "g1", "passThrough": true]),
                fr("verrouille la transparence de la forme", ["ref": "s1", "lock": "transparency"]),
                en("set the fill opacity to 40", ["fill": 40]),
                en("lock the layer", ["lock": "all"]),
                en("rename the layer to Logo", ["name": "Logo"]),
                para("le fond du calque à moitié", .fr, ["fill": 50]),
                near("opacité du calque à 50", .fr, expected: "layerOpacity"),
            ]
            s.verify = [.structural(.layerFillOpacity, .equalsParam("fill")), .structural(.layerLock, .changed), .unverifiable("names and settings")]
            s.grammar = .keywordsOnly
            s.uiTool = "layers"
        }
    }

    // MARK: Export

    static var exportPhoto: OperationSpec {
        op("exportPhoto", .handler, in: [.photo], .export, .output,
           title: t("Export as", "Exporter en"), summary: t("Opens the export sheet on a format", "Ouvre l'export sur un format")) { s in
            s.params = [
                enumParam("format", ExportFileFormat.self, .oneOf(group: "what"), doc: "file format")
                    .aliases(["jpg": "jpeg", "tif": "tiff", "photoshop": "psd", "heif": "heic"]),
                enumParam("bitDepth", ["8", "10", "16"], doc: "bits per channel")
                    .aliases(["8 bits": "8", "10 bits": "10", "16 bits": "16", "8 bit": "8", "10 bit": "10", "16 bit": "16"]),
                enumParam("colorSpace", ["displayP3", "sRGB"], doc: "colour space").offCard
                    .aliases(["p3": "displayP3", "display p3": "displayP3"]),
                enumParam("size", ["full", "4096", "2048", "1080"], doc: "long side in pixels").offCard
                    .aliases(["originale": "full", "pleine taille": "full", "taille originale": "full", "full size": "full"]),
                boolean("layers", doc: "PSD: keep the layers").offCard,
                enumParam("preset", ["instagram", "print", "web"], .oneOf(group: "what"), doc: "ready-made settings")
                    .aliases(["impression": "print", "imprimer": "print", "insta": "instagram"]),
            ]
            s.triggers = [
                .fr: ["exporte en PNG 16 bits", "enregistre en TIFF", "exporte en PSD avec les calques", "fais un PDF de la photo", "HEIC 10 bits",
                      "exporte pour l'impression", "exporte en", "exporte pour le web", "exporte pour Instagram", "fichier PSD"],
                .en: ["export as a 16-bit PNG", "save as TIFF", "export a layered PSD", "export as PDF", "export as", "export for print",
                      "export for the web", "PSD file"],
            ]
            s.avoid = [.fr: ["partage la photo", "enregistre cette version"], .en: ["share the photo", "save this version"]]
            s.examples = [
                fr("exporte en PNG 16 bits", ["format": "png", "bitDepth": "16"]),
                fr("enregistre en TIFF", ["format": "tiff"]),
                fr("exporte en PSD avec les calques", ["format": "psd", "layers": true]),
                fr("fais un PDF de la photo", ["format": "pdf"]),
                fr("exporte en HEIC 10 bits", ["format": "heic", "bitDepth": "10"]),
                fr("exporte pour l'impression", ["preset": "print"]),
                fr("exporte en JPEG sRGB en 2048", ["format": "jpeg", "colorSpace": "sRGB", "size": "2048"]),
                en("export as a 16-bit PNG", ["format": "png", "bitDepth": "16"]),
                en("export a layered PSD", ["format": "psd", "layers": true]),
                en("export for Instagram", ["preset": "instagram"]),
                en("export for the web", ["preset": "web"]),
                para("sors-moi un TIFF 16 bits", .fr, ["format": "tiff", "bitDepth": "16"]),
                near("partage la photo", .fr, expected: "share"),
                near("enregistre cette version", .fr, expected: "saveVersion"),
            ]
            s.verify = [.unverifiable("the person confirms the export")]
            s.grammar = .keywordsOnly
            s.uiTool = "export"
        }
    }
}
