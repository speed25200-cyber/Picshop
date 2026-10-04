import Foundation

/// Kill switches for the W1, W2 and W3 features and UX 2.0, one per feature.
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

    // W3: layers, render latency, pro export, LLM layer ops, Live latency (D24). There is deliberately no flag on
    // writing document-v2.json: proLayers off only stops creating v2-only state.
    /// Groups, clipping, fill opacity, partial locks, gradient fills, layer masks, via copy/cut, merges (L1–L4).
    case proLayers
    /// Non-uniform scale, skew, distort and perspective handles, smart guides and snapping (L1, L3).
    case freeTransform
    /// The 52 pt Layers column on the canvas edge (L3).
    case layersColumn
    /// Inspector rows generated from the catalog's ParamSpec (L1, L3).
    case paramInspector
    /// Content-hash render cache keys and the byte-bounded caches (L1, L2).
    case contentHashCache
    /// The nonisolated interactive snapshot for drags (L2, L3).
    case interactiveSnapshot
    /// Detail tiles at deep zoom and strip rendering from 24 MP (L2).
    case tiledRendering
    /// 16-bit PNG and TIFF, 10-bit HEIC, PDF of the photo, presets (L2, L3).
    case proExport
    /// The layered PSD export (L1, L2).
    case psdExport
    /// The LLM's layer operations, layer refs and the layers line (L4).
    case layerOps
    /// Outline-then-fill for long goals on the 4B (L4).
    case outlineFill
    /// The four recipes (L1, L4).
    case recipes
    /// The KV engine: checkpoint and restore, prefix snapshot, picture turns appended (L5).
    case kvEngine
    /// The prefix snapshot persisted across launches (L5).
    case persistedPrefix

    // UX 2.0 (ux-spec §6.1): the new editor frame (EditorShell, labelled bars, InspectorPanel v2) and the new Home.
    /// UX 2.0: Home and the photo editor in the new frame (increment 1); video and PDF join later. Off brings back
    /// the previous Home and editors, from Réglages › Avancé › Expérimental.
    case ux2

    /// On in Release when nobody overrode it. Testers get each wave through TestFlight, so a
    /// finished feature ships on; a feature left unfinished is turned off here, and
    /// its owner says so. Debug builds have every flag on.
    public var releaseDefault: Bool {
        switch self {
        case .catalogOps, .retrievalCards, .displayLinkCanvas, .proTone, .studioWorkspace, .psBackdrop: return true
        case .masks, .aiSelection, .samModel, .depthModel, .pixelPostconditions, .fmDynamicSchema, .commandPalette, .metalOrb,
             .graphiteSurround, .modelBroker:
            return true
        // W3 (D24): on; L5 turns off in P2 anything a lane reports unfinished.
        case .proLayers, .freeTransform, .layersColumn, .paramInspector, .contentHashCache, .interactiveSnapshot, .tiledRendering,
             .proExport, .psdExport, .layerOps, .outlineFill, .recipes, .kvEngine, .persistedPrefix:
            return true
        // UX 2.0: on in Release too while the owner judges it through TestFlight (§6.1 has it off until sign-off;
        // the owner chose on). The previous UI stays one switch away under Réglages › Avancé › Expérimental.
        case .ux2:
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
