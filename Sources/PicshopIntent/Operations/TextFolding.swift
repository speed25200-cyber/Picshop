import Foundation
import PicshopCore

/// The text processing retrieval and abstention share: lowercase, accents folded,
/// punctuation to spaces, and a small French/English suffix stemmer. Pure Swift with
/// its own folding table, so a query folds to the same tokens on Linux and on iOS.
public enum TextFolding {
    /// Lowercased, accents and ligatures folded, apostrophes and punctuation turned into
    /// spaces; decimals ("1.5"), ratios ("16:9") and "%" kept as tokens.
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        func flush() {
            if !current.isEmpty { tokens.append(String(current)) }
            current = String.UnicodeScalarView()
        }
        for (index, scalar) in scalars.enumerated() {
            if fold(scalar, into: &current) { continue }
            let previousIsDigit = index > 0 && isDigit(scalars[index - 1])
            let nextIsDigit = index + 1 < scalars.count && isDigit(scalars[index + 1])
            switch scalar {
            case ".", ",", ":":
                // 1.5, 1,5 → 1.5; 16:9 stays one token; anything else separates.
                if previousIsDigit && nextIsDigit { current.append(scalar == ":" ? ":" : ".") } else { flush() }
            case "%":
                flush()
                tokens.append("%")
            case "°":
                flush()
                tokens.append("deg")
            case "-" where !previousIsDigit && nextIsDigit && current.isEmpty:
                current.append("-")
            default:
                flush()
            }
        }
        flush()
        return splitElisions(tokens)
    }

    /// The speech recogniser sometimes drops the apostrophe of an elided article ("lhorizon",
    /// "dabord"): "l" or "d" glued to a word of `elided` is split back into two tokens, so it folds
    /// like "l'horizon". Only listed words: "lent", "dans" or "date" are never cut.
    static func splitElisions(_ tokens: [String]) -> [String] {
        guard tokens.contains(where: { $0.count > 3 && ($0.hasPrefix("l") || $0.hasPrefix("d")) }) else { return tokens }
        var result: [String] = []
        result.reserveCapacity(tokens.count + 1)
        for token in tokens {
            if token.count > 3, let first = token.first, first == "l" || first == "d", elided.contains(String(token.dropFirst())) {
                result.append(String(first))
                result.append(String(token.dropFirst()))
            } else {
                result.append(token)
            }
        }
        return result
    }

    /// Words that start with a vowel or a mute h and that an editor hears after "l'" or "d'".
    static let elided: Set<String> = [
        "horizon", "histogramme", "herbe", "homme", "hiver", "abord", "ombre", "ombres", "image", "images", "objet", "objets", "oiseau", "oiseaux",
        "opacite", "eclairage", "exposition", "ecran", "effet", "effets", "element", "elements", "arriere", "avant", "angle", "audio", "arbre",
        "eau", "oeil", "interieur", "exterieur", "ensemble", "intro", "outro", "ordre", "original", "originale", "echelle", "etiquette",
        "affiche", "album", "aspect", "encre", "entete", "espace", "ete", "automne", "animation", "annotation", "apercu", "arc", "ambiance",
    ]

    /// Every token stemmed, stopwords kept: what phrase matching compares.
    public static func stems(_ text: String) -> [String] {
        tokens(text).map(stem)
    }

    /// The tokens that carry meaning, stemmed: what BM25 scores.
    public static func contentStems(_ text: String) -> [String] {
        tokens(text).filter { !stopwords.contains($0) && $0 != "%" }.map(stem)
    }

    /// "layerOpacity" → "layer opacity", "removeLUT" → "remove lut".
    public static func camelWords(_ id: String) -> String {
        var words: [String] = []
        var current = ""
        let characters = Array(id)
        for (index, character) in characters.enumerated() {
            let startsWord = character.isUppercase && !current.isEmpty
                && (!(characters[index - 1].isUppercase) || (index + 1 < characters.count && characters[index + 1].isLowercase))
            if startsWord {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }.joined(separator: " ")
    }

    /// Light French/English stemming: the longest known suffix comes off when at least three
    /// letters stay ("saturation", "saturer", "sature" → "satur"; "courbes" → "courb";
    /// "niveaux" → "niveau"). Numbers and short words are kept as they are.
    public static func stem(_ token: String) -> String {
        let stemmed = suffixStripped(token)
        return slang[stemmed] ?? stemmed
    }

    /// Colloquial verbs folded onto the stem of the word the catalog uses: "vire la musique"
    /// reads like "enlève la musique", "vire le dernier clip" like "enlève le dernier clip".
    static let slang: [String: String] = ["vir": "enlev"]

    static func suffixStripped(_ token: String) -> String {
        let bytes = Array(token.utf8)
        guard bytes.count > 3, let first = bytes.first, (first >= 97 && first <= 122) || first >= 128 else { return token }
        guard let last = bytes.last, let candidates = suffixesByLastByte[last] else { return token }
        for suffix in candidates where bytes.count - suffix.count >= 3 && bytes.ends(with: suffix) {
            // "ss", "us", "is" keep their s ("gris", "focus").
            if suffix.count == 1, last == 115, bytes.count >= 2 {
                let before = bytes[bytes.count - 2]
                if before == 115 || before == 117 || before == 105 { continue }
            }
            return String(decoding: bytes[0..<(bytes.count - suffix.count)], as: UTF8.self)
        }
        return token
    }

    /// Longest first.
    static let suffixes: [String] = suffixList.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
    /// The suffixes by their last byte, longest first: a token only tries the ones it can end with.
    static let suffixesByLastByte: [UInt8: [[UInt8]]] = {
        var table: [UInt8: [[UInt8]]] = [:]
        for suffix in suffixes {
            let bytes = Array(suffix.utf8)
            if let last = bytes.last { table[last, default: []].append(bytes) }
        }
        return table
    }()

    private static let suffixList: [String] = [
        "issements", "issement", "ements", "ations", "ateurs", "atrice", "ement", "ation", "ateur", "ances", "ences", "ities", "euses",
        "ments", "ables", "ated", "ates", "ions", "ment", "able", "ance", "ence", "euse", "ives", "ings", "ness", "ites",
        "ate", "ion", "ity", "ite", "eux", "ive", "ing", "ees", "ers", "ez", "er", "es", "ee", "ed", "ly", "s", "e", "x",
    ]

    /// Words that carry no operation: articles, pronouns, politeness, and the generic verbs
    /// every request starts with. "son" (the sound) and "euh" (a filler to cut) stay content.
    public static let stopwords: Set<String> = [
        // French
        "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "et", "ou", "a", "au", "aux", "en", "sur", "dans", "pour", "par", "avec",
        "ce", "cet", "cette", "ces", "ca", "cela", "mon", "ma", "mes", "ton", "ta", "tes", "sa", "ses", "notre", "votre", "leur", "leurs",
        "que", "qui", "quoi", "est", "sont", "c", "j", "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "m", "te", "t",
        "se", "s", "lui", "y", "ne", "n", "pas", "plus", "moins", "peu", "tres", "trop", "encore", "aussi", "bien", "tout", "toute", "tous",
        "toutes", "stp", "svp", "plait", "hum", "ok", "okay", "alors", "bon", "donc", "mais", "puis", "ensuite", "fais", "fait",
        "faire", "mets", "met", "mettre", "rends", "rend", "rendre", "peux", "veux", "voudrais", "pourrais", "moi", "toi", "qu",
        "comme", "si", "chose", "quelque", "petit", "petite", "vraiment", "juste", "maintenant", "ici", "voila", "super",
        // English
        "the", "a", "an", "to", "of", "in", "on", "at", "it", "its", "this", "that", "these", "those", "is", "be", "are", "me", "my", "your",
        "and", "or", "with", "for", "from", "by", "some", "more", "less", "bit", "little", "lot", "very", "too", "please", "can", "could",
        "would", "you", "i", "we", "do", "make", "put", "set", "just", "now", "here", "so", "then", "uh", "um", "something", "thing", "get",
        "let", "lets", "s", "much", "really", "also", "all",
    ]

    // MARK: Folding

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    /// Appends a letter or digit, lowercased and folded to ASCII; false for anything else.
    static func fold(_ scalar: Unicode.Scalar, into output: inout String.UnicodeScalarView) -> Bool {
        let value = scalar.value
        if (value >= 97 && value <= 122) || (value >= 48 && value <= 57) {
            output.append(scalar)
            return true
        }
        if value >= 65 && value <= 90, let lower = Unicode.Scalar(value + 32) {
            output.append(lower)
            return true
        }
        guard value >= 128 else { return false }
        if let folded = accents[scalar] {
            output.append(contentsOf: folded.unicodeScalars)
            return true
        }
        guard scalar.properties.isAlphabetic else { return false }
        output.append(contentsOf: String(scalar).lowercased().unicodeScalars)
        return true
    }

    static let accents: [Unicode.Scalar: String] = {
        var table: [Unicode.Scalar: String] = [:]
        let groups: [(String, String)] = [
            ("àâäáãåā", "a"), ("ç", "c"), ("éèêëē", "e"), ("îïíì", "i"), ("ôöóòõø", "o"), ("ùûüú", "u"), ("ÿý", "y"), ("ñ", "n"),
            ("ÀÂÄÁÃÅ", "a"), ("Ç", "c"), ("ÉÈÊË", "e"), ("ÎÏÍÌ", "i"), ("ÔÖÓÒÕØ", "o"), ("ÙÛÜÚ", "u"), ("Ÿ", "y"), ("Ñ", "n"),
        ]
        for (letters, ascii) in groups { for scalar in letters.unicodeScalars { table[scalar] = ascii } }
        table["œ"] = "oe"
        table["Œ"] = "oe"
        table["æ"] = "ae"
        table["Æ"] = "ae"
        table["ß"] = "ss"
        return table
    }()
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        guard count >= suffix.count else { return false }
        var index = count - suffix.count
        for byte in suffix {
            if self[index] != byte { return false }
            index += 1
        }
        return true
    }
}
