import Foundation
import PicshopCore

/// Decides when the user has finished speaking: 0.55 s of silence after a
/// complete sentence, 0.80 s when likely complete, 1.60 s when incomplete.
/// Hard cap 2.5 s. No speculation.
public struct EndOfTurnDetector: Sendable {
    public struct Parameters: Sendable {
        public var commitComplete = 0.55
        public var commitLikely = 0.80
        public var commitIncomplete = 1.60
        public var hardSilenceCap = 2.50
        public var maxTurn = 30.0
        public var minSpeech = 0.18
        public var volatileSettle = 0.15

        public init() {}
    }

    public enum Completeness: String, Sendable, Equatable { case complete, likely, incomplete }

    public var parameters: Parameters

    public init(parameters: Parameters = .init()) {
        self.parameters = parameters
    }

    /// Words a sentence does not end on.
    public static let frenchTrailing: Set<String> = [
        "et", "mais", "ou", "puis", "donc", "alors", "de", "du", "des", "le", "la", "les", "un", "une", "a", "au", "aux", "avec", "pour", "sur",
        "dans", "en", "que", "qui", "je", "tu", "il", "on", "mon", "ma", "mes", "ton", "ta", "plus", "moins", "tres", "euh", "bah", "ben",
    ]
    public static let englishTrailing: Set<String> = [
        "and", "but", "or", "then", "so", "of", "the", "a", "an", "to", "with", "for", "on", "in", "at", "that", "which", "i", "you", "my", "your",
        "more", "less", "very", "um", "uh", "like", "maybe",
    ]
    /// Phrases a request ends with.
    public static let closingPhrases = ["merci", "s'il te plait", "s'il vous plait", "stp", "svp", "please", "thanks", "thank you", "c'est tout", "that's it"]

    public func completeness(_ snapshot: TranscriptSnapshot, grammar: EditPlan?, sinceTextChange: Double) -> Completeness {
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .incomplete }
        if !snapshot.volatile.isEmpty, sinceTextChange < parameters.volatileSettle { return .incomplete }
        if text.hasSuffix(",") || text.hasSuffix("-") { return .incomplete }
        let folded = text.normalizedForMatching
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        if let last = words.last {
            let bare = last.hasPrefix("'") ? String(last.dropFirst()) : last
            if Self.frenchTrailing.contains(bare) || Self.englishTrailing.contains(bare) { return .incomplete }
        }
        if let grammar, !grammar.isEmpty, grammar.confidence >= 0.85, grammar.clarification == nil { return .complete }
        if text.hasSuffix("?") || text.hasSuffix("!") { return .complete }
        let stripped = folded.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if Self.closingPhrases.contains(where: { stripped == $0 || stripped.hasSuffix(" " + $0) }) { return .complete }
        return .likely
    }

    /// Seconds of silence after which a turn of this completeness is committed.
    public func threshold(_ completeness: Completeness) -> Double {
        switch completeness {
        case .complete: return parameters.commitComplete
        case .likely: return parameters.commitLikely
        case .incomplete: return parameters.commitIncomplete
        }
    }

    /// Commit or wait. Too little speech never commits; 2.5 s of silence always does;
    /// a 30 s turn commits at the first short pause.
    public func shouldCommit(silence: Double, speechDuration: Double, completeness: Completeness) -> Bool {
        guard speechDuration >= parameters.minSpeech else { return false }
        if silence >= parameters.hardSilenceCap { return true }
        if speechDuration >= parameters.maxTurn, silence >= 0.2 { return true }
        return silence >= threshold(completeness)
    }
}
