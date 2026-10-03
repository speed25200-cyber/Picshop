import Foundation

/// Levels and the user curves baked into one 1D table per channel, applied in a
/// gamma-encoded space (ToneRenderer, one CIColorCurves pass).
public struct ToneLUT: Hashable, Sendable {
    public var red: [Float], green: [Float], blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// For each colour channel: its levels, then the rgb levels, then its own curve, then
    /// the rgb master curve. `count` entries sample 0…1 evenly.
    public static func make(levels: Levels, curve: ToneCurve, count: Int = 256) -> ToneLUT {
        let count = max(2, count)
        let master = CurveSpline.Prepared(curve.rgb)
        func table(_ channel: ToneCurve.Channel) -> [Float] {
            let own = CurveSpline.Prepared(curve.points(channel))
            return (0..<count).map { index in
                let x = Double(index) / Double(count - 1)
                return Float(master.value(at: own.value(at: levels.map(x, channel: channel))))
            }
        }
        return ToneLUT(red: table(.red), green: table(.green), blue: table(.blue))
    }

    /// Every entry within 1/1024 of the identity ramp.
    public var isIdentity: Bool {
        [red, green, blue].allSatisfy { table in
            let ramp = Self.identityRamp(table.count)
            return zip(table, ramp).allSatisfy { abs($0 - $1) <= 1.0 / 1024 }
        }
    }

    /// The table as CIColorCurves reads it: interleaved r, g, b floats, one triple per entry.
    public var interleaved: [Float] {
        let count = min(red.count, green.count, blue.count)
        var values = [Float](repeating: 0, count: count * 3)
        for index in 0..<count {
            values[index * 3] = red[index]
            values[index * 3 + 1] = green[index]
            values[index * 3 + 2] = blue[index]
        }
        return values
    }

    /// One value of a channel through the table, linearly interpolated (what the GPU does).
    public func value(_ x: Double, channel: ToneCurve.Channel) -> Double {
        let table: [Float]
        switch channel {
        case .red: table = red
        case .green: table = green
        case .blue: table = blue
        case .rgb: table = green
        }
        guard table.count > 1 else { return table.first.map(Double.init) ?? x }
        let position = x.clamped(to: 0...1) * Double(table.count - 1)
        let lower = Int(position.rounded(.down)), upper = min(table.count - 1, lower + 1)
        let t = position - Double(lower)
        return Double(table[lower]) * (1 - t) + Double(table[upper]) * t
    }

    static func identityRamp(_ count: Int) -> [Float] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        return (0..<count).map { Float($0) / Float(count - 1) }
    }
}
