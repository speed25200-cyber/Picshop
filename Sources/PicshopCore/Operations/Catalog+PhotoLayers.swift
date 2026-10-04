import Foundation

/// Layers: select, duplicate and delete, and the W1 layer properties (opacity, blend mode,
/// visibility, order). Layer refs: l2 a text layer, s1 a shape, i1 an image layer; W3 adds j1 an adjustment or
/// fill layer and g1 a group or a table bundle (stored refs that never renumber, D19); no ref is the selected layer.
enum CatalogPhotoLayers {
    static var all: [OperationSpec] { [selectLayer, duplicateLayer, deleteLayer, layerOpacity, layerBlend, layerVisibility, layerOrder] }

    static var selectLayer: OperationSpec {
        legacy(.selectLayer, in: [.photo], .layers, .composition,
               title: t("Select layer", "Sélectionner un calque"), summary: t("Picks the layer the next edits apply to", "Choisit le calque des prochaines retouches")) { s in
            s.params = [Step.choiceIndex(-1...99, doc: "layer number, -1 top"), Step.textChoice(["text", "image"], doc: "the text or the photo"),
                        PicshopCore.ref("ref", allLayerRefs, doc: "l1, i1, j1, g1: that layer").keys("layer")]
            s.triggers = [
                .fr: ["sélectionne le calque", "choisis le calque", "prends le calque", "active le calque", "va au calque", "passe au calque", "sélectionne le texte",
                      "sélectionne la photo", "va sur le groupe"],
                .en: ["select the layer", "select layer", "go to layer", "take the layer", "select the text layer", "select the group"],
            ]
            s.examples = [
                fr("sélectionne le calque 2", ["choiceIndex": 2]),
                fr("sélectionne le texte", ["text": "text"]),
                en("select layer 2", ["choiceIndex": 2]),
                fr("passe au calque 1", ["choiceIndex": 1]),
                en("select the text layer", ["text": "text"]),
                fr("va sur le groupe g1", ["ref": "g1"]),
                fr("active le calque de réglage j3", ["ref": "j3"]),
                en("select layer i1", ["ref": "i1"]),
                near("sélectionne la tasse rouge", .fr, expected: "select"),
            ]
            // W3: a ref is checked on the document's stored refs (the selected layer's ref equals it).
            s.verify = [.structural(.selectedLayer, .equalsParam("ref"))]
            s.grammar = .owned
            s.uiTool = "layers"
        }
    }

    static var duplicateLayer: OperationSpec {
        legacy(.duplicateLayer, in: [.photo], .layers, .composition,
               title: t("Duplicate layer", "Dupliquer le calque"), summary: t("Copies the selected layer", "Copie le calque sélectionné")) { s in
            s.params = [PicshopCore.ref("ref", allLayerRefs, doc: "l1, i1, j1, g1; none: the selected").keys("layer")]
            s.triggers = [
                .fr: ["duplique le calque", "copie le calque", "duplique", "calque"],
                .en: ["duplicate the layer", "copy the layer", "duplicate", "layer"],
            ]
            s.examples = [
                fr("duplique le calque"),
                fr("copie le calque"),
                en("duplicate the layer"),
                fr("fais une copie du calque"),
                en("copy this layer"),
                fr("duplique le logo i2", ["ref": "i2"]),
                en("duplicate the group g1", ["ref": "g1"]),
                near("supprime le calque", .fr, expected: "deleteLayer"),
            ]
            s.verify = [.structural(.layerCount, .increased)]
            s.grammar = .owned
            s.uiTool = "layers"
        }
    }

    static var deleteLayer: OperationSpec {
        legacy(.deleteLayer, in: [.photo], .layers, .composition,
               title: t("Delete layer", "Supprimer le calque"), summary: t("Removes the selected layer", "Supprime le calque sélectionné")) { s in
            s.params = [PicshopCore.ref("ref", allLayerRefs, doc: "l1, i1, j1, g1; none: the selected").keys("layer")]
            s.requires = needs(nonBaseLayer: true, destructive: true)
            s.triggers = [
                .fr: ["supprime le calque", "efface le calque", "enlève le calque", "calque"],
                .en: ["delete the layer", "remove the layer", "delete layer", "layer"],
            ]
            s.examples = [
                fr("supprime le calque"),
                fr("enlève le calque"),
                en("delete the layer"),
                fr("retire ce calque"),
                en("remove this layer"),
                fr("supprime le calque de réglage j3", ["ref": "j3"]),
                en("delete the layer s1", ["ref": "s1"]),
                near("masque le calque", .fr, expected: "layerVisibility"),
            ]
            s.verify = [.structural(.layerCount, .decreased)]
            s.grammar = .owned
            s.uiTool = "layers"
        }
    }

    // MARK: W1 layer properties

