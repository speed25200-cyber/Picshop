import Foundation

/// Kill switches for the W1 and W2 features, one per feature.
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

    // W2: masks and AI selection.
    /// Local adjustments through masks: the Masques tool and maskAdjust, maskEdit, maskDelete (M1–M4).
    case masks
    /// The selection as document state: the Sélection tool and select, selectionModify, selectionApply (M1–M4).
    case aiSelection
    /// SAM 2.1 tiny for object taps, boxes and Quick Selection (M2).
    case samModel
    /// Depth Anything V2 Small for depth-range masks (M2).
    case depthModel
    /// Pixel postconditions on 256 px proxies after mask and selection steps (M4).
    case pixelPostconditions
    /// The Foundation Models dynamic schema for the planner and the Apple Intelligence Live brain (M4).
    case fmDynamicSchema
    /// Command palette suggestions in the Ask field (M4, M5).
    case commandPalette
    /// The Metal orb shader in Live (M5).
    case metalOrb
    /// Graphite surround while a tone, colour or mask panel is open (M3).
    case graphiteSurround
    /// The model broker: memory floor, priorities and eviction for SAM, Depth, LaMa, the upscaler, SD and the LLM (M5).
    case modelBroker

    /// On in Release when nobody overrode it. Testers get each wave through TestFlight, so a
    /// finished feature ships on; a feature left unfinished is turned off here, and
    /// its owner says so. Debug builds have every flag on.
    public var releaseDefault: Bool {
        switch self {
        case .catalogOps, .retrievalCards, .displayLinkCanvas, .proTone, .studioWorkspace, .psBackdrop: return true
        case .masks, .aiSelection, .samModel, .depthModel, .pixelPostconditions, .fmDynamicSchema, .commandPalette, .metalOrb,
             .graphiteSurround, .modelBroker:
            return true
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
