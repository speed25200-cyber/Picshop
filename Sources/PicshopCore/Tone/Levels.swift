import Foundation

/// Photoshop-style Levels per channel: input black and white points, gamma, and
/// output black and white points, all in 0…1 (gamma 0.1…9.99), on gamma-encoded
/// values. Each colour channel's levels come first, then the rgb master's.
public struct Levels: Hashable, Codable, Sendable {
    public struct Channel: Hashable, Codable, Sendable {
        public var inBlack: Double, inWhite: Double, gamma: Double, outBlack: Double, outWhite: Double

        public init(inBlack: Double = 0, inWhite: Double = 1, gamma: Double = 1, outBlack: Double = 0, outWhite: Double = 1) {
            self.inBlack = inBlack
            self.inWhite = inWhite
            self.gamma = gamma
            self.outBlack = outBlack
            self.outWhite = outWhite
        }

        public static let identity = Channel()

        public static let gammaRange: ClosedRange<Double> = 0.1...9.99

        /// Changes nothing (within 1/1024 at the handles).
        public var isIdentity: Bool {
            abs(inBlack) <= 1.0 / 1024 && abs(inWhite - 1) <= 1.0 / 1024 && abs(gamma - 1) <= 0.001
                && abs(outBlack) <= 1.0 / 1024 && abs(outWhite - 1) <= 1.0 / 1024
        }

        /// One value through these levels: stretched between the input points (values
        /// outside clip), bent by gamma (above 1 lifts the midtones), then mapped to the
        /// output range (an output black above the output white inverts).
        public func map(_ value: Double) -> Double {
            let black = inBlack.clamped(to: 0...1), white = inWhite.clamped(to: 0...1)
            let span = white - black
            var v: Double
            if span <= 1e-6 {
                // A collapsed range is a threshold at the black point.
                v = value > black ? 1 : 0
            } else {
                v = ((value - black) / span).clamped(to: 0...1)
            }
            let g = gamma.clamped(to: Self.gammaRange)
            if abs(g - 1) > 1e-9, v > 0, v < 1 { v = pow(v, 1 / g) }
            let low = outBlack.clamped(to: 0...1), high = outWhite.clamped(to: 0...1)
            return (low + v * (high - low)).clamped(to: 0...1)
        }
    }

    public var rgb: Channel, red: Channel, green: Channel, blue: Channel

    public init(rgb: Channel = .identity, red: Channel = .identity, green: Channel = .identity, blue: Channel = .identity) {
        self.rgb = rgb
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = Levels()

    public var isIdentity: Bool { rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }

    public subscript(channel: ToneCurve.Channel) -> Channel {
        get {
            switch channel {
            case .rgb: return rgb
            case .red: return red
            case .green: return green
            case .blue: return blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// One value of a colour channel through its own levels, then the rgb master's.
    public func map(_ value: Double, channel: ToneCurve.Channel) -> Double {
        channel == .rgb ? rgb.map(value) : rgb.map(self[channel].map(value))
    }

    /// Adaptive auto levels ("Auto" in Levels, the autoTone operation): tone only, never colour.
    ///
    /// - Black and white points: the darkest and brightest values once `clip` of the pixels
    ///   (0.1 % by default) are let go on each side, taken over R, G and B together so no
    ///   channel clips more than that. Set on the rgb master; the colour channels stay
    ///   identity, so a sunset stays orange.
    /// - A flat picture is stretched at most 4×, around its middle.
    /// - Midtones adapt: gamma moves the luma median halfway toward middle grey (gamma 0.67…1.5).
    /// An empty histogram gives identity.
    public static func auto(from histogram: Histogram, clip: Double = 0.001) -> Levels {
        guard histogram.total > 0 else { return .identity }
        let clip = clip.clamped(to: 0...0.2)
        let channels = [histogram.red, histogram.green, histogram.blue]
        let blacks = channels.map { Histogram.blackPoint(of: $0, clip: clip) }
        let whites = channels.map { Histogram.whitePoint(of: $0, clip: clip) }
        let last = Double(Histogram.binCount - 1)
        var black = Double(blacks.min() ?? 0) / last
        var white = Double(whites.max() ?? Histogram.binCount - 1) / last
        guard white > black else { return .identity }
        // At most a 4× stretch: a fog or a flat wall would otherwise turn to noise.
        if white - black < 0.25 {
            let middle = (black + white) / 2
            black = middle - 0.125
            white = middle + 0.125
            if black < 0 { white -= black; black = 0 }
            if white > 1 { black -= white - 1; white = 1 }
        }
        var master = Channel(inBlack: black, inWhite: white)
        // Midtones: the median luma, once stretched, moves halfway toward 0.5.
        let median = histogram.percentile(0.5, .luma)
        let stretched = ((median - black) / (white - black)).clamped(to: 0.02...0.98)
        let target = (stretched + 0.5) / 2
        let gamma = (log(stretched) / log(target)).clamped(to: 0.67...1.5)
        if abs(gamma - 1) >= 0.03 { master.gamma = (gamma * 100).rounded() / 100 }
        let levels = Levels(rgb: master)
        return levels.isIdentity ? .identity : levels
    }
}
