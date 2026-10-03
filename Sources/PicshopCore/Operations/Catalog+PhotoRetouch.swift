import Foundation

/// Retouch, objects, background, generative and detail: what removes, moves, blurs or
/// invents pixels, plus the W1 lens focus.
enum CatalogPhotoRetouch {
    static var all: [OperationSpec] {
        [removeObject, cleanUp, eraseRegion, blurObject, moveObject, removeBackground, replaceBackground, blurBackground, generativeFill,
         expandCanvas, upscale, denoise, sharpen, lensFocus]
    }

    static var removeObject: OperationSpec {
        legacy(.removeObject, in: [.photo, .video], .objects, .refDependent,
               title: t("Remove object", "Effacer un objet"), summary: t("Erases a thing and fills the gap", "Efface une chose et comble le trou")) { s in
            s.coreIn = [.photo]
            s.params = [Step.target(.oneOf(group: "what"), doc: "English noun: person, car, sign"), Step.point.inGroup("what"),
                        Step.ref([.object], doc: "o1"), Step.spatialHint, Step.ordinal, Step.all, Step.attributes]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["efface", "enlève", "supprime", "retire", "fais disparaître", "gomme", "le poteau", "les fils", "la poubelle", "enlève la personne",
                      "efface la personne", "les gens"],
                .en: ["remove", "erase", "delete", "get rid of", "take out", "the power lines", "the pole", "remove the person", "the people"],
            ]
            s.examples = [
                fr("efface le chien à gauche", ["target": "dog", "spatialHint": "left"]),
                fr("enlève le poteau à droite", ["target": "pole", "spatialHint": "right"]),
                fr("supprime la deuxième voiture", ["target": "car", "ordinal": 2]),
                en("remove the dog", ["target": "dog"]),
                en("get rid of the power lines", ["target": "wire", "all": true]),
                para("éfface le chien", .fr, ["target": "dog"]),
                near("enlève le fond", .fr, expected: "removeBackground"),
            ]
            s.verify = [.pixels("objectAbsent", .changed)]
            s.grammar = .owned
            s.uiTool = "erase"
        }
    }

    static var cleanUp: OperationSpec {
        legacy(.cleanUp, in: [.photo], .objects, .cleanup,
               title: t("Clean up", "Nettoyer"), summary: t("Erases passers-by, keeps the subject", "Efface les passants, garde le sujet")) { s in
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["passants", "les passants", "touristes", "photobomb", "nettoie la photo", "les gens derrière", "les intrus", "ce qui dérange"],
                .en: ["passers-by", "tourists", "photobombers", "clean up", "clean the photo", "people behind", "distractions"],
            ]
            s.examples = [
                fr("enlève les passants"),
                fr("nettoie la photo, il y a des touristes"),
                en("remove the tourists in the background"),
            ]
            s.verify = [.unverifiable("which people stay is judged by eye")]
            s.grammar = .owned
            s.uiTool = "erase"
        }
    }

    static var eraseRegion: OperationSpec {
        legacy(.eraseRegion, in: [.photo], .retouch, .refDependent,
               title: t("Erase area", "Effacer une zone"), summary: t("Erases a box or a scene id", "Efface une zone ou un élément nommé")) { s in
            s.params = [Step.box(doc: "[x1,y1,x2,y2] 0-1000").inGroup("where"), Step.ref([.printedText, .textLayer, .object, .freeArea], .oneOf(group: "where"), doc: "t3, l2, o1, f1"),
                        Step.point.inGroup("where")]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["efface cette zone", "efface la zone", "efface le texte imprimé", "efface ce bloc", "gomme ce coin"],
                .en: ["erase this area", "erase the box", "erase that block", "clear this region", "patch", "erase this spot"],
            ]
            s.examples = [
                fr("efface le bloc de texte t3", ["ref": "t3"]),
                fr("efface la zone en haut à gauche", ["box": .box(PSRect(x: 0, y: 0, width: 300, height: 200))]),
                en("erase that block of text", ["ref": "t1"]),
            ]
            s.verify = [.unverifiable("the erased area is judged by eye")]
            s.grammar = .keywordsOnly
            s.uiTool = "erase"
        }
    }

    static var blurObject: OperationSpec {
        legacy(.blurObject, in: [.photo], .objects, .refDependent,
               title: t("Blur object", "Flouter un élément"), summary: t("Privacy blur on faces, plates, screens", "Flou de confidentialité : visages, plaques, écrans")) { s in
            s.params = [Step.target(doc: "face (default), licence plate, screen"), Step.ref([.object], doc: "o1"), Step.point, Step.all]
            s.requires = needs(cost: .fast)
            s.triggers = [
                .fr: ["floute les visages", "floute la plaque", "pixelise", "pixellise", "anonymise", "cache les visages", "floute l'écran"],
                .en: ["blur the faces", "blur the licence plate", "pixelate", "pixelize", "anonymise", "hide the faces"],
            ]
            s.examples = [
                fr("floute les visages", ["target": "face", "all": true]),
                fr("pixelise la plaque d'immatriculation", ["target": "sign"]),
                en("blur the faces", ["target": "face", "all": true]),
            ]
            s.verify = [.unverifiable("a privacy blur is judged by eye")]
            s.grammar = .owned
            s.uiTool = "erase"
        }
    }

    static var moveObject: OperationSpec {
        legacy(.moveObject, in: [.photo], .objects, .refDependent,
               title: t("Move object", "Déplacer un objet"), summary: t("Moves a thing, fills where it was", "Déplace un objet et comble sa place")) { s in
            s.params = [Step.target(.oneOf(group: "what"), doc: "the object"), Step.point.inGroup("what"), Step.ref([.object], doc: "o1"),
                        Step.degrees(-360...360, doc: "direction: 0 right, 90 up"),
                        Step.amount(0.05...0.5, .fraction, doc: "distance, part of the frame"), Step.placement.offCard]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["déplace le", "déplace la", "bouge le", "décale", "pousse vers la gauche", "au centre de la photo"],
                .en: ["move the", "shift the", "reposition", "push to the left"],
            ]
            s.examples = [
                fr("déplace la voiture un peu vers la droite", ["target": "car", "degrees": 0, "amount": 0.08]),
                fr("décale le chien vers la gauche", ["target": "dog", "degrees": 180, "amount": 0.15]),
                en("move the person to the right", ["target": "person", "degrees": 0, "amount": 0.2]),
            ]
            s.verify = [.unverifiable("the new position is judged by eye")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var removeBackground: OperationSpec {
        legacy(.removeBackground, in: [.photo, .video], .background, .composition,
               title: t("Remove background", "Enlever le fond"), summary: t("Cuts the subject out", "Détoure le sujet")) { s in
            s.coreIn = [.photo]
            s.requires = needs(subject: true, cost: .fast)
            s.triggers = [
                .fr: ["enlève le fond", "supprime le fond", "détoure", "détourage", "fond transparent", "garde que le sujet"],
                .en: ["remove the background", "cut out", "cutout", "transparent background", "only the subject"],
            ]
            s.examples = [
                fr("enlève le fond"),
                fr("détoure le sujet"),
                en("remove the background"),
            ]
            s.verify = [.pixels("alphaCoverage", .decreased)]
            s.grammar = .owned
            s.uiTool = "cutout"
        }
    }

    static var replaceBackground: OperationSpec {
        legacy(.replaceBackground, in: [.photo, .video], .background, .composition,
               title: t("Replace background", "Changer le fond"), summary: t("A colour, transparent or blur behind the subject", "Une couleur, du transparent ou du flou derrière le sujet")) { s in
            s.params = [Step.background]
            s.requires = needs(subject: true, cost: .fast)
            s.triggers = [
                .fr: ["fond blanc", "mets un fond", "change le fond", "fond bleu", "fond noir", "fond vert", "fond uni", "fond coloré"],
                .en: ["white background", "change the background", "swap the background", "switch the background", "new background", "background to",
                      "plain background", "green background"],
            ]
            s.examples = [
                fr("mets un fond blanc", ["background": "white"]),
                fr("change le fond en bleu clair", ["background": "light blue"]),
                en("change the background to light blue", ["background": "light blue"]),
            ]
            s.verify = [.unverifiable("the new background is judged by eye")]
            s.grammar = .owned
            s.uiTool = "cutout"
        }
    }

    static var blurBackground: OperationSpec {
        legacy(.blurBackground, in: [.photo, .video], .background, .effects,
               title: t("Blur background", "Flouter le fond"), summary: t("Portrait-mode background blur", "Flou d'arrière-plan façon portrait")) { s in
            s.coreIn = [.photo]
            s.params = [Step.amount(0...100, .percent, doc: "blur strength"), Step.amountMode]
            s.requires = needs(subject: true, cost: .fast)
            s.triggers = [
                .fr: ["floute l'arrière-plan", "floute le fond", "mode portrait", "bokeh", "flou d'arrière-plan", "arrière-plan flou"],
                .en: ["blur the background", "portrait mode", "bokeh", "background blur", "depth of field"],
            ]
            s.examples = [
                fr("floute l'arrière-plan"),
                fr("mode portrait", ["amount": 60]),
                en("blur the background", ["amount": 60]),
                para("floute larrière plan", .fr),
                near("fais la mise au point sur le chien", .fr, expected: "lensFocus"),
            ]
            s.verify = [.unverifiable("the blur strength is judged by eye")]
            s.grammar = .owned
            s.uiTool = "focus"
        }
    }

    static var generativeFill: OperationSpec {
        legacy(.generativeFill, in: [.photo], .generative, .composition,
               title: t("Generative fill", "Remplissage génératif"), summary: t("Invents new content in a region", "Invente un nouveau contenu dans une zone")) { s in
            s.params = [Step.text(.required, max: 200, doc: "what to generate, in English"), Step.target(doc: "region to replace: sky")]
            s.requires = needs(generativeEngine: true, cost: .heavy)
            s.triggers = [
                .fr: ["remplace le ciel par", "ajoute un chapeau", "rajoute", "rajoute un", "génère", "invente", "change le ciel", "mets un coucher de soleil"],
                .en: ["replace the sky with", "add a hat", "generate", "the sky is boring", "make a sunset sky"],
            ]
            s.examples = [
                fr("remplace le ciel par un coucher de soleil", ["target": "sky", "text": "a sunset sky with warm clouds"]),
                fr("ajoute un chapeau à la personne", ["target": "person", "text": "a hat"]),
                en("the sky is boring, do something about it", ["target": "sky", "text": "a dramatic sky with golden sunset clouds"]),
            ]
            s.verify = [.unverifiable("generated content is judged by eye")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var expandCanvas: OperationSpec {
        legacy(.expandCanvas, in: [.photo], .generative, .geometry,
               title: t("Expand", "Agrandir le cadre"), summary: t("A bigger frame, the border invented", "Un cadre plus grand, le bord inventé")) { s in
            s.params = [Step.aspect()]
            s.requires = needs(generativeEngine: true, cost: .heavy, geometryChange: true)
            s.triggers = [
                .fr: ["agrandis la toile", "agrandis le cadre", "élargis la photo", "étends l'image", "dézoome", "outpainting", "sur les côtés", "plus de décor",
                      "étends le décor"],
                .en: ["expand the canvas", "uncrop", "outpaint", "extend the photo", "zoom out the frame", "on the sides", "more scenery"],
            ]
            s.examples = [
                fr("agrandis la toile vers la gauche"),
                fr("élargis la photo en 16:9", ["aspect": "ratio16x9"]),
                en("expand the canvas to square", ["aspect": "square"]),
            ]
            // Without an aspect the frame grows on every side and keeps its shape.
            s.verify = [.unverifiable("the canvas grows; its shape changes only with an aspect")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var upscale: OperationSpec {
        legacy(.upscale, in: [.photo], .detail, .output,
               title: t("Upscale", "Agrandir"), summary: t("More pixels, sharper detail", "Plus de pixels, plus de détails")) { s in
            s.params = [Step.amount(2...4, .multiplier, doc: "factor 2-4")]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["augmente la résolution", "agrandis la photo", "super résolution", "haute définition", "plus de pixels", "en 4K", "4K", "8K"],
                .en: ["upscale", "increase the resolution", "super resolution", "higher resolution", "4K", "8K", "in 4K"],
            ]
            s.examples = [
                fr("augmente la résolution"),
                fr("agrandis la photo trois fois", ["amount": 3]),
                en("upscale it 3 times", ["amount": 3]),
            ]
            s.verify = [.unverifiable("the size is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "magic"
        }
    }

    static var denoise: OperationSpec {
        legacy(.denoise, in: [.photo, .video], .detail, .cleanup,
               title: t("Reduce noise", "Réduire le bruit"), summary: t("Cleans grain and noise", "Nettoie le grain et le bruit")) { s in
            s.params = [Step.amount(0...100, .percent, doc: "strength"), Step.amountMode]
            s.triggers = [
                .fr: ["réduis le bruit", "enlève le bruit", "débruite", "photo bruitée", "moins de bruit"],
                .en: ["denoise", "reduce the noise", "remove the noise", "noisy"],
            ]
            s.examples = [
                fr("réduis le bruit", ["amount": 40]),
                fr("enlève le bruit de la photo", ["amount": 50]),
                en("denoise it", ["amount": 40]),
            ]
            s.verify = [.structural(.adjustment("noiseReduction"), .increased)]
            s.grammar = .keywordsOnly
            s.uiTool = "adjust"
        }
    }

    static var sharpen: OperationSpec {
        legacy(.sharpen, in: [.photo, .video], .detail, .effects,
               title: t("Sharpen", "Netteté"), summary: t("Crisper detail", "Des détails plus nets")) { s in
            s.params = [Step.amount(0...100, .percent, doc: "strength"), Step.amountMode]
            s.triggers = [
                .fr: ["plus net", "accentue la netteté", "renforce les détails", "c'est flou"],
                .en: ["sharpen", "sharper", "crisper", "more detail"],
            ]
            s.examples = [
                fr("rends la photo plus nette", ["amount": 30]),
                fr("accentue la netteté", ["amount": 40]),
                en("sharpen it a bit", ["amount": 20]),
            ]
            s.verify = [.structural(.adjustment("sharpness"), .increased)]
            s.grammar = .keywordsOnly
            s.uiTool = "adjust"
        }
    }

    // MARK: W1

    static var lensFocus: OperationSpec {
        op("lensFocus", .handler, in: [.photo], .effects, .effects,
           title: t("Lens focus", "Mise au point"), summary: t("Sharp where you say, lens blur elsewhere", "Net où tu dis, flou d'objectif ailleurs")) { s in
            s.params = [
                ref("ref", [.object], .oneOf(group: "where"), doc: "o1: what to focus on"),
                ParamSpec("point", .point, .oneOf(group: "where"), doc: "[x,y] focus point 0-1000"),
                percent("aperture", 0...100, .optional(60), doc: "blur strength").keys("amount", "blur"),
            ]
            s.exclusiveGroups = ["where"]
            s.triggers = [
                .fr: ["mise au point", "mets au point", "fais le point", "fais la mise au point", "map", "la map", "ouverture", "profondeur de champ sur", "net sur"],
                .en: ["focus on", "focus point", "aperture", "rack focus", "sharp on"],
            ]
            s.examples = [
                fr("fais la mise au point sur le chien", ["ref": "o1"]),
                fr("mise au point au centre, ouverture 80", ["point": pt(500, 500), "aperture": 80]),
                fr("mets la personne de gauche nette et floute le reste", ["ref": "o2"]),
                en("focus on the dog", ["ref": "o1"]),
                en("set the focus point at the top, aperture 40", ["point": pt(500, 200), "aperture": 40]),
                near("floute l'arrière-plan", .fr, expected: "blurBackground"),
            ]
            s.verify = [.structural(.lensBlur, .changed)]
            s.uiTool = "focus"
        }
    }
}
