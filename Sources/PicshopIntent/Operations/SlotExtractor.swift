import Foundation
import PicshopCore

/// Typed values a request carries ("50 %", "3 secondes", "page 2", "16:9", "les bleus",
/// "ombres bleues"). Retrieval boosts the operations with a parameter of that type;
/// abstention reads the colour-band and tinted-range slots as pro colour vocabulary.
public struct OperationSlots: Sendable, Equatable {
    /// Units said next to a number.
    public var units: Set<OpUnit> = []
    /// A page number ("page 3").
    public var page: Int?
    /// A frame ratio ("16:9", "4 par 5").
    public var ratio = false
    /// Colour names said (folded).
    public var colors: [String] = []
    /// Mixer bands said as a plural group ("les bleus", "the greens"): English band names.
    public var bands: [String] = []
    /// Tonal ranges said with a tint ("ombres bleues", "orange highlights"): ColorGrade.Range raw values.
    public var tintedRanges: [String] = []
    /// Every number said.
    public var numbers: [Double] = []

    public init() {}

    public var isEmpty: Bool { self == OperationSlots() }
}

public enum SlotExtractor {
    public static func extract(_ text: String) -> OperationSlots {
        extract(tokens: TextFolding.tokens(text))
    }

    public static func extract(tokens: [String]) -> OperationSlots {
        var slots = OperationSlots()
        for (index, token) in tokens.enumerated() {
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            let previous = index > 0 ? tokens[index - 1] : ""
            if let value = number(token) {
                slots.numbers.append(value)
                if next == "%" || percentWords.contains(next) || (next == "pour" && index + 2 < tokens.count && tokens[index + 2] == "cent") {
                    slots.units.insert(.percent)
                }
                if secondWords.contains(next) { slots.units.insert(.seconds) }
                if degreeWords.contains(next) { slots.units.insert(.degrees) }
                if timesWords.contains(next) { slots.units.insert(.multiplier) }
                if pageWords.contains(previous), value >= 1, value == value.rounded() { slots.page = Int(value) }
                if ["par", "by", "sur"].contains(next), index + 2 < tokens.count, let other = number(tokens[index + 2]), value <= 21, other <= 21 {
                    slots.ratio = true
                }
            }
            if token.contains(":"), token.split(separator: ":").count == 2, token.split(separator: ":").allSatisfy({ Int($0) != nil }) { slots.ratio = true }
            if token.hasPrefix("x"), Double(token.dropFirst()) != nil { slots.units.insert(.multiplier) }
            if ["twice", "double"].contains(token) { slots.units.insert(.multiplier) }
            if colorWords.contains(token) { slots.colors.append(token) }
            if pluralGroupWords.contains(previous), let band = bandPlurals[token] { slots.bands.append(band) }
        }
        slots.tintedRanges = tintedRanges(tokens)
        return slots
    }

    /// "ombres bleues", "hautes lumières orangées", "teal shadows", "warm highlights".
    static func tintedRanges(_ tokens: [String]) -> [String] {
        var found: [String] = []
        for (index, token) in tokens.enumerated() {
            var range: String?
            var span = 1
            if ["ombres", "ombre", "shadows", "shadow"].contains(token) { range = "shadows" }
            if ["highlights", "highlight"].contains(token) { range = "highlights" }
            if ["midtones", "mids"].contains(token) { range = "midtones" }
            if index + 1 < tokens.count {
                let pair = token + " " + tokens[index + 1]
                if ["hautes lumieres", "haute lumiere", "hautes lumiere"].contains(pair) { range = "highlights"; span = 2 }
                if ["tons moyens", "demi teintes", "tons medians"].contains(pair) { range = "midtones"; span = 2 }
            }
            guard let range else { continue }
            let window = tokens[max(0, index - 2)..<min(tokens.count, index + span + 3)]
            if window.contains(where: { tintWords.contains($0) }) { found.append(range) }
        }
        return found
    }

    static func number(_ token: String) -> Double? {
        guard let first = token.first, first.isNumber || first == "-" else { return nil }
        return Double(token)
    }

    static let percentWords: Set<String> = ["pourcent", "pourcents", "percent", "pct"]
    static let secondWords: Set<String> = ["s", "sec", "seconde", "secondes", "second", "seconds", "secs"]
    static let degreeWords: Set<String> = ["deg", "degre", "degres", "degree", "degrees"]
    static let timesWords: Set<String> = ["fois", "times", "x"]
    static let pageWords: Set<String> = ["page", "p", "pages"]
    static let pluralGroupWords: Set<String> = ["les", "des", "aux", "the"]

    /// Plural colour words that name a mixer band.
    static let bandPlurals: [String: String] = [
        "rouges": "red", "reds": "red", "oranges": "orange", "jaunes": "yellow", "yellows": "yellow", "verts": "green", "greens": "green",
        "cyans": "aqua", "aquas": "aqua", "turquoises": "aqua", "bleus": "blue", "blues": "blue", "violets": "purple", "purples": "purple",
        "magentas": "magenta", "roses": "magenta", "pinks": "magenta",
    ]

    static let colorWords: Set<String> = [
        "rouge", "rouges", "red", "orange", "oranges", "jaune", "jaunes", "yellow", "vert", "verte", "verts", "vertes", "green", "bleu", "bleue",
        "bleus", "bleues", "blue", "violet", "violette", "purple", "rose", "pink", "magenta", "cyan", "turquoise", "teal", "blanc", "blanche",
        "white", "noir", "noire", "black", "gris", "grise", "gray", "grey", "marron", "brown",
    ]

    /// Colour and temperature words that tint a tonal range.
    static let tintWords: Set<String> = [
        "bleu", "bleue", "bleues", "bleus", "blue", "orange", "orangee", "orangees", "oranges", "chaud", "chaude", "chaudes", "chauds", "warm",
        "warmer", "froid", "froide", "froides", "froids", "cool", "cold", "teal", "sarcelle", "vert", "verte", "vertes", "green", "rouge",
        "rouges", "red", "magenta", "jaune", "jaunes", "yellow", "violet", "violettes", "purple", "cyan", "rose", "roses", "pink", "dorees",
        "doree", "golden",
    ]
}
