import Foundation

/// Video timeline editing: cuts, ranges, clips, speed, frames, transitions, stabilisation.
/// Times are seconds on the timeline; clips are numbered from 1, -1 the last.
enum CatalogVideoEdit {
    static var all: [OperationSpec] {
        [trim, split, deleteClip, deleteRange, setSpeed, reverse, freezeFrame, duplicateClip, moveClip, extractFrame, addTransition,
         removeTransition, stabilize]
    }

    static var trim: OperationSpec {
        legacy(.trim, in: [.video], .cut, .geometry,
               title: t("Trim", "Garder une partie"), summary: t("Keeps only start…end", "Ne garde que début…fin")) { s in
            s.coreIn = [.video]
            s.params = [Step.startSeconds(.required), Step.endSeconds(.required), Step.clipNumber().offCard]
            s.triggers = [
                .fr: ["garde seulement", "garde de", "ne garde que", "raccourcis à", "garde le passage"],
                .en: ["keep only", "trim to", "keep from", "keep the part"],
            ]
            s.examples = [
                fr("garde seulement de 2 à 8 secondes", ["startSeconds": 2, "endSeconds": 8]),
                fr("ne garde que les 10 premières secondes", ["startSeconds": 0, "endSeconds": 10]),
                en("keep only from 5 to 20 seconds", ["startSeconds": 5, "endSeconds": 20]),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var split: OperationSpec {
        legacy(.split, in: [.video], .cut, .geometry,
               title: t("Split", "Couper en deux"), summary: t("Cuts the clip at a time", "Coupe le clip à un instant")) { s in
            s.coreIn = [.video]
            s.params = [Step.seconds(doc: "where; omit = playhead")]
            s.triggers = [
                .fr: ["coupe ici", "coupe à", "scinde", "sépare le clip", "coupe le clip en deux"],
                .en: ["split", "cut here", "split at", "cut the clip in two"],
            ]
            s.examples = [
                fr("coupe ici"),
                fr("coupe à 5 secondes", ["seconds": 5]),
                en("split at 10 seconds", ["seconds": 10]),
            ]
            s.verify = [.structural(.clipCount, .increased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var deleteClip: OperationSpec {
        legacy(.deleteClip, in: [.video], .cut, .geometry,
               title: t("Delete clip", "Supprimer le clip"), summary: t("Removes a whole clip", "Enlève un clip entier")) { s in
            s.params = [Step.clipNumber(doc: "clip 1.., -1 last; omit = selected")]
            s.requires = needs(destructive: true)
            s.triggers = [
                .fr: ["supprime le clip", "enlève le clip", "retire le clip", "efface ce clip", "supprime ce plan"],
                .en: ["delete the clip", "remove the clip", "delete clip"],
            ]
            s.examples = [
                fr("supprime le clip 2", ["clipNumber": 2]),
                fr("supprime ce clip"),
                fr("supprime le dernier clip", ["clipNumber": -1]),
                en("delete the last clip", ["clipNumber": -1]),
            ]
            s.verify = [.structural(.clipCount, .decreased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var deleteRange: OperationSpec {
        legacy(.deleteRange, in: [.video], .cut, .geometry,
               title: t("Cut a range", "Couper un passage"), summary: t("Removes start…end", "Enlève début…fin")) { s in
            s.coreIn = [.video]
            s.params = [Step.startSeconds(.required), Step.endSeconds(), Step.clipNumber().offCard]
            s.triggers = [
                .fr: ["coupe les", "enlève les", "premières secondes", "dernières secondes", "coupe de", "supprime le passage"],
                .en: ["cut the first", "remove the last", "first seconds", "last seconds", "cut from", "delete the part"],
            ]
            s.examples = [
                fr("coupe les 3 premières secondes", ["startSeconds": 0, "endSeconds": 3]),
                fr("coupe le clip 2 de 3 à 5 secondes", ["clipNumber": 2, "startSeconds": 3, "endSeconds": 5]),
                en("remove from 10 to 12 seconds", ["startSeconds": 10, "endSeconds": 12]),
                para("coupe les trois premières secondes", .fr, ["startSeconds": 0, "endSeconds": 3]),
            ]
            s.verify = [.structural(.timelineDuration, .decreased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var setSpeed: OperationSpec {
        legacy(.setSpeed, in: [.video], .speed, .geometry,
               title: t("Speed", "Vitesse"), summary: t("Faster or slower playback", "Lecture plus rapide ou ralentie")) { s in
            s.coreIn = [.video]
            s.params = [Step.speed(), Step.clipNumber().offCard, Step.scope(doc: "all for every clip").offCard]
            s.triggers = [
                .fr: ["accélère", "ralentis", "ralenti", "vitesse", "x2", "deux fois plus vite", "au ralenti"],
                .en: ["speed up", "slow down", "slow motion", "faster", "speed", "twice as fast"],
            ]
            s.examples = [
                fr("accélère x2", ["speed": 2]),
                fr("mets le clip 2 au ralenti", ["clipNumber": 2, "speed": 0.5]),
                en("slow motion", ["speed": 0.5]),
                para("accélère deux fois", .fr, ["speed": 2]),
            ]
            s.verify = [.structural(.timelineDuration, .changed)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "speed"
        }
    }

    static var reverse: OperationSpec {
        legacy(.reverse, in: [.video], .speed, .geometry,
               title: t("Reverse", "Lecture inversée"), summary: t("Plays the clip backwards", "Lit le clip à l'envers")) { s in
            s.params = [Step.clipNumber().offCard]
            s.triggers = [
                .fr: ["inverse la vidéo", "à l'envers", "lecture inversée", "en arrière", "rembobine"],
                .en: ["reverse", "play backwards", "rewind effect", "backwards"],
            ]
            s.examples = [
                fr("inverse la vidéo"),
                fr("joue le clip à l'envers"),
                en("play it backwards"),
                near("inverse les clips 1 et 2", .fr, expected: "moveClip"),
            ]
            s.verify = [.unverifiable("the playback direction is judged by eye")]
            s.grammar = .owned
            s.uiTool = "speed"
        }
    }

    static var freezeFrame: OperationSpec {
        legacy(.freezeFrame, in: [.video], .speed, .geometry,
               title: t("Freeze frame", "Arrêt sur image"), summary: t("Holds one frame", "Fige une image")) { s in
            s.params = [Step.seconds(doc: "where; omit = playhead"), Step.amount(0...100, .percent, doc: "hold length").offCard]
            s.triggers = [
                .fr: ["fige l'image", "arrêt sur image", "freeze", "image figée"],
                .en: ["freeze frame", "freeze the frame", "hold the frame"],
            ]
            s.examples = [
                fr("fige l'image à 4 secondes", ["seconds": 4]),
                fr("arrêt sur image ici"),
                en("freeze frame at 3 seconds", ["seconds": 3]),
            ]
            s.verify = [.structural(.timelineDuration, .increased)]
            s.grammar = .owned
            s.uiTool = "speed"
        }
    }

    static var duplicateClip: OperationSpec {
        legacy(.duplicateClip, in: [.video], .cut, .geometry,
               title: t("Duplicate clip", "Dupliquer le clip"), summary: t("Copies a clip after itself", "Copie un clip juste après")) { s in
            s.params = [Step.clipNumber()]
            s.triggers = [
                .fr: ["duplique le clip", "copie le clip", "double le clip", "duplique le plan", "copie le plan", "copie"],
                .en: ["duplicate the clip", "copy the clip"],
            ]
            s.examples = [
                fr("duplique le clip"),
                fr("duplique le clip 2", ["clipNumber": 2]),
                en("duplicate the clip"),
            ]
            s.verify = [.structural(.clipCount, .increased)]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var moveClip: OperationSpec {
        legacy(.moveClip, in: [.video], .cut, .geometry,
               title: t("Move clip", "Déplacer le clip"), summary: t("Moves a clip to a new position", "Change la place d'un clip")) { s in
            s.params = [Step.clipNumber(.required, doc: "the clip moved"), Step.choiceIndex(1...999, doc: "its new position, 1-based").required()]
            s.triggers = [
                .fr: ["déplace le clip", "mets le clip", "au début", "à la fin", "inverse les clips", "échange les clips", "intervertis"],
                .en: ["move clip", "move the clip", "to the beginning", "to the end", "swap the clips"],
            ]
            s.examples = [
                fr("déplace le clip 2 au début", ["clipNumber": 2, "choiceIndex": 1]),
                fr("inverse les clips 1 et 2", ["clipNumber": 1, "choiceIndex": 2]),
                en("move clip 2 to the beginning", ["clipNumber": 2, "choiceIndex": 1]),
            ]
            s.verify = [.unverifiable("the order is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "cut"
        }
    }

    static var extractFrame: OperationSpec {
        legacy(.extractFrame, in: [.video], .export, .output,
               title: t("Extract frame", "Extraire une image"), summary: t("Saves one frame as a photo", "Enregistre une image en photo")) { s in
            s.params = [Step.seconds(doc: "which frame; omit = playhead")]
            s.triggers = [
                .fr: ["extrais l'image", "capture d'écran", "fais une photo de", "enregistre cette image"],
                .en: ["extract a frame", "screenshot", "grab this frame", "save the frame"],
            ]
            s.examples = [
                fr("extrais l'image à 3 secondes", ["seconds": 3]),
                fr("fais une capture d'écran"),
                en("grab this frame"),
            ]
            s.verify = [.unverifiable("the photo is saved outside the timeline")]
            s.grammar = .owned
            s.uiTool = "frame"
        }
    }

    static var addTransition: OperationSpec {
        legacy(.addTransition, in: [.video], .transitions, .effects,
               title: t("Transition", "Transition"), summary: t("A transition between clips", "Une transition entre les clips")) { s in
            s.coreIn = [.video]
            s.params = [Step.transition(), Step.scope(doc: "all = every cut"), Step.clipNumber().offCard]
            s.triggers = [
                .fr: ["transition", "fondu enchaîné", "fondu au noir", "fondu", "glissé", "entre les clips"],
                .en: ["transition", "crossfade", "cross dissolve", "fade to black", "slide", "between the clips"],
            ]
            s.examples = [
                fr("ajoute un fondu enchaîné entre tous les clips", ["transition": "crossDissolve", "scope": "all"]),
                fr("ajoute une transition glissée", ["transition": "slideLeft"]),
                en("add a fade to black between the clips", ["transition": "fadeToBlack", "scope": "all"]),
            ]
            s.verify = [.unverifiable("transitions are checked by the executor")]
            s.grammar = .owned
            s.uiTool = "transitions"
        }
    }

    static var removeTransition: OperationSpec {
        legacy(.removeTransition, in: [.video], .transitions, .effects,
               title: t("Remove transition", "Enlever la transition"), summary: t("Back to a straight cut", "Revient à une coupe franche")) { s in
            s.params = [Step.scope(doc: "all = every cut"), Step.clipNumber().offCard]
            s.triggers = [
                .fr: ["enlève la transition", "supprime les transitions", "sans transition", "coupe franche"],
                .en: ["remove the transition", "no transition", "hard cut"],
            ]
            s.examples = [
                fr("enlève la transition"),
                fr("supprime toutes les transitions", ["scope": "all"]),
                en("remove the transitions", ["scope": "all"]),
            ]
            s.verify = [.unverifiable("transitions are checked by the executor")]
            s.grammar = .owned
            s.uiTool = "transitions"
        }
    }

    static var stabilize: OperationSpec {
        legacy(.stabilize, in: [.video], .motion, .cleanup,
               title: t("Stabilise", "Stabiliser"), summary: t("Steadies shaky footage", "Calme les tremblements")) { s in
            s.params = [Step.clipNumber().offCard, Step.scope(doc: "all clips").offCard]
            s.requires = needs(cost: .heavy)
            s.triggers = [
                .fr: ["stabilise", "stabilisation", "ça tremble", "tremblements", "image qui bouge"],
                .en: ["stabilise", "stabilize", "shaky", "steady the shot"],
            ]
            s.examples = [
                fr("stabilise la vidéo"),
                fr("ça tremble, stabilise"),
                en("stabilize the video"),
            ]
            s.verify = [.unverifiable("stability is judged by eye")]
            s.grammar = .owned
            s.uiTool = "motion"
        }
    }
}
