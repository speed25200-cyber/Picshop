import Foundation

/// Colour: looks, colour match, recolour, and the W1 colour operations (HSL mixer, three-way
/// grade, LUT intensity and removal).
enum CatalogPhotoColor {
    static var all: [OperationSpec] { [applyLook, matchColor, recolor, hsl, colorGrade, lutIntensity, removeLUT] }

    static var applyLook: OperationSpec {
        legacy(.applyLook, in: [.photo, .video], .color, .color,
               title: t("Look", "Filtre"), summary: t("A ready-made look", "Un look tout prêt")) { s in
            s.coreIn = [.photo, .video]
            s.params = [Step.look(), Step.amount(0...100, .percent, doc: "intensity"), Step.amountMode]
            s.triggers = [
                .fr: ["filtre", "look", "noir et blanc", "heure dorée", "vintage", "cinéma", "ciné", "argentique", "rétro", "pastel", "dramatique", "teal orange"],
                .en: ["filter", "look", "black and white", "golden hour", "vintage", "cinematic", "film look", "retro", "pastel", "dramatic", "moody"],
            ]
            s.examples = [
                fr("noir et blanc", ["look": "mono"]),
                fr("mets le filtre vintage", ["look": "vintage"]),
                fr("un look plus cinéma", ["look": "cinematic", "amount": 70]),
                en("apply the cinematic look", ["look": "cinematic"]),
                en("black and white", ["look": "mono"]),
                para("met en noir est blanc", .fr, ["look": "mono"]),
                near("ombres bleues", .fr, expected: "colorGrade"),
            ]
            s.verify = [.unverifiable("a look is judged by eye")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "looks"
        }
    }

    static var matchColor: OperationSpec {
        legacy(.matchColor, in: [.photo, .video], .color, .color,
               title: t("Match colour", "Harmoniser les couleurs"), summary: t("Colours of another photo or clip", "Les couleurs d'une autre photo ou d'un clip")) { s in
            s.params = [Step.clipNumber(doc: "video: the reference clip"), Step.scope(doc: "video: all clips")]
            s.requires = needs(referenceAsset: .image, cost: .fast)
            s.triggers = [
                .fr: ["copie les couleurs", "les couleurs d'une autre photo", "mêmes couleurs que", "harmonise les couleurs", "transfert de couleur",
                      "la couleur du clip", "couleur du clip", "comme le clip"],
                .en: ["match the colours", "match the colors", "colour transfer", "same colours as", "copy the colours", "match the clip"],
            ]
            s.examples = [
                fr("prends les couleurs d'une autre photo"),
                fr("mets la couleur du clip 1 sur tous les clips", ["clipNumber": 1, "scope": "all"]),
                fr("harmonise les couleurs avec le premier clip", ["clipNumber": 1]),
                en("match the colours of another photo"),
                en("copy the colours of another picture"),
                near("applique un filtre vintage", .fr, expected: "applyLook"),
            ]
            s.verify = [.unverifiable("needs the reference picked by the user")]
            s.grammar = .owned
            s.uiTool = "color"
        }
    }

    static var recolor: OperationSpec {
        legacy(.recolor, in: [.photo], .color, .refDependent,
               title: t("Recolour", "Changer la couleur"), summary: t("New colour for one object", "Une nouvelle couleur pour un objet")) { s in
            s.params = [Step.target(.required, doc: "the object: car, shirt"), Step.color(.required), Step.ref([.object], doc: "o1"),
                        Step.point, Step.amount(0...1, .fraction, doc: "strength 0-1").offCard, Step.spatialHint, Step.attributes]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["rends la voiture rouge", "change la couleur de", "en rouge", "en bleu", "recolore", "repeins", "couleur du t-shirt"],
                .en: ["make the car red", "change the colour of", "recolour", "recolor", "paint it"],
            ]
            s.examples = [
                fr("rends la voiture rouge", ["target": "car", "color": "red"]),
                fr("mets le t-shirt en bleu", ["target": "shirt", "color": "blue"]),
                en("make the car red", ["target": "car", "color": "red"]),
                fr("passe la voiture en vert", ["target": "car", "color": "green"]),
                en("turn the shirt blue", ["target": "shirt", "color": "blue"]),
                near("rends les verts moins saturés", .fr, expected: "hsl"),
            ]
            s.verify = [.unverifiable("a change on one object: the pixel check comes in W2")]
            s.grammar = .owned
            s.uiTool = "color"
        }
    }

