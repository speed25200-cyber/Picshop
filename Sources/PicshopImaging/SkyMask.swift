import Foundation
import PicshopCore

/// « Ciel » without a segmentation model (W2, D8, D11): a colour, smoothness and connectivity heuristic over a
/// ≤ 640 px proxy, with foreground instances and far-depth gating, and a guided-filter edge. Pure Swift and
/// Linux-tested; the Vision instances, the depth map and the full-resolution `CIGuidedFilter` edge are added by
/// `VisionPhotoServices` under Core Image.
///
/// The method, in order:
/// 1. every pixel gets a sky-colour score (blue, overcast white or grey, sunset warm or violet) and a texture
///    measure (mean absolute luma gradient over 3 × 3);
/// 2. a region grows from the top rows through smooth, sky-coloured pixels whose colour changes little from one
///    pixel to the next, so gradients (a sunset, a hazy horizon) are followed and hard edges stop it;
/// 3. the horizon is the 90th percentile of the columns' unbroken sky runs from the top: what the region reached
///    far below it through a gap (a lake reflecting the sky beyond a shore line) is dropped, while sky seen through
///    a tree line just above it is kept;
/// 4. small holes close (birds, wires), foreground instances are cut out, and with a depth map anything nearer
///    than the far 35 % fades out;
/// 5. the edge follows the picture (guided filter), then a 0.5 threshold softened to ± 0.1.
///
/// `confidence` is colour agreement × top connectivity × edge contrast. Below `approximateBelow` the result is
/// marked approximate (the UI captions « Ciel approximatif : affine-le au pinceau »).
public enum SkyMask {
    /// The proxy's longest side.
    public static let workingSide = 640
    /// Below this confidence the result is approximate.
    public static let approximateBelow = 0.55
    /// Coverage under which there is no sky (notFound).
    public static let minimumCoverage = 0.01

    public struct Result: Sendable, Equatable {
        /// 8-bit, 255 = sky, row 0 at the top.
        public var mask: [UInt8]
        public var width: Int
        public var height: Int
        /// 0…1: how far the heuristic trusts itself.
        public var confidence: Double
        /// Fraction of pixels above 127.
        public var coverage: Double

        public var isApproximate: Bool { confidence < SkyMask.approximateBelow }
        public var isEmpty: Bool { coverage < SkyMask.minimumCoverage }
    }

    // MARK: - Entry point

    /// The sky of a picture. `rgba` is top-down RGBA8 in gamma sRGB; `foreground` (instances, 255 = an object) and
    /// `depth` (0 far … 1 near) are optional, at the same size. `refineEdge` false leaves the edge to the caller
    /// (the GPU guided filter at full resolution).
    public static func estimate(rgba: [UInt8], width: Int, height: Int, foreground: [UInt8]? = nil, depth: [Float]? = nil,
                                refineEdge: Bool = true) -> Result {
        let count = width * height
        guard width > 2, height > 2, rgba.count >= count * 4 else {
            return Result(mask: [UInt8](repeating: 0, count: max(0, count)), width: max(0, width), height: max(0, height), confidence: 0, coverage: 0)
        }
        let features = Features(rgba: rgba, width: width, height: height)
        var region = grow(features)
        let (horizon, runs) = horizonRow(region, width: width, height: height)
        dropBelowHorizon(&region, runs: runs, horizon: horizon, width: width, height: height)

        var hard = region.map { $0 ? UInt8(255) : 0 }
        hard = RegionMask.closed(hard, width: width, height: height, radius: max(1, min(width, height) / 100))
        if let foreground, foreground.count == count {
            for index in 0..<count where foreground[index] > 127 { hard[index] = 0 }
        }
        let confidence = self.confidence(hard, features: features)

        var soft = hard.map { Float($0) / 255 }
        if let depth, depth.count == count {
            for index in 0..<count {
                let near = Double(depth[index])
                // The far 35 % stays; nearer fades out over 0.30…0.40.
                soft[index] *= Float(1 - smoothstep(0.30, 0.40, near))
            }
        }
        if refineEdge {
            soft = edgeRefined(soft, guide: features.luma, width: width, height: height)
        }
        let mask = soft.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        let covered = mask.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
        return Result(mask: mask, width: width, height: height, confidence: confidence, coverage: Double(covered) / Double(count))
    }

