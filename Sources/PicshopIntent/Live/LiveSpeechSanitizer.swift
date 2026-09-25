import Foundation
import PicshopCore

/// The last guard before a line built from executor or tool text is spoken or captioned (D11):
/// no English internal label inside « » in French (« subject » → « sujet », or the guillemets and
/// the label go), no machine code ("reason:no_subject", "table:…", "[no_table]"), no markup.
/// Lines Live writes itself (LiveLines) are clean by construction and pass through unchanged.
public enum LiveSpeechSanitizer {
    /// English words the app uses internally (labels, targets, codes) that must never be heard inside a
    /// French sentence. A French user phrase in « » ("« panneau »") is the user's own words and stays.
    static let internalLabels: Set<String> = [
        "subject", "object", "objects", "person", "people", "persons", "text", "background", "foreground", "sky", "face", "faces", "region", "area",
        "selection", "table", "cell", "cells", "data", "number", "numbers", "item", "thing", "target", "mask", "layer", "unknown", "none", "null",
        "nil", "sign", "car", "dog", "cat", "tree", "pole", "wire", "wires", "trash", "logo", "watermark", "hand", "hair", "eyes", "teeth", "skin",
        "building", "window", "lamp", "chair", "bottle", "cup", "glasses", "hat", "shadow", "blemish", "phone", "plate", "boat", "bird", "horse",
    ]

    /// Machine words that are never spoken in any language.
    static let machineWords: Set<String> = [
        "no_subject", "not_found", "no_table", "unknown_row", "unknown_column", "nothing_to_do", "too_many", "needs_selection", "unknown_ref",
        "bad_region", "no_text", "verify_failed", "needs_user", "needs_clarification", "select_region", "tap_to_erase", "crop_handles",
        "apply_edits", "propose_ideas", "compare_before_after", "loop_limit", "invalid_input",
    ]

    /// The camelCase action names, which no sentence says.
    static let actionNames: [String] = IntentAction.allCases.map(\.rawValue).filter { $0.contains(where: \.isUppercase) }
    static let actionPattern = #"\b("# + actionNames.joined(separator: "|") + #")\b"#
    static let machinePattern = #"\b("# + machineWords.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + #")\b"#

    /// Whether a line may hold anything `clean` removes: markup, a code, a guillemet, a colon, a camelCase
    /// name, a scene id or a cell address.
    static func needsLook(_ text: String) -> Bool {
        if text.contains(where: { "<>{}[]_:«»".contains($0) }) { return true }
        let lower = text.lowercased()
        if ["hint", "verif", "retry", "subject", "problem"].contains(where: { lower.contains($0) }) { return true }
        if containsSceneID(text) { return true }
        return actionNames.contains { text.contains($0) }
    }

    /// "t3", "l2", "o1", "f1" (scene ids) and "r6c3" (a cell address) as whole words: what the grounding lines
    /// teach the model, never what a person hears ("J'efface t neuf").
    static func containsSceneID(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { word in
            let lower = word.lowercased()
            guard let first = lower.first else { return false }
            if "tlof".contains(first), (2...4).contains(lower.count), lower.dropFirst().allSatisfy(\.isNumber) { return true }
            if first == "r", let c = lower.firstIndex(of: "c"), c > lower.index(after: lower.startIndex),
               lower[lower.index(after: lower.startIndex)..<c].allSatisfy(\.isNumber), lower[lower.index(after: c)...].allSatisfy(\.isNumber),
               lower.index(after: c) < lower.endIndex {
                return true
            }
            return false
        }
    }

    static let cellAddressPattern = #"\b[rR]\d{1,3}\s?[cC]\d{1,3}\b"#
    static let sceneIDPattern = #"\b[tlofTLOF]\d{1,3}\b"#

