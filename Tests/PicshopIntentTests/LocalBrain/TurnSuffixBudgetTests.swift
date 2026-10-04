import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// D23's suffix budgets: what each warm turn prefills on the KV engine (the turn's tool results, its user message
/// with the state delta, the layers line and the retrieved cards, and the generation prompt), measured with
/// `QwenChatTemplate` at 3.36 characters a token over the W3 scripted sessions. The p50 must stay within
/// `warmSuffixBudget` (no new cards) and `warmSuffixBudgetWithCards`.
final class TurnSuffixBudgetTests: XCTestCase {
    func testTheWarmSuffixesStayWithinTheirBudgets() {
        var plain: [Int] = []
        var carded: [Int] = []
        for dialogue in W3LiveScript.dialogues {
            let run = W3LiveScript.simulate(dialogue, limits: LiveContextPolicy.limits(for: LocalModelCatalog.max.info, engine: .kvEngine,
                                                                                       mediaAppendVerified: true))
            for turn in run.turns where turn.path == "warm" {
                if turn.hadCards { carded.append(turn.suffixTokens) } else { plain.append(turn.suffixTokens) }
            }
        }
        XCTAssertGreaterThan(plain.count, 20, "enough warm turns without cards to measure")
        XCTAssertGreaterThan(carded.count, 10, "enough warm turns with cards to measure")
        let plainP50 = W3LiveScript.median(plain)
        let cardedP50 = W3LiveScript.median(carded)
        print("warm suffix p50: \(plainP50) tokens without new cards (\(plain.count) turns), \(cardedP50) with (\(carded.count) turns)")
        XCTAssertLessThanOrEqual(plainP50, LiveContextPolicy.warmSuffixBudget)
        XCTAssertLessThanOrEqual(cardedP50, LiveContextPolicy.warmSuffixBudgetWithCards)
        // Order of magnitude only: a warm suffix is never a whole conversation.
        XCTAssertLessThan((plain + carded).max() ?? 0, 1_500)
    }

    func testTheScriptIsTwelveDialoguesOfTenTurns() {
        XCTAssertEqual(W3LiveScript.dialogues.count, 12)
        for dialogue in W3LiveScript.dialogues {
            XCTAssertEqual(dialogue.turns.count + 1, 10, dialogue.name)
        }
        XCTAssertEqual(Set(W3LiveScript.dialogues.map(\.name)).count, 12)
        // L4's corpus: French and English sessions, with the edits, the undo and the refused edit the replay models.
        let english = W3LiveScript.dialogues.filter { $0.language == .english }.count
        XCTAssertTrue((1...11).contains(english), "\(english) English sessions")
        XCTAssertEqual(W3LiveScript.core.map(\.name), LiveDialogueCases.layers.map(\.name))
        let steps = W3LiveScript.core.flatMap(\.turns)
        XCTAssertTrue(steps.contains { if case .undo = $0 { return true } else { return false } })
        XCTAssertTrue(steps.contains { if case .edit(_, _, _, _, let refused) = $0 { return refused != nil } else { return false } })
        XCTAssertGreaterThan(steps.filter { if case .edit(_, _, _, true, nil) = $0 { return true } else { return false } }.count, 15)
    }

