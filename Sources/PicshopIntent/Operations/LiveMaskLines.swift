import Foundation
import PicshopCore

/// The `masks:` and `selection:` state lines Live sends with a photo turn (W2, §8.6). They count against the
/// per-turn budget, not the stable prefix. The model names a mask by its ref ("a1" is the first local adjustment)
/// and reads which dials it already moved, so « encore », « sur le masque 2 » and « inverse-le » need no question.
public enum LiveMaskLines {
    /// The most masks the line lists (the newest), and its length.
    public static let maxMasks = 6
    public static let budget = 240

    /// One entry per mask, newest last: "a1 Ciel (sky) exposure +0.30", at most 6 entries and 240 characters in all
    /// (joined with " · "). The name is in the reply language; the region and the dials as the model writes them.
    public static func lines(for document: PhotoDocument, language: OpLanguage) -> [String] {
        let masks = document.localAdjustments
        guard !masks.isEmpty else { return [] }
        let names = MaskAccessibility.displayNames(for: masks, language: language)
        var entries = masks.indices.map { index in entry(masks[index], ref: "a\(index + 1)", name: names[index]) }
        if entries.count > maxMasks { entries = Array(entries.suffix(maxMasks)) }
        while entries.count > 1, entries.joined(separator: " · ").count > budget { entries.removeFirst() }
        if let only = entries.first, entries.count == 1, only.count > budget { entries = [String(only.prefix(budget - 1)) + "…"] }
        return entries
    }

    /// "a2 Bas (bottom) exposure -0.20, contrast +0.10".
    static func entry(_ adjustment: LocalAdjustment, ref: String, name: String) -> String {
        var text = "\(ref) \(clean(name)) (\(kind(adjustment)))"
        let dials = MaskAccessibility.dialOrder.filter { abs(adjustment.adjustments[$0]) > 0.0005 }.prefix(2)
        var effects = dials.map { "\($0.rawValue) \(signed(adjustment.adjustments[$0]))" }
        if dials.isEmpty {
            if let curve = adjustment.curve, !curve.isIdentity { effects.append("curve") }
            if let mixer = adjustment.mixer, !mixer.isNeutral { effects.append("hsl") }
            if let grade = adjustment.grade, !grade.isNeutral { effects.append("colour") }
        }
        if !effects.isEmpty { text += " " + effects.joined(separator: ", ") }
        if adjustment.stack.isInverted { text += ", inverted" }
        if adjustment.amount < 0.995 { text += ", amount \(Int((adjustment.amount * 100).rounded()))%" }
        if !adjustment.isVisible { text += ", hidden" }
        return text
    }

    /// What the mask is made of, as the model names it: "sky", "object cup", "person 2", "linear".
    static func kind(_ adjustment: LocalAdjustment) -> String {
        if let region = adjustment.region {
            switch region {
            case .object: return "object" + (adjustment.label.map { " " + clean($0) } ?? "")
            case .person, .face, .faceSkin, .eyes, .lips, .teeth:
                return region.rawValue + (personNumber(adjustment.label).map { " \($0)" } ?? "")
            default: return region.rawValue
            }
        }
        guard let first = adjustment.stack.components.first else { return "empty" }
        switch first.kind {
        case .raster(let raster): return raster.origin.rawValue
        case .brush: return "brush"
        case .linear: return "linear"
        case .radial: return "radial"
        case .colorRange: return "color"
        case .luminanceRange: return "luminance"
        case .depthRange: return "depth"
        case .unsupported: return "newer"
        }
    }

    /// "selection: tasse (object) 6 %, ajout" / "selection: cup (object) 6 %, add"; nil without a selection.
    public static func selectionLine(for document: PhotoDocument, language: OpLanguage) -> String? {
        guard let selection = document.selection else { return nil }
        let fr = language == .fr
        let last = selection.steps.last
        let what: String
        if let step = last {
            what = "\(stepNoun(step, fr: fr)) (\(step.source.rawValue))"
        } else {
            what = fr ? "zone" : "area"
        }
        let percent = selection.coverage * 100
        let shown = percent > 0 && percent < 1
            ? String(format: "%.1f", percent).replacingOccurrences(of: ".", with: fr ? "," : ".")
            : "\(Int(percent.rounded()))"
        var line = "selection: \(clean(what)) \(shown) %"
        if let mode = last?.mode {
            switch mode {
            case .add: line += fr ? ", ajout" : ", add"
            case .subtract: line += fr ? ", retrait" : ", subtract"
            case .intersect: line += fr ? ", intersection" : ", intersect"
            }
        }
        if selection.steps.count > 1 { line += fr ? ", \(selection.steps.count) étapes" : ", \(selection.steps.count) steps" }
        if selection.refinement != nil { line += fr ? ", bords affinés" : ", refined edges" }
        return line
    }

