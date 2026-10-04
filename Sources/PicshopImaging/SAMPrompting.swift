import Foundation
import PicshopCore
import PicshopIntent

/// How taps, boxes and Quick Selection strokes become SAM 2.1 prompts (W2, D9). Pure Swift, Linux-tested.
///
/// The analysis image is stretched to the encoder's 1024 × 1024 input (scaleFill), so a normalised point
/// (top-left origin) maps to the model's pixels by × 1024 on both axes, and back by / 1024. The prompt encoder
/// takes at most 16 points; the mask decoder only accepts 2…15 sparse embeddings (the points plus SAM's padding
/// one), so a request carries at most `maxPrompts` (12): box corners first (labels 2 and 3), then the latest
/// points (1 positive, 0 negative).
public enum SAMPrompting {
    /// The encoder's square input side.
    public static let inputSide = 1024
    /// Points per request, box corners included.
    public static let maxPrompts = 12
    /// Samples taken along one Quick Selection stroke.
    public static let maxSamplesPerStroke = 8
    /// Samples are at least this many brush radii apart…
    public static let spacingInRadii = 1.5
    /// …and at least this fraction of the longest side.
    public static let minimumSpacing = 0.02

    /// SAM's point labels.
    public enum Label: Float, Sendable {
        case negative = 0
        case positive = 1
        case boxTopLeft = 2
        case boxBottomRight = 3
    }

    /// A request's prompt arrays, ready for `points` [1, N, 2] and `labels` [1, N].
    public struct Encoded: Equatable, Sendable {
        /// x0, y0, x1, y1, … in model pixels (0…1024), top-left origin.
        public var coordinates: [Float]
        public var labels: [Float]

        public init(coordinates: [Float], labels: [Float]) {
            self.coordinates = coordinates
            self.labels = labels
        }

        public var count: Int { labels.count }
        public var isEmpty: Bool { labels.isEmpty }
        /// Whether at least one point adds (a box counts as adding).
        public var hasPositive: Bool { labels.contains { $0 != Label.negative.rawValue } }
    }

    // MARK: - Coordinates

    /// A normalised point (top-left origin) in the model's pixels.
    public static func modelPoint(_ point: PSPoint) -> (x: Float, y: Float) {
        let side = Double(inputSide)
        return (Float(point.x.clamped(to: 0...1) * side), Float(point.y.clamped(to: 0...1) * side))
    }

    /// A model pixel back to a normalised point.
    public static func normalised(x: Float, y: Float) -> PSPoint {
        let side = Double(inputSide)
        return PSPoint(x: Double(x) / side, y: Double(y) / side)
    }

    /// Fractions of the longest side spanned by the width and the height of a layer of aspect w/h.
    static func axisShares(aspect: Double) -> (x: Double, y: Double) {
        let ratio = aspect > 0 && aspect.isFinite ? aspect : 1
        return ratio >= 1 ? (1, 1 / ratio) : (ratio, 1)
    }

