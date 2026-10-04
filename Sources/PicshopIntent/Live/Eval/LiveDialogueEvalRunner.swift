import Foundation
import PicshopCore

/// Runs the dialogue corpus (`LiveDialogueCases`) through any `LiveBrain`, turn after turn, on a fresh
/// executor-backed editor per case (`LiveEvalEditor`), and checks what each turn did to the picture and
/// what was said. The unit tests run it with a scripted model and with the rules alone; the Diagnostic Live
/// screen runs it with the model loaded on the iPhone, so the real model's understanding is measured on the
/// same cases with the same scorer.
///
/// Hard gates on every turn: never silent, no markup, no internal word or code spoken, no scene id or cell
/// address spoken, no failed step run twice in the turn.
@MainActor public enum LiveDialogueEvalRunner {
    public struct TurnResult: Sendable {
        public var failures: [String]
        public var gates: [String]
        public var spoken: String
        /// With a model loaded, LiveTurnRouter would run this turn on the local (grammar) lane.
        public var localLane: Bool
        /// Executor runs in the turn (a call and its repair round count separately).
        public var runs: Int
        /// What the model read by the end of the turn (the state of every turn so far, with the words, and every
        /// tool result): the groundability check looks for the ids and names a reference uses in it.
        public var seen: String

        public var passed: Bool { failures.isEmpty && gates.isEmpty }
    }

    /// Per category, for one brain.
    public struct CategoryScore: Sendable, Equatable {
        public var cases = 0
        public var turns = 0
        public var passed = 0
        /// Turns the router would send to the local lane with a model loaded, and those of them that failed.
        public var localTurns = 0
        public var localWrong = 0

        public init() {}

        public var percent: Int { turns == 0 ? 0 : passed * 100 / turns }
    }

    public struct Report: Sendable {
        public var label: String
        public var scores: [LiveDialogueCase.Category: CategoryScore]
        /// "[table] name #2: what failed — said '…'".
        public var failures: [String]

        /// One line per category: "table      46  46  passed 45 (97%)  local lane 43 (0 wrong)".
        public var lines: [String] {
            var lines = ["LiveDialogueEval \(label): category, cases, turns, passed, local lane"]
            for category in LiveDialogueCase.Category.allCases {
                let score = scores[category] ?? CategoryScore()
                lines.append("\(category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(score.cases)  \(score.turns)  passed \(score.passed) (\(score.percent)%)  local lane \(score.localTurns) (\(score.localWrong) wrong)")
            }
            let total = scores.values.reduce(into: (0, 0)) { $0.0 += $1.passed; $0.1 += $1.turns }
            lines.append("total      \(total.0)/\(total.1) turns (\(total.1 == 0 ? 0 : total.0 * 100 / total.1)%)")
            return lines
        }
    }

    /// Every case through fresh brains from `makeBrain` (one per case: a conversation starts with the case),
    /// each turn announced to `onTurn` first (a scripted model reads its reference there), `progress` after
    /// each case. A cancelled task stops before the next case and reports the cases already run.
    public static func evaluate(_ cases: [LiveDialogueCase], label: String, makeBrain: @MainActor (LiveDialogueCase) async -> any LiveBrain,
                                onTurn: (@MainActor (DialogueTurn) -> Void)? = nil,
                                progress: (@MainActor (Int, Int) -> Void)? = nil) async -> Report {
        var report = Report(label: label, scores: [:], failures: [])
        for (index, testCase) in cases.enumerated() {
            if Task.isCancelled { break }
            let brain = await makeBrain(testCase)
            let results = await run(testCase, brain: brain, onTurn: onTurn)
            var score = report.scores[testCase.category] ?? CategoryScore()
            score.cases += 1
            score.turns += results.count
            score.passed += results.filter(\.passed).count
            score.localTurns += results.filter(\.localLane).count
            score.localWrong += results.filter { $0.localLane && !$0.passed }.count
            report.scores[testCase.category] = score
            for (turn, result) in results.enumerated() where !result.passed {
                report.failures.append("[\(testCase.category.rawValue)] \(testCase.name) #\(turn + 1): \((result.failures + result.gates).joined(separator: "; ")) — said '\(result.spoken)'")
            }
            progress?(index + 1, cases.count)
        }
        return report
    }

