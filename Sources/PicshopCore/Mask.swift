import Foundation

/// One stroke painted by the user on a mask. Points are normalised to the
/// layer's image space so masks survive resolution changes.
public struct BrushStroke: Hashable, Codable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case add
        case subtract
    }

    public var id: UUID
    public var points: [PSPoint]
    /// Radius as a fraction of the image's longest side.
    public var radius: Double
    /// 0 = fully soft edge, 1 = hard edge.
    public var hardness: Double
    public var mode: Mode

    public init(id: UUID = UUID(), points: [PSPoint], radius: Double, hardness: Double = 0.6, mode: Mode = .add) {
        self.id = id
        self.points = points
        self.radius = radius
        self.hardness = hardness
        self.mode = mode
    }
}

/// Describes how a mask was produced. Kept alongside the rasterised mask so the
/// app can re-generate it at a different resolution or explain it in the UI.
public enum MaskSource: Hashable, Codable, Sendable {
    /// Segmented from a natural-language target ("the dog on the left").
    case object(label: String, boundingBox: PSRect)
    /// Salient subject/foreground.
    case subject
    /// Inverse of the subject.
    case background
    /// People (person segmentation).
    case people
    /// Sky region.
    case sky
    /// Hand-painted.
    case brush
    /// Rectangular region in normalised coordinates.
    case rectangle(PSRect)
    /// Tapped point seed in normalised coordinates.
    case point(PSPoint)
    /// Contiguous colour region grown from a point (tolerance 0…1).
    case magicWand(PSPoint, tolerance: Double)
    /// Free-form polygon in normalised coordinates.
    case lasso([PSPoint])
    /// Named region ("sky", "grass"…).
    case region(String)
}

/// Reference to a rasterised mask stored in the project bundle.
public struct MaskReference: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Path relative to the project bundle, e.g. `masks/<uuid>.png`.
    public var relativePath: String
    public var source: MaskSource
    /// Bounding box of the non-zero region, normalised (0...1). Lets the
    /// renderer restrict expensive work (inpainting) to a crop.
    public var boundingBox: PSRect
    /// Brush strokes that produced or refined the mask, if any.
    public var strokes: [BrushStroke]
    public var feather: Double
    public var isInverted: Bool

    public init(id: UUID = UUID(), relativePath: String? = nil, source: MaskSource, boundingBox: PSRect = .unit,
                strokes: [BrushStroke] = [], feather: Double = 0.02, isInverted: Bool = false) {
        self.id = id
        self.relativePath = relativePath ?? "masks/\(id.uuidString).png"
        self.source = source
        self.boundingBox = boundingBox
        self.strokes = strokes
        self.feather = feather
        self.isInverted = isInverted
    }

    public var displayName: String {
        switch source {
        case .object(let label, _): return label.capitalized
        case .subject: return "Subject"
        case .background: return "Background"
        case .people: return "People"
        case .sky: return "Sky"
        case .brush: return "Brush"
        case .rectangle: return "Rectangle"
        case .point: return "Selection"
        case .magicWand: return "Magic Wand"
        case .lasso: return "Lasso"
        case .region(let name): return name.capitalized
        }
    }
}

/// Draws brush strokes into an 8-bit mask (255 = selected, row 0 at the top), honouring
/// hardness: full inside `hardness × radius`, a smoothstep falloff out to the radius. A hard
/// brush (falloff under a pixel) gets a one-pixel anti-aliased edge instead. Strokes are
/// round-capped polylines; `add` raises the mask to the brush, `subtract` lowers it.
/// Pure Swift, so the edge profile is tested on Linux; MaskStore and the renderer use it.
public enum BrushRaster {
    /// Coverage (0…1) at distance `d` pixels from the stroke's spine.
    public static func coverage(distance d: Double, radius r: Double, hardness: Double) -> Double {
        let inner = r * hardness.clamped(to: 0...1)
        if r - inner < 1 {
            return (r + 0.5 - d).clamped(to: 0...1)
        }
        if d <= inner { return 1 }
        if d >= r { return 0 }
        let t = (r - d) / (r - inner)
        return t * t * (3 - 2 * t)
    }

    public static func draw(_ strokes: [BrushStroke], width: Int, height: Int, into bytes: inout [UInt8]) {
        for stroke in strokes { draw(stroke, width: width, height: height, into: &bytes) }
    }

