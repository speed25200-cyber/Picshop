import Foundation

/// Geometry: crop and frame shape, orientation, straighten, and the W1 perspective correction.
enum CatalogPhotoGeometry {
    static var all: [OperationSpec] { [crop, setAspect, autoCrop, rotate, straighten, flip, resetOrientation, perspective] }

    static var crop: OperationSpec {
        legacy(.crop, in: [.photo, .video], .geometry, .geometry,
               title: t("Crop", "Recadrer"), summary: t("Crop to a frame shape", "Recadre selon un format")) { s in
            s.coreIn = [.photo, .video]
            s.params = [Step.aspect(), Step.target(doc: "crop around: face, dog").offCard]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["recadre", "recadrage", "rogne", "carré", "format", "16:9", "9:16", "4:5", "en portrait", "fond d'écran"],
                .en: ["crop", "square", "crop to", "aspect ratio", "16:9", "9:16", "4:5"],
            ]
            s.examples = [
                fr("recadre en carré", ["aspect": "square"]),
                fr("format 4 par 5", ["aspect": "ratio4x5"]),
                fr("rogne la vidéo en 16:9", ["aspect": "ratio16x9"]),
                en("crop to 16:9", ["aspect": "ratio16x9"]),
                para("récadre en carré", .fr, ["aspect": "square"]),
                near("recadre au mieux", .fr, expected: "autoCrop"),
            ]
            s.verify = [.structural(.canvasAspect, .equalsParam("aspect"))]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    static var setAspect: OperationSpec {
        legacy(.setAspect, in: [.photo, .video], .geometry, .geometry,
               title: t("Aspect ratio", "Format"), summary: t("Sets the frame shape", "Change la forme du cadre")) { s in
            s.params = [Step.aspect(.required)]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["passe en", "format", "ratio", "en vertical", "en paysage", "pour une story"],
                .en: ["aspect ratio", "make it vertical", "landscape format", "for a story"],
            ]
            s.examples = [
                fr("passe en format 9:16", ["aspect": "ratio9x16"]),
                fr("mets-la au format paysage", ["aspect": "ratio16x9"]),
                en("set the aspect ratio to 4:3", ["aspect": "ratio4x3"]),
            ]
            s.verify = [.structural(.canvasAspect, .equalsParam("aspect"))]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    static var autoCrop: OperationSpec {
        legacy(.autoCrop, in: [.photo], .geometry, .geometry,
               title: t("Best crop", "Meilleur cadrage"), summary: t("The framing an aesthetics model prefers", "Le cadrage préféré d'un modèle esthétique")) { s in
            s.requires = needs(cost: .fast, geometryChange: true)
            s.triggers = [
                .fr: ["recadre au mieux", "meilleur cadrage", "recadrage automatique", "améliore le cadrage", "cadre mieux"],
                .en: ["best crop", "auto crop", "smart crop", "improve the framing", "frame it better"],
            ]
            s.examples = [
                fr("recadre au mieux"),
                fr("trouve le meilleur cadrage"),
                en("improve the framing"),
            ]
            s.verify = [.structural(.canvasAspect, .changed)]
            s.grammar = .owned
            s.uiTool = "crop"
        }
    }

    static var rotate: OperationSpec {
        legacy(.rotate, in: [.photo, .video], .geometry, .geometry,
               title: t("Rotate", "Pivoter"), summary: t("Turns by degrees", "Tourne de quelques degrés")) { s in
            s.coreIn = [.photo]
            s.params = [Step.degrees(doc: "negative = counter-clockwise")]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["tourne", "pivote", "rotation", "quart de tour", "degrés", "vers la gauche", "vers la droite"],
                .en: ["rotate", "turn", "rotation", "quarter turn", "degrees"],
            ]
            s.examples = [
                fr("tourne de 90 degrés vers la gauche", ["degrees": -90]),
                fr("tourne de 15 degrés", ["degrees": 15]),
                en("rotate right", ["degrees": 90]),
                para("tourne la à droite", .fr, ["degrees": 90]),
            ]
            s.verify = [.structural(.rotation, .changed)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    static var straighten: OperationSpec {
        legacy(.straighten, in: [.photo, .video], .geometry, .geometry,
               title: t("Straighten", "Redresser"), summary: t("Levels the horizon", "Met l'horizon à niveau")) { s in
            s.params = [Step.degrees(-45...45, doc: "small tilt; omit to detect")]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["redresse l'horizon", "redresse", "horizon", "c'est penché", "penche", "de travers", "tordu", "pas droit", "mets à niveau", "remets droit"],
                .en: ["straighten", "level the horizon", "horizon", "it's tilted", "tilted", "crooked", "not level"],
            ]
            s.examples = [
                fr("redresse l'horizon"),
                fr("redresse de 2 degrés", ["degrees": 2]),
                en("straighten the horizon"),
            ]
            s.verify = [.structural(.rotation, .changed)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    static var flip: OperationSpec {
        legacy(.flip, in: [.photo, .video], .geometry, .geometry,
               title: t("Flip", "Miroir"), summary: t("Mirrors horizontally or vertically", "Retourne en miroir")) { s in
            s.params = [Step.flipAxis]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["miroir", "retourne", "inverse gauche droite", "effet miroir", "retourne verticalement"],
                .en: ["flip", "mirror", "flip it", "flip vertically"],
            ]
            s.examples = [
                fr("effet miroir", ["flipAxis": "horizontal"]),
                fr("retourne verticalement", ["flipAxis": "vertical"]),
                en("flip it", ["flipAxis": "horizontal"]),
            ]
            s.verify = [.unverifiable("a mirror keeps every measured value")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    static var resetOrientation: OperationSpec {
        legacy(.resetOrientation, in: [.photo, .video], .geometry, .geometry,
               title: t("Right way up", "Remettre à l'endroit"), summary: t("Undoes every turn and mirror", "Annule rotations et miroirs")) { s in
            s.params = [Step.degrees(-360...360, doc: "180 when it shows upside down").offCard, Step.flipAxis.offCard]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["remets-la à l'endroit", "à l'endroit", "c'est à l'envers", "la tête en bas", "annule le miroir"],
                .en: ["right way up", "it's upside down", "upright", "undo the mirror"],
            ]
            s.examples = [
                fr("remets-la à l'endroit"),
                fr("c'est à l'envers", ["degrees": 180]),
                en("it's upside down", ["degrees": 180]),
            ]
            s.verify = [.structural(.rotation, .changed)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "crop"
        }
    }

    // MARK: W1

    static var perspective: OperationSpec {
        op("perspective", .handler, in: [.photo], .geometry, .geometry,
           title: t("Perspective", "Perspective"), summary: t("Straightens converging lines", "Redresse les lignes fuyantes")) { s in
            s.params = [
                signedPercent("horizontal", .oneOf(group: "axes"), doc: "left ↔ right keystone"),
                signedPercent("vertical", .oneOf(group: "axes"), doc: "top ↔ bottom keystone"),
            ]
            s.requires = needs(geometryChange: true)
            s.triggers = [
                .fr: ["perspective", "corrige la perspective", "lignes fuyantes", "lignes de fuite", "redresse les verticales", "les verticales", "redresse les lignes",
                      "trapèze", "bâtiment penché", "bâtiment droit", "immeuble droit", "façade droite", "façade", "tombe en arrière"],
                .en: ["perspective", "fix the perspective", "keystone", "converging lines", "straighten the verticals", "the verticals", "parallel verticals",
                      "straight building", "leaning building"],
            ]
            s.examples = [
                fr("corrige la perspective", ["vertical": 25]),
                fr("corrige la perspective verticale de 20", ["vertical": 20]),
                fr("redresse les verticales du bâtiment", ["vertical": 30]),
                en("fix the perspective", ["vertical": 25]),
                en("keystone correction, horizontal -15", ["horizontal": -15]),
                near("redresse l'horizon", .fr, expected: "straighten"),
            ]
            s.verify = [.structural(.perspective, .changed)]
            s.uiTool = "crop"
        }
    }
}
