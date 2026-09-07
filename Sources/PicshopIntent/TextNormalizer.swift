import Foundation
import PicshopCore

/// Tokenised, accent-folded view of an utterance with helpers used by the
/// rule-based parser.
public struct NormalizedUtterance: Sendable {
    public let original: String
    public let text: String
    public let tokens: [String]
    public let language: Language

    public enum Language: String, Sendable {
        case french = "fr"
        case english = "en"
    }

    public init(_ original: String) {
        self.original = original
        let normalized = NormalizedUtterance.normalize(original)
        text = normalized
        tokens = normalized.split(separator: " ").map(String.init)
        language = NormalizedUtterance.detectLanguage(tokens: tokens)
    }

    /// Lowercases, strips diacritics, expands elisions ("l'arbre" → "l arbre"),
    /// turns punctuation into spaces and collapses whitespace.
    public static func normalize(_ input: String) -> String {
        var s = input.normalizedForMatching
        s = s.replacingOccurrences(of: "'", with: " ")
        s = s.replacingOccurrences(of: "(?<![0-9])-(?=[0-9])", with: " -", options: .regularExpression)
        s = s.replacingOccurrences(of: "-(?![0-9])", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "%", with: " pourcent ")
        s = s.replacingOccurrences(of: "×", with: " x ")
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == ":" || scalar == "." || scalar == "+" || scalar == "," || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else {
                out.append(" ")
            }
        }
        // Keep decimal numbers ("1.5", "1,5") but treat other commas/periods as separators.
        var cleaned = ""
        let chars = Array(out)
        for (index, character) in chars.enumerated() {
            if character == "." || character == "," {
                let previousIsDigit = index > 0 && chars[index - 1].isNumber
                let nextIsDigit = index + 1 < chars.count && chars[index + 1].isNumber
                cleaned.append(previousIsDigit && nextIsDigit ? "." : " ")
            } else {
                cleaned.append(character)
            }
        }
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func detectLanguage(tokens: [String]) -> Language {
        let frenchMarkers: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "de", "et", "sur", "dans", "efface", "enleve", "supprime",
                                          "retire", "mets", "ajoute", "augmente", "diminue", "baisse", "plus", "moins", "fond", "photo", "video",
                                          "gauche", "droite", "peu", "beaucoup", "tres", "avec", "pour", "au", "aux", "ce", "cette", "ca",
                                          "coupe", "recadre", "tourne", "annule", "retablis", "reviens", "montre", "applique", "rends", "fais", "remets"]
        let englishMarkers: Set<String> = ["the", "a", "an", "and", "on", "in", "remove", "erase", "delete", "make", "add", "increase", "decrease",
                                           "more", "less", "background", "photo", "video", "left", "right", "bit", "lot", "very", "with", "for",
                                           "this", "that", "it", "cut", "crop", "rotate", "undo", "redo", "show", "apply", "set", "put", "to", "of"]
        var fr = 0
        var en = 0
        for token in tokens {
            if frenchMarkers.contains(token) { fr += 1 }
            if englishMarkers.contains(token) { en += 1 }
        }
        if fr == en {
            // Tie-break on typical French endings.
            let frenchEndings = tokens.filter { $0.hasSuffix("ez") || $0.hasSuffix("er") || $0.hasSuffix("tion") }.count
            return frenchEndings > 0 ? .french : .english
        }
        return fr > en ? .french : .english
    }

    /// True if any of the given phrases (already normalised) occurs as a whole-word sequence.
    public func contains(_ phrases: [String]) -> Bool {
        phrases.contains { containsPhrase($0) }
    }

    public func containsPhrase(_ phrase: String) -> Bool {
        let padded = " " + text + " "
        return padded.contains(" " + phrase + " ")
    }

    /// Returns the first phrase in `phrases` that occurs, longest first.
    public func firstMatch(_ phrases: [String]) -> String? {
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where containsPhrase(phrase) {
            return phrase
        }
        return nil
    }

    /// Index of the first token of `phrase` in `tokens`, if present.
    public func tokenIndex(of phrase: String) -> Int? {
        let words = phrase.split(separator: " ").map(String.init)
        guard !words.isEmpty, tokens.count >= words.count else { return nil }
        for start in 0...(tokens.count - words.count) where Array(tokens[start..<(start + words.count)]) == words {
            return start
        }
        return nil
    }

    /// Text after the first occurrence of any phrase (longest match wins).
    public func remainder(after phrases: [String]) -> String? {
        var best: (index: Int, length: Int)?
        for phrase in phrases {
            if let index = tokenIndex(of: phrase) {
                let length = phrase.split(separator: " ").count
                if best == nil || index < best!.index || (index == best!.index && length > best!.length) {
                    best = (index, length)
                }
            }
        }
        guard let best else { return nil }
        let rest = tokens[(best.index + best.length)...]
        return rest.joined(separator: " ")
    }
}

/// Splits one utterance into several commands ("erase the dog and make it brighter").
public enum UtteranceSegmenter {
    /// Phrases that contain a conjunction but must not be split.
    static let protectedPhrases: [String] = [
        "noir et blanc", "black and white", "teal and orange", "teal et orange", "rock and roll", "light and airy", "bright and clean", "avant apres", "before and after", "before after", "avant et apres",
        "and then", "et ensuite", "et puis", "et apres", "and after that", "et aussi", "and also", "et en plus",
    ]

    static let separators: [String] = [" puis ", " ensuite ", " apres ca ", " apres ", " then ", " and then ", " et aussi ", " and also ", " et ", " and ", " , ", " ; "]

    public static func segments(of normalizedText: String) -> [String] {
        var text = " " + normalizedText + " "
        var placeholders: [String: String] = [:]
        for (index, phrase) in protectedPhrases.sorted(by: { $0.count > $1.count }).enumerated() {
            let token = " __p\(index)__ "
            if text.contains(" " + phrase + " ") {
                placeholders[token.trimmingCharacters(in: .whitespaces)] = phrase
                text = text.replacingOccurrences(of: " " + phrase + " ", with: token)
            }
        }
        // "and then" / "et puis" become plain separators after protection.
        for (token, phrase) in placeholders where ["and then", "et ensuite", "et puis", "et apres", "and after that", "et aussi", "and also", "et en plus"].contains(phrase) {
            text = text.replacingOccurrences(of: token, with: " puis ")
        }
        var parts = [text]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { part in
            var restored = part
            for (token, phrase) in placeholders {
                restored = restored.replacingOccurrences(of: token, with: phrase)
            }
            return restored.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty }
    }
}
