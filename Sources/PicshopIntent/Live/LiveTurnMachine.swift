import Foundation
import PicshopCore

// The turn-taking reducer of a Live conversation: deterministic, with time
// injected through the events, so every rule is a Linux unit test.

public enum EchoRisk: Sendable, Equatable { case low, normal, high }

public enum BargeInMode: Sendable, Equatable { case full, safe }

/// The reducer's internal phase. LiveSession maps it onto LiveState.
public enum LivePhase: String, Sendable { case idle, listening, userSpeaking, thinking, speaking, acting, interrupted }

public enum TurnSignal: Sendable, Equatable { case firstOutput, toolStarted, toolFinished(changedDocument: Bool), ended(endsWithQuestion: Bool), failed }

public enum SpeakerSignal: Sendable, Equatable { case chunkQueued, chunkStarted(String), chunkFinished, drained }

public enum Earcon: String, Sendable { case open, close, commit, applied, error }

public enum LiveHaptic: Sendable, Equatable { case liveStart, liveEnd, bargeIn, actionStarted, actionApplied, problem }

public enum LiveEvent: Sendable, Equatable {
    case start(at: Double), stop
    case appWillResignActive(at: Double), appDidBecomeActive(at: Double), appDidEnterBackground
    case audioInterruption(began: Bool, shouldResume: Bool, at: Double)
    case routeChanged(EchoRisk)
    case mute(Bool)
    case audio(AudioFrameFeatures)
    case transcript(TranscriptSnapshot, grammar: EditPlan?, at: Double)
    /// A recognizer's final (the simple voice path, which endpoints on its own).
    case utterance(String, at: Double)
    case tick(Double)
    case orbTapped(at: Double)
    case typed(String, at: Double)
    case ideaTapped(at: Double)
    case turn(Int, TurnSignal, at: Double)
    case speaker(Int, SpeakerSignal, at: Double)
}

public enum LiveEffect: Sendable, Equatable {
    case openMic, closeMic, setInputMuted(Bool)
    case beginUserTurn(at: Double)
    case showCaption(TranscriptSnapshot, paused: Bool)
    case commitTurn(Int, text: String)
    case cancelTurn(Int, spokenText: String)
    case stopSpeaking(fadeMs: Int)
    case pausePlayback
    case earcon(Earcon)
    case haptic(LiveHaptic)
    case autoPaused
    /// The committed turn got no answer within `thinkingDeadline`: the session cancels it and says so.
    case turnTimedOut(Int)
    /// A line queued but never started, or a chunk that never drained: the session switches voices.
    case speakerStuck
}

public struct LiveTurnState: Sendable, Equatable {
    public fileprivate(set) var phase: LivePhase
    /// Idle because the app went inactive or audio was interrupted; can resume.
    public fileprivate(set) var paused: Bool
    public fileprivate(set) var muted: Bool
    /// Generation: bumped on commit, barge-in and stop. Signals for another turn are stale.
    public fileprivate(set) var turn: Int
    public fileprivate(set) var caption: TranscriptSnapshot
    public fileprivate(set) var brainOpen: Bool
    public fileprivate(set) var toolsRunning: Int
    public fileprivate(set) var chunksQueued: Int
    public fileprivate(set) var spokenText: String
    public fileprivate(set) var echoRisk: EchoRisk
    public fileprivate(set) var effectiveBargeIn: BargeInMode
    // Timing and bookkeeping, readable for tests and the debug screen.
    /// A committed turn whose brain has not ended yet.
    public fileprivate(set) var turnInFlight = false
    public fileprivate(set) var speechStartedAt: Double?
    public fileprivate(set) var lastVoiceAt: Double?
    public fileprivate(set) var lastTextChangeAt: Double?
    public fileprivate(set) var listeningSince: Double?
    public fileprivate(set) var speakingSince: Double?
    public fileprivate(set) var pausedAt: Double?
    /// The caption shows the breathing ellipsis: silent, not committed.
    public fileprivate(set) var captionPaused = false
    public fileprivate(set) var lastAssistantEndsWithQuestion = false
    /// A short "oui" said over the assistant, committed if the reply ends with a question.
    public fileprivate(set) var pendingBackchannel: String?
    /// Words of a turn cancelled before any output, prefixed to the next commit.
    public fileprivate(set) var carryOver: String?
    public fileprivate(set) var committedText: String?
    public fileprivate(set) var turnHadOutput = false
    /// The microphone is muted for turn-taking (VoiceOver) while the assistant speaks.
    public fileprivate(set) var turnTakingMuted = false
    /// The latest end-of-turn or barge-in decision, with its reason, for diagnostics.
    public fileprivate(set) var lastDecision: String?
    // Deadlines (see LiveTurnMachine's statics).
    /// When the turn in flight was committed.
    public fileprivate(set) var committedAt: Double?
    /// When the first line still waiting to start was queued.
    public fileprivate(set) var queuedAt: Double?
    public fileprivate(set) var lastChunkStartedAt: Double?
    public fileprivate(set) var lastChunkWords = 0
    /// Hearing is ignored until then, after the voice drained on a route with echo.
    public fileprivate(set) var echoGateUntil: Double?

