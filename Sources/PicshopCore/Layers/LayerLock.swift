import Foundation

// D7: what each lock forbids. Pure, so every caller (document, handlers, UI) reads one table. The document enforces it
// in `apply`, `removeLayer`, `moveLayer`, `applyLayerEdit` and `applyStructureEdit`, so every caller inherits it.

/// The kinds of change a lock can refuse.
public enum LayerMutation: String, Hashable, Sendable, CaseIterable {
    /// EditStack append or replace; text, shape, fill, gradient or adjustment change; a merge into the layer.
    case content
    /// removeBackground, cutout, expand, mask apply, a fill under the selection on this layer.
    case alpha
    /// Transform, flip, align.
    case placement
    /// Opacity, fill, blend, clip.
    case properties
    /// Layer-mask edits.
    case mask
    /// Move, group, ungroup.
    case order
    case delete
}

public enum LayerLockPolicy {
    /// D7's table: content ← pixels or all; alpha ← transparency, pixels or all; placement ← position or all;
    /// properties, mask, order and delete ← all. Visibility, rename and lock changes are never refused (no mutation).
    public static func allows(_ mutation: LayerMutation, lock: LayerLockOptions) -> Bool {
        if lock.isSuperset(of: .all) { return false }
        switch mutation {
        case .content: return !lock.contains(.pixels)
        case .alpha: return !lock.contains(.pixels) && !lock.contains(.transparency)
        case .placement: return !lock.contains(.position)
        case .properties, .mask, .order, .delete: return true
        }
    }

    /// The same, with the layer's effective lock (own ∪ parent group's). A missing layer allows nothing.
    public static func allows(_ mutation: LayerMutation, on layerID: UUID, in document: PhotoDocument) -> Bool {
        guard document.layer(id: layerID) != nil else { return false }
        return allows(mutation, lock: document.effectiveLock(of: layerID))
    }

    /// The mutation a layer edit needs (D7, the comments of `LayerEdit`); nil for the edits no lock refuses
    /// (visibility, rename, lock changes, the adjustment kind). The UI disables a control whose mutation is refused.
    public static func mutation(for edit: LayerEdit) -> LayerMutation? {
        switch edit {
        case .opacity, .fillOpacity, .blendMode, .clipped, .folder: return .properties
        case .transform: return .placement
        case .maskStack, .maskEdit, .maskEnabled, .maskLinked: return .mask
        case .solidFill, .gradient, .adjustments: return .content
        case .visible, .lock, .lockAll, .rename, .recipeKind: return nil
        }
    }

    /// .alpha for removeBackground, replaceBackground with a transparent backdrop, expand; .content for every other kind.
    public static func mutation(for kind: EditOperation.Kind) -> LayerMutation {
        switch kind {
        case .removeBackground, .expand: return .alpha
        case .replaceBackground(let background, _): return background == .transparent ? .alpha : .content
        default: return .content
        }
    }
}
