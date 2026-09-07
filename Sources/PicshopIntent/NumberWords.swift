import Foundation

/// Parses spoken numbers in French and English ("vingt cinq", "twenty five",
/// "1.5", "half", "deux fois") from token arrays.
public enum NumberWords {
    static let english: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "half": 0.5, "quarter": 0.25, "double": 2, "triple": 3, "a": 1, "an": 1,
    ]

    static let french: [String: Double] = [
        "zero": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
        "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16, "vingt": 20, "trente": 30, "quarante": 40,
        "cinquante": 50, "soixante": 60, "cent": 100, "demi": 0.5, "demie": 0.5, "moitie": 0.5, "quart": 0.25, "double": 2, "triple": 3,
    ]

    /// Attempts to read a number starting at `index`. Returns the value and the
    /// number of tokens consumed.
    public static func parse(_ tokens: [String], at index: Int) -> (value: Double, consumed: Int)? {
        guard index < tokens.count else { return nil }
        let first = tokens[index]
        if let numeric = Double(first.replacingOccurrences(of: ",", with: ".")) {
            return (numeric, 1)
        }
        if first.hasPrefix("+"), let numeric = Double(first.dropFirst()) {
            return (numeric, 1)
        }
        if first.hasSuffix("x") || first.hasSuffix("×"), let numeric = Double(first.dropLast()) {
            return (numeric, 1)
        }
        if first.hasPrefix("x"), let numeric = Double(first.dropFirst()) {
            return (numeric, 1)
        }
        guard let firstValue = english[first] ?? french[first] else { return nil }
        // Articles alone are not numbers ("a dog"), only in "a bit"/"a half".
        if (first == "a" || first == "an" || first == "un" || first == "une"), index + 1 < tokens.count {
            let next = tokens[index + 1]
            if next == "half" || next == "quarter" || next == "demi" || next == "quart" {
                return (english[next] ?? french[next] ?? 1, 2)
            }
            return nil
        }
        var total = 0.0
        var current = firstValue
        var consumed = 1
        var cursor = index + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token == "et" || token == "and" {
                if cursor + 1 < tokens.count, let value = english[tokens[cursor + 1]] ?? french[tokens[cursor + 1]], value < 20 {
                    current += value
                    cursor += 2
                    consumed += 2
                    continue
                }
                break
            }
            if token == "hundred" || token == "cent" || token == "cents" {
                current *= 100
                cursor += 1
                consumed += 1
                continue
            }
            if token == "vingts" {
                current *= 20
                cursor += 1
                consumed += 1
                continue
            }
            guard let value = english[token] ?? french[token] else { break }
            if value >= 20 && current >= 20 && current.truncatingRemainder(dividingBy: 20) == 0 && (current == 60 || current == 80) {
                // "soixante dix", "quatre vingt dix"
                current += value
            } else if value < 20 && current >= 20 {
                current += value
            } else if value == 20 && current == 4 {
                current = 80
            } else if value >= 20 && current < 20 {
                total += current
                current = value
            } else {
                break
            }
            cursor += 1
            consumed += 1
        }
        return (total + current, consumed)
    }

    /// Finds the first number anywhere in the tokens.
    public static func firstNumber(in tokens: [String]) -> (value: Double, index: Int, consumed: Int)? {
        for index in tokens.indices {
            if let parsed = parse(tokens, at: index) {
                return (parsed.value, index, parsed.consumed)
            }
        }
        return nil
    }

    /// Ordinal words → 1-based index.
    public static func ordinal(_ token: String) -> Int? {
        let table: [String: Int] = [
            "first": 1, "1st": 1, "premier": 1, "premiere": 1, "1er": 1, "1ere": 1,
            "second": 2, "2nd": 2, "deuxieme": 2, "seconde": 2, "2eme": 2, "2e": 2,
            "third": 3, "3rd": 3, "troisieme": 3, "3eme": 3, "3e": 3,
            "fourth": 4, "4th": 4, "quatrieme": 4, "4eme": 4,
            "fifth": 5, "5th": 5, "cinquieme": 5, "5eme": 5,
            "last": -1, "dernier": -1, "derniere": -1,
        ]
        return table[token]
    }
}

