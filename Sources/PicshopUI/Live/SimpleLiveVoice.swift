#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopSpeech

/// The voice path a Live conversation runs on. `simple` is the default and the
/// fallback: VoiceController hears one utterance at a time and `speak()` talks,
/// one side at a time. `duplex` is the echo-cancelling LiveAudioStack, used only
/// with headphones once the self-test has passed.
public enum LiveVoicePath: String, Sendable { case simple, duplex }

/// Live on the proven path: VoiceController hears one utterance at a time,
/// AVSpeechSynthesizer.speak() talks, and the microphone is closed while it talks.
///
/// `start` takes the audio session for the whole conversation and saves what it
/// changes on VoiceController (mode, locale, timeouts, callbacks); `stop` puts all
/// of it back, so push-to-talk behaves as before once Live ends.
///
/// Phase 0: the frozen surface. LiveSession wires it in phase 1, together with the
/// watch loop that reopens the ear and reports `.unavailable` through `onFailure`.
@MainActor
final class SimpleLiveVoice {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// System speech only (`speak()`): its engine is never started.
    let speaker: LiveSpeaker

    private let voice: VoiceController
    private var saved: SavedVoice?
    private var wantsListening = false
    private var reopenTask: Task<Void, Never>?

    /// What `start` changed on VoiceController, restored by `stop`.
    private struct SavedVoice {
        var mode: VoiceController.Mode
        var locale: Locale
        var silenceTimeout: TimeInterval
        var maximumDuration: TimeInterval
        var onFinalTranscript: ((String) -> Void)?
        var onPartialTranscript: ((String) -> Void)?
    }

    init(voice: VoiceController) {
        self.voice = voice
        speaker = LiveSpeaker(engine: LiveAudioEngine())
        speaker.setUsesSystemSpeech(true)
    }

    /// The microphone level while an utterance is heard, 0...1.
    var level: Double { voice.level }

    /// Acquires the session as `.liveSimple`, then sets VoiceController up for Live:
    /// one utterance per `listen`, 0.9 s of silence ends it, 20 s at most.
    func start(locale: Locale) async throws {
        try await AudioSessionArbiter.shared.acquire(.liveSimple)
        if saved == nil {
            saved = SavedVoice(mode: voice.mode, locale: voice.locale, silenceTimeout: voice.silenceTimeout, maximumDuration: voice.maximumDuration,
                               onFinalTranscript: voice.onFinalTranscript, onPartialTranscript: voice.onPartialTranscript)
        }
        voice.locale = locale
        voice.mode = .tapToTalk
        voice.silenceTimeout = 0.9
        voice.maximumDuration = 20
        voice.onPartialTranscript = { [weak self] text in self?.onPartial?(text) }
        voice.onFinalTranscript = { [weak self] text in
            self?.wantsListening = false
            self?.onFinal?(text)
        }
    }

    /// Opens the ear for one utterance, after `delay` seconds (the echo tail after the voice).
    func listen(after delay: Double = 0) {
        wantsListening = true
        reopenTask?.cancel()
        reopenTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.wantsListening, self.voice.canStart else { return }
            self.voice.start()
        }
    }

    /// Closes the ear: what was being heard is dropped.
    func pauseListening() {
        wantsListening = false
        reopenTask?.cancel()
        reopenTask = nil
        if voice.isListening { voice.cancel() }
    }

    /// Everything off; VoiceController gets back what `start` saved, and the session is released.
    func stop() {
        pauseListening()
        speaker.stop(fadeMs: 0)
        if let saved {
            voice.mode = saved.mode
            voice.locale = saved.locale
            voice.silenceTimeout = saved.silenceTimeout
            voice.maximumDuration = saved.maximumDuration
            voice.onFinalTranscript = saved.onFinalTranscript
            voice.onPartialTranscript = saved.onPartialTranscript
            self.saved = nil
        }
        AudioSessionArbiter.shared.release(.liveSimple)
    }
}
#endif
