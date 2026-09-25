import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// A5: the table grammar on the whole utterance, FR and EN — scopes, values, alternatives, style
/// words, follow-ups and relative references — and the regressions it must not cause.
final class TableGrammarTests: XCTestCase {
    let engine = RuleBasedIntentEngine()
    typealias Ref = TableEditSpec.Ref

    private func context(table: TableGrid? = TableFixtures.benchmark(), last: TableEditSpec? = nil, lastIntent: EditIntent? = nil,
                         language: String? = nil) -> IntentContext {
        IntentContext(mode: .photo, preferredLanguage: language, table: table, lastTableEdit: last, lastIntent: lastIntent)
    }

    struct Case {
        var phrase: String
        var action: IntentAction = .fillCells
        var rows: [Ref] = []
        var columns: [Ref] = []
        var onlyEmpty = true
        var value: CellValue?
        var alternative: CellValue?
        var last: TableEditSpec?
        var table = true
    }

    private func check(_ item: Case, file: StaticString = #filePath, line: UInt = #line) {
        let lastIntent = item.last.map { EditIntent(action: .fillCells, table: $0) }
        let plan = engine.parse(item.phrase, context: context(table: item.table ? TableFixtures.benchmark() : nil, last: item.last, lastIntent: lastIntent))
        guard let intent = plan.intents.first, plan.intents.count == 1 else {
            return XCTFail("\(item.phrase): \(plan.intents.map(\.action))", file: file, line: line)
        }
        XCTAssertEqual(intent.action, item.action, item.phrase, file: file, line: line)
        XCTAssertEqual(intent.table?.rows, item.rows, "\(item.phrase) rows", file: file, line: line)
        XCTAssertEqual(intent.table?.columns, item.columns, "\(item.phrase) columns", file: file, line: line)
        if item.action == .fillCells {
            XCTAssertEqual(intent.table?.onlyEmpty, item.onlyEmpty, "\(item.phrase) onlyEmpty", file: file, line: line)
            XCTAssertEqual(intent.table?.value, item.value, "\(item.phrase) value", file: file, line: line)
            XCTAssertEqual(intent.table?.alternative, item.alternative, "\(item.phrase) alternative", file: file, line: line)
            XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, "\(item.phrase): the fast lane takes it", file: file, line: line)
            XCTAssertNil(plan.clarification, item.phrase, file: file, line: line)
        } else {
            XCTAssertGreaterThanOrEqual(plan.confidence, 0.9, item.phrase, file: file, line: line)
        }
    }

    // MARK: The report

    func testTheUsersSentence() {
        let plan = engine.parse("Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires", context: context())
        XCTAssertEqual(plan.intents.count, 1)
        let intent = plan.intents[0]
        XCTAssertEqual(intent.action, .fillCells)
        XCTAssertEqual(intent.table?.value, .constant("1"))
        XCTAssertEqual(intent.table?.alternative, .random(min: nil, max: nil, decimals: nil))
        XCTAssertEqual(intent.table?.onlyEmpty, true)
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.9)
        XCTAssertEqual(plan.reply, "Je remplis les cases avec 1.")
        // With no table detected yet, the words alone still say it.
        XCTAssertEqual(engine.parse("Remplis chaque case du tableau avec le chiffre 1 ou des chiffres aléatoires", context: context(table: nil)).intents.first?.action, .fillCells)
    }

    func testTheFollowUpOfTheReport() {
        // The stray "1" of the old build is the value; nothing else was said.
        let stray = TableFixtures.benchmark().overlaying(TableFixtures.strayOne(in: TableFixtures.document()).layers)
        let plan = engine.parse("Il faut remplir les autres cases aussi.", context: IntentContext(mode: .photo, table: stray))
        XCTAssertEqual(plan.intents.first?.action, .fillCells)
        XCTAssertEqual(plan.intents.first?.table?.value, .constant("1"))
        XCTAssertEqual(plan.intents.first?.table?.onlyEmpty, true)
        XCTAssertGreaterThanOrEqual(plan.confidence, 0.9)
        // After a random fill, the same words fill with random numbers.
        let random = TableEditSpec(value: .random(min: nil, max: nil, decimals: nil))
        XCTAssertEqual(engine.parse("Il faut remplir les autres cases aussi.", context: context(table: stray, last: random)).intents.first?.table?.value, random.value)
        // Nothing to go on: ask.
        let asked = engine.parse("remplis les cases vides", context: context())
        XCTAssertEqual(asked.clarification, "Avec quoi ? Des 1, ou des nombres au hasard ?")
        XCTAssertEqual(asked.intents.first?.action, .fillCells)
    }

    // MARK: Corpus

    func testFrenchFills() {
        let cases: [Case] = [
            Case(phrase: "écris 1 dans chaque case du tableau", value: .constant("1")),
            Case(phrase: "mets des chiffres aléatoires dans toutes les cases", value: .random(min: nil, max: nil, decimals: nil)),
            Case(phrase: "remplis les cases vides avec des nombres au hasard entre 50 et 90", value: .random(min: 50, max: 90, decimals: nil)),
            Case(phrase: "mets 90% à Opus 5 sur la ligne Agentic coding", rows: [.name("Agentic coding")], columns: [.name("Opus 5")], value: .constant("90%")),
            Case(phrase: "remplis le tableau avec des 0", value: .constant("0")),
            Case(phrase: "mets 1 dans toutes les cases", value: .constant("1")),
            Case(phrase: "remplis la colonne Opus 5.5 avec 1", columns: [.name("Opus 5.5")], value: .constant("1")),
            Case(phrase: "remplis la colonne GPT six Astra avec des 1", columns: [.name("GPT-6 Astra")], value: .constant("1")),
            Case(phrase: "complète la dernière colonne avec 0", columns: [.index(-1)], value: .constant("0")),
            Case(phrase: "mets 12,5 dans la case Fable 5.1 / Visual reasoning", rows: [.name("Visual reasoning")], columns: [.name("Fable 5.1")], value: .constant("12,5")),
            Case(phrase: "remplis la ligne Knowledge work avec des tirets", rows: [.name("Knowledge work")], value: .constant("—")),
            Case(phrase: "remplis la troisième colonne avec des nombres aléatoires avec une décimale", columns: [.index(3)], value: .random(min: nil, max: nil, decimals: 1)),
            Case(phrase: "mets des pourcentages au hasard de 0 à 100 dans la colonne Gemini 3.5 Pro", columns: [.name("Gemini 3.5 Pro")], value: .random(min: 0, max: 100, decimals: nil)),
            Case(phrase: "numérote les cases de 1 à 45", value: .sequence(start: 1, step: 1)),
            Case(phrase: "remplis la première ligne avec des valeurs réalistes", rows: [.index(1)], value: .plausible),
            Case(phrase: "mets 80, 75, 70, 65 et 60 sur la ligne Agentic coding", rows: [.name("Agentic coding")], value: .list(["80", "75", "70", "65", "60"])),
            Case(phrase: "écris N/A dans la colonne GPT-6 Astra", columns: [.name("GPT-6 Astra")], value: .constant("N/A")),
            Case(phrase: "il faut remplir les cases vides avec 0", value: .constant("0")),
            Case(phrase: "tu peux remplir le tableau avec des 1 ?", value: .constant("1")),
            Case(phrase: "mets quatre-vingt-dix pour cent dans la case Opus 5.5 / Scaled tool use", rows: [.name("Scaled tool use")], columns: [.name("Opus 5.5")], value: .constant("90%")),
            Case(phrase: "remplis sous Gemini 3.5 Pro avec 5", columns: [.name("Gemini 3.5 Pro")], value: .constant("5")),
            Case(phrase: "mets 0 pour GPT-6 Astra", columns: [.name("GPT-6 Astra")], value: .constant("0")),
            Case(phrase: "mets des chiffres de 0 à 9 au hasard dans le tableau", value: .random(min: 0, max: 9, decimals: nil)),
            Case(phrase: "remplis tout le tableau avec des nombres entiers aléatoires entre 1 et 10", value: .random(min: 1, max: 10, decimals: 0)),
            Case(phrase: "Remplis la colonne Opus 5 avec des 1 ou des nombres au hasard", columns: [.name("Opus 5")], value: .constant("1"), alternative: .random(min: nil, max: nil, decimals: nil)),
            Case(phrase: "mets 3 dans la cellule Opus 5 Novel problem solving", rows: [.name("Novel problem solving")], columns: [.name("Opus 5")], value: .constant("3")),
            Case(phrase: "saisis 7 dans la colonne 2", columns: [.index(2)], value: .constant("7")),
            Case(phrase: "remplis la grille avec des zéros", value: .constant("0")),
            Case(phrase: "mets « oui » dans la colonne Fable 5.1", columns: [.name("Fable 5.1")], value: .constant("oui")),
            Case(phrase: "remplis la ligne 4 avec 50", rows: [.index(4)], value: .constant("50")),
        ]
        cases.forEach { check($0) }
    }

    func testEnglishFills() {
        let cases: [Case] = [
            Case(phrase: "fill every cell of the table with 1", value: .constant("1")),
            Case(phrase: "put random numbers in the empty cells", value: .random(min: nil, max: nil, decimals: nil)),
            Case(phrase: "fill the Opus 5 column with zeros", columns: [.name("Opus 5")], value: .constant("0")),
            Case(phrase: "write 42 in the last row", rows: [.index(-1)], value: .constant("42")),
            Case(phrase: "fill column 3 with random numbers between 50 and 90", columns: [.index(3)], value: .random(min: 50, max: 90, decimals: nil)),
            Case(phrase: "put 87.5 in Fable 5.1 for Visual reasoning", rows: [.name("Visual reasoning")], columns: [.name("Fable 5.1")], value: .constant("87.5")),
            Case(phrase: "number the cells from 1 to 45", value: .sequence(start: 1, step: 1)),
            Case(phrase: "fill the table with random values with one decimal", value: .random(min: nil, max: nil, decimals: 1)),
            Case(phrase: "put dashes in the Opus 5 column", columns: [.name("Opus 5")], value: .constant("—")),
            Case(phrase: "fill the empty cells with plausible values", value: .plausible),
            Case(phrase: "fill the table with 1 or random numbers", value: .constant("1"), alternative: .random(min: nil, max: nil, decimals: nil)),
            Case(phrase: "set every cell in the Gemini 3.5 Pro column to 0", columns: [.name("Gemini 3.5 Pro")], value: .constant("0")),
            Case(phrase: "enter 5 in the second column", columns: [.index(2)], value: .constant("5")),
            Case(phrase: "populate the grid with random digits", value: .random(min: 0, max: 9, decimals: nil)),
            Case(phrase: "write N/A in the GPT-6 Astra column", columns: [.name("GPT-6 Astra")], value: .constant("N/A")),
        ]
        cases.forEach { check($0) }
    }

    func testFollowUpsAndReferences() {
        let ones = TableEditSpec(value: .constant("1"))
        let random = TableEditSpec(value: .random(min: nil, max: nil, decimals: nil))
        let oneCell = TableEditSpec(rows: [.name("Agentic coding")], columns: [.name("Opus 5.5")], value: .constant("90%"))
        let column = TableEditSpec(columns: [.name("Opus 5")], value: .constant("1"))
        let cases: [Case] = [
            Case(phrase: "Il faut remplir les autres cases aussi.", value: .constant("1"), last: ones),
            Case(phrase: "les autres aussi", value: .random(min: nil, max: nil, decimals: nil), last: random),
            Case(phrase: "pareil pour la colonne Gemini", columns: [.name("Gemini 3.5 Pro")], value: .constant("1"), last: ones),
            Case(phrase: "remplis le reste avec des 0", value: .constant("0"), last: ones),
            Case(phrase: "mets la même chose dans la case à droite", rows: [.index(1)], columns: [.index(2)], value: .constant("90%"), last: oneCell),
            Case(phrase: "et la case en dessous", rows: [.index(2)], columns: [.index(1)], value: .constant("90%"), last: oneCell),
            Case(phrase: "pareil pour la colonne suivante", columns: [.index(3)], value: .constant("1"), last: column),
            Case(phrase: "remplace les 1 par des chiffres aléatoires", onlyEmpty: false, value: .random(min: nil, max: nil, decimals: nil), last: ones),
            Case(phrase: "mets des chiffres aléatoires à la place", onlyEmpty: false, value: .random(min: nil, max: nil, decimals: nil), last: ones),
            Case(phrase: "encore", onlyEmpty: false, value: .random(min: nil, max: nil, decimals: nil), last: random),
            Case(phrase: "the others too", value: .constant("1"), last: ones),
            Case(phrase: "fill the rest with ones", value: .constant("1"), last: ones),
            Case(phrase: "same for the Gemini column", columns: [.name("Gemini 3.5 Pro")], value: .constant("1"), last: ones),
            Case(phrase: "and the cell to the right", rows: [.index(1)], columns: [.index(2)], value: .constant("90%"), last: oneCell),
        ]
        cases.forEach { check($0) }
    }

    func testClearAndHighlight() {
        let cases: [Case] = [
            Case(phrase: "vide la colonne GPT-6 Astra", action: .clearCells, columns: [.name("GPT-6 Astra")]),
            Case(phrase: "efface la colonne Opus 5", action: .clearCells, columns: [.name("Opus 5")]),
            Case(phrase: "efface le contenu de la ligne Visual reasoning", action: .clearCells, rows: [.name("Visual reasoning")]),
            Case(phrase: "vide le tableau", action: .clearCells),
            Case(phrase: "enlève les chiffres de la dernière colonne", action: .clearCells, columns: [.index(-1)]),
            Case(phrase: "clear the GPT-6 Astra column", action: .clearCells, columns: [.name("GPT-6 Astra")]),
            Case(phrase: "empty the first row", action: .clearCells, rows: [.index(1)]),
            Case(phrase: "surligne la colonne Opus 5.5", action: .highlightCells, columns: [.name("Opus 5.5")]),
            Case(phrase: "mets en évidence la ligne Agentic coding", action: .highlightCells, rows: [.name("Agentic coding")]),
            Case(phrase: "surligne la dernière ligne en vert", action: .highlightCells, rows: [.index(-1)]),
            Case(phrase: "encadre la case Opus 5 / Novel problem solving", action: .highlightCells, rows: [.name("Novel problem solving")], columns: [.name("Opus 5")]),
            Case(phrase: "highlight the last column", action: .highlightCells, columns: [.index(-1)]),
            Case(phrase: "highlight the Agentic coding row in blue", action: .highlightCells, rows: [.name("Agentic coding")]),
            Case(phrase: "shade row 2", action: .highlightCells, rows: [.index(2)]),
        ]
        cases.forEach { check($0) }
        XCTAssertEqual(engine.parse("surligne la dernière ligne en vert", context: context()).intents.first?.table?.style?.color, .green)
        XCTAssertEqual(engine.parse("highlight the Agentic coding row in blue", context: context()).intents.first?.color, .blue)
    }

    func testStyleWords() {
        let red = engine.parse("remplis la ligne Agentic computer use avec 1 en rouge", context: context()).intents.first
        XCTAssertEqual(red?.table?.rows, [.name("Agentic computer use")])
        XCTAssertEqual(red?.table?.style?.color, .red)
        let bold = engine.parse("mets des 1 en gras dans la colonne Opus 5", context: context()).intents.first
        XCTAssertEqual(bold?.table?.style?.weight, .bold)
        XCTAssertEqual(bold?.table?.columns, [.name("Opus 5")])
    }

    func testCompoundCommands() {
        let plan = engine.parse("remplis la colonne Opus 5 avec 1 et surligne-la", context: context())
        XCTAssertEqual(plan.intents.map(\.action), [.fillCells, .highlightCells])
        XCTAssertEqual(plan.intents.last?.table?.columns, [.name("Opus 5")], "« la » is the column just filled")
        let clearThenFill = engine.parse("vide la colonne Opus 5 puis remplis-la avec des 0", context: context())
        XCTAssertEqual(clearThenFill.intents.map(\.action), [.clearCells, .fillCells])
        XCTAssertEqual(clearThenFill.intents.last?.table?.value, .constant("0"))
        let withLook = engine.parse("remplis le tableau avec des 1 et augmente le contraste", context: context())
        XCTAssertEqual(withLook.intents.map(\.action), [.fillCells, .adjust])
        // "entre 50 et 90" is one range, never two commands.
        XCTAssertEqual(engine.parse("remplis le tableau avec des nombres au hasard entre 50 et 90", context: context()).intents.count, 1)
    }

    func testAmbiguousNamesAreAskedAndAnswered() async {
        let plan = engine.parse("remplis la colonne Opus avec 1", context: context())
        XCTAssertEqual(plan.intents.first?.table?.columns, [.name("Opus")], "as said")
        let executor = PhotoCommandExecutor(services: TableFakeServices(), language: .french)
        let (_, result) = await executor.execute(plan.intents[0], on: TableFixtures.document(), context: context())
        guard case .needsClarification(let request) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(request.question, "Quelle colonne : Opus 5.5 ou Opus 5 ?")
        XCTAssertEqual(result.reason, .ambiguous)
        let answer = engine.parse("Opus 5", context: IntentContext(mode: .photo, pendingClarification: request, table: TableFixtures.benchmark()))
        XCTAssertEqual(answer.intents.first?.action, .chooseCandidate)
        XCTAssertEqual(answer.intents.first?.index, 2, "« Opus 5 » is not « Opus 5.5 »")
        let pending = IntentContext(mode: .photo, pendingClarification: request, table: TableFixtures.benchmark())
        let (filled, done) = await executor.execute(answer.intents[0], on: TableFixtures.document(), context: pending)
        XCTAssertEqual(done.tableReport?.changed, 9)
        XCTAssertEqual(Set(filled.layers.compactMap { $0.group?.column }), [2])
    }

    // MARK: One cell by where it is (review: never many cells for one)

    func testOneCellByItsPlace() {
        let cases: [(String, Ref, Ref)] = [
            ("mets 5 dans la case en bas à droite", .index(-1), .index(-1)),
            ("mets 5 dans la case en haut à gauche", .index(1), .index(1)),
            ("mets 5 dans la première case", .index(1), .index(1)),
            ("remplis la dernière case avec 3", .index(-1), .index(-1)),
            ("mets 5 dans la case en haut à droite", .index(1), .index(-1)),
            ("mets 5 dans la case en bas à gauche", .index(-1), .index(1)),
            ("put 5 in the bottom right cell", .index(-1), .index(-1)),
            ("put 5 in the top left cell", .index(1), .index(1)),
            ("put 5 in the first cell", .index(1), .index(1)),
            ("fill the last cell with 3", .index(-1), .index(-1)),
        ]
        for (phrase, row, column) in cases {
            let plan = engine.parse(phrase, context: context())
            XCTAssertEqual(plan.intents.count, 1, phrase)
            XCTAssertEqual(plan.intents.first?.table?.rows, [row], phrase)
            XCTAssertEqual(plan.intents.first?.table?.columns, [column], phrase)
            XCTAssertTrue(plan.intents.first?.table?.namesOneCell ?? false, "\(phrase): exactly one cell")
        }
        // One cell said, and not which: asked, below the fast lane, never the whole table or a column.
        for phrase in ["mets 5 dans la case", "mets 5 dans la case de la colonne Opus 5", "put 5 in the cell"] {
            let plan = engine.parse(phrase, context: context())
            XCTAssertNotNil(plan.clarification, phrase)
            XCTAssertTrue(plan.clarification?.hasPrefix("Quelle case") == true || plan.clarification?.hasPrefix("Which cell") == true, "\(phrase): \(plan.clarification ?? "-")")
            XCTAssertLessThan(plan.confidence, 0.9, phrase)
        }
        // "chaque case", "every cell" are every cell.
        XCTAssertEqual(engine.parse("mets 5 dans chaque case", context: context()).intents.first?.table?.rows, [])
        XCTAssertEqual(engine.parse("put 5 in every cell", context: context()).intents.first?.table?.columns, [])
    }

    func testTheCellNextToANamedOne() {
        let right = engine.parse("mets 1 dans la case à droite de Opus 5.5 sur la ligne Agentic coding", context: context()).intents.first?.table
        XCTAssertEqual(right?.rows, [.name("Agentic coding")])
        XCTAssertEqual(right?.columns, [.index(2)], "the column right of Opus 5.5, not Opus 5.5")
        XCTAssertEqual(engine.parse("remplis la colonne juste avant GPT-6 Astra avec 0", context: context()).intents.first?.table?.columns, [.index(4)])
        // After a fill, the words alone name the neighbour.
        let last = TableEditSpec(rows: [.name("Agentic coding")], columns: [.name("Opus 5.5")], value: .constant("1"))
        let plan = engine.parse("la case à droite de Opus 5.5 sur la ligne Agentic coding", context: context(last: last, lastIntent: EditIntent(action: .fillCells, table: last)))
        XCTAssertEqual(plan.intents.first?.table?.columns, [.index(2)])
        XCTAssertEqual(plan.intents.first?.table?.value, .constant("1"))
    }

    // MARK: Values said as words, counted ranges

    func testNumbersSaidAsWordsAreWrittenInDigits() {
        let cases: [(String, CellValue)] = [
            ("mets deux dans chaque case du tableau", .constant("2")),
            ("mets zéro dans toutes les cases", .constant("0")),
            ("fill every cell with seven", .constant("7")),
            ("put a zero in every cell", .constant("0")),
            ("mets quatre-vingt-dix pour cent dans la case Opus 5.5 / Scaled tool use", .constant("90%")),
            ("mets 12,5 dans la case Fable 5.1 / Visual reasoning", .constant("12,5")),
        ]
        for (phrase, value) in cases {
            XCTAssertEqual(engine.parse(phrase, context: context()).intents.first?.table?.value, value, phrase)
        }
    }

    func testARangeThatCountsTheCellsIsASequence() {
        XCTAssertEqual(engine.parse("mets des nombres de 1 à 45 dans les cases", context: context()).intents.first?.table?.value, .sequence(start: 1, step: 1))
        XCTAssertEqual(engine.parse("mets des nombres entre 50 et 90 dans les cases", context: context()).intents.first?.table?.value, .random(min: 50, max: 90, decimals: nil))
        XCTAssertEqual(engine.parse("mets des nombres de 0 à 100 dans les cases", context: context()).intents.first?.table?.value, .random(min: 0, max: 100, decimals: nil),
                       "101 values for 45 cells: a range, not a count")
        XCTAssertEqual(engine.parse("mets des nombres au hasard de 1 à 45 dans les cases", context: context()).intents.first?.table?.value,
                       .random(min: 1, max: 45, decimals: nil), "said at random")
    }

    // MARK: Fast-lane precision (review: 11 turns the fast lane got wrong)

    func testFastLaneTurnsThatWereWrong() {
        func lane(_ phrase: String, _ ctx: IntentContext? = nil) -> (plan: EditPlan, local: Bool) {
            let plan = engine.parse(phrase, context: ctx ?? context())
            if case .local = LiveTurnRouter.route(phrase, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true) { return (plan, true) }
            return (plan, false)
        }
        // One cell: exactly one, or not on the fast lane.
        XCTAssertTrue(lane("mets 5 dans la case en bas à droite").plan.intents.first?.table?.namesOneCell ?? false)
        XCTAssertTrue(lane("mets 5 dans la première case").plan.intents.first?.table?.namesOneCell ?? false)
        XCTAssertEqual(lane("mets 1 dans la case à droite de Opus 5.5 sur la ligne Agentic coding").plan.intents.first?.table?.columns, [.index(2)])
        XCTAssertFalse(lane("mets 5 dans la case").local)
        // Values.
        XCTAssertEqual(lane("put a zero in every cell").plan.intents.first?.table?.value, .constant("0"))
        XCTAssertEqual(lane("mets des nombres de 1 à 45 dans les cases").plan.intents.first?.table?.value, .sequence(start: 1, step: 1))
        // Two clauses: each its own step, never one merged list.
        let clearFill = lane("vide la colonne Opus 5 et mets des 0 dans la colonne Fable 5.1").plan
        XCTAssertEqual(clearFill.intents.map(\.action), [.clearCells, .fillCells])
        let firstLast = lane("remplis la première colonne avec 1 et la dernière avec 0").plan
        XCTAssertEqual(firstLast.intents.map(\.action), [.fillCells, .fillCells])
        XCTAssertEqual(firstLast.intents.map { $0.table?.value }, [.constant("1"), .constant("0")])
        XCTAssertEqual(firstLast.intents.last?.table?.columns, [.name("GPT-6 Astra")])
        let rows = lane("remplis la ligne Agentic coding avec 1 et la ligne Knowledge work avec 0").plan
        XCTAssertEqual(rows.intents.map { $0.table?.rows }, [[.name("Agentic coding")], [.name("Knowledge work")]])
        let rest = lane("remplis la colonne Opus 5.5 avec 1, puis les autres avec 0").plan
        XCTAssertEqual(rest.intents.map { $0.table?.value }, [.constant("1"), .constant("0")])
        XCTAssertEqual(rest.intents.last?.table?.columns, [], "the others: the whole table's empty cells")
        XCTAssertFalse(rest.intents.contains { if case .list? = $0.table?.value { return true } else { return false } })
        // "ligne A" is a name the table does not have: asked, never the first row.
        XCTAssertEqual(lane("remplis la ligne A avec 1 et la ligne B avec 0").plan.intents.first?.table?.rows, [.name("A")])
        // A clause the grammar cannot read keeps the plan off the fast lane.
        let poster = IntentContext(mode: .photo, scene: SceneFixtures.posterScene())
        let square = lane("recadre en carré et ajoute « Promo » en haut", poster)
        XCTAssertFalse(square.local)
        XCTAssertTrue(square.plan.intents.contains { $0.action == .addText }, "the second clause is its own step")
        XCTAssertLessThan(engine.parse("remplis le tableau avec des 1 et fais un truc bizarre au ciel", context: context()).confidence, 0.9)
    }

    func testPoliteRequestsAreRequests() {
        for phrase in ["tu peux mettre des 1 partout ?", "Can you fill every cell with 1?", "Peux-tu surligner la colonne Opus 5 ?"] {
            let plan = engine.parse(phrase, context: context())
            XCTAssertTrue(IntentNormalizer.tableActions.contains(plan.intents.first?.action ?? .unknown), phrase)
            XCTAssertEqual(LiveTurnRouter.route(phrase, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true), .local(plan), phrase)
        }
        for question in ["tu peux me dire combien de cases sont vides ?", "can you see a person?", "que penses-tu de la colonne Opus 5 ?"] {
            XCTAssertEqual(LiveTurnRouter.route(question, grammar: engine.parse(question, context: context()), brain: .model, ideasOnScreen: 0,
                                                jobRunning: false, fastLane: true), .brain(isQuestion: true), question)
        }
    }

    // MARK: Regressions

    func testWhatIsNotATableCommand() {
        let ctx = context()
        XCTAssertEqual(engine.parse("supprime toutes les données du tableau", context: ctx).intents.first?.action, .removeObject)
        XCTAssertEqual(engine.parse("Supprime toutes les données du tableau.", context: .photo).intents.first?.target?.label, "text")
        XCTAssertEqual(engine.parse("remplis le ciel de nuages", context: ctx).intents.first?.action, .generativeFill)
        XCTAssertEqual(engine.parse("mets le texte en haut", context: IntentContext(mode: .photo, textLayerCount: 1, table: TableFixtures.benchmark())).intents.first?.action, .editText)
        XCTAssertNotEqual(engine.parse("écris 1 dans chaque case du tableau", context: .photo).intents.first?.action, .addText)
        XCTAssertNotEqual(engine.parse("mets des chiffres aléatoires dans toutes les cases", context: .photo).intents.first?.action, .generativeFill)
        for phrase in ["just in case, make it brighter", "combien de cases sont vides ?", "que penses-tu de la colonne Opus 5 ?", "remove the cell phone",
                       "mets la photo en noir et blanc", "efface la ligne d'horizon", "remove the table", "clear the table data", "ajoute le texte « Bonjour » en bas",
                       "put a vase on the table", "what is in the last column?", "ajoute le titre « Résultats » au-dessus du tableau",
                       "add the caption “Source: Picshop” under the table"] {
            let actions = engine.parse(phrase, context: ctx).intents.map(\.action)
            XCTAssertTrue(Set(actions).isDisjoint(with: IntentNormalizer.tableActions), "\(phrase): \(actions)")
        }
        XCTAssertEqual(engine.parse("remove the cell phone", context: .photo).intents.first?.target?.label, "phone")
        XCTAssertEqual(engine.parse("remove the table", context: .photo).intents.first?.target?.label, "table")
        XCTAssertEqual(engine.parse("ajoute le texte « Bonjour » en bas", context: ctx).intents.first?.text, "Bonjour")
        XCTAssertEqual(engine.parse("ajoute le titre « Résultats » au-dessus du tableau", context: ctx).intents.first?.text, "Résultats")
        XCTAssertEqual(engine.parse("écris « Total » dans la dernière ligne de la colonne Opus 5", context: ctx).intents.first?.action, .fillCells, "a cell is named")
    }
}
