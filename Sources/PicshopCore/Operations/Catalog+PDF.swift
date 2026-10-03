import Foundation

/// PDF: pages, text marks, replacement, signature, numbering, merge. A page is named by
/// clipNumber (1-based, -1 the last; omitted = the current page), the planner's contract.
enum CatalogPDF {
    static var all: [OperationSpec] {
        [goToPage, deletePage, rotatePage, movePage, duplicatePage, insertBlankPage, extractPage, highlightText, underlineText, redactText,
         findText, replaceText, addSignature, addPageNumbers, mergeDocument]
    }

    static let pageScope = ["current", "all"]

    static var goToPage: OperationSpec {
        legacy(.goToPage, in: [.pdf], .pages, .refDependent,
               title: t("Go to page", "Aller à la page"), summary: t("Shows a page", "Affiche une page")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page(.required)]
            s.triggers = [
                .fr: ["va à la page", "montre la page", "page suivante", "dernière page", "ouvre la page"],
                .en: ["go to page", "show page", "next page", "last page"],
            ]
            s.examples = [
                fr("va à la page 4", ["clipNumber": 4]),
                fr("montre-moi la dernière page", ["clipNumber": -1]),
                en("go to page 2", ["clipNumber": 2]),
            ]
            s.verify = [.unverifiable("only the view changes")]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var deletePage: OperationSpec {
        legacy(.deletePage, in: [.pdf], .pages, .geometry,
               title: t("Delete page", "Supprimer la page"), summary: t("Removes a page", "Enlève une page")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page()]
            s.requires = needs(destructive: true)
            s.triggers = [
                .fr: ["supprime la page", "enlève la page", "efface la page", "retire la page"],
                .en: ["delete page", "remove the page", "delete the last page"],
            ]
            s.examples = [
                fr("supprime la page 3", ["clipNumber": 3]),
                fr("enlève la dernière page", ["clipNumber": -1]),
                en("delete page 2", ["clipNumber": 2]),
            ]
            s.verify = [.structural(.pageCount, .delta(-1))]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var rotatePage: OperationSpec {
        legacy(.rotatePage, in: [.pdf], .pages, .geometry,
               title: t("Rotate page", "Pivoter la page"), summary: t("Turns a page or every page", "Tourne une page ou toutes")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page(), Step.degrees(-270...270, doc: "90, 180, -90"), Step.scope(pageScope, doc: "all = every page")]
            s.triggers = [
                .fr: ["pivote la page", "tourne la page", "pivote toutes les pages", "page à l'envers"],
                .en: ["rotate the page", "rotate page", "rotate all pages", "page is upside down"],
            ]
            s.examples = [
                fr("pivote toutes les pages", ["scope": "all", "degrees": 90]),
                fr("tourne la page 2 à l'envers", ["clipNumber": 2, "degrees": 180]),
                en("rotate page 3 to the left", ["clipNumber": 3, "degrees": -90]),
            ]
            s.verify = [.unverifiable("the page rotation is checked by the executor")]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var movePage: OperationSpec {
        legacy(.movePage, in: [.pdf], .pages, .geometry,
               title: t("Move page", "Déplacer la page"), summary: t("Moves a page to a new position", "Change la place d'une page")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page(doc: "the page moved; omit = current"), Step.choiceIndex(-1...9_999, doc: "its new position, -1 the end").required()]
            s.triggers = [
                .fr: ["déplace la page", "mets la page", "à la fin", "au début", "en première position"],
                .en: ["move page", "move the page", "to the end", "to the beginning"],
            ]
            s.examples = [
                fr("déplace la page 2 à la fin", ["clipNumber": 2, "choiceIndex": -1]),
                fr("mets la page 5 en première position", ["clipNumber": 5, "choiceIndex": 1]),
                en("move page 3 to position 1", ["clipNumber": 3, "choiceIndex": 1]),
            ]
            s.verify = [.structural(.pageCount, .unchanged)]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var duplicatePage: OperationSpec {
        legacy(.duplicatePage, in: [.pdf], .pages, .geometry,
               title: t("Duplicate page", "Dupliquer la page"), summary: t("Copies a page after itself", "Copie une page juste après")) { s in
            s.params = [Step.page()]
            s.triggers = [
                .fr: ["duplique la page", "copie la page", "double la page"],
                .en: ["duplicate page", "copy the page"],
            ]
            s.examples = [
                fr("duplique la page 1", ["clipNumber": 1]),
                fr("copie cette page"),
                en("duplicate page 2", ["clipNumber": 2]),
            ]
            s.verify = [.structural(.pageCount, .delta(1))]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var insertBlankPage: OperationSpec {
        legacy(.insertBlankPage, in: [.pdf], .pages, .geometry,
               title: t("Insert blank page", "Insérer une page blanche"), summary: t("A blank page at a position", "Une page vierge à un endroit")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page(doc: "page; after it with scope selection"), Step.scope(["current", "selection"], doc: "selection = after the page")]
            s.triggers = [
                .fr: ["page blanche", "insère une page", "ajoute une page vide", "page vierge"],
                .en: ["blank page", "insert a page", "add an empty page"],
            ]
            s.examples = [
                fr("insère une page blanche après la page 2", ["clipNumber": 2, "scope": "selection"]),
                fr("ajoute une page vide"),
                en("insert a blank page after page 1", ["clipNumber": 1, "scope": "selection"]),
            ]
            s.verify = [.structural(.pageCount, .delta(1))]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var extractPage: OperationSpec {
        legacy(.extractPage, in: [.pdf], .export, .output,
               title: t("Extract page", "Extraire la page"), summary: t("Saves a page as its own PDF", "Enregistre une page dans un PDF à part")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page()]
            s.triggers = [
                .fr: ["extrais la page", "sors la page", "exporte la page", "page à part"],
                .en: ["extract page", "save the page as a PDF", "export this page"],
            ]
            s.examples = [
                fr("extrais la page 2", ["clipNumber": 2]),
                fr("exporte cette page à part"),
                en("extract page 3", ["clipNumber": 3]),
            ]
            s.verify = [.unverifiable("the extracted file is saved outside the document")]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var highlightText: OperationSpec {
        legacy(.highlightText, in: [.pdf], .annotate, .text,
               title: t("Highlight", "Surligner"), summary: t("Highlights the words where they appear", "Surligne les mots là où ils sont")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.text(.required, max: 120, doc: "the words"), Step.color(), Step.scope(pageScope, doc: "all = whole document")]
            s.triggers = [
                .fr: ["surligne", "surligne le mot", "fluo", "mets en évidence"],
                .en: ["highlight", "highlight the word", "mark the word"],
            ]
            s.examples = [
                fr("surligne le mot contrat", ["text": "contrat"]),
                fr("surligne « date limite » en vert partout", ["text": "date limite", "color": "green", "scope": "all"]),
                en("highlight the word total", ["text": "total"]),
            ]
            s.verify = [.structural(.markupCount, .increased)]
            s.grammar = .owned
            s.uiTool = "highlight"
        }
    }

    static var underlineText: OperationSpec {
        legacy(.underlineText, in: [.pdf], .annotate, .text,
               title: t("Underline or strike", "Souligner ou barrer"), summary: t("Underlines words; red strikes them out", "Souligne ; en rouge, barre les mots")) { s in
            s.params = [Step.text(.required, max: 120, doc: "the words"), Step.color(doc: "red strikes out"), Step.scope(pageScope, doc: "all = whole document")]
            s.triggers = [
                .fr: ["souligne", "souligne le mot", "trait sous", "trace un trait", "barre le mot", "rature"],
                .en: ["underline", "strike out", "strikethrough", "cross out"],
            ]
            s.examples = [
                fr("souligne le mot total en rouge", ["text": "total", "color": "red"]),
                fr("barre le mot brouillon", ["text": "brouillon", "color": "red"]),
                en("underline the word deadline", ["text": "deadline"]),
            ]
            s.verify = [.structural(.markupCount, .increased)]
            s.grammar = .owned
            s.uiTool = "highlight"
        }
    }

    static var redactText: OperationSpec {
        legacy(.redactText, in: [.pdf], .annotate, .text,
               title: t("Redact", "Caviarder"), summary: t("Blacks out words for good", "Noircit des mots définitivement")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.text(.required, max: 120, doc: "the words"), Step.scope(pageScope, doc: "all = whole document")]
            s.requires = needs(destructive: true)
            s.triggers = [
                .fr: ["caviarde", "noircis", "masque le nom", "anonymise le document", "cache le numéro"],
                .en: ["redact", "black out", "hide the name", "censor"],
            ]
            s.examples = [
                fr("caviarde les numéros de téléphone", ["text": "numéros de téléphone"]),
                fr("noircis le nom Dupont partout", ["text": "Dupont", "scope": "all"]),
                en("redact the name Smith", ["text": "Smith"]),
            ]
            s.verify = [.structural(.markupCount, .increased)]
            s.grammar = .owned
            s.uiTool = "redact"
        }
    }

    static var findText: OperationSpec {
        legacy(.findText, in: [.pdf], .pdfText, .refDependent,
               title: t("Find", "Chercher"), summary: t("Finds words in the document", "Trouve des mots dans le document")) { s in
            s.params = [Step.text(.required, max: 120, doc: "the words"), Step.scope(pageScope, doc: "all = whole document")]
            s.triggers = [
                .fr: ["cherche", "trouve le mot", "où est écrit", "recherche"],
                .en: ["find", "search for", "where does it say"],
            ]
            s.examples = [
                fr("cherche le mot facture", ["text": "facture"]),
                fr("trouve « échéance » dans le document", ["text": "échéance", "scope": "all"]),
                en("find the word invoice", ["text": "invoice"]),
            ]
            s.verify = [.unverifiable("a search changes nothing")]
            s.grammar = .owned
            s.uiTool = "highlight"
        }
    }

    static var replaceText: OperationSpec {
        legacy(.replaceText, in: [.pdf], .pdfText, .text,
               title: t("Replace text", "Remplacer le texte"), summary: t("Replaces words; empty erases them", "Remplace des mots ; vide les efface")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.text(.required, max: 120, doc: "the words there now"), Step.replacement(), Step.scope(pageScope, doc: "all = whole document")]
            s.triggers = [
                .fr: ["remplace", "remplace par", "corrige le mot", "efface le mot", "change le mot"],
                .en: ["replace", "replace with", "change the word", "erase the word"],
            ]
            s.examples = [
                fr("remplace monsieur par madame", ["text": "monsieur", "replacement": "madame"]),
                fr("efface le mot brouillon", ["text": "brouillon", "replacement": ""]),
                en("replace 2025 with 2026 everywhere", ["text": "2025", "replacement": "2026", "scope": "all"]),
            ]
            s.verify = [.pixels("textAbsent", .changed)]
            s.grammar = .owned
            s.uiTool = "text"
        }
    }

    static var addSignature: OperationSpec {
        legacy(.addSignature, in: [.pdf], .sign, .composition,
               title: t("Sign", "Signer"), summary: t("Places your saved signature", "Place ta signature enregistrée")) { s in
            s.coreIn = [.pdf]
            s.params = [Step.page(), Step.placement]
            s.requires = needs(referenceAsset: .signature)
            s.triggers = [
                .fr: ["signe", "ajoute ma signature", "signature", "signe en bas"],
                .en: ["sign", "add my signature", "signature", "sign at the bottom"],
            ]
            s.examples = [
                fr("signe en bas à droite", ["placement": "bottomTrailing"]),
                fr("ajoute ma signature sur la dernière page", ["clipNumber": -1]),
                en("sign at the bottom", ["placement": "bottom"]),
            ]
            s.verify = [.structural(.markupCount, .increased)]
            s.grammar = .owned
            s.uiTool = "signature"
        }
    }

    static var addPageNumbers: OperationSpec {
        legacy(.addPageNumbers, in: [.pdf], .document, .text,
               title: t("Page numbers", "Numéros de page"), summary: t("Numbers every page", "Numérote toutes les pages")) { s in
            s.coreIn = [.pdf]
            s.triggers = [
                .fr: ["numérote les pages", "numéros de page", "pagination", "ajoute les numéros"],
                .en: ["page numbers", "number the pages", "add page numbers"],
            ]
            s.examples = [
                fr("numérote les pages"),
                fr("ajoute les numéros de page"),
                en("add page numbers"),
            ]
            s.verify = [.structural(.markupCount, .increased)]
            s.grammar = .owned
            s.uiTool = "pages"
        }
    }

    static var mergeDocument: OperationSpec {
        legacy(.mergeDocument, in: [.pdf], .document, .composition,
               title: t("Merge", "Fusionner"), summary: t("Adds another PDF or an image", "Ajoute un autre PDF ou une image")) { s in
            s.params = [Step.textChoice(["pdf", "image"], doc: "image to place a picture")]
            s.requires = needs(referenceAsset: .image)
            s.triggers = [
                .fr: ["fusionne avec", "ajoute un autre PDF", "combine les PDF", "ajoute une image", "insère une photo"],
                .en: ["merge with", "add another PDF", "combine the PDFs", "add an image"],
            ]
            s.examples = [
                fr("fusionne avec un autre PDF"),
                fr("ajoute une image", ["text": "image"]),
                en("merge it with another PDF"),
            ]
            s.verify = [.unverifiable("needs the file picked by the user")]
            s.grammar = .owned
            s.uiTool = "image"
        }
    }
}
