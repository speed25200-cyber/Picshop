import Foundation

// W3 layer model values (D4, D7, D9): locks, a group's settings, gradient fills and their shared maths (the CPU
// reference L2's GradientRenderer matches), and the adjustment-layer kinds. Codable keys are final (D2); every decoder
// is lenient.

/// What a layer lock forbids (W3, D7). `Layer.isLocked` (the v1 key) stays "lock all".
/// Codable as the bare Int (RawRepresentable); unknown bits are kept as read.
public struct LayerLockOptions: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Alpha may not change.
    public static let transparency = LayerLockOptions(rawValue: 1)
    /// No edit operation and no content change.
    public static let pixels = LayerLockOptions(rawValue: 2)
    /// No transform, flip or align.
    public static let position = LayerLockOptions(rawValue: 4)
    public static let all: LayerLockOptions = [.transparency, .pixels, .position]
}

/// A group's own settings (D4). One level: a group never contains a group.
public struct LayerFolder: Hashable, Codable, Sendable {
    /// Photoshop's default: the children composite straight onto the backdrop.
    public var passThrough: Bool
    public var isCollapsed: Bool

    public init(passThrough: Bool = true, isCollapsed: Bool = false) {
        self.passThrough = passThrough
        self.isCollapsed = isCollapsed
    }

    // Keys passThrough (default true) and collapsed (default false).
    private enum CodingKeys: String, CodingKey { case passThrough, collapsed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passThrough = ((try? c.decodeIfPresent(Bool.self, forKey: .passThrough)) ?? nil) ?? true
        isCollapsed = ((try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? nil) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(passThrough, forKey: .passThrough)
        try c.encode(isCollapsed, forKey: .collapsed)
    }
}

/// One stop of a gradient fill: a location 0…1 and a straight-alpha colour.
public struct GradientStop: Hashable, Codable, Sendable {
    public var location: Double
    public var color: PSColor

    public init(location: Double, color: PSColor) {
        self.location = location
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case location = "at"
        case color
    }
}

/// A gradient fill layer's gradient (D9). Keys style, stops, angle, scale, center, reverse, dither; every key
/// decodes with the init default; an unknown style is .linear; stops are sorted by location and kept to 2…8.
public struct GradientFill: Hashable, Codable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable { case linear, radial, reflected }

    static let stopRange = 2...8

    public var style: Style
    public var stops: [GradientStop]
    /// Degrees, Photoshop's convention: 0 runs left → right, 90 bottom → top.
    public var angle: Double
    /// 10…150 (percent).
    public var scale: Double
    /// Canvas-normalised, top-left origin.
    public var center: PSPoint
    public var reverse: Bool
    public var dither: Bool

    public init(style: Style = .linear, stops: [GradientStop], angle: Double = 90, scale: Double = 100,
                center: PSPoint = PSPoint(x: 0.5, y: 0.5), reverse: Bool = false, dither: Bool = true) {
        self.style = style
        self.stops = stops
        self.angle = angle
        self.scale = scale
        self.center = center
        self.reverse = reverse
        self.dither = dither
    }

    /// Photoshop's « Premier plan → transparent » with a black foreground.
    public static let blackToTransparent = GradientFill(stops: [GradientStop(location: 0, color: .black),
                                                                GradientStop(location: 1, color: PSColor(red: 0, green: 0, blue: 0, alpha: 0))])

    public static func twoColor(_ a: PSColor, _ b: PSColor, style: Style = .linear, angle: Double = 90) -> GradientFill {
        GradientFill(style: style, stops: [GradientStop(location: 0, color: a), GradientStop(location: 1, color: b)], angle: angle)
    }

    /// The colour at t ∈ 0…1 (after `reverse`): the first stop's colour before it, the last one's after it, and between
    /// two stops a linear mix of their components and alpha. The mix is done on premultiplied components, so a stop
    /// that fades to transparent keeps its neighbour's colour (red → clear is red at 50 % alpha halfway, never a dark
    /// fringe); when both alphas are equal it is exactly linear in the components. L2's 256-entry ramp is built from it.
    public func color(at t: Double) -> PSColor {
        let sorted = Self.normalizedStops(stops)
        let x = (reverse ? 1 - (t.isFinite ? t : 0) : (t.isFinite ? t : 0)).clamped(to: 0...1)
        guard let first = sorted.first, let last = sorted.last else { return .clear }
        if x <= first.location { return first.color }
        if x >= last.location { return last.color }
        for index in 1..<sorted.count {
            let a = sorted[index - 1], b = sorted[index]
            guard x <= b.location else { continue }
            let span = b.location - a.location
            let f = span > 1e-12 ? (x - a.location) / span : 1
            return Self.mix(a.color, b.color, f)
        }
        return last.color
    }

