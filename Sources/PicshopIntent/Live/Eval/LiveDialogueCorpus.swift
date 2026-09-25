import Foundation
import PicshopCore

// The dialogue LiveEval (A17 and the "understand any instruction" bar): multi-turn French and English
// conversations on real pictures (the report's benchmark table, empty, with values or with the stray
// "1", and a summer-sale poster), each turn with what a good answer does to the editor. Every turn also
// carries one good model answer in Qwen3.5's own output format: the scripted-model lane replays it
// through the whole turn loop (filter, coercer, validator, handler, the real executor, verify), the
// grammar lane runs the same words through the rules alone, as Live does without a model.

/// What the picture is at the start of a dialogue.
public enum DialoguePicture: String, Sendable, CaseIterable {
    /// The report's screenshot: 9 × 5 table, every data cell empty.
    case benchmark
    /// The same table with its printed values.
    case values
    /// The user's own project: the empty table and the giant "1" of the old build in r6c3.
    case stray
    /// A summer-sale poster: title t1, subtitle t2, price t3, a person o1, free areas f1 and f2.
    case poster
}

/// What a good answer does, checked on the editor after the turn. Built by chaining.
public struct DialogueExpect: Sendable {
    public struct Cell: Sendable { public var row: Int; public var column: Int; public var text: String? }
    public struct Styled: Sendable { public var text: String; public var colour: String }
    public struct Placed: Sendable { public var text: String; public var y: ClosedRange<Double> }

    /// The actions that applied this turn (a set); nil: any.
    public var actions: Set<IntentAction>?
    /// Nothing may change (questions, refusals).
    public var noEdit = false
    public var filled: Int?
    public var cells: [Cell] = []
    public var columns: [Cell] = []
    public var rows: [Cell] = []
    public var randomIn: ClosedRange<Double>?
    public var cellLayers: Int?
    public var texts: [String] = []
    public var gone: [String] = []
    public var highlights: Int?
    public var erased = false
    public var said: [String] = []
    public var asks = false
    public var bigger: String?
    public var smaller: String?
    public var colours: [Styled] = []
    public var bold = false
    public var placed: [Placed] = []
    public var layerCounts: [String: Int] = [:]
    /// Every cell value written before the turn is still there after it (a restyle never draws again).
    public var keepsValues = false
    /// Never a plain « C'est fait. » / "Done." (a check failed: the line says so).
    public var neverDone = false
    /// At most this many executor runs in the turn (one call, then at most one repair round).
    public var maxRuns: Int?
    /// A new text may land over other text (said so); otherwise at most 10 % of it may.
    public var overlapAllowed = false

    public static var any: DialogueExpect { DialogueExpect() }

    public func action(_ actions: IntentAction...) -> Self { var copy = self; copy.actions = Set(actions); return copy }
    public func noChange() -> Self { var copy = self; copy.noEdit = true; return copy }
    public func filled(_ count: Int) -> Self { var copy = self; copy.filled = count; return copy }
    public func cell(_ row: Int, _ column: Int, _ text: String) -> Self { var copy = self; copy.cells.append(Cell(row: row, column: column, text: text)); return copy }
    public func empty(_ row: Int, _ column: Int) -> Self { var copy = self; copy.cells.append(Cell(row: row, column: column, text: nil)); return copy }
    public func column(_ column: Int, _ text: String? = nil) -> Self { var copy = self; copy.columns.append(Cell(row: 0, column: column, text: text)); return copy }
    public func row(_ row: Int, _ text: String? = nil) -> Self { var copy = self; copy.rows.append(Cell(row: row, column: 0, text: text)); return copy }
    public func random(_ range: ClosedRange<Double>) -> Self { var copy = self; copy.randomIn = range; return copy }
    public func layers(_ count: Int) -> Self { var copy = self; copy.cellLayers = count; return copy }
    public func text(_ text: String) -> Self { var copy = self; copy.texts.append(text); return copy }
    public func gone(_ text: String) -> Self { var copy = self; copy.gone.append(text); return copy }
    public func highlighted(_ count: Int) -> Self { var copy = self; copy.highlights = count; return copy }
    public func erasing() -> Self { var copy = self; copy.erased = true; return copy }
    public func said(_ words: String...) -> Self { var copy = self; copy.said += words; return copy }
    public func asking() -> Self { var copy = self; copy.asks = true; return copy }
    public func grew(_ text: String) -> Self { var copy = self; copy.bigger = text; return copy }
    public func shrank(_ text: String) -> Self { var copy = self; copy.smaller = text; return copy }
    public func colour(_ text: String, _ name: String) -> Self { var copy = self; copy.colours.append(Styled(text: text, colour: name)); return copy }
    public func boldCells() -> Self { var copy = self; copy.bold = true; return copy }
    public func at(_ text: String, y: ClosedRange<Double>) -> Self { var copy = self; copy.placed.append(Placed(text: text, y: y)); return copy }
    public func count(_ text: String, _ count: Int) -> Self { var copy = self; copy.layerCounts[text] = count; return copy }
    public func keepingValues() -> Self { var copy = self; copy.keepsValues = true; return copy }
    public func honest(runs: Int = 2) -> Self { var copy = self; copy.neverDone = true; copy.maxRuns = runs; return copy }
    public func overlapping() -> Self { var copy = self; copy.overlapAllowed = true; return copy }
}

/// One thing the user says, one good model answer, and what it must do.
public struct DialogueTurn: Sendable {
    public let text: String
    /// A good answer in Qwen3.5's output format (a sentence, then the call).
    public let reference: String
    /// The model's answer to a round of tool results only (after a failure or a refusal); nil: a sentence.
    public var afterResult: String?
    public let expect: DialogueExpect
    /// What the model says after a second round of results (once its repair ran); nil: a plain line.
    public var closing: String?

    public init(text: String, reference: String, afterResult: String? = nil, expect: DialogueExpect, closing: String? = nil) {
        self.text = text
        self.reference = reference
        self.afterResult = afterResult
        self.expect = expect
        self.closing = closing
    }
}

public struct LiveDialogueCase: Sendable {
    public enum Category: String, CaseIterable, Sendable { case table, text, followUp, reference, compound, question, recovery, verify }

    public let name: String
    public let category: Category
    public let picture: DialoguePicture
    public let turns: [DialogueTurn]
    /// Check tags the render never reads (a text too small, a cell smudged): act-then-verify fails on them.
    public var failingChecks: Set<String> = []

    public init(name: String, category: Category, picture: DialoguePicture, turns: [DialogueTurn], failingChecks: Set<String> = []) {
        self.name = name
        self.category = category
        self.picture = picture
        self.turns = turns
        self.failingChecks = failingChecks
    }

    /// The reply language, as the speech recognizer's locale gives it: English cases end their name with "EN".
    public var language: NormalizedUtterance.Language { name.hasSuffix(" EN") ? .english : .french }
}

/// The corpus: 186 cases, about half French and half English.
public enum LiveDialogueCases {
    // MARK: Qwen3.5's output format

    public static func call(_ steps: String) -> String {
        "<tool_call>\n<function=apply_edits>\n<parameter=steps>\n\(steps)\n</parameter>\n</function>\n</tool_call>"
    }

    public static func edit(_ sentence: String, _ steps: String) -> String { sentence + "\n\n" + call(steps) }

    public static func undo(_ sentence: String) -> String { sentence + "\n\n<tool_call>\n<function=undo>\n</function>\n</tool_call>" }

    public static func turn(_ text: String, _ reference: String, _ expect: DialogueExpect, after: String? = nil) -> DialogueTurn {
        DialogueTurn(text: text, reference: reference, afterResult: after, expect: expect)
    }

    private static func one(_ name: String, _ category: LiveDialogueCase.Category, _ picture: DialoguePicture, _ text: String, _ reference: String,
                            _ expect: DialogueExpect, after: String? = nil) -> LiveDialogueCase {
        LiveDialogueCase(name: name, category: category, picture: picture, turns: [turn(text, reference, expect, after: after)])
    }

    private static func many(_ name: String, _ category: LiveDialogueCase.Category, _ picture: DialoguePicture, _ turns: [DialogueTurn]) -> LiveDialogueCase {
        LiveDialogueCase(name: name, category: category, picture: picture, turns: turns)
    }

