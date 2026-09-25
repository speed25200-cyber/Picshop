#if canImport(SwiftUI) && canImport(CoreImage) && canImport(UIKit)
import Foundation
import CoreImage
import PicshopCore
import PicshopIntent
import PicshopImaging

/// What Picshop Live reaches in the photo editor, and the only way it reaches it.
/// Every step goes through the editor's own executor and history, so Undo,
/// the mirrors and the autosave see Live's edits like any other.
extension PhotoEditorSession: LiveEditingHost {
    public var liveMode: EditorMode { .photo }

    public var liveVersion: Int { revision }

    public var liveIsBusy: Bool { isProcessing }

    /// The photo tasks report completion rather than a fraction.
    public var liveProcessingProgress: Double? { nil }

    /// The pending question and its numbered candidates, as Live shows and speaks them: in the
    /// interface's words ("chien (gauche)"), never the detector's English label; a table's rows and
    /// columns by their own names, which are the picture's words.
    public var livePendingChoice: LiveChoiceRequest? {
        guard let request = pendingClarification, !request.candidates.isEmpty else { return nil }
        let names = Self.tableActions.contains(request.pendingIntent.action)
        let candidates = request.candidates.enumerated().map { offset, candidate in
            LiveChoiceRequest.Candidate(id: offset + 1, label: names ? candidate.label : Self.choiceLabel(candidate, french: psPrefersFrench))
        }
        return LiveChoiceRequest(question: LiveSpeechSanitizer.clean(request.question, language: language), candidates: candidates,
                                 allowsAll: candidates.count > 1 && !names)
    }

    /// "chien (gauche)" / "dog (left)": the candidate's label in the interface's language and where it is.
    static func choiceLabel(_ candidate: ObjectCandidate, french: Bool) -> String {
        let label = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let x = candidate.boundingBox.midX
        guard french else {
            let side = x < 0.34 ? "left" : (x > 0.66 ? "right" : "centre")
            return "\(label) (\(side))"
        }
        let name = ObjectVocabulary.frenchName(forLabel: label) ?? ObjectVocabulary.frenchSceneLabel(label)
        let side = x < 0.34 ? "gauche" : (x > 0.66 ? "droite" : "centre")
        return "\(name) (\(side))"
    }

    public func liveIntentContext() -> IntentContext { intentContext }

    public func liveContextSummary() -> LiveEditorState {
        var state = LiveEditorState(mode: .photo, version: revision)
        state.canvasPixels = document.canvasSize
        state.appliedEdits = Array(undoLabels.filter { $0 != "Select" }.suffix(12))
        state.adjustments = document.activeAdjustments
        state.selection = liveSelectionDescription
        if let request = pendingClarification {
            state.pendingQuestion = request.question
            state.candidates = request.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" }
        }
        state.scene = sceneDescription
        // Table cells are in the table lines, not in the text list.
        state.mediaText = document.textLayers.filter { $0.group == nil }.compactMap { $0.textElement?.text }.filter { !$0.isEmpty }
        // The same overlaid table and scene map the intent context carries: the ids and cells the
        // model reads are the ones its steps resolve against.
        state.table = liveTable
        state.sceneMap = liveSceneMap
        state.hasGenerativeEngine = hasGenerativeEngine
        state.canUndo = canUndo
        state.busyTitle = isProcessing && !processingTitle.isEmpty ? processingTitle : nil
        return state
    }

    /// The text layer, the wand or lasso selection, or the object tapped in Magic.
    private var liveSelectionDescription: String? {
        if let mask = selectionMask {
            switch mask.source {
            case .lasso: return "lasso selection"
            case .magicWand: return "magic wand selection"
            default: return "selected region"
            }
        }
        if let group = document.selectedLayer?.group, let row = group.row, let column = group.column {
            return "table cell r\(row) c\(column)"
        }
        if let layer = document.selectedLayer, let text = layer.textElement?.text {
            return "text layer '\(text.prefix(40))'"
        }
        if let layer = document.selectedLayer, layer.isShape { return "shape layer" }
        if let object = magicSelection { return "object '\(object.label)'" }
        return nil
    }

    /// The editor's own run(_:), once a step already running has finished (100 ms
    /// polls, 20 s at most), with no toast and no speech: Live tells it. The result carries the
    /// checks the step deserves; Live batches them into one liveVerify after the run.
    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        var waited = 0.0
        while isProcessing, waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        liveRunDepth += 1
        defer { liveRunDepth -= 1 }
        let step = await runStep(intent)
        return LiveRunResult(outcome: step.outcome, effects: lastEffects, verificationRequest: step.verification)
    }

    /// Act-then-verify: the rendered picture checked against the steps that just applied, one render
    /// and one text pass for all of them; what failed is ringed on the canvas. Empty when it could not
    /// be checked. The handler hands the reports to the model (tool result) or the fast lane (its line).
    public func liveVerify(_ requests: [VerificationRequest]) async -> [VerificationReport] {
        await checkResult(requests)
    }

    public func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        liveRunDepth += 1
        defer { liveRunDepth -= 1 }
        if toOriginal {
            return revert() ? [undoLabels.last ?? "Revert to Original"] : []
        }
        if redo {
            var labels: [String] = []
            for _ in 0..<max(1, count) {
                guard let label = self.redo() else { break }
                labels.append(label)
            }
            return labels
        }
        return undo(steps: max(1, count))
    }

    public func liveCompareBeforeAfter(seconds: Double) {
        compareBeforeAfter(seconds: seconds)
    }

    /// The picture as it is now, rendered without expensive work, flattened on
    /// white and encoded off the main thread; one per revision.
    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? {
        let version = revision
        if let cached = snapshotCache, cached.revision == version,
           max(cached.image.pixelWidth, cached.image.pixelHeight) <= maxPixel { return cached.image }
        guard let renderer else { return nil }
        let options = PhotoRenderer.Options(targetLongestSide: Double(maxPixel), showOriginal: false, allowExpensiveWork: false, isDisplayed: false)
        guard let image = try? await renderer.render(document, options: options) else { return nil }
        let encoded = await Task.detached(priority: .userInitiated) { () -> (data: Data, width: Int, height: Int)? in
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: image.extent)
            return LiveMediaEncoder.jpeg(from: image.composited(over: white), maxPixel: maxPixel)
        }.value
        guard let encoded else { return nil }
        let snapshot = LiveImage(jpeg: encoded.data, pixelWidth: encoded.width, pixelHeight: encoded.height, version: version)
        if version == revision { snapshotCache = (version, snapshot) }
        return snapshot
    }

    /// The local pipeline (outside Live): its reply goes to Live's capsule.
    public func liveHandleCommand(_ text: String) async -> LiveCommandReply {
        if isProcessing {
            return LiveCommandReply(text: L("One moment…"), isProblem: true, isError: false, language: language.rawValue)
        }
        repliesInCapsule = true
        defer { repliesInCapsule = false }
        await handleTranscript(text)
        return LiveCommandReply(text: lastPlan?.reply ?? "", isProblem: lastReplyIsProblem, isError: lastReplyIsError,
                                language: lastPlan?.language ?? language.rawValue)
    }

    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult {
        switch choice {
        case .index(let number): return await liveRun(EditIntent(action: .chooseCandidate, index: number))
        case .all: return await liveRun(EditIntent(action: .chooseCandidate, scope: .all))
        }
    }

    @discardableResult
    public func liveCancelProcessing() -> Bool {
        cancelProcessing()
    }
}

/// The table step running now (`cellWork`), for Live's activity line.
extension PhotoEditorSession: LiveCellWorkReporting {}
#endif