    /// t (unclamped, then clamped 0…1) for a canvas-normalised point on a canvas of aspect w/h. The maths runs in
    /// square units (x × aspect, y), so a circle stays a circle on a wide canvas. Linear: the projection on the angle's
    /// axis through `center` (direction (cos a, −sin a), y down, so 90° runs bottom → top), 0.5 at the centre, over a
    /// span of `scale` % of the canvas diagonal; radial: the distance from the centre over `scale` % of the half
    /// diagonal; reflected: |linear t − 0.5| · 2, the first stop at the centre mirrored outwards.
    public func parameter(at point: PSPoint, aspect: Double) -> Double {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 1
        let diagonal = (ratio * ratio + 1).squareRoot()
        let fraction = (scale.isFinite ? scale : 100) / 100
        let dx = (point.x - center.x) * ratio, dy = point.y - center.y
        let t: Double
        switch style {
        case .linear, .reflected:
            let radians = (angle.isFinite ? angle : 90) * .pi / 180
            let span = max(1e-9, fraction * diagonal)
            let linear = 0.5 + (dx * cos(radians) - dy * sin(radians)) / span
            t = style == .linear ? linear : abs(linear - 0.5) * 2
        case .radial:
            let radius = max(1e-9, fraction * diagonal / 2)
            t = (dx * dx + dy * dy).squareRoot() / radius
        }
        return t.isFinite ? t.clamped(to: 0...1) : 0
    }

    /// The premultiplied mix of two straight colours at f ∈ 0…1, returned straight.
    static func mix(_ a: PSColor, _ b: PSColor, _ f: Double) -> PSColor {
        let alpha = a.alpha + (b.alpha - a.alpha) * f
        guard alpha > 1e-9 else {
            return PSColor(red: a.red + (b.red - a.red) * f, green: a.green + (b.green - a.green) * f,
                           blue: a.blue + (b.blue - a.blue) * f, alpha: 0)
        }
        func channel(_ x: Double, _ y: Double) -> Double { ((x * a.alpha) + (y * b.alpha - x * a.alpha) * f) / alpha }
        return PSColor(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue), alpha: alpha)
    }

    private enum CodingKeys: String, CodingKey { case style, stops, angle, scale, center, reverse, dither }

    public init(from decoder: Decoder) throws {
        // Lenient (D2): a value this build cannot read takes the init default rather than failing the layer.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let styleName = (try? c.decodeIfPresent(String.self, forKey: .style)) ?? nil
        style = styleName.flatMap(Style.init(rawValue:)) ?? .linear
        stops = Self.normalizedStops((try? c.decodeIfPresent([GradientStop].self, forKey: .stops)) ?? nil)
        angle = ((try? c.decodeIfPresent(Double.self, forKey: .angle)) ?? nil) ?? 90
        scale = ((try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? nil) ?? 100
        center = ((try? c.decodeIfPresent(PSPoint.self, forKey: .center)) ?? nil) ?? PSPoint(x: 0.5, y: 0.5)
        reverse = ((try? c.decodeIfPresent(Bool.self, forKey: .reverse)) ?? nil) ?? false
        dither = ((try? c.decodeIfPresent(Bool.self, forKey: .dither)) ?? nil) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(style, forKey: .style)
        try c.encode(stops, forKey: .stops)
        try c.encode(angle, forKey: .angle)
        try c.encode(scale, forKey: .scale)
        try c.encode(center, forKey: .center)
        try c.encode(reverse, forKey: .reverse)
        try c.encode(dither, forKey: .dither)
    }

    /// Sorted by location (clamped to 0…1, a non-finite one at 0), 2…8 of them: none read → black to transparent;
    /// one → that stop and a copy at 1 (at 0 and 1 when it already sat at 1); more than 8 → the first 8 by location.
    static func normalizedStops(_ read: [GradientStop]?) -> [GradientStop] {
        let clamped = (read ?? []).map { GradientStop(location: $0.location.isFinite ? $0.location.clamped(to: 0...1) : 0, color: $0.color) }
        // A stable sort: two stops at one location keep their order (a hard edge).
        let sorted = clamped.enumerated().sorted { $0.element.location != $1.element.location ? $0.element.location < $1.element.location : $0.offset < $1.offset }
            .map(\.element)
        switch sorted.count {
        case 0: return blackToTransparent.stops
        case 1:
            let stop = sorted[0]
            return stop.location >= 1 ? [GradientStop(location: 0, color: stop.color), stop] : [stop, GradientStop(location: 1, color: stop.color)]
        default: return Array(sorted.prefix(stopRange.upperBound))
        }
    }

    /// This gradient with its stops normalised (sorted, clamped, 2…8): what `LayerEdit.gradient` stores.
    public var normalized: GradientFill {
        var copy = self
        copy.stops = Self.normalizedStops(stops)
        return copy
    }
}

/// Which panel and name an adjustment layer has; its recipe is the layer's `edits` (D9).
public enum AdjustmentLayerKind: String, Codable, Sendable, CaseIterable {
    case light, curves, levels, hsl, colorGrade, lut, look

    public var frenchName: String {
        switch self {
        case .light: return "Lumière"
        case .curves: return "Courbes"
        case .levels: return "Niveaux"
        case .hsl: return "Teinte/Saturation"
        case .colorGrade: return "Étalonnage"
        case .lut: return "LUT"
        case .look: return "Look"
        }
    }

    public var englishName: String {
        switch self {
        case .light: return "Light"
        case .curves: return "Curves"
        case .levels: return "Levels"
        case .hsl: return "Hue/Saturation"
        case .colorGrade: return "Color Grading"
        case .lut: return "LUT"
        case .look: return "Look"
        }
    }
}
