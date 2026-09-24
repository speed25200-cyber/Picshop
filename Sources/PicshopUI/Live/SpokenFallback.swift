#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import PicshopIntent
import PicshopSpeech

/// The voice of last resort: when Live has no speaker (it failed to start, or has
/// already stopped), a problem line from `LiveLines` is still said out loud, with
/// the best installed system voice for the reply language.
///
/// The line starts 0.35 s later: Live's audio session, released just before, is
/// deactivated on its own queue first, so it cannot cut the line off.
@MainActor
enum SpokenFallback {
    private static let synthesizer = AVSpeechSynthesizer()
    private static var pending: Task<Void, Never>?

    static func say(_ text: String, language: NormalizedUtterance.Language) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let code = language == .french ? "fr-FR" : "en-US"
        let utterance = AVSpeechUtterance(string: clean)
        let best = SystemVoices.best(for: code, preferredIdentifier: nil)
        utterance.voice = best.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: code)
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = false
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.speak(utterance)
        }
    }
}
#endif
