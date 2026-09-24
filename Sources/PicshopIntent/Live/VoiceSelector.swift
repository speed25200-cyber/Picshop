import Foundation
import PicshopCore

/// A system voice, described without AVFoundation so the ranking is testable.
public struct VoiceCandidate: Sendable, Hashable, Identifiable {
    public enum Quality: Int, Sendable, Comparable {
        case standard = 1, enhanced = 2, premium = 3

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var identifier: String
    public var name: String
    /// BCP-47, fr-FR.
    public var language: String
    public var quality: Quality
    public var isNovelty: Bool
    public var isPersonalVoice: Bool

    public var id: String { identifier }

    public init(identifier: String, name: String, language: String, quality: Quality, isNovelty: Bool, isPersonalVoice: Bool) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
        self.isNovelty = isNovelty
        self.isPersonalVoice = isPersonalVoice
    }
}

/// Picks the voice Live speaks with.
public enum VoiceSelector {
    public static func best(for language: String, among voices: [VoiceCandidate], preferredIdentifier: String? = nil, region: String? = nil) -> VoiceCandidate? {
        // Phase 0 stub: the preferred voice, else the first one in the language.
        if let preferredIdentifier, let preferred = voices.first(where: { $0.identifier == preferredIdentifier }) { return preferred }
        let prefix = String(language.prefix(2)).lowercased()
        return voices.first { $0.language.lowercased().hasPrefix(prefix) && !$0.isNovelty && !$0.isPersonalVoice }
    }

    /// Picker order.
    public static func sorted(_ voices: [VoiceCandidate], language: String) -> [VoiceCandidate] {
        // Phase 0 stub.
        voices
    }

    /// nil or standard quality.
    public static func needsBetterVoiceHint(_ voice: VoiceCandidate?) -> Bool {
        guard let voice else { return true }
        return voice.quality == .standard
    }
}