    static let layerRefs: Set<RefKind> = [.textLayer, .shape, .imageLayer, .adjustmentLayer, .layerGroup]
    /// Every layer kind a ref names (W3, D19): text, shape, image, adjustment and fill, group and table bundle.
    static let allLayerRefs: Set<RefKind> = [.textLayer, .shape, .imageLayer, .adjustmentLayer, .layerGroup]

    static var layerOpacity: OperationSpec {
        op("layerOpacity", .handler, in: [.photo], .layers, .composition,
           title: t("Layer opacity", "Opacité du calque"), summary: t("How see-through a layer is", "La transparence d'un calque")) { s in
            s.params = [
                ref("ref", layerRefs, doc: "l2, s1, i1, j1, g1; none: selected").keys("layer"),
                percent("opacity", 0...100, .required, doc: "0 invisible, 100 solid").keys("amount", "value").labelled("Opacity", "Opacité"),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["opacité", "opacité du calque", "transparence du calque", "calque transparent", "rends le calque transparent"],
                .en: ["opacity", "layer opacity", "transparency of the layer", "see-through"],
            ]
            s.examples = [
                fr("baisse l'opacité du calque à 50 %", ["opacity": 50]),
                fr("mets le calque l2 à 30 % d'opacité", ["ref": "l2", "opacity": 30]),
                fr("rends le texte à moitié transparent", ["ref": "l1", "opacity": 50]),
                en("set the layer opacity to 50", ["opacity": 50]),
                para("opa du calque à 80", .fr, ["opacity": 80]),
                en("make the layer half transparent", ["opacity": 50]),
                fr("baisse l'opacité du groupe g1 à 60 %", ["ref": "g1", "opacity": 60]),
                near("cache le calque", .fr, expected: "layerVisibility"),
            ]
            s.verify = [.structural(.layerOpacity, .equalsParam("opacity"))]
            s.uiTool = "layers"
        }
    }

    /// Generic French words for the blend modes, voice aliases only (folded).
    static let blendAliases: [String: String] = [
        "produit": "multiply", "superposition": "overlay", "incrustation": "overlay", "lumiere tamisee": "softLight", "lumiere crue": "hardLight",
        "ecran": "screen", "obscurcir": "darken", "eclaircir": "lighten", "difference": "difference", "soustraction": "subtract",
        "densite couleur plus": "colorDodge", "densite couleur moins": "colorBurn", "densite lineaire plus": "linearDodge",
        "densite lineaire moins": "linearBurn", "lumiere vive": "vividLight", "lumiere lineaire": "linearLight", "lumiere ponctuelle": "pinLight",
        "melange maximal": "hardMix", "couleur plus claire": "lighterColor", "couleur plus foncee": "darkerColor", "teinte": "hue",
        "couleur": "color", "luminosite": "luminosity", "fondu": "dissolve", "exclusion": "exclusion", "division": "divide",
        "saturation": "saturation", "normal": "normal", "add": "linearDodge", "addition": "linearDodge",
    ]

    static var layerBlend: OperationSpec {
        op("layerBlend", .handler, in: [.photo], .layers, .composition,
           title: t("Blend mode", "Mode de fusion"), summary: t("How a layer mixes with what is below", "Comment un calque se mêle au dessous")) { s in
            s.params = [
                ref("ref", layerRefs, doc: "l2, s1, i1, j1, g1; none: selected").keys("layer"),
                enumParam("mode", BlendMode.self, .required, doc: "blend mode").aliases(blendAliases).keys("blendMode", "blend")
                    .labelled("Blend mode", "Mode de fusion"),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["mode de fusion", "mode produit", "en mode produit", "mode superposition", "mode écran", "mode lumière tamisée",
                      "mode incrustation", "mode différence", "fusion du calque", "calque en mode", "calque en produit", "calque en superposition",
                      "calque en écran", "calque en éclaircir", "calque en obscurcir", "calque en incrustation", "calque en lumière tamisée"],
                .en: ["blend mode", "blending mode", "multiply mode", "screen mode", "overlay mode", "soft light", "set to multiply", "layer to multiply",
                      "layer to screen", "layer to overlay", "layer to lighten", "layer to darken"],
            ]
            s.examples = [
                fr("mets le calque en mode produit", ["mode": "multiply"]),
                fr("mode de fusion superposition", ["mode": "overlay"]),
                fr("passe le texte en mode écran", ["ref": "l1", "mode": "screen"]),
                en("set the blend mode to multiply", ["mode": "multiply"]),
                en("screen blend mode for the text layer", ["ref": "l1", "mode": "screen"]),
                para("calque en lumière tamisée", .fr, ["mode": "softLight"]),
                fr("passe le calque de remplissage j1 en mode incrustation", ["ref": "j1", "mode": "overlay"]),
                near("fusionne les calques", .fr, expected: "mergeLayers"),
            ]
            s.verify = [.structural(.layerBlend, .equalsParam("mode"))]
            s.uiTool = "layers"
        }
    }

