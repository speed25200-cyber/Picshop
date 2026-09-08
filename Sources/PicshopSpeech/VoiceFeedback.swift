#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopCore

/// Short spoken confirmations ("Done, removed the dog"). Off by default in the
/// UI; when on, it speaks at a low volume in the command's language.
@MainActor
public final class VoiceFeedback {
    public static let shared = VoiceFeedback()

    private let synthesizer = AVSpeechSynthesizer()
    public var isEnabled = false
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.05

    private init() {}

    public func speak(_ text: String, language: String?, force: Bool = false) {
        guard isEnabled || force, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = force ? AVSpeechUtteranceDefaultSpeechRate : rate
        utterance.volume = force ? 1 : 0.8
        utterance.prefersAssistiveTechnologySettings = false
        let code = (language ?? Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("fr") ? "fr-FR" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif
