import Foundation

// W3 (L3, §7.12): what the Layers column, the Layers inspector and the transform handles say, on screen and for
// VoiceOver, in French and English. Pure, so Linux tests the words: « Tasse, calque d'image, 80 %, produit, écrêté,
// masque, verrouillé, sélectionné ». The transform handles are adjustable elements (« Largeur 120 % », ±5 %), the
// column's cells are buttons with the actions « Afficher/Masquer », « Monter », « Descendre ».

/// The transform's figures as the HUD and the transform rows show them: the size in percent of the natural fit, the
/// rotation, the skews, and where the layer's bounds are centred in canvas pixels. Computed from the transform alone
/// for an affine placement (the numbers match the `layerTransform` params), from the corners for a 4-corner one.
public struct LayerTransformFigures: Hashable, Sendable {
    /// Largeur: 100 × scale × |scaleX| (% of the natural fit).
    public var widthPercent: Double
    /// Hauteur: 100 × scale × |scaleY|.
    public var heightPercent: Double
    /// Clockwise degrees, −180…180.
    public var rotation: Double
    public var skewX: Double
    public var skewY: Double
    /// The bounds' centre in canvas pixels.
    public var x: Double
    public var y: Double

    public init(widthPercent: Double = 100, heightPercent: Double = 100, rotation: Double = 0, skewX: Double = 0, skewY: Double = 0,
                x: Double = 0, y: Double = 0) {
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.rotation = rotation
        self.skewX = skewX
        self.skewY = skewY
        self.x = x
        self.y = y
    }

    /// The figures of `layer` placed on `canvasSize`; `contentSize` (when known) gives the bounds' centre and, for a
    /// 4-corner placement, the edge lengths. The base photo is never transformed: 100 %, centred.
    public static func of(_ layer: Layer, contentSize: PSSize?, canvasSize: PSSize, isBase: Bool) -> LayerTransformFigures {
        if isBase { return LayerTransformFigures(x: canvasSize.width / 2, y: canvasSize.height / 2) }
        let transform = LayerPlacement.effectiveTransform(of: layer)
        var figures = LayerTransformFigures(widthPercent: 100 * transform.scale * abs(transform.scaleX),
                                            heightPercent: 100 * transform.scale * abs(transform.scaleY),
                                            rotation: normalizedDegrees(transform.rotation),
                                            skewX: transform.skewX, skewY: transform.skewY,
                                            x: transform.center.x * canvasSize.width, y: transform.center.y * canvasSize.height)
        guard let size = contentSize, size.width > 0, size.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return figures }
        let bounds = LayerPlacement.bounds(for: layer, contentSize: size, canvasSize: canvasSize, isBase: false)
        figures.x = bounds.midX * canvasSize.width
        figures.y = bounds.midY * canvasSize.height
        if let quad = transform.quad, quad.count == 4 {
            // The corners decide: the top edge's length and angle, the left edge's length, over the fitted size.
            let fit = LayerPlacement.fitScale(contentSize: size, canvasSize: canvasSize)
            let tl = (quad[0].x * canvasSize.width, quad[0].y * canvasSize.height)
            let tr = (quad[1].x * canvasSize.width, quad[1].y * canvasSize.height)
            let bl = (quad[3].x * canvasSize.width, quad[3].y * canvasSize.height)
            let top = ((tr.0 - tl.0) * (tr.0 - tl.0) + (tr.1 - tl.1) * (tr.1 - tl.1)).squareRoot()
            let left = ((bl.0 - tl.0) * (bl.0 - tl.0) + (bl.1 - tl.1) * (bl.1 - tl.1)).squareRoot()
            figures.widthPercent = 100 * top / max(1e-9, fit * size.width)
            figures.heightPercent = 100 * left / max(1e-9, fit * size.height)
            figures.rotation = normalizedDegrees(atan2(tr.1 - tl.1, tr.0 - tl.0) * 180 / .pi)
            figures.skewX = 0
            figures.skewY = 0
        }
        return figures
    }

    /// « L 120 % · H 80 % · 15° » / "W 120% · H 80% · 15°"; a skew follows when set (« Incl. 12° »).
    public func sizeLine(language: OpLanguage) -> String {
        let fr = language == .fr
        var parts = [
            "\(fr ? "L" : "W") \(LayerAccessibility.percent(widthPercent, language: language))",
            "H \(LayerAccessibility.percent(heightPercent, language: language))",
            LayerAccessibility.degrees(rotation, language: language),
        ]
        if abs(skewX) > 0.05 || abs(skewY) > 0.05 {
            let skew = abs(skewX) >= abs(skewY) ? skewX : skewY
            parts.append("\(fr ? "Incl." : "Skew") \(LayerAccessibility.degrees(skew, language: language))")
        }
        return parts.joined(separator: " · ")
    }

    /// « X 412 · Y 96 px ».
    public func positionLine(language: OpLanguage) -> String {
        "X \(Int(x.rounded())) · Y \(Int(y.rounded())) px"
    }

    /// −180…180 (−180 reads as 180).
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return abs(value) < 1e-9 ? 0 : value
    }
}