    /// The distance between two normalised points in longest-side units.
    static func distance(_ a: PSPoint, _ b: PSPoint, shares: (x: Double, y: Double)) -> Double {
        let dx = (b.x - a.x) * shares.x, dy = (b.y - a.y) * shares.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Strokes

    /// The spacing between a stroke's samples: max(1.5 × radius, 2 % of the longest side).
    public static func spacing(radius: Double) -> Double {
        max(spacingInRadii * max(0, radius), minimumSpacing)
    }

    /// Points along a stroke (normalised, top-left), the first point included, each at least `spacing(radius:)` from
    /// the previous one in straight-line distance, at most `maxSamplesPerStroke`. A long stroke spreads its samples
    /// over its whole length rather than bunching them at the start.
    public static func samples(along points: [PSPoint], radius: Double, aspect: Double) -> [PSPoint] {
        guard let first = points.first else { return [] }
        let shares = axisShares(aspect: aspect)
        var length = 0.0
        for index in points.indices.dropFirst() { length += distance(points[index - 1], points[index], shares: shares) }
        // Wider steps on a long stroke, so 8 samples reach its end.
        let step = max(spacing(radius: radius), length / Double(maxSamplesPerStroke - 1))
        var kept = [first]
        // Longest-side units, so the spacing is the same in both directions.
        func scaled(_ p: PSPoint) -> (x: Double, y: Double) { (p.x * shares.x, p.y * shares.y) }
        func unscaled(_ p: (x: Double, y: Double)) -> PSPoint { PSPoint(x: p.x / shares.x, y: p.y / shares.y) }
        var last = scaled(first)
        for index in points.indices.dropFirst() {
            var a = scaled(points[index - 1])
            let b = scaled(points[index])
            // Every place on this segment exactly one step (straight line) from the last sample.
            while hypot(b.x - last.x, b.y - last.y) >= step - 1e-12 {
                let dx = b.x - a.x, dy = b.y - a.y
                let ax = a.x - last.x, ay = a.y - last.y
                let qa = dx * dx + dy * dy
                guard qa > 0 else { break }
                let qb = 2 * (dx * ax + dy * ay), qc = ax * ax + ay * ay - step * step
                let root = max(0, (-qb + max(0, qb * qb - 4 * qa * qc).squareRoot()) / (2 * qa))
                let t = min(1, root)
                let point = (x: a.x + dx * t, y: a.y + dy * t)
                kept.append(unscaled(point))
                if kept.count == maxSamplesPerStroke { return kept }
                last = point
                a = point
            }
        }
        return kept
    }

    /// A stroke's prompts: its samples, positive when painting, negative when erasing.
    public static func prompts(along points: [PSPoint], radius: Double, aspect: Double, erase: Bool) -> [MaskPrompt] {
        samples(along: points, radius: radius, aspect: aspect).map { MaskPrompt($0, positive: !erase) }
    }

    // MARK: - Requests

    /// Box corners first (labels 2, 3), then the latest points (1 or 0), `maxPrompts` in all. An empty or inverted
    /// box is left out.
    public static func encode(_ prompts: [MaskPrompt], box: PSRect? = nil) -> Encoded {
        var coordinates: [Float] = []
        var labels: [Float] = []
        if let box = box?.clampedToUnit(), box.width > 0, box.height > 0 {
            let topLeft = modelPoint(PSPoint(x: box.minX, y: box.minY))
            let bottomRight = modelPoint(PSPoint(x: box.maxX, y: box.maxY))
            coordinates += [topLeft.x, topLeft.y, bottomRight.x, bottomRight.y]
            labels += [Label.boxTopLeft.rawValue, Label.boxBottomRight.rawValue]
        }
        let room = max(0, maxPrompts - labels.count)
        for prompt in prompts.suffix(room) {
            let point = modelPoint(prompt.point)
            coordinates += [point.x, point.y]
            labels.append(prompt.isPositive ? Label.positive.rawValue : Label.negative.rawValue)
        }
        return Encoded(coordinates: coordinates, labels: labels)
    }

    /// Where the decoder's mask must touch: the positive points, else the box centre (normalised).
    public static func anchors(_ prompts: [MaskPrompt], box: PSRect?) -> [PSPoint] {
        var anchors = prompts.filter(\.isPositive).map(\.point)
        if let box, box.width > 0, box.height > 0 { anchors.append(PSPoint(x: box.midX, y: box.midY)) }
        return anchors
    }

    // MARK: - Decoder output

    /// The decoder's best mask: the index of the highest score.
    public static func bestMask(scores: [Float]) -> Int {
        var best = 0
        for index in scores.indices where scores[index] > scores[best] { best = index }
        return best
    }

    /// A `side` × `side` plane of logits (the decoder's 256 × 256 low-resolution mask, for the stretched 1024
    /// input) back at the analysis size: bilinear, non-uniform (the inverse of the stretch), then a sigmoid, as
    /// 8-bit values.
    public static func maskBytes(fromLogits logits: [Float], side: Int, width: Int, height: Int) -> [UInt8] {
        guard side > 0, width > 0, height > 0, logits.count >= side * side else { return [UInt8](repeating: 0, count: max(0, width * height)) }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let sx = Double(side) / Double(width), sy = Double(side) / Double(height)
        for y in 0..<height {
            let fy = min(Double(side - 1), max(0, (Double(y) + 0.5) * sy - 0.5))
            let y0 = Int(fy), y1 = min(side - 1, y0 + 1)
            let ty = Float(fy - Double(y0))
            for x in 0..<width {
                let fx = min(Double(side - 1), max(0, (Double(x) + 0.5) * sx - 0.5))
                let x0 = Int(fx), x1 = min(side - 1, x0 + 1)
                let tx = Float(fx - Double(x0))
                let top = logits[y0 * side + x0] * (1 - tx) + logits[y0 * side + x1] * tx
                let bottom = logits[y1 * side + x0] * (1 - tx) + logits[y1 * side + x1] * tx
                let logit = top * (1 - ty) + bottom * ty
                let probability = 1 / (1 + exp(-Double(logit)))
                bytes[y * width + x] = UInt8((probability * 255).rounded())
            }
        }
        return bytes
    }

    /// The decoder's mask cleaned: specks under 0.05 % of the picture go, then only the regions (4-connected,
    /// above 127) that touch an anchor (a positive point or the box centre, within `tolerance` pixels) stay. When no
    /// region touches one (an anchor on a hole), every region whose centre lies in the box stays, else all of them.
    public static func cleaned(_ bytes: [UInt8], width: Int, height: Int, anchors: [PSPoint], box: PSRect?, tolerance: Int = 3) -> [UInt8] {
        let count = width * height
        guard width > 0, height > 0, bytes.count >= count else { return bytes }
        var labels = [Int32](repeating: 0, count: count)
        var areas: [Int32: Int] = [:]
        var boxes: [Int32: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<count where bytes[start] > 127 && labels[start] == 0 {
            next += 1
            let label = next
            labels[start] = label
            stack.append(start)
            var area = 0
            var bounds = (minX: width, minY: height, maxX: -1, maxY: -1)
            while let index = stack.popLast() {
                area += 1
                let x = index % width, y = index / width
                bounds = (min(bounds.minX, x), min(bounds.minY, y), max(bounds.maxX, x), max(bounds.maxY, y))
                if x > 0, labels[index - 1] == 0, bytes[index - 1] > 127 { labels[index - 1] = label; stack.append(index - 1) }
                if x < width - 1, labels[index + 1] == 0, bytes[index + 1] > 127 { labels[index + 1] = label; stack.append(index + 1) }
                if y > 0, labels[index - width] == 0, bytes[index - width] > 127 { labels[index - width] = label; stack.append(index - width) }
                if y < height - 1, labels[index + width] == 0, bytes[index + width] > 127 { labels[index + width] = label; stack.append(index + width) }
            }
            areas[label] = area
            boxes[label] = bounds
        }
        let minimum = max(1, Int(Double(count) * 0.0005))
        let large = Set(areas.filter { $0.value >= minimum }.map(\.key))
        var keep: Set<Int32> = []
        for anchor in anchors {
            let ax = Int(anchor.x * Double(width)), ay = Int(anchor.y * Double(height))
            for dy in -tolerance...tolerance {
                for dx in -tolerance...tolerance {
                    let x = ax + dx, y = ay + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let label = labels[y * width + x]
                    if label != 0, large.contains(label) { keep.insert(label) }
                }
            }
        }
        if keep.isEmpty, let box {
            for label in large {
                guard let b = boxes[label] else { continue }
                let centre = PSPoint(x: (Double(b.minX + b.maxX) / 2 + 0.5) / Double(width), y: (Double(b.minY + b.maxY) / 2 + 0.5) / Double(height))
                if box.contains(centre) { keep.insert(label) }
            }
        }
        if keep.isEmpty { keep = large }
        // Soft edge pixels (≤ 127) next to a kept region stay; the rest of the picture is cleared.
        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            let label = labels[index]
            if label != 0 {
                if keep.contains(label) { out[index] = bytes[index] }
                continue
            }
            guard bytes[index] > 0 else { continue }
            let x = index % width, y = index / width
            var near = false
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1), (x - 2, y), (x + 2, y), (x, y - 2), (x, y + 2)]
            where nx >= 0 && nx < width && ny >= 0 && ny < height {
                if keep.contains(labels[ny * width + nx]) { near = true; break }
            }
            if near { out[index] = bytes[index] }
        }
        return out
    }
}
