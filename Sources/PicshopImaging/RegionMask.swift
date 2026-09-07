import Foundation

/// Heuristic masks for large uniform regions that instance segmentation does
/// not return ("the sky", "the grass", "the water"). Pure Swift so it is
/// unit-tested everywhere; the grounder runs it on a downsampled frame.
public enum RegionMask {
    public enum Kind: String, Sendable {
        case sky, grass, water
    }

    /// Returns an 8-bit mask (255 = region) for the given kind.
    public static func mask(kind: Kind, rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return [] }
        var candidate = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(rgba[i]) / 255, g = Double(rgba[i + 1]) / 255, b = Double(rgba[i + 2]) / 255
                candidate[y * width + x] = matches(kind, r: r, g: g, b: b, relativeY: Double(y) / Double(height))
            }
        }
        // Keep only components attached to the expected border (sky: top, grass/water: bottom) —
        // this rejects blue shirts in the middle of the frame or a green car.
        let seedRows: [Int] = kind == .sky ? [0, 1, 2] : [height - 1, height - 2, height - 3]
        var region = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for row in seedRows where row >= 0 && row < height {
            for x in 0..<width where candidate[row * width + x] {
                let index = row * width + x
                if !region[index] { region[index] = true; stack.append(index) }
            }
        }
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbours where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let ni = ny * width + nx
                if candidate[ni], !region[ni] {
                    region[ni] = true
                    stack.append(ni)
                }
            }
        }
        // Fill small holes (clouds, ripples) with a closing pass.
        var bytes = region.map { $0 ? UInt8(255) : 0 }
        let radius = max(1, min(width, height) / 100)
        bytes = closed(bytes, width: width, height: height, radius: radius)
        return bytes
    }

    static func matches(_ kind: Kind, r: Double, g: Double, b: Double, relativeY: Double) -> Bool {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
        switch kind {
        case .sky:
            guard relativeY < 0.85 else { return false }
            let blueish = b >= r * 1.05 && b >= g * 0.92 && luma > 0.28
            let overcast = saturation < 0.12 && luma > 0.62
            let sunset = r > 0.55 && g > 0.3 && b < r && saturation > 0.2 && luma > 0.4 && relativeY < 0.5
            return blueish || overcast || sunset
        case .grass:
            guard relativeY > 0.2 else { return false }
            return g >= r * 1.08 && g >= b * 1.15 && luma > 0.1 && luma < 0.85
        case .water:
            guard relativeY > 0.25 else { return false }
            return b >= r * 1.1 && (b >= g * 0.9) && luma > 0.12 && saturation > 0.08
        }
    }

    /// Morphological closing (dilate then erode) on an 8-bit mask.
    static func closed(_ input: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        func filter(_ source: [UInt8], _ op: (UInt8, UInt8) -> UInt8, initial: UInt8) -> [UInt8] {
            var horizontal = source
            for y in 0..<height {
                for x in 0..<width {
                    var value = initial
                    for k in max(0, x - radius)...min(width - 1, x + radius) { value = op(value, source[y * width + k]) }
                    horizontal[y * width + x] = value
                }
            }
            var out = horizontal
            for x in 0..<width {
                for y in 0..<height {
                    var value = initial
                    for k in max(0, y - radius)...min(height - 1, y + radius) { value = op(value, horizontal[k * width + x]) }
                    out[y * width + x] = value
                }
            }
            return out
        }
        let dilated = filter(input, { max($0, $1) }, initial: 0)
        return filter(dilated, { min($0, $1) }, initial: 255)
    }

    /// Fraction of the frame covered by the mask.
    public static func coverage(_ mask: [UInt8]) -> Double {
        guard !mask.isEmpty else { return 0 }
        return Double(mask.filter { $0 > 127 }.count) / Double(mask.count)
    }

    /// Normalised bounding box (top-left origin) of the mask.
    public static func boundingBox(_ mask: [UInt8], width: Int, height: Int) -> (x: Double, y: Double, w: Double, h: Double)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return (Double(minX) / Double(width), Double(minY) / Double(height), Double(maxX - minX + 1) / Double(width), Double(maxY - minY + 1) / Double(height))
    }
}