/// Parses durations and timestamps ("10 secondes", "1 minute 30", "0:45", "at 2 minutes").
public enum TimeExpressions {
    static let secondWords: Set<String> = ["s", "sec", "secs", "second", "seconds", "seconde", "secondes"]
    static let minuteWords: Set<String> = ["min", "mins", "minute", "minutes"]
    static let frameWords: Set<String> = ["frame", "frames", "image", "images"]
    static let adjectiveWords: Set<String> = ["premieres", "premiere", "premiers", "premier", "dernieres", "derniere", "derniers", "dernier", "first", "last", "next", "prochaines", "prochains", "suivantes", "suivants"]
    static let rangeConnectors: Set<String> = ["a", "to", "et", "and", "jusqu", "-"]

    /// Reads a time (in seconds) starting at `index`. Supports "mm:ss", "1 minute 30",
    /// "45 secondes", "2 min". Returns seconds and tokens consumed.
    public static func parse(_ tokens: [String], at index: Int, frameRate: Double = 30) -> (seconds: Double, consumed: Int)? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        if token.contains(":") {
            let parts = token.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { return (parts[0] * 60 + parts[1], 1) }
            if parts.count == 3 { return (parts[0] * 3600 + parts[1] * 60 + parts[2], 1) }
        }
        guard let number = NumberWords.parse(tokens, at: index) else { return nil }
        var seconds = 0.0
        var consumed = number.consumed
        var cursor = index + number.consumed
        // "3 premières secondes", "first 3 seconds", "last two seconds", "next 5 seconds"
        while cursor < tokens.count, adjectiveWords.contains(tokens[cursor]) {
            cursor += 1
            consumed += 1
        }
        guard cursor < tokens.count else { return nil }
        let unit = tokens[cursor]
        if minuteWords.contains(unit) {
            seconds = number.value * 60
            consumed += 1
            cursor += 1
            if cursor < tokens.count, let rest = NumberWords.parse(tokens, at: cursor) {
                let afterRest = cursor + rest.consumed
                if afterRest < tokens.count, secondWords.contains(tokens[afterRest]) {
                    seconds += rest.value
                    consumed += rest.consumed + 1
                } else if afterRest >= tokens.count || !(minuteWords.contains(tokens[afterRest])) {
                    seconds += rest.value
                    consumed += rest.consumed
                }
            }
            return (seconds, consumed)
        }
        if secondWords.contains(unit) {
            return (number.value, consumed + 1)
        }
        if frameWords.contains(unit) {
            return (number.value / frameRate, consumed + 1)
        }
        return nil
    }

    /// Finds the first time expression anywhere in the tokens.
    public static func firstTime(in tokens: [String], frameRate: Double = 30) -> (seconds: Double, index: Int, consumed: Int)? {
        for index in tokens.indices {
            if let parsed = parse(tokens, at: index, frameRate: frameRate) {
                return (parsed.seconds, index, parsed.consumed)
            }
        }
        return nil
    }

    /// Finds every time expression, in order.
    public static func allTimes(in tokens: [String], frameRate: Double = 30) -> [Double] {
        var results: [Double] = []
        var index = 0
        while index < tokens.count {
            if let parsed = parse(tokens, at: index, frameRate: frameRate) {
                results.append(parsed.seconds)
                index += parsed.consumed
                continue
            }
            // "de 5 à 12 secondes" / "from 5 to 12 seconds": the first number borrows the unit of the second.
            if let bare = NumberWords.parse(tokens, at: index), !(tokens[index] == "a" || tokens[index] == "un" || tokens[index] == "une" || tokens[index] == "an") {
                let after = index + bare.consumed
                if after < tokens.count, rangeConnectors.contains(tokens[after]) {
                    var probe = after + 1
                    if probe < tokens.count, tokens[probe] == "a" { probe += 1 }
                    if probe < tokens.count, let second = parse(tokens, at: probe, frameRate: frameRate) {
                        let secondNumber = NumberWords.parse(tokens, at: probe)
                        let scale = (secondNumber?.value ?? 0) > 0 ? second.seconds / (secondNumber?.value ?? 1) : 1
                        let scaleIsUnit = tokens[probe].contains(":") ? 1 : scale
                        results.append(bare.value * scaleIsUnit)
                        results.append(second.seconds)
                        index = probe + second.consumed
                        continue
                    }
                }
                index += bare.consumed
                continue
            }
            index += 1
        }
        return results
    }
}