    init(effectiveBargeIn: BargeInMode) {
        phase = .idle
        paused = false
        muted = false
        turn = 0
        caption = TranscriptSnapshot()
        brainOpen = false
        toolsRunning = 0
        chunksQueued = 0
        spokenText = ""
        echoRisk = .normal
        self.effectiveBargeIn = effectiveBargeIn
    }
}

/// The turn-taking reducer. Pure: every event carries its time, every
/// consequence is an effect for the session to perform.
public struct LiveTurnMachine: Sendable {
    public struct Options: Sendable, Equatable {
        /// .full only when AppSettings.liveBargeIn.
        public var bargeInOnSpeaker: BargeInMode
        /// Mic muted while the assistant speaks (VoiceOver, or the half-duplex simple path).
        public var turnTaking: Bool
        public var autoPauseAfter: Double = 90
        /// The recognizer decides the end of each utterance (`.utterance`); the reducer only caps it.
        public var externalEndpointing = false

        public init(bargeInOnSpeaker: BargeInMode, turnTaking: Bool, externalEndpointing: Bool = false) {
            self.bargeInOnSpeaker = bargeInOnSpeaker
            self.turnTaking = turnTaking
            self.externalEndpointing = externalEndpointing
        }
    }

    public private(set) var state: LiveTurnState
    private var options: Options
    private var eot: EndOfTurnDetector
    private var vad: VoiceActivityDetector
    private var bargeIn: BargeInPolicy
    private var grammar: EditPlan?
    /// The last sign of life of the turn in flight (commit, output, a tool, the voice): the thinking deadline counts from it.
    private var progressAt: Double?

    /// Resuming after the app comes back is allowed within this many seconds.
    static let resumeWindow = 60.0
    /// Silence with fewer than 2 recognized characters drops the turn (a cough).
    static let noiseDropAfter = 2.5
    static let captionPauseAfter = 0.35
    static let transcriptSilenceLag = 0.45
    static let preRoll = 0.3

    // Deadlines: no state lasts forever.
    /// Hearing with fewer than 2 recognized characters ends after this many seconds, whatever the VAD says.
    public static let emptyHearingCap = 4.0
    /// With external endpointing, an utterance with no final ends after this many seconds.
    public static let externalEndpointCap = 25.0
    /// A committed turn with no brain answer ends with `.turnTimedOut`.
    public static let thinkingDeadline = 15.0
    /// A queued line that never started ends with `.speakerStuck`.
    public static let queuedLineDeadline = 4.0
    /// Hearing stays closed this long after the voice drained, except on headphones.
    public static let echoTail = 0.6

    /// How long a started chunk of `words` words may take to drain: 3 + words/1.8 s.
    public static func drainDeadline(words: Int) -> Double {
        3 + Double(max(0, words)) / 1.8
    }

    public init(options: Options, eot: EndOfTurnDetector = .init(), vad: VoiceActivityDetector = .init(), bargeIn: BargeInPolicy = .init()) {
        self.options = options
        self.eot = eot
        self.vad = vad
        self.bargeIn = bargeIn
        state = LiveTurnState(effectiveBargeIn: options.bargeInOnSpeaker)
    }

    public mutating func setOptions(_ options: Options) {
        self.options = options
        updateBargeInMode()
    }

