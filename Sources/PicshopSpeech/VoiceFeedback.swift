#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore

/// Short spoken confirmations ("Done, removed the dog"). Off by default in the
/// UI; when on, it speaks at a low volume in the command's language.
///
/// It never talks over the microphone: while `VoiceController` listens a reply
/// is skipped (the recogniser would transcribe it), and a microphone that
/// restarts on its own waits for `waitUntilFinished()` first.
@MainActor
public final class VoiceFeedback: NSObject {
    public static let shared = VoiceFeedback()

    private let synthesizer = AVSpeechSynthesizer()
    public var isEnabled = false
    /// True for the whole of a Live session, which speaks through its own engine:
    /// `speak(_:language:force:)` then returns silently, even with `force`.
    public var isSuppressed = false
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05
    /// Set by `VoiceController` while it prepares, listens or finishes.
    public internal(set) var isMicrophoneActive = false
    /// Whether an utterance is being spoken (or queued) right now.
    public private(set) var isSpeaking = false
    /// The utterance being spoken, so a late "cancelled" for the one it replaced is ignored.
    private var current: ObjectIdentifier?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, language: String?, force: Bool = false) {
        guard !isSuppressed else { return }
        guard isEnabled || force, !text.isEmpty else { return }
        // Heard by the open microphone, the reply would come back as the next command.
        guard !isMicrophoneActive else {
            PSLog.debug("reply not spoken while listening", category: .speech)
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = force ? AVSpeechUtteranceDefaultSpeechRate : rate
        utterance.volume = force ? 1 : 0.8
        utterance.prefersAssistiveTechnologySettings = false
        let code = (language ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("fr") ? "fr-FR" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        isSpeaking = true
        current = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        finished(nil)
    }

    /// Returns once nothing is being spoken, or after `timeout` seconds.
    public func waitUntilFinished(timeout: TimeInterval = 8) async {
        guard isSpeaking else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resumeWaiters()
        }
        await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
        }
        deadline.cancel()
    }

    /// `utterance` nil: everything stopped.
    private func finished(_ utterance: ObjectIdentifier?) {
        if let utterance, utterance != current { return }
        current = nil
        isSpeaking = false
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

extension VoiceFeedback: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in VoiceFeedback.shared.finished(id) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in VoiceFeedback.shared.finished(id) }
    }
}
#endif
