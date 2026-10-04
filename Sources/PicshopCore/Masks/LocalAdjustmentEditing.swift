import Foundation

/// One change to a local adjustment. `PhotoDocument.applyLocalEdit(_:to:)` is the only code that changes a
/// local adjustment: the session (UI) and the operation handlers (voice) both call it, so they give the same document.
public enum LocalAdjustmentEdit: Hashable, Sendable {
    /// Appended; refused past MaskStack.maxComponents.
    case addComponent(MaskComponent)
    case removeComponent(UUID)
    case setComponentMode(UUID, CombineMode)
    case invertComponent(UUID, Bool)
    /// Handle drags, range thumbs, brush strokes.
    case setComponentKind(UUID, MaskComponent.Kind)
    case setStack(feather: Double?, expand: Double?, density: Double?, isInverted: Bool?)
    /// Vignette refused.
    case setDial(AdjustmentParameter, Double)
    case setCurve(ToneCurve?)
    case setMixer(ColorMixer?)
    case setGrade(ColorGrade?)
    case setAmount(Double)
    case setVisible(Bool)
    case rename(String?)
    /// Fresh adjustment and component UUIDs, shared RasterRefs, appended.
    case duplicate
}

public extension LocalAdjustment {
    /// This adjustment with `edit` applied (values clamped to their ranges); nil when the edit is refused or
    /// names a component it does not have. `.duplicate` is a document edit and gives nil here.
    func applying(_ edit: LocalAdjustmentEdit) -> LocalAdjustment? {
        var result = self
        switch edit {
        case .addComponent(let component):
            guard stack.components.count < MaskStack.maxComponents else { return nil }
            var added = component
            // Component ids are unique within a stack: a reused one gets a fresh id.
            if stack.components.contains(where: { $0.id == component.id }) { added.id = UUID() }
            added.opacity = Self.unit(added.opacity, default: 1)
            result.stack.components.append(added)
        case .removeComponent(let id):
            guard let index = stack.components.firstIndex(where: { $0.id == id }) else { return nil }
            result.stack.components.remove(at: index)
        case .setComponentMode(let id, let mode):
            guard let index = stack.components.firstIndex(where: { $0.id == id }) else { return nil }
            result.stack.components[index].mode = mode
        case .invertComponent(let id, let inverted):
            guard let index = stack.components.firstIndex(where: { $0.id == id }) else { return nil }
            result.stack.components[index].isInverted = inverted
        case .setComponentKind(let id, let kind):
            guard let index = stack.components.firstIndex(where: { $0.id == id }) else { return nil }
            result.stack.components[index].kind = kind
        case .setStack(let feather, let expand, let density, let isInverted):
            if let feather { result.stack.feather = Self.unit(feather, default: stack.feather) }
            if let expand, expand.isFinite { result.stack.expand = expand.clamped(to: -1...1) }
            if let density { result.stack.density = Self.unit(density, default: stack.density) }
            if let isInverted { result.stack.isInverted = isInverted }
        case .setDial(let parameter, let value):
            // Vignette is a frame effect, never a local one.
            guard parameter != .vignette, value.isFinite else { return nil }
            result.adjustments[parameter] = value
        case .setCurve(let curve):
            result.curve = curve
        case .setMixer(let mixer):
            result.mixer = mixer
        case .setGrade(let grade):
            result.grade = grade
        case .setAmount(let amount):
            guard amount.isFinite else { return nil }
            result.amount = amount.clamped(to: 0...1)
        case .setVisible(let visible):
            result.isVisible = visible
        case .rename(let name):
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.name = trimmed?.isEmpty == false ? trimmed : nil
        case .duplicate:
            return nil
        }
        return result
    }

    /// A copy with a fresh id and fresh component ids; rasters are shared (they are immutable files).
    func duplicated() -> LocalAdjustment {
        var copy = self
        copy.id = UUID()
        copy.stack.components = stack.components.map { component in
            var fresh = component
            fresh.id = UUID()
            return fresh
        }
        return copy
    }

    private static func unit(_ value: Double, default fallback: Double) -> Double {
        value.isFinite ? value.clamped(to: 0...1) : fallback
    }
}

public extension PhotoDocument {
    /// Applies `edit` to the local adjustment `id` (in place, one op per id). False when nothing changed or a cap
    /// refused it (16 adjustments, 12 components). Callers own history labels.
    ///
    /// `.duplicate` appends the copy after every other operation: it is `localAdjustments.last` afterwards.
    @discardableResult
    mutating func applyLocalEdit(_ edit: LocalAdjustmentEdit, to id: UUID) -> Bool {
        guard let layerID = localAdjustmentsLayerID, let current = layer(id: layerID)?.edits.localAdjustment(id: id) else { return false }
        if case .duplicate = edit {
            guard canAddLocalAdjustment else { return false }
            setLocalAdjustment(current.duplicated())
            return true
        }
        guard let edited = current.applying(edit), edited != current else { return false }
        // In place: same operation id, same position, same history label (a drag is one undo step).
        setLocalAdjustment(edited)
        return true
    }
}