    // MARK: W1 colour operations

    /// Band values: the mixer's English band names, with the bands' own aliases.
    static var bandValues: [String] { ColorMixer.Band.allCases.map { $0.englishName.lowercased() } }

    static var bandAliases: [String: String] {
        var aliases: [String: String] = [:]
        for band in ColorMixer.Band.allCases {
            let value = band.englishName.lowercased()
            for alias in band.aliases + [band.frenchName] { aliases[alias.normalizedForMatching] = value }
        }
        return aliases
    }

    static var hsl: OperationSpec {
        op("hsl", .handler, in: [.photo], .color, .color,
           title: t("Colour mixer", "Mélangeur de couleurs"), summary: t("Hue, saturation, lightness of one colour", "Teinte, saturation, luminance d'une couleur")) { s in
            s.params = [
                enumParam("band", bandValues, .required, doc: "the colour").aliases(bandAliases).keys("color", "colour"),
                signedPercent("hue", .oneOf(group: "values"), doc: "shift toward the next colour"),
                signedPercent("saturation", .oneOf(group: "values"), doc: "less to more vivid"),
                signedPercent("luminance", .oneOf(group: "values"), doc: "darker to lighter").keys("lightness"),
                enumParam("amountMode", ["relative", "absolute"], .optional("relative"), doc: "relative adds").offCard,
            ]
            s.triggers = [
                .fr: ["mélangeur de couleurs", "TSL", "teinte saturation luminance", "désature les bleus", "sature les rouges", "les verts plus jaunes",
                      "teinte des verts", "luminance des bleus", "saturation des oranges", "tons chair", "couleur de peau"],
                .en: ["HSL", "colour mixer", "color mixer", "hue saturation luminance", "desaturate the blues", "the greens more yellow",
                      "saturation of the reds", "skin tones", "skin tone"],
            ]
            s.examples = [
                fr("désature les bleus", ["band": "blue", "saturation": -40]),
                fr("rends les verts plus jaunes", ["band": "green", "hue": -30]),
                fr("éclaircis les oranges", ["band": "orange", "luminance": 20]),
                fr("sature un peu les rouges", ["band": "red", "saturation": 20]),
                en("desaturate the blues", ["band": "blue", "saturation": -40]),
                en("make the greens more yellow", ["band": "green", "hue": -30]),
                para("baisse la sat des bleus", .fr, ["band": "blue", "saturation": -30]),
                near("plus de saturation", .fr, expected: "adjust"),
            ]
            s.verify = [.structural(.colorMixer, .changed)]
            s.uiTool = "color"
        }
    }