    public static func draw(_ stroke: BrushStroke, width: Int, height: Int, into bytes: inout [UInt8]) {
        guard width > 0, height > 0, bytes.count >= width * height, !stroke.points.isEmpty else { return }
        let radius = stroke.radius * Double(max(width, height))
        guard radius > 0 else { return }
        // Pixel space, top-left origin; a lone point is a segment of length zero (a dot).
        let xs = stroke.points.map { $0.x * Double(width) }, ys = stroke.points.map { $0.y * Double(height) }
        let segmentCount = max(1, xs.count - 1)
        let subtract = stroke.mode == .subtract
        let hardness = stroke.hardness
        let reach = radius + 1
        bytes.withUnsafeMutableBufferPointer { buffer in
            for segment in 0..<segmentCount {
                let next = min(segment + 1, xs.count - 1)
                let ax = xs[segment], ay = ys[segment], bx = xs[next], by = ys[next]
                let minX = max(0, Int((min(ax, bx) - reach).rounded(.down)))
                let maxX = min(width - 1, Int((max(ax, bx) + reach).rounded(.up)))
                let minY = max(0, Int((min(ay, by) - reach).rounded(.down)))
                let maxY = min(height - 1, Int((max(ay, by) + reach).rounded(.up)))
                guard minX <= maxX, minY <= maxY else { continue }
                let dx = bx - ax, dy = by - ay
                let lengthSquared = dx * dx + dy * dy
                let reachSquared = reach * reach
                for y in minY...maxY {
                    let py = Double(y) + 0.5
                    let row = y * width
                    for x in minX...maxX {
                        let px = Double(x) + 0.5
                        var t = 0.0
                        if lengthSquared > 0 {
                            t = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamped(to: 0...1)
                        }
                        let ex = px - (ax + t * dx), ey = py - (ay + t * dy)
                        let distanceSquared = ex * ex + ey * ey
                        guard distanceSquared < reachSquared else { continue }
                        let value = coverage(distance: distanceSquared.squareRoot(), radius: radius, hardness: hardness)
                        guard value > 0 else { continue }
                        let level = UInt8((value * 255).rounded())
                        if subtract {
                            buffer[row + x] = min(buffer[row + x], 255 - level)
                        } else {
                            buffer[row + x] = max(buffer[row + x], level)
                        }
                    }
                }
            }
        }
    }
}

/// Stroke masks kept between renders (clone, paint, heal): a stroke list drawn once per size is
/// served again without drawing, and a list that extends one already drawn copies it and draws
/// only the new strokes. Least recently used out first past `byteLimit`.
public struct StrokeRasterCache: Sendable {
    private struct Entry: Sendable {
        let strokes: [BrushStroke]
        let width: Int
        let height: Int
        let bytes: [UInt8]
        var lastUse: Int
    }

    private var entries: [String: Entry] = [:]
    private var tick = 0
    private var bytesHeld = 0
    public let byteLimit: Int
    /// Strokes drawn since the cache was made: a hit draws none, an extended list only its new ones.
    public private(set) var strokesDrawn = 0

    public init(byteLimit: Int = 48 * 1_048_576) {
        self.byteLimit = byteLimit
    }

    public var keys: Set<String> { Set(entries.keys) }
    public var count: Int { entries.count }

    public static func key(for strokes: [BrushStroke], width: Int, height: Int) -> String {
        var hasher = Hasher()
        hasher.combine(strokes)
        return "strokes-\(strokes.count)-\(hasher.finalize())@\(width)x\(height)"
    }

    /// The mask of `strokes` at `width` × `height`, and whether it was drawn just now.
    public mutating func mask(for strokes: [BrushStroke], width: Int, height: Int) -> (key: String, bytes: [UInt8], isNew: Bool) {
        tick += 1
        let key = Self.key(for: strokes, width: width, height: height)
        if var entry = entries[key], entry.strokes == strokes, entry.width == width, entry.height == height {
            entry.lastUse = tick
            entries[key] = entry
            return (key, entry.bytes, false)
        }
        // The longest list already drawn at this size that this one continues.
        let base = entries.values
            .filter { $0.width == width && $0.height == height && $0.strokes.count < strokes.count && strokes.starts(with: $0.strokes) }
            .max { $0.strokes.count < $1.strokes.count }
        var bytes = base?.bytes ?? [UInt8](repeating: 0, count: max(0, width * height))
        let fresh = strokes.dropFirst(base?.strokes.count ?? 0)
        BrushRaster.draw(Array(fresh), width: width, height: height, into: &bytes)
        strokesDrawn += fresh.count
        if let old = entries[key] { bytesHeld -= old.bytes.count }
        entries[key] = Entry(strokes: strokes, width: width, height: height, bytes: bytes, lastUse: tick)
        bytesHeld += bytes.count
        evict(keeping: key)
        return (key, bytes, true)
    }

    public mutating func removeAll() {
        entries.removeAll()
        bytesHeld = 0
    }

    private mutating func evict(keeping key: String) {
        guard bytesHeld > byteLimit else { return }
        for (old, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where old != key {
            guard bytesHeld > byteLimit else { break }
            entries[old] = nil
            bytesHeld -= entry.bytes.count
        }
    }
}
