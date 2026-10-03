import Foundation

/// Every continuous, non-destructive tone/colour control the editor exposes.
///
/// Values are normalised: bipolar parameters live in `-1...1` with `0` neutral,
/// unipolar parameters live in `0...1` with `0` neutral. The imaging layer maps
/// these to concrete Core Image filter inputs.
public enum AdjustmentParameter: String, Codable, Sendable, CaseIterable, Identifiable {
    case exposure
    case brightness
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case saturation
    case vibrance
    case temperature
    case tint
    case sharpness
    case clarity
    case noiseReduction
    case vignette
    case grain
    case fade
    case hue
    case skinTone

    public var id: String { rawValue }

    public var isBipolar: Bool {
        switch self {
        case .sharpness, .noiseReduction, .vignette, .grain, .fade, .clarity:
            return false
        default:
            return true
        }
    }

    public var range: ClosedRange<Double> { isBipolar ? -1...1 : 0...1 }
    public var neutralValue: Double { 0 }

    /// A sensible step for "a bit more / a bit less" voice commands.
    public var defaultStep: Double { 0.15 }

    /// Human readable names, English and French, used by parsers and UI.
    public var englishName: String {
        switch self {
        case .exposure: return "Exposure"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .temperature: return "Warmth"
        case .tint: return "Tint"
        case .sharpness: return "Sharpness"
        case .clarity: return "Clarity"
        case .noiseReduction: return "Noise Reduction"
        case .vignette: return "Vignette"
        case .grain: return "Grain"
        case .fade: return "Fade"
        case .hue: return "Hue"
        case .skinTone: return "Skin Tone"
        }
    }

    public var frenchName: String {
        switch self {
        case .exposure: return "Exposition"
        case .brightness: return "Luminosité"
        case .contrast: return "Contraste"
        case .highlights: return "Hautes lumières"
        case .shadows: return "Ombres"
        case .whites: return "Blancs"
        case .blacks: return "Noirs"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .temperature: return "Chaleur"
        case .tint: return "Teinte"
        case .sharpness: return "Netteté"
        case .clarity: return "Clarté"
        case .noiseReduction: return "Réduction du bruit"
        case .vignette: return "Vignettage"
        case .grain: return "Grain"
        case .fade: return "Voile"
        case .hue: return "Nuance"
        case .skinTone: return "Teint"
        }
    }

    /// SF Symbol used in the UI.
    public var symbolName: String {
        switch self {
        case .exposure: return "sun.max"
        case .brightness: return "sun.min"
        case .contrast: return "circle.lefthalf.filled"
        case .highlights: return "sun.haze"
        case .shadows: return "moon"
        case .whites: return "circle"
        case .blacks: return "circle.fill"
        case .saturation: return "drop"
        case .vibrance: return "drop.halffull"
        case .temperature: return "thermometer.medium"
        case .tint: return "paintpalette"
        case .sharpness: return "triangle"
        case .clarity: return "sparkle"
        case .noiseReduction: return "waveform.path.ecg"
        case .vignette: return "circle.dashed.inset.filled"
        case .grain: return "circle.grid.3x3"
        case .fade: return "cloud"
        case .hue: return "rainbow"
        case .skinTone: return "face.smiling"
        }
    }

    /// Parameters grouped for the adjustments panel.
    public static let lightGroup: [AdjustmentParameter] = [.exposure, .brightness, .contrast, .highlights, .shadows, .whites, .blacks]
    public static let colorGroup: [AdjustmentParameter] = [.saturation, .vibrance, .temperature, .tint, .hue, .skinTone]
    public static let detailGroup: [AdjustmentParameter] = [.sharpness, .clarity, .noiseReduction]
    public static let effectsGroup: [AdjustmentParameter] = [.vignette, .grain, .fade]
}

/// A complete set of adjustment values. Equatable and Codable so it can live
/// inside the undo history and project files.
public struct Adjustments: Hashable, Codable, Sendable {
    private var storage: [AdjustmentParameter: Double]

    public init() {
        storage = [:]
    }

    public init(_ values: [AdjustmentParameter: Double]) {
        storage = values.filter { $0.value != $0.key.neutralValue }
    }

    public static let neutral = Adjustments()

    public subscript(parameter: AdjustmentParameter) -> Double {
        get { storage[parameter] ?? parameter.neutralValue }
        set {
            let clamped = newValue.clamped(to: parameter.range)
            if abs(clamped - parameter.neutralValue) < 0.0005 {
                storage.removeValue(forKey: parameter)
            } else {
                storage[parameter] = clamped
            }
        }
    }

    public var isNeutral: Bool { storage.isEmpty }
    public var activeParameters: [AdjustmentParameter] { AdjustmentParameter.allCases.filter { storage[$0] != nil } }

    /// Adds `delta` to the parameter, clamping to its range.
    public mutating func nudge(_ parameter: AdjustmentParameter, by delta: Double) {
        self[parameter] = self[parameter] + delta
    }

    /// Combines two sets by summing values (used to apply a look on top of manual edits).
    public func combined(with other: Adjustments, weight: Double = 1) -> Adjustments {
        var result = self
        for parameter in other.activeParameters {
            result.nudge(parameter, by: other[parameter] * weight)
        }
        return result
    }

