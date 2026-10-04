import Foundation

/// Light and tone: the global settings, a local setting, auto enhance, relight, and the
/// W1 pro tone operations (curves, levels, auto tone).
enum CatalogPhotoTone {
    static var all: [OperationSpec] { [adjust, selectiveAdjust, autoEnhance, relight, curves, levels, autoTone] }

    static var adjust: OperationSpec {
        legacy(.adjust, in: [.photo, .video], .light, .tone,
               title: t("Adjust", "Réglage"), summary: t("One tone or colour setting", "Un réglage de ton ou de couleur")) { s in
            s.coreIn = [.photo, .video]
            s.params = [Step.parameter(), Step.amount(-100...100, .signedPercent, doc: "relative ±; a bit 10, a lot 40"), Step.amountMode]
            s.triggers = [
                .fr: ["luminosité", "plus lumineux", "plus clair", "éclaircis", "assombris", "plus sombre", "exposition", "contraste", "saturation",
                      "plus de couleurs", "désature", "vibrance", "réchauffe", "plus chaud", "plus froid", "chaleur", "ombres", "hautes lumières",
                      "noirs", "blancs", "netteté", "plus net", "clarté", "grain", "vignettage", "teinte", "nuance", "bruit", "terne", "délavé"],
                .en: ["brighter", "darker", "brightness", "exposure", "contrast", "saturation", "more colour", "desaturate", "vibrance", "warmer",
                      "cooler", "warmth", "shadows", "highlights", "blacks", "whites", "sharpness", "sharper", "clarity", "grain", "vignette",
                      "tint", "hue", "noise", "dull", "washed out"],
            ]
            s.examples = [
                fr("plus lumineux", ["parameter": "brightness", "amount": 20]),
                fr("augmente le contraste de 20", ["parameter": "contrast", "amount": 20]),
                fr("mets l'exposition à -20", ["parameter": "exposure", "amountMode": "absolute", "amount": -20]),
                fr("réchauffe un peu", ["parameter": "temperature", "amount": 10]),
                fr("ajoute du grain", ["parameter": "grain", "amount": 20]),
                en("make it brighter", ["parameter": "brightness", "amount": 20]),
                en("less contrast", ["parameter": "contrast", "amount": -20]),
                para("rend la plus chaude", .fr, ["parameter": "temperature", "amount": 20]),
                near("désature les bleus", .fr, expected: "hsl"),
                near("courbe en S", .fr, expected: "curves"),
            ]
            s.verify = [.structural(.adjustment("parameter"), .changed)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "adjust"
        }
    }

    static var selectiveAdjust: OperationSpec {
        legacy(.selectiveAdjust, in: [.photo], .light, .tone,
               title: t("Local adjust", "Réglage local"), summary: t("A setting on one region only", "Un réglage sur une zone seulement")) { s in
            // W2: maskAdjust takes its place in the photo core set (the cards bring it back when `masks` is off), and the
            // executor lowers it onto a local adjustment through the legacy target resolution.
            s.params = [Step.target(.required, doc: "region: sky, face, eyes, teeth"), Step.parameter(),
                        Step.amount(-100...100, .signedPercent, doc: "relative ±"), Step.amountMode, Step.spatialHint, Step.point]
            s.triggers = [
                .fr: ["le ciel plus bleu", "du visage", "le visage", "la peau", "lisse la peau", "les dents", "blanchis les dents", "les yeux",
                      "éclaircis les yeux", "l'herbe", "sur le ciel", "seulement le ciel", "le fond plus sombre", "ombres du visage",
                      "visage plus clair"],
                .en: ["the sky", "the face", "skin", "smooth the skin", "teeth", "whiten the teeth", "the eyes", "brighten the eyes", "only the sky"],
            ]
            s.examples = [
                fr("rends le ciel plus bleu", ["target": "sky", "parameter": "saturation", "amount": 20]),
                fr("lisse la peau", ["target": "face", "parameter": "noiseReduction", "amount": 50]),
                fr("éclaircis le visage", ["target": "face", "parameter": "brightness", "amount": 15]),
                en("whiten the teeth", ["target": "teeth", "parameter": "brightness", "amount": 20]),
                en("make the sky bluer", ["target": "sky", "parameter": "saturation", "amount": 20]),
                near("rends les bleus plus saturés", .fr, expected: "hsl"),
            ]
            s.verify = [.pixels(PixelProbe.maskedParameter.rawValue, .changed)]
            s.grammar = .owned
            s.uiTool = "adjust"
        }
    }

    static var autoEnhance: OperationSpec {
        legacy(.autoEnhance, in: [.photo, .video], .light, .tone,
               title: t("Auto enhance", "Amélioration auto"), summary: t("Balanced light and colour in one go", "Lumière et couleurs équilibrées d'un coup")) { s in
            s.coreIn = [.photo]
            s.params = [Step.amount(0...100, .percent, doc: "strength"), Step.amountMode]
            s.triggers = [
                .fr: ["améliore", "améliore la photo", "amélioration automatique", "rends-la plus belle", "c'est moche", "fais quelque chose", "retouche auto"],
                .en: ["enhance", "auto enhance", "improve", "fix it", "do your magic", "make it better"],
            ]
            s.examples = [
                fr("améliore la photo"),
                fr("rends-la plus belle", ["amount": 70]),
                fr("c'est moche, fais quelque chose"),
                en("fix it"),
                en("auto enhance at 50", ["amount": 50]),
                near("niveaux automatiques", .fr, expected: "levels"),
                near("auto tone", .en, expected: "autoTone"),
            ]
            s.verify = [.unverifiable("several settings change at once")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "magic"
        }
    }

    static var relight: OperationSpec {
        legacy(.relight, in: [.photo], .light, .tone,
               title: t("Relight", "Rééclairer"), summary: t("New light on the subject", "Une nouvelle lumière sur le sujet")) { s in
            s.params = [Step.degrees(0...360, doc: "light from: 0 right, 90 top"), Step.amount(-100...100, .signedPercent, doc: "strength").offCard]
            s.requires = needs(subject: true, cost: .fast)
            s.triggers = [
                .fr: ["rééclaire", "change la lumière", "éclairage studio", "lumière de côté", "relight", "éclaire le sujet"],
                .en: ["relight", "studio light", "light from the side", "change the lighting"],
            ]
            s.examples = [
                fr("rééclaire le sujet"),
                fr("mets une lumière qui vient de la gauche", ["degrees": 180]),
                en("relight the portrait"),
                fr("éclaire la personne depuis la droite", ["degrees": 0]),
                en("light the subject from the left", ["degrees": 180]),
                near("éclaircis toute la photo", .fr, expected: "adjust"),
            ]
            s.verify = [.unverifiable("the relit look is judged by eye")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    // MARK: W1 pro tone

    static let curvePresets = ["sCurve", "strongS", "matte", "fade", "invert", "brighten", "darken", "linear"]

    static var curves: OperationSpec {
        op("curves", .handler, in: [.photo], .light, .tone,
           title: t("Curves", "Courbes"), summary: t("Tone curve per channel", "Courbe de tons par canal")) { s in
            s.params = [
                enumParam("channel", ToneCurve.Channel.self, .optional("rgb"), doc: "channel")
                    .aliases(["rvb": "rgb", "master": "rgb", "tout": "rgb", "all": "rgb", "rouge": "red", "vert": "green", "bleu": "blue"]),
                enumParam("preset", curvePresets, doc: "a ready-made shape").inGroup("shape").keys("shape", "curve")
                    .aliases(["s": "sCurve", "en s": "sCurve", "s curve": "sCurve", "courbe en s": "sCurve", "s leger": "sCurve",
                              "s fort": "strongS", "strong s": "strongS", "s prononce": "strongS", "mat": "matte", "mate": "matte",
                              "delave": "fade", "faded": "fade", "inverse": "invert", "negatif": "invert", "negative": "invert",
                              "eclaircir": "brighten", "plus clair": "brighten", "lighten": "brighten", "assombrir": "darken",
                              "plus sombre": "darken", "lineaire": "linear", "plate": "linear", "reset": "linear", "flat": "linear"]),
                ParamSpec("points", .list(.point, max: ToneCurve.maxPoints), .oneOf(group: "shape"), doc: "[[in,out]…] 0-1000"),
                percent("amount", 0...100, .optional(50), doc: "strength").keys("strength", "intensity"),
            ]
            s.exclusiveGroups = ["shape"]
            s.triggers = [
                .fr: ["courbe", "courbes", "courbe en S", "courbe de tons", "courbe des tons", "S léger", "contraste en S", "courbe mate", "inverse les tons"],
                .en: ["curve", "curves", "S curve", "tone curve", "S-curve", "S contrast", "curves adjustment"],
            ]
            s.examples = [
                fr("applique une courbe en S légère", ["preset": "sCurve", "amount": 30]),
                fr("courbe en S", ["preset": "sCurve"]),
                fr("une courbe mate sur le canal bleu", ["channel": "blue", "preset": "matte"]),
                fr("remonte le milieu de la courbe", ["points": pts([(0, 0), (500, 600), (1_000, 1_000)])]),
                en("add an S curve", ["preset": "sCurve"]),
                en("strong S curve on the red channel", ["channel": "red", "preset": "strongS"]),
                para("mets une petite courbe en S", .fr, ["preset": "sCurve", "amount": 25]),
                para("courbe en esse", .fr, ["preset": "sCurve"]),
                near("plus de contraste", .fr, expected: "adjust"),
            ]
            s.verify = [.structural(.toneCurve, .changed)]
            s.uiTool = "curves"
        }
    }

    static var levels: OperationSpec {
        op("levels", .handler, in: [.photo], .light, .tone,
           title: t("Levels", "Niveaux"), summary: t("Black, white and gamma points", "Points noir, blanc et gamma")) { s in
            s.params = [
                enumParam("channel", ToneCurve.Channel.self, .optional("rgb"), doc: "channel")
                    .aliases(["rvb": "rgb", "master": "rgb", "tout": "rgb", "rouge": "red", "vert": "green", "bleu": "blue"]),
                number("black", 0...254, .level255, .oneOf(group: "values"), doc: "input black").keys("blackPoint", "inBlack"),
                number("white", 1...255, .level255, .oneOf(group: "values"), doc: "input white").keys("whitePoint", "inWhite"),
                number("gamma", 0.1...9.99, .none, .oneOf(group: "values"), doc: "midtones, 1 neutral").keys("midtones"),
                number("outBlack", 0...254, .level255, .oneOf(group: "values"), doc: "output black").offCard,
                number("outWhite", 1...255, .level255, .oneOf(group: "values"), doc: "output white").offCard,
                boolean("auto", .oneOf(group: "values"), doc: "automatic levels"),
            ]
            s.triggers = [
                .fr: ["niveaux", "niveaux automatiques", "point noir", "point blanc", "gamma", "niveaux du rouge", "réglage des niveaux"],
                .en: ["levels", "auto levels", "black point", "white point", "gamma", "input levels", "output levels"],
            ]
            s.examples = [
                fr("niveaux automatiques", ["auto": true]),
                fr("mets le point noir à 20", ["black": 20]),
                fr("règle les niveaux : noir 15, blanc 240", ["black": 15, "white": 240]),
                fr("niveaux du rouge, blanc à 230", ["channel": "red", "white": 230]),
                en("auto levels", ["auto": true]),
                en("set the levels gamma to 1.2", ["gamma": 1.2]),
                para("fais les niveaux tout seul", .fr, ["auto": true]),
                near("plus de noirs", .fr, expected: "adjust"),
            ]
            s.verify = [.structural(.levels, .changed)]
            s.uiTool = "levels"
        }
    }

    static var autoTone: OperationSpec {
        op("autoTone", .handler, in: [.photo], .light, .tone,
           title: t("Auto tone", "Tons auto"), summary: t("Levels from the histogram", "Niveaux tirés de l'histogramme")) { s in
            s.params = [percent("amount", 0...100, .optional(100), doc: "strength").keys("strength", "intensity")]
            s.triggers = [
                .fr: ["tons automatiques", "tonalité automatique", "ton auto", "tons auto", "corrige les tons", "étale l'histogramme"],
                .en: ["auto tone", "automatic tone", "auto contrast", "stretch the histogram"],
            ]
            s.examples = [
                fr("tonalité automatique"),
                fr("corrige les tons automatiquement", ["amount": 100]),
                fr("tons auto à moitié", ["amount": 50]),
                en("auto tone"),
                en("auto tone, but gently", ["amount": 40]),
                near("améliore la photo", .fr, expected: "autoEnhance"),
            ]
            // Unverifiable when the histogram already spans the full range (no change is right then).
            s.verify = [.structural(.levels, .changed)]
            s.uiTool = "levels"
        }
    }
}

/// A list of curve points in 0…1000.
func pts(_ pairs: [(Double, Double)]) -> OpValue {
    .list(pairs.map { .point(PSPoint(x: $0.0, y: $0.1)) })
}

/// One point in 0…1000.
func pt(_ x: Double, _ y: Double) -> OpValue {
    .point(PSPoint(x: x, y: y))
}
