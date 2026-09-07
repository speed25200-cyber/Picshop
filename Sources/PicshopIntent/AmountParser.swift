import Foundation
import PicshopCore

/// Extracts "how much" from a segment: explicit numbers, qualifiers and direction words.
public enum AmountParser {
    public enum Qualifier: Sendable {
        case slight
        case strong
    }

    public struct Magnitude: Sendable {
        /// Normalised explicit value (percent / 100) if the user said a number.
        public var explicitNumber: Double?
        public var qualifier: Qualifier?
        /// True when the number was introduced by "to"/"à"/"at"/"set … to".
        public var isAbsolute: Bool
        public var hasExplicitNegative: Bool
        public var hasExplicitPositive: Bool
    }

    static let slightWords: [String] = ["un peu", "un petit peu", "legerement", "leger", "legere", "a bit", "a little", "a little bit", "slightly", "a touch", "a tad", "subtly", "subtilement", "subtil", "un poil", "un chouia", "un tout petit peu", "doucement", "gently", "softly", "juste un peu", "just a bit", "just a little", "a hair", "a smidge", "modestly", "peu", "subtle", "gentle", "gently", "mild", "mildly", "delicat", "delicatement", "discret", "discretement"]
    static let strongWords: [String] = ["beaucoup", "fort", "fortement", "vraiment", "tres", "carrement", "enormement", "a lot", "much", "way", "really", "strongly", "heavily", "a ton", "big", "significantly", "a bunch", "massively", "franchement", "bien plus", "much more", "much less", "far", "considerably", "drastically", "hugely", "super"]
    static let maxWords: [String] = ["au maximum", "au max", "a fond", "max", "maximum", "all the way", "fully", "completement", "completely", "to the max", "totalement", "totally", "maximal", "au taquet", "a donf", "cranked"]
    static let resetWords: [String] = ["reset", "remets a zero", "remise a zero", "remet a zero", "neutre", "neutral", "a zero", "to zero", "zero", "par defaut", "default", "normal", "remets le normal", "reinitialise", "back to normal", "comme avant", "annule le", "annule la"]
    static let tooWords: [String] = ["too", "trop", "too much", "trop de", "way too", "beaucoup trop", "excessive", "excessif", "excessivement", "overly"]
    static let negativeWords: [String] = ["moins", "diminue", "diminuer", "diminues", "baisse", "baisser", "baisses", "reduis", "reduire", "reduit", "descends", "descendre", "decrease", "lower", "reduce", "less", "down", "drop", "minus", "cut", "tone down", "attenue", "attenuer", "abaisse", "abaisser", "enleve un peu de", "remove some", "soften", "dial down", "dial back", "bring down", "turn down", "ease off", "un peu moins", "a bit less", "slightly less"]
    static let positiveWords: [String] = ["plus", "augmente", "augmenter", "augmentes", "monte", "monter", "increase", "raise", "boost", "more", "up", "bump", "bump up", "add", "ajoute", "pousse", "push", "crank", "renforce", "accentue", "accentuer", "intensifie", "intensify", "amplifie", "amplify", "turn up", "bring up", "dial up", "rajoute", "davantage", "un peu plus", "a bit more", "slightly more", "strengthen", "enhance", "pump", "pump up", "remonte"]
    static let setVerbs: [String] = ["set", "mets", "met", "mettre", "regle", "regler", "fixe", "fixer", "place", "put", "adjust to", "ajuste a", "regle a", "mets a", "set to", "at", "a"]
    static let absoluteMarkers: [String] = ["to", "at", "a", "sur", "au niveau", "at level", "vers"]
    static let relativeMarkers: [String] = ["by", "de", "d", "of"]

    public static func magnitude(in u: NormalizedUtterance) -> Magnitude {
        var result = Magnitude(explicitNumber: nil, qualifier: nil, isAbsolute: false, hasExplicitNegative: false, hasExplicitPositive: false)
        if u.contains(slightWords) { result.qualifier = .slight }
        if u.contains(strongWords) { result.qualifier = .strong }

        let tokens = u.tokens
        if let number = NumberWords.firstNumber(in: tokens) {
            var value = number.value
            let numberToken = tokens[number.index]
            if numberToken.hasPrefix("+") { result.hasExplicitPositive = true }
            let before = number.index > 0 ? tokens[number.index - 1] : ""
            let twoBefore = number.index > 1 ? tokens[number.index - 2] : ""
            let after = number.index + number.consumed < tokens.count ? tokens[number.index + number.consumed] : ""
            if before == "moins" || before == "minus" || before == "-" || numberToken.hasPrefix("-") {
                result.hasExplicitNegative = true
            }
            if before == "plus" && twoBefore != "un" && twoBefore != "de" && twoBefore != "a" {
                // "plus 20" in French means "+20".
                result.hasExplicitPositive = true
            }
            let isPercent = after == "pourcent" || after == "percent" || after == "pour" || after == "%"
            // Values above 1 are percents; values within [-1, 1] are already normalised unless followed by a percent word.
            if abs(value) > 1 || isPercent {
                value /= 100
            }
            // Speed multipliers / degrees are parsed elsewhere; here everything is normalised to [-1, 1].
            result.explicitNumber = min(max(value, -1), 1)
            if absoluteMarkers.contains(before) || (before == "at" || before == "to") || absoluteMarkers.contains(twoBefore) && before == "niveau" {
                result.isAbsolute = true
            }
            if before == "a", twoBefore == "de" { result.isAbsolute = false } // "de 20 à 30"? rare; keep relative
            if relativeMarkers.contains(before) { result.isAbsolute = false }
            if u.contains(["set", "regle", "regler", "fixe", "fixer", "mets a", "met a", "set to", "put at", "ajuste a"]) && !relativeMarkers.contains(before) {
                result.isAbsolute = true
            }
        }
        return result
    }

    /// +1 / -1 / 0 from direction words.
    public static func sign(in u: NormalizedUtterance) -> Int {
        let negative = u.contains(negativeWords)
        let positive = u.contains(positiveWords)
        if negative && !positive { return -1 }
        if positive && !negative { return 1 }
        if negative && positive {
            // "un peu moins" contains "un peu" (positive list has "un peu plus" only) — decide on the last word that appears.
            let lastNegative = negativeWords.compactMap { u.tokenIndex(of: $0) }.max() ?? -1
            let lastPositive = positiveWords.compactMap { u.tokenIndex(of: $0) }.max() ?? -1
            return lastNegative > lastPositive ? -1 : 1
        }
        return 0
    }
}
