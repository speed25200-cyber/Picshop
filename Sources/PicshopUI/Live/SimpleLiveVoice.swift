#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import PicshopCore
import PicshopSpeech

/// The voice path a Live conversation runs on. `simple` is the default and the
/// fallback: VoiceController hears one utterance at a time and `speak()` talks,
/// one side at a time. `duplex` is the echo-cancelling LiveAudioStack, used only
/// with headphones once the self-test has passed.
public enum LiveVoicePath: String, Sendable { case simple, duplex }

/// Live on the proven path: VoiceController hears one utterance at a time (a fresh
/// SpeechAnalyzer each, ended by 0.9 s of silence, words that stop changing, or 20 s),
/// AVSpeechSynthesizer.speak() talks, and LiveSession keeps the ear closed while it talks.
///
/// `start` takes the audio session for the whole conversation and saves what it
/// changes on VoiceController (mode, locale, timeouts, callbacks); `stop` puts all
/// of it back, so push-to-talk behaves as before once Live ends.
///
/// Nothing is swallowed: an utterance that ends without words reports an empty final
/// (the reducer then listens again), a recognizer that fails is retried once quietly
/// and reported through `onFailure` the second time, and a watch loop reopens the ear
/// VoiceController closed on its own (6 s without a sound). A start that has not reached
/// listening after 8 s is cancelled and counts as a failure; an utterance still finishing
/// after 4 s is reported at once. Live's recognition stays on the iPhone
/// (`requiresOnDeviceRecognition`), and a speech model download is announced.
@MainActor
final class SimpleLiveVoice {
    var onPartial: ((String) -> Void)?
    /// A recognizer final. Empty when an utterance ended with no words.
    var onFinal: ((String) -> Void)?
    /// The ear failed twice in a row and stays closed until `retry()`.
    var onFailure: ((String) -> Void)?
    /// An audio interruption began (true) or ended (false, with the system's shouldResume).
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?
    /// Headphones or a Bluetooth device came or went.
    var onRouteChange: (() -> Void)?
    /// Three utterances in a row had sound but no words (once, until words come back).
    var onNothingRecognized: (() -> Void)?
    /// SpeechAnalyzer's model started (true) or stopped (false) downloading; SFSpeechRecognizer hears meanwhile.
    var onSpeechModelInstalling: ((Bool) -> Void)?
    /// System speech only (`speak()`): its engine is never started.
    let speaker: LiveSpeaker

    /// The ear should be open: set by `listen`, cleared by a final, a pause or a failure.
    private(set) var wantsListening = false
    /// Two failures in a row: the ear stays closed until `retry()`.
    private(set) var gaveUp = false
    /// When the words of the current utterance last changed (uptime), for the latency marks.
    private(set) var lastPartialAt: Double?

    private let voice: VoiceController
    private var saved: SavedVoice?
    private var reopenTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isStopped = false
    /// Results of the utterance this object started are wanted; a paused ear delivers nothing.
    private var isHearing = false
    private var finalDelivered = false
    private var utteranceHadWords = false
    private var utteranceMaxLevel = 0.0
    /// Started here (not adopted mid-way): its sound level counts toward `onNothingRecognized`.
    private var utteranceStartedHere = false
    private var emptyWithSound = 0
    private var reportedNothingRecognized = false
    private var failures = 0
    private var lastState: VoiceController.State = .idle
    private var idleSince: Double?
    /// When VoiceController entered `lastState` (uptime), for the start and finish watchdogs.
    private var stateSince = ProcessInfo.processInfo.systemUptime
    /// The watchdog already acted on this state.
    private var stuckReported = false
    private var lastInstalling = false

    /// What `start` changed on VoiceController, restored by `stop`.
    private struct SavedVoice {
        var mode: VoiceController.Mode
        var locale: Locale
        var silenceTimeout: TimeInterval
        var maximumDuration: TimeInterval
        var textSilenceTimeout: TimeInterval?
        var onFinalTranscript: ((String) -> Void)?
        var onPartialTranscript: ((String) -> Void)?
        var requiresOnDeviceRecognition: Bool
    }

    /// Silence that ends an utterance, and how long its words may stay unchanged in a loud room.
    static let silenceTimeout: TimeInterval = 0.9
    static let textSilenceTimeout: TimeInterval = 1.6
    static let maximumDuration: TimeInterval = 20
    /// A start (session, recognizer, engine) that takes longer is cancelled and counts as a failure.
    static let startLimit: Double = 8
    /// An utterance still finishing after this long is reported (VoiceController bounds it to 2.5 s).
    static let finishLimit: Double = 4

