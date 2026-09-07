import Foundation

public enum BlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten, difference, luminosity, color, hue

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft Light"
        case .hardLight: return "Hard Light"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        case .luminosity: return "Luminosity"
        case .color: return "Color"
        case .hue: return "Hue"
        }
    }
}

/// A shape layer (used for simple graphics and colour blocks).
public struct ShapeElement: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangle, roundedRectangle, ellipse, line, arrow
    }

    public var kind: Kind
    public var fill: PSColor
    public var stroke: PSColor?
    public var strokeWidth: Double
    public var cornerRadius: Double
    /// Size as a fraction of the canvas.
    public var relativeSize: PSSize

    public init(kind: Kind, fill: PSColor = .white, stroke: PSColor? = nil, strokeWidth: Double = 0,
                cornerRadius: Double = 0.02, relativeSize: PSSize = PSSize(width: 0.4, height: 0.2)) {
        self.kind = kind
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.relativeSize = relativeSize
    }
}

/// One layer in a photo document. Layers compose bottom-to-top.
public struct Layer: Hashable, Codable, Sendable, Identifiable {
    public enum Content: Hashable, Codable, Sendable {
        case image(MediaAsset)
        case text(TextElement)
        case shape(ShapeElement)
        /// Adjustment layer: applies adjustments to everything beneath.
        case adjustment(Adjustments)
        case fill(PSColor)
    }

    public var id: UUID
    public var name: String
    public var content: Content
    public var transform: LayerTransform
    public var opacity: Double
    public var blendMode: BlendMode
    public var isVisible: Bool
    public var isLocked: Bool
    public var mask: MaskReference?
    public var edits: EditStack

    public init(id: UUID = UUID(), name: String, content: Content, transform: LayerTransform = .identity,
                opacity: Double = 1, blendMode: BlendMode = .normal, isVisible: Bool = true,
                isLocked: Bool = false, mask: MaskReference? = nil, edits: EditStack = EditStack()) {
        self.id = id
        self.name = name
        self.content = content
        self.transform = transform
        self.opacity = opacity
        self.blendMode = blendMode
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.mask = mask
        self.edits = edits
    }

    public var isImage: Bool {
        if case .image = content { return true }
        return false
    }

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    public var imageAsset: MediaAsset? {
        if case .image(let asset) = content { return asset }
        return nil
    }

    public var textElement: TextElement? {
        get {
            if case .text(let element) = content { return element }
            return nil
        }
        set {
            if let newValue { content = .text(newValue) }
        }
    }

    public var symbolName: String {
        switch content {
        case .image: return "photo"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .adjustment: return "slider.horizontal.3"
        case .fill: return "paintbrush.fill"
        }
    }
}
