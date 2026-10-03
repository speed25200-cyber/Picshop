import Foundation

/// How a layer composites over what is beneath it: the 12 original modes, then
/// the 15 added in W1 (27, Photoshop's set). New modes go at the end.
public enum BlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten, difference, luminosity, color, hue
    case colorBurn, colorDodge, linearBurn, linearDodge, linearLight, vividLight, pinLight, hardMix
    case exclusion, subtract, divide, saturation, darkerColor, lighterColor, dissolve

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
        case .colorBurn: return "Color Burn"
        case .colorDodge: return "Color Dodge"
        case .linearBurn: return "Linear Burn"
        case .linearDodge: return "Linear Dodge (Add)"
        case .linearLight: return "Linear Light"
        case .vividLight: return "Vivid Light"
        case .pinLight: return "Pin Light"
        case .hardMix: return "Hard Mix"
        case .exclusion: return "Exclusion"
        case .subtract: return "Subtract"
        case .divide: return "Divide"
        case .saturation: return "Saturation"
        case .darkerColor: return "Darker Color"
        case .lighterColor: return "Lighter Color"
        case .dissolve: return "Dissolve"
        }
    }

    /// Generic French names, the same words the voice aliases accept.
    public var frenchName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Produit"
        case .screen: return "Écran"
        case .overlay: return "Incrustation"
        case .softLight: return "Lumière tamisée"
        case .hardLight: return "Lumière crue"
        case .darken: return "Obscurcir"
        case .lighten: return "Éclaircir"
        case .difference: return "Différence"
        case .luminosity: return "Luminosité"
        case .color: return "Couleur"
        case .hue: return "Teinte"
        case .colorBurn: return "Densité couleur moins"
        case .colorDodge: return "Densité couleur plus"
        case .linearBurn: return "Densité linéaire moins"
        case .linearDodge: return "Densité linéaire plus"
        case .linearLight: return "Lumière linéaire"
        case .vividLight: return "Lumière vive"
        case .pinLight: return "Lumière ponctuelle"
        case .hardMix: return "Mélange maximal"
        case .exclusion: return "Exclusion"
        case .subtract: return "Soustraction"
        case .divide: return "Division"
        case .saturation: return "Saturation"
        case .darkerColor: return "Couleur plus foncée"
        case .lighterColor: return "Couleur plus claire"
        case .dissolve: return "Fondu"
        }
    }
}

/// A shape layer (used for simple graphics and colour blocks).
public struct ShapeElement: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangle, roundedRectangle, ellipse, line, arrow

        public var displayName: String {
            switch self {
            case .rectangle: return "Rectangle"
            case .roundedRectangle: return "Rounded"
            case .ellipse: return "Ellipse"
            case .line: return "Line"
            case .arrow: return "Arrow"
            }
        }
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
    /// The group the layer was made with (the cells of one table fill); nil for a layer on its own.
    public var group: LayerGroup?

    public init(id: UUID = UUID(), name: String, content: Content, transform: LayerTransform = .identity,
                opacity: Double = 1, blendMode: BlendMode = .normal, isVisible: Bool = true,
                isLocked: Bool = false, mask: MaskReference? = nil, edits: EditStack = EditStack(), group: LayerGroup? = nil) {
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
        self.group = group
    }

    public var isImage: Bool {
        if case .image = content { return true }
        return false
    }

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    public var isShape: Bool {
        if case .shape = content { return true }
        return false
    }

    public var shapeElement: ShapeElement? {
        get {
            if case .shape(let shape) = content { return shape }
            return nil
        }
        set {
            if let newValue { content = .shape(newValue) }
        }
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

    /// What a text or shape layer's raster depends on, for the renderer's overlay cache: the
    /// content without where it sits. A text element's centre and rotation (and a layer's
    /// transform) only place the raster, so dragging or turning a title never draws it again;
    /// the text, its font, size, colour and style do. Nil for other layers.
    public var overlayRasterKey: String? {
        switch content {
        case .text(var element):
            element.center = PSPoint(x: 0.5, y: 0.5)
            element.rotation = 0
            return "text-\(id.uuidString)-\(element.hashValue)"
        case .shape(let shape):
            return "shape-\(id.uuidString)-\(shape.hashValue)"
        default:
            return nil
        }
    }
}
