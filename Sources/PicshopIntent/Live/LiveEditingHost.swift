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
    /// The video plays: its sound is not in the echo canceller's reference, so Live does not hear meanwhile.
    var liveIsPlaying: Bool { get }
    /// Act-then-verify: checks the rendered result against the requests of the steps that just applied
    /// (`LiveRunResult.verificationRequest`), with one render and one text pass for all of them
    /// (`PhotoAIServices.verify`). One report per request, in order; empty when the editor cannot
    /// check (video, PDF) or the check could not run. Never throws, never changes the document.
    func liveVerify(_ requests: [VerificationRequest]) async -> [VerificationReport]
}

extension LiveEditingHost {
    public func livePausePlayback() {}

    public var liveIsPlaying: Bool { false }

    /// Editors that cannot look at their result: nothing is verified.
    public func liveVerify(_ requests: [VerificationRequest]) async -> [VerificationReport] { [] }

    /// Runs the intents in order through liveRun; stops after failed or needsClarification; later steps are skipped.
    public func execute(steps: [EditIntent]) async -> LiveExecution {
        var results: [LiveStepResult] = []
        for (index, intent) in steps.enumerated() {
            let result = LiveStepResult(index: index, intent: intent, run: await liveRun(intent))
            results.append(result)
            if result.stopsTheRun {
                results += steps.indices.dropFirst(index + 1).map { LiveStepResult(index: $0, action: steps[$0].action, status: .skipped) }
                break
            }
        }
        return LiveExecution(steps: results, version: liveVersion, canUndo: liveIntentContext().canUndo)
    }
}

extension LiveStepResult {
    /// What one executor run means to Live: the outcome, plus the needs_user hint and
    /// the spoken sentence the effects carry.
    public init(index: Int, intent: EditIntent, run: LiveRunResult) {
        var needsUser: String?
        var spoken: String?
        for effect in run.effects {
            guard case .message(let message) = effect else { continue }
            switch message {
            case "selectRegion": needsUser = "select_region"
            case "tapToErase": needsUser = "tap_to_erase"
            case "crop": needsUser = "crop_handles"
            default: if message.hasPrefix("speak:") { spoken = String(message.dropFirst("speak:".count)) }
            }
        }
        switch run.outcome {
        case .applied(let label):
            self.init(index: index, action: intent.action, status: .applied, label: label.isEmpty ? intent.summary : label, message: spoken)
        case .info(let message):
            self.init(index: index, action: intent.action, status: needsUser == nil ? .info : .needsUser, message: spoken ?? message, needsUser: needsUser)
        case .needsClarification(let request):
            self.init(index: index, action: intent.action, status: .needsClarification, message: request.question,
                      candidates: request.candidates.map(\.spokenDescription))
        case .failed(let message):
            self.init(index: index, action: intent.action, status: .failed, message: message)
        case .ignored:
            self.init(index: index, action: intent.action, status: .ignored)
        }
        // The machine channel (D10): the reason code and the table report, never spoken.
        reason = ExecutionReason(effects: run.effects)
        report = TableEditReport(effects: run.effects)
    }

    /// failed and needs_clarification end a run: later steps are skipped.
    public var stopsTheRun: Bool { status == .failed || status == .needsClarification }
}