    /// The editor a case starts on.
    public static func host(for testCase: LiveDialogueCase) -> LiveEvalEditor {
        switch testCase.picture {
        case .benchmark: return .benchmark(failingChecks: testCase.failingChecks)
        case .values: return .benchmark(withValues: true, failingChecks: testCase.failingChecks)
        case .stray: return .benchmark(strayOne: true, failingChecks: testCase.failingChecks)
        case .poster: return .poster(failingChecks: testCase.failingChecks)
        case .lake: return .lake(failingChecks: testCase.failingChecks)
        }
    }

    /// One dialogue through one brain, on a fresh editor.
    public static func run(_ testCase: LiveDialogueCase, brain: any LiveBrain, onTurn: (@MainActor (DialogueTurn) -> Void)? = nil) async -> [TurnResult] {
        let host = host(for: testCase)
        let handler = EditorToolHandler(host: host, onIdeas: { _ in }, onJobFinished: { _ in })
        var results: [TurnResult] = []
        var seen = ""
        for (index, turn) in testCase.turns.enumerated() {
            onTurn?(turn)
            let language = testCase.language
            handler.language = language
            host.setLanguage(language)
            let before = Snapshot(host)
            let plan = RuleBasedIntentEngine().parse(turn.text, context: host.liveIntentContext())
            var local = false
            if case .local = LiveTurnRouter.route(turn.text, grammar: plan, brain: .model, ideasOnScreen: 0, jobRunning: false, fastLane: true) { local = true }
            let live = LiveUserTurn(id: index + 1, kind: .speech, text: turn.text, language: language, image: nil, editorState: host.liveContextSummary(),
                                    recentActions: Array(handler.recentActions.suffix(3)))
            seen += "\n" + LocalLivePrompt.userMessage(live, previous: nil, imageAttached: false)
            let (events, error) = await collect(brain.respond(to: live, tools: handler))
            for event in events {
                if case .toolFinished(_, _, let result) = event { seen += "\n" + ToolResultEncoder.compactText(result) }
            }
            let spoken = events.compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            var gates = Self.gates(spoken, language: language, events: events, error: error)
            // D12: a step that failed is never run again in the same turn (the same step applied twice is the
            // plan's business, not a retry).
            let appliedIDs = Set(host.applied.map(\.id))
            var firstRun: [LocalModelLiveBrain.StepSignature: Bool] = [:]
            for intent in host.runs.dropFirst(before.runs) {
                let signature = LocalModelLiveBrain.StepSignature(intent)
                if let applied = firstRun[signature] {
                    if !applied { gates.append("a failed step ran again: \(intent.action.rawValue)") }
                } else {
                    firstRun[signature] = appliedIDs.contains(intent.id)
                }
            }
            let failures = Self.check(turn.expect, host: host, before: before, spoken: spoken)
            results.append(TurnResult(failures: failures, gates: gates, spoken: spoken, localLane: local, runs: host.runs.count - before.runs, seen: seen))
        }
        return results
    }

