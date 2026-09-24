#if canImport(SwiftUI) && canImport(PDFKit) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent

/// What Picshop Live reaches in the PDF editor. Live never converses here
/// (canGoLive is false): the orb dictates and typed text runs the local pipeline
/// through liveHandleCommand.
///
/// Phase 0: state is passed through, and every action answers neutrally until
/// the session wiring lands.
extension PDFEditorSession: LiveEditingHost {
    public var liveMode: EditorMode { .pdf }

    public var liveVersion: Int { revision }

    public var liveIsBusy: Bool { isProcessing }

    /// The PDF steps report completion rather than a fraction.
    public var liveProcessingProgress: Double? { nil }

    public var livePendingChoice: LiveChoiceRequest? { nil }

    public func liveIntentContext() -> IntentContext { intentContext }

    public func liveContextSummary() -> LiveEditorState {
        LiveEditorState(mode: .pdf, version: revision)
    }

    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        LiveRunResult(outcome: .ignored)
    }

    public func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        []
    }

    public func liveCompareBeforeAfter(seconds: Double) {}

    /// A page is never sent: PDF has no Live conversation.
    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? {
        nil
    }

    public func liveHandleCommand(_ text: String) async -> LiveCommandReply {
        LiveCommandReply(text: "", isProblem: false, isError: false, language: language.rawValue)
    }

    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult {
        LiveRunResult(outcome: .ignored)
    }

    /// The PDF steps are short and run to the end.
    @discardableResult
    public func liveCancelProcessing() -> Bool {
        false
    }
}
#endif