    /// Something the assistant said outside the chunk signals (a filler line), for the echo guard.
    public mutating func noteAssistantSpoke(_ text: String, at: Double) {
        bargeIn.noteSpoken(text, at: at)
    }

    public var noiseFloorDB: Float { vad.noiseFloorDB }

    public mutating func handle(_ event: LiveEvent) -> [LiveEffect] {
        switch event {
        case .start(let time): return start(at: time)
        case .stop, .appDidEnterBackground: return stop()
        case .appWillResignActive(let time): return pause(at: time)
        case .appDidBecomeActive(let time): return resume(at: time, allowed: state.pausedAt.map { time - $0 <= Self.resumeWindow } ?? false)
        case .audioInterruption(let began, let shouldResume, let time):
            if began { return pause(at: time) }
            return shouldResume ? resume(at: time, allowed: true) : []
        case .routeChanged(let risk):
            state.echoRisk = risk
            bargeIn.echoRisk = risk
            updateBargeInMode()
            return []
        case .mute(let muted): return mute(muted)
        case .audio(let frame): return audio(frame)
        case .transcript(let snapshot, let plan, let time): return transcript(snapshot, plan: plan, at: time)
        case .utterance(let text, let time): return utterance(text, at: time)
        case .tick(let time): return tick(time)
        case .orbTapped(let time): return orbTapped(at: time)
        case .typed(let text, let time): return typed(text, at: time)
        case .ideaTapped(let time): return ideaTapped(at: time)
        case .turn(let id, let signal, let time): return turnSignal(id, signal, at: time)
        case .speaker(let id, let signal, let time): return speakerSignal(id, signal, at: time)
        }
    }

    // MARK: Lifecycle

    private mutating func start(at time: Double) -> [LiveEffect] {
        guard state.phase == .idle else { return [] }
        state.paused = false
        state.pausedAt = nil
        state.muted = false
        state.phase = .listening
        state.listeningSince = time
        state.toolsRunning = 0
        state.echoGateUntil = nil
        resetVoiceWatch()
        resetUserTurn()
        return [.openMic, .beginUserTurn(at: time), .earcon(.open), .haptic(.liveStart)]
    }

    private mutating func stop() -> [LiveEffect] {
        // A tool still running no longer shows (also after an auto-pause, already idle).
        state.toolsRunning = 0
        guard state.phase != .idle || state.paused else { return [] }
        var effects = cancelResponse(fadeMs: 0)
        state.phase = .idle
        state.paused = false
        state.pausedAt = nil
        state.echoGateUntil = nil
        resetUserTurn()
        effects += [.closeMic, .earcon(.close), .haptic(.liveEnd)]
        return effects
    }

    private mutating func pause(at time: Double) -> [LiveEffect] {
        guard state.phase != .idle else { return [] }
        var effects = cancelResponse(fadeMs: 0)
        state.phase = .idle
        state.paused = true
        state.pausedAt = time
        state.echoGateUntil = nil
        resetUserTurn()
        effects.append(.closeMic)
        if !effects.contains(.stopSpeaking(fadeMs: 0)) { effects.insert(.stopSpeaking(fadeMs: 0), at: 0) }
        return effects
    }

    private mutating func resume(at time: Double, allowed: Bool) -> [LiveEffect] {
        guard state.phase == .idle, state.paused else { return [] }
        state.paused = false
        state.pausedAt = nil
        guard allowed else { return [.autoPaused] }
        state.phase = .listening
        state.listeningSince = time
        resetUserTurn()
        var effects: [LiveEffect] = [.openMic, .beginUserTurn(at: time)]
        if state.muted { effects.append(.setInputMuted(true)) }
        return effects
    }

    private mutating func mute(_ muted: Bool) -> [LiveEffect] {
        guard state.muted != muted else { return [] }
        state.muted = muted
        var effects: [LiveEffect] = [.setInputMuted(muted || state.turnTakingMuted)]
        if muted, state.phase == .userSpeaking {
            state.phase = .listening
            resetUserTurn()
            effects.append(.showCaption(TranscriptSnapshot(), paused: false))
        }
        return effects
    }

    // MARK: Hearing

    private var hearingIgnored: Bool { state.phase == .idle || state.muted || state.turnTakingMuted }

