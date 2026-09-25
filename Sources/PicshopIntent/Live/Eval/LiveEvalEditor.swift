import Foundation
import PicshopCore

/// An editor for Live built on the real `PhotoCommandExecutor` and `LiveEvalServices`, wired the way the
/// photo session is: the table and the scene map overlaid with the layers in the context and in the state,
/// `lastTableEdit` / `lastIntent` kept for follow-ups, one undo entry per applied step, and act-then-verify
/// (`EditVerifier.request` after each step, `services.verify` for `liveVerify`). The model lane tests, the
/// dialogue eval and the Diagnostic Live runner run on it, so they exercise the real executor.
@MainActor public final class LiveEvalEditor: LiveEditingHost {
    public private(set) var document: PhotoDocument
    public let services: LiveEvalServices
    private var executor: PhotoCommandExecutor
    /// What each applied step replaced, newest last: undo restores it.
    public private(set) var history: [(label: String, before: PhotoDocument)] = []
    public private(set) var revision = 0
    public private(set) var lastTableEdit: TableEditSpec?
    public private(set) var lastIntent: EditIntent?
    private var pending: ClarificationRequest?
    public var liveSpeechSuppressed = true
    /// Every step the executor ran, in order, and the ones that changed the document.
    public private(set) var runs: [EditIntent] = []
    public private(set) var applied: [EditIntent] = []
    public private(set) var verifyCalls = 0
    /// What `liveContextSummary` says about the picture (the Vision scene line).
    public var description: SceneDescription?
    /// The old session (before the scene map was kept across edits): no scene map between an erase and the
    /// next read. Off by default, as the session is now; on, it measures what the rules do without a map.
    public var dropsSceneUntilRead = false

    public init(services: LiveEvalServices, document: PhotoDocument, description: SceneDescription? = nil, language: NormalizedUtterance.Language = .french) {
        self.services = services
        self.document = document
        self.description = description
        executor = PhotoCommandExecutor(services: services, language: language)
    }

    /// The benchmark screenshot of the report: the empty 9 × 5 table, its scene map, no subject.
    public static func benchmark(withValues: Bool = false, strayOne: Bool = false, failingChecks: Set<String> = []) -> LiveEvalEditor {
        let grid = LiveEvalFixtures.benchmark(withValues: withValues)
        let services = LiveEvalServices(grid: grid, scene: LiveEvalFixtures.benchmarkScene(withValues: withValues), failingChecks: failingChecks)
        var document = LiveEvalFixtures.benchmarkDocument()
        if strayOne { document = LiveEvalFixtures.strayOne(in: document) }
        return LiveEvalEditor(services: services, document: document,
                               description: SceneDescription(labels: ["screenshot", "document"], hasText: true, brightness: 0.92, colourfulness: 0.04))
    }

    /// The summer-sale poster: a person, a title, a subtitle, a price.
    public static func poster(failingChecks: Set<String> = []) -> LiveEvalEditor {
        LiveEvalEditor(services: LiveEvalFixtures.posterServices(failingChecks: failingChecks), document: LiveEvalFixtures.posterDocument(),
                        description: SceneDescription(people: 1, faces: 1, labels: ["outdoor", "sky"], hasText: true, brightness: 0.62, colourfulness: 0.4))
    }

    public func setLanguage(_ language: NormalizedUtterance.Language) {
        executor = PhotoCommandExecutor(services: services, language: language)
    }

    // MARK: What the session knows

    /// The table as the session holds it: the grid read once, overlaid with the layers.
    public var table: TableGrid? { services.grid?.overlaying(document.layers) }

    /// The scene map as the session holds it: printed blocks an erase removed are gone (a new text pass
    /// would not read them), the layers are laid over it, and ids carry over from the last map.
    public var scene: SceneMap? {
        guard var map = services.scene else { return nil }
        let erased = (document.baseLayer?.edits.operations ?? []).compactMap { operation -> PSRect? in
            if case .removeObject(let mask) = operation.kind { return mask.boundingBox }
            return nil
        }
        // The old session: an erase dropped the map until the next text pass (this host never reads again).
        if dropsSceneUntilRead, !erased.isEmpty { return nil }
        map.texts.removeAll { block in !block.isLayer && erased.contains { $0.intersection(block.box).area >= block.box.area * 0.5 } }
        return map.overlaying(document.layers)
    }

