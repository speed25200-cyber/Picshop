import Foundation

/// What a local adjustment is called, on screen and for VoiceOver (W2, M3): « Ciel », « Bas », « Sujet »,
/// « Personne 2 », « Tasse », and « Ciel, masque, visible, exposition plus 0,3 ».
///
/// The person's own name wins; otherwise the region it was made from (with its object noun or person number),
/// otherwise what its first component is (« Pinceau », « Dégradé linéaire »).
public enum MaskAccessibility {
    /// The dials in the panel's order (Photos' order, vignette left out: it never acts locally).
    public static let dialOrder: [AdjustmentParameter] = [
        .exposure, .brightness, .highlights, .shadows, .contrast, .whites, .blacks,
        .saturation, .vibrance, .temperature, .tint, .skinTone, .hue,
        .sharpness, .clarity, .noiseReduction, .grain, .fade,
    ]

    // MARK: Names

    /// The name the mask list shows.
    public static func displayName(for adjustment: LocalAdjustment, language: OpLanguage) -> String {
        if let name = adjustment.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let region = adjustment.region { return regionName(region, label: adjustment.label, language: language) }
        if let first = adjustment.stack.components.first { return componentName(first.kind, language: language) }
        return language == .fr ? "Masque" : "Mask"
    }

    /// Every adjustment's name, the repeated ones numbered in order (« Ciel », « Ciel 2 »).
    public static func displayNames(for adjustments: [LocalAdjustment], language: OpLanguage) -> [String] {
        let names = adjustments.map { displayName(for: $0, language: language) }
        var totals: [String: Int] = [:]
        for name in names { totals[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard totals[name, default: 0] > 1 else { return name }
            seen[name, default: 0] += 1
            let index = seen[name]!
            return index == 1 ? name : "\(name) \(index)"
        }
    }

    /// A region as the interface names it; `label` is an object noun (English), a person number, or "teeth:2".
    public static func regionName(_ region: MaskRegion, label: String? = nil, language: OpLanguage) -> String {
        let fr = language == .fr
        let person = personNumber(label)
        switch region {
        case .object:
            guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return fr ? "Objet" : "Object" }
            let noun = fr ? (PicshopError.frenchLabel(for: label) ?? label) : label
            return capitalizedFirst(noun.replacingOccurrences(of: "_", with: " "))
        case .person:
            let base = fr ? "Personne" : "Person"
            return person.map { "\(base) \($0)" } ?? base
        case .face, .faceSkin, .eyes, .lips, .teeth:
            let base = plainRegionName(region, fr: fr)
            return person.map { "\(base) (\($0))" } ?? base
        default:
            return plainRegionName(region, fr: fr)
        }
    }

    /// A component kind's name (a mask made by hand, or a row of the component list).
    public static func componentName(_ kind: MaskComponent.Kind, language: OpLanguage) -> String {
        let fr = language == .fr
        switch kind {
        case .raster(let raster):
            switch raster.origin {
            case .subject: return fr ? "Sujet" : "Subject"
            case .background: return fr ? "Arrière-plan" : "Background"
            case .people: return fr ? "Personnes" : "People"
            case .person: return regionName(.person, label: raster.label, language: language)
            case .object: return regionName(.object, label: raster.label, language: language)
            case .sky: return fr ? "Ciel" : "Sky"
            case .vegetation: return fr ? "Végétation" : "Vegetation"
            case .water: return fr ? "Eau" : "Water"
            case .depth: return fr ? "Profondeur" : "Depth"
            case .selection: return fr ? "Sélection" : "Selection"
            case .brush: return fr ? "Pinceau" : "Brush"
            case .imported: return fr ? "Masque" : "Mask"
            case .facePart, .matte:
                let parts = (raster.label ?? "").split(separator: ":").map(String.init)
                if let first = parts.first, let region = MaskRegion(rawValue: first) {
                    return regionName(region, label: parts.count > 1 ? parts[1] : nil, language: language)
                }
                return fr ? "Visage" : "Face"
            }
        case .brush: return fr ? "Pinceau" : "Brush"
        case .linear: return fr ? "Dégradé linéaire" : "Linear gradient"
        case .radial: return fr ? "Dégradé radial" : "Radial gradient"
        case .colorRange: return fr ? "Plage de couleurs" : "Colour range"
        case .luminanceRange: return fr ? "Plage de luminance" : "Luminance range"
        case .depthRange: return fr ? "Plage de profondeur" : "Depth range"
        case .unsupported: return fr ? "Élément d'une version plus récente" : "Item from a newer version"
        }
    }

    // MARK: VoiceOver