    /// A cell address or a scene id, said as what it is in the reply's language.
    static func spokenIDs(_ text: String, language: NormalizedUtterance.Language) -> String {
        let fr = language == .french
        var line = replacing(cellAddressPattern, in: text, with: fr ? "cette case" : "that cell")
        guard let expression = try? NSRegularExpression(pattern: sceneIDPattern) else { return line }
        for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range, in: line), let letter = line[range].lowercased().first else { continue }
            let noun: String
            switch letter {
            case "o": noun = fr ? "cet élément" : "that item"
            case "f": noun = fr ? "cet endroit" : "that spot"
            default: noun = fr ? "ce texte" : "that text"
            }
            line.replaceSubrange(range, with: noun)
        }
        return line
    }

    /// The line with every internal word replaced by its French noun or dropped, and raw codes removed.
    public static func clean(_ text: String, language: NormalizedUtterance.Language) -> String {
        // Most lines hold nothing to look at: no regular expression runs for them.
        guard needsLook(text) else { return text }
        var line = text
        // Markup and machine records: a tag, a JSON object, "reason:…", "table:…", "[code]".
        line = replacing(#"<[^>]{0,80}>"#, in: line, with: "")
        line = replacing(#"\{[^{}]{0,300}\}"#, in: line, with: "")
        line = replacing(#"\b(reason|table|speak):[A-Za-z0-9_=;%.\-|]+"#, in: line, with: "")
        line = replacing(#"\[[a-z]+(_[a-z]+)*\]"#, in: line, with: "")
        // Sentences written for the model ("Hint: …", "Do not retry …", "verify failed 1/3: …").
        line = replacing(#"(?i)\b(hint|problems?):[^.!?]*[.!?]?"#, in: line, with: "")
        line = replacing(#"(?i)\bdo not retry[^.!?]*[.!?]?"#, in: line, with: "")
        line = replacing(#"(?i)\bverif(y|ied) (failed )?\d+/\d+(:[^.!?]*)?[.!?]?"#, in: line, with: "")
        line = replacing(machinePattern, in: line, with: "")
        // Action names ("textBehind", "fillCells") are code, never words.
        if actionNames.contains(where: { line.contains($0) }) { line = replacing(actionPattern, in: line, with: "") }
        // Ids and cell addresses the state lines teach: "J'efface t9." → "J'efface ce texte."
        if containsSceneID(line) { line = spokenIDs(line, language: language) }
        if language == .french { line = frenchLabels(line) }
        return tidy(line, original: text)
    }

    /// True when `clean` would leave the line as it is: it may be spoken raw.
    public static func isClean(_ text: String, language: NormalizedUtterance.Language) -> Bool {
        clean(text, language: language) == text
    }

    // MARK: French labels

    /// « subject » → « sujet »; an English internal label without a French noun becomes « ça »
    /// ("Je ne trouve pas « thing » sur la photo." → "Je ne trouve pas ça sur la photo.").
    static func frenchLabels(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"«\s*([^«»]{1,40}?)\s*»"#) else { return text }
        var result = text
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let label = String(result[inner])
            let key = label.lowercased().trimmingCharacters(in: .whitespaces)
            let bare = key.hasPrefix("the ") ? String(key.dropFirst(4)) : key
            guard internalLabels.contains(bare) || machineWords.contains(bare) || bare.contains("_") else { continue }
            if let french = PicshopError.frenchLabel(for: bare) {
                result.replaceSubrange(whole, with: "« \(french) »")
            } else {
                // Nothing French to say: the label goes.
                result.replaceSubrange(whole, with: "ça")
            }
        }
        // Bare internal words right after a French verb that names them ("Je ne trouve pas subject").
        for label in ["subject", "background", "object", "person"] {
            if let french = PicshopError.frenchLabel(for: label) {
                result = replacing(#"(?<=\bpas |\bde |\ble |\bla |\bdu )"# + label + #"\b"#, in: result, with: french)
            }
        }
        return result
    }

    // MARK: Helpers

    static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Single spaces, no space before punctuation that French does not space, no empty guillemets, no
    /// dangling separators. Unchanged text stays byte-identical (so `isClean` holds for clean lines).
    static func tidy(_ text: String, original: String) -> String {
        guard text != original else { return text }
        var line = text
        line = replacing(#"«\s*»"#, in: line, with: "")
        line = replacing(#"\(\s*\)"#, in: line, with: "")
        line = replacing(#"[ \t]{2,}"#, in: line, with: " ")
        line = replacing(#"\s+([.,)])"#, in: line, with: "$1")
        line = replacing(#"\s*[:;,]+\s*([.!?])"#, in: line, with: "$1")
        line = replacing(#"^[\s:;,.·—]+"#, in: line, with: "")
        line = replacing(#"[\s:;,·—-]+$"#, in: line, with: "")
        line = replacing(#"\.{2,}$"#, in: line, with: ".")
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
