#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent

/// What Picshop Live reaches in the PDF editor. Live never converses here
/// (canGoLive is false): the orb dictates and typed text runs the local
/// pipeline through liveHandleCommand, whose reply shows in Live's capsule.
/// Chips and choices run through the editor's own executor and history.
extension PDFEditorSession: LiveEditingHost {
    public var liveMode: EditorMode { .pdf }

    public var liveVersion: Int { revision }

    public var liveIsBusy: Bool { isProcessing }

    /// The PDF steps report completion rather than a fraction.
    public var liveProcessingProgress: Double? { nil }

    /// The pending question and its numbered candidates, for the choice chips.
    public var livePendingChoice: LiveChoiceRequest? {
        guard let request = pendingClarification, !request.candidates.isEmpty else { return nil }
        let candidates = request.candidates.enumerated().map { LiveChoiceRequest.Candidate(id: $0.offset + 1, label: $0.element.spokenDescription) }
        return LiveChoiceRequest(question: request.question, candidates: candidates, allowsAll: candidates.count > 1)
    }

    public func liveIntentContext() -> IntentContext { intentContext }

    public func liveContextSummary() -> LiveEditorState {
        var state = LiveEditorState(mode: .pdf, version: revision)
        if document.pages.indices.contains(document.currentPageIndex) {
            state.canvasPixels = document.pages[document.currentPageIndex].size
        }
        state.appliedEdits = Array(undoLabels.suffix(12))
        state.selection = "page \(document.currentPageIndex + 1) of \(document.pageCount)"
        if let request = pendingClarification {
            state.pendingQuestion = request.question
            state.candidates = request.candidates.enumerated().map { "\($0.offset + 1): \($0.element.spokenDescription)" }
        }
        state.canUndo = canUndo
        state.busyTitle = isProcessing && !processingTitle.isEmpty ? processingTitle : nil
        return state
    }

    /// The editor's own run(_:), once a step already running has finished (100 ms
    /// polls, 20 s at most), with no toast and no speech.
    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        var waited = 0.0
        while isProcessing, waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        liveRunDepth += 1
        defer { liveRunDepth -= 1 }
        let outcome = await run(intent)
        return LiveRunResult(outcome: outcome, effects: lastEffects)
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

    /// A document has no before-and-after view.
    public func liveCompareBeforeAfter(seconds: Double) {}

    /// A page is never sent: PDF has no Live conversation.
    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? {
        nil
    }

    /// The local pipeline: its reply goes to Live's capsule.
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

    /// A numbered chip under the question: the pending step, with that candidate.
    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult {
        let result: LiveRunResult
        switch choice {
        case .index(let number): result = await liveRun(EditIntent(action: .chooseCandidate, index: number))
        case .all: result = await liveRun(EditIntent(action: .chooseCandidate, scope: .all))
        }
        // The question is answered either way: the chips go.
        if case .needsClarification = result.outcome {} else { pendingClarification = nil }
        return result
    }

    /// The PDF steps are short and run to the end.
    @discardableResult
    public func liveCancelProcessing() -> Bool {
        false
    }
}
#endif
