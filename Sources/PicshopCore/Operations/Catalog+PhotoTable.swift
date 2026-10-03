import Foundation

/// Tables seen on the picture: fill, clear and highlight cells by row and column names.
enum CatalogPhotoTable {
    static var all: [OperationSpec] { [fillCells, clearCells, highlightCells] }

    static var fillCells: OperationSpec {
        legacy(.fillCells, in: [.photo], .table, .refDependent,
               title: t("Fill cells", "Remplir des cases"), summary: t("Writes values in table cells, one step", "Écrit des valeurs dans les cases, en une étape")) { s in
            s.coreIn = [.photo]
            // Text or generated values; or only a colour, weight or size to restyle the cells already filled.
            s.params = [Step.text(max: 200, doc: "the value; list: a|b|c").inGroup("content"), Step.values.inGroup("content"), Step.cells,
                        Step.row, Step.column, Step.min, Step.max, Step.decimals, Step.color().offCard.inGroup("content"),
                        Step.weight.offCard.inGroup("content"), Step.size.offCard.inGroup("content")]
            s.requires = needs(table: true)
            s.triggers = [
                .fr: ["remplis", "remplis les cases", "cases vides", "le tableau", "la colonne", "la ligne", "au hasard", "des chiffres", "complète le tableau"],
                .en: ["fill", "fill the cells", "empty cells", "the table", "the column", "the row", "random numbers", "complete the table"],
            ]
            s.examples = [
                fr("remplis les cases vides avec des 1", ["text": "1", "cells": "empty"]),
                fr("mets des nombres au hasard entre 50 et 90", ["values": "random", "min": 50, "max": 90]),
                fr("remplis la colonne Prix avec 10", ["text": "10", "column": "Prix"]),
                en("fill the empty cells with zeros", ["text": "0", "cells": "empty"]),
                en("put random numbers in the Score column", ["values": "random", "column": "Score"]),
            ]
            s.verify = [.structural(.textLayerCount, .increased)]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "text"
        }
    }

    static var clearCells: OperationSpec {
        legacy(.clearCells, in: [.photo], .table, .refDependent,
               title: t("Clear cells", "Vider des cases"), summary: t("Empties table cells", "Vide des cases du tableau")) { s in
            s.params = [Step.row.inGroup("cells"), Step.column.inGroup("cells"), Step.cells.inGroup("cells")]
            s.requires = needs(table: true)
            s.triggers = [
                .fr: ["vide la colonne", "vide la ligne", "efface la colonne", "vide les cases", "efface les valeurs"],
                .en: ["clear the column", "clear the row", "empty the cells", "clear the values"],
            ]
            s.examples = [
                fr("vide la colonne Total", ["column": "Total"]),
                fr("efface toute la ligne 3", ["row": "3", "cells": "all"]),
                en("clear the second column", ["column": "2", "cells": "all"]),
            ]
            s.verify = [.unverifiable("emptied cells are checked by OCR from W2")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "text"
        }
    }

    static var highlightCells: OperationSpec {
        legacy(.highlightCells, in: [.photo], .table, .refDependent,
               title: t("Highlight cells", "Surligner des cases"), summary: t("A translucent box over rows or columns", "Un fond coloré sur des lignes ou colonnes")) { s in
            s.params = [Step.row.inGroup("cells"), Step.column.inGroup("cells"), Step.color()]
            s.requires = needs(table: true)
            s.triggers = [
                .fr: ["surligne la colonne", "surligne la ligne", "colore la ligne", "mets en évidence la colonne"],
                .en: ["highlight the column", "highlight the row", "shade the row"],
            ]
            s.examples = [
                fr("surligne la colonne Total en jaune", ["column": "Total", "color": "yellow"]),
                fr("colore la ligne 2 en vert", ["row": "2", "color": "green"]),
                en("highlight the last row", ["row": "-1"]),
            ]
            s.verify = [.unverifiable("the highlight is judged by eye")]
            s.grammar = .owned
            s.fastLane = true
            s.uiTool = "text"
        }
    }
}
