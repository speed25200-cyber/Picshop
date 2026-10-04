import Foundation
import PicshopCore

/// The M lane on the device (W2): drives any LiveBrain through LiveEvalEditor and LiveEvalServices over
/// MLaneCorpus (single-turn photo requests with gold op and args, kept apart from the catalog examples) and the
/// W2 LiveDialogueCorpus dialogues. The test-only HeldOutUtterances cannot ship in the app, so it is not used
/// here. LiveDebugView's « Banc d'essai M » row runs it on the loaded model and shares the JSON report.
@MainActor public enum MLaneRunner {
    public struct Report: Codable, Sendable, Equatable {
        public var label: String
        public var cases: Int
        public var opExactMatch: Double
        public var argumentF1: Double
        public var firstTryValid: Double
        public var appliedVerified: Double
        public var honestRefusals: Double
        /// Seconds per turn.
        public var latencyP50: Double
        public var latencyP95: Double
        /// The first 40, one line each.
        public var failures: [String]

        public init(label: String, cases: Int = 0, opExactMatch: Double = 0, argumentF1: Double = 0, firstTryValid: Double = 0,
                    appliedVerified: Double = 0, honestRefusals: Double = 0, latencyP50: Double = 0, latencyP95: Double = 0,
                    failures: [String] = []) {
            self.label = label
            self.cases = cases
            self.opExactMatch = opExactMatch
            self.argumentF1 = argumentF1
            self.firstTryValid = firstTryValid
            self.appliedVerified = appliedVerified
            self.honestRefusals = honestRefusals
            self.latencyP50 = latencyP50
            self.latencyP95 = latencyP95
            self.failures = failures
        }

        /// The report as shared from the device (sorted keys, so two runs diff line by line).
        public var json: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    /// What one single-turn case gave.
    public struct CaseResult: Sendable, Equatable {
        public var text: String
        public var refusal: Bool
        public var ops: [String]
        public var opMatch = false
        public var argumentF1 = 0.0
        public var firstTryValid = false
        public var appliedVerified = false
        public var honest = false
        public var seconds: Double
        public var failure: String?
    }

    /// Runs the single-turn cases (the first `limit`), then (with `dialogues`, on a full run) the W2 dialogue turns.
    /// Op match and argument F1 are measured on the requests that name an operation; firstTryValid on every request;
    /// appliedVerified on the edit requests and the dialogue turns (a dialogue turn counts when its expectations
    /// hold); honestRefusals on the requests whose right answer changes nothing. `onCase` and `onTurn` announce what
    /// is about to run (a scripted model reads its reference there).
    public static func run(label: String, limit: Int? = nil, dialogues: Bool = true, onCase: (@MainActor (MLaneCase) -> Void)? = nil,
                           onTurn: (@MainActor (DialogueTurn) -> Void)? = nil, makeBrain: @MainActor () async -> any LiveBrain) async -> Report {
        let cases = Array(MLaneCorpus.all.prefix(limit ?? MLaneCorpus.all.count))
        var results: [CaseResult] = []
        for testCase in cases {
            if Task.isCancelled { break }
            onCase?(testCase)
            results.append(await run(testCase, brain: await makeBrain()))
        }
        var turns: [(passed: Bool, seconds: Double, failure: String?)] = []
        if dialogues, limit == nil {
            for testCase in LiveDialogueCases.masks {
                if Task.isCancelled { break }
                let started = ContinuousClock.now
                let results = await LiveDialogueEvalRunner.run(testCase, brain: await makeBrain(), onTurn: onTurn)
                let each = seconds(ContinuousClock.now - started) / Double(max(1, results.count))
                for (index, result) in results.enumerated() {
                    let failure = result.passed ? nil : "[dialogue] \(testCase.name) #\(index + 1): \((result.failures + result.gates).joined(separator: "; "))"
                    turns.append((result.passed, each, failure))
                }
            }
        }
        return report(label: label, results: results, dialogueTurns: turns)
    }

