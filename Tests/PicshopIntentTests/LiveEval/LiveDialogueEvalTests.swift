import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The dialogue LiveEval: every case of LiveDialogueCases through LiveDialogueEvalRunner (the same runner
/// the Diagnostic Live screen runs on the iPhone with the model loaded), on the executor-backed editor:
/// - scripted replay (pipeline): LocalModelLiveBrain replaying each turn's reference answer in Qwen3.5's own
///   format, streamed in random deltas. It measures the plumbing (filter, coercer, validator, handler, the
///   executor, verify), not a model's understanding: the answers were written by hand. Target: 100%.
/// - perturbed replay: the same, with the first answer written the way a small model writes it wrong (a cut
///   name, "r6", "bottom right", a size of 2, a stale id): each must still succeed within one repair round.
/// - grammar: LocalLiveBrain, the rules alone (Live without a model), and where LiveTurnRouter would send
///   each turn with the model loaded (the fast lane, which must never be wrong).
/// - Live with a model: the fast-lane turns scored on the grammar, the others on the model lane.
/// The real Qwen3.5 on these cases is measured on the device (Diagnostic Live › Understanding eval); until it
/// has run there, its accuracy is unmeasured.
final class LiveDialogueEvalTests: XCTestCase {
    /// Turns passed per category on the grammar lane (floors: a change that understands less fails here;
    /// one that understands more raises them). Measured:
    ///
    ///     category   cases turns  grammar          scripted replay   Live with model   fast lane (wrong)
    ///     table      46    46     46 (100%)        46 (100%)         46 (100%)         45 (0)
    ///     text       34    34     31 (91%)         34 (100%)         34 (100%)         0 (0)
    ///     followUp   26    52     52 (100%)        52 (100%)         52 (100%)         32 (0)
    ///     reference  21    22     22 (100%)        22 (100%)         22 (100%)         12 (0)
    ///     compound   21    22     21 (95%)         22 (100%)         22 (100%)         9 (0)
    ///     question   16    16     16 (100%)        16 (100%)         16 (100%)         0 (0)
    ///     recovery   11    11     11 (100%)        11 (100%)         11 (100%)         5 (0)
    ///     verify     11    11     11 (100%)        11 (100%)         11 (100%)         5 (0)
    static let grammarFloors: [LiveDialogueCase.Category: Int] = [
        .table: 45, .text: 31, .followUp: 52, .reference: 22, .compound: 21, .question: 16, .recovery: 11, .verify: 11,
    ]

    /// Targets (reported): the bar this corpus measures the grammar against.
    static let grammarTargets: [LiveDialogueCase.Category: Int] = [
        .table: 95, .text: 90, .followUp: 90, .reference: 80, .compound: 85, .question: 100, .recovery: 80, .verify: 90,
    ]

    func testCorpusShape() {
        let cases = LiveDialogueCases.all
        XCTAssertGreaterThanOrEqual(cases.count, 150, "at least 150 new cases")
        XCTAssertEqual(Set(cases.map(\.name)).count, cases.count, "names are unique")
        let minimum: [LiveDialogueCase.Category: Int] = [.table: 40, .text: 30, .followUp: 25, .reference: 20, .compound: 20, .question: 15, .recovery: 10,
                                                         .verify: 10]
        for category in LiveDialogueCase.Category.allCases {
            XCTAssertGreaterThanOrEqual(cases.filter { $0.category == category }.count, minimum[category] ?? 0, category.rawValue)
        }
        let turns = cases.flatMap(\.turns)
        let french = cases.filter { $0.language == .french }.flatMap(\.turns).count
        XCTAssertGreaterThan(french, turns.count / 2 - turns.count / 5, "about half French")
        XCTAssertGreaterThan(turns.count - french, turns.count / 5, "and English")
        XCTAssertGreaterThanOrEqual(cases.filter { $0.turns.count > 1 }.count, 25, "multi-turn follow-ups")
        XCTAssertGreaterThanOrEqual(turns.filter { $0.text.hasSuffix("?") && PoliteRequest.isRequest(NormalizedUtterance($0.text).tokens) }.count, 6,
                                    "polite requests the recognizer ends with ?")
        for turn in turns {
            XCTAssertFalse(turn.reference.isEmpty, turn.text)
            XCTAssertFalse(turn.reference.lowercased().contains("claude"))
        }
    }

    func testTheDialoguesThroughEveryLane() async throws {
        let cases = LiveDialogueCases.all
        let oracle = DialogueOracle()
        // The grammar lane through the runner's own report, as the Diagnostic screen runs it.
        let grammar = await LiveDialogueEvalRunner.evaluate(cases, label: "grammar", makeBrain: { _ in
            LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: .photo)
        })
        var grammarResults: [String: [LiveDialogueEvalRunner.TurnResult]] = [:]
        var modelResults: [String: [LiveDialogueEvalRunner.TurnResult]] = [:]
        var model = LiveDialogueEvalRunner.Report(label: "scripted replay (pipeline)", scores: [:], failures: [])
        // Live with a model: the fast-lane turns are the grammar's, the others the model's.
        var withModel: [LiveDialogueCase.Category: Int] = [:]
        for testCase in cases {
            let rules = await LiveDialogueEvalRunner.run(testCase, brain: LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: .photo))
            grammarResults[testCase.name] = rules
            let replay = await LiveDialogueEvalRunner.run(testCase, brain: Self.scriptedBrain(oracle: oracle, seed: Self.seed(testCase.name)), onTurn: { oracle.set($0) })
            modelResults[testCase.name] = replay
            var score = model.scores[testCase.category] ?? .init()
            score.cases += 1
            score.turns += replay.count
            score.passed += replay.filter(\.passed).count
            model.scores[testCase.category] = score
            for (turn, result) in replay.enumerated() where !result.passed {
                model.failures.append("[\(testCase.category.rawValue)] \(testCase.name) #\(turn + 1): \((result.failures + result.gates).joined(separator: "; ")) — said '\(result.spoken)'")
            }
            for (rule, scripted) in zip(rules, replay) where rule.localLane ? rule.passed : scripted.passed {
                withModel[testCase.category, default: 0] += 1
            }
        }

        var rows = ["LiveDialogueEval (\(cases.count) cases, \(cases.flatMap(\.turns).count) turns): category, cases, turns, grammar, scripted replay (pipeline), Live with model, fast lane (wrong)"]
        for category in LiveDialogueCase.Category.allCases {
            let rules = grammar.scores[category] ?? .init(), replay = model.scores[category] ?? .init()
            let live = withModel[category] ?? 0
            rows.append("\(category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(rules.cases)  \(rules.turns)  grammar \(rules.passed) (\(rules.percent)%, target \(Self.grammarTargets[category] ?? 0)%)  replay \(replay.passed) (\(replay.percent)%)  Live with model \(live) (\(rules.turns == 0 ? 0 : live * 100 / rules.turns)%)  fast lane \(rules.localTurns) (\(rules.localWrong) wrong)")
        }
        rows.append("The real Qwen3.5 on this corpus: unmeasured here; run Diagnostic Live › Understanding eval on the iPhone.")
        print(rows.joined(separator: "\n"))
        if ProcessInfo.processInfo.environment["LIVE_EVAL_VERBOSE"] == "1" { print(grammar.failures.map { "rules  " + $0 }.joined(separator: "\n")) }

        XCTAssertTrue(model.failures.isEmpty, "the scripted replay passes every turn:\n" + model.failures.joined(separator: "\n"))
        var gateViolations: [String] = []
        for testCase in cases {
            for (lane, results) in [("model", modelResults[testCase.name] ?? []), ("rules", grammarResults[testCase.name] ?? [])] {
                for (turn, result) in results.enumerated() where !result.gates.isEmpty {
                    gateViolations.append("\(lane) \(testCase.name) #\(turn + 1): \(result.gates.joined(separator: "; ")) — said '\(result.spoken)'")
                }
            }
            // With a model loaded the fast lane runs these turns without it: it must never be wrong.
            for (turn, result) in (grammarResults[testCase.name] ?? []).enumerated() where result.localLane && !result.passed {
                gateViolations.append("fast lane wrong: \(testCase.name) #\(turn + 1): \(result.failures.joined(separator: "; "))")
            }
            if testCase.category == .question, grammarResults[testCase.name]?.contains(where: \.localLane) == true {
                gateViolations.append("fast lane took a question: \(testCase.name)")
            }
        }
        XCTAssertTrue(gateViolations.isEmpty, "hard gates:\n" + gateViolations.joined(separator: "\n"))
        for category in LiveDialogueCase.Category.allCases {
            XCTAssertGreaterThanOrEqual(grammar.scores[category]?.passed ?? 0, Self.grammarFloors[category] ?? 0, "the grammar lane fell below its floor on \(category.rawValue)")
        }
        // A17: the table category on the grammar lane, at least 95 %.
        let table = grammar.scores[.table] ?? .init()
        XCTAssertGreaterThanOrEqual(table.passed * 100, table.turns * 95, "A17: grammar lane ≥ 95 % on tables")
    }

    /// Every reference answer uses only what the model could know: the prompt's own values, and ids and
    /// names it read in this case (the state lines, the tool results, or the user's words).
    func testEveryReferenceIsGrounded() async throws {
        let guide = LocalLivePrompt.actionGuide(mode: .photo, size: .full) + " " + LocalLivePrompt.persona(mode: .photo, size: .full)
        let oracle = DialogueOracle()
        var problems: [String] = []
        for testCase in LiveDialogueCases.all {
            let results = await LiveDialogueEvalRunner.run(testCase, brain: Self.scriptedBrain(oracle: oracle, seed: Self.seed(testCase.name)), onTurn: { oracle.set($0) })
            for (turn, result) in zip(testCase.turns, results) {
                let visible = result.seen + "\n" + turn.text
                for answer in [turn.reference, turn.afterResult].compactMap({ $0 }) {
                    for step in Self.steps(in: answer) {
                        for key in ["placement", "cells", "values", "weight", "align", "font"] {
                            guard let value = step[key]?.string else { continue }
                            if guide.range(of: "\\b\(NSRegularExpression.escapedPattern(for: value))\\b", options: .regularExpression) == nil {
                                problems.append("\(testCase.name): \(key) '\(value)' is not a value the prompt teaches")
                            }
                        }
                        for key in ["ref", "match"] {
                            guard let value = step[key]?.string, value != "nearby" else { continue }
                            if !visible.contains(value) { problems.append("\(testCase.name): \(key) '\(value)' was never shown to the model") }
                        }
                        for key in ["row", "column"] {
                            guard let value = step[key]?.string, Int(value) == nil else { continue }
                            if !visible.contains(value), !SceneMap.folded(turn.text).contains(SceneMap.folded(value)) {
                                problems.append("\(testCase.name): \(key) '\(value)' is not printed whole in a table line nor said")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, "ungrounded references:\n" + problems.joined(separator: "\n"))
    }

    /// Plausible wrong first answers (a cut name, "r6", "bottom right", a size of 2, the erased block's id):
    /// the coercer, the validator and the one repair round (which answers with the reference) still get
    /// every such turn right, with at most one repair.
    func testPerturbedAnswersRecoverWithinOneRepair() async throws {
        let oracle = DialogueOracle()
        var tried = 0
        var failures: [String] = []
        for testCase in LiveDialogueCases.all where testCase.turns.contains(where: { Self.perturbed($0, in: testCase) != nil }) {
            let turns = testCase.turns.map { turn in Self.perturbed(turn, in: testCase) ?? turn }
            let perturbed = LiveDialogueCase(name: testCase.name, category: testCase.category, picture: testCase.picture, turns: turns, failingChecks: testCase.failingChecks)
            let results = await LiveDialogueEvalRunner.run(perturbed, brain: Self.scriptedBrain(oracle: oracle, seed: Self.seed(testCase.name) &+ 7), onTurn: { oracle.set($0) })
            for index in results.indices where turns[index].reference != testCase.turns[index].reference {
                tried += 1
                let result = results[index]
                if !result.passed {
                    failures.append("\(testCase.name) #\(index + 1): \((result.failures + result.gates).joined(separator: "; ")) — first answer '\(turns[index].reference.suffix(90))'")
                }
                if result.runs > 2 * max(1, Self.steps(in: testCase.turns[index].reference).count) { failures.append("\(testCase.name) #\(index + 1): \(result.runs) runs, more than one repair") }
            }
        }
        print("LiveDialogueEval perturbed replay: \(tried - failures.count)/\(tried) turns recovered")
        XCTAssertGreaterThanOrEqual(tried, 20, "enough perturbed turns")
        XCTAssertTrue(failures.isEmpty, "perturbed answers that did not recover:\n" + failures.joined(separator: "\n"))
    }

    // MARK: Helpers

    /// A stable seed per case (FNV-1a of its name): the random deltas are the same on every run.
    static func seed(_ name: String) -> UInt64 {
        name.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    static func scriptedBrain(oracle: DialogueOracle, seed: UInt64) -> any LiveBrain {
        let factory: LocalChatEngineFactory = { _ in ScriptedQwenEngine(info: ScriptedQwenEngine.modelInfo, seed: seed, answer: { oracle.answer($0) }) }
        return LocalModelLiveBrain(mode: .photo, info: ScriptedQwenEngine.modelInfo, makeEngine: factory, fallback: nil)
    }

    /// The steps of the apply_edits calls in an answer written in Qwen3.5's format.
    static func steps(in answer: String) -> [JSONValue] {
        guard let start = answer.range(of: "<parameter=steps>\n"), let end = answer.range(of: "\n</parameter>", range: start.upperBound..<answer.endIndex),
              let parsed = try? JSONValue.parse(String(answer[start.upperBound..<end.lowerBound])) else { return [] }
        return parsed.array ?? []
    }

    /// The turn with its first answer written the way a small model gets it wrong, and the right answer as
    /// its repair; nil when there is nothing plausible to perturb (or the turn already scripts a recovery).
    static func perturbed(_ turn: DialogueTurn, in testCase: LiveDialogueCase) -> DialogueTurn? {
        guard turn.afterResult == nil, testCase.failingChecks.isEmpty, let start = turn.reference.range(of: "<parameter=steps>\n"),
              let end = turn.reference.range(of: "\n</parameter>", range: start.upperBound..<turn.reference.endIndex) else { return nil }
        var steps = String(turn.reference[start.upperBound..<end.lowerBound])
        let original = steps
        let replacements: [(String, String)] = [
            (#""placement":"topLeft""#, #""placement":"top left""#), (#""placement":"bottomRight""#, #""placement":"en bas à droite""#),
            (#""placement":"top""#, #""placement":"en haut""#), (#""placement":"bottom""#, #""placement":"bottom-center""#),
            (#""size":"bigger""#, #""size":1.35"#), (#""size":"x1.5""#, #""size":1.5"#),
            (#""row":"Graduate-level reasoning""#, #""row":"Graduate-level re…""#), (#""row":"Agentic coding""#, #""row":"Agentic co…""#),
            (#""row":"Visual reasoning""#, #""row":"Visual reas…""#), (#""row":"Knowledge work""#, #""row":"Knowledge wo…""#),
            (#""row":"1""#, #""row":"r1""#), (#""row":"2""#, #""row":"row 2""#), (#""row":"6""#, #""row":"r6""#), (#""column":"3""#, #""column":"c3""#),
            (#""column":"1""#, #""column":"col 1""#), (#""row":"-1""#, #""row":"last""#),
        ]
        for (from, to) in replacements where steps.contains(from) {
            steps = steps.replacingOccurrences(of: from, with: to)
            break
        }
        // A stale id: the printed block a rewrite replaced, named after the rewrite.
        if steps == original, let index = testCase.turns.firstIndex(where: { $0.text == turn.text }), index > 0, steps.contains(#""ref":"l1""#),
           let previous = Self.steps(in: testCase.turns[index - 1].reference).first?["ref"]?.string, previous.hasPrefix("t") {
            steps = steps.replacingOccurrences(of: #""ref":"l1""#, with: #""ref":"\#(previous)""#)
        }
        guard steps != original else { return nil }
        var wrong = turn.reference
        wrong.replaceSubrange(start.upperBound..<end.lowerBound, with: steps)
        return DialogueTurn(text: turn.text, reference: wrong, afterResult: turn.reference, expect: turn.expect, closing: nil)
    }
}

/// Answers the scripted engine with the current turn's reference (the user's words), its answer to the first
/// round of tool results (a repair, or a sentence after a refusal), then its closing line.
final class DialogueOracle: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DialogueTurn?
    private var rounds = 0

    func set(_ turn: DialogueTurn) { lock.withLock { current = turn; rounds = 0 } }

    func answer(_ words: String?) -> String {
        lock.withLock {
            guard let turn = current else { return "D'accord." }
            if words != nil { return turn.reference }
            rounds += 1
            let french = NormalizedUtterance(turn.text).language == .french
            if rounds == 1, let after = turn.afterResult { return after }
            return turn.closing ?? (french ? "Voilà." : "There you go.")
        }
    }
}