    /// The guided-filter edge (radius 8 px at 1536, ε 1e-3, luma guide) and the softened 0.5 threshold.
    public static func edgeRefined(_ mask: [Float], guide: [Float], width: Int, height: Int) -> [Float] {
        let radius = max(1, Int((8.0 * Double(max(width, height)) / 1536).rounded()))
        let guided = EdgeRefineReference.guidedFilter(input: mask, guide: guide, width: width, height: height, radius: radius, epsilon: 1e-3)
        return guided.map { softThreshold($0) }
    }

    /// The 0.5 threshold softened to ± 0.1.
    public static func softThreshold(_ value: Float) -> Float {
        min(1, max(0, (value - 0.4) / 0.2))
    }

    // MARK: - Features

    struct Features {
        let width: Int
        let height: Int
        let r: [Float]
        let g: [Float]
        let b: [Float]
        let luma: [Float]
        /// Sky-colour score 0…1.
        let score: [Float]
        /// Mean absolute luma gradient over 3 × 3.
        let texture: [Float]

        init(rgba: [UInt8], width: Int, height: Int) {
            self.width = width
            self.height = height
            let count = width * height
            var r = [Float](repeating: 0, count: count), g = r, b = r, luma = r, score = r
            for index in 0..<count {
                let red = Float(rgba[index * 4]) / 255, green = Float(rgba[index * 4 + 1]) / 255, blue = Float(rgba[index * 4 + 2]) / 255
                r[index] = red
                g[index] = green
                b[index] = blue
                luma[index] = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                score[index] = SkyMask.colourScore(r: red, g: green, b: blue)
            }
            var gradient = [Float](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    let left = luma[y * width + max(0, x - 1)], right = luma[y * width + min(width - 1, x + 1)]
                    let up = luma[max(0, y - 1) * width + x], down = luma[min(height - 1, y + 1) * width + x]
                    gradient[y * width + x] = (abs(right - left) + abs(down - up)) * 0.5
                }
            }
            self.r = r
            self.g = g
            self.b = b
            self.luma = luma
            self.score = score
            texture = EdgeRefineReference.boxMean(gradient, width: width, height: height, radius: 1)
        }