    init(voice: VoiceController) {
        self.voice = voice
        speaker = LiveSpeaker(engine: LiveAudioEngine())
        speaker.setUsesSystemSpeech(true)
    }

    /// The microphone level while an utterance is heard, 0...1.
    var level: Double { wantsListening ? voice.level : 0 }

    /// Acquires the session as `.liveSimple`, then sets VoiceController up for Live:
    /// one utterance per `listen`, 0.9 s of silence ends it, 20 s at most.
    /// LiveSession wraps it in a 6 s deadline; a start that finishes after `stop` undoes itself.
    func start(locale: Locale) async throws {
        guard !isStopped else { throw CancellationError() }
        try await AudioSessionArbiter.shared.acquire(.liveSimple)
        guard !isStopped else {
            AudioSessionArbiter.shared.release(.liveSimple)
            throw CancellationError()
        }
        if saved == nil {
            saved = SavedVoice(mode: voice.mode, locale: voice.locale, silenceTimeout: voice.silenceTimeout, maximumDuration: voice.maximumDuration,
                               textSilenceTimeout: voice.textSilenceTimeout,
                               onFinalTranscript: voice.onFinalTranscript, onPartialTranscript: voice.onPartialTranscript,
                               requiresOnDeviceRecognition: voice.requiresOnDeviceRecognition)
        }
        // D1: Live's words never leave the iPhone, even on the SFSpeechRecognizer fallback.
        voice.requiresOnDeviceRecognition = true
        voice.locale = locale
        voice.mode = .tapToTalk
        voice.silenceTimeout = Self.silenceTimeout
        voice.maximumDuration = Self.maximumDuration
        voice.textSilenceTimeout = Self.textSilenceTimeout
        voice.onPartialTranscript = { [weak self] text in self?.partial(text) }
        voice.onFinalTranscript = { [weak self] text in self?.final(text) }
        // A failure left over from before Live is not this conversation's.
        lastState = voice.state
        stateSince = ProcessInfo.processInfo.systemUptime
        stuckReported = false
        observeSession()
        watch()
    }

