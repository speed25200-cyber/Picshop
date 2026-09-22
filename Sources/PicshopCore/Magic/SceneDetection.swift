import Foundation

/// A small fingerprint of one frame: how its colours are spread, and a
/// coarse picture of its light. Two frames of the same shot have close
/// fingerprints even when the camera moves; a cut changes both at once.
public struct FrameSignature: Hashable, Sendable {
    public var time: Double
    /// Joint RGB histogram, 4 × 4 × 4 bins, summing to 1.
    public var histogram: [Float]
    /// Luma on a coarse grid, 0…1.
    public var luma: [Float]

    public init(time: Double, histogram: [Float], luma: [Float]) {
        self.time = time
        self.histogram = histogram
        self.luma = luma
    }

    public static let gridWidth = 16
    public static let gridHeight = 9

    /// Fingerprint of an RGBA8 bitmap (any size; it is read on a coarse grid).
    public static func measure(rgba: [UInt8], width: Int, height: Int, time: Double) -> FrameSignature {
        var histogram = [Float](repeating: 0, count: 64)
        var luma = [Float](repeating: 0, count: gridWidth * gridHeight)
        var counts = [Float](repeating: 0, count: gridWidth * gridHeight)
        guard width > 0, height > 0, rgba.count >= width * height * 4 else {
            return FrameSignature(time: time, histogram: histogram, luma: luma)
        }
        // A coarse sampling is plenty for a fingerprint.
        let step = max(1, min(width, height) / 90)
        var total: Float = 0
        var y = 0
        while y < height {
            var x = 0
            let row = y * width * 4
            let cellY = min(gridHeight - 1, y * gridHeight / height)
            while x < width {
                let index = row + x * 4
                let r = rgba[index], g = rgba[index + 1], b = rgba[index + 2]
                histogram[Int(r >> 6) * 16 + Int(g >> 6) * 4 + Int(b >> 6)] += 1
                let cell = cellY * gridWidth + min(gridWidth - 1, x * gridWidth / width)
                luma[cell] += (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255
                counts[cell] += 1
                total += 1
                x += step
            }
            y += step
        }
        if total > 0 { histogram = histogram.map { $0 / total } }
        for index in luma.indices where counts[index] > 0 { luma[index] /= counts[index] }
        return FrameSignature(time: time, histogram: histogram, luma: luma)
    }

    /// 0 (same picture) … 1 (nothing in common).
    public func distance(to other: FrameSignature) -> Double {
        var histogramDistance: Float = 0
        for index in histogram.indices where index < other.histogram.count {
            histogramDistance += abs(histogram[index] - other.histogram[index])
        }
        var lumaDistance: Float = 0
        for index in luma.indices where index < other.luma.count {
            lumaDistance += abs(luma[index] - other.luma[index])
        }
        let lumaMean = luma.isEmpty ? 0 : lumaDistance / Float(luma.count)
        // Histogram L1 runs 0…2; luma differences rarely pass 0.5 even across cuts.
        return Double(0.5 * (histogramDistance / 2) + 0.5 * min(1, lumaMean * 2.5))
    }
}

/// Finds where one shot ends and the next begins in a stream of frame
/// fingerprints: a jump that stands well above the motion around it.
/// Adaptive, so a handheld street scene is not cut on every step and a
/// slow interview still has its cutaways found.
public enum SceneDetector {
    /// Times (seconds, same clock as the frames) of each cut, at the first frame of the new shot.
    public static func cuts(in frames: [FrameSignature], sensitivity: Double = 0.5, minimumShot: Double = 0.8) -> [Double] {
        guard frames.count > 2 else { return [] }
        let distances = (1..<frames.count).map { frames[$0].distance(to: frames[$0 - 1]) }
        let sensitivity = sensitivity.clamped(to: 0...1)
        let floor = 0.34 - 0.18 * sensitivity
        var cuts: [Double] = []
        for index in distances.indices {
            let value = distances[index]
            guard value >= floor else { continue }
            // A peak, not the shoulder of one.
            let before = index > 0 ? distances[index - 1] : 0
            let after = index + 1 < distances.count ? distances[index + 1] : 0
            guard value >= before, value > after else { continue }
            // Well above the usual frame-to-frame change nearby.
            let window = distances[max(0, index - 12)...min(distances.count - 1, index + 12)]
            let neighbours = window.enumerated().filter { $0.offset + max(0, index - 12) != index }.map(\.element).sorted()
            let median = neighbours.isEmpty ? 0 : neighbours[neighbours.count / 2]
            guard value > median * (3.2 - 1.2 * sensitivity) + 0.05 else { continue }
            let time = frames[index + 1].time
            if let last = cuts.last, time - last < minimumShot { continue }
            if time - frames[0].time < minimumShot * 0.5 || frames[frames.count - 1].time - time < minimumShot * 0.5 { continue }
            cuts.append(time)
        }
        return cuts
    }
}