    /// Returns a copy where every value is scaled by `factor` (intensity slider for looks).
    public func scaled(by factor: Double) -> Adjustments {
        var result = Adjustments()
        for parameter in activeParameters {
            result[parameter] = self[parameter] * factor
        }
        return result
    }

    // MARK: Codable — stored as a flat dictionary keyed by parameter name.

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: Double].self)
        var values: [AdjustmentParameter: Double] = [:]
        for (key, value) in raw {
            if let parameter = AdjustmentParameter(rawValue: key) {
                values[parameter] = value.clamped(to: parameter.range)
            }
        }
        self.init(values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let raw = Dictionary(uniqueKeysWithValues: storage.map { ($0.key.rawValue, $0.value) })
        try container.encode(raw)
    }
}

/// A tone curve defined by control points in unit space, per channel: 2 to 16
/// points each (the rgb master and red, green, blue), evaluated by CurveSpline.
/// A look's built-in curve (5 points) goes through Core Image's tone curve with
/// the adjustments; the person's own curve (`EditOperation.Kind.toneCurve`)
/// is baked with Levels into one ToneLUT.
public struct ToneCurve: Hashable, Codable, Sendable {
    public struct Point: Hashable, Codable, Sendable {
        public var input: Double
        public var output: Double
        public init(_ input: Double, _ output: Double) {
            self.input = input.clamped(to: 0...1)
            self.output = output.clamped(to: 0...1)
        }
    }

    public var rgb: [Point]
    public var red: [Point]
    public var green: [Point]
    public var blue: [Point]

    public init(rgb: [Point] = ToneCurve.linear, red: [Point] = ToneCurve.linear, green: [Point] = ToneCurve.linear, blue: [Point] = ToneCurve.linear) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let linear: [Point] = [Point(0, 0), Point(0.25, 0.25), Point(0.5, 0.5), Point(0.75, 0.75), Point(1, 1)]
    public static let identity = ToneCurve()

    /// Every channel leaves every value where it is, within 1/1024 (evaluated, not compared point by point).
    public var isIdentity: Bool { Channel.allCases.allSatisfy { isIdentity($0) } }

    /// A gentle S-curve that adds punch without clipping.
    public static func sCurve(strength: Double) -> ToneCurve {
        let s = strength.clamped(to: 0...1) * 0.12
        return ToneCurve(rgb: [Point(0, 0), Point(0.25, 0.25 - s), Point(0.5, 0.5), Point(0.75, 0.75 + s), Point(1, 1)])
    }

    /// A matte/faded look lifting blacks.
    public static func matte(lift: Double) -> ToneCurve {
        let l = lift.clamped(to: 0...1) * 0.12
        return ToneCurve(rgb: [Point(0, l), Point(0.25, 0.25 + l * 0.6), Point(0.5, 0.5 + l * 0.3), Point(0.75, 0.75), Point(1, 1)])
    }

    /// The curves panel's presets row, and the catalog's `curves` presets (same shapes as the
    /// operation handler's): control points for one channel at a strength 0…1.
    public enum Preset: String, Codable, Sendable, CaseIterable, Identifiable {
        case sCurve, strongS, matte, fade, invert, brighten, darken, linear

        public var id: String { rawValue }

        public var englishName: String {
            switch self {
            case .sCurve: return "S curve"
            case .strongS: return "Strong S"
            case .matte: return "Matte"
            case .fade: return "Fade"
            case .invert: return "Invert"
            case .brighten: return "Brighten"
            case .darken: return "Darken"
            case .linear: return "Linear"
            }
        }

        public var frenchName: String {
            switch self {
            case .sCurve: return "Courbe en S"
            case .strongS: return "S marqué"
            case .matte: return "Mat"
            case .fade: return "Délavé"
            case .invert: return "Inverser"
            case .brighten: return "Éclaircir"
            case .darken: return "Assombrir"
            case .linear: return "Linéaire"
            }
        }

        /// The points at `strength` (0…1); `invert` and `linear` ignore it.
        public func points(strength: Double) -> [Point] {
            let s = strength.clamped(to: 0...1)
            switch self {
            case .sCurve: return [Point(0, 0), Point(0.25, 0.25 - 0.12 * s), Point(0.5, 0.5), Point(0.75, 0.75 + 0.12 * s), Point(1, 1)]
            case .strongS: return [Point(0, 0), Point(0.25, 0.25 - 0.22 * s), Point(0.5, 0.5), Point(0.75, 0.75 + 0.22 * s), Point(1, 1)]
            case .matte:
                let lift = 0.2 * s
                return [Point(0, lift), Point(0.25, 0.25 + lift * 0.6), Point(0.5, 0.5 + lift * 0.3), Point(0.75, 0.75), Point(1, 1)]
            case .fade:
                let lift = 0.18 * s
                return [Point(0, lift), Point(0.5, 0.5 + lift * 0.2), Point(1, 1 - lift * 0.6)]
            case .invert: return [Point(0, 1), Point(1, 0)]
            case .brighten: return [Point(0, 0), Point(0.5, 0.5 + 0.2 * s), Point(1, 1)]
            case .darken: return [Point(0, 0), Point(0.5, 0.5 - 0.2 * s), Point(1, 1)]
            case .linear: return ToneCurve.straight
            }
        }
    }
}
