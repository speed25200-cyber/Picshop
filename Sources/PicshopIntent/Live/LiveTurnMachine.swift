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
}

public struct LiveTurnState: Sendable, Equatable {
    public private(set) var phase: LivePhase
    public private(set) var paused: Bool
    public private(set) var muted: Bool
    public private(set) var turn: Int
    public private(set) var caption: TranscriptSnapshot
    public private(set) var brainOpen: Bool
    public private(set) var toolsRunning: Int
    public private(set) var chunksQueued: Int
    public private(set) var spokenText: String
    public private(set) var echoRisk: EchoRisk
    public private(set) var effectiveBargeIn: BargeInMode

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

public struct LiveTurnMachine: Sendable {
    public struct Options: Sendable, Equatable {
        /// .full only when AppSettings.liveBargeIn.
        public var bargeInOnSpeaker: BargeInMode
        /// VoiceOver running: mic muted while the assistant speaks.
        public var turnTaking: Bool
        public var autoPauseAfter: Double = 90

        public init(bargeInOnSpeaker: BargeInMode, turnTaking: Bool) {
            self.bargeInOnSpeaker = bargeInOnSpeaker
            self.turnTaking = turnTaking
        }
    }

    public private(set) var state: LiveTurnState
    private var options: Options
    private var eot: EndOfTurnDetector
    private var vad: VoiceActivityDetector
    private var bargeIn: BargeInPolicy

    public init(options: Options, eot: EndOfTurnDetector = .init(), vad: VoiceActivityDetector = .init(), bargeIn: BargeInPolicy = .init()) {
        self.options = options
        self.eot = eot
        self.vad = vad
        self.bargeIn = bargeIn
        state = LiveTurnState(effectiveBargeIn: options.bargeInOnSpeaker)
    }

    public mutating func setOptions(_ options: Options) {
        self.options = options
    }

    public mutating func handle(_ event: LiveEvent) -> [LiveEffect] {
        // Phase 0 stub.
        []
    }

    public mutating func noteAssistantSpoke(_ text: String, at: Double) {
        // Phase 0 stub.
    }
}