        /// The largest channel step between two pixels.
        func step(_ a: Int, _ c: Int) -> Float {
            max(abs(r[a] - r[c]), abs(g[a] - g[c]), abs(b[a] - b[c]))
        }
    }

    /// How sky-like a colour is (gamma sRGB 0…1): blue skies, white or grey overcast and haze, and the warm or
    /// violet hues of a sunset; greens, browns and dark tones score 0.
    public static func colourScore(r: Float, g: Float, b: Float) -> Float {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luma > 0.16 else { return 0 }
        let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
        // Neutral: overcast, clouds, haze; brighter is likelier sky.
        if saturation < 0.16 {
            return luma > 0.5 ? 0.9 : max(0, (luma - 0.3) / 0.2) * 0.9
        }
        let hue = hueDegrees(r: r, g: g, b: b)
        switch hue {
        case 175..<265:
            // Cyan to blue: the classic sky.
            return luma > 0.22 ? 1 : 0.6
        case 265..<345:
            // Violet, magenta, pink: dusk.
            return luma > 0.25 ? 0.8 : 0.3
        case 345..<360, 0..<62:
            // Red, orange, yellow: a sunset, only when bright (bricks and wood are darker).
            return luma > 0.42 ? 0.75 : max(0, (luma - 0.3) / 0.12) * 0.75
        default:
            // Greens and teal: vegetation, water plants.
            return 0
        }
    }

    static func hueDegrees(r: Float, g: Float, b: Float) -> Float {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard delta > 1e-6 else { return 0 }
        var hue: Float
        if maxC == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return hue
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Growing

    /// Smoothness limit (mean absolute luma gradient per pixel at the proxy size).
    static let maximumTexture: Float = 0.035
    /// The largest channel change between neighbouring sky pixels.
    static let maximumStep: Float = 0.045
    static let seedScore: Float = 0.5
    static let growScore: Float = 0.3

    /// The top-connected sky region.
    static func grow(_ f: Features) -> [Bool] {
        let width = f.width, height = f.height
        var region = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        let seedRows = max(1, height / 50)
        for y in 0..<seedRows {
            for x in 0..<width {
                let index = y * width + x
                if f.score[index] >= seedScore, f.texture[index] < maximumTexture, !region[index] {
                    region[index] = true
                    stack.append(index)
                }
            }
        }
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            func visit(_ next: Int) {
                guard !region[next], f.score[next] >= growScore, f.texture[next] < maximumTexture, f.step(index, next) < maximumStep else { return }
                region[next] = true
                stack.append(next)
            }
            if x > 0 { visit(index - 1) }
            if x < width - 1 { visit(index + 1) }
            if y > 0 { visit(index - width) }
            if y < height - 1 { visit(index + width) }
        }
        return region
    }

    /// The horizon row (90th percentile of the unbroken runs of sky from the top, over the columns that start
    /// with sky) and each column's run. Gaps of up to 2 px (a wire) do not break a run.
    static func horizonRow(_ region: [Bool], width: Int, height: Int) -> (horizon: Int, runs: [Int]) {
        var runs = [Int](repeating: 0, count: width)
        for x in 0..<width {
            var y = 0, gap = 0, last = -1
            while y < height {
                if region[y * width + x] {
                    last = y
                    gap = 0
                } else {
                    gap += 1
                    if gap > 2 { break }
                }
                y += 1
            }
            runs[x] = last + 1
        }
        let skyColumns = runs.filter { $0 > 0 }.sorted()
        guard !skyColumns.isEmpty else { return (0, runs) }
        let horizon = skyColumns[min(skyColumns.count - 1, Int(Double(skyColumns.count - 1) * 0.9))]
        return (horizon, runs)
    }

    /// Drops what lies below both its column's run and the horizon (plus 3 % of the height).
    static func dropBelowHorizon(_ region: inout [Bool], runs: [Int], horizon: Int, width: Int, height: Int) {
        let limit = horizon + max(2, height * 3 / 100)
        for x in 0..<width {
            let keep = max(runs[x], limit)
            guard keep < height else { continue }
            for y in keep..<height { region[y * width + x] = false }
        }
    }

    // MARK: - Confidence

    /// colour agreement × top connectivity × edge contrast, each 0…1.
    static func confidence(_ mask: [UInt8], features f: Features) -> Double {
        let parts = confidenceParts(mask, features: f)
        return parts.colour * parts.top * (0.4 + 0.6 * parts.edge)
    }

    /// The three factors of `confidence`.
    static func confidenceParts(_ mask: [UInt8], features f: Features) -> (colour: Double, top: Double, edge: Double) {
        let width = f.width, height = f.height
        var inside = 0, scoreSum = 0.0
        for index in mask.indices where mask[index] > 127 {
            inside += 1
            scoreSum += Double(f.score[index])
        }
        guard inside > 0 else { return (0, 0, 0) }
        let colour = scoreSum / Double(inside)
        // Top connectivity: the share of the top row that is sky, saturating at half the row.
        var topSky = 0
        for x in 0..<width where mask[x] > 127 { topSky += 1 }
        let top = min(1, Double(topSky) / Double(width) * 2)
        // Edge contrast: the share of the region's inner boundary (off the picture's border) where the colour
        // jumps; a boundary that fades is where a heuristic is most likely wrong.
        var boundary = 0, sharp = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                guard mask[index] > 127 else { continue }
                let neighbours = [index - 1, index + 1, index - width, index + width]
                guard let outside = neighbours.first(where: { mask[$0] <= 127 }) else { continue }
                boundary += 1
                // The region stops where the texture rises, a pixel or two before the edge itself: look up to four
                // pixels out for the jump.
                let dx = outside % width - x, dy = outside / width - y
                for k in 1...4 {
                    let px = x + dx * k, py = y + dy * k
                    guard px >= 0, px < width, py >= 0, py < height else { break }
                    let probe = py * width + px
                    if f.step(index, probe) > 0.08 || f.score[probe] < 0.2 {
                        sharp += 1
                        break
                    }
                }
            }
        }
        let edge = boundary == 0 ? 1 : Double(sharp) / Double(boundary)
        return (colour, top, edge)
    }
}
