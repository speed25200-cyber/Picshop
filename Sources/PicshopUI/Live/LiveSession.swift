#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import UIKit
import PicshopCore
import PicshopIntent
import PicshopSpeech

/// Picshop Live in one editor: the conversation's state for the views, and the
/// orchestrator between the microphone, the brains, the voice and the editor
/// session that hosts it. Each editor session creates one in its init.
///
/// Views read the stored mirrors below. Audio levels live only in `meter`, and
/// every property is assigned only when its value changes. The pure turn-taking
/// reducer (LiveTurnMachine) decides; this class feeds it events and runs its effects.
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
        guard isRunning else { return false }
        switch state {
        case .off, .dictating: return false
        case .connecting, .listening, .hearing, .thinking, .speaking, .acting, .problem: return true
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

    // MARK: Observed internals

    /// From start() to end(), whatever `state` shows meanwhile (a problem, a pause).
    private(set) var isRunning = false
    private(set) var activityTitle: String?
    /// Previews only: what a host would report.
    private var scriptedChoices: LiveChoiceRequest?
    private var scriptedProgress: Double?

    // MARK: Runtime (not observed)

    /// Nil for a preview: no services, no audio.
    @ObservationIgnored let app: AppEnvironment?
    @ObservationIgnored weak var host: (any LiveEditingHost)?
    @ObservationIgnored var toolHandler: EditorToolHandler?
    @ObservationIgnored var toolProxy: LiveToolProxy?
    @ObservationIgnored var machine: LiveTurnMachine
    @ObservationIgnored var accumulator = TranscriptAccumulator()
    @ObservationIgnored var latency = LatencyTracker()
    @ObservationIgnored var selector = BrainSelector()
    @ObservationIgnored let clock = SystemLiveClock()
    @ObservationIgnored var audio: LiveAudioStack?
    @ObservationIgnored var captionOnly: CaptionOnlySpeaker?
    @ObservationIgnored var claudeBrain: ClaudeLiveBrain?
    /// Read once from the Keychain at Live start, for the pre-connect. Never logged.
    @ObservationIgnored var claudeKey: String?
    @ObservationIgnored var claudeTransport: (any ClaudeTransport)?
    @ObservationIgnored var onDeviceBrain: (any LiveBrain)?
    @ObservationIgnored var onDeviceAvailable = false
    @ObservationIgnored var localBrain: LocalLiveBrain?
    /// The brain that answers the current turn.
    @ObservationIgnored var currentKind: LiveBrainKind = .local
    /// The cloud badge's 'Continuer sur l'iPhone', for this editor.
    @ObservationIgnored var claudeForcedOff = false

    @ObservationIgnored var isTornDown = false
    @ObservationIgnored var isStarting = false
    @ObservationIgnored var isConnecting = false
    @ObservationIgnored var isDictating = false
    /// Hold (push-to-talk) or tap (PDF) dictation.
    @ObservationIgnored var dictationIsHold = true
    @ObservationIgnored var dictationStopRequested = false
    /// A command outside Live: thinking, then acting, then the reply capsule.
    @ObservationIgnored var restingPhase: LiveState?
    @ObservationIgnored var problemState: LiveProblem?
    @ObservationIgnored var problemToken = 0
    @ObservationIgnored var recognitionAvailable = true
    @ObservationIgnored var microphoneAskedThisTime = false

    @ObservationIgnored var brainTask: Task<Void, Never>?
    @ObservationIgnored var brainTurnID: Int?
    @ObservationIgnored var brainTurnKind: LiveUserTurn.Kind?
    /// The brain streaming the current turn, for brain.interrupt.
    @ObservationIgnored var activeBrainKind: LiveBrainKind?
    /// The turn that brain answers: a cancelled local-lane turn leaves its history alone.
    @ObservationIgnored var activeBrainTurnID: Int?
    @ObservationIgnored var brainProducedOutput = false
    /// brain.interrupt for a cancelled turn: the next turn starts after it.
    @ObservationIgnored var pendingInterrupt: Task<Void, Never>?
    /// "Contrast +15 (manual)", "tapped idea 'Portrait doux' -> applied": drained into the next brain turn.
    @ObservationIgnored var sinceLastReply: [String] = []
    @ObservationIgnored var interruptedAfter: String?
    @ObservationIgnored var pendingTypedText: String?
    @ObservationIgnored var responseChunks: [String] = []
    @ObservationIgnored var lastResponseChunks: [String] = []
    @ObservationIgnored var replyLanguage: NormalizedUtterance.Language = .french
    @ObservationIgnored var lastFiller: String?
    /// > 0 while Live itself changes the document (tool, idea, choice, undo).
    @ObservationIgnored var liveEditDepth = 0
    @ObservationIgnored var backgroundJobs = 0
    /// Bumped at every Live start: a tool from an earlier conversation never reaches this one's reducer.
    @ObservationIgnored var liveGeneration = 0
    @ObservationIgnored var firstAudioMarked: Set<Int> = []
    /// The video plays: Live does not hear (the reducer is muted, `isMuted` stays the user's).
    @ObservationIgnored var playbackHolds = false
    /// The turn whose own steps started playback ("lecture"): its reply does not pause it again.
    @ObservationIgnored var playbackTurn: Int?

    @ObservationIgnored var heuristicIdeas: [LiveIdea] = []
    @ObservationIgnored var brainIdeas: [LiveIdea] = []
    /// Per document: an editor session owns one LiveSession.
    @ObservationIgnored var dismissedIdeas: Set<String> = []
    @ObservationIgnored var ideasRefreshTask: Task<Void, Never>?
    @ObservationIgnored var ideasDeadlineTask: Task<Void, Never>?
    @ObservationIgnored var ideasReady = false

    @ObservationIgnored var snapshotCache: (key: String, image: LiveImage?)?
    @ObservationIgnored var snapshotTask: (key: String, task: Task<LiveImage?, Never>)?
    @ObservationIgnored var contextGeneration = 0
    @ObservationIgnored var cachedIntentContext: (key: String, context: IntentContext)?

    @ObservationIgnored var pendingCaption: (snapshot: TranscriptSnapshot, paused: Bool)?
    @ObservationIgnored var lastCaptionPublish: Double = 0
    @ObservationIgnored var loopTask: Task<Void, Never>?
    @ObservationIgnored var dictationTask: Task<Void, Never>?
    @ObservationIgnored var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored var eventQueue: [LiveEvent] = []
    @ObservationIgnored var isFeeding = false
    @ObservationIgnored var serial = 0

    @ObservationIgnored var floorDB: Double = -60
    @ObservationIgnored var levelDB: Double = -100
    @ObservationIgnored var lastVoicedAt: Double?
    @ObservationIgnored var lastLoopTick: Double = 0
    @ObservationIgnored var lastMeterPublish: Double = 0
    @ObservationIgnored var lastDebugPush: Double = 0
    @ObservationIgnored var previewTask: Task<Void, Never>?

    public convenience init(app: AppEnvironment, mode: EditorMode, canGoLive: Bool) {
        self.init(environment: app, mode: mode, canGoLive: canGoLive)
    }

    private init(environment: AppEnvironment?, mode: EditorMode, canGoLive: Bool) {
        app = environment
        self.mode = mode
        self.canGoLive = canGoLive
        meter = LiveMeter()
        let bargeIn: BargeInMode = (environment?.settings.liveBargeIn ?? false) ? .full : .safe
        let turnTaking = environment != nil && UIAccessibility.isVoiceOverRunning
        machine = LiveTurnMachine(options: .init(bargeInOnSpeaker: bargeIn, turnTaking: turnTaking))
        if let environment {
            route = LiveRoute(brain: Self.localBadge(environment))
        }
    }

    /// Weak. app.voice.onFinalTranscript is taken for dictation when dictation starts
    /// (beginDictation, or the orb on PDF), so a session SwiftUI throws away never keeps it.
    public func attach(_ host: any LiveEditingHost) {
        guard !isTornDown else { return }
        self.host = host
        guard app != nil else { return }
        // Warms the Claude key's Keychain read before the first orb tap.
        _ = LiveServices.shared.keyStore
        let handler = EditorToolHandler(
            host: host,
            onIdeas: { [weak self] ideas in self?.receiveBrainIdeas(ideas) },
            onJobFinished: { [weak self] execution in self?.jobFinished(execution) }
        )
        toolHandler = handler
        toolProxy = LiveToolProxy(handler: handler, session: self)
        refreshIdeas(immediately: true)
    }

    /// Ends Live and releases every hook. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        end()
        cancelDictation()
        isTornDown = true
        previewTask?.cancel()
        previewTask = nil
        ideasRefreshTask?.cancel()
        ideasDeadlineTask?.cancel()
        snapshotTask?.task.cancel()
        snapshotTask = nil
        releaseVoice()
        host?.liveSpeechSuppressed = false
        toolHandler = nil
        toolProxy = nil
    }

    // MARK: Called by views

    /// D5: start, interrupt, send now or bounce, depending on the state.
    public func orbTapped() {
        guard !isTornDown else { return }
        if isDictating {
            endDictation()
            return
        }
        guard canGoLive else {
            beginDictation(hold: false)
            return
        }
        guard isRunning else {
            start()
            return
        }
        switch state {
        case .off:
            // Paused (Control Center, a call past its window): start again.
            end()
            start()
        case .connecting:
            break
        default:
            // Over a playing video Live does not hear: the orb pauses it, and Live listens.
            if playbackHolds { host?.livePausePlayback() }
            feed(.orbTapped(at: clock.now()))
        }
    }

    /// Orb hold: push-to-talk while off, nothing during Live.
    public func beginDictation() {
        beginDictation(hold: true)
    }

    public func endDictation() {
        guard isDictating, let app else { return }
        dictationStopRequested = true
        app.voice.stop()
    }

    public func start() {
        guard !isTornDown, app != nil else { return }
        guard canGoLive else {
            if isDictating { endDictation() } else { beginDictation(hold: false) }
            return
        }
        guard !isRunning, !isStarting else { return }
        Task { await self.beginLive(consentResolved: false) }
    }

    public func end() {
        guard isRunning || isStarting else { return }
        stopLive(reason: "end")
    }

    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        guard isRunning else { return }
        feed(.mute(muted || playbackHolds))
        debugDecision(muted ? "microphone muted" : "microphone unmuted")
    }

    /// A typed Live turn while Live runs; the local pipeline otherwise (D15).
    public func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTornDown else { return }
        if isLive, state != .connecting {
            pendingTypedText = trimmed
            feed(.typed(trimmed, at: clock.now()))
        } else {
            runRestingCommand(trimmed)
        }
    }

    /// Runs the idea's steps locally, with no model call.
    public func choose(_ idea: LiveIdea) {
        runIdea(idea)
    }

    public func dismiss(_ idea: LiveIdea) {
        dismissIdea(idea)
    }

    public func choose(_ choice: LiveCandidateChoice) {
        runChoice(choice)
    }

    /// The choice row's close chip: drops the pending question.
    public func dismissChoice() {
        cancelChoice()
    }

    /// The inline Annuler: undoes the last Live, idea or choice edit.
    public func undoLastAction() {
        undoLast()
    }

    /// The cloud badge's 'Continuer sur l'iPhone'.
    public func continueOnDevice() {
        guard !claudeForcedOff else { return }
        claudeForcedOff = true
        debugDecision("Claude turned off for this editor (badge)")
        if isRunning { assignRoute(brain: badge(for: chooseBrain(excluding: [.claude]))) }
    }

    public func resolveConsent(granted: Bool, sendImages: Bool) {
        guard needsConsent, let app else { return }
        needsConsent = false
        app.settings.liveConsentVersion = granted ? AppSettings.liveConsentCurrent : -AppSettings.liveConsentCurrent
        app.settings.liveSendsImages = granted && sendImages
        Task { await self.beginLive(consentResolved: true) }
    }

    public func performNoticeAction() {
        guard let current = notice else { return }
        assignNotice(nil)
        switch current.action {
        case .none:
            break
        case .allowMicrophone:
            Task {
                let granted = await VoiceController.requestPermissions()
                if granted { self.start() } else { self.showNotice(self.problemText(.noMicrophone), isProblem: true, action: .openSettings) }
            }
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    public func dismissVoiceHint() {
        if showsVoiceHint { showsVoiceHint = false }
    }

    // MARK: Called by editor sessions

    /// From the host's didChangeHistory(), after every history change.
    public func noteDocumentChanged(label: String?) {
        documentChanged(label: label)
    }

    /// Scene description, clarification, selection or current clip changed.
    public func noteContextChanged() {
        contextChanged()
    }

    // MARK: Publishing (the only writers of the published mirrors)

    /// The LiveState the views see, from the reducer's phase and Live's own flags (contract 7.6).
    func computedState() -> LiveState {
        if isDictating { return .dictating }
        if let problemState { return .problem(problemState) }
        guard isRunning else { return restingPhase ?? .off }
        if isConnecting { return .connecting }
        switch machine.state.phase {
        case .idle: return .off
        case .listening: return .listening
        case .userSpeaking, .interrupted: return .hearing
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .acting: return .acting
        }
    }

    func publishState() {
        let next = computedState()
        if state != next { state = next }
    }

    func assignRunning(_ running: Bool) {
        if isRunning != running { isRunning = running }
    }

    func assignTranscript(_ next: LiveTranscript) {
        if transcript != next { transcript = next }
    }

    func assignIdeas(_ next: LiveIdeasState) {
        if ideas != next { ideas = next }
    }

    func assignRoute(_ next: LiveRoute) {
        if route != next { route = next }
    }

    func assignRoute(brain: LiveRoute.Brain) {
        var next = route
        next.brain = brain
        assignRoute(next)
    }

    func assignMuted(_ muted: Bool) {
        if isMuted != muted { isMuted = muted }
    }

    func assignUndoOffer(_ next: LiveUndoOffer?) {
        if undoOffer != next { undoOffer = next }
    }

    func assignReply(_ next: LiveReply?) {
        if reply != next { reply = next }
    }

    func assignNotice(_ next: LiveNotice?) {
        if notice != next { notice = next }
    }

    func assignNeedsConsent(_ next: Bool) {
        if needsConsent != next { needsConsent = next }
    }

    func assignShowsVoiceHint(_ next: Bool) {
        if showsVoiceHint != next { showsVoiceHint = next }
    }

    func assignActivityTitle(_ next: String?) {
        if activityTitle != next { activityTitle = next }
    }

    /// Commandes appears only when the rule grammar is the only brain (D9).
    static func localBadge(_ app: AppEnvironment) -> LiveRoute.Brain {
        app.activeEngine == .rules ? .commands : .onDevice
    }
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
        if needsConsent != frame.needsConsent { needsConsent = frame.needsConsent }
        if showsVoiceHint != frame.showsVoiceHint { showsVoiceHint = frame.showsVoiceHint }
        if meter.input != frame.input { meter.input = frame.input }
        if meter.output != frame.output { meter.output = frame.output }
    }
}
#endif
#endif