    /// A turn whose render does not read on `failing` check tags: a first call, the model's repair (`repair`),
    /// then its closing line; the grammar lane says the honest line.
    private static func checked(_ name: String, _ picture: DialoguePicture, failing: Set<String>, _ text: String, _ reference: String,
                                repair: String, closing: String? = nil, _ expect: DialogueExpect) -> LiveDialogueCase {
        LiveDialogueCase(name: name, category: .verify, picture: picture,
                         turns: [DialogueTurn(text: text, reference: reference, afterResult: repair, expect: expect, closing: closing)], failingChecks: failing)
    }

    public static let all: [LiveDialogueCase] = table + text + followUps + references + compound + questions + recovery + verify

    // MARK: Table (42)

    static let fillAllOnes = #"[{"action":"fillCells","cells":"empty","text":"1"}]"#
    static let every = DialogueExpect.any.action(.fillCells).filled(45).cell(1, 1, "1").cell(9, 5, "1")

    public static let table: [LiveDialogueCase] = [
        one("the report's sentence", .table, .benchmark, "Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires",
            edit("Je remplis les 45 cases.", fillAllOnes), every.said("45")),
        one("fill all with ones", .table, .benchmark, "remplis toutes les cases avec des 1", edit("Je remplis tout.", fillAllOnes), every),
        one("put one everywhere", .table, .benchmark, "mets 1 dans toutes les cases du tableau", edit("Je mets des 1.", fillAllOnes), every),
        one("write one in each cell", .table, .benchmark, "écris 1 dans chaque case du tableau", edit("J'écris des 1.", fillAllOnes), every),
        one("fill every cell EN", .table, .benchmark, "fill every cell with 1", edit("Filling every cell.", fillAllOnes), every),
        one("zero everywhere EN", .table, .benchmark, "put a zero in every cell", edit("Zeros everywhere.", #"[{"action":"fillCells","text":"0"}]"#),
            .any.action(.fillCells).filled(45).cell(1, 1, "0").cell(5, 3, "0")),
        one("the grid", .table, .benchmark, "remplis la grille avec des 1", edit("Je remplis la grille.", fillAllOnes), every),
        one("complete with zeros", .table, .benchmark, "complète le tableau avec des zéros", edit("Je complète avec des 0.", #"[{"action":"fillCells","text":"0"}]"#),
            .any.action(.fillCells).filled(45).cell(9, 5, "0")),
        one("populate EN", .table, .benchmark, "populate all the cells with 5", edit("Putting 5 everywhere.", #"[{"action":"fillCells","text":"5"}]"#),
            .any.action(.fillCells).filled(45).cell(3, 3, "5")),
        one("each cell EN", .table, .benchmark, "put 1 in each cell of the table", edit("Done in a sec.", fillAllOnes), every),
        one("column Opus 5.5", .table, .benchmark, "remplis la colonne Opus 5.5 avec 1",
            edit("Je remplis la colonne Opus 5.5.", #"[{"action":"fillCells","column":"Opus 5.5","text":"1"}]"#),
            .any.action(.fillCells).filled(9).column(1, "1").empty(1, 2)),
        one("column Opus 5 never 5.5", .table, .benchmark, "remplis la colonne Opus 5 avec des 0",
            edit("Je remplis Opus 5.", #"[{"action":"fillCells","column":"Opus 5","text":"0"}]"#),
            .any.action(.fillCells).filled(9).column(2, "0").empty(1, 1)),
        one("column GPT EN", .table, .benchmark, "fill the GPT-6 Astra column with 1",
            edit("Filling GPT-6 Astra.", #"[{"action":"fillCells","column":"GPT-6 Astra","text":"1"}]"#), .any.action(.fillCells).filled(9).column(5, "1")),
        one("random range in a column", .table, .benchmark, "mets des nombres au hasard entre 50 et 90 dans la colonne Gemini 3.5 Pro",
            edit("Des nombres au hasard pour Gemini.", #"[{"action":"fillCells","column":"Gemini 3.5 Pro","values":"random","min":50,"max":90}]"#),
            .any.action(.fillCells).filled(9).column(4).random(50...90)),
        one("random range everywhere", .table, .benchmark, "remplis les cases vides avec des nombres au hasard entre 50 et 90",
            edit("Je remplis au hasard.", #"[{"action":"fillCells","cells":"empty","values":"random","min":50,"max":90}]"#),
            .any.action(.fillCells).filled(45).random(50...90)),
        one("random digits everywhere", .table, .benchmark, "mets des chiffres aléatoires dans toutes les cases",
            edit("Des chiffres au hasard partout.", #"[{"action":"fillCells","values":"random"}]"#), .any.action(.fillCells).filled(45).random(0...100)),
        one("random small EN", .table, .benchmark, "put random numbers between 0 and 10 in the Opus 5 column",
            edit("Random numbers in Opus 5.", #"[{"action":"fillCells","column":"Opus 5","values":"random","min":0,"max":10}]"#),
            .any.action(.fillCells).filled(9).column(2).random(0...10)),
        one("one decimal EN", .table, .benchmark, "random numbers with one decimal between 50 and 90 in the Opus 5.5 column",
            edit("On it.", #"[{"action":"fillCells","column":"Opus 5.5","values":"random","min":50,"max":90,"decimals":1}]"#),
            .any.action(.fillCells).filled(9).column(1).random(50...90)),
        one("one cell by names", .table, .benchmark, "mets 90% à Opus 5 sur la ligne Agentic coding",
            edit("Je mets 90 %.", #"[{"action":"fillCells","row":"Agentic coding","column":"Opus 5","text":"90%"}]"#),
            .any.action(.fillCells).filled(1).cell(1, 2, "90%").empty(1, 1)),
        one("one cell EN", .table, .benchmark, "write 75 in the Fable 5.1 column for Visual reasoning",
            edit("Writing 75.", #"[{"action":"fillCells","row":"Visual reasoning","column":"Fable 5.1","text":"75"}]"#),
            .any.action(.fillCells).filled(1).cell(8, 3, "75")),
        one("one cell slash", .table, .benchmark, "mets 42 dans la case Fable 5.1 / Graduate-level reasoning",
            edit("Je mets 42.", #"[{"action":"fillCells","row":"Graduate-level reasoning","column":"Fable 5.1","text":"42"}]"#),
            .any.action(.fillCells).filled(1).cell(7, 3, "42")),
        one("a row", .table, .benchmark, "remplis la ligne Knowledge work avec 1",
            edit("Je remplis la ligne.", #"[{"action":"fillCells","row":"Knowledge work","text":"1"}]"#), .any.action(.fillCells).filled(5).row(9, "1")),
        one("a row EN", .table, .benchmark, "fill the Agentic coding row with 100",
            edit("Filling the row.", #"[{"action":"fillCells","row":"Agentic coding","text":"100"}]"#), .any.action(.fillCells).filled(5).row(1, "100")),
        one("last column", .table, .benchmark, "mets 1 dans la dernière colonne",
            edit("Je remplis la dernière colonne.", #"[{"action":"fillCells","column":"-1","text":"1"}]"#), .any.action(.fillCells).filled(9).column(5, "1")),
        one("first row", .table, .benchmark, "mets 1 dans la première ligne",
            edit("Je remplis la première ligne.", #"[{"action":"fillCells","row":"1","text":"1"}]"#), .any.action(.fillCells).filled(5).row(1, "1")),
        one("number the cells", .table, .benchmark, "numérote les cases",
            edit("Je numérote les cases.", #"[{"action":"fillCells","values":"sequence","min":1}]"#), .any.action(.fillCells).filled(45).cell(1, 1, "1").cell(1, 2, "2")),
        one("one to forty-five", .table, .benchmark, "mets des nombres de 1 à 45 dans les cases",
            edit("De 1 à 45.", #"[{"action":"fillCells","values":"sequence","min":1}]"#), .any.action(.fillCells).filled(45).cell(9, 5, "45")),
        one("highlight a column", .table, .benchmark, "surligne la colonne Opus 5.5",
            edit("Je surligne Opus 5.5.", #"[{"action":"highlightCells","column":"Opus 5.5","color":"yellow"}]"#), .any.action(.highlightCells).highlighted(1)),
        one("highlight a row EN", .table, .benchmark, "highlight the Knowledge work row",
            edit("Highlighting it.", #"[{"action":"highlightCells","row":"Knowledge work","color":"yellow"}]"#), .any.action(.highlightCells).highlighted(1)),
        one("highlight in green", .table, .benchmark, "surligne la colonne Gemini 3.5 Pro en vert",
            edit("En vert.", #"[{"action":"highlightCells","column":"Gemini 3.5 Pro","color":"green"}]"#), .any.action(.highlightCells).highlighted(1)),
        one("highlight in blue EN", .table, .benchmark, "highlight the Opus 5 column in blue",
            edit("In blue.", #"[{"action":"highlightCells","column":"Opus 5","color":"blue"}]"#), .any.action(.highlightCells).highlighted(1)),
        one("spoken number name", .table, .benchmark, "mets 1 dans GPT six Astra pour Scaled tool use",
            edit("Je mets 1.", #"[{"action":"fillCells","row":"Scaled tool use","column":"GPT-6 Astra","text":"1"}]"#), .any.action(.fillCells).filled(1).cell(3, 5, "1")),
        one("misheard name", .table, .benchmark, "remplis la colonne Jémini 3.5 Pro avec 2",
            edit("Je remplis Gemini.", #"[{"action":"fillCells","column":"Gemini 3.5 Pro","text":"2"}]"#), .any.action(.fillCells).filled(9).column(4, "2")),
        one("plausible values", .table, .benchmark, "remplis le tableau avec des valeurs réalistes",
            edit("Des valeurs crédibles.", #"[{"action":"fillCells","values":"plausible"}]"#), .any.action(.fillCells).filled(45)),
        one("a list in a column", .table, .benchmark, "mets 80, 75, 70, 65, 60, 55, 50, 45 et 40 dans la colonne Opus 5",
            edit("Je mets ta liste.", #"[{"action":"fillCells","column":"Opus 5","values":"list","text":"80|75|70|65|60|55|50|45|40"}]"#),
            .any.action(.fillCells).filled(9).cell(1, 2, "80").cell(9, 2, "40")),
        one("N/A EN", .table, .benchmark, "fill the empty cells with N/A", edit("N/A everywhere.", #"[{"action":"fillCells","cells":"empty","text":"N/A"}]"#),
            .any.action(.fillCells).filled(45).cell(2, 2, "N/A")),
        one("in red", .table, .benchmark, "remplis tout en rouge avec des 1", edit("Des 1 en rouge.", #"[{"action":"fillCells","text":"1","color":"red"}]"#), every),
        one("in bold EN", .table, .benchmark, "fill the table with ones in bold", edit("Bold ones.", #"[{"action":"fillCells","text":"1","weight":"bold"}]"#),
            every.boldCells()),
        one("all printed", .table, .values, "mets 1 dans toutes les cases", edit("Je mets des 1.", fillAllOnes),
            .any.layers(0).filled(45), after: "Toutes les cases sont déjà remplies."),
        one("clear a printed column", .table, .values, "vide la colonne Opus 5.5",
            edit("Je vide la colonne.", #"[{"action":"clearCells","column":"Opus 5.5"}]"#), .any.action(.clearCells).erasing()),
        one("clear what you wrote", .table, .benchmark, "vide toutes les cases",
            edit("Je vide tout.", #"[{"action":"clearCells","cells":"all"}]"#), .any.noChange().filled(0), after: "Elles sont déjà vides."),
        // A request the recognizer ends with "?" is still a request.
        one("polite, everywhere", .table, .benchmark, "tu peux mettre des 1 partout ?", edit("Oui, je mets des 1.", fillAllOnes), every),
        one("polite, highlight", .table, .benchmark, "Peux-tu surligner la colonne Opus 5 ?",
            edit("Je la surligne.", #"[{"action":"highlightCells","column":"Opus 5","color":"yellow"}]"#), .any.action(.highlightCells).highlighted(1)),
        one("polite, fill EN", .table, .benchmark, "Can you fill every cell with 1?", edit("Sure.", fillAllOnes), every),
        one("polite, clear EN", .table, .values, "could you clear the Opus 5.5 column?",
            edit("Clearing it.", #"[{"action":"clearCells","column":"Opus 5.5"}]"#), .any.action(.clearCells).erasing()),
        one("dashes EN", .table, .benchmark, "put a dash in every cell of the last row",
            edit("Dashes in the last row.", #"[{"action":"fillCells","row":"-1","text":"-"}]"#), .any.action(.fillCells).row(9)),
    ]

    // MARK: Text on the picture (32)

    public static let text: [LiveDialogueCase] = [
        one("title on top", .text, .poster, "ajoute « Été 2026 » en haut",
            edit("J'ajoute le titre en haut.", #"[{"action":"addText","text":"Été 2026","placement":"top"}]"#), .any.action(.addText).text("Été 2026").at("Été 2026", y: 0...0.3)),
        one("bottom in red EN", .text, .poster, "write “Sale” at the bottom in red",
            edit("Adding it.", #"[{"action":"addText","text":"Sale","placement":"bottom","color":"red"}]"#), .any.action(.addText).text("Sale").colour("Sale", "red")),
        one("under the title in its style", .text, .poster, "ajoute « Jusqu'au 31 août » sous le titre dans le même style",
            edit("Je l'ajoute sous le titre.", #"[{"action":"addText","text":"Jusqu'au 31 août","ref":"t1","match":"t1"}]"#),
            .any.action(.addText).text("Jusqu'au 31 août").at("Jusqu'au 31 août", y: 0.1...0.35)),
        one("in the free sky", .text, .poster, "écris « Nouveau » dans le ciel en haut à droite",
            edit("J'écris dans le ciel.", #"[{"action":"addText","text":"Nouveau","ref":"f1"}]"#), .any.action(.addText).text("Nouveau").at("Nouveau", y: 0.2...0.42)),
        one("in the free band EN", .text, .poster, "add “Limited offer” in the empty band at the bottom",
            edit("Adding it at the bottom.", #"[{"action":"addText","text":"Limited offer","ref":"f2"}]"#), .any.action(.addText).text("Limited offer").at("Limited offer", y: 0.9...1)),
        one("replace the subtitle", .text, .poster, "remplace « -50% sur tout » par « -70% sur tout »",
            edit("Je le remplace.", #"[{"action":"editText","ref":"t2","text":"-70% sur tout"}]"#), .any.action(.editText).text("-70% sur tout").gone("-50% sur tout")),
        one("change the price EN", .text, .poster, "change the price to 19,99 €",
            edit("Changing the price.", #"[{"action":"editText","ref":"t3","text":"19,99 €"}]"#), .any.action(.editText).text("19,99 €").gone("29,99 €")),
        one("erase the price", .text, .poster, "efface le prix", edit("J'efface le prix.", #"[{"action":"removeText","ref":"t3"}]"#), .any.action(.removeText).gone("29,99 €")),
        one("remove the subtitle EN", .text, .poster, "remove the subtitle", edit("Removing it.", #"[{"action":"removeText","ref":"t2"}]"#), .any.action(.removeText).gone("-50% sur tout")),
        one("title in red", .text, .poster, "mets le titre en rouge", edit("Je le mets en rouge.", #"[{"action":"editText","ref":"t1","color":"red"}]"#),
            .any.action(.editText).text("SOLDES D'ÉTÉ").colour("SOLDES D'ÉTÉ", "red")),
        one("title bigger EN", .text, .poster, "make the title bigger", edit("Making it bigger.", #"[{"action":"editText","ref":"t1","size":"bigger"}]"#),
            .any.action(.editText).text("SOLDES D'ÉTÉ")),
        one("big in the middle", .text, .poster, "écris « Promo » en gros au centre",
            edit("J'écris Promo au centre.", #"[{"action":"addText","text":"Promo","placement":"center","size":"large"}]"#), .any.action(.addText).text("Promo").at("Promo", y: 0.4...0.6)),
        one("small bottom right", .text, .poster, "ajoute « @picshop » en petit en bas à droite",
            edit("Je l'ajoute en bas à droite.", #"[{"action":"addText","text":"@picshop","placement":"bottomRight","size":"small"}]"#),
            .any.action(.addText).text("@picshop").at("@picshop", y: 0.7...1)),
        one("move the price", .text, .poster, "déplace le prix en haut à gauche",
            edit("Je le déplace.", #"[{"action":"moveText","ref":"t3","placement":"topLeft"}]"#), .any.action(.moveText).text("29,99 €").at("29,99 €", y: 0...0.3)),
        one("move the subtitle EN", .text, .poster, "move the subtitle to the bottom",
            edit("Moving it down.", #"[{"action":"moveText","ref":"t2","placement":"bottom"}]"#), .any.action(.moveText).text("-50% sur tout").at("-50% sur tout", y: 0.7...1)),
        one("erase an area", .text, .poster, "efface la zone en bas à gauche",
            edit("J'efface ce coin.", #"[{"action":"eraseRegion","box":[40,840,300,930]}]"#), .any.action(.eraseRegion).erasing()),
        one("erase the top text EN", .text, .poster, "erase the text in the top band", edit("Erasing the title.", #"[{"action":"removeText","ref":"t1"}]"#),
            .any.action(.removeText).gone("SOLDES D'ÉTÉ")),
        one("next to the price", .text, .poster, "écris « TTC » sous le prix dans le même style",
            edit("J'ajoute TTC.", #"[{"action":"addText","text":"TTC","ref":"t3","match":"t3"}]"#), .any.action(.addText).text("TTC")),
        one("yellow bold on top", .text, .poster, "ajoute « Offre spéciale » en haut en jaune et en gras",
            edit("En jaune et en gras.", #"[{"action":"addText","text":"Offre spéciale","placement":"top","color":"yellow","weight":"bold"}]"#),
            .any.action(.addText).text("Offre spéciale").colour("Offre spéciale", "yellow")),
        one("rewrite the title", .text, .poster, "réécris le titre en « SOLDES D'HIVER »",
            edit("Je le réécris.", #"[{"action":"editText","ref":"t1","text":"SOLDES D'HIVER"}]"#), .any.action(.editText).text("SOLDES D'HIVER").gone("SOLDES D'ÉTÉ")),
        one("subtitle bold", .text, .poster, "mets le sous-titre en gras", edit("En gras.", #"[{"action":"editText","ref":"t2","weight":"bold"}]"#),
            .any.action(.editText).text("-50% sur tout")),
        one("price right aligned", .text, .poster, "aligne le prix à droite", edit("Je l'aligne à droite.", #"[{"action":"editText","ref":"t3","align":"right"}]"#),
            .any.action(.editText).text("29,99 €")),
        one("serif at the bottom", .text, .poster, "écris « Merci » en serif en bas",
            edit("J'écris Merci.", #"[{"action":"addText","text":"Merci","placement":"bottom","font":"serif"}]"#), .any.action(.addText).text("Merci")),
        one("caption under the person EN", .text, .poster, "add a caption “Photo: Léa” under the person",
            edit("Adding the caption.", #"[{"action":"addText","text":"Photo: Léa","ref":"o1"}]"#), .any.action(.addText).text("Photo: Léa").at("Photo: Léa", y: 0.9...1)),
        one("in the price's style", .text, .poster, "ajoute « NEW » dans le ciel, dans le même style que le prix",
            edit("J'ajoute NEW.", #"[{"action":"addText","text":"NEW","ref":"f1","match":"t3"}]"#), .any.action(.addText).text("NEW").colour("NEW", "yellow")),
        one("red top-left corner", .text, .poster, "écris « -30 % » en rouge en haut à gauche",
            edit("Je l'écris.", #"[{"action":"addText","text":"-30 %","placement":"topLeft","color":"red"}]"#), .any.action(.addText).text("-30 %").colour("-30 %", "red")),
        one("change quoted text", .text, .poster, "change « SOLDES D'ÉTÉ » en « GRANDES SOLDES »",
            edit("Je change le titre.", #"[{"action":"editText","ref":"t1","text":"GRANDES SOLDES"}]"#), .any.action(.editText).text("GRANDES SOLDES")),
        one("remove quoted EN", .text, .poster, "remove the text “-50% sur tout”", edit("Removing it.", #"[{"action":"removeText","ref":"t2"}]"#),
            .any.action(.removeText).gone("-50% sur tout")),
        one("small centred bottom", .text, .poster, "écris « Livraison offerte » en bas, en petit",
            edit("Je l'ajoute en bas.", #"[{"action":"addText","text":"Livraison offerte","placement":"bottom","size":"small"}]"#), .any.action(.addText).text("Livraison offerte")),
        one("in a box EN", .text, .poster, "write “Only today” in the top right corner",
            edit("Writing it.", #"[{"action":"addText","text":"Only today","box":[700,220,980,300]}]"#), .any.action(.addText).text("Only today").at("Only today", y: 0.2...0.32)),
        one("polite, write", .text, .poster, "tu peux écrire « Promo » en bas ?",
            edit("Je l'écris en bas.", #"[{"action":"addText","text":"Promo","placement":"bottom"}]"#), .any.action(.addText).text("Promo")),
        one("polite, bigger title EN", .text, .poster, "can you make the title bigger?",
            edit("Making it bigger.", #"[{"action":"editText","ref":"t1","size":"bigger"}]"#), .any.action(.editText).text("SOLDES D'ÉTÉ")),
        one("table title", .text, .benchmark, "change le titre en « Scores 2026 »",
            edit("Je change le titre.", #"[{"action":"editText","ref":"t1","text":"Scores 2026"}]"#), .any.action(.editText).text("Scores 2026").gone("Claude Opus 5.5")),
        one("table source note", .text, .benchmark, "ajoute « Source : tests internes » en haut à droite",
            edit("J'ajoute la source.", #"[{"action":"addText","text":"Source : tests internes","ref":"f1"}]"#), .any.action(.addText).text("Source : tests internes")),
    ]

    // MARK: Follow-ups (25)

    static let fillColumnOne = turn("remplis la colonne Opus 5.5 avec 1",
                                    edit("Je remplis Opus 5.5.", #"[{"action":"fillCells","column":"Opus 5.5","text":"1"}]"#), .any.action(.fillCells).filled(9))
    static let addSummer = turn("ajoute « Été 2026 » en haut", edit("Je l'ajoute.", #"[{"action":"addText","text":"Été 2026","placement":"top"}]"#),
                                .any.action(.addText).text("Été 2026"))

    public static let followUps: [LiveDialogueCase] = [
        many("the others too", .followUp, .benchmark, [fillColumnOne,
            turn("Il faut remplir les autres cases aussi.", edit("Je remplis le reste.", fillAllOnes), .any.action(.fillCells).filled(45).cell(9, 5, "1"))]),
        many("the others too EN", .followUp, .benchmark, [
            turn("fill the Opus 5 column with 0", edit("Filling Opus 5.", #"[{"action":"fillCells","column":"Opus 5","text":"0"}]"#), .any.filled(9)),
            turn("the others too", edit("Filling the rest.", #"[{"action":"fillCells","cells":"empty","text":"0"}]"#), .any.action(.fillCells).filled(45).cell(1, 1, "0"))]),
        one("the stray one, the others too", .followUp, .stray, "Il faut remplir les autres cases aussi.",
            edit("Je remplis les autres avec des 1.", fillAllOnes), .any.action(.fillCells).filled(45).cell(1, 1, "1").cell(6, 3, "1")),
        many("same for another column", .followUp, .benchmark, [
            turn("remplis la colonne Opus 5.5 avec des nombres au hasard entre 50 et 90",
                 edit("Au hasard pour Opus 5.5.", #"[{"action":"fillCells","column":"Opus 5.5","values":"random","min":50,"max":90}]"#), .any.filled(9)),
            turn("pareil pour la colonne Opus 5",
                 edit("Pareil pour Opus 5.", #"[{"action":"fillCells","column":"Opus 5","values":"random","min":50,"max":90}]"#),
                 .any.action(.fillCells).filled(18).column(2).random(50...90))]),
        many("next row", .followUp, .benchmark, [
            turn("mets 1 dans la ligne Agentic coding", edit("Je remplis la ligne.", #"[{"action":"fillCells","row":"Agentic coding","text":"1"}]"#), .any.filled(5)),
            turn("pareil pour la ligne suivante", edit("Et la suivante.", #"[{"action":"fillCells","row":"2","text":"1"}]"#),
                 .any.action(.fillCells).filled(10).row(2, "1"))]),
        many("again for Gemini", .followUp, .benchmark, [
            turn("remplis la colonne Fable 5.1 avec 1", edit("Je remplis Fable 5.1.", #"[{"action":"fillCells","column":"Fable 5.1","text":"1"}]"#), .any.filled(9)),
            turn("encore pour Gemini 3.5 Pro", edit("Et Gemini.", #"[{"action":"fillCells","column":"Gemini 3.5 Pro","text":"1"}]"#), .any.action(.fillCells).filled(18).column(4, "1"))]),
        many("undo a fill", .followUp, .benchmark, [
            turn("mets des 1 partout", edit("Des 1 partout.", fillAllOnes), .any.filled(45)),
            turn("annule", undo("J'annule."), .any.filled(0))]),
        many("the alternative instead", .followUp, .benchmark, [
            turn("mets des 1 partout", edit("Des 1 partout.", fillAllOnes), .any.filled(45)),
            turn("non, plutôt des chiffres au hasard", edit("Des chiffres au hasard.", #"[{"action":"fillCells","cells":"all","values":"random"}]"#),
                 .any.action(.fillCells).filled(45).random(0...100).layers(45))]),
        many("bigger after adding", .followUp, .poster, [addSummer,
            turn("plus gros", edit("Je l'agrandis.", #"[{"action":"editText","ref":"l1","size":"bigger"}]"#), .any.action(.editText).grew("Été 2026"))]),
        many("in red after adding", .followUp, .poster, [addSummer,
            turn("en rouge", edit("En rouge.", #"[{"action":"editText","ref":"l1","color":"red"}]"#), .any.action(.editText).colour("Été 2026", "red"))]),
        many("bigger after replacing", .followUp, .poster, [
            turn("remplace « -50% sur tout » par « -70% sur tout »", edit("Je le remplace.", #"[{"action":"editText","ref":"t2","text":"-70% sur tout"}]"#), .any.text("-70% sur tout")),
            turn("plus gros", edit("Je l'agrandis.", #"[{"action":"editText","ref":"l1","size":"bigger"}]"#), .any.action(.editText).grew("-70% sur tout"))]),
        many("the subtitle too", .followUp, .poster, [
            turn("efface le prix", edit("J'efface le prix.", #"[{"action":"removeText","ref":"t3"}]"#), .any.gone("29,99 €")),
            turn("le sous-titre aussi", edit("Et le sous-titre.", #"[{"action":"removeText","ref":"t2"}]"#), .any.action(.removeText).gone("-50% sur tout").gone("29,99 €"))]),
        many("even bigger", .followUp, .poster, [
            turn("écris « Promo » en bas", edit("J'écris Promo.", #"[{"action":"addText","text":"Promo","placement":"bottom"}]"#), .any.text("Promo")),
            turn("encore plus gros", edit("Encore plus gros.", #"[{"action":"editText","ref":"l1","size":"x1.5"}]"#), .any.action(.editText).grew("Promo"))]),
        many("move it up", .followUp, .poster, [
            turn("écris « Promo » en bas", edit("J'écris Promo.", #"[{"action":"addText","text":"Promo","placement":"bottom"}]"#), .any.text("Promo")),
            turn("déplace-le en haut", edit("Je le monte.", #"[{"action":"moveText","ref":"l1","placement":"top"}]"#), .any.action(.moveText).at("Promo", y: 0...0.3))]),
        many("highlight another", .followUp, .benchmark, [
            turn("surligne la colonne Opus 5.5", edit("Je surligne.", #"[{"action":"highlightCells","column":"Opus 5.5","color":"yellow"}]"#), .any.highlighted(1)),
            turn("pareil pour Opus 5", edit("Et Opus 5.", #"[{"action":"highlightCells","column":"Opus 5","color":"yellow"}]"#), .any.action(.highlightCells).highlighted(2))]),
        many("and a row too", .followUp, .benchmark, [fillColumnOne,
            turn("et la ligne Knowledge work aussi", edit("Et la ligne.", #"[{"action":"fillCells","row":"Knowledge work","text":"1"}]"#),
                 .any.action(.fillCells).filled(13).row(9, "1"))]),
        many("the rest too EN", .followUp, .benchmark, [
            turn("fill the Opus 5.5 column with 1", edit("Filling it.", #"[{"action":"fillCells","column":"Opus 5.5","text":"1"}]"#), .any.filled(9)),
            turn("the rest too", edit("And the rest.", fillAllOnes), .any.action(.fillCells).filled(45))]),
        many("same for GPT EN", .followUp, .benchmark, [
            turn("put random numbers in the Gemini 3.5 Pro column", edit("Random numbers.", #"[{"action":"fillCells","column":"Gemini 3.5 Pro","values":"random"}]"#),
                 .any.filled(9)),
            turn("same for GPT-6 Astra", edit("Same there.", #"[{"action":"fillCells","column":"GPT-6 Astra","values":"random"}]"#),
                 .any.action(.fillCells).filled(18).column(5).random(0...100))]),
        many("smaller EN", .followUp, .poster, [
            turn("add “Sale” at the top", edit("Adding it.", #"[{"action":"addText","text":"Sale","placement":"top"}]"#), .any.text("Sale")),
            turn("make it smaller", edit("Smaller.", #"[{"action":"editText","ref":"l1","size":"smaller"}]"#), .any.action(.editText).shrank("Sale"))]),
        many("same at the bottom", .followUp, .poster, [
            turn("écris « Été » en haut", edit("J'écris Été.", #"[{"action":"addText","text":"Été","placement":"top"}]"#), .any.count("Été", 1)),
            turn("pareil en bas", edit("Et en bas.", #"[{"action":"addText","text":"Été","placement":"bottom"}]"#), .any.action(.addText).count("Été", 2))]),
        many("fill, others, undo", .followUp, .benchmark, [fillColumnOne,
            turn("les autres aussi", edit("Le reste.", fillAllOnes), .any.filled(45)),
            turn("annule", undo("J'annule."), .any.filled(9))]),
        many("the subtitle too in red", .followUp, .poster, [
            turn("mets le titre en rouge", edit("En rouge.", #"[{"action":"editText","ref":"t1","color":"red"}]"#), .any.colour("SOLDES D'ÉTÉ", "red")),
            turn("le sous-titre aussi", edit("Le sous-titre aussi.", #"[{"action":"editText","ref":"t2","color":"red"}]"#), .any.action(.editText).colour("-50% sur tout", "red"))]),
        many("again in the second", .followUp, .benchmark, [
            turn("mets 1 dans la première colonne", edit("Première colonne.", #"[{"action":"fillCells","column":"1","text":"1"}]"#), .any.filled(9)),
            turn("encore dans la deuxième", edit("Et la deuxième.", #"[{"action":"fillCells","column":"2","text":"1"}]"#), .any.action(.fillCells).filled(18).column(2, "1"))]),
        many("in bold after", .followUp, .benchmark, [
            turn("remplis tout avec des 1", edit("Des 1 partout.", fillAllOnes), .any.filled(45)),
            turn("en gras", edit("En gras.", #"[{"action":"fillCells","cells":"all","text":"1","weight":"bold"}]"#), .any.action(.fillCells).filled(45).layers(45).boldCells())]),
        many("bigger keeps random values", .followUp, .benchmark, [
            turn("mets des nombres au hasard partout", edit("Au hasard partout.", #"[{"action":"fillCells","values":"random"}]"#), .any.filled(45)),
            turn("plus gros", edit("Je les agrandis.", #"[{"action":"fillCells","cells":"all","size":"bigger"}]"#),
                 .any.action(.fillCells).filled(45).layers(45).keepingValues())]),
        many("no, at the bottom", .followUp, .poster, [addSummer,
            turn("non, en bas", edit("En bas alors.", #"[{"action":"moveText","ref":"l1","placement":"bottom"}]"#), .any.action(.moveText).at("Été 2026", y: 0.7...1))]),
    ]

    // MARK: References (21)

    public static let references: [LiveDialogueCase] = [
        one("the cell to the right", .reference, .benchmark, "mets 1 dans la case à droite de Opus 5.5 sur la ligne Agentic coding",
            edit("Je mets 1 à droite.", #"[{"action":"fillCells","row":"Agentic coding","column":"Opus 5","text":"1"}]"#), .any.action(.fillCells).filled(1).cell(1, 2, "1")),
        one("last cell of a row", .reference, .benchmark, "mets 1 dans la dernière case de la ligne Agentic coding",
            edit("La dernière case.", #"[{"action":"fillCells","row":"Agentic coding","column":"-1","text":"1"}]"#), .any.action(.fillCells).filled(1).cell(1, 5, "1")),
        one("the column before", .reference, .benchmark, "remplis la colonne juste avant GPT-6 Astra avec 0",
            edit("La colonne d'avant.", #"[{"action":"fillCells","column":"Gemini 3.5 Pro","text":"0"}]"#), .any.action(.fillCells).filled(9).column(4, "0")),
        one("bottom right cell", .reference, .benchmark, "mets 5 dans la case en bas à droite",
            edit("En bas à droite.", #"[{"action":"fillCells","row":"-1","column":"-1","text":"5"}]"#), .any.action(.fillCells).filled(1).cell(9, 5, "5")),
        one("first cell", .reference, .benchmark, "mets 5 dans la première case",
            edit("La première case.", #"[{"action":"fillCells","row":"1","column":"1","text":"5"}]"#), .any.action(.fillCells).filled(1).cell(1, 1, "5")),
        one("the text at the bottom", .reference, .poster, "efface le texte en bas", edit("J'efface le prix.", #"[{"action":"removeText","ref":"t3"}]"#),
            .any.action(.removeText).gone("29,99 €")),
        one("the top text", .reference, .poster, "change le texte du haut en « PROMO »",
            edit("Je change le titre.", #"[{"action":"editText","ref":"t1","text":"PROMO"}]"#), .any.action(.editText).text("PROMO")),
        one("the title in yellow", .reference, .poster, "mets le titre en jaune", edit("En jaune.", #"[{"action":"editText","ref":"t1","color":"yellow"}]"#),
            .any.action(.editText).colour("SOLDES D'ÉTÉ", "yellow")),
        one("under the title", .reference, .poster, "efface le texte sous le titre", edit("J'efface le sous-titre.", #"[{"action":"removeText","ref":"t2"}]"#),
            .any.action(.removeText).gone("-50% sur tout")),
        one("bottom left EN", .reference, .poster, "remove the text at the bottom left", edit("Removing the price.", #"[{"action":"removeText","ref":"t3"}]"#),
            .any.action(.removeText).gone("29,99 €")),
        one("above the person", .reference, .poster, "écris « Top » au-dessus de la personne",
            edit("J'écris Top.", #"[{"action":"addText","text":"Top","box":[300,203,700,238]}]"#), .any.action(.addText).text("Top").at("Top", y: 0.15...0.26)),
        one("the table's title", .reference, .benchmark, "change le titre en « Résultats »",
            edit("Je change le titre.", #"[{"action":"editText","ref":"t1","text":"Résultats"}]"#), .any.action(.editText).text("Résultats")),
        one("column three", .reference, .benchmark, "mets 1 dans la colonne 3", edit("La colonne 3.", #"[{"action":"fillCells","column":"3","text":"1"}]"#),
            .any.action(.fillCells).filled(9).column(3, "1")),
        one("row two", .reference, .benchmark, "remplis la ligne 2 avec 0", edit("La ligne 2.", #"[{"action":"fillCells","row":"2","text":"0"}]"#),
            .any.action(.fillCells).filled(5).row(2, "0")),
        one("the model's own notation", .reference, .benchmark, "mets 1 dans la case r6c3",
            edit("Je mets 1.", #"[{"action":"fillCells","row":"6","column":"3","text":"1"}]"#), .any.action(.fillCells).filled(1).cell(6, 3, "1")),
        one("the price bigger", .reference, .poster, "rends le prix plus gros", edit("Je l'agrandis.", #"[{"action":"editText","ref":"t3","size":"bigger"}]"#),
            .any.action(.editText).text("29,99 €")),
        one("instead of the subtitle", .reference, .poster, "mets « -70% » à la place du sous-titre",
            edit("Je le remplace.", #"[{"action":"editText","ref":"t2","text":"-70%"}]"#), .any.action(.editText).text("-70%").gone("-50% sur tout")),
        one("Gemini for Visual", .reference, .benchmark, "mets 1 dans la case de Gemini pour Visual reasoning",
            edit("Je mets 1.", #"[{"action":"fillCells","row":"Visual reasoning","column":"Gemini 3.5 Pro","text":"1"}]"#), .any.action(.fillCells).filled(1).cell(8, 4, "1")),
        one("second to last column", .reference, .benchmark, "mets 1 dans l'avant-dernière colonne",
            edit("L'avant-dernière.", #"[{"action":"fillCells","column":"4","text":"1"}]"#), .any.action(.fillCells).filled(9).column(4, "1")),
        one("the top text erased", .reference, .poster, "efface le texte en haut", edit("J'efface le titre.", #"[{"action":"removeText","ref":"t1"}]"#),
            .any.action(.removeText).gone("SOLDES D'ÉTÉ")),
        many("empty it", .reference, .benchmark, [
            turn("remplis la colonne Opus 5 avec 1", edit("Je remplis Opus 5.", #"[{"action":"fillCells","column":"Opus 5","text":"1"}]"#), .any.filled(9)),
            turn("vide-la", edit("Je la vide.", #"[{"action":"clearCells","column":"Opus 5"}]"#), .any.action(.clearCells).filled(0))]),
    ]

    // MARK: Compound (21)

    public static let compound: [LiveDialogueCase] = [
        one("erase and rewrite the price", .compound, .poster, "efface le prix et écris « 19,99 € » à la place",
            edit("J'efface et je réécris.", #"[{"action":"removeText","ref":"t3"},{"action":"addText","text":"19,99 €","box":[60,860,280,910],"match":"nearby"}]"#),
            .any.action(.removeText, .addText).text("19,99 €").gone("29,99 €")),
        one("mono and a date", .compound, .poster, "passe la photo en noir et blanc et ajoute « 1995 » en bas",
            edit("Noir et blanc, puis la date.", #"[{"action":"applyLook","look":"mono","amount":100},{"action":"addText","text":"1995","placement":"bottom"}]"#),
            .any.action(.applyLook, .addText).text("1995")),
        one("fill and highlight", .compound, .benchmark, "remplis la colonne Opus 5.5 avec 1 et surligne-la",
            edit("Je remplis et je surligne.", #"[{"action":"fillCells","column":"Opus 5.5","text":"1"},{"action":"highlightCells","column":"Opus 5.5","color":"yellow"}]"#),
            .any.action(.fillCells, .highlightCells).column(1, "1").highlighted(1)),
        many("clear one, fill another", .compound, .benchmark, [
            turn("remplis tout avec des 1", edit("Des 1 partout.", fillAllOnes), .any.filled(45)),
            turn("vide la colonne Opus 5 et mets des 0 dans la colonne Fable 5.1",
                 edit("Je vide Opus 5 et je mets des 0.", #"[{"action":"clearCells","column":"Opus 5"},{"action":"fillCells","column":"Fable 5.1","cells":"all","text":"0"}]"#),
                 .any.action(.clearCells, .fillCells).empty(1, 2).cell(1, 3, "0").filled(36))]),
        one("warmer and brighter", .compound, .poster, "rends-la plus chaude et plus lumineuse",
            edit("Plus chaude et plus lumineuse.", #"[{"action":"adjust","parameter":"temperature","amount":20},{"action":"adjust","parameter":"brightness","amount":15}]"#),
            .any.action(.adjust)),
        one("remove and write", .compound, .poster, "enlève la personne et mets « Vide » au centre",
            edit("J'enlève la personne et j'écris.", #"[{"action":"removeObject","target":"person"},{"action":"addText","text":"Vide","placement":"center"}]"#),
            .any.action(.removeObject, .addText).text("Vide")),
        one("two colours", .compound, .poster, "mets le titre en rouge et le prix en jaune",
            edit("Rouge et jaune.", #"[{"action":"editText","ref":"t1","color":"red"},{"action":"editText","ref":"t3","color":"yellow"}]"#),
            .any.action(.editText).colour("SOLDES D'ÉTÉ", "red").text("29,99 €")),
        one("first and last columns", .compound, .benchmark, "remplis la première colonne avec 1 et la dernière avec 0",
            edit("Première et dernière.", #"[{"action":"fillCells","column":"1","text":"1"},{"action":"fillCells","column":"-1","text":"0"}]"#),
            .any.action(.fillCells).cell(1, 1, "1").cell(1, 5, "0").filled(18)),
        one("remove and bigger EN", .compound, .poster, "remove the price and make the title bigger",
            edit("Removing the price, bigger title.", #"[{"action":"removeText","ref":"t3"},{"action":"editText","ref":"t1","size":"bigger"}]"#),
            .any.action(.removeText, .editText).gone("29,99 €").text("SOLDES D'ÉTÉ")),
        one("blur and caption", .compound, .poster, "floute l'arrière-plan et écris « Moi » en bas",
            edit("Je floute le fond et j'écris.", #"[{"action":"blurBackground","amount":60},{"action":"addText","text":"Moi","placement":"bottom"}]"#),
            .any.action(.blurBackground, .addText).text("Moi")),
        one("title and fill", .compound, .benchmark, "change le titre en « Scores » et remplis tout avec des 1",
            edit("Nouveau titre et des 1.", #"[{"action":"editText","ref":"t1","text":"Scores"},{"action":"fillCells","text":"1"}]"#),
            .any.action(.editText, .fillCells).text("Scores").filled(45)),
        one("square and title", .compound, .poster, "recadre en carré et ajoute « Promo » en haut",
            edit("Carré, puis le titre.", #"[{"action":"setAspect","aspect":"square"},{"action":"addText","text":"Promo","placement":"top"}]"#),
            .any.action(.setAspect, .addText).text("Promo")),
        one("random then highlight", .compound, .benchmark, "mets des nombres au hasard entre 0 et 100 partout puis surligne la colonne Opus 5.5",
            edit("Au hasard, puis je surligne.", #"[{"action":"fillCells","values":"random","min":0,"max":100},{"action":"highlightCells","column":"Opus 5.5","color":"yellow"}]"#),
            .any.action(.fillCells, .highlightCells).filled(45).random(0...100).highlighted(1)),
        one("erase and move", .compound, .poster, "efface le sous-titre et déplace le prix en haut",
            edit("J'efface et je déplace.", #"[{"action":"removeText","ref":"t2"},{"action":"moveText","ref":"t3","placement":"top"}]"#),
            .any.action(.removeText, .moveText).gone("-50% sur tout").at("29,99 €", y: 0...0.3)),
        one("two texts EN", .compound, .poster, "add “Sale” at the top in red and “-50%” at the bottom in yellow",
            edit("Both added.", #"[{"action":"addText","text":"Sale","placement":"top","color":"red"},{"action":"addText","text":"-50%","placement":"bottom","color":"yellow"}]"#),
            .any.action(.addText).colour("Sale", "red").colour("-50%", "yellow")),
        one("two rows", .compound, .benchmark, "remplis la ligne Agentic coding avec 1 et la ligne Knowledge work avec 0",
            edit("Les deux lignes.", #"[{"action":"fillCells","row":"Agentic coding","text":"1"},{"action":"fillCells","row":"Knowledge work","text":"0"}]"#),
            .any.action(.fillCells).row(1, "1").row(9, "0").filled(10)),
        one("contrast and bold title", .compound, .poster, "augmente le contraste et mets le titre en gras",
            edit("Plus de contraste, titre en gras.", #"[{"action":"adjust","parameter":"contrast","amount":20},{"action":"editText","ref":"t1","weight":"bold"}]"#),
            .any.action(.adjust, .editText)),
        one("one column then the rest", .compound, .benchmark, "remplis la colonne Opus 5.5 avec 1, puis les autres avec 0",
            edit("Des 1, puis des 0.", #"[{"action":"fillCells","column":"Opus 5.5","text":"1"},{"action":"fillCells","cells":"empty","text":"0"}]"#),
            .any.action(.fillCells).cell(1, 1, "1").cell(1, 2, "0").filled(45)),
        one("three removals", .compound, .poster, "enlève le prix, le sous-titre et le titre",
            edit("J'enlève les trois.", #"[{"action":"removeText","ref":"t3"},{"action":"removeText","ref":"t2"},{"action":"removeText","ref":"t1"}]"#),
            .any.action(.removeText).gone("29,99 €").gone("-50% sur tout").gone("SOLDES D'ÉTÉ")),
        one("A on top, B at the bottom", .compound, .poster, "écris « A » en haut et « B » en bas",
            edit("A en haut, B en bas.", #"[{"action":"addText","text":"A","placement":"top"},{"action":"addText","text":"B","placement":"bottom"}]"#),
            .any.action(.addText).at("A", y: 0...0.3).at("B", y: 0.7...1)),
        one("fill and highlight EN", .compound, .benchmark, "fill the Opus 5 column with 1 and highlight it",
            edit("Filling and highlighting.", #"[{"action":"fillCells","column":"Opus 5","text":"1"},{"action":"highlightCells","column":"Opus 5","color":"yellow"}]"#),
            .any.action(.fillCells, .highlightCells).column(2, "1").highlighted(1)),
    ]

    // MARK: Questions (16): words only, nothing changes

    public static let questions: [LiveDialogueCase] = [
        one("value of a cell", .question, .values, "que vaut Opus 5 en Agentic coding ?", "C'est 77,2 %.", .any.noChange().said("77,2")),
        one("best of a column", .question, .values, "quelle est la meilleure valeur de la colonne Opus 5.5 ?", "87 %, en Graduate-level reasoning.", .any.noChange().said("87")),
        one("how many empty", .question, .benchmark, "combien de cases sont vides ?", "Les 45 cases sont vides.", .any.noChange().said("45")),
        one("what's at the bottom", .question, .poster, "c'est écrit quoi en bas ?", "Le prix : 29,99 €.", .any.noChange().said("29,99")),
        one("what the title says EN", .question, .poster, "what does the title say?", "It says SOLDES D'ÉTÉ.", .any.noChange().said("soldes")),
        one("opinion on a column", .question, .benchmark, "que penses-tu de la colonne Opus 5 ?", "Elle est encore vide ; je peux la remplir si tu veux.",
            .any.noChange()),
        one("best model EN", .question, .values, "which model is best at Knowledge work?", "Opus 5.5, with 79.4%.", .any.noChange().said("79.4")),
        one("how many texts", .question, .poster, "combien de textes il y a sur l'image ?", "Trois : le titre, le sous-titre et le prix.", .any.noChange().said("trois")),
        one("highest in a row", .question, .values, "quelle colonne a le plus haut score en Agentic coding ?", "Opus 5.5, avec 80,9 %.", .any.noChange().said("80,9")),
        one("why not behind", .question, .benchmark, "pourquoi tu ne peux pas écrire derrière ?", "Il n'y a personne sur une capture de tableau.", .any.noChange()),
        one("is the title readable", .question, .poster, "est-ce que le titre est lisible ?", "Oui, blanc et gras sur le ciel, il se lit bien.", .any.noChange()),
        one("a value EN", .question, .values, "what's the value for GPT-6 Astra in Visual reasoning?", "76.1%.", .any.noChange().said("76.1")),
        one("the last column", .question, .benchmark, "c'est quoi la dernière colonne ?", "GPT-6 Astra.", .any.noChange().said("astra")),
        one("see a person", .question, .poster, "tu vois une personne ?", "Oui, au centre de la photo.", .any.noChange().said("oui")),
        one("Fable on novel problems", .question, .values, "combien a Fable 5.1 en Novel problem solving ?", "61,2 %.", .any.noChange().said("61,2")),
        one("the rows", .question, .benchmark, "quelles sont les lignes du tableau ?", "Agentic coding, Agentic terminal coding… jusqu'à Knowledge work.",
            .any.noChange().said("agentic")),
    ]

    // MARK: Act-then-verify (11): the render does not read; one repair at most, then an honest line

    static let fillEveryOne = #"[{"action":"fillCells","cells":"all","text":"1"}]"#

    public static let verify: [LiveDialogueCase] = [
        checked("a fill that does not read", .benchmark, failing: ["r2c1"], "remplis toutes les cases avec des 1",
                edit("Je remplis tout.", fillAllOnes), repair: edit("Je réécris les cases.", fillEveryOne),
                .any.action(.fillCells).said("en partie").honest()),
        checked("a fill that does not read EN", .benchmark, failing: ["r5c3"], "fill every cell with 1",
                edit("Filling every cell.", fillAllOnes), repair: edit("Writing them again.", fillEveryOne),
                .any.action(.fillCells).said("partly").honest()),
        checked("one cell that does not read", .benchmark, failing: ["r1c2"], "mets 90% à Opus 5 sur la ligne Agentic coding",
                edit("Je mets 90 %.", #"[{"action":"fillCells","row":"Agentic coding","column":"Opus 5","text":"90%"}]"#),
                repair: edit("Je la réécris.", #"[{"action":"fillCells","row":"1","column":"2","cells":"all","text":"90%"}]"#),
                .any.action(.fillCells).said("en partie").honest()),
        checked("the bottom right cell EN", .benchmark, failing: ["r9c5"], "put 5 in the bottom right cell",
                edit("Putting 5 there.", #"[{"action":"fillCells","row":"-1","column":"-1","text":"5"}]"#),
                repair: edit("Writing it again.", #"[{"action":"fillCells","row":"-1","column":"-1","cells":"all","text":"5"}]"#),
                .any.action(.fillCells).said("partly").honest()),
        checked("the stray one does not read", .stray, failing: ["r6c3"], "Il faut remplir les autres cases aussi.",
                edit("Je remplis les autres.", fillAllOnes), repair: edit("Je réécris la case.", #"[{"action":"fillCells","row":"6","column":"3","cells":"all","text":"1"}]"#),
                .any.action(.fillCells).said("en partie").honest()),
        checked("a cleared cell still shows", .values, failing: ["r3c1"], "vide la colonne Opus 5.5",
                edit("Je vide la colonne.", #"[{"action":"clearCells","column":"Opus 5.5"}]"#),
                repair: edit("J'efface ce qui reste.", #"[{"action":"clearCells","row":"3","column":"1"}]"#),
                .any.action(.clearCells).erasing().said("encore du texte").honest()),
        checked("text in the sky too small", .poster, failing: ["text"], "écris « Merci » dans le ciel",
                edit("Je l'écris dans le ciel.", #"[{"action":"addText","text":"Merci","ref":"f1"}]"#),
                repair: edit("Je l'agrandis.", #"[{"action":"editText","ref":"l1","size":"large"}]"#), closing: "C'est plus lisible comme ça.",
                .any.text("Merci").honest()),
        checked("text on top too small", .poster, failing: ["text"], "ajoute « Été 2026 » en haut",
                edit("Je l'ajoute en haut.", #"[{"action":"addText","text":"Été 2026","placement":"top"}]"#),
                repair: edit("Je le mets dans le ciel.", #"[{"action":"moveText","ref":"l1","box":[700,230,980,390]}]"#), closing: "Voilà, plus lisible.",
                .any.text("Été 2026").honest()),
        checked("red sale unreadable EN", .poster, failing: ["text"], "write “Sale” at the bottom in red",
                edit("Adding it.", #"[{"action":"addText","text":"Sale","placement":"bottom","color":"red"}]"#),
                repair: edit("Making it larger.", #"[{"action":"editText","ref":"l1","size":"large"}]"#), closing: "That reads better.",
                .any.text("Sale").honest()),
        checked("a price that still shows", .poster, failing: ["t3"], "efface le prix",
                edit("J'efface le prix.", #"[{"action":"removeText","ref":"t3"}]"#),
                repair: edit("J'efface ce qui reste.", #"[{"action":"eraseRegion","box":[50,850,290,920]}]"#), closing: "C'est propre maintenant.",
                .any.erasing().honest()),
        checked("a rewrite that does not read", .poster, failing: ["t2"], "remplace « -50% sur tout » par « -70% sur tout »",
                edit("Je le remplace.", #"[{"action":"editText","ref":"t2","text":"-70% sur tout"}]"#),
                repair: edit("Je l'agrandis.", #"[{"action":"editText","ref":"l1","size":"large"}]"#), closing: "C'est plus net comme ça.",
                .any.text("-70% sur tout").honest()),
    ]

    // MARK: Recovery (11): a refusal or a failure, then a way out

    public static let recovery: [LiveDialogueCase] = [
        one("behind a person on a table", .recovery, .benchmark, "écris 1 derrière la personne",
            edit("Je le glisse derrière.", #"[{"action":"textBehind","text":"1"}]"#), .any.noChange().said("tableau"),
            after: "Il n'y a personne sur une capture de tableau. Je remplis les cases à la place ?"),
        one("follows the hint", .recovery, .stray, "Il faut remplir les autres cases aussi.",
            edit("Je le mets derrière.", #"[{"action":"textBehind","text":"1"}]"#), .any.action(.fillCells).filled(45),
            after: edit("Je remplis plutôt les cases.", fillAllOnes)),
        one("unknown column", .recovery, .benchmark, "remplis la colonne GPT 7 avec 1",
            edit("Je remplis GPT 7.", #"[{"action":"fillCells","column":"GPT 7","text":"1"}]"#), .any.noChange().said("GPT-6 Astra"),
            after: "Je ne trouve pas GPT 7 : il y a Opus 5.5, Opus 5, Fable 5.1, Gemini 3.5 Pro et GPT-6 Astra."),
        one("ambiguous column", .recovery, .benchmark, "remplis la colonne Opus avec 1",
            edit("Je remplis Opus.", #"[{"action":"fillCells","column":"Opus","text":"1"}]"#), .any.noChange().asking(),
            after: "Opus 5.5 ou Opus 5 ?"),
        one("unknown id", .recovery, .poster, "efface le texte t9", edit("J'efface ce texte.", #"[{"action":"removeText","ref":"t9"}]"#), .any.noChange(),
            after: "Je ne vois pas ce texte : lequel veux-tu effacer ?"),
        one("nothing to fill", .recovery, .values, "remplis les cases vides avec 0", edit("Je remplis les vides.", #"[{"action":"fillCells","cells":"empty","text":"0"}]"#),
            .any.layers(0), after: "Il n'y a aucune case vide : tout est déjà rempli."),
        one("no background on a table", .recovery, .benchmark, "enlève le fond", edit("J'enlève le fond.", #"[{"action":"removeBackground"}]"#),
            .any.noChange(), after: "Sur une capture de tableau, il n'y a pas de fond à détacher."),
        one("no blur on a table", .recovery, .benchmark, "floute l'arrière-plan", edit("Je floute le fond.", #"[{"action":"blurBackground","amount":60}]"#),
            .any.noChange(), after: "Il n'y a pas d'arrière-plan à flouter sur un tableau."),
        one("unknown free area", .recovery, .poster, "écris « X » dans la zone f7",
            edit("J'écris X.", #"[{"action":"addText","text":"X","ref":"f7"}]"#), .any.noChange().asking(), after: "Je ne vois pas cette zone : où veux-tu l'écrire ?"),
        one("bounds the wrong way", .recovery, .benchmark, "remplis les cases avec des nombres entre 90 et 50",
            edit("Au hasard.", #"[{"action":"fillCells","values":"random","min":90,"max":50}]"#), .any.action(.fillCells).filled(45).random(50...90),
            after: edit("Entre 50 et 90.", #"[{"action":"fillCells","values":"random","min":50,"max":90}]"#)),
        one("subject on the report EN", .recovery, .benchmark, "put the title behind the subject",
            edit("Putting it behind.", #"[{"action":"textBehind","text":"Title"}]"#), .any.noChange().said("table"),
            after: "This is a table screenshot, there is no subject. Shall I fill the cells instead?"),
    ]
}
