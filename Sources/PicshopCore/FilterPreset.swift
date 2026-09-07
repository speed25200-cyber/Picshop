import Foundation

/// Curated "looks". Each look is a recipe of adjustments plus an optional tone
/// curve so it renders identically on photo layers and video clips.
public enum FilterPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case vivid
    case vividWarm
    case vividCool
    case dramatic
    case dramaticWarm
    case dramaticCool
    case cinematic
    case goldenHour
    case tealOrange
    case matte
    case vintage
    case film
    case mono
    case silvertone
    case noir
    case portrait
    case pastel
    case punch
    case fresh

    public var id: String { rawValue }

    public var englishName: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .vividWarm: return "Vivid Warm"
        case .vividCool: return "Vivid Cool"
        case .dramatic: return "Dramatic"
        case .dramaticWarm: return "Dramatic Warm"
        case .dramaticCool: return "Dramatic Cool"
        case .cinematic: return "Cinematic"
        case .goldenHour: return "Golden Hour"
        case .tealOrange: return "Teal & Orange"
        case .matte: return "Matte"
        case .vintage: return "Vintage"
        case .film: return "Film"
        case .mono: return "Mono"
        case .silvertone: return "Silvertone"
        case .noir: return "Noir"
        case .portrait: return "Portrait"
        case .pastel: return "Pastel"
        case .punch: return "Punch"
        case .fresh: return "Fresh"
        }
    }

    public var frenchName: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Éclatant"
        case .vividWarm: return "Éclatant chaud"
        case .vividCool: return "Éclatant froid"
        case .dramatic: return "Dramatique"
        case .dramaticWarm: return "Dramatique chaud"
        case .dramaticCool: return "Dramatique froid"
        case .cinematic: return "Cinéma"
        case .goldenHour: return "Heure dorée"
        case .tealOrange: return "Teal & Orange"
        case .matte: return "Mat"
        case .vintage: return "Vintage"
        case .film: return "Argentique"
        case .mono: return "Mono"
        case .silvertone: return "Argenté"
        case .noir: return "Noir"
        case .portrait: return "Portrait"
        case .pastel: return "Pastel"
        case .punch: return "Punch"
        case .fresh: return "Frais"
        }
    }

    /// Alternate spoken names (lower-case, accent-folded) recognised by the parsers.
    public var aliases: [String] {
        switch self {
        case .original: return ["none", "no filter", "aucun", "sans filtre", "normal"]
        case .vivid: return ["vibrant", "vif", "eclatant", "colorful", "colore", "saturated"]
        case .vividWarm: return ["vivid warm", "vif chaud", "eclatant chaud"]
        case .vividCool: return ["vivid cool", "vif froid", "eclatant froid"]
        case .dramatic: return ["drama", "dramatique", "contrasty", "contraste"]
        case .dramaticWarm: return ["dramatic warm", "dramatique chaud"]
        case .dramaticCool: return ["dramatic cool", "dramatique froid"]
        case .cinematic: return ["cinema", "cinematique", "movie", "film look", "hollywood", "cine"]
        case .goldenHour: return ["golden", "golden hour", "heure doree", "doree", "sunset", "coucher de soleil", "warm sunset"]
        case .tealOrange: return ["teal orange", "teal and orange", "teal & orange", "orange teal", "blockbuster"]
        case .matte: return ["mat", "matte", "faded", "delave", "flat"]
        case .vintage: return ["retro", "old", "ancien", "vieux", "70s", "seventies", "nostalgic", "nostalgique"]
        case .film: return ["argentique", "analog", "analogue", "kodak", "fuji", "pellicule", "35mm", "grainy"]
        case .mono: return ["black and white", "black & white", "noir et blanc", "b&w", "bw", "monochrome", "grayscale", "greyscale", "gris"]
        case .silvertone: return ["silver", "argente", "silvertone"]
        case .noir: return ["film noir", "noir et blanc contraste", "high contrast black and white", "dark mono"]
        case .portrait: return ["portrait", "beauty", "beaute", "skin", "peau"]
        case .pastel: return ["pastel", "soft", "doux", "douce", "airy", "aerien", "light and airy"]
        case .punch: return ["punch", "punchy", "pop", "peps", "energique"]
        case .fresh: return ["fresh", "frais", "fraiche", "clean", "propre", "bright and clean"]
        }
    }

    /// The adjustment recipe at 100% intensity.
    public var recipe: Adjustments {
        switch self {
        case .original:
            return .neutral
        case .vivid:
            return Adjustments([.saturation: 0.25, .vibrance: 0.35, .contrast: 0.12, .clarity: 0.15])
        case .vividWarm:
            return Adjustments([.saturation: 0.25, .vibrance: 0.3, .contrast: 0.12, .temperature: 0.22, .clarity: 0.12])
        case .vividCool:
            return Adjustments([.saturation: 0.22, .vibrance: 0.3, .contrast: 0.12, .temperature: -0.22, .clarity: 0.12])
        case .dramatic:
            return Adjustments([.contrast: 0.35, .highlights: -0.3, .shadows: -0.2, .clarity: 0.3, .saturation: -0.08, .vignette: 0.25])
        case .dramaticWarm:
            return Adjustments([.contrast: 0.35, .highlights: -0.3, .shadows: -0.2, .clarity: 0.3, .temperature: 0.2, .vignette: 0.25])
        case .dramaticCool:
            return Adjustments([.contrast: 0.35, .highlights: -0.3, .shadows: -0.2, .clarity: 0.3, .temperature: -0.2, .vignette: 0.25])
        case .cinematic:
            return Adjustments([.contrast: 0.2, .saturation: -0.15, .temperature: -0.08, .tint: 0.05, .shadows: 0.1, .highlights: -0.15, .vignette: 0.3, .fade: 0.12, .grain: 0.1])
        case .goldenHour:
            return Adjustments([.temperature: 0.4, .tint: 0.06, .highlights: -0.1, .shadows: 0.15, .saturation: 0.1, .vibrance: 0.15, .fade: 0.06])
        case .tealOrange:
            return Adjustments([.temperature: 0.18, .tint: -0.1, .contrast: 0.22, .saturation: 0.12, .vibrance: 0.2, .shadows: 0.05])
        case .matte:
            return Adjustments([.contrast: -0.12, .fade: 0.35, .saturation: -0.1, .blacks: 0.15])
        case .vintage:
            return Adjustments([.temperature: 0.25, .saturation: -0.25, .fade: 0.3, .grain: 0.3, .vignette: 0.35, .contrast: -0.05, .tint: 0.08])
        case .film:
            return Adjustments([.grain: 0.4, .fade: 0.15, .contrast: 0.1, .saturation: -0.05, .temperature: 0.06, .highlights: -0.1])
        case .mono:
            return Adjustments([.saturation: -1, .contrast: 0.1, .clarity: 0.1])
        case .silvertone:
            return Adjustments([.saturation: -1, .contrast: -0.05, .fade: 0.2, .highlights: -0.1, .shadows: 0.15])
        case .noir:
            return Adjustments([.saturation: -1, .contrast: 0.45, .blacks: -0.25, .clarity: 0.3, .vignette: 0.45, .grain: 0.2])
        case .portrait:
            return Adjustments([.skinTone: 0.2, .clarity: -0.1, .highlights: -0.1, .shadows: 0.15, .vibrance: 0.1, .noiseReduction: 0.2])
        case .pastel:
            return Adjustments([.saturation: -0.2, .fade: 0.25, .exposure: 0.15, .contrast: -0.2, .highlights: -0.1])
        case .punch:
            return Adjustments([.contrast: 0.3, .saturation: 0.3, .clarity: 0.35, .sharpness: 0.2])
        case .fresh:
            return Adjustments([.exposure: 0.1, .vibrance: 0.25, .temperature: -0.06, .contrast: 0.08, .whites: 0.1, .clarity: 0.08])
        }
    }

    public var toneCurve: ToneCurve {
        switch self {
        case .cinematic, .dramatic, .dramaticWarm, .dramaticCool, .punch: return .sCurve(strength: 0.7)
        case .matte, .vintage, .pastel, .silvertone: return .matte(lift: 0.8)
        case .film: return .matte(lift: 0.35)
        default: return .identity
        }
    }

    /// Looks in the order shown in the filter strip.
    public static let gallery: [FilterPreset] = [
        .original, .vivid, .fresh, .punch, .goldenHour, .tealOrange, .cinematic,
        .dramatic, .matte, .pastel, .portrait, .film, .vintage, .mono, .silvertone, .noir,
        .vividWarm, .vividCool, .dramaticWarm, .dramaticCool,
    ]

    /// Resolves a spoken/written name to a preset. Accent and case insensitive.
    public static func matching(_ text: String) -> FilterPreset? {
        let query = text.normalizedForMatching
        guard !query.isEmpty else { return nil }
        var best: (FilterPreset, Int)?
        for preset in allCases {
            let candidates = [preset.rawValue.normalizedForMatching,
                              preset.englishName.normalizedForMatching,
                              preset.frenchName.normalizedForMatching] + preset.aliases.map { $0.normalizedForMatching }
            for candidate in candidates where !candidate.isEmpty {
                if candidate == query { return preset }
                if query.contains(candidate) || candidate.contains(query) {
                    let score = candidate.count
                    if best == nil || score > best!.1 { best = (preset, score) }
                }
            }
        }
        return best?.0
    }
}

public extension String {
    /// Lowercased, accent-folded and whitespace-collapsed for fuzzy matching.
    var normalizedForMatching: String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.replacingOccurrences(of: "’", with: "'")
    }
}
