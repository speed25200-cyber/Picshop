#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopIntent

/// The system's speech voices as `VoiceCandidate`s, for `VoiceSelector`, Live's
/// speaker and the Settings voice picker, plus the picker's sample player.
@MainActor
public enum SystemVoices {
    /// `speechVoices()` takes tens of milliseconds: read once, again when voices change.
    private static var cached: [VoiceCandidate]?
    private static var observer: NSObjectProtocol?
    private static var sampleSynthesizer: AVSpeechSynthesizer?

    /// Every installed voice, novelty voices excluded.
    public static func all() -> [VoiceCandidate] {
        if let cached { return cached }
        observeChanges()
        let voices = AVSpeechSynthesisVoice.speechVoices().compactMap(candidate(from:))
        cached = voices
        return voices
    }

    /// The voice Live speaks `language` with: `preferredIdentifier` when installed, else the best one.
    public static func best(for language: String, preferredIdentifier: String?) -> VoiceCandidate? {
        VoiceSelector.best(for: language, among: all(), preferredIdentifier: preferredIdentifier)
    }

    /// Speaks the picker's sample sentence, outside Live only. `rate` multiplies the default rate (0.85...1.25).
    public static func playSample(language: String, voiceIdentifier: String?, rate: Double) {
        guard AudioSessionArbiter.shared.owner != .live else { return }
        stopSample()
        let french = language.lowercased().hasPrefix("fr")
        let text = french ? "Bonjour ! Je suis prête à retoucher tes photos avec toi." : "Hi! I'm ready to edit your photos with you."
        let code = language.contains("-") ? language : (french ? "fr-FR" : "en-US")
        let identifier = voiceIdentifier ?? best(for: code, preferredIdentifier: nil)?.identifier
        let multiplier = Float(min(max(rate.isFinite ? rate : 1, 0.85), 1.25))
        let utterance = SynthesizerSpeechRenderer.utterance(text: text, language: code, voiceIdentifier: identifier,
                                                             rate: AVSpeechUtteranceDefaultSpeechRate * multiplier)
        let synthesizer = AVSpeechSynthesizer()
        sampleSynthesizer = synthesizer
        synthesizer.speak(utterance)
    }

    public static func stopSample() {
        sampleSynthesizer?.stopSpeaking(at: .immediate)
        sampleSynthesizer = nil
    }

    /// Yields whenever voices are downloaded or removed.
    public static func voicesDidChange() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ObserverToken(NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { _ in
                continuation.yield()
            })
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.value) }
        }
    }

    /// A notification observer handed to a stream's termination handler.
    private final class ObserverToken: @unchecked Sendable {
        let value: NSObjectProtocol
        init(_ value: NSObjectProtocol) { self.value = value }
    }

    private static func observeChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SystemVoices.cached = nil }
        }
    }

    private static func candidate(from voice: AVSpeechSynthesisVoice) -> VoiceCandidate? {
        let traits = voice.voiceTraits
        guard !traits.contains(.isNoveltyVoice) else { return nil }
        let quality: VoiceCandidate.Quality
        switch voice.quality {
        case .premium: quality = .premium
        case .enhanced: quality = .enhanced
        default: quality = .standard
        }
        return VoiceCandidate(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality,
                              isNovelty: false, isPersonalVoice: traits.contains(.isPersonalVoice))
    }
}
#endif
