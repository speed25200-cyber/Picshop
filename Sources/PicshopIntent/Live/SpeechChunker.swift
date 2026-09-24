import Foundation
import PicshopCore

/// Cuts streaming reply text into chunks the speech synthesizer can start on
/// early: a short first chunk, then whole sentences.
///
/// - The first chunk flushes at the first comma (or ; : dash) once there are
///   4 words, or after 12 words.
/// - Later chunks are whole sentences; past 28 words, a sentence is split at
///   its last comma, else at a word boundary.
/// - Never inside a number (3.5, 10:30), an abbreviation, a URL or a quote.
public struct SpeechChunker: Sendable {
    public struct Parameters: Sendable {
        public var firstMinWords = 4
        public var firstMaxWords = 12
        public var maxWords = 28

        public init() {}
    }

    private let language: NormalizedUtterance.Language
    private let parameters: Parameters
    private var buffer = ""
    private var emitted = 0
    public private(set) var lastEndsWithQuestion = false

    static let abbreviations: Set<String> = [
        "m.", "mme.", "mlle.", "dr.", "etc.", "cf.", "p.", "ex.", "mr.", "mrs.", "ms.", "e.g.", "i.e.", "vs.", "approx.", "st.", "no.", "n°.", "av.", "bd.",
    ]
    static let terminators: Set<Character> = [".", "!", "?", "…"]
    static let closers: Set<Character> = ["\"", "»", "”", "’", ")", "]"]

    public init(language: NormalizedUtterance.Language) {
        self.init(language: language, parameters: Parameters())
    }

    public init(language: NormalizedUtterance.Language, parameters: Parameters) {
        self.language = language
        self.parameters = parameters
    }

    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var chunks: [String] = []
        while let cut = nextCut(final: false) {
            emit(String(buffer[..<cut]), into: &chunks)
            buffer = String(buffer[cut...])
        }
        return chunks
    }

    public mutating func finish() -> [String] {
        var chunks: [String] = []
        while let cut = nextCut(final: true) {
            emit(String(buffer[..<cut]), into: &chunks)
            buffer = String(buffer[cut...])
        }
        emit(buffer, into: &chunks)
        buffer = ""
        return chunks
    }

    private mutating func emit(_ raw: String, into chunks: inout [String]) {
        let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }
        chunks.append(chunk)
        emitted += 1
        let tail = chunk.trimmingCharacters(in: CharacterSet(charactersIn: "\"»”’)] \u{202F}\u{00A0}"))
        lastEndsWithQuestion = tail.hasSuffix("?")
    }

    /// Where the next chunk ends in the buffer, or nil to wait for more text.
    private func nextCut(final: Bool) -> String.Index? {
        let characters = Array(buffer)
        guard !characters.isEmpty else { return nil }
        var inQuote = false
        var words = 0
        var inWord = false
        var lastComma: (offset: Int, words: Int)?
        var boundaryAfterWord: [Int: Int] = [:]   // word count -> offset just after that word
        let isFirst = emitted == 0

        func index(_ offset: Int) -> String.Index { buffer.index(buffer.startIndex, offsetBy: offset) }
        func followedBySpace(_ offset: Int) -> Bool {
            offset + 1 < characters.count ? characters[offset + 1].isWhitespace : final
        }

        for offset in characters.indices {
            let character = characters[offset]
            if character.isWhitespace {
                if inWord {
                    inWord = false
                    boundaryAfterWord[words] = offset
                }
            } else if !inWord {
                inWord = true
                if character.isLetter || character.isNumber { words += 1 } else { inWord = false }
            }
            switch character {
            case "«", "“": inQuote = true
            case "»", "”": inQuote = false
            case "\"": inQuote.toggle()
            default: break
            }
            guard !inQuote else { continue }

            if Self.terminators.contains(character), followedBySpace(offset) {
                if character == ".", isAbbreviation(characters, endingAt: offset) { continue }
                var end = offset + 1
                while end < characters.count, Self.closers.contains(characters[end]) { end += 1 }
                return index(end)
            }
            if character == "," || character == ";" || character == ":" || character == "—" || (character == "-" && offset > 0 && characters[offset - 1].isWhitespace) {
                guard followedBySpace(offset), !(offset > 0 && characters[offset - 1].isNumber && offset + 1 < characters.count && characters[offset + 1].isNumber) else { continue }
                if character == "," { lastComma = (offset, words) }
                if isFirst, words >= parameters.firstMinWords { return index(offset + 1) }
            }
            if isFirst, words > parameters.firstMaxWords, let cut = boundaryAfterWord[parameters.firstMaxWords] {
                return index(cut)
            }
            if !isFirst, words > parameters.maxWords {
                if let comma = lastComma, comma.words >= parameters.firstMinWords { return index(comma.offset + 1) }
                if let cut = boundaryAfterWord[parameters.maxWords] { return index(cut) }
            }
        }
        return nil
    }

    private func isAbbreviation(_ characters: [Character], endingAt offset: Int) -> Bool {
        var start = offset
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        let token = String(characters[start...offset]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(«“\""))
        return Self.abbreviations.contains(token)
    }
}

/// Makes model text fit to be read aloud.
public enum SpeakableText {
    public static func clean(_ text: String) -> String {
        var result = text
        // URLs, then tags.
        result = result.replacingOccurrences(of: #"(https?://|www\.)[^\s]+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"</?[A-Za-z][^>]*>"#, with: " ", options: .regularExpression)
        // Markdown: headings, bullets, emphasis, code.
        result = result.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\*\*|__|\*|`+|~~)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![\p{L}\p{N}])_(?=\p{L})|(?<=\p{L})_(?![\p{L}\p{N}])"#, with: "", options: .regularExpression)
        // "×2" / "x2": fois deux, times two.
        let french = NormalizedUtterance(text).language == .french
        result = replaceMultipliers(in: result, french: french)
        // Arrows, emoji and pictographs.
        var scalars = String.UnicodeScalarView()
        for scalar in result.unicodeScalars {
            let properties = scalar.properties
            let isArrow = (0x2190...0x21FF).contains(scalar.value) || (0x27F0...0x27FF).contains(scalar.value) || (0x2900...0x297F).contains(scalar.value)
            let isPictograph = properties.isEmojiPresentation || (properties.isEmoji && scalar.value > 0xFF && !(0x2000...0x206F).contains(scalar.value))
            let isJoiner = scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) || properties.isEmojiModifier
            if isArrow { scalars.append(" ") } else if !isPictograph && !isJoiner { scalars.append(scalar) }
        }
        result = String(scalars)
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func replaceMultipliers(in text: String, french: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[x×]\s?(\d+(?:[.,]\d+)?)(?![\p{L}\p{N}])"#) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let number = source.substring(with: match.range(at: 1))
            result += (french ? "fois " : "times ") + spelled(number, french: french)
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }

    private static func spelled(_ number: String, french: Bool) -> String {
        let french1to10 = ["un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf", "dix"]
        let english1to10 = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        guard let value = Int(number), (1...10).contains(value) else { return french ? number.replacingOccurrences(of: ".", with: ",") : number }
        return (french ? french1to10 : english1to10)[value - 1]
    }
}
