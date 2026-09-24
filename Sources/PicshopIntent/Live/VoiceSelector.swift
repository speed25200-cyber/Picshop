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
///
/// Score: +1,000 for the preferred voice; +300 premium, +200 enhanced, +100
/// standard; +20 for the exact region (fr-FR / en-US unless one is given);
/// -10,000 for novelty voices. Personal voices only when preferred; other
/// languages never. Ties go by name.
public enum VoiceSelector {
    public static func best(for language: String, among voices: [VoiceCandidate], preferredIdentifier: String? = nil, region: String? = nil) -> VoiceCandidate? {
        let primary = primaryLanguage(language)
        let target = targetRegion(language: language, region: region)
        let eligible = voices.filter { voice in
            primaryLanguage(voice.language) == primary && (!voice.isPersonalVoice || voice.identifier == preferredIdentifier)
        }
        func score(_ voice: VoiceCandidate) -> Int {
            var total = voice.quality.rawValue * 100
            if voice.identifier == preferredIdentifier { total += 1_000 }
            if normalizedTag(voice.language) == target { total += 20 }
            if voice.isNovelty { total -= 10_000 }
            return total
        }
        return eligible.min { lhs, rhs in
            let (left, right) = (score(lhs), score(rhs))
            if left != right { return left > right }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.identifier < rhs.identifier
        }
    }

    /// Picker order: premium, enhanced, standard; the default region first; then name. Novelty voices are left out.
    public static func sorted(_ voices: [VoiceCandidate], language: String) -> [VoiceCandidate] {
        let primary = primaryLanguage(language)
        let target = targetRegion(language: language, region: nil)
        return voices.filter { primaryLanguage($0.language) == primary && !$0.isNovelty }.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            let (left, right) = (normalizedTag(lhs.language) == target, normalizedTag(rhs.language) == target)
            if left != right { return left }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.identifier < rhs.identifier
        }
    }

    /// nil or standard quality.
    public static func needsBetterVoiceHint(_ voice: VoiceCandidate?) -> Bool {
        guard let voice else { return true }
        return voice.quality == .standard
    }

    static func primaryLanguage(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// fr-fr style, for comparing tags written with - or _.
    static func normalizedTag(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// The exact region to prefer: the one given, the one in the language tag, else fr-FR / en-US / xx-XX.
    static func targetRegion(language: String, region: String?) -> String {
        let primary = primaryLanguage(language)
        if let region, !region.isEmpty {
            let code = region.split(whereSeparator: { $0 == "-" || $0 == "_" }).last.map(String.init) ?? region
            return "\(primary)-\(code.lowercased())"
        }
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" })
        if parts.count >= 2 { return "\(primary)-\(parts[parts.count - 1].lowercased())" }
        switch primary {
        case "en": return "en-us"
        default: return "\(primary)-\(primary)"
        }
    }
}
