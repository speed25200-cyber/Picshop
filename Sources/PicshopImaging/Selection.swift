import Foundation

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
