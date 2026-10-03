import Foundation

/// Kill switches for the W1 features, one per feature.
public enum FeatureFlag: String, CaseIterable, Sendable {
    /// Catalog operations (IntentAction.operation) in Live and the planner (E2).
    case catalogOps
    /// The catalog prompt: core block plus per-turn retrieved cards (E2).
    case retrievalCards
    /// The display-link frame pump and direct canvas sink (E4).
    case displayLinkCanvas
    /// Curves, Levels, histogram and the 27 blend modes in the photo editor (E3).
    case proTone
    /// Editor shell: title and zoom, compare button, tool rail, inspector, Outils search (E5).
    case studioWorkspace
    /// PSBackdrop and the new Home (E5).
    case psBackdrop

    /// On in Release when nobody overrode it. Testers get W1 through TestFlight, so a
    /// finished feature ships on; a feature left unfinished is turned off here, and
    /// its owner says so. Debug builds have every flag on.
    public var releaseDefault: Bool {
        switch self {
        case .catalogOps, .retrievalCards, .displayLinkCanvas, .proTone, .studioWorkspace, .psBackdrop: return true
        }
    }
}

public enum FeatureFlags {
    static func key(_ flag: FeatureFlag) -> String { "picshop.flag.\(flag.rawValue)" }

    /// The override set in Réglages › Avancé › Expérimental, else on in Debug and `releaseDefault` in Release.
    public static func isOn(_ flag: FeatureFlag) -> Bool {
        if let override = UserDefaults.standard.object(forKey: key(flag)) as? Bool { return override }
        return defaultValue(flag)
    }

    /// Overrides the flag; nil restores the default.
    public static func set(_ flag: FeatureFlag, _ value: Bool?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key(flag))
        } else {
            UserDefaults.standard.removeObject(forKey: key(flag))
        }
    }

    /// The value without any override.
    public static func defaultValue(_ flag: FeatureFlag) -> Bool {
        #if DEBUG
        return true
        #else
        return flag.releaseDefault
        #endif
    }
}