    static var layerVisibility: OperationSpec {
        op("layerVisibility", .handler, in: [.photo], .layers, .composition,
           title: t("Show or hide layer", "Afficher ou masquer"), summary: t("Hides or shows a layer", "Masque ou affiche un calque")) { s in
            s.params = [
                ref("ref", layerRefs, doc: "l2, s1, i1, j1, g1; none: selected").keys("layer"),
                boolean("visible", .required, doc: "false hides it").keys("shown", "show").labelled("Visible", "Visible"),
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["masque le calque", "cache le calque", "affiche le calque", "réaffiche le calque", "calque invisible", "calque visible", "éteins le calque",
                      "allume le calque", "calque éteint", "calque allumé", "fais disparaître ce calque", "fais réapparaître le calque"],
                .en: ["hide the layer", "show the layer", "layer visibility", "make the layer invisible", "unhide the layer", "turn the layer off",
                      "turn off the layer", "turn the layer on", "turn on the layer", "layer off"],
            ]
            s.examples = [
                fr("masque le calque", ["visible": false]),
                fr("réaffiche le calque l1", ["ref": "l1", "visible": true]),
                fr("cache le calque du texte", ["ref": "l1", "visible": false]),
                en("hide the layer", ["visible": false]),
                near("supprime le calque", .fr, expected: "deleteLayer"),
                en("show layer l1 again", ["ref": "l1", "visible": true]),
                fr("cache le groupe g1", ["ref": "g1", "visible": false]),
            ]
            s.verify = [.structural(.layerVisibility, .equalsParam("visible"))]
            s.uiTool = "layers"
        }
    }

    static var layerOrder: OperationSpec {
        op("layerOrder", .handler, in: [.photo], .layers, .composition,
           title: t("Layer order", "Ordre des calques"), summary: t("Brings a layer forward or sends it back", "Avance ou recule un calque")) { s in
            s.params = [
                ref("ref", layerRefs, doc: "l2, s1, i1, j1, g1; none: selected").keys("layer"),
                enumParam("position", ["front", "back", "forward", "backward", "above", "below"], .oneOf(group: "where"), doc: "where it goes")
                    .aliases(["premier plan": "front", "devant": "forward", "au dessus": "forward", "arriere plan": "back", "tout derriere": "back",
                              "derriere": "backward", "en dessous": "backward", "top": "front", "bottom": "back", "up": "forward", "down": "backward",
                              "au dessus de": "above", "en dessous de": "below", "sous": "below"]),
                // W3: above or below another layer (`target` with position above/below), into a group or out of it.
                ref("target", allLayerRefs, doc: "with above/below: that layer").offCard.noInspector,
                PicshopCore.text("group", max: 8, .oneOf(group: "where"), doc: "g1 into that group, none: out").offCard.noInspector,
            ]
            s.requires = needs(nonBaseLayer: true)
            s.triggers = [
                .fr: ["ordre des calques", "calque au premier plan", "calque en arrière-plan", "passe devant", "passe derrière", "monte le calque",
                      "descends le calque", "calque au-dessus", "calque en dessous", "derrière tout", "devant tout", "tout derrière", "tout devant",
                      "en haut de la pile", "en bas de la pile", "haut de la pile", "dans le groupe", "sors du groupe", "au-dessus du calque",
                      "en dessous du calque"],
                .en: ["bring to front", "send to back", "bring forward", "send backward", "layer order", "move the layer up", "move the layer down",
                      "behind everything", "in front of everything", "on top of everything", "top of the stack", "bottom of the stack", "into the group",
                      "out of the group"],
            ]
            s.examples = [
                fr("déplace le calque texte en arrière-plan", ["ref": "l1", "position": "back"]),
                fr("mets ce calque au premier plan", ["position": "front"]),
                fr("passe le calque derrière", ["position": "backward"]),
                en("bring the layer forward", ["position": "forward"]),
                en("send the text layer to the back", ["ref": "l1", "position": "back"]),
                fr("mets le titre au-dessus du logo i2", ["ref": "l1", "position": "above", "target": "i2"]),
                fr("mets la forme dans le groupe g1", ["ref": "s1", "group": "g1"]),
                fr("sors le texte l3 du groupe", ["ref": "l3", "group": "none"]),
                en("put the text below layer i1", ["ref": "l1", "position": "below", "target": "i1"]),
                near("floute l'arrière-plan", .fr, expected: "blurBackground"),
            ]
            s.verify = [.structural(.layerOrder, .changed)]
            s.uiTool = "layers"
        }
    }
}
