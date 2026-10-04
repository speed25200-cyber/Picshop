import Foundation

/// Text: write, rewrite, remove and move text, and the title behind the subject.
enum CatalogPhotoText {
    static var all: [OperationSpec] { [addText, editText, removeText, moveText, textBehind] }

    static var addText: OperationSpec {
        legacy(.addText, in: [.photo, .video, .pdf], .text, .text,
               title: t("Add text", "Ajouter du texte"), summary: t("Writes words on the picture or page", "Écrit des mots sur l'image ou la page")) { s in
            s.coreIn = [.photo, .video, .pdf]
            s.params = [Step.text(.required, doc: "the words, verbatim"), Step.placement, Step.color(),
                        Step.ref([.printedText, .textLayer, .object, .freeArea], doc: "f1 inside, t1 under that text"),
                        Step.box(doc: "[x1,y1,x2,y2] 0-1000").offCard, Step.size, Step.weight.offCard, Step.align, Step.font.offCard, Step.match]
            s.triggers = [
                .fr: ["ajoute le texte", "écris", "mets le texte", "ajoute un titre", "légende", "texte en haut", "texte en bas"],
                .en: ["add text", "write", "add a title", "caption", "text at the top", "text saying"],
            ]
            s.examples = [
                fr("ajoute le texte Été 2026 en haut en jaune", ["text": "Été 2026", "placement": "top", "color": "yellow"]),
                fr("écris « Bon anniversaire » en bas", ["text": "Bon anniversaire", "placement": "bottom"]),
                fr("ajoute le texte Approuvé en haut", ["text": "Approuvé", "placement": "top"]),
                en("add text saying Happy Birthday at the bottom", ["text": "Happy Birthday", "placement": "bottom"]),
                en("write Summer 2026 at the top in yellow", ["text": "Summer 2026", "placement": "top", "color": "yellow"]),
                near("change le texte en Hello", .fr, expected: "editText"),
            ]
            s.verify = [.structural(.textLayerCount, .increased)]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var editText: OperationSpec {
        legacy(.editText, in: [.photo, .video], .text, .refDependent,
               title: t("Edit text", "Modifier le texte"), summary: t("New words or style for a text, same look", "Nouveaux mots ou style pour un texte")) { s in
            s.coreIn = [.photo]
            s.params = [Step.ref([.printedText, .textLayer], doc: "t3 printed, l2 yours"), Step.text(doc: "the new words"), Step.color(),
                        Step.size, Step.weight, Step.font.offCard, Step.align, Step.placement]
            s.triggers = [
                .fr: ["change le texte", "remplace le texte", "corrige le texte", "modifie le titre", "en gras", "plus gros", "police",
                      "déplace le titre", "titre en haut", "titre en bas"],
                .en: ["change the text", "edit the text", "replace the text", "make the title bold", "bigger title", "move the title"],
            ]
            s.examples = [
                fr("change le texte en Hello", ["text": "Hello"]),
                fr("mets le titre en gras", ["ref": "l1", "weight": "bold"]),
                fr("remplace « 2025 » par « 2026 »", ["ref": "t1", "text": "2026"]),
                en("change the text to Hello", ["text": "Hello"]),
                en("make the title bold", ["ref": "l1", "weight": "bold"]),
                near("ajoute le texte Promo en haut", .fr, expected: "addText"),
            ]
            s.verify = [.pixels("textPresent", .changed)]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var removeText: OperationSpec {
        legacy(.removeText, in: [.photo, .video, .pdf], .text, .refDependent,
               title: t("Remove text", "Enlever le texte"), summary: t("Erases a text block or a layer", "Efface un bloc de texte ou un calque")) { s in
            s.params = [Step.ref([.printedText, .textLayer], doc: "t3 printed, l2 yours"), Step.text(doc: "pdf: all or pageNumber").offCard]
            s.triggers = [
                .fr: ["enlève le texte", "supprime le texte", "efface le titre", "enlève le titre", "efface le texte", "enlève la note", "efface la note"],
                .en: ["remove the text", "delete the text", "erase the title", "remove the caption", "remove the note"],
            ]
            s.examples = [
                fr("enlève le texte"),
                fr("efface le titre", ["ref": "l1"]),
                en("remove the text"),
                fr("supprime ce texte", ["ref": "l1"]),
                en("delete the title", ["ref": "l1"]),
                near("efface la zone en haut à gauche", .fr, expected: "eraseRegion"),
            ]
            s.verify = [.pixels("textAbsent", .changed)]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var moveText: OperationSpec {
        legacy(.moveText, in: [.photo], .text, .refDependent,
               title: t("Move text", "Déplacer le texte"), summary: t("Moves a text block", "Déplace un bloc de texte")) { s in
            s.params = [Step.ref([.printedText, .textLayer], doc: "t3 or l2"), Step.placement.inGroup("to"), Step.box(doc: "[x1,y1,x2,y2] 0-1000").inGroup("to"),
                        Step.point.inGroup("to"), Step.degrees(doc: "direction: 0 right, 90 up").inGroup("to").offCard,
                        Step.amount(0...1, .fraction, doc: "distance").offCard]
            s.triggers = [
                .fr: ["déplace le titre", "déplace le texte", "monte le texte", "descends le titre", "mets le texte en haut"],
                .en: ["move the title", "move the text", "move the caption up"],
            ]
            s.examples = [
                fr("déplace le titre en haut", ["ref": "l1", "placement": "top"]),
                fr("mets ce texte en bas à droite", ["ref": "t2", "placement": "bottomTrailing"]),
                en("move the title to the bottom", ["ref": "l1", "placement": "bottom"]),
                fr("descends le titre en bas", ["ref": "l1", "placement": "bottom"]),
                en("put this text at the top", ["ref": "t2", "placement": "top"]),
                near("déplace le chien vers la gauche", .fr, expected: "moveObject"),
            ]
            s.verify = [.unverifiable("the new place is judged by eye")]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var textBehind: OperationSpec {
        legacy(.textBehind, in: [.photo], .text, .text,
               title: t("Text behind", "Texte derrière"), summary: t("A title behind the person", "Un titre derrière la personne")) { s in
            s.params = [Step.text(max: 60, doc: "the words")]
            s.requires = needs(subject: true, cost: .fast)
            s.triggers = [
                .fr: ["texte derrière", "derrière la personne", "effet profondeur", "titre derrière", "effet écran verrouillé"],
                .en: ["text behind", "behind the person", "depth effect", "lock screen effect", "title behind"],
            ]
            s.examples = [
                fr("écris « Paris » derrière la personne", ["text": "Paris"]),
                fr("effet profondeur avec le mot Été", ["text": "Été"]),
                en("put the title behind me", ["text": "Summer"]),
                fr("mets le mot Été derrière moi", ["text": "Été"]),
                en("write Paris behind the person", ["text": "Paris"]),
                near("ajoute le texte Paris en haut", .fr, expected: "addText"),
            ]
            s.verify = [.structural(.textLayerCount, .increased)]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }
}