    static func collect(_ stream: AsyncThrowingStream<LiveBrainEvent, Error>) async -> ([LiveBrainEvent], Error?) {
        var events: [LiveBrainEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    /// What the editor looked like before the turn.
    struct Snapshot {
        var runs: Int
        var applied: Int
        var erases: Int
        var sizes: [String: Double]
        var cellValues: [String]
        var layerIDs: Set<UUID>
        /// W2: the local adjustments and the pixel selection before the turn.
        var masks: [LocalAdjustment]
        var selection: PhotoSelection?
        var history: Int

        @MainActor init(_ host: LiveEvalEditor) {
            history = host.history.count
            masks = host.document.localAdjustments
            selection = host.document.selection
            runs = host.runs.count
            applied = host.applied.count
            erases = LiveDialogueEvalRunner.erases(host)
            sizes = Dictionary(host.textLayers.map { (SceneMap.folded($0.text), $0.relativeSize) }, uniquingKeysWith: { first, _ in first })
            cellValues = LiveDialogueEvalRunner.cellValues(host)
            layerIDs = Set(host.document.layers.map(\.id))
        }
    }

    /// The text of every cell layer, in row-major order.
    static func cellValues(_ host: LiveEvalEditor) -> [String] {
        let layers: [Layer] = host.cellLayers
        let ordered = layers.sorted { first, second in
            let a = (first.group?.row ?? 0) * 1_000 + (first.group?.column ?? 0)
            let b = (second.group?.row ?? 0) * 1_000 + (second.group?.column ?? 0)
            return a < b
        }
        return ordered.compactMap { $0.textElement?.text }
    }

    static func erases(_ host: LiveEvalEditor) -> Int {
        (host.document.baseLayer?.edits.operations ?? []).filter { operation in
            if case .removeObject = operation.kind { return true }
            return false
        }.count
    }

    // MARK: Gates

    /// "t3", "l2", "o1", "f1" or "r6c3" spoken.
    static let spokenIDPattern = #"\b[tlof]\d{1,3}\b|\br\d+c\d+\b"#

    public static func gates(_ spoken: String, language: NormalizedUtterance.Language, events: [LiveBrainEvent], error: Error?) -> [String] {
        var gates: [String] = []
        if let error { gates.append("error \(error)") }
        if !events.contains(where: { if case .completed = $0 { return true } else { return false } }) { gates.append("never completed") }
        if spoken.isEmpty { gates.append("silent") }
        if spoken.contains(where: { "<>{}[]".contains($0) }) { gates.append("markup spoken") }
        if !LiveSpeechSanitizer.isClean(spoken, language: language) { gates.append("internal word spoken") }
        if language == .french, spoken.lowercased().contains("subject") { gates.append("'subject' in French") }
        if spoken.contains("_") { gates.append("code spoken") }
        if spoken.range(of: spokenIDPattern, options: .regularExpression) != nil { gates.append("id spoken") }
        return gates
    }

    // MARK: Expectations

    static func check(_ expect: DialogueExpect, host: LiveEvalEditor, before: Snapshot, spoken: String) -> [String] {
        var failures: [String] = []
        let applied = Array(host.applied.dropFirst(before.applied))
        let fold = SceneMap.folded
        if let actions = expect.actions, Set(applied.map(\.action)) != actions {
            failures.append("applied \(applied.map(\.action.rawValue)) instead of \(actions.map(\.rawValue).sorted())")
        }
        if expect.noEdit, !applied.isEmpty { failures.append("edited \(applied.map(\.action.rawValue)) on a turn that changes nothing") }
        if let filled = expect.filled, host.filledCells != filled { failures.append("\(host.filledCells) cells filled instead of \(filled)") }
        for cell in expect.cells {
            let actual = host.cellText(row: cell.row, column: cell.column)
            if let text = cell.text {
                if actual != text { failures.append("r\(cell.row)c\(cell.column) reads \(actual.map { "'\($0)'" } ?? "nothing") instead of '\(text)'") }
            } else if host.table?.cell(dataRow: cell.row, dataColumn: cell.column)?.state != .empty {
                failures.append("r\(cell.row)c\(cell.column) should be empty")
            }
        }
        let rows = host.table?.dataRows.count ?? 0, columns = host.table?.dataColumns.count ?? 0
        for column in expect.columns {
            for row in stride(from: 1, through: rows, by: 1) {
                let actual = host.cellText(row: row, column: column.column)
                if actual == nil || (column.text != nil && actual != column.text) { failures.append("column \(column.column) r\(row): \(actual ?? "empty")"); break }
            }
        }
        for row in expect.rows {
            for column in stride(from: 1, through: columns, by: 1) {
                let actual = host.cellText(row: row.row, column: column)
                if actual == nil || (row.text != nil && actual != row.text) { failures.append("row \(row.row) c\(column): \(actual ?? "empty")"); break }
            }
        }
        if let range = expect.randomIn {
            let values = host.cellLayers.compactMap(\.textElement?.text)
            let numbers = values.compactMap { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "%", with: "")) }
            if numbers.count != values.count || values.isEmpty || !numbers.allSatisfy(range.contains) {
                failures.append("values \(values.prefix(6)) are not all numbers in \(range)")
            }
        }
        if let count = expect.cellLayers, host.cellLayers.count != count { failures.append("\(host.cellLayers.count) cell layers instead of \(count)") }
        if expect.keepsValues {
            let now = cellValues(host)
            if now != before.cellValues { failures.append("the cell values changed: \(before.cellValues.prefix(4)) → \(now.prefix(4))") }
        }
        let layers = host.textLayers
        func layer(_ text: String) -> TextElement? { layers.last { fold($0.text) == fold(text) } }
        for text in expect.texts where layer(text) == nil { failures.append("no text layer reads '\(text)'") }
        for text in expect.gone where host.scene?.texts.contains(where: { !$0.isLayer && fold($0.text) == fold(text) }) ?? false {
            failures.append("'\(text)' is still printed")
        }
        if let count = expect.highlights {
            let groups = Set(host.document.layers.compactMap { $0.group?.kind == .tableHighlight ? $0.group?.id : nil })
            if groups.count != count { failures.append("\(groups.count) highlights instead of \(count)") }
        }
        if expect.erased, erases(host) <= before.erases { failures.append("nothing was erased") }
        for words in expect.said where !fold(spoken).contains(fold(words)) { failures.append("did not say '\(words)'") }
        if expect.asks, !spoken.contains("?"), host.livePendingChoice == nil { failures.append("asked nothing") }
        if let text = expect.bigger {
            if let now = layer(text)?.relativeSize, let then = before.sizes[fold(text)] { if now <= then { failures.append("'\(text)' did not grow") } } else { failures.append("'\(text)' not found") }
        }
        if let text = expect.smaller {
            if let now = layer(text)?.relativeSize, let then = before.sizes[fold(text)] { if now >= then { failures.append("'\(text)' did not shrink") } } else { failures.append("'\(text)' not found") }
        }
        for styled in expect.colours {
            let colour = layer(styled.text).map { SceneMap.colorClass(of: $0.color) }
            if colour != styled.colour { failures.append("'\(styled.text)' is \(colour ?? "missing"), not \(styled.colour)") }
        }
        if expect.bold, host.cellLayers.contains(where: { SceneMap.weight(ofFontNamed: $0.textElement?.fontName ?? "") != .bold }) {
            failures.append("cells are not bold")
        }
        for placed in expect.placed {
            guard let element = layer(placed.text) else { failures.append("'\(placed.text)' not found"); continue }
            if !placed.y.contains(element.center.y) { failures.append("'\(placed.text)' at y \(element.center.y), not in \(placed.y)") }
        }
        for (text, count) in expect.layerCounts where layers.filter({ fold($0.text) == fold(text) }).count != count {
            failures.append("\(layers.filter { fold($0.text) == fold(text) }.count) layers read '\(text)' instead of \(count)")
        }
        if expect.neverDone, spoken.range(of: #"(?i)(^|[.!?]\s*)(c'est fait|done)\s*[.!]"#, options: .regularExpression) != nil {
            failures.append("said it was done although the check failed")
        }
        failures += maskFailures(expect, host: host, before: before, applied: applied)
        if let limit = expect.maxRuns, host.runs.count - before.runs > limit {
            failures.append("\(host.runs.count - before.runs) runs: more than one repair round")
        }
        // A new text lands clear of the text already there (at most 10 % of it over another block), unless asked.
        if !expect.overlapAllowed, applied.contains(where: { $0.action == .addText }), let scene = host.scene {
            let canvas = host.document.canvasSize
            for new in host.document.layers where !before.layerIDs.contains(new.id) && new.group == nil {
                guard let element = new.textElement else { continue }
                let box = element.estimatedBox(canvasSize: canvas)
                for block in scene.texts where block.layerID != new.id && box.area > 0 {
                    let shared = box.intersection(block.box).area / box.area
                    if shared > 0.1 { failures.append("'\(element.text)' covers \(Int(shared * 100))% of '\(block.text)'") }
                }
            }
        }
        return failures
    }