    func testTheLayersLineFollowsTheEdits() {
        var line = W3LiveScript.LayersLine()
        XCTAssertNil(line.text)
        line.apply(#"[{"action":"layerVia","mode":"copy","where":"subject"}]"#)
        line.apply(#"[{"action":"addFillLayer","fill":"gradient","color":"black","angle":90}]"#)
        line.apply(#"[{"action":"addFillLayer","fill":"solid","color":"white","opacity":20}]"#)
        XCTAssertEqual(line.text, "layers: j2 Couleur 20% | j1 Dégradé | i1 subject | Photo base")
        line.apply(#"[{"action":"groupLayers","refs":["j1","j2"]}]"#)
        line.apply(#"[{"action":"layerOpacity","ref":"g1","opacity":60}]"#)
        XCTAssertEqual(line.text, "layers: g1 Groupe 1 60% [j2 Couleur 20% | j1 Dégradé] | i1 subject | Photo base")
        XCTAssertEqual(line.count, 5)
        line.apply(#"[{"action":"layerProperties","ref":"i1","lock":"all"}]"#)
        XCTAssertEqual(line.rows.last, "i1 subject lock")
        line.apply(#"[{"action":"layerProperties","ref":"i1","lock":"none"}]"#)
        XCTAssertEqual(line.rows.last, "i1 subject")
    }
}

/// The W3 layer dialogues (`LiveDialogueCases.layers`, the 12 sessions of §8.7: layers via copy, fills, clipped
/// adjustment layers, groups, recipes, PSD export, locks, layer masks), each extended to 10 turns with filler turns,
/// and a replay of the brain's context bookkeeping over them: the prefix of the 4B's photo prompt, each turn's owed
/// tool results and user message (`LocalLivePrompt`, with the retrieved cards the brain would add and the layers line
/// the edits leave), the reply with its call, a look whenever `needsFreshLook` says so, and a compaction past
/// `compactAt` or the picture cap. Token counts are `QwenChatTemplate` characters at 3.36 a token; a picture costs
/// 192 tokens.
enum W3LiveScript {
    static let charactersPerToken = 3.36
    static let tokensPerPicture = LocalContextLedger.tokensPerImage

    enum Step {
        /// An apply_edits call: what the user says, the reply's sentence, the steps, whether the document changes,
        /// and the reply after a refused result (nil: the result is not refused).
        case edit(String, String, String, Bool, String?)
        /// Speech only (questions, thanks): the reply.
        case talk(String, String)
        /// The undo tool.
        case undo(String, String)
    }

    struct Dialogue {
        var name: String
        var language: NormalizedUtterance.Language
        var turns: [Step]
    }

    struct TurnRecord {
        var path: String
        var suffixTokens: Int
        var hadCards: Bool
        var picture: Bool
        var contextTokens: Int
    }

    struct Run {
        var turns: [TurnRecord] = []
        var compactions = 0
        var peakTokens = 0
    }

    // MARK: The sessions

    static let fillersFR: [Step] = [
        .talk("parfait, merci", "Avec plaisir."),
        .edit("un peu plus de contraste", "J'ajoute un peu de contraste.", #"[{"action":"adjust","parameter":"contrast","amount":10}]"#, true, nil),
        .talk("c'est mieux comme ça ?", "Oui, le sujet ressort mieux et le fond reste doux."),
        .undo("annule la dernière", "J'annule la dernière modification."),
        .talk("qu'est-ce que tu en penses ?", "C'est équilibré ; un léger vignettage concentrerait le regard."),
        .talk("garde ça", "C'est gardé."),
    ]

    static let fillersEN: [Step] = [
        .talk("great, thanks", "You're welcome."),
        .edit("a bit more contrast", "A little more contrast.", #"[{"action":"adjust","parameter":"contrast","amount":10}]"#, true, nil),
        .talk("is it better now?", "Yes, the subject stands out and the background stays soft."),
        .undo("undo the last one", "Undoing the last change."),
        .talk("what do you think?", "It's balanced; a light vignette would draw the eye."),
        .talk("keep it", "Kept."),
    ]

    /// A corpus turn as the replay's step: its reference reply's sentence and call (apply_edits or undo), or speech.
    static func step(_ turn: DialogueTurn) -> Step {
        let reference = turn.reference
        guard let call = reference.range(of: "<tool_call>") else { return .talk(turn.text, reference) }
        let sentence = reference[..<call.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.contains("<function=undo>") { return .undo(turn.text, sentence) }
        guard let open = reference.range(of: "<parameter=steps>\n"),
              let close = reference.range(of: "\n</parameter>", range: open.upperBound..<reference.endIndex) else {
            return .talk(turn.text, sentence)
        }
        return .edit(turn.text, sentence, String(reference[open.upperBound..<close.lowerBound]), !turn.expect.noEdit, turn.afterResult)
    }

    /// L4's 12 W3 dialogues as steps.
    static let core: [Dialogue] = LiveDialogueCases.layers.map { dialogue in
        Dialogue(name: dialogue.name, language: dialogue.language, turns: dialogue.turns.map(step))
    }

    /// The 12 sessions, each extended to 10 turns (the session start plus 9) with filler turns.
    static let dialogues: [Dialogue] = core.enumerated().map { index, dialogue in
        var extended = dialogue
        let fillers = dialogue.language == .english ? fillersEN : fillersFR
        var next = index
        while extended.turns.count < 9 {
            // Fillers go between the scripted turns, so the follow-ups land after real edits.
            let position = min(extended.turns.count, 1 + 2 * (extended.turns.count - dialogue.turns.count))
            extended.turns.insert(fillers[next % fillers.count], at: position)
            next += 1
        }
        return extended
    }

    /// The `layers:` line the edits leave (D19's shape, top → bottom, the photo last), from the steps' actions.
    struct LayersLine {
        private(set) var rows: [String] = []
        private var counters: [String: Int] = [:]

        var text: String? { rows.isEmpty ? nil : "layers: " + (rows + ["Photo base"]).joined(separator: " | ") }

        /// The layers on the line, the photo included (a group counts with its children).
        var count: Int {
            1 + rows.reduce(0) { total, row in
                total + row.split(separator: " ").filter { word in
                    let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "[]|"))
                    guard let letter = trimmed.first, "ijslg".contains(letter) else { return false }
                    return trimmed.count > 1 && trimmed.dropFirst().allSatisfy(\.isNumber)
                }.count
            }
        }

        /// A JSON number as an Int (Foundation hands back NSNumber or a Swift number, by platform).
        static func number(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value) }
            if let value = value as? NSNumber { return value.intValue }
            return nil
        }

        private mutating func ref(_ letter: String) -> String {
            counters[letter, default: 0] += 1
            return "\(letter)\(counters[letter] ?? 1)"
        }

        private mutating func flag(_ ref: String?, _ flag: String) {
            guard let ref, let index = rows.firstIndex(where: { $0.hasPrefix(ref + " ") }) else { return }
            rows[index] += " " + flag
        }

        mutating func apply(_ stepsJSON: String) {
            guard let data = stepsJSON.data(using: .utf8),
                  let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            for step in steps {
                let ref = step["ref"] as? String
                switch step["action"] as? String {
                case "layerVia":
                    rows.insert("\(self.ref("i")) \((step["where"] as? String) ?? "Calque")", at: 0)
                case "addFillLayer":
                    let opacity = Self.number(step["opacity"]).map { " \($0)%" } ?? ""
                    rows.insert("\(self.ref("j")) \((step["fill"] as? String) == "gradient" ? "Dégradé" : "Couleur")\(opacity)", at: 0)
                case "addAdjustmentLayer":
                    rows.insert("\(self.ref("j")) \(((step["kind"] as? String) ?? "Réglage").capitalized)", at: 0)
                case "mergeLayers":
                    if let index = rows.firstIndex(where: { $0.hasPrefix((ref ?? "") + " ") }) ?? rows.indices.first { rows.remove(at: index) }
                case "groupLayers":
                    let refs = (step["refs"] as? [String]) ?? []
                    let members = rows.filter { row in refs.contains { row.hasPrefix($0 + " ") } }
                    rows.removeAll { row in refs.contains { row.hasPrefix($0 + " ") } }
                    let group = self.ref("g")
                    rows.insert("\(group) Groupe \(group.dropFirst()) [\(members.joined(separator: " | "))]", at: 0)
                case "layerClip":
                    flag(ref, "clip")
                case "layerOpacity":
                    if let opacity = Self.number(step["opacity"]) {
                        if let index = rows.firstIndex(where: { $0.hasPrefix((ref ?? "") + " ") }) {
                            rows[index] = rows[index].replacingOccurrences(of: " [", with: " \(opacity)% [")
                            if !rows[index].contains("\(opacity)%") { rows[index] += " \(opacity)%" }
                        }
                    }
                case "layerProperties":
                    if let lock = step["lock"] as? String, lock != "none" { flag(ref, "lock") }
                    if (step["lock"] as? String) == "none", let ref, let index = rows.firstIndex(where: { $0.hasPrefix(ref + " ") }) {
                        rows[index] = rows[index].replacingOccurrences(of: " lock", with: "")
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: The replay

    static func tokens(_ characters: Int) -> Int {
        Int((Double(max(0, characters)) / charactersPerToken).rounded(.up))
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// The steps' actions, joined: the history label and the result's words.
    static func actions(_ stepsJSON: String) -> String {
        guard let data = stepsJSON.data(using: .utf8),
              let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return "edit" }
        let names = steps.compactMap { $0["action"] as? String }
        return names.isEmpty ? "edit" : names.joined(separator: " + ")
    }

    /// One session through the brain's bookkeeping under `limits`.
    static func simulate(_ dialogue: Dialogue, limits: LiveContextLimits) -> Run {
        let info = LocalModelCatalog.max.info
        let setup = LocalModelLiveBrain.prefixSetup(mode: .photo, info: info)
        let language = dialogue.language
        let opLanguage: OpLanguage = language == .english ? .en : .fr

        var run = Run()
        var history = setup.history
        var transcript: [LocalChatMessage] = []
        var pictures = 0
        var owed: [LocalChatMessage] = []
        var previous: LiveEditorState?
        var recentCards: [[OpID]] = []
        var lastLookVersion: Int?
        var applied: [String] = []
        var line = LayersLine()
        var version = 1
        var exchanges: [String] = []
        var justCompacted = false
        var callCounter = 0

        func contextTokens() -> Int {
            var current = setup
            current.history = history
            return tokens(QwenChatTemplate.render(current, appending: transcript, addGenerationPrompt: false).count) + pictures * tokensPerPicture
        }

        func compact() {
            run.compactions += 1
            let recap = LocalLivePrompt.recap(LocalRecapInput(appliedEdits: Array(applied.suffix(10)), lastExchanges: Array(exchanges.suffix(3)),
                                                              openQuestion: nil, lastLook: "Une photo avec un sujet au centre."))
            history = setup.history + [.user(recap, imageJPEG: nil), .assistant(LocalModelLiveBrain.recapAcknowledgement(recap), toolCalls: [])]
            transcript = []
            pictures = 0
            owed = []
            previous = nil
            recentCards = []
            justCompacted = true
        }

        func cards(for turn: LiveUserTurn) -> String {
            let query = OperationQuery(text: turn.text, domain: .photo, language: language,
                                       hints: LocalModelLiveBrain.stateHints(turn.editorState), sticky: [])
            let fresh = OperationIndex.shared.retrieve(query, limit: 8).filter { !Set(recentCards.flatMap { $0 }).contains($0.id) }
            let block = OperationCards.turnBlock(fresh, language: opLanguage, budget: 1_000)
            let printed = block.isEmpty ? [] : fresh.map(\.id).filter { id in
                guard let spec = OperationCatalog.shared.spec(id) else { return false }
                return block.contains(OperationCards.card(spec, language: opLanguage)) || block.contains(spec.id.raw)
            }
            recentCards.append(printed)
            if recentCards.count > 3 { recentCards.removeFirst(recentCards.count - 3) }
            return block
        }

        let all: [Step?] = [nil] + dialogue.turns.map { Optional($0) }
        for (index, step) in all.enumerated() {
            var state = LiveEditorState(mode: .photo, version: version)
            state.canvasPixels = PSSize(width: 4_032, height: 3_024)
            state.appliedEdits = Array(applied.suffix(12))
            state.canUndo = !applied.isEmpty
            state.layers = line.text
            state.layerCount = line.count
            let text: String
            switch step {
            case nil: text = ""
            case .edit(let words, _, _, _, _)?, .talk(let words, _)?, .undo(let words, _)?: text = words
            }
            var turn = LiveUserTurn(id: index, kind: step == nil ? .sessionStart : .speech, text: text, language: language, image: nil,
                                    editorState: state)

            if contextTokens() > limits.compactAt { compact() }
            let since = lastLookVersion.map { max(0, version - $0) } ?? Int.max / 2
            let looks = lastLookVersion != version && LocalLivePrompt.needsFreshLook(turn, versionsSinceLastLook: since)
            if looks {
                if pictures >= limits.maxImagesInContext { compact() }
                turn.image = LiveImage(jpeg: Data([0xFF]), pixelWidth: 768, pixelHeight: 576, version: version)
                lastLookVersion = version
            }

            let message: String
            var hadCards = false
            if step == nil {
                message = LocalLivePrompt.sessionStartMessage(turn, imageAttached: looks)
            } else {
                let block = cards(for: turn)
                hadCards = !block.isEmpty
                message = LocalLivePrompt.userMessage(turn, previous: previous, imageAttached: looks, cards: block)
            }
            let sent = owed + [LocalChatMessage.user(message, imageJPEG: looks ? Data([0xFF]) : nil)]
            owed = []
            previous = state

            // The suffix a warm turn prefills: from the "\n" after the last <|im_end|> to the generation prompt.
            let anchor = LocalChatMessage.assistant("x", toolCalls: [])
            let suffixCharacters = QwenChatTemplate.render(system: "", tools: [], messages: [anchor] + sent).count
                - QwenChatTemplate.render(system: "", tools: [], messages: [anchor], addGenerationPrompt: false).count + 1
            let path: String
            if looks { path = "picture" } else if justCompacted || index == 0 { path = "prefix" } else { path = "warm" }
            justCompacted = false
            transcript += sent
            if looks { pictures += 1 }

            // The reply, its call, and the result owed to the next message.
            callCounter += 1
            let id = "call_\(index)_\(callCounter)"
            switch step {
            case nil:
                let ideas: JSONValue = .object(["ideas": .array((1...3).map { number in
                    .object(["title": .string("Idée \(number)"), "why": .string("Elle met le sujet en valeur sans trop en faire."),
                             "steps": .array([.object(["action": .string("adjust"), "contrast": .number(Double(10 * number))])])])
                })])
                let call = LocalToolCall(id: id, name: "propose_ideas", arguments: ideas)
                transcript.append(.assistant("Une photo lumineuse avec un sujet au centre.", toolCalls: [call]))
                owed = [.toolResult(callID: id, name: "propose_ideas", content: "Ideas shown.")]
            case .edit(let words, let reply, let stepsJSON, let changes, let refused)?:
                let call = LocalToolCall(id: id, name: "apply_edits", arguments: .object(["steps": .string(stepsJSON)]))
                transcript.append(.assistant(reply, toolCalls: [call]))
                let label = actions(stepsJSON)
                if let refused {
                    // A refused result (a locked layer) comes back within the turn and the reply follows it.
                    transcript.append(.toolResult(callID: id, name: "apply_edits", content: "0 operations applied: \(label) refused: the layer is locked"))
                    transcript.append(.assistant(refused, toolCalls: []))
                } else if changes {
                    owed = [.toolResult(callID: id, name: "apply_edits", content: "1 operation applied: \(label) · v\(version + 1) · check: verified")]
                    applied.append(label)
                    version += 1
                    line.apply(stepsJSON)
                } else {
                    owed = [.toolResult(callID: id, name: "apply_edits", content: "1 operation applied: \(label) · v\(version) · the document is unchanged")]
                }
                exchanges.append("\(words) → \(reply)")
            case .talk(let words, let reply)?:
                transcript.append(.assistant(reply, toolCalls: []))
                exchanges.append("\(words) → \(reply)")
            case .undo(let words, let reply)?:
                let call = LocalToolCall(id: id, name: "undo", arguments: .object([:]))
                transcript.append(.assistant(reply, toolCalls: [call]))
                owed = [.toolResult(callID: id, name: "undo", content: "Undone: \(applied.last ?? "edit")")]
                if !applied.isEmpty { applied.removeLast() }
                version += 1
                exchanges.append("\(words) → \(reply)")
            }
            let context = contextTokens()
            run.peakTokens = max(run.peakTokens, context)
            run.turns.append(TurnRecord(path: path, suffixTokens: tokens(suffixCharacters), hadCards: hadCards, picture: looks, contextTokens: context))
        }
        return run
    }
}