    private var audioActive: Bool { state.speakingSince != nil || state.chunksQueued > 0 }

    /// Right after the voice drained on a route with echo, what is heard is its tail.
    private func echoGated(_ time: Double) -> Bool {
        guard let gate = state.echoGateUntil else { return false }
        return time < gate
    }

    /// Energy only starts hearing. It never cancels a reply: thinking, acting and the
    /// greeting ignore it, and while the voice plays (full barge-in) it only re-weighs
    /// words already recognized.
    private mutating func audio(_ frame: AudioFrameFeatures) -> [LiveEffect] {
        guard !hearingIgnored, !echoGated(frame.time) else { return [] }
        let event = vad.process(frame, assistantSpeaking: state.phase == .speaking)
        if vad.isSpeech, let voiced = vad.lastVoicedAt { state.lastVoiceAt = voiced }
        let time = frame.time
        switch state.phase {
        case .listening:
            if case .speechStart(let start) = event { return beginHearing(at: start) }
        case .userSpeaking:
            if case .speechStart(let start) = event, state.speechStartedAt == nil { state.speechStartedAt = start }
        case .speaking, .acting:
            guard vad.isSpeech, audioActive, state.effectiveBargeIn == .full, !state.caption.text.isEmpty else { return [] }
            return evaluateBargeIn(at: time)
        case .thinking, .idle, .interrupted:
            break
        }
        return []
    }

    private mutating func transcript(_ snapshot: TranscriptSnapshot, plan: EditPlan?, at time: Double) -> [LiveEffect] {
        guard !hearingIgnored, !echoGated(time) else { return [] }
        grammar = plan
        let changed = snapshot != state.caption
        switch state.phase {
        case .listening:
            guard !snapshot.text.isEmpty else { return [] }
            state.caption = snapshot
            state.lastTextChangeAt = time
            return beginHearing(at: time)
        case .userSpeaking:
            guard changed else { return [] }
            state.caption = snapshot
            state.lastTextChangeAt = time
            state.captionPaused = false
            return [.showCaption(snapshot, paused: false)]
        case .thinking:
            // A late or re-emitted result of the committed words is not the user talking again.
            guard !snapshot.text.isEmpty, hasNewWords(snapshot.text) || isStopWord(snapshot.text, at: time) else { return [] }
            state.caption = snapshot
            return interruptByVoice(at: time, reason: "words while thinking")
        case .speaking, .acting:
            guard !snapshot.text.isEmpty else { return [] }
            if !audioActive {
                guard hasNewWords(snapshot.text) || isStopWord(snapshot.text, at: time) else { return [] }
                state.caption = snapshot
                return interruptByVoice(at: time, reason: "words while acting")
            }
            state.caption = snapshot
            if state.effectiveBargeIn == .full { return evaluateBargeIn(at: time) }
            // Safe mode on the loudspeaker: only a stop word interrupts; nothing else is shown or committed.
            if BargeInPolicy.containsStopPhrase(snapshot.text), !bargeIn.isEcho(BargeInPolicy.tokens(snapshot.text), now: time, threshold: 1) {
                return interruptByVoice(at: time, reason: "stop word (safe mode)")
            }
            return []
        case .idle, .interrupted:
            return []
        }
    }

