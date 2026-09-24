import Foundation
import PicshopCore

/// The hooks every editor session exposes to Live. The photo, video and PDF
/// sessions implement it; Live never reaches into a session any other way.
@MainActor
public protocol LiveEditingHost: AnyObject {
    var liveMode: EditorMode { get }
    /// == session.revision, bumped by every history change.
    var liveVersion: Int { get }
    /// A heavy step is running.
    var liveIsBusy: Bool { get }
    var liveProcessingProgress: Double? { get }
    /// Observed through the session, so views reading it through LiveSession update.
    var livePendingChoice: LiveChoiceRequest? { get }
    /// True for the whole of a Live session: no toast for liveRun steps, no VoiceController start, no spoken clarification.
    var liveSpeechSuppressed: Bool { get set }
    func liveIntentContext() -> IntentContext
    func liveContextSummary() -> LiveEditorState
    /// The existing run(_:) path, returning what the executor reported.
    func liveRun(_ intent: EditIntent) async -> LiveRunResult
    /// Labels affected; empty = nothing to do.
    func liveUndo(count: Int, redo: Bool, toOriginal: Bool) -> [String]
    func liveCompareBeforeAfter(seconds: Double)
    /// Photo: current render; video: frame at playhead; nil when unavailable.
    func liveSnapshotImage(maxPixel: Int) async -> LiveImage?
    /// The existing handleTranscript pipeline (outside Live).
    func liveHandleCommand(_ text: String) async -> LiveCommandReply
    func liveChooseCandidate(_ choice: LiveCandidateChoice) async -> LiveRunResult
    @discardableResult func liveCancelProcessing() -> Bool
    func livePausePlayback()
}

extension LiveEditingHost {
    public func livePausePlayback() {}

    /// Runs the intents in order through liveRun; stops after failed or needsClarification; later steps are skipped.
    public func execute(steps: [EditIntent]) async -> LiveExecution {
        // Phase 0 stub.
        LiveExecution(steps: [], version: liveVersion, canUndo: false)
    }
}
