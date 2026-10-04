import Foundation
import PicshopCore

/// Pixel-precise selection tools that do not need any ML: colour-based
/// magic wand and polygon (lasso) rasterisation. Pure Swift, unit-tested.
public enum Selection {
    /// Contiguous region grown from `seed` (normalised, top-left origin) whose
    /// colours stay within `tolerance` (0…1) of the seed colour. Returns an
    /// 8-bit mask.
    public static func magicWand(rgba: [UInt8], width: Int, height: Int, seed: (x: Double, y: Double), tolerance: Double, contiguous: Bool = true) -> [UInt8] {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return [] }
        let sx = min(width - 1, max(0, Int(seed.x * Double(width))))
        let sy = min(height - 1, max(0, Int(seed.y * Double(height))))
        let si = (sy * width + sx) * 4
        let sr = Int(rgba[si]), sg = Int(rgba[si + 1]), sb = Int(rgba[si + 2])
        // Tolerance maps to a max Euclidean RGB distance (0…441).
        let maxDistance = max(4.0, tolerance.clamped01 * 255 * 1.2)
        let threshold = maxDistance * maxDistance
        func matches(_ i: Int) -> Bool {
            let dr = Double(Int(rgba[i * 4]) - sr), dg = Double(Int(rgba[i * 4 + 1]) - sg), db = Double(Int(rgba[i * 4 + 2]) - sb)
            return dr * dr + dg * dg + db * db <= threshold
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        if !contiguous {
            for i in 0..<(width * height) where matches(i) { mask[i] = 255 }
            return mask
        }
        var stack = [sy * width + sx]
        mask[sy * width + sx] = 255
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbours where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let ni = ny * width + nx
                if mask[ni] == 0, matches(ni) {
                    mask[ni] = 255
                    stack.append(ni)
                }
            }
        }
        return mask
    }

    // MARK: - Lab wand (W2)

    /// The W2 magic wand: pixels whose CIE Lab colour lies within ΔE76 ≤ 2 + 48 × `tolerance` of the seed's,
    /// the seed's colour being the average of a `sampleSize` × `sampleSize` window (1, 3 or 5 pixels). `contiguous`
    /// grows a 4-connected region from the seed; otherwise every matching pixel is taken. With `antiAlias`, the
    /// region's inner boundary pixels get the share of their 3 × 3 neighbourhood that is selected, a one-pixel
    /// soft edge. `rgba` is top-down RGBA8 in gamma sRGB; the result is 8-bit (255 = selected). The RGB `magicWand`
    /// above stays as it was.
    public static func magicWandLab(rgba: [UInt8], width: Int, height: Int, seed: (x: Double, y: Double), tolerance: Double,
                                    contiguous: Bool = true, sampleSize: Int = 1, antiAlias: Bool = true) -> [UInt8] {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return [] }
        let sx = min(width - 1, max(0, Int(seed.x * Double(width))))
        let sy = min(height - 1, max(0, Int(seed.y * Double(height))))
        let reference = averageLab(rgba: rgba, width: width, height: height, x: sx, y: sy, sampleSize: sampleSize)
        let limit = wandThreshold(tolerance: tolerance)
        let limitSquared = limit * limit
        let count = width * height
        // 0 untested, 1 inside, 2 outside: each pixel's colour is converted at most once.
        var state = [UInt8](repeating: 0, count: count)
        func matches(_ index: Int) -> Bool {
            if state[index] == 0 {
                let lab = Lab.of(r: rgba[index * 4], g: rgba[index * 4 + 1], b: rgba[index * 4 + 2])
                let dl = lab.l - reference.l, da = lab.a - reference.a, db = lab.b - reference.b
                state[index] = dl * dl + da * da + db * db <= limitSquared ? 1 : 2
            }
            return state[index] == 1
        }
        var mask = [UInt8](repeating: 0, count: count)
        if contiguous {
            let start = sy * width + sx
            // The seed is in by definition, even when the window's average drifted from its own colour.
            mask[start] = 255
            var stack = [start]
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                if x > 0, mask[index - 1] == 0, matches(index - 1) { mask[index - 1] = 255; stack.append(index - 1) }
                if x < width - 1, mask[index + 1] == 0, matches(index + 1) { mask[index + 1] = 255; stack.append(index + 1) }
                if y > 0, mask[index - width] == 0, matches(index - width) { mask[index - width] = 255; stack.append(index - width) }
                if y < height - 1, mask[index + width] == 0, matches(index + width) { mask[index + width] = 255; stack.append(index + width) }
            }
        } else {
            for index in 0..<count where matches(index) { mask[index] = 255 }
        }
        return antiAlias ? antiAliased(mask, width: width, height: height) : mask
    }

    /// The wand's ΔE76 limit for a tolerance 0…1.
    public static func wandThreshold(tolerance: Double) -> Double {
        2 + 48 * tolerance.clamped01
    }

    /// The mean Lab colour of the `sampleSize` window (1, 3 or 5; clipped at the edges) centred on (x, y).
    public static func averageLab(rgba: [UInt8], width: Int, height: Int, x: Int, y: Int, sampleSize: Int) -> Lab {
        let size = [1, 3, 5].min { abs($0 - sampleSize) < abs($1 - sampleSize) } ?? 1
        let half = size / 2
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for dy in -half...half {
            for dx in -half...half {
                let px = x + dx, py = y + dy
                guard px >= 0, px < width, py >= 0, py < height else { continue }
                let i = (py * width + px) * 4
                r += Double(rgba[i]); g += Double(rgba[i + 1]); b += Double(rgba[i + 2]); n += 1
            }
        }
        guard n > 0 else { return Lab(l: 0, a: 0, b: 0) }
        // The average of the colours (as Photoshop's sample size does), converted once.
        return Lab.of(red: r / n / 255, green: g / n / 255, blue: b / n / 255)
    }

    /// Inner boundary pixels (selected, with an unselected 4-neighbour) take the selected share of their 3 × 3
    /// neighbourhood; everything else keeps 0 or 255.
    static func antiAliased(_ mask: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = mask
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] == 255 {
                let index = y * width + x
                let edge = (x > 0 && mask[index - 1] == 0) || (x < width - 1 && mask[index + 1] == 0)
                    || (y > 0 && mask[index - width] == 0) || (y < height - 1 && mask[index + width] == 0)
                guard edge else { continue }
                var selected = 0, total = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let px = x + dx, py = y + dy
                        guard px >= 0, px < width, py >= 0, py < height else { continue }
                        total += 1
                        if mask[py * width + px] == 255 { selected += 1 }
                    }
                }
                out[index] = UInt8((255 * Double(selected) / Double(max(1, total))).rounded())
            }
        }
        return out
    }

    /// CIE L*a*b* (D65) of gamma-encoded sRGB: Core's `MaskMath.lab` (its 8-bit path is a table lookup, so the wand
    /// converts a 1536-pixel picture in a few tens of milliseconds), so the wand, the colour samples and the colour
    /// ranges all measure colour the same way.
    public struct Lab: Hashable, Sendable {
        public var l: Double
        public var a: Double
        public var b: Double

        public init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }

        init(_ lab: LabColor) {
            self.init(l: lab.l, a: lab.a, b: lab.b)
        }

        public static func of(r: UInt8, g: UInt8, b: UInt8) -> Lab {
            Lab(MaskMath.lab(bytes: r, g, b))
        }

        public static func of(red: Double, green: Double, blue: Double) -> Lab {
            Lab(MaskMath.lab(r: red, g: green, b: blue))
        }

        /// ΔE76 to another colour.
        public func distance(to other: Lab) -> Double {
            let dl = l - other.l, da = a - other.a, db = b - other.b
            return (dl * dl + da * da + db * db).squareRoot()
        }
    }

    /// Scanline fill of a closed polygon given in normalised coordinates.
    public static func lasso(points: [(x: Double, y: Double)], width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard points.count >= 3, width > 0, height > 0 else { return mask }
        let vertices = points.map { (x: $0.x * Double(width), y: $0.y * Double(height)) }
        for y in 0..<height {
            let scan = Double(y) + 0.5
            var crossings: [Double] = []
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i + 1) % vertices.count]
                if (a.y <= scan && b.y > scan) || (b.y <= scan && a.y > scan) {
                    let t = (scan - a.y) / (b.y - a.y)
                    crossings.append(a.x + t * (b.x - a.x))
                }
            }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let x0 = max(0, Int(crossings[i].rounded(.up))), x1 = min(width - 1, Int(crossings[i + 1].rounded(.down)))
                if x1 >= x0 { for x in x0...x1 { mask[y * width + x] = 255 } }
                i += 2
            }
        }
        return mask
    }

    /// Removes speckles smaller than `minimumPixels` (4-connected components).
    public static func despeckled(_ mask: [UInt8], width: Int, height: Int, minimumPixels: Int) -> [UInt8] {
        var result = mask
        var visited = [Bool](repeating: false, count: mask.count)
        for start in 0..<mask.count where mask[start] > 127 && !visited[start] {
            var component = [start]
            var stack = [start]
            visited[start] = true
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < width && ny >= 0 && ny < height {
                    let ni = ny * width + nx
                    if !visited[ni], mask[ni] > 127 { visited[ni] = true; stack.append(ni); component.append(ni) }
                }
            }
            if component.count < minimumPixels {
                for index in component { result[index] = 0 }
            }
        }
        return result
    }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