    /// Opens the ear for one utterance, after `delay` seconds (the echo tail after the voice).
    func listen(after delay: Double = 0) {
        guard !isStopped, !gaveUp else { return }
        wantsListening = true
        reopenTask?.cancel()
        reopenTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.reopenTask = nil
            guard self.wantsListening, !self.gaveUp, !self.isStopped else { return }
            // Still finishing the last one: the watch loop starts it once VoiceController is idle.
            if self.voice.canStart { self.beginUtterance() }
        }
    }

    /// Closes the ear: what was being heard is dropped, never delivered.
    func pauseListening() {
        wantsListening = false
        isHearing = false
        reopenTask?.cancel()
        reopenTask = nil
        idleSince = nil
        if voice.isListening { voice.cancel() }
    }

    /// After `onFailure` (a tap on the orb): the ear may open again.
    func retry() {
        gaveUp = false
        failures = 0
    }

    /// Everything off; VoiceController gets back what `start` saved, and the session is released.
    func stop() {
        isStopped = true
        pauseListening()
        watchTask?.cancel()
        watchTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        speaker.stop(fadeMs: 0)
        if let saved {
            voice.mode = saved.mode
            voice.locale = saved.locale
            voice.silenceTimeout = saved.silenceTimeout
            voice.maximumDuration = saved.maximumDuration
            voice.textSilenceTimeout = saved.textSilenceTimeout
            voice.onFinalTranscript = saved.onFinalTranscript
            voice.onPartialTranscript = saved.onPartialTranscript
            voice.requiresOnDeviceRecognition = saved.requiresOnDeviceRecognition
            self.saved = nil
        }
        AudioSessionArbiter.shared.release(.liveSimple)
    }

    // MARK: Utterances

    private func beginUtterance() {
        guard voice.canStart else { return }
        adoptUtterance()
        utteranceStartedHere = true
        voice.start()
        // A start of ours: an `.unavailable` seen after it is a new failure, even with the
        // same message as the last one and even if it came before the next 100 ms sample.
        noteState(.preparing)
    }

    private func noteState(_ state: VoiceController.State) {
        lastState = state
        stateSince = ProcessInfo.processInfo.systemUptime
        stuckReported = false
    }

    /// The utterance VoiceController hears now is ours: its partials and final count.
    private func adoptUtterance() {
        isHearing = true
        finalDelivered = false
        utteranceHadWords = false
        utteranceMaxLevel = 0
        utteranceStartedHere = false
        lastPartialAt = nil
    }

    private func partial(_ text: String) {
        guard isHearing, !isStopped else { return }
        if !text.isEmpty {
            utteranceHadWords = true
            lastPartialAt = ProcessInfo.processInfo.systemUptime
        }
        onPartial?(text)
    }

    private func final(_ text: String) {
        guard isHearing, !isStopped else { return }
        isHearing = false
        finalDelivered = true
        wantsListening = false
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            emptyWithSound = 0
            reportedNothingRecognized = false
        }
        onFinal?(words)
    }

    /// VoiceController went back to idle. An utterance of ours that showed words but
    /// delivered no final (a route change mid-sentence) reports an empty final, so the
    /// reducer never waits on it. One without words never left listening: nothing to
    /// report (and the reducer's silence clock keeps running toward its auto-pause).
    private func utteranceEnded() {
        guard isHearing else { return }
        isHearing = false
        guard !finalDelivered else { return }
        if utteranceHadWords {
            onFinal?("")
            return
        }
        guard utteranceMaxLevel > 0.25 else { return }
        emptyWithSound += 1
        if emptyWithSound >= 3, !reportedNothingRecognized {
            reportedNothingRecognized = true
            emptyWithSound = 0
            onNothingRecognized?()
        }
    }

    // MARK: Watch

    /// 10 Hz: notices the end of utterances, reopens an ear VoiceController closed on its
    /// own, and handles a recognizer that cannot start.
    private func watch() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !self.isStopped else { return }
                self.step()
            }
        }
    }

    private func step() {
        let installing = voice.isInstallingSpeechModel
        if installing != lastInstalling {
            lastInstalling = installing
            onSpeechModelInstalling?(installing)
        }
        let state = voice.state
        let previous = lastState
        if state != previous { noteState(state) }
        let now = ProcessInfo.processInfo.systemUptime
        switch state {
        case .preparing, .listening:
            idleSince = nil
            if !isHearing {
                // VoiceController restarted on its own (a route or configuration change):
                // adopted when the ear is wanted, cancelled otherwise.
                if wantsListening, !gaveUp {
                    adoptUtterance()
                } else {
                    voice.cancel()
                }
            }
            if state == .listening {
                if previous != .listening { failures = 0 }
                if isHearing, utteranceStartedHere { utteranceMaxLevel = max(utteranceMaxLevel, voice.level) }
            } else if !stuckReported, now - stateSince > Self.startLimit {
                // The session, the recognizer or the engine never answered: cancelled, and a failure.
                stuckReported = true
                isHearing = false
                voice.cancel()
                recognizerFailed("start took more than \(Int(Self.startLimit)) s")
            }
        case .finishing:
            idleSince = nil
            if !stuckReported, now - stateSince > Self.finishLimit {
                // Nothing can cancel an utterance that is ending: reported at once, shown and said.
                stuckReported = true
                isHearing = false
                failures = max(failures, 1)
                recognizerFailed("finishing took more than \(Int(Self.finishLimit)) s")
            }
        case .idle:
            if previous != .idle { utteranceEnded() }
            guard wantsListening, !gaveUp, reopenTask == nil, recoveryTask == nil, voice.canStart else {
                idleSince = nil
                return
            }
            if let since = idleSince {
                if now - since >= 0.35 {
                    idleSince = nil
                    beginUtterance()
                }
            } else {
                idleSince = now
            }
        case .unavailable(let message):
            idleSince = nil
            guard previous != state else { return }
            isHearing = false
            recognizerFailed(message)
        }
    }

    /// The first failure is retried quietly (the session again, then the ear); the second is reported.
    private func recognizerFailed(_ message: String) {
        failures += 1
        PSLog.error("live simple: the ear could not start (\(failures)): \(message)", category: .speech)
        guard failures >= 2 else {
            recoveryTask?.cancel()
            recoveryTask = Task { @MainActor [weak self] in
                try? await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: false)
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, !Task.isCancelled else { return }
                self.recoveryTask = nil
                guard !self.isStopped, self.wantsListening, !self.gaveUp, self.voice.canStart else { return }
                self.beginUtterance()
            }
            return
        }
        gaveUp = true
        wantsListening = false
        onFailure?(message)
    }

    // MARK: Session events

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo
            guard let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: (info?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            let began = type == .began
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if !began {
                    // The call is over: the conversation's session again before the ear reopens.
                    try? await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: false)
                }
                self.onInterruption?(began, shouldResume)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.onRouteChange?()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                // Every audio object is invalid now, the synthesizer included.
                self.speaker.resetSystemVoice()
                try? await AudioSessionArbiter.shared.reactivateLive(hdBluetooth: false)
            }
        })
    }
}
#endif