public enum LayerAccessibility {
    /// The handles' VoiceOver step: ±5 percentage points of width, height or scale, ±5° of rotation.
    public static let handleStep = 5.0

    // MARK: Words

    /// What kind of layer this is: « calque d'image », « calque de texte », « forme », « calque de réglage Courbes »,
    /// « calque de remplissage », « calque de dégradé », « groupe », « tableau », « photo de fond ».
    public static func kindName(_ layer: Layer, isBase: Bool = false, bundle: LayerGroup.Kind? = nil, language: OpLanguage) -> String {
        let fr = language == .fr
        if isBase { return fr ? "photo de fond" : "background photo" }
        if let bundle {
            switch bundle {
            case .tableCells: return fr ? "tableau" : "table"
            case .tableHighlight: return fr ? "surlignage" : "highlight"
            }
        }
        switch layer.content {
        case .image: return fr ? "calque d'image" : "image layer"
        case .text: return fr ? "calque de texte" : "text layer"
        case .shape: return fr ? "forme" : "shape"
        case .adjustment:
            let kind = layer.recipeKind ?? .light
            return fr ? "calque de réglage \(kind.frenchName)" : "\(kind.englishName) adjustment layer"
        case .fill: return fr ? "calque de remplissage" : "fill layer"
        case .gradientFill: return fr ? "calque de dégradé" : "gradient layer"
        case .group: return fr ? "groupe" : "group"
        case .unsupported: return fr ? "calque d'une version plus récente" : "layer from a newer version"
        }
    }

    /// A blend mode as the row says it: « produit », "multiply".
    public static func blendName(_ mode: BlendMode, language: OpLanguage) -> String {
        language == .fr ? mode.frenchName.lowercased() : mode.displayName.lowercased()
    }