    /// One request on a fresh lake photo.
    public static func run(_ testCase: MLaneCase, brain: any LiveBrain) async -> CaseResult {
        let host = LiveEvalEditor.lake()
        await prepare(host, testCase.setup)
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        let language = testCase.language
        handler.language = language
        host.setLanguage(language)
        let runsBefore = host.runs.count, appliedBefore = host.applied.count
        let turn = LiveUserTurn(id: 1, kind: .speech, text: testCase.text, language: language, image: nil, editorState: host.liveContextSummary())
        let started = ContinuousClock.now
        let (events, error) = await LiveDialogueEvalRunner.collect(brain.respond(to: turn, tools: handler))
        let ran = Array(host.runs.dropFirst(runsBefore))
        let applied = Array(host.applied.dropFirst(appliedBefore))
        let ops = ran.map(opID)
        let spoken = events.compactMap { event -> String? in
            if case .text(let text) = event { return text }
            return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = events.compactMap { event -> LiveToolResult? in
            if case .toolFinished(_, let name, let result) = event, name == .applyEdits { return result }
            return nil
        }
        let failedCheck = calls.contains { $0.execution?.steps.contains { $0.verification?.status == .failed } ?? false }
        var result = CaseResult(text: testCase.text, refusal: testCase.isRefusal, ops: ops, seconds: seconds(ContinuousClock.now - started))
        // Valid: the validator took the first call (a step the handler then refused honestly is still valid).
        func valid(_ result: LiveToolResult) -> Bool {
            guard result.isError, case .object(let payload) = result.payload, case .string(let kind)? = payload["error"] else { return true }
            return kind != "invalid_input"
        }
        if testCase.isRefusal {
            result.honest = applied.isEmpty && !spoken.isEmpty && error == nil
            result.firstTryValid = calls.first.map(valid) ?? true
            if !result.honest { result.failure = "« \(testCase.text) » should change nothing: ran \(ops), said '\(spoken.prefix(60))'" }
            return result
        }
        result.firstTryValid = calls.first.map(valid) ?? false
        result.opMatch = ops.first.map(testCase.gold.contains) ?? false
        let chosen = ran.first { testCase.gold.contains(opID($0)) } ?? ran.first
        result.argumentF1 = chosen.map { f1(produced: arguments(of: $0), gold: testCase.args) } ?? 0
        result.appliedVerified = applied.contains { testCase.gold.contains(opID($0)) } && !failedCheck
        if !result.opMatch || !result.appliedVerified || result.argumentF1 < 1 {
            result.failure = "« \(testCase.text) » ran \(ops) (gold \(testCase.gold.sorted())), F1 \(String(format: "%.2f", result.argumentF1))"
                + (result.appliedVerified ? "" : ", not applied and verified") + (error.map { ", \($0)" } ?? "")
        }
        return result
    }

    // MARK: Setup

    static func prepare(_ host: LiveEvalEditor, _ setup: MLaneCase.Setup) async {
        let calls: [OperationCall]
        switch setup {
        case .none: calls = []
        case .masks:
            calls = [OperationCall("maskAdjust", args: ["where": "sky", "parameter": "exposure", "amount": -10], source: .ui),
                     OperationCall("maskAdjust", args: ["where": "bottom", "parameter": "exposure", "amount": -20], source: .ui)]
        case .selection: calls = [OperationCall("select", args: ["what": "subject"], source: .ui)]
        }
        for call in calls { _ = await host.liveRun(EditIntent(action: .operation, operation: call)) }
    }

    // MARK: Scoring

    /// A step's operation: its catalog id, or a legacy action's raw value.
    nonisolated static func opID(_ intent: EditIntent) -> String {
        intent.operation?.id.raw ?? intent.action.rawValue
    }

    /// The step's arguments as the corpus writes them (numbers by their sign, text lower-cased, lists sorted). A
    /// legacy selectiveAdjust's target is its `where`.
    nonisolated static func arguments(of intent: EditIntent) -> [String: String] {
        if let call = intent.operation { return call.args.mapValues(normalized) }
        guard let data = try? JSONEncoder().encode(RawIntentStep(intent: intent)), let json = try? JSONValue.parse(bytes: Array(data)),
              case .object(let object) = json else { return [:] }
        var arguments: [String: String] = [:]
        for (key, value) in object where key != "action" { arguments[key] = normalized(value) }
        if intent.action == .selectiveAdjust, let target = arguments["target"] { arguments["where"] = target }
        return arguments
    }

    nonisolated static func normalized(_ value: OpValue) -> String {
        switch value {
        case .number(let number): return number > 0 ? "+" : number < 0 ? "-" : "0"
        case .string(let text): return text.lowercased()
        case .bool(let flag): return flag ? "true" : "false"
        case .point: return "point"
        case .box: return "box"
        case .list(let items): return items.map(normalized).sorted().joined(separator: ",")
        }
    }

    nonisolated static func normalized(_ value: JSONValue) -> String {
        switch value {
        case .number(let number): return number > 0 ? "+" : number < 0 ? "-" : "0"
        case .string(let text): return text.lowercased()
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let items): return items.map(normalized).sorted().joined(separator: ",")
        case .object: return "object"
        case .null: return ""
        }
    }

    /// F1 of the produced pairs against the gold ones, on the gold's keys (1 when the gold names none).
    nonisolated static func f1(produced: [String: String], gold: [String: String]) -> Double {
        guard !gold.isEmpty else { return 1 }
        let produced = produced.filter { gold[$0.key] != nil }
        let hits = gold.filter { produced[$0.key] == $0.value }.count
        guard hits > 0 else { return 0 }
        let precision = Double(hits) / Double(produced.count), recall = Double(hits) / Double(gold.count)
        return 2 * precision * recall / (precision + recall)
    }

    nonisolated static func report(label: String, results: [CaseResult], dialogueTurns: [(passed: Bool, seconds: Double, failure: String?)]) -> Report {
        let edits = results.filter { !$0.refusal }
        let refusals = results.filter(\.refusal)
        func rate(_ hits: Int, _ total: Int) -> Double { total == 0 ? 0 : (Double(hits) / Double(total) * 1_000).rounded() / 1_000 }
        let latencies = (results.map(\.seconds) + dialogueTurns.map(\.seconds)).sorted()
        func percentile(_ p: Double) -> Double {
            guard !latencies.isEmpty else { return 0 }
            let index = min(latencies.count - 1, Int((Double(latencies.count - 1) * p).rounded()))
            return (latencies[index] * 1_000).rounded() / 1_000
        }
        let f1 = edits.isEmpty ? 0 : edits.map(\.argumentF1).reduce(0, +) / Double(edits.count)
        return Report(label: label, cases: results.count + dialogueTurns.count,
                      opExactMatch: rate(edits.filter(\.opMatch).count, edits.count),
                      argumentF1: (f1 * 1_000).rounded() / 1_000,
                      firstTryValid: rate(results.filter(\.firstTryValid).count, results.count),
                      appliedVerified: rate(edits.filter(\.appliedVerified).count + dialogueTurns.filter(\.passed).count, edits.count + dialogueTurns.count),
                      honestRefusals: rate(refusals.filter(\.honest).count, refusals.count),
                      latencyP50: percentile(0.5), latencyP95: percentile(0.95),
                      failures: Array((results.compactMap(\.failure) + dialogueTurns.compactMap(\.failure)).prefix(40)))
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