    public var liveMode: EditorMode { .photo }
    public var liveVersion: Int { revision }
    public var liveIsBusy: Bool { false }
    public var liveProcessingProgress: Double? { nil }
    public var livePendingChoice: LiveChoiceRequest? {
        pending.map { request in
            LiveChoiceRequest(question: request.question, candidates: request.candidates.enumerated().map { .init(id: $0.offset + 1, label: $0.element.spokenDescription) },
                              allowsAll: false)
        }
    }

    public func liveIntentContext() -> IntentContext {
        IntentContext(mode: .photo, currentAdjustments: document.activeAdjustments, pendingClarification: pending, canUndo: !history.isEmpty,
                      preferredLanguage: "fr", table: table, lastTableEdit: lastTableEdit, scene: scene, lastIntent: lastIntent)
    }

    public func liveContextSummary() -> LiveEditorState {
        var state = LiveEditorState(mode: .photo, version: revision)
        state.canvasPixels = document.canvasSize
        state.appliedEdits = Array(history.map(\.label).suffix(12))
        state.adjustments = document.activeAdjustments
        state.canUndo = !history.isEmpty
        state.scene = description
        state.table = table
        state.sceneMap = scene
        state.mediaText = document.layers.compactMap { $0.group == nil ? $0.textElement?.text : nil }
        state.candidates = pending?.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" } ?? []
        state.pendingQuestion = pending?.question
        return state
    }

    // MARK: Running

    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        runs.append(intent)
        let context = liveIntentContext()
        let before = document
        var step = intent
        if intent.action == .chooseCandidate, var pendingIntent = pending?.pendingIntent {
            pendingIntent.id = intent.id
            step = pendingIntent
        }
        let (updated, result) = await executor.execute(intent, on: before, context: context)
        // Undo and revert are the history's, as in the session.
        if result.effects.contains(.undo) { _ = liveUndo(count: 1, redo: false, toOriginal: false) }
        if result.effects.contains(.revert) { _ = liveUndo(count: 1, redo: false, toOriginal: true) }
        var verification: VerificationRequest?
        if result.changedDocument {
            history.append((result.label, before))
            document = updated
            revision += 1
            applied.append(step)
            remember(step)
            verification = EditVerifier.request(for: step, before: before, after: document, result: result, scene: context.scene)
        }
        if case .needsClarification(let request) = result.outcome { pending = request } else if result.outcome.isSuccess { pending = nil }
        return LiveRunResult(outcome: result.outcome, effects: result.effects, verificationRequest: verification)
    }

    public func liveVerify(_ requests: [VerificationRequest]) async -> [VerificationReport] {
        verifyCalls += 1
        return (try? await services.verify(requests, in: document)) ?? []
    }

    /// As the session: the last step, and the table edit whose value "les autres aussi" reuses.
    private func remember(_ intent: EditIntent) {
        guard !intent.action.isMeta else { return }
        lastIntent = intent
        guard LiveTurnRouter.tableActions.contains(intent.action), var spec = intent.table else { return }
        if spec.value == nil {
            spec.value = lastTableEdit?.value
            spec.alternative = spec.alternative ?? lastTableEdit?.alternative
        }
        lastTableEdit = spec
    }

    public func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        guard !redo, !history.isEmpty else { return [] }
        let taken = toOriginal ? history.count : min(count, history.count)
        var labels: [String] = []
        for _ in 0..<taken {
            let entry = history.removeLast()
            document = entry.before
            labels.append(entry.label)
        }
        revision += 1
        return labels
    }

    public func liveCompareBeforeAfter(seconds: Double) {}
    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? { nil }
    public func liveHandleCommand(_ text: String) async -> LiveCommandReply { LiveCommandReply(text: text, isProblem: false, isError: false, language: "fr") }
    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult { LiveRunResult(outcome: .ignored) }
    public func liveCancelProcessing() -> Bool { false }

    // MARK: Reading the result

    /// The Picshop text layers written into table cells.
    public var cellLayers: [Layer] { document.layers.filter { $0.group?.kind == .tableCells } }

    /// Data cells that hold something (printed or a layer), after the overlay.
    public var filledCells: Int { table?.dataCells.filter { $0.state != .empty }.count ?? 0 }

    /// The text of the layer over a 1-based data cell.
    public func cellText(row: Int, column: Int) -> String? {
        guard let cell = table?.cell(dataRow: row, dataColumn: column), let id = cell.layerID else { return nil }
        return document.layer(id: id)?.textElement?.text
    }

    /// Ungrouped text layers (addText, rewritten text).
    public var textLayers: [TextElement] { document.layers.filter { $0.group == nil }.compactMap(\.textElement) }
}