    /// The lock in words: « verrouillé » for all, else what is locked (« position verrouillée »); nil when unlocked.
    public static func lockName(_ lock: LayerLockOptions, language: OpLanguage) -> String? {
        let fr = language == .fr
        if lock.isSuperset(of: .all) { return fr ? "verrouillé" : "locked" }
        var parts: [String] = []
        if lock.contains(.position) { parts.append(fr ? "position verrouillée" : "position locked") }
        if lock.contains(.pixels) { parts.append(fr ? "pixels verrouillés" : "pixels locked") }
        if lock.contains(.transparency) { parts.append(fr ? "transparence verrouillée" : "transparency locked") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The name a row shows: the layer's own name, a bundle by its kind and size (« Tableau · 120 cases »), the base
    /// « Photo de fond » until it is renamed, a text layer without a name its words.
    public static func displayName(_ layer: Layer, isBase: Bool = false, bundle: (kind: LayerGroup.Kind, count: Int)? = nil,
                                   language: OpLanguage) -> String {
        let fr = language == .fr
        if let bundle {
            switch bundle.kind {
            case .tableCells: return fr ? "Tableau · \(bundle.count) cases" : "Table · \(bundle.count) cells"
            case .tableHighlight: return fr ? "Surlignage · \(bundle.count) cases" : "Highlight · \(bundle.count) boxes"
            }
        }
        let name = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The base keeps the name the import gave it ("Photo") until the person renames it.
        if isBase, name.isEmpty || name == "Photo" { return fr ? "Photo de fond" : "Background photo" }
        if !name.isEmpty { return name }
        if let text = layer.textElement?.text, !text.isEmpty { return String(text.prefix(40)) }
        return capitalizedFirst(kindName(layer, language: language))
    }

    /// The row's VoiceOver label: the name, the kind, then what is not default: opacity, blend, fill, clipping, the
    /// mask, the lock, hidden, selected. « Tasse, calque d'image, 80 %, produit, écrêté, masque, verrouillé,
    /// sélectionné ».
    public static func label(for layer: Layer, in document: PhotoDocument, isSelected: Bool, language: OpLanguage) -> String {
        let fr = language == .fr
        let isBase = layer.id == document.baseLayerID
        let bundle = document.bundle(containing: layer.id)
        let bundleInfo: (kind: LayerGroup.Kind, count: Int)? = bundle.flatMap { $0.memberIDs.count > 1 ? (kind: $0.kind, count: $0.memberIDs.count) : nil }
        let name = displayName(layer, isBase: isBase, bundle: bundleInfo, language: language)
        let kind = kindName(layer, isBase: isBase, bundle: bundleInfo?.kind, language: language)
        // « Photo de fond » is its own kind: said once.
        var parts = name.lowercased() == kind.lowercased() ? [name] : [name, kind]
        if layer.isGroup {
            let count = document.children(of: layer.id).count
            parts.append(fr ? (count == 1 ? "1 calque" : "\(count) calques") : (count == 1 ? "1 layer" : "\(count) layers"))
        }
        if layer.opacity < 0.995 { parts.append(percent(layer.opacity * 100, language: language)) }
        if layer.blendMode != .normal { parts.append(blendName(layer.blendMode, language: language)) }
        if !layer.isGroup, layer.fillOpacity < 0.995 {
            parts.append("\(fr ? "fond" : "fill") \(percent(layer.fillOpacity * 100, language: language))")
        }
        if layer.isClipped, !isBase { parts.append(fr ? "écrêté" : "clipped") }
        if layer.maskStack != nil || layer.mask != nil {
            parts.append(layer.isMaskEnabled ? (fr ? "masque" : "mask") : (fr ? "masque désactivé" : "mask off"))
        }
        if let lock = lockName(document.effectiveLock(of: layer.id), language: language) { parts.append(lock) }
        if !layer.isVisible { parts.append(fr ? "masqué" : "hidden") }
        if isSelected { parts.append(fr ? "sélectionné" : "selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Column actions

    /// The column cell's visibility action: « Masquer » for a visible layer, « Afficher » for a hidden one.
    public static func visibilityAction(isVisible: Bool, language: OpLanguage) -> String {
        language == .fr ? (isVisible ? "Masquer" : "Afficher") : (isVisible ? "Hide" : "Show")
    }

    /// « Monter ».
    public static func moveUpAction(language: OpLanguage) -> String { language == .fr ? "Monter" : "Move up" }

    /// « Descendre ».
    public static func moveDownAction(language: OpLanguage) -> String { language == .fr ? "Descendre" : "Move down" }

    // MARK: Transform handles

    /// The handle's name: « Coin supérieur gauche », « Bord droit », « Rotation », « Calque », « Pivot ».
    public static func handleName(_ kind: TransformHandleKind, language: OpLanguage) -> String {
        let fr = language == .fr
        switch kind {
        case .corner(let index):
            switch index {
            case 0: return fr ? "Coin supérieur gauche" : "Top left corner"
            case 1: return fr ? "Coin supérieur droit" : "Top right corner"
            case 2: return fr ? "Coin inférieur droit" : "Bottom right corner"
            default: return fr ? "Coin inférieur gauche" : "Bottom left corner"
            }
        case .edge(let index):
            switch index {
            case 0: return fr ? "Bord supérieur" : "Top edge"
            case 1: return fr ? "Bord droit" : "Right edge"
            case 2: return fr ? "Bord inférieur" : "Bottom edge"
            default: return fr ? "Bord gauche" : "Left edge"
            }
        case .rotate: return fr ? "Poignée de rotation" : "Rotation handle"
        case .pivot: return fr ? "Pivot" : "Pivot"
        case .inside: return fr ? "Calque" : "Layer"
        }
    }

    /// What the handle's value reads: corners « Échelle 100 % », left and right edges « Largeur 120 % », top and
    /// bottom « Hauteur 80 % », the knob « Rotation 15° », the pivot and the inside the position.
    public static func handleValue(_ kind: TransformHandleKind, figures: LayerTransformFigures, language: OpLanguage) -> String {
        let fr = language == .fr
        switch kind {
        case .corner:
            return "\(fr ? "Échelle" : "Scale") \(percent((figures.widthPercent + figures.heightPercent) / 2, language: language))"
        case .edge(let index) where index == 1 || index == 3:
            return "\(fr ? "Largeur" : "Width") \(percent(figures.widthPercent, language: language))"
        case .edge:
            return "\(fr ? "Hauteur" : "Height") \(percent(figures.heightPercent, language: language))"
        case .rotate:
            return "Rotation \(degrees(figures.rotation, language: language))"
        case .pivot, .inside:
            return figures.positionLine(language: language)
        }
    }

    /// Whether VoiceOver can adjust the handle (the knob, the corners, the edges).
    public static func isAdjustable(_ kind: TransformHandleKind) -> Bool {
        switch kind {
        case .corner, .edge, .rotate: return true
        case .pivot, .inside: return false
        }
    }

    /// VoiceOver's increment or decrement of a handle: ±5 percentage points of scale (corners), width (left and
    /// right edges) or height (top and bottom), ±5° of rotation (the knob). A 4-corner placement scales or turns its
    /// corners about their centroid. Nil when the result would be degenerate or the handle is not adjustable.
    public static func adjusted(_ kind: TransformHandleKind, transform: LayerTransform, increment: Bool) -> LayerTransform? {
        let sign = increment ? 1.0 : -1.0
        var result = transform
        switch kind {
        case .rotate:
            result.rotation = LayerTransformFigures.normalizedDegrees(transform.rotation + sign * handleStep)
            if let quad = transform.quad, quad.count == 4 {
                let center = centroid(quad)
                let angle = sign * handleStep * .pi / 180
                result.quad = quad.map { point in
                    let dx = point.x - center.x, dy = point.y - center.y
                    return PSPoint(x: center.x + dx * cos(angle) - dy * sin(angle), y: center.y + dx * sin(angle) + dy * cos(angle))
                }
            }
            return result
        case .corner, .edge:
            let horizontal: Bool, vertical: Bool
            if case .edge(let index) = kind {
                horizontal = index == 1 || index == 3
                vertical = !horizontal
            } else {
                horizontal = true
                vertical = true
            }
            if let quad = transform.quad, quad.count == 4 {
                let center = centroid(quad)
                let factor = 1 + sign * handleStep / 100
                result.quad = quad.map { point in
                    PSPoint(x: horizontal ? center.x + (point.x - center.x) * factor : point.x,
                            y: vertical ? center.y + (point.y - center.y) * factor : point.y)
                }
                return result
            }
            guard transform.scale > 0, transform.scale.isFinite else { return nil }
            if horizontal && vertical {
                let next = 100 * transform.scale + sign * handleStep
                guard next >= 1 else { return nil }
                result.scale = next / 100
            } else if horizontal {
                let next = 100 * transform.scale * abs(transform.scaleX) + sign * handleStep
                guard next >= 1 else { return nil }
                result.scaleX = (transform.scaleX < 0 ? -1 : 1) * next / 100 / transform.scale
            } else {
                let next = 100 * transform.scale * abs(transform.scaleY) + sign * handleStep
                guard next >= 1 else { return nil }
                result.scaleY = (transform.scaleY < 0 ? -1 : 1) * next / 100 / transform.scale
            }
            return result
        case .pivot, .inside:
            return nil
        }
    }

    // MARK: Numbers

    /// « 80 % » / "80%", rounded to a whole percent.
    public static func percent(_ value: Double, language: OpLanguage) -> String {
        let whole = value.isFinite ? Int(value.rounded()) : 0
        return language == .fr ? "\(whole) %" : "\(whole)%"
    }

    /// « 15° », « −7,5° » (French comma, U+2212 minus); a whole number of degrees has no decimal.
    public static func degrees(_ value: Double, language: OpLanguage) -> String {
        let clean = value.isFinite ? value : 0
        let rounded = (clean * 10).rounded() / 10
        let magnitude = abs(rounded)
        var text = magnitude.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(magnitude))" : String(format: "%.1f", magnitude)
        if language == .fr { text = text.replacingOccurrences(of: ".", with: ",") }
        return (rounded < 0 ? "\u{2212}" : "") + text + "°"
    }

    // MARK: Helpers

    static func centroid(_ points: [PSPoint]) -> PSPoint {
        guard !points.isEmpty else { return PSPoint(x: 0.5, y: 0.5) }
        var x = 0.0, y = 0.0
        for point in points {
            x += point.x
            y += point.y
        }
        return PSPoint(x: x / Double(points.count), y: y / Double(points.count))
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
