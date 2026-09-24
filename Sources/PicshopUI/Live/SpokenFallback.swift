#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import PicshopIntent
import PicshopSpeech

/// The voice of last resort: when Live has no speaker (it failed to start, or has
/// already stopped), a problem line from `LiveLines` is still said out loud, with
/// the best installed system voice for the reply language.
@MainActor
enum SpokenFallback {
    private static let synthesizer = AVSpeechSynthesizer()

    static func say(_ text: String, language: NormalizedUtterance.Language) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let code = language == .french ? "fr-FR" : "en-US"
        let utterance = AVSpeechUtterance(string: clean)
        let best = SystemVoices.best(for: code, preferredIdentifier: nil)
        utterance.voice = best.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: code)
        utterance.volume = 1
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}
#endif
