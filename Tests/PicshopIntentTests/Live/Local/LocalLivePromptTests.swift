import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The local model's prompt: budgets, content rules, examples that validate,
/// the delta editor state, fresh looks, the recap, and a golden snapshot.
final class LocalLivePromptTests: XCTestCase {
    static let modes: [EditorMode] = [.photo, .video]
    static let sizes: [LocalPromptSize] = [.full, .compact]

    /// The examples as the engine's history, the way the model brain replays them (a recovery's
    /// afterResult included).
    static func history(mode: EditorMode, size: LocalPromptSize) -> [LocalChatMessage] {
        LocalModelLiveBrain.exampleHistory(mode: mode, size: size)
    }

    static func setup(mode: EditorMode, size: LocalPromptSize) -> LocalChatSetup {
        LocalChatSetup(system: LocalLivePrompt.system(mode: mode, size: size), tools: LocalLivePrompt.toolSpecs(mode: mode),
                       history: history(mode: mode, size: size), imageMaxPixels: 196_608)
    }

    // MARK: Budgets and words

    func testBudgetsHold() {
        for mode in Self.modes {
            let specs = LocalLivePrompt.toolSpecs(mode: mode).map { $0.serialized() }.joined()
            XCTAssertLessThanOrEqual(specs.count, LocalLivePrompt.toolSpecsBudget, "\(mode) tool specs")
            for size in Self.sizes {
                let system = LocalLivePrompt.system(mode: mode, size: size)
                XCTAssertLessThanOrEqual(system.count, size == .full ? LocalLivePrompt.Budgets.systemFull : LocalLivePrompt.Budgets.systemCompact)
                let ledger = LocalContextLedger(setup: Self.setup(mode: mode, size: size))
                // The cached prefix, estimated at 3.2 characters a token (conservative): about 4.9K for the 4B's
                // photo prompt with its 15 examples (each id grounded in its own state, a failed check and its
                // repair), 3K for the 2B's, so a grounded conversation has room for four or five turns before
                // `compactAt` (7,000).
                XCTAssertLessThanOrEqual(ledger.prefixTokens, size == .full ? 5_000 : 3_000, "\(mode) \(size)")
                XCTAssertGreaterThan(ledger.prefixTokens, 1_000)
            }
            XCTAssertLessThan(LocalLivePrompt.system(mode: mode, size: .compact).count, LocalLivePrompt.system(mode: mode, size: .full).count)
        }
    }

    func testTheLocalPromptNamesNoCloudServiceAndStaysDeterministic() {
        var texts: [String] = []
        for mode in Self.modes {
            for size in Self.sizes {
                XCTAssertEqual(LocalLivePrompt.system(mode: mode, size: size), LocalLivePrompt.system(mode: mode, size: size))
                XCTAssertEqual(LocalLivePrompt.examples(mode: mode, size: size), LocalLivePrompt.examples(mode: mode, size: size))
                texts.append(QwenChatTemplate.render(Self.setup(mode: mode, size: size)))
            }
        }
        var turn = LiveUserTurn.speech("plus chaud")
        texts.append(LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: true))
        turn.kind = .sessionStart
        texts.append(LocalLivePrompt.sessionStartMessage(turn, imageAttached: true))
        texts.append(LocalLivePrompt.recap(LocalRecapInput(appliedEdits: ["Warmth +15"], lastExchanges: ["a → b"], openQuestion: "Lequel ?", lastLook: "Une plage.")))
        for text in texts {
            for word in ["claude", "anthropic", "chatgpt", "openai", "api key", "clé api"] {
                XCTAssertFalse(text.lowercased().contains(word), "says \(word)")
            }
        }
    }

    func testPersonaRules() {
        let full = LocalLivePrompt.system(mode: .photo, size: .full)
        for rule in ["tutoie", "moins de 20 mots", "apply_edits", "undo", "compare_before_after", "propose_ideas", "un peu 10", "beaucoup 40",
                     "<editor_state>", "<media_text>", "N'identifie jamais", "langue", "You are Picshop Live"] {
            XCTAssertTrue(full.contains(rule), rule)
        }
        XCTAssertTrue(full.hasPrefix("Tu es Picshop Live"), "French first")
        // About 230 words of persona for the 2B; the 4B's adds the undo, compare, vague-request, text and recovery rules,
        // and both say what a follow-up changes, that « tu peux … ? » is a request, and never to speak an id.
        XCTAssertLessThanOrEqual(LocalLivePrompt.persona(mode: .photo, size: .full).split(whereSeparator: \.isWhitespace).count, 380)
        XCTAssertLessThanOrEqual(LocalLivePrompt.persona(mode: .photo, size: .compact).split(whereSeparator: \.isWhitespace).count, 235)
        // The table, follow-up and recovery rules (contract §11), and textBehind only behind a person.
        for rule in ["Tableau (lignes table:)", "jamais addText, textBehind ni generativeFill", "refont last: sur la nouvelle portée",
                     "changent ce que last: a écrit (editText/moveText sur son id l…", "« tu peux … ? » est une demande : fais-la", "Ne dis jamais un id",
                     "ne relance jamais la même étape",
                     "dis pourquoi en une phrase et propose l'action la plus proche", "jamais un look sans rapport"] {
            XCTAssertTrue(full.contains(rule), rule)
        }
        XCTAssertFalse(full.contains("behind the subject"), "textBehind is worded for a person")
        XCTAssertTrue(full.contains("textBehind: a title behind a PERSON only"))
        XCTAssertFalse(LocalLivePrompt.system(mode: .video, size: .full).contains("fillCells"), "tables are photo-only")
        let compact = LocalLivePrompt.system(mode: .photo, size: .compact)
        for rule in ["tutoie", "apply_edits", "undo", "propose_ideas", "<editor_state>", "N'identifie jamais"] {
            XCTAssertTrue(compact.contains(rule), "compact: \(rule)")
        }
        XCTAssertTrue(LocalLivePrompt.system(mode: .video, size: .full).contains("vidéos"))
    }

    /// The action list names only real actions and values, allowed in its editor, about 20 for photos and 15 for videos.
    func testTheActionListIsExact() {
        for mode in Self.modes {
            let guide = LocalLivePrompt.actionGuide(mode: mode, size: .full)
            let allowed = Set(LiveToolSchema.allowedActions(for: mode).map(\.rawValue))
            // Values that share a name with an action (highlights, zoom) are not actions here.
            let values = Set(AdjustmentParameter.allCases.map(\.rawValue) + TransitionKind.allCases.map(\.rawValue) + FilterPreset.allCases.map(\.rawValue))
            let named = IntentAction.allCases.map(\.rawValue).filter { !values.contains($0) }.filter { action in
                guide.range(of: "\\b\(action)\\b", options: .regularExpression) != nil
            }
            XCTAssertTrue(Set(named).isSubset(of: allowed), "\(mode): \(Set(named).subtracting(allowed))")
            XCTAssertGreaterThanOrEqual(named.count, mode == .photo ? 18 : 15, "\(mode): \(named)")
            for look in ["vivid", "goldenHour", "mono", "cinematic"] { XCTAssertNotNil(FilterPreset(rawValue: look)); XCTAssertTrue(guide.contains(look)) }
            for parameter in ["temperature", "contrast", "exposure", "saturation"] { XCTAssertTrue(guide.contains(parameter)) }
            for aspect in ["square", "ratio16x9", "ratio9x16"] { XCTAssertNotNil(AspectPreset(rawValue: aspect)); XCTAssertTrue(guide.contains(aspect)) }
        }
    }

    // MARK: Tool specs

    func testToolSpecsAreCompactValidJSONForEveryTool() throws {
        for mode in Self.modes {
            let specs = LocalLivePrompt.toolSpecs(mode: mode)
            XCTAssertEqual(specs.compactMap { $0["function"]?["name"]?.string }, LiveToolName.allCases.map(\.rawValue).sorted())
            for spec in specs {
                XCTAssertEqual(try JSONValue.parse(spec.serialized()), spec)
                XCTAssertEqual(spec["type"], "function")
                let parameters = try XCTUnwrap(spec["function"]?["parameters"])
                XCTAssertEqual(parameters["type"], "object")
                XCTAssertFalse(spec.serialized().contains("\"enum\""), "enums live in prose")
            }
            XCTAssertEqual(specs.first { $0["function"]?["name"] == "apply_edits" }?["function"]?["parameters"]?["required"], ["steps"])
            XCTAssertEqual(specs.first { $0["function"]?["name"] == "propose_ideas" }?["function"]?["parameters"]?["required"], ["ideas"])
        }
    }

    // MARK: Examples

    func testTheExamplesTeachWhatASmallModelMustDo() {
        let photo = LocalLivePrompt.examples(mode: .photo, size: .full)
        XCTAssertEqual(photo.count, 15, "10 to 20 targeted examples for the 4B")
        XCTAssertEqual(photo.map(\.toolName), [.applyEdits, .undo, .proposeIdeas, .applyEdits, .applyEdits, .applyEdits, .applyEdits, .applyEdits,
                                                .applyEdits, .applyEdits, .applyEdits, .applyEdits, nil, .applyEdits, nil])
        func calls(_ example: LocalPromptExample) -> String { example.arguments?.serialized() ?? "" }
        XCTAssertTrue(calls(photo[3]).contains("\"point\""), "remove with a point")
        XCTAssertEqual(photo[4].arguments?["steps"]?.array?.count, 2, "two steps in one call")
        XCTAssertTrue(calls(photo[5]).contains("\"match\":\"t2\""), "write in the style of a text")
        XCTAssertTrue(calls(photo[6]).contains("\"ref\":\"t2\""), "replace a text by its id")
        XCTAssertTrue(photo[6].user.contains("texts: t1"), "the replacement reads its own texts line")
        XCTAssertTrue(photo[6].toolResult?.contains("(now l2)") ?? false, "the result names the layer the rewrite made")
        XCTAssertTrue(photo[7].user.contains("last: editText ref=t2→l2"), "a follow-up reads the last line, with the live id")
        XCTAssertFalse(photo[7].user.contains("t2 \""), "the erased block is off the texts line")
        XCTAssertTrue(calls(photo[7]).contains("\"ref\":\"l2\""), "…and acts on what it wrote")
        XCTAssertTrue(photo[8].user.contains("table: 5 rows x 4 cols"))
        XCTAssertTrue(calls(photo[8]).contains("fillCells"))
        XCTAssertTrue(photo[9].user.contains("last: fillCells"), "« les autres aussi »")
        XCTAssertTrue(calls(photo[9]).contains("\"cells\":\"empty\""))
        XCTAssertTrue(photo[10].user.hasSuffix("in the Atlas column"), "an English table request")
        XCTAssertTrue(calls(photo[11]).contains("\"row\"") && calls(photo[11]).contains("\"column\""), "one cell")
        XCTAssertTrue(photo[12].user.contains("table_focus:"), "a question the table line answers, without a tool")
        // Act-then-verify: a failed check, one repair on the layer the step made, then one line.
        let repaired = photo[13]
        XCTAssertTrue(repaired.toolResult?.contains("verify failed 1/1: text missing") ?? false, repaired.toolResult ?? "")
        XCTAssertTrue(repaired.toolResult?.contains("Hint:") ?? false)
        XCTAssertTrue(repaired.toolResult?.contains("(l1)") ?? false, "the result names what the step wrote")
        XCTAssertEqual(repaired.repair?.arguments["steps"]?.array?.first?["ref"], "l1")
        XCTAssertTrue(repaired.repair?.toolResult.contains("verified 1/1") ?? false)
        XCTAssertNotNil(repaired.afterResult)
        // A refusal the picture explains, with an offer and no call, comes last.
        XCTAssertNil(photo.last?.toolName)
        XCTAssertTrue(photo.last?.user.contains("scene: table screenshot") ?? false)
        XCTAssertTrue(photo.last?.assistant.hasSuffix("?") ?? false)

        // Every id an example's call names was printed in a state the model read by then (never teach a guess).
        var read = ""
        for example in photo {
            read += example.user
            for step in example.arguments?["steps"]?.array ?? [] {
                for key in ["ref", "match"] {
                    guard let id = step[key]?.string, id != "nearby" else { continue }
                    XCTAssertTrue(read.contains(id + " "), "\(id) was never printed before '\(example.user.suffix(60))'")
                }
            }
        }
        // And every ref, match, row and column a call names is in that example's own user text (or, for the repair
        // round, in the result it just read): no example teaches an id the model could not have seen.
        for size in Self.sizes {
            for example in LocalLivePrompt.examples(mode: .photo, size: size) {
                let calls: [(JSONValue?, String)] = [(example.arguments, example.user)] + [example.repair.map { ($0.arguments, example.user + (example.toolResult ?? "")) }].compactMap { $0 }
                for (arguments, visible) in calls {
                    for step in arguments?["steps"]?.array ?? [] {
                        for key in ["ref", "match", "row", "column"] {
                            guard let value = step[key]?.string, value != "nearby", Int(value) == nil else { continue }
                            XCTAssertTrue(visible.contains(value), "\(size): '\(value)' is not in its own state: '\(example.user.suffix(80))'")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(LocalLivePrompt.examples(mode: .video, size: .full).count, 6)
        XCTAssertEqual(LocalLivePrompt.examples(mode: .video, size: .compact).count, 4)
        let compact = LocalLivePrompt.examples(mode: .photo, size: .compact)
        XCTAssertEqual(compact.map(\.toolName), [.applyEdits, .undo, .proposeIdeas, nil, .applyEdits, .applyEdits, .applyEdits, nil])
        XCTAssertFalse(compact.contains { $0.repair != nil }, "the repair example is the 4B's")
        XCTAssertTrue(compact.contains { calls($0).contains("fillCells") }, "the 2B learns fillCells too")
        XCTAssertFalse(compact.contains { $0.user.hasSuffix("make it pop") }, "the 2B drops pop")
        for mode in Self.modes {
            for size in Self.sizes {
                for example in LocalLivePrompt.examples(mode: mode, size: size) {
                    for said in [example.assistant] + [example.afterResult].compactMap({ $0 }) {
                        XCTAssertLessThan(said.split(whereSeparator: \.isWhitespace).count, 20, said)
                        XCTAssertEqual(FilteredOutput.run([said]).speech, said, "speakable as written")
                        XCTAssertTrue(LiveSpeechSanitizer.isClean(said, language: .french), said)
                    }
                    XCTAssertTrue(example.user.contains("<editor_state"), "the real message format")
                    XCTAssertTrue(example.user.contains("langue: "))
                    XCTAssertEqual(example.toolResult == nil, example.toolName == nil)
                    XCTAssertFalse(example.user.lowercased().contains("claude"))
                }
            }
        }
    }

    /// Every example's call is one the validator accepts in its editor: the model learns only valid calls.
    func testEveryExampleCallValidates() throws {
        let grounding = ToolInputValidator.Grounding(imageAspect: 4.0 / 3.0, canvasAspect: 4.0 / 3.0)
        for mode in Self.modes {
            for size in Self.sizes {
                for example in LocalLivePrompt.examples(mode: mode, size: size) {
                    guard let tool = example.toolName else { continue }
                    let use = ToolArgumentCoercer.rawToolUse(id: "e", name: tool.rawValue, arguments: example.arguments ?? [:])
                    var context = IntentContext(mode: mode)
                    context.timelineDuration = 30
                    context.clipCount = 2
                    let call = try ToolInputValidator(mode: mode).validate(use, context: context, grounding: grounding).get()
                    if case .proposeIdeas(let ideas) = call.tool {
                        XCTAssertTrue(ideas.allSatisfy { !$0.steps.isEmpty }, "\(mode) \(size)")
                        XCTAssertEqual(ideas.count, mode == .video && size == .full ? 3 : 2)
                    }
                    if case .applyEdits(let intents) = call.tool, intents.first?.action == .removeObject, intents.first?.target?.point != nil {
                        XCTAssertEqual(use.rawInput.contains("0.82"), true, "the 0-1000 point reaches the validator in 0-1")
                    }
                }
            }
        }
    }

    // MARK: Messages

    private func richTurn(_ text: String = "rends-la plus chaude") -> LiveUserTurn {
        var turn = LiveUserTurn.speech(text)
        turn.editorState.appliedEdits = ["Warmth +15", "Contrast +20"]
        turn.editorState.adjustments[.temperature] = 0.15
        turn.editorState.scene = SceneDescription(people: 1, faces: 1, labels: ["beach", "sunset"], brightness: 0.62, colourfulness: 0.4)
        turn.sinceLastReply = ["tapped idea 'Portrait doux' -> applied"]
        turn.ideasOnScreen = ["Ciel plus dense", "Noir et blanc"]
        return turn
    }

    func testAFirstMessageCarriesTheWholeState() {
        var turn = richTurn()
        turn.editorState.mediaText = ["SOLDES -50%"]
        let message = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: true)
        XCTAssertEqual(message, """
        <editor_state v=10>
        mode: photo, 4032x3024 (4:3)
        applied: Warmth +15; Contrast +20
        values: temperature +15
        scene: 1 person, 1 face; beach, sunset; brightness 0.62, colourful 0.40
        since your reply: tapped idea 'Portrait doux' -> applied
        ideas on screen: 1 Ciel plus dense | 2 Noir et blanc
        image: attached (v10)
        </editor_state>
        langue: fr
        <media_text>
        SOLDES -50%
        </media_text>
        rends-la plus chaude
        """)
    }

    func testLaterMessagesCarryOnlyWhatChanged() {
        let turn = richTurn()
        var previous = turn.editorState
        previous.appliedEdits = ["Warmth +15"]
        previous.version = 9
        XCTAssertEqual(LocalLivePrompt.userMessage(turn, previous: previous, imageAttached: false), """
        <editor_state v=10>
        new: Contrast +20
        since your reply: tapped idea 'Portrait doux' -> applied
        ideas on screen: 1 Ciel plus dense | 2 Noir et blanc
        </editor_state>
        langue: fr
        rends-la plus chaude
        """)
        var quiet = LiveUserTurn.speech("merci")
        quiet.language = .french
        quiet.editorState = turn.editorState
        XCTAssertEqual(LocalLivePrompt.userMessage(quiet, previous: turn.editorState, imageAttached: false),
                       "<editor_state v=10>\nunchanged\n</editor_state>\nlangue: fr\nmerci")
        // An undo shrinks the history: the whole list, and the values that went away.
        var undone = quiet
        undone.editorState.appliedEdits = ["Warmth +15"]
        undone.editorState.adjustments = .neutral
        undone.editorState.pendingQuestion = "Lequel ?"
        let message = LocalLivePrompt.userMessage(undone, previous: turn.editorState, imageAttached: false)
        XCTAssertTrue(message.contains("applied: Warmth +15\n"), message)
        XCTAssertTrue(message.contains("values: neutral"))
        XCTAssertTrue(message.contains("question: Lequel ?"))
        var interrupted = quiet
        interrupted.interruptedAfter = "Je réchauffe un peu <la> photo"
        interrupted.language = .english
        interrupted.text = "no <b>colder</b>"
        let english = LocalLivePrompt.userMessage(interrupted, previous: turn.editorState, imageAttached: false)
        XCTAssertTrue(english.contains("interrupted after: 'Je réchauffe un peu ‹la> photo'"))
        XCTAssertTrue(english.contains("langue: en\nno ‹b>colder‹/b>"), "no tag can open in the user's words")
    }

    func testMessagesStayWithinBudget() {
        var turn = richTurn(String(repeating: "encore plus chaud ", count: 60))
        turn.editorState.appliedEdits = (1...12).map { "A long history label number \($0) with details" }
        turn.editorState.candidates = (1...8).map { "\($0): a candidate with a long description" }
        turn.sinceLastReply = (1...10).map { "commands: said something rather long \($0), applied it" }
        turn.ideasOnScreen = ["Une idée au titre long", "Une autre idée", "Et une troisième"]
        turn.editorState.mediaText = [String(repeating: "texte ", count: 200)]
        turn.interruptedAfter = String(repeating: "mot ", count: 80)
        let message = LocalLivePrompt.userMessage(turn, previous: nil, imageAttached: true)
        XCTAssertLessThanOrEqual(message.count, LocalLivePrompt.Budgets.userMessage)
        let state = LocalLivePrompt.editorDelta(turn, previous: nil, imageAttached: true)
        XCTAssertLessThanOrEqual(state.count, LocalLivePrompt.Budgets.editorDelta)
        XCTAssertTrue(state.hasSuffix("</editor_state>"))
        XCTAssertTrue(message.contains("langue: fr\n"))
        XCTAssertTrue(message.hasSuffix("…"), "the words are cut, never the language line")
        XCTAssertFalse(message.contains("<media_text>"), "media text only when it fits")
        var start = turn
        start.kind = .sessionStart
        XCTAssertLessThanOrEqual(LocalLivePrompt.sessionStartMessage(start, imageAttached: true).count, LocalLivePrompt.Budgets.userMessage)
    }

    func testSessionStartAsksForOneSentenceAndIdeas() {
        var turn = richTurn("")
        turn.kind = .sessionStart
        turn.language = .french
        let french = LocalLivePrompt.sessionStartMessage(turn, imageAttached: true)
        XCTAssertTrue(french.hasPrefix("<editor_state v=10>\nmode: photo"))
        XCTAssertTrue(french.contains("image: attached (v10)"))
        XCTAssertTrue(french.contains("Nouvelle session"))
        XCTAssertTrue(french.contains("propose_ideas"))
        turn.language = .english
        turn.editorState.mode = .video
        let english = LocalLivePrompt.sessionStartMessage(turn, imageAttached: false)
        XCTAssertTrue(english.contains("langue: en\nNew session"))
        XCTAssertTrue(english.contains("real video"))
        XCTAssertFalse(english.contains("image: attached"))
    }

    func testFreshLooks() {
        var start = LiveUserTurn.speech("")
        start.kind = .sessionStart
        XCTAssertTrue(LocalLivePrompt.needsFreshLook(start, versionsSinceLastLook: 0))
        XCTAssertFalse(LocalLivePrompt.needsFreshLook(.speech("plus chaud"), versionsSinceLastLook: 1), "a plain command")
        XCTAssertFalse(LocalLivePrompt.needsFreshLook(.speech("make it warmer"), versionsSinceLastLook: 2))
        XCTAssertTrue(LocalLivePrompt.needsFreshLook(.speech("plus chaud"), versionsSinceLastLook: 3), "3 versions since the last look")
        for words in ["tu en penses quoi ?", "qu'est-ce que tu proposes", "enlève le poteau à gauche", "le ciel est trop pâle", "what do you see", "remove the car"] {
            XCTAssertTrue(LocalLivePrompt.needsFreshLook(.speech(words), versionsSinceLastLook: 1), words)
        }
    }

    // MARK: Recap

    func testRecapKeepsTheNewestFactsWithinBudget() {
        let recap = LocalLivePrompt.recap(LocalRecapInput(appliedEdits: ["Warmth +15", "Vivid 60%"], lastExchanges: ["plus chaud → Je réchauffe.", "tu en penses quoi → Belle lumière."],
                                                          openQuestion: "Lequel des deux chiens ?", lastLook: "Plage au coucher du soleil, une personne."))
        XCTAssertEqual(recap, """
        Recap of the conversation so far (written by the app, not by the user):
        applied: Warmth +15; Vivid 60%
        last exchanges: plus chaud → Je réchauffe. | tu en penses quoi → Belle lumière.
        open question: Lequel des deux chiens ?
        last look: Plage au coucher du soleil, une personne.
        Carry on from here.
        """)
        let long = LocalLivePrompt.recap(LocalRecapInput(appliedEdits: (1...60).map { "Edit number \($0)" }, lastExchanges: (1...20).map { "exchange \($0) with <tags>" },
                                                         openQuestion: nil, lastLook: nil))
        XCTAssertLessThanOrEqual(long.count, LocalLivePrompt.Budgets.recap)
        XCTAssertTrue(long.contains("Edit number 60"), "the newest edit stays")
        XCTAssertTrue(long.contains("exchange 20"), "the newest exchange stays")
        XCTAssertFalse(long.contains("Edit number 1;"))
        XCTAssertFalse(long.contains("<tags>"))
        XCTAssertTrue(LocalLivePrompt.recap(LocalRecapInput(appliedEdits: [], lastExchanges: [], openQuestion: nil, lastLook: nil)).contains("applied: nothing"))
    }

    // MARK: Golden

    /// The whole cached prefix as the model reads it: system prompt, tool specs and
    /// examples, rendered through Qwen3.5's template. A change here is a prompt
    /// change: review it (LIVE_PROMPT_DUMP writes the files), then update the hashes.
    func testGoldenPrefix() {
        let golden: [(EditorMode, LocalPromptSize, Int, String)] = [
            // Re-baselined for the review round: the request-as-question and follow-up-on-last: rules, ids never
            // spoken, the corner/size/restyle guide lines, and the 15 photo examples (8 for the 2B) with a repair.
            (.photo, .full, 15728, "d13f8c6129ce6d95"),
            (.photo, .compact, 9457, "4e1e3119c40b9196"),
            (.video, .full, 8868, "d7ec0a13801f42d1"),
            (.video, .compact, 6822, "ac1d4d10810c4fc5"),
        ]
        for (mode, size, length, hash) in golden {
            let text = QwenChatTemplate.render(Self.setup(mode: mode, size: size), addGenerationPrompt: false)
            XCTAssertEqual(text.utf8.count, length, "\(mode) \(size)")
            XCTAssertEqual(IntentPromptGoldenTests.fnv1a(text), hash, "\(mode) \(size)")
        }
    }
}
