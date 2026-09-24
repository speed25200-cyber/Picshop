import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    /// Questions score low on the grammar alone (it hears "trop saturé ?" as an edit); with Claude
    /// allowed, the router sends every one of them to the brain as a question.
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

            let lane = LiveTurnRouter.route(testCase.text, grammar: plan, brain: .claude, ideasOnScreen: 0, jobRunning: false, fastLane: true)
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

    // MARK: Opt-in: the real API

    /// Only with LIVE_EVAL=1 and ANTHROPIC_API_KEY set; never in CI. LIVE_EVAL_LIMIT caps the cases.
    func testClaudeOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LIVE_EVAL"] == "1", let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set LIVE_EVAL=1 and ANTHROPIC_API_KEY to run the Claude eval.")
        }
        let limit = environment["LIVE_EVAL_LIMIT"].flatMap(Int.init) ?? LiveEvalCases.all.count
        var correct = 0, toolCalls = 0, invalid = 0, answered = 0
        var firstTokens: [Double] = []
        var dollars = 0.0
        var usageTotal = ClaudeUsage()
        for testCase in LiveEvalCases.all.prefix(limit) {
            let entries = LogCollector()
            let brain = ClaudeLiveBrain(mode: testCase.mode, apiKey: key, transport: OneShotURLSessionTransport(), log: { entries.add($0) })
            let handler = FakeToolHandler()
            let context = testCase.context
            await MainActor.run { handler.intentContext = context }
            var state = LiveEditorState(mode: testCase.mode, version: 1)
            state.canvasPixels = testCase.mode == .video ? PSSize(width: 1920, height: 1080) : PSSize(width: 4032, height: 3024)
            let turn = LiveUserTurn(id: 1, kind: .speech, text: testCase.text, language: NormalizedUtterance(testCase.text).language, image: nil, editorState: state)
            let started = ProcessInfo.processInfo.systemUptime
            var firstText: Double?
            do {
                for try await event in brain.respond(to: turn, tools: handler) {
                    switch event {
                    case .text where firstText == nil: firstText = ProcessInfo.processInfo.systemUptime - started
                    case .usage(let usage):
                        dollars += LiveCostEstimator.dollars(usage)
                        usageTotal.inputTokens += usage.inputTokens
                        usageTotal.outputTokens += usage.outputTokens
                        usageTotal.cacheReadInputTokens += usage.cacheReadInputTokens
                    default: break
                    }
                }
                answered += 1
            } catch {
                print("LiveEval Claude error on '\(testCase.text)': \(error)")
            }
            if let firstText { firstTokens.append(firstText * 1000) }
            let calls = await MainActor.run { handler.calls }
            if !calls.isEmpty { toolCalls += 1 }
            invalid += entries.all.filter { $0.event == "tool_invalid" }.count
            var firstEdit: EditIntent?
            if case .applyEdits(let intents)? = calls.first(where: { if case .applyEdits = $0.tool { return true } else { return false } })?.tool { firstEdit = intents.first }
            if Self.matches(firstEdit, testCase) { correct += 1 }
        }
        let sorted = firstTokens.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        print("""
        LiveEval Claude (\(limit) cases, \(answered) answered)
        accuracy \(correct * 100 / max(1, limit))%  tool-call rate \(toolCalls * 100 / max(1, limit))%  invalid inputs \(invalid)
        first text p50 \(Int(percentile(0.5))) ms  p90 \(Int(percentile(0.9))) ms
        tokens in \(usageTotal.inputTokens) (cache read \(usageTotal.cacheReadInputTokens)) out \(usageTotal.outputTokens)  estimated cost $\(String(format: "%.3f", dollars)) (estimate)
        """)
    }
}

/// The opt-in runner's transport: plain URLSession, the whole SSE body delivered as one chunk.
struct OneShotURLSessionTransport: ClaudeTransport {
    func stream(_ request: ClaudeHTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (status, headers, body) = try await send(request)
                    guard (200..<300).contains(status) else { throw ClaudeAPIError(status: status, body: body, headers: headers) }
                    continuation.yield(body)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func send(_ request: ClaudeHTTPRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
        guard let url = URL(string: request.url) else { throw LiveBrainError.network("bad url") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] { headers["\(name)".lowercased()] = "\(value)" }
        return (http?.statusCode ?? 0, headers, data)
    }
}
