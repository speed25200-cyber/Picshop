#if canImport(AVFoundation)
import Foundation
import AVFoundation
import PicshopIntent

/// The system's speech voices as `VoiceCandidate`s, for `VoiceSelector`, Live's
/// speaker and the Settings voice picker, plus the picker's sample player.
@MainActor
public enum SystemVoices {
    /// Every installed voice, novelty voices excluded.
    public static func all() -> [VoiceCandidate] {
        // Phase 0 stub.
        []
    }

    /// The voice Live speaks `language` with: `preferredIdentifier` when installed, else the best one.
    public static func best(for language: String, preferredIdentifier: String?) -> VoiceCandidate? {
        VoiceSelector.best(for: language, among: all(), preferredIdentifier: preferredIdentifier)
    }

    /// Speaks the picker's sample sentence, outside Live only. `rate` multiplies the default rate (0.85...1.25).
    public static func playSample(language: String, voiceIdentifier: String?, rate: Double) {
        // Phase 0 stub.
    }

    public static func stopSample() {
        // Phase 0 stub.
    }

    /// Yields whenever voices are downloaded or removed.
    public static func voicesDidChange() -> AsyncStream<Void> {
        // Phase 0 stub: no change is ever reported.
        AsyncStream { $0.finish() }
    }
}
#endif
