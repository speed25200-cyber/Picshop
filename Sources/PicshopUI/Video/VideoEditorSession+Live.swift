#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent

/// What Picshop Live reaches in the video editor, and the only way it reaches it.
///
/// Phase 0: state is passed through, and every action answers neutrally (nothing
/// runs, nothing is undone, no frame) until the session wiring lands.
extension VideoEditorSession: LiveEditingHost {
    public var liveMode: EditorMode { .video }

    public var liveVersion: Int { revision }

    public var liveIsBusy: Bool { isProcessing }

    public var liveProcessingProgress: Double? { processingProgress }

    public var livePendingChoice: LiveChoiceRequest? { nil }

    public func liveIntentContext() -> IntentContext { intentContext }

    public func liveContextSummary() -> LiveEditorState {
        LiveEditorState(mode: .video, version: revision)
    }

    public func liveRun(_ intent: EditIntent) async -> LiveRunResult {
        LiveRunResult(outcome: .ignored)
    }

    public func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String] {
        []
    }

    public func liveCompareBeforeAfter(seconds: Double) {}

    public func liveSnapshotImage(maxPixel: Int) async -> LiveImage? {
        nil
    }

    public func liveHandleCommand(_ text: String) async -> LiveCommandReply {
        LiveCommandReply(text: "", isProblem: false, isError: false, language: language.rawValue)
    }

    public func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult {
        LiveRunResult(outcome: .ignored)
    }

    @discardableResult
    public func liveCancelProcessing() -> Bool {
        cancelProcessing()
    }

    public func livePausePlayback() {
        player.pause()
    }
}
#endif