    static var colorGrade: OperationSpec {
        op("colorGrade", .handler, in: [.photo], .color, .color,
           title: t("Colour grade", "Étalonnage"), summary: t("Tint shadows, midtones or highlights", "Teinte des ombres, tons moyens ou hautes lumières")) { s in
            s.params = [
                enumParam("range", ColorGrade.Range.self, .required, doc: "tonal range")
                    .aliases(["ombres": "shadows", "tons moyens": "midtones", "demi teintes": "midtones", "hautes lumieres": "highlights",
                              "lumieres": "highlights", "mids": "midtones"]),
                ParamSpec("color", .color, .oneOf(group: "tint"), doc: "tint colour name").keys("colour", "couleur"),
                number("hue", 0...360, .degrees, .oneOf(group: "tint"), doc: "tint hue, 0 red"),
                percent("amount", 0...100, .optional(30), doc: "tint strength"),
                signedPercent("luminance", doc: "darker to lighter"),
                signedPercent("balance", doc: "shadows ↔ highlights split").offCard,
            ]
            s.exclusiveGroups = ["tint"]
            s.triggers = [
                .fr: ["étalonnage", "ombres bleues", "ombres froides", "ombres chaudes", "hautes lumières orangées", "hautes lumières chaudes",
                      "teinte les ombres", "virage partiel", "roues chromatiques", "étalonne", "ombres turquoise"],
                .en: ["colour grade", "color grade", "color grading", "split toning", "teal shadows", "orange highlights", "warm highlights",
                      "cool shadows", "blue shadows", "tint the shadows", "colour wheels", "color wheels"],
            ]
            s.examples = [
                fr("ombres bleues", ["range": "shadows", "color": "blue", "amount": 30]),
                fr("hautes lumières orangées", ["range": "highlights", "color": "orange", "amount": 30]),
                fr("réchauffe les tons moyens à l'étalonnage", ["range": "midtones", "color": "orange", "amount": 20]),
                en("teal shadows", ["range": "shadows", "color": "teal", "amount": 30]),
                en("split toning with orange highlights", ["range": "highlights", "color": "orange", "amount": 30]),
                para("des ombres un peu froides", .fr, ["range": "shadows", "color": "blue", "amount": 20]),
                near("teal and orange", .en, expected: "applyLook"),
            ]
            s.verify = [.structural(.colorGrade, .changed)]
            s.uiTool = "color"
        }
    }

    static var lutIntensity: OperationSpec {
        op("lutIntensity", .handler, in: [.photo], .color, .color,
           title: t("LUT intensity", "Intensité du LUT"), summary: t("How strongly the imported LUT applies", "La force du LUT importé")) { s in
            s.params = [percent("amount", 0...100, .required, doc: "0 none, 100 full").keys("intensity", "strength")]
            s.requires = needs(importedLUT: true)
            s.triggers = [
                .fr: ["LUT", "intensité du LUT", "force du LUT", "LUT à", "applique mon LUT", "dose du LUT"],
                .en: ["LUT", "LUT intensity", "LUT strength", "apply my LUT", "LUT at"],
            ]
            s.examples = [
                fr("mets le LUT à 50 %", ["amount": 50]),
                fr("baisse l'intensité du LUT", ["amount": 40]),
                fr("applique mon LUT à fond", ["amount": 100]),
                en("LUT intensity 70", ["amount": 70]),
                para("mets un LUT", .fr, ["amount": 100]),
                en("set the LUT to half strength", ["amount": 50]),
                near("enlève le LUT", .fr, expected: "removeLUT"),
            ]
            s.verify = [.structural(.lutIntensity, .equalsParam("amount"))]
            s.uiTool = "color"
        }
    }

    static var removeLUT: OperationSpec {
        op("removeLUT", .handler, in: [.photo], .color, .color,
           title: t("Remove LUT", "Retirer le LUT"), summary: t("Takes the imported LUT off", "Enlève le LUT importé")) { s in
            s.requires = needs(importedLUT: true)
            s.triggers = [
                .fr: ["enlève le LUT", "retire le LUT", "supprime le LUT", "sans LUT", "enlève la LUT"],
                .en: ["remove the LUT", "no LUT", "turn off the LUT", "delete the LUT"],
            ]
            s.examples = [
                fr("enlève le LUT"),
                fr("retire la LUT"),
                en("remove the LUT"),
                near("enlève le filtre", .fr, expected: "applyLook"),
                fr("supprime le LUT importé"),
                en("take the LUT off"),
            ]
            s.verify = [.structural(.lutIntensity, .decreased)]
            s.uiTool = "color"
        }
    }
}
