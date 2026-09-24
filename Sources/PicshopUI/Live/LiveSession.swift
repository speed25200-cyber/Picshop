#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import PicshopCore
import PicshopIntent

/// Picshop Live in one editor: the conversation's state for the views, and the
/// orchestrator between the microphone, the brains, the voice and the editor
/// session that hosts it. Each editor session creates one in its init.
///
/// Views read the stored mirrors below. Audio levels live only in `meter`, and
/// every property is assigned only when its value changes.
@MainActor
@Observable
public final class LiveSession {
    public let mode: EditorMode
    /// False on PDF: the orb dictates and typed text runs the local pipeline.
    public let canGoLive: Bool
    /// Read only by LiveOrb and its halo.
    public let meter: LiveMeter

    // MARK: Read by views

    public private(set) var state: LiveState = .off
    public private(set) var transcript = LiveTranscript()
    public private(set) var ideas: LiveIdeasState = .loading
    public private(set) var route = LiveRoute()
    public private(set) var isMuted = false
    /// 6 s after a Live, idea or choice edit.
    public private(set) var undoOffer: LiveUndoOffer?
    /// The resting reply capsule: 4 s, 7 s for errors.
    public private(set) var reply: LiveReply?
    /// A problem or info line, in or out of Live.
    public private(set) var notice: LiveNotice?
    /// StudioChrome presents LiveConsentSheet while this is true.
    public private(set) var needsConsent = false
    /// The one-time better-voice card.
    public private(set) var showsVoiceHint = false

    /// A conversation is running (not `.off`, not `.dictating`).
    public var isLive: Bool {
        switch state {
        case .off, .dictating: return false
        case .problem: return isRunning
        case .connecting, .listening, .hearing, .thinking, .speaking, .acting: return true
        }
    }

    /// Passed through from the host, so views reading it here update with the host.
    public var choices: LiveChoiceRequest? {
        host?.livePendingChoice ?? scriptedChoices
    }

    /// The title is stored here; the progress is passed through from the host.
    public var activity: LiveActivity? {
        guard let activityTitle else { return nil }
        return LiveActivity(title: activityTitle, progress: host?.liveProcessingProgress ?? scriptedProgress)
    }

    // MARK: Private state

    /// From start() to end(), whatever `state` shows meanwhile (a problem, for example).
    private var isRunning = false
    private var activityTitle: String?
    /// Previews only: what a host would report.
    private var scriptedChoices: LiveChoiceRequest?
    private var scriptedProgress: Double?
    /// Nil for a preview: no services, no audio.
    private let app: AppEnvironment?
    @ObservationIgnored private weak var host: (any LiveEditingHost)?
    @ObservationIgnored private var isTornDown = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    public convenience init(app: AppEnvironment, mode: EditorMode, canGoLive: Bool) {
        self.init(environment: app, mode: mode, canGoLive: canGoLive)
    }

    private init(environment: AppEnvironment?, mode: EditorMode, canGoLive: Bool) {
        app = environment
        self.mode = mode
        self.canGoLive = canGoLive
        meter = LiveMeter()
    }

    /// Weak. Takes app.voice.onFinalTranscript for dictation.
    public func attach(_ host: any LiveEditingHost) {
        // Phase 0 stub: dictation, ideas and the tool handler arrive in phase 1.
        self.host = host
    }

    /// Ends Live and releases every hook. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        previewTask?.cancel()
        previewTask = nil
    }

    // MARK: Called by views
    // Phase 0 stubs: no-ops until the orchestrator lands.

    /// D5: start, interrupt, send now or bounce, depending on the state.
    public func orbTapped() {}

    /// Orb hold: push-to-talk while off, nothing during Live.
    public func beginDictation() {}

    public func endDictation() {}

    public func start() {}

    public func end() {}

    public func setMuted(_ muted: Bool) {}

    /// A typed Live turn while Live runs; the local pipeline otherwise (D15).
    public func send(text: String) {}

    /// Runs the idea's steps locally, with no model call.
    public func choose(_ idea: LiveIdea) {}

    public func dismiss(_ idea: LiveIdea) {}

    public func choose(_ choice: LiveCandidateChoice) {}

    /// The inline Annuler: undoes the last Live, idea or choice edit.
    public func undoLastAction() {}

    /// The cloud badge's 'Continuer sur l'iPhone'.
    public func continueOnDevice() {}

    public func resolveConsent(granted: Bool, sendImages: Bool) {}

    public func performNoticeAction() {}

    public func dismissVoiceHint() {}

    // MARK: Called by editor sessions

    /// From the host's didChangeHistory(), after every history change.
    public func noteDocumentChanged(label: String?) {}

    /// Scene description, clarification, selection or current clip changed.
    public func noteContextChanged() {}
}

#if DEBUG
extension LiveSession {
    /// A session with no AppEnvironment and no audio, redrawn from `script` about
    /// 30 times a second until it is torn down or released. Previews only.
    static func scripted(mode: EditorMode, script: @escaping @MainActor (_ elapsed: Double) -> LivePreviewFrame) -> LiveSession {
        let session = LiveSession(environment: nil, mode: mode, canGoLive: mode != .pdf)
        session.show(script(0))
        let start = Date()
        session.previewTask = Task { @MainActor [weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled, let session else { return }
                session.show(script(Date().timeIntervalSince(start)))
            }
        }
        return session
    }

    private func show(_ frame: LivePreviewFrame) {
        if state != frame.state { state = frame.state }
        if isRunning != frame.isRunning { isRunning = frame.isRunning }
        if transcript != frame.transcript { transcript = frame.transcript }
        if ideas != frame.ideas { ideas = frame.ideas }
        if scriptedChoices != frame.choices { scriptedChoices = frame.choices }
        if activityTitle != frame.activityTitle { activityTitle = frame.activityTitle }
        if scriptedProgress != frame.progress { scriptedProgress = frame.progress }
        if route != frame.route { route = frame.route }
        if isMuted != frame.isMuted { isMuted = frame.isMuted }
        if undoOffer != frame.undoOffer { undoOffer = frame.undoOffer }
        if reply != frame.reply { reply = frame.reply }
        if notice != frame.notice { notice = frame.notice }
        if meter.input != frame.input { meter.input = frame.input }
        if meter.output != frame.output { meter.output = frame.output }
    }
}
#endif
#endif
