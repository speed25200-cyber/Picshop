import Foundation
import PicshopCore

/// Quick Selection without SAM (W2, D8): a Lab wand at every `SAMPrompting` sample of the stroke, each result
/// clipped to a disk of 4 × the brush radius around its sample, unioned (painting) or subtracted (erasing).
/// Pure Swift, Linux-tested; the caller adds the guided-filter edge under Core Image and marks the result
/// approximate (`usedModel = false`).
public enum QuickSelectFallback {
    /// The wand's tolerance (ΔE76 ≤ 2 + 48 × 0.18 ≈ 10.6).
    public static let tolerance = 0.18
    /// Each sample's colour is the mean of a 3 × 3 window.
    public static let sampleSize = 3
    /// Each sample's region is clipped to a disk of this many brush radii.
    public static let reachInRadii = 4.0

    /// The selection after one stroke. `points` are normalised (top-left), `radius` a fraction of the longest side,
    /// `rgba` top-down RGBA8 in gamma sRGB at `width` × `height`, `base` the selection so far (nil: none) at the
    /// same size. Painting raises the selection to what the stroke found; erasing lowers it.
    public static func stroke(rgba: [UInt8], width: Int, height: Int, points: [PSPoint], radius: Double, erase: Bool,
                              base: [UInt8]?) -> [UInt8] {
        let count = width * height
        var result = base.flatMap { $0.count == count ? $0 : nil } ?? [UInt8](repeating: 0, count: count)
        guard width > 0, height > 0, rgba.count >= count * 4, !points.isEmpty else { return result }
        let found = region(rgba: rgba, width: width, height: height, points: points, radius: radius)
        for index in 0..<count where found[index] > 0 {
            result[index] = erase ? min(result[index], 255 - found[index]) : max(result[index], found[index])
        }
        return result
    }

    /// What a stroke reaches: the union of the clipped wand regions of its samples.
    public static func region(rgba: [UInt8], width: Int, height: Int, points: [PSPoint], radius: Double) -> [UInt8] {
        let count = width * height
        var union = [UInt8](repeating: 0, count: count)
        guard width > 0, height > 0, rgba.count >= count * 4 else { return union }
        let aspect = Double(width) / Double(height)
        let samples = SAMPrompting.samples(along: points, radius: radius, aspect: aspect)
        let longest = Double(max(width, height))
        let reach = max(2, reachInRadii * max(0, radius) * longest)
        let reachSquared = reach * reach
        for sample in samples {
            let cx = sample.x * Double(width), cy = sample.y * Double(height)
            let x0 = max(0, Int((cx - reach).rounded(.down))), x1 = min(width - 1, Int((cx + reach).rounded(.up)))
            let y0 = max(0, Int((cy - reach).rounded(.down))), y1 = min(height - 1, Int((cy + reach).rounded(.up)))
            guard x0 <= x1, y0 <= y1 else { continue }
            // The wand runs on the disk's bounding box only: a uniform background is not flooded end to end for
            // a region that is clipped to the disk anyway.
            let cropWidth = x1 - x0 + 1, cropHeight = y1 - y0 + 1
            var crop = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
            for y in 0..<cropHeight {
                let source = ((y0 + y) * width + x0) * 4
                crop.replaceSubrange((y * cropWidth * 4)..<((y + 1) * cropWidth * 4), with: rgba[source..<(source + cropWidth * 4)])
            }
            let seed = ((cx - Double(x0)) / Double(cropWidth), (cy - Double(y0)) / Double(cropHeight))
            let wand = Selection.magicWandLab(rgba: crop, width: cropWidth, height: cropHeight, seed: seed, tolerance: tolerance,
                                              contiguous: true, sampleSize: sampleSize, antiAlias: true)
            guard wand.count == cropWidth * cropHeight else { continue }
            for y in 0..<cropHeight {
                let dy = Double(y0 + y) + 0.5 - cy
                for x in 0..<cropWidth {
                    let dx = Double(x0 + x) + 0.5 - cx
                    guard dx * dx + dy * dy <= reachSquared else { continue }
                    let value = wand[y * cropWidth + x]
                    let index = (y0 + y) * width + (x0 + x)
                    if value > union[index] { union[index] = value }
                }
            }
        }
        return union
    }
}