    /// W2: the masks and the selection a turn must leave.
    static func maskFailures(_ expect: DialogueExpect, host: LiveEvalEditor, before: Snapshot, applied: [EditIntent]) -> [String] {
        var failures: [String] = []
        let masks = host.document.localAdjustments
        if let ops = expect.ops {
            let ran = Set(applied.compactMap { $0.operation?.id.raw ?? ($0.action == .selectiveAdjust ? "selectiveAdjust" : nil) })
            if ran != ops { failures.append("ran \(ran.sorted()) instead of \(ops.sorted())") }
        }
        if let count = expect.maskCount, masks.count != count { failures.append("\(masks.count) masks instead of \(count)") }
        func mask(_ index: Int) -> LocalAdjustment? { index >= 1 && index <= masks.count ? masks[index - 1] : nil }
        func previous(_ index: Int) -> LocalAdjustment? {
            guard let now = mask(index) else { return nil }
            return before.masks.first { $0.id == now.id }
        }
        for dial in expect.dials {
            guard let adjustment = mask(dial.index) else { failures.append("no mask a\(dial.index)"); continue }
            let value = adjustment.adjustments[dial.parameter]
            let old = previous(dial.index)?.adjustments[dial.parameter] ?? 0
            switch dial.change {
            case .up: if value <= 0.0005 { failures.append("a\(dial.index) \(dial.parameter.rawValue) is \(value), not raised") }
            case .down: if value >= -0.0005 { failures.append("a\(dial.index) \(dial.parameter.rawValue) is \(value), not lowered") }
            case .grew: if abs(value) <= abs(old) + 0.0005 { failures.append("a\(dial.index) \(dial.parameter.rawValue) did not grow (\(old) → \(value))") }
            case .shrank: if abs(value) >= abs(old) - 0.0005 { failures.append("a\(dial.index) \(dial.parameter.rawValue) did not shrink (\(old) → \(value))") }
            }
        }
        for (index, region) in expect.maskRegions where mask(index)?.region != region {
            failures.append("a\(index) is \(mask(index)?.region?.rawValue ?? "missing"), not \(region.rawValue)")
        }
        for index in expect.invertedMasks where mask(index)?.stack.isInverted != true { failures.append("a\(index) is not inverted") }
        for index in expect.hiddenMasks where mask(index)?.isVisible != false { failures.append("a\(index) is not hidden") }
        if let selected = expect.selected {
            if selected, host.document.selection == nil { failures.append("nothing is selected") }
            if !selected, host.document.selection != nil { failures.append("something is still selected") }
        }
        if expect.selectionChanged, host.document.selection == before.selection { failures.append("the selection did not change") }
        if expect.reverts, host.history.count >= before.history { failures.append("nothing was undone") }
        for region in expect.regionsPresent where !masks.contains(where: { $0.region == region }) { failures.append("no mask on \(region.rawValue)") }
        for index in expect.strengthened {
            guard let now = mask(index) else { failures.append("no mask a\(index)"); continue }
            let total = { (adjustment: LocalAdjustment?) in adjustment.map { a in AdjustmentParameter.allCases.reduce(0) { $0 + abs(a.adjustments[$1]) } } ?? 0 }
            if total(now) <= total(previous(index)) + 0.0005 { failures.append("a\(index) did not get stronger") }
        }
        return failures
    }
}
