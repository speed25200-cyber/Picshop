import Foundation

/// A single non-destructive edit recorded on a layer. Operations are replayed in
/// order by the renderer; the history stack stores whole documents so undo is
/// trivially correct.
public struct EditOperation: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: Kind
    public var createdAt: Date
    /// Human readable label ("Exposure +20", "Remove dog") for the history UI.
    public var label: String

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date(), label: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.label = label ?? kind.defaultLabel
    }

    public enum Kind: Hashable, Codable, Sendable {
        /// Sets one adjustment parameter to an absolute value.
        case adjust(AdjustmentParameter, value: Double)
        /// Replaces the whole adjustment set (used by auto-enhance and looks).
        case adjustments(Adjustments)
        case toneCurve(ToneCurve)
        case look(FilterPreset, intensity: Double)
        case autoEnhance(strength: Double)
        case crop(PSRect)
        case rotate(degrees: Double)
        case straighten(degrees: Double)
        case flip(FlipAxis)
        case perspective(horizontal: Double, vertical: Double)
        /// Content-aware fill inside the mask (object removal, healing).
        case removeObject(MaskReference)
        case heal(strokes: [BrushStroke])
        /// Keeps the subject, makes everything else transparent.
        case removeBackground(MaskReference?)
        case replaceBackground(Background, mask: MaskReference?)
        case blurBackground(amount: Double, mask: MaskReference?)
        case selectiveAdjust(MaskReference, Adjustments)
        case upscale(factor: Double)
        case denoise(amount: Double)
        case sharpen(amount: Double)
        case relight(direction: Double, intensity: Double)
        /// Text-guided synthesis inside the mask ("replace the sky with a sunset").
        case generativeFill(MaskReference, prompt: String)
        /// Changes the colour of the masked region while keeping its shading.
        case recolor(MaskReference, PSColor, strength: Double)
        /// Copies pixels from `offset` (normalised) along the strokes.
        case cloneStamp(strokes: [BrushStroke], offset: PSPoint)
        /// Paints an opaque colour along the strokes (pixel brush).
        case pixelPaint(strokes: [BrushStroke], color: PSColor)

        public var defaultLabel: String {
            switch self {
            case .adjust(let parameter, let value):
                let percent = Int((value * 100).rounded())
                return "\(parameter.englishName) \(percent >= 0 ? "+" : "")\(percent)"
            case .adjustments: return "Adjustments"
            case .toneCurve: return "Curves"
            case .look(let preset, _): return preset.englishName
            case .autoEnhance: return "Auto Enhance"
            case .crop: return "Crop"
            case .rotate(let degrees): return "Rotate \(Int(degrees))°"
            case .straighten: return "Straighten"
            case .flip(let axis): return axis == .horizontal ? "Flip Horizontal" : "Flip Vertical"
            case .perspective: return "Perspective"
            case .removeObject(let mask): return "Remove \(mask.displayName)"
            case .heal: return "Heal"
            case .removeBackground: return "Remove Background"
            case .replaceBackground: return "Replace Background"
            case .blurBackground: return "Blur Background"
            case .selectiveAdjust: return "Selective Edit"
            case .upscale(let factor): return "Upscale \(Int(factor))×"
            case .denoise: return "Denoise"
            case .sharpen: return "Sharpen"
            case .relight: return "Relight"
            case .generativeFill(_, let prompt): return "Generate: \(prompt)"
            case .recolor(let mask, _, _): return "Recolor \(mask.displayName)"
            case .cloneStamp: return "Clone Stamp"
            case .pixelPaint: return "Paint"
            }
        }

        /// Whether the operation changes the pixel geometry (affects masks placed afterwards).
        public var isGeometric: Bool {
            switch self {
            case .crop, .rotate, .straighten, .flip, .perspective, .upscale: return true
            default: return false
            }
        }

        /// Operations that need heavy ML/compute and should show progress.
        public var isExpensive: Bool {
            switch self {
            case .removeObject, .heal, .removeBackground, .replaceBackground, .blurBackground, .upscale, .denoise, .relight, .generativeFill: return true
            default: return false
            }
        }
    }
}

/// What appears behind a cut-out subject.
public enum Background: Hashable, Codable, Sendable {
    case transparent
    case solid(PSColor)
    case gradient(PSColor, PSColor)
    case blurredOriginal(amount: Double)
    case image(MediaAsset)
}

/// Ordered list of operations plus derived, cached state.
public struct EditStack: Hashable, Codable, Sendable {
    public var operations: [EditOperation]

    public init(operations: [EditOperation] = []) {
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }

    public mutating func append(_ kind: EditOperation.Kind, label: String? = nil) {
        operations.append(EditOperation(kind: kind, label: label))
    }

    /// Flattens all adjustment-type operations into the effective adjustment set.
    public var resolvedAdjustments: Adjustments {
        var result = Adjustments()
        for operation in operations {
            switch operation.kind {
            case .adjust(let parameter, let value):
                result[parameter] = value
            case .adjustments(let set):
                result = set
            case .autoEnhance(let strength):
                result = result.combined(with: Adjustments([.exposure: 0.08, .contrast: 0.1, .vibrance: 0.2, .shadows: 0.12, .highlights: -0.1, .clarity: 0.1]), weight: strength)
            default:
                break
            }
        }
        return result
    }

    public var resolvedLook: (preset: FilterPreset, intensity: Double)? {
        for operation in operations.reversed() {
            if case .look(let preset, let intensity) = operation.kind {
                return preset == .original ? nil : (preset, intensity)
            }
        }
        return nil
    }

    public var resolvedToneCurve: ToneCurve {
        for operation in operations.reversed() {
            if case .toneCurve(let curve) = operation.kind { return curve }
        }
        return resolvedLook?.preset.toneCurve ?? .identity
    }

    /// Effective crop rectangle (normalised), last one wins.
    public var resolvedCrop: PSRect? {
        for operation in operations.reversed() {
            if case .crop(let rect) = operation.kind { return rect }
        }
        return nil
    }

    /// Sum of rotation and straighten operations, in degrees.
    public var resolvedRotation: Double {
        operations.reduce(0) { partial, operation in
            switch operation.kind {
            case .rotate(let degrees): return partial + degrees
            case .straighten(let degrees): return partial + degrees
            default: return partial
            }
        }
    }

    public var resolvedFlip: (horizontal: Bool, vertical: Bool) {
        var h = false
        var v = false
        for operation in operations {
            if case .flip(let axis) = operation.kind {
                if axis == .horizontal { h.toggle() } else { v.toggle() }
            }
        }
        return (h, v)
    }

    /// Operations that require pixel synthesis, in order.
    public var pixelOperations: [EditOperation] {
        operations.filter { $0.kind.isExpensive }
    }

    /// Replaces the last `.adjust` for `parameter` if it is the most recent
    /// operation, so dragging a slider doesn't create hundreds of entries.
    public mutating func setAdjustment(_ parameter: AdjustmentParameter, value: Double) {
        if let last = operations.last, case .adjust(let p, _) = last.kind, p == parameter {
            operations[operations.count - 1] = EditOperation(id: last.id, kind: .adjust(parameter, value: value), createdAt: last.createdAt)
        } else {
            append(.adjust(parameter, value: value))
        }
    }
}
