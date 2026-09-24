import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Runs the Live eval set through the rules and LocalLiveBrain in CI and prints the
/// accuracy per category. It fails only below the baseline measured when it was written.
final class LiveEvalTests: XCTestCase {
    struct Score {
        var cases = 0
        var rules = 0
        var local = 0
        var routedAsQuestion = 0
        var fastLane = 0
    }

    /// Correct answers per category on the day the eval was committed (rules, local brain):
    ///
    ///     LiveEval (222 cases): category, cases, rules, local brain, routed as a question, fast lane
    ///     direct      85  rules 83 (97%)  local 83 (97%)  question 0%  fast lane 43%
    ///     vague       42  rules 32 (76%)  local 32 (76%)  question 0%  fast lane 71%
    ///     correction  25  rules 23 (92%)  local 23 (92%)  question 0%  fast lane 40%
    ///     reference   20  rules 14 (70%)  local 14 (70%)  question 0%  fast lane 0%
    ///     asr         25  rules 18 (72%)  local 18 (72%)  question 0%  fast lane 48%
    ///     question    25  rules 9 (36%)  local 9 (36%)  question 100%  fast lane 0%
    ///
    /// Questions score low on the grammar alone (it hears "trop saturé ?" as an edit); with a model
    /// brain available, the router sends every one of them to the brain as a question.
    static let baseline: [LiveEvalCase.Category: (rules: Int, local: Int)] = [
        .direct: (83, 83), .vague: (32, 32), .correction: (23, 23), .reference: (14, 14), .asr: (18, 18), .question: (9, 9),
    ]

    func testCorpusShape() {
        XCTAssertGreaterThanOrEqual(LiveEvalCases.all.count, 200)
        for category in LiveEvalCase.Category.allCases {
            XCTAssertGreaterThanOrEqual(LiveEvalCases.all.filter { $0.category == category }.count, 15, category.rawValue)
        }
        let french = LiveEvalCases.all.filter { NormalizedUtterance($0.text).language == .french }.count
        XCTAssertGreaterThan(french, 60)
        XCTAssertGreaterThan(LiveEvalCases.all.count - french, 60)
    }

    /// Whether the first intent is an acceptable answer to the case.
    static func matches(_ intent: EditIntent?, _ testCase: LiveEvalCase) -> Bool {
        guard let intent else { return testCase.expected.isEmpty }
        guard testCase.expected.contains(intent.action) else { return false }
        if let parameter = testCase.parameter, intent.action == .adjust, intent.parameter != parameter { return false }
        if testCase.direction != 0, intent.action == .adjust, let amount = intent.amount, amount.mode == .relative {
            return (amount.value > 0 ? 1 : -1) == testCase.direction
        }
        return true
    }

    func testRulesAndLocalBrainAgainstTheBaseline() async throws {
        var scores: [LiveEvalCase.Category: Score] = [:]
        var misses: [String] = []
        let engine = RuleBasedIntentEngine()
        for testCase in LiveEvalCases.all {
            var score = scores[testCase.category] ?? Score()
            score.cases += 1
            let plan = engine.parse(testCase.text, context: testCase.context)
            let first = plan.intents.first { $0.action != .unknown }
            let rulesOK = Self.matches(first, testCase)
            if rulesOK { score.rules += 1 } else { misses.append("rules  [\(testCase.category.rawValue)] \(testCase.text) -> \(first?.action.rawValue ?? "nothing")") }

            let lane = LiveTurnRouter.route(testCase.text, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true)
            if lane == .brain(isQuestion: true) { score.routedAsQuestion += 1 }
            if case .local = lane { score.fastLane += 1 }

            let handler = FakeToolHandler()
            let context = testCase.context
            await MainActor.run { handler.intentContext = context }
            let brain = LocalLiveBrain(router: HybridIntentRouter(preferredEngine: .rules), mode: testCase.mode)
            let turn = LiveUserTurn(id: 1, kind: .speech, text: testCase.text, language: NormalizedUtterance(testCase.text).language,
                                    image: nil, editorState: LiveEditorState(mode: testCase.mode, version: 1))
            _ = await collect(brain.respond(to: turn, tools: handler))
            let calls = await MainActor.run { handler.calls }
            var firstApplied: EditIntent?
            if case .applyEdits(let intents)? = calls.first?.tool { firstApplied = intents.first }
            if Self.matches(firstApplied, testCase) { score.local += 1 }
            scores[testCase.category] = score
        }

        var report = ["LiveEval (\(LiveEvalCases.all.count) cases): category, cases, rules, local brain, routed as a question, fast lane"]
        for category in LiveEvalCase.Category.allCases {
            let score = scores[category] ?? Score()
            func percent(_ value: Int) -> String { score.cases == 0 ? "-" : "\(value * 100 / score.cases)%" }
            report.append("\(category.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(score.cases)  rules \(score.rules) (\(percent(score.rules)))  local \(score.local) (\(percent(score.local)))  question \(percent(score.routedAsQuestion))  fast lane \(percent(score.fastLane))")
        }
        print(report.joined(separator: "\n"))
        if ProcessInfo.processInfo.environment["LIVE_EVAL_VERBOSE"] == "1" { print(misses.joined(separator: "\n")) }

        for category in LiveEvalCase.Category.allCases {
            let score = scores[category] ?? Score()
            let floor = Self.baseline[category] ?? (0, 0)
            XCTAssertGreaterThanOrEqual(score.rules, floor.rules, "rules fell below the baseline on \(category.rawValue)")
            XCTAssertGreaterThanOrEqual(score.local, floor.local, "the local brain fell below the baseline on \(category.rawValue)")
        }
        // Every question must reach the brain as a question, never the fast lane.
        XCTAssertEqual(scores[.question]?.fastLane, 0)
    }
}
