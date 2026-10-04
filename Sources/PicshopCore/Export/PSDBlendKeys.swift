import Foundation

/// D16b: Photoshop's 4-character blend keys for the 27 modes, plus pass-through for groups.
public enum PSDBlendKey {
    public static func key(for mode: BlendMode) -> String {
        switch mode {
        case .normal: return "norm"
        case .dissolve: return "diss"
        case .darken: return "dark"
        case .multiply: return "mul "
        case .colorBurn: return "idiv"
        case .linearBurn: return "lbrn"
        case .darkerColor: return "dkCl"
        case .lighten: return "lite"
        case .screen: return "scrn"
        case .colorDodge: return "div "
        case .linearDodge: return "lddg"
        case .lighterColor: return "lgCl"
        case .overlay: return "over"
        case .softLight: return "sLit"
        case .hardLight: return "hLit"
        case .vividLight: return "vLit"
        case .linearLight: return "lLit"
        case .pinLight: return "pLit"
        case .hardMix: return "hMix"
        case .difference: return "diff"
        case .exclusion: return "smud"
        case .subtract: return "fsub"
        case .divide: return "fdiv"
        case .hue: return "hue "
        case .saturation: return "sat "
        case .color: return "colr"
        case .luminosity: return "lum "
        }
    }

    /// The mode a key names; nil for "pass" and unknown keys.
    public static func mode(for key: String) -> BlendMode? {
        BlendMode.allCases.first { Self.key(for: $0) == key }
    }

    /// Groups only (D16c).
    public static let passThrough = "pass"
}