    /// The step's subject in the reply language: "tasse", "personne 2", "rouge", "ciel".
    static func stepNoun(_ step: SelectionStep, fr: Bool) -> String {
        let language: OpLanguage = fr ? .fr : .en
        switch step.source {
        case .object:
            guard let label = step.label else { return fr ? "objet" : "object" }
            return fr ? (PicshopError.frenchLabel(for: label) ?? label) : label
        case .person:
            return MaskAccessibility.regionName(.person, label: step.label, language: language).lowercased()
        case .facePart:
            let parts = (step.label ?? "").split(separator: ":").map(String.init)
            if let first = parts.first, let region = MaskRegion(rawValue: first) {
                return MaskAccessibility.regionName(region, label: parts.count > 1 ? parts[1] : nil, language: language).lowercased()
            }
            return fr ? "visage" : "face"
        case .colorRange:
            return step.label.map { fr ? (frenchColour($0) ?? $0) : $0 } ?? (fr ? "couleur" : "colour")
        case .luminanceRange, .region:
            if let raw = step.label, let region = MaskRegion(rawValue: raw) { return MaskAccessibility.regionName(region, language: language).lowercased() }
            return fr ? "zone" : "area"
        case .subject: return fr ? "sujet" : "subject"
        case .background: return fr ? "arrière-plan" : "background"
        case .sky: return fr ? "ciel" : "sky"
        case .people: return fr ? "personnes" : "people"
        case .quick: return fr ? "sélection rapide" : "quick selection"
        case .wand: return fr ? "baguette magique" : "magic wand"
        case .lasso: return "lasso"
        case .all: return fr ? "toute la photo" : "whole photo"
        case .invert: return fr ? "inversée" : "inverted"
        case .modify: return fr ? "modifiée" : "modified"
        case .refine: return fr ? "affinée" : "refined"
        case .mask: return step.label.map { (fr ? "masque " : "mask ") + $0 } ?? (fr ? "masque" : "mask")
        }
    }

    static func frenchColour(_ name: String) -> String? {
        ["red": "rouge", "reds": "rouges", "orange": "orange", "oranges": "oranges", "yellow": "jaune", "yellows": "jaunes", "green": "vert",
         "greens": "verts", "cyans": "cyans", "blue": "bleu", "blues": "bleus", "magentas": "magentas", "purple": "violet", "pink": "rose",
         "skinTones": "tons chair", "white": "blanc", "black": "noir", "gray": "gris", "brown": "marron"][name]
    }

    /// Whether a `selection:` state line is a pixel selection (W2's, a lasso or a wand), not a selected layer.
    public static func isPixelSelection(_ text: String) -> Bool {
        text.hasPrefix("selection:") || ["lasso selection", "magic wand selection", "selected region"].contains(text)
    }

    /// The line's text without its "selection: " prefix (the prompts print the key themselves).
    public static func selectionValue(_ text: String) -> String {
        text.hasPrefix("selection: ") ? String(text.dropFirst("selection: ".count)) : text
    }

    /// "masks: a1 Ciel (sky) exposure +0.30 · a2 Bas (bottom) exposure -0.20", nil without masks.
    public static func masksLine(_ entries: [String]) -> String? {
        entries.isEmpty ? nil : "masks: " + entries.joined(separator: " · ")
    }

    /// "2" or "teeth:2" → 2.
    static func personNumber(_ label: String?) -> Int? {
        guard let label else { return nil }
        return Int((label.split(separator: ":").last.map(String.init) ?? label).trimmingCharacters(in: .whitespaces))
    }

    static func signed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return (rounded >= 0 ? "+" : "-") + String(format: "%.2f", abs(rounded))
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: "·", with: "-")
    }
}
