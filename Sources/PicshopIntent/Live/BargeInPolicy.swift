import Foundation
import PicshopCore

/// When speech over the assistant's voice counts as an interruption: echo
/// guard, stop words, backchannels and thresholds.
public struct BargeInPolicy: Sendable {
    public struct Parameters: Sendable {
        /// Seconds of speech with words: 0.18 with low echo risk, 0.28 normal, 0.40 high.
        public var minSpeechLowEcho = 0.18
        public var minSpeech = 0.28
        public var minSpeechHighEcho = 0.40
        /// Speech this long and this loud interrupts before the recognizer has words.
        public var minSpeechWithoutWords = 0.45
        public var loudAboveFloorDB = 20.0
        /// After the first TTS audio, while echo cancellation converges.
        public var graceAfterSpeechStarts = 0.15
        public var echoOverlap = 0.6
        public var echoWindow = 3.0

        public init() {}
    }

    public enum Decision: Sendable, Equatable { case ignore, backchannel(String), interrupt, hardStop }

    public static let frenchStopPhrases = ["stop", "arrete", "attends", "tais-toi", "tais toi", "chut", "pause", "non non"]
    public static let englishStopPhrases = ["stop", "wait", "hold on", "hang on", "pause", "no no", "cancel"]
    public static let frenchBackchannels = ["oui", "ouais", "ok", "d'accord", "mh", "mhm", "hm", "ah", "super", "cool", "exact", "c'est ca", "vas-y", "vas y"]
    public static let englishBackchannels = ["yes", "yeah", "yep", "ok", "okay", "mhm", "uh-huh", "uh huh", "right", "sure", "cool", "nice", "got it"]

    public let parameters: Parameters
    public var echoRisk: EchoRisk = .normal
    private var spoken: [(time: Double, tokens: [String])] = []

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }

    /// A chunk the assistant just started saying, for the echo guard.
    public mutating func noteSpoken(_ text: String, at time: Double) {
        let tokens = Self.tokens(text)
        guard !tokens.isEmpty else { return }
        spoken.append((time, tokens))
        spoken.removeAll { time - $0.time > parameters.echoWindow * 4 }
    }

    public mutating func forgetSpoken() {
        spoken.removeAll()
    }

    public var requiredSpeech: Double {
        switch echoRisk {
        case .low: return parameters.minSpeechLowEcho
        case .normal: return parameters.minSpeech
        case .high: return parameters.minSpeechHighEcho
        }
    }

    public func evaluate(speechDuration: Double, dBAboveFloor: Double, words: String, now: Double, speakingSince: Double?) -> Decision {
        let heard = Self.tokens(words)
        if Self.containsStopPhrase(words), !isEcho(heard, now: now, threshold: 1) { return .hardStop }
        if let speakingSince, now - speakingSince < parameters.graceAfterSpeechStarts { return .ignore }
        if !heard.isEmpty {
            if isEcho(heard, now: now, threshold: parameters.echoOverlap) { return .ignore }
            if Self.isBackchannel(words) { return .backchannel(words.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if speechDuration >= requiredSpeech { return .interrupt }
            return .ignore
        }
        if speechDuration >= parameters.minSpeechWithoutWords, dBAboveFloor >= parameters.loudAboveFloorDB { return .interrupt }
        return .ignore
    }

    /// Whether most of what was heard is the assistant's own voice from the last 3 s.
    public func isEcho(_ heard: [String], now: Double, threshold: Double) -> Bool {
        guard !heard.isEmpty else { return false }
        let recent = spoken.enumerated().filter { $0.offset == spoken.count - 1 || now - $0.element.time <= parameters.echoWindow }
        let vocabulary = Set(recent.flatMap { $0.element.tokens })
        guard !vocabulary.isEmpty else { return false }
        let matched = heard.filter { vocabulary.contains($0) }.count
        return Double(matched) / Double(heard.count) >= threshold
    }

    public static func containsStopPhrase(_ words: String) -> Bool {
        let text = " " + tokens(words).joined(separator: " ") + " "
        return (frenchStopPhrases + englishStopPhrases).contains { text.contains(" " + normalizedPhrase($0) + " ") }
    }

    /// At most 2 words, all agreement or acknowledgement ("c'est ça" is two words).
    public static func isBackchannel(_ words: String) -> Bool {
        let heard = tokens(words)
        let spoken = words.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.contains(where: \.isLetter) }
        guard (1...2).contains(spoken.count), !heard.isEmpty else { return false }
        let phrase = heard.joined(separator: " ")
        let phrases = Set((frenchBackchannels + englishBackchannels).map(normalizedPhrase))
        if phrases.contains(phrase) { return true }
        return heard.allSatisfy { phrases.contains($0) }
    }

    static func tokens(_ text: String) -> [String] {
        NormalizedUtterance(text).tokens
    }

    static func normalizedPhrase(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }
}