    /// A recognizer's final: commit it. Under 2 characters (a cough), listen again.
    /// While a reply is on its way, only new words count: a late final of the committed words is ignored.
    private mutating func utterance(_ text: String, at time: Double) -> [LiveEffect] {
        guard !hearingIgnored, !echoGated(time) else { return [] }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state.phase {
        case .listening, .userSpeaking:
            guard words.count >= 2 else {
                state.phase = .listening
                state.listeningSince = time
                resetUserTurn()
                state.lastDecision = "dropped: final of \(words.count) characters"
                return [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: time), .openMic]
            }
        case .thinking, .speaking, .acting:
            guard hasNewWords(words) || isStopWord(words, at: time) else { return [] }
            // Said more before any answer: the new words continue the turn, as with a voice interruption.
            if state.turnInFlight, !state.turnHadOutput, let committed = state.committedText, !committed.isEmpty { state.carryOver = committed }
        case .idle, .interrupted:
            return []
        }
        let effects = cancelResponse(fadeMs: 60)
        state.lastDecision = "commit: recognizer final"
        return effects + commit(words, at: time)
    }

    /// At least 2 tokens that are not in the committed text.
    private func hasNewWords(_ text: String) -> Bool {
        let committed = Set(BargeInPolicy.tokens(state.committedText ?? ""))
        return BargeInPolicy.tokens(text).filter { !committed.contains($0) }.count >= 2
    }

    /// "stop", "attends": always the user, unless the assistant just said it.
    private func isStopWord(_ text: String, at time: Double) -> Bool {
        BargeInPolicy.containsStopPhrase(text) && !bargeIn.isEcho(BargeInPolicy.tokens(text), now: time, threshold: 1)
    }

    private mutating func beginHearing(at time: Double) -> [LiveEffect] {
        state.phase = .userSpeaking
        state.speechStartedAt = state.speechStartedAt ?? time
        state.lastVoiceAt = state.lastVoiceAt ?? time
        state.captionPaused = false
        return [.showCaption(state.caption, paused: false), .pausePlayback]
    }

    private mutating func evaluateBargeIn(at time: Double) -> [LiveEffect] {
        let decision = bargeIn.evaluate(speechDuration: vad.recentSpeechDuration(at: time), dBAboveFloor: Double(vad.levelAboveFloorDB), words: state.caption.text,
                                        now: time, speakingSince: state.speakingSince)
        switch decision {
        case .ignore:
            return []
        case .backchannel(let words):
            state.pendingBackchannel = words
            state.lastDecision = "backchannel '\(words.count) chars' kept for a question"
            return []
        case .interrupt:
            // Only words cancel: two of them that the user had not already said.
            guard hasNewWords(state.caption.text) else { return [] }
            return interruptByVoice(at: time, reason: "barge-in")
        case .hardStop:
            return interruptByVoice(at: time, reason: "stop word")
        }
    }

    // MARK: End of turn

    private mutating func tick(_ time: Double) -> [LiveEffect] {
        switch state.phase {
        case .listening:
            if let since = state.listeningSince, time - since >= options.autoPauseAfter {
                state.phase = .idle
                state.paused = false
                resetUserTurn()
                state.lastDecision = "auto-paused after \(Int(options.autoPauseAfter)) s of silence"
                return [.closeMic, .autoPaused]
            }
            return []
        case .userSpeaking:
            guard !state.muted else { return [] }
            if options.externalEndpointing { return externalHearingCaps(at: time) }
            return endOfTurn(at: time)
        case .thinking, .speaking, .acting:
            if let effects = voiceWatchdog(at: time) { return effects }
            // A brain still open with nothing playing, queued or running: no sign of life for 15 s ends the turn.
            if state.turnInFlight || state.brainOpen, state.toolsRunning == 0, state.chunksQueued == 0, let since = progressAt ?? state.committedAt,
               time - since > Self.thinkingDeadline {
                state.lastDecision = "thinking deadline: nothing for \(Int(Self.thinkingDeadline)) s"
                let id = state.turn
                return cancelResponse(fadeMs: 0) + [.turnTimedOut(id)] + settle(at: time)
            }
            return []
        case .idle, .interrupted:
            return []
        }
    }

    /// The recognizer ends each utterance; the reducer only caps hearing: 4 s with
    /// no words (a latched VAD, a noise), 25 s in all. Then the ear reopens.
    private mutating func externalHearingCaps(at time: Double) -> [LiveEffect] {
        let hearingFor = time - (state.speechStartedAt ?? time)
        let empty = state.caption.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
        guard (empty && hearingFor >= Self.emptyHearingCap) || hearingFor >= Self.externalEndpointCap else { return [] }
        state.phase = .listening
        state.listeningSince = time
        state.lastDecision = empty ? "dropped: no words after \(format(hearingFor)) s" : "dropped: no final after \(format(hearingFor)) s"
        resetUserTurn()
        return [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: time), .openMic]
    }

    /// A line queued that never started, or a started chunk that never drained.
    private mutating func voiceWatchdog(at time: Double) -> [LiveEffect]? {
        if state.chunksQueued > 0, let queued = state.queuedAt, time - queued > Self.queuedLineDeadline {
            return speakerWatchdog(at: time, reason: "queued line never started")
        }
        if let started = state.lastChunkStartedAt, time - started > Self.drainDeadline(words: state.lastChunkWords) {
            return speakerWatchdog(at: time, reason: "chunk never drained")
        }
        return nil
    }

    /// The voice is stuck: stop it, tell the session (it switches voices), and carry on.
    private mutating func speakerWatchdog(at time: Double, reason: String) -> [LiveEffect] {
        state.lastDecision = "speaker watchdog: \(reason)"
        var effects: [LiveEffect] = [.stopSpeaking(fadeMs: 0), .speakerStuck]
        state.chunksQueued = 0
        state.speakingSince = nil
        resetVoiceWatch()
        bargeIn.forgetSpoken()
        progressAt = time
        if state.turnTakingMuted {
            state.turnTakingMuted = false
            effects.append(.setInputMuted(state.muted))
        }
        let before = state.phase
        effects += settle(at: time)
        if before != .listening, state.phase == .listening {
            resetUserTurn()
            effects.append(.beginUserTurn(at: time))
        }
        return effects
    }

    private mutating func endOfTurn(at time: Double) -> [LiveEffect] {
        let voiceSilence = time - (state.lastVoiceAt ?? state.speechStartedAt ?? time)
        var silence = vad.isSpeech ? 0 : voiceSilence
        if !state.caption.text.isEmpty, let changed = state.lastTextChangeAt {
            silence = max(silence, time - changed - Self.transcriptSilenceLag)
        }
        var effects: [LiveEffect] = []
        if silence >= Self.captionPauseAfter, !state.captionPaused {
            state.captionPaused = true
            effects.append(.showCaption(state.caption, paused: true))
        }
        let text = state.caption.text
        if text.count < 2 {
            // A latched VAD can no longer pin "hearing": 4 s without words ends it.
            let hearingFor = time - (state.speechStartedAt ?? time)
            if silence >= Self.noiseDropAfter || hearingFor >= Self.emptyHearingCap {
                state.phase = .listening
                state.listeningSince = time
                resetUserTurn()
                state.lastDecision = "dropped: \(text.count) characters after \(format(max(silence, hearingFor))) s"
                return [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: time)]
            }
            return effects
        }
        let completeness = eot.completeness(state.caption, grammar: grammar, sinceTextChange: time - (state.lastTextChangeAt ?? time))
        let speech = max(0, (state.lastVoiceAt ?? time) - (state.speechStartedAt ?? time))
        let duration = max(speech, state.caption.text.isEmpty ? 0 : eot.parameters.minSpeech)
        guard eot.shouldCommit(silence: silence, speechDuration: duration, completeness: completeness) else { return effects }
        state.lastDecision = "commit: \(completeness.rawValue) after \(format(silence)) s"
        return effects + commit(text, at: time)
    }

    private mutating func commit(_ text: String, at time: Double) -> [LiveEffect] {
        var effects: [LiveEffect] = []
        if audioActive {
            // Whatever still plays belongs to an older turn (a greeting that talked over the user).
            effects.append(.stopSpeaking(fadeMs: 60))
            state.chunksQueued = 0
            state.speakingSince = nil
            resetVoiceWatch()
            bargeIn.forgetSpoken()
            if state.turnTakingMuted {
                state.turnTakingMuted = false
                effects.append(.setInputMuted(state.muted))
            }
        }
        state.turn += 1
        let full = [state.carryOver, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        state.carryOver = nil
        state.committedText = full
        state.turnInFlight = true
        state.committedAt = time
        progressAt = time
        state.brainOpen = false
        state.turnHadOutput = false
        state.spokenText = ""
        state.pendingBackchannel = nil
        state.phase = .thinking
        resetUserTurn()
        return effects + [.commitTurn(state.turn, text: full), .beginUserTurn(at: time), .earcon(.commit)]
    }

    // MARK: Interruptions

    /// Speech cut in: stop the voice (80 ms), cancel the brain, and hear the new words from 0.3 s before they began.
    private mutating func interruptByVoice(at time: Double, reason: String) -> [LiveEffect] {
        let start = vad.isSpeech ? (vad.speechStartedAt ?? time) : time
        let noOutput = !state.turnHadOutput
        var effects = cancelResponse(fadeMs: 80)
        if noOutput, let committed = state.committedText, !committed.isEmpty { state.carryOver = committed }
        state.turn += 1
        state.committedText = nil
        state.phase = .userSpeaking
        state.speechStartedAt = start
        state.lastVoiceAt = time
        state.lastTextChangeAt = time
        state.captionPaused = false
        state.lastDecision = "interrupt: \(reason)"
        effects += [.beginUserTurn(at: start - Self.preRoll), .haptic(.bargeIn), .showCaption(state.caption, paused: false), .pausePlayback]
        return effects
    }

    private mutating func orbTapped(at time: Double) -> [LiveEffect] {
        switch state.phase {
        case .thinking, .speaking, .acting:
            var effects = cancelResponse(fadeMs: 60)
            state.carryOver = nil
            state.committedText = nil
            state.turn += 1
            state.phase = .listening
            state.listeningSince = time
            resetUserTurn()
            state.lastDecision = "interrupt: orb tap"
            effects += [.beginUserTurn(at: time), .haptic(.bargeIn), .showCaption(TranscriptSnapshot(), paused: false)]
            return effects
        case .userSpeaking:
            let text = state.caption.text
            guard !text.isEmpty else {
                state.phase = .listening
                state.listeningSince = time
                resetUserTurn()
                return [.showCaption(TranscriptSnapshot(), paused: false), .beginUserTurn(at: time)]
            }
            state.lastDecision = "commit: orb tap"
            return commit(text, at: time)
        case .listening, .idle, .interrupted:
            return []
        }
    }

    private mutating func typed(_ text: String, at time: Double) -> [LiveEffect] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.phase != .idle, !words.isEmpty else { return [] }
        var effects = cancelResponse(fadeMs: 60)
        state.carryOver = nil
        effects += commit(words, at: time)
        effects.removeAll { $0 == .earcon(.commit) }
        return effects
    }

    private mutating func ideaTapped(at time: Double) -> [LiveEffect] {
        guard state.phase != .idle else { return [] }
        var effects: [LiveEffect] = []
        if state.turnInFlight || audioActive || state.phase == .speaking {
            effects = cancelResponse(fadeMs: 60)
            state.turn += 1
        }
        state.carryOver = nil
        state.committedText = nil
        if state.phase != .userSpeaking {
            state.phase = state.toolsRunning > 0 ? .acting : .listening
            state.listeningSince = time
        }
        return effects
    }

    /// stopSpeaking, and cancelTurn when a brain turn is still open or its voice is cut
    /// (the stream usually ends seconds before the voice does). Tools keep running.
    private mutating func cancelResponse(fadeMs: Int) -> [LiveEffect] {
        var effects: [LiveEffect] = []
        let voiceCut = audioActive || state.phase == .speaking
        if voiceCut { effects.append(.stopSpeaking(fadeMs: fadeMs)) }
        if state.turnInFlight || state.brainOpen || voiceCut { effects.append(.cancelTurn(state.turn, spokenText: state.spokenText)) }
        state.turnInFlight = false
        state.brainOpen = false
        state.chunksQueued = 0
        state.speakingSince = nil
        resetVoiceWatch()
        state.spokenText = ""
        state.pendingBackchannel = nil
        state.turnHadOutput = false
        if state.turnTakingMuted {
            state.turnTakingMuted = false
            effects.append(.setInputMuted(state.muted))
        }
        bargeIn.forgetSpoken()
        return effects
    }

    // MARK: Response signals

    private mutating func turnSignal(_ id: Int, _ signal: TurnSignal, at time: Double) -> [LiveEffect] {
        if id != state.turn {
            // A stale turn's tool still finished: keep the counters right.
            if case .toolFinished = signal, state.toolsRunning > 0 {
                state.toolsRunning -= 1
                return settle(at: time)
            }
            return []
        }
        var effects: [LiveEffect] = []
        progressAt = time
        switch signal {
        case .firstOutput:
            state.brainOpen = true
            state.turnHadOutput = true
        case .toolStarted:
            state.toolsRunning += 1
            state.turnHadOutput = true
            effects.append(.haptic(.actionStarted))
        case .toolFinished(let changed):
            state.toolsRunning = max(0, state.toolsRunning - 1)
            if changed { effects += [.earcon(.applied), .haptic(.actionApplied)] }
        case .ended(let endsWithQuestion):
            state.brainOpen = false
            state.turnInFlight = false
            state.lastAssistantEndsWithQuestion = endsWithQuestion
        case .failed:
            state.brainOpen = false
            state.turnInFlight = false
            state.lastAssistantEndsWithQuestion = false
            effects.append(.earcon(.error))
        }
        return effects + settle(at: time)
    }

    private mutating func speakerSignal(_ id: Int, _ signal: SpeakerSignal, at time: Double) -> [LiveEffect] {
        guard id == state.turn else { return [] }
        var effects: [LiveEffect] = []
        switch signal {
        case .chunkQueued:
            state.chunksQueued += 1
            // Waiting behind a chunk that plays is normal; waiting on nothing is watched.
            if state.lastChunkStartedAt == nil, state.queuedAt == nil { state.queuedAt = time }
        case .chunkStarted(let text):
            state.queuedAt = nil
            state.lastChunkStartedAt = time
            state.lastChunkWords = text.split(whereSeparator: { $0.isWhitespace }).count
            if state.speakingSince == nil, options.turnTaking, !state.turnTakingMuted {
                state.turnTakingMuted = true
                effects.append(.setInputMuted(true))
            }
            state.speakingSince = state.speakingSince ?? time
            state.spokenText += (state.spokenText.isEmpty ? "" : " ") + text
            bargeIn.noteSpoken(text, at: time)
        case .chunkFinished:
            state.chunksQueued = max(0, state.chunksQueued - 1)
            state.lastChunkStartedAt = nil
            state.queuedAt = state.chunksQueued > 0 ? time : nil
        case .drained:
            state.chunksQueued = 0
            state.speakingSince = nil
            resetVoiceWatch()
            if state.turnTakingMuted {
                state.turnTakingMuted = false
                effects.append(.setInputMuted(state.muted))
            }
            // What was heard over the voice in safe mode is dropped: listen afresh,
            // after the echo tail unless the route has no echo (headphones).
            if state.phase != .userSpeaking {
                let tail = state.echoRisk == .low ? 0 : Self.echoTail
                state.echoGateUntil = tail > 0 ? time + tail : nil
                resetUserTurn()
                effects.append(.beginUserTurn(at: time + tail))
            }
        }
        progressAt = time
        return effects + settle(at: time)
    }

    /// The displayed phase of a response (speaking > acting > thinking), and the
    /// return to listening once nothing is open, running or queued.
    private mutating func settle(at time: Double) -> [LiveEffect] {
        guard state.phase != .idle, state.phase != .userSpeaking, state.phase != .interrupted else { return [] }
        if state.speakingSince != nil {
            state.phase = .speaking
        } else if state.toolsRunning > 0 {
            state.phase = .acting
        } else if state.turnInFlight || state.brainOpen || state.chunksQueued > 0 {
            state.phase = .thinking
        } else if state.phase != .listening {
            state.phase = .listening
            state.listeningSince = time
            let backchannel = state.pendingBackchannel
            state.pendingBackchannel = nil
            if let backchannel, state.lastAssistantEndsWithQuestion {
                // The user's "oui" answered the question.
                state.lastDecision = "backchannel answered the question"
                state.lastAssistantEndsWithQuestion = false
                return commit(backchannel, at: time)
            }
            // The recognizer path closed its ear for the reply (or an edit said nothing): reopen it.
            if options.externalEndpointing { return [.openMic] }
        }
        return []
    }

    // MARK: Helpers

    private mutating func resetUserTurn() {
        state.caption = TranscriptSnapshot()
        state.speechStartedAt = nil
        state.lastVoiceAt = nil
        state.lastTextChangeAt = nil
        state.captionPaused = false
        grammar = nil
    }

    private mutating func resetVoiceWatch() {
        state.queuedAt = nil
        state.lastChunkStartedAt = nil
        state.lastChunkWords = 0
    }

    private mutating func updateBargeInMode() {
        state.effectiveBargeIn = state.echoRisk == .low || options.bargeInOnSpeaker == .full ? .full : .safe
    }

    private func format(_ seconds: Double) -> String {
        let hundredths = Int((seconds * 100).rounded())
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)"
    }
}
