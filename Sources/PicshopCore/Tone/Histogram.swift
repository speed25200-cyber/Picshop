import Foundation

public enum HistogramChannel: String, Sendable, CaseIterable { case red, green, blue, luma }

/// 256-bin histograms of R, G, B and luma (gamma-encoded values; luma with the
/// Rec. 709 weights). Imaging fills it from a small proxy of the settled frame.
public struct Histogram: Hashable, Sendable {
    public struct Clipping: Hashable, Sendable {
        /// Fractions of the pixels in the two darkest bins (≤ 1/255) and the two brightest
        /// (≥ 254/255), in the channel that clips most.
        public var shadows: Double
        public var highlights: Double

        public init(shadows: Double, highlights: Double) {
            self.shadows = shadows
            self.highlights = highlights
        }

        /// The histogram card's triangles light up past this fraction (0.5 %).
        public static let warningFraction = 0.005
    }

    public static let binCount: Int = 256

    public var red: [UInt32], green: [UInt32], blue: [UInt32], luma: [UInt32]

    public init(red: [UInt32], green: [UInt32], blue: [UInt32], luma: [UInt32]) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luma = luma
    }

    public func bins(_ channel: HistogramChannel) -> [UInt32] {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        case .luma: return luma
        }
    }

    /// Pixels counted (the luma bins' sum).
    public var total: UInt64 { luma.reduce(0) { $0 + UInt64($1) } }

    /// How much of the picture is crushed to black or blown to white, in its worst channel.
    public var clipping: Clipping {
        let count = Double(total)
        guard count > 0 else { return Clipping(shadows: 0, highlights: 0) }
        var shadows = 0.0, highlights = 0.0
        for channel in HistogramChannel.allCases {
            let bins = self.bins(channel)
            guard bins.count >= 4 else { continue }
            shadows = max(shadows, Double(UInt64(bins[0]) + UInt64(bins[1])) / count)
            highlights = max(highlights, Double(UInt64(bins[bins.count - 1]) + UInt64(bins[bins.count - 2])) / count)
        }
        return Clipping(shadows: shadows, highlights: highlights)
    }

    /// The value (0…1) below which `fraction` of the channel's pixels fall: the first bin
    /// where the running count reaches it.
    public func percentile(_ fraction: Double, _ channel: HistogramChannel) -> Double {
        let bins = self.bins(channel)
        let count = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard count > 0, bins.count > 1 else { return 0 }
        let goal = Double(count) * min(max(fraction, 0), 1)
        var running = 0.0
        for (index, value) in bins.enumerated() {
            running += Double(value)
            if running >= goal, running > 0 { return Double(index) / Double(bins.count - 1) }
        }
        return 1
    }

    /// The highest bin that may become black while at most `clip` of the pixels sit at or
    /// below it (0 when the darkest bin alone holds more).
    public static func blackPoint(of bins: [UInt32], clip: Double) -> Int {
        let count = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard count > 0 else { return 0 }
        let allowed = Double(count) * clip
        var running = 0.0
        var point = 0
        for (index, value) in bins.enumerated() {
            running += Double(value)
            guard running <= allowed else { break }
            point = index
        }
        return point
    }

    /// The lowest bin that may become white while at most `clip` of the pixels sit at or above it.
    public static func whitePoint(of bins: [UInt32], clip: Double) -> Int {
        let count = bins.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard count > 0, !bins.isEmpty else { return max(0, bins.count - 1) }
        let allowed = Double(count) * clip
        var running = 0.0
        var point = bins.count - 1
        for index in stride(from: bins.count - 1, through: 0, by: -1) {
            running += Double(bins[index])
            guard running <= allowed else { break }
            point = index
        }
        return point
    }

    /// Counts 8-bit RGBA pixels (alpha ignored); luma uses the Rec. 709 weights.
    public static func compute(rgba: [UInt8], width: Int, height: Int) -> Histogram {
        count(rgba: rgba, width: width, height: height, premultiplied: false)
    }

    /// Counts premultiplied RGBA pixels as a picture readback gives them: transparent pixels
    /// (a cut-out's background) are left out, partly transparent ones unpremultiplied.
    public static func compute(premultipliedRGBA rgba: [UInt8], width: Int, height: Int) -> Histogram {
        count(rgba: rgba, width: width, height: height, premultiplied: true)
    }

    private static func count(rgba: [UInt8], width: Int, height: Int, premultiplied: Bool) -> Histogram {
        var r = [UInt32](repeating: 0, count: binCount)
        var g = r, b = r, y = r
        let pixels = min(max(0, width) * max(0, height), rgba.count / 4)
        rgba.withUnsafeBufferPointer { buffer in
            for index in 0..<pixels {
                let base = index * 4
                var red = Int(buffer[base]), green = Int(buffer[base + 1]), blue = Int(buffer[base + 2])
                if premultiplied {
                    let alpha = Int(buffer[base + 3])
                    if alpha == 0 { continue }
                    if alpha < 255 {
                        red = min(255, (red * 255 + alpha / 2) / alpha)
                        green = min(255, (green * 255 + alpha / 2) / alpha)
                        blue = min(255, (blue * 255 + alpha / 2) / alpha)
                    }
                }
                r[red] += 1
                g[green] += 1
                b[blue] += 1
                let luma = (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)).rounded()
                y[min(255, max(0, Int(luma)))] += 1
            }
        }
        return Histogram(red: r, green: g, blue: b, luma: y)
    }
}