    /// « Ciel, masque, visible, exposition plus 0,3 » / "Sky, mask, visible, exposure plus 0.3": the name, the
    /// visibility and the first two dials off zero (or what else it changes).
    public static func label(for adjustment: LocalAdjustment, language: OpLanguage) -> String {
        let fr = language == .fr
        var parts = [displayName(for: adjustment, language: language), fr ? "masque" : "mask"]
        parts.append(adjustment.isVisible ? "visible" : (fr ? "caché" : "hidden"))
        let dials = dialOrder.filter { abs(adjustment.adjustments[$0]) > 0.0005 }.prefix(2)
        for parameter in dials {
            let value = adjustment.adjustments[parameter]
            let name = (fr ? parameter.frenchName : parameter.englishName).lowercased()
            let sign = value >= 0 ? (fr ? "plus" : "plus") : (fr ? "moins" : "minus")
            parts.append("\(name) \(sign) \(number(abs(value), language: language))")
        }
        if dials.isEmpty {
            var others: [String] = []
            if let curve = adjustment.curve, !curve.isIdentity { others.append(fr ? "courbe" : "curve") }
            if let mixer = adjustment.mixer, !mixer.isNeutral { others.append(fr ? "TSL" : "HSL") }
            if let grade = adjustment.grade, !grade.isNeutral { others.append(fr ? "couleur" : "colour") }
            parts.append(others.isEmpty ? (fr ? "aucun réglage" : "no adjustment") : others.joined(separator: ", "))
        }
        if adjustment.amount < 0.995 {
            parts.append(fr ? "quantité \(Int((adjustment.amount * 100).rounded())) %" : "amount \(Int((adjustment.amount * 100).rounded()))%")
        }
        return parts.joined(separator: ", ")
    }

    /// 0.3 → « 0,3 » / "0.3": two decimals at most, trailing zeros dropped.
    public static func number(_ value: Double, language: OpLanguage) -> String {
        guard value.isFinite else { return "0" }
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100, fraction = abs(hundredths % 100)
        let separator = language == .fr ? "," : "."
        let sign = hundredths < 0 && whole == 0 ? "-" : ""
        guard fraction != 0 else { return "\(sign)\(whole)" }
        let digits = fraction % 10 == 0 ? "\(fraction / 10)" : (fraction < 10 ? "0\(fraction)" : "\(fraction)")
        return "\(sign)\(whole)\(separator)\(digits)"
    }

    // MARK: Helpers

    static func plainRegionName(_ region: MaskRegion, fr: Bool) -> String {
        switch region {
        case .subject: return fr ? "Sujet" : "Subject"
        case .background: return fr ? "Arrière-plan" : "Background"
        case .sky: return fr ? "Ciel" : "Sky"
        case .people: return fr ? "Personnes" : "People"
        case .person: return fr ? "Personne" : "Person"
        case .object: return fr ? "Objet" : "Object"
        case .vegetation: return fr ? "Végétation" : "Vegetation"
        case .water: return fr ? "Eau" : "Water"
        case .face: return fr ? "Visage" : "Face"
        case .faceSkin: return fr ? "Peau du visage" : "Face skin"
        case .eyes: return fr ? "Yeux" : "Eyes"
        case .lips: return fr ? "Lèvres" : "Lips"
        case .teeth: return fr ? "Dents" : "Teeth"
        case .hair: return fr ? "Cheveux" : "Hair"
        case .bodySkin: return fr ? "Peau" : "Skin"
        case .top: return fr ? "Haut" : "Top"
        case .bottom: return fr ? "Bas" : "Bottom"
        case .left: return fr ? "Gauche" : "Left"
        case .right: return fr ? "Droite" : "Right"
        case .center: return fr ? "Centre" : "Centre"
        case .edges: return fr ? "Bords" : "Edges"
        case .color: return fr ? "Plage de couleurs" : "Colour range"
        case .shadows: return fr ? "Ombres" : "Shadows"
        case .midtones: return fr ? "Tons moyens" : "Midtones"
        case .highlights: return fr ? "Hautes lumières" : "Highlights"
        case .skinTones: return fr ? "Tons chair" : "Skin tones"
        case .near: return fr ? "Premier plan" : "Foreground"
        case .far: return fr ? "Lointain" : "Distance"
        case .selection: return fr ? "Sélection" : "Selection"
        }
    }

    /// "2" or "teeth:2" → 2.
    static func personNumber(_ label: String?) -> Int? {
        guard let label else { return nil }
        let last = label.split(separator: ":").last.map(String.init) ?? label
        return Int(last.trimmingCharacters(in: .whitespaces))
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
