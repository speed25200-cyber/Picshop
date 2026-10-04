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
        /// W3: a group; its children are the layers whose parentID is this layer's id, directly below it (D1, D4).
        case group(LayerFolder)
        /// W3: a gradient fill layer (D9).
        case gradientFill(GradientFill)
        /// A content kind a newer build wrote: the "content" object's JSON (sorted keys), written back as read; drawn as
        /// nothing, never projected to v1.
        case unsupported(String)
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

    // MARK: W3 (document v2). Each key is written only when it differs from its default (LayerCodable.swift), so a
    // layer that uses no W3 feature encodes byte for byte like W2 under sorted keys (D2).

    /// "fill", default 1: multiplies the content's alpha before the blend (D6). Forced to 1 on groups.
    public var fillOpacity: Double
    /// "maskStack", default nil: the layer mask (D8), in the layer's content space when linked, else canvas space.
    public var maskStack: MaskStack?
    /// "maskEnabled", default true.
    public var isMaskEnabled: Bool
    /// "maskLinked", default true.
    public var isMaskLinked: Bool
    /// "clipped", default false: clips onto the nearest unclipped layer below with the same parent (D5).
    public var isClipped: Bool
    /// "lock", default []: partial locks (D7); `isLocked` stays "lock all".
    public var lockOptions: LayerLockOptions
    /// "parent", default nil: the group layer this layer belongs to (one level, D1).
    public var parentID: UUID?
    /// "recipeKind", default nil; an unknown raw value decodes as nil. Picks an adjustment layer's panel and name (D9).
    public var recipeKind: AdjustmentLayerKind?
    /// "bakedMask", default nil: a raster of maskStack kept only for the v1 projection (D8, "should"); never rendered.
    public var bakedMask: MaskReference?
    /// "ref", default nil: the stored ref number (D19), assigned at creation, never renumbered; out of render keys.
    public var refNumber: Int?
    /// Unknown keys as sorted-keys JSON text, written back as read (D2). Not a key of its own.
    public var retainedFields: [String: String]

    public init(id: UUID = UUID(), name: String, content: Content, transform: LayerTransform = .identity,
                opacity: Double = 1, blendMode: BlendMode = .normal, isVisible: Bool = true,
                isLocked: Bool = false, mask: MaskReference? = nil, edits: EditStack = EditStack(), group: LayerGroup? = nil,
                fillOpacity: Double = 1, maskStack: MaskStack? = nil, isMaskEnabled: Bool = true, isMaskLinked: Bool = true,
                isClipped: Bool = false, lockOptions: LayerLockOptions = [], parentID: UUID? = nil,
                recipeKind: AdjustmentLayerKind? = nil, refNumber: Int? = nil) {
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
        self.fillOpacity = fillOpacity
        self.maskStack = maskStack
        self.isMaskEnabled = isMaskEnabled
        self.isMaskLinked = isMaskLinked
        self.isClipped = isClipped
        self.lockOptions = lockOptions
        self.parentID = parentID
        self.recipeKind = recipeKind
        self.bakedMask = nil
        self.refNumber = refNumber
        self.retainedFields = [:]
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
        case .group: return "folder"
        // "square.fill.on.square.fill" needs a recent SF Symbols set; the UI falls back to "paintbrush.fill".
        case .gradientFill: return "square.fill.on.square.fill"
        case .unsupported: return "questionmark.square.dashed"
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
        case .image, .adjustment, .fill, .group, .gradientFill, .unsupported:
            return nil
        }
    }

    // MARK: W3 accessors

    public var isGroup: Bool {
        if case .group = content { return true }
        return false
    }

    public var isAdjustment: Bool {
        if case .adjustment = content { return true }
        return false
    }

    /// .fill or .gradientFill.
    public var isFill: Bool {
        switch content {
        case .fill, .gradientFill: return true
        case .image, .text, .shape, .adjustment, .group, .unsupported: return false
        }
    }

    public var folder: LayerFolder? {
        if case .group(let folder) = content { return folder }
        return nil
    }

    public var gradient: GradientFill? {
        if case .gradientFill(let gradient) = content { return gradient }
        return nil
    }

    /// isLocked → .all, else lockOptions (the parent's lock is added by PhotoDocument.effectiveLock(of:)).
    public var ownLock: LayerLockOptions {
        isLocked ? .all : lockOptions
    }

    /// True when the layer uses any v2-only state (D2 needsV2); `refNumber` and `bakedMask` alone do not count.
    public var usesV2State: Bool {
        switch content {
        case .group, .gradientFill, .unsupported: return true
        case .image, .text, .shape, .adjustment, .fill: break
        }
        return fillOpacity != 1 || maskStack != nil || !isMaskEnabled || !isMaskLinked || isClipped || !lockOptions.isEmpty
            || parentID != nil || recipeKind != nil || !transform.isAffineIdentityExtras || !transform.retainedFields.isEmpty
            || !retainedFields.isEmpty
    }
}
