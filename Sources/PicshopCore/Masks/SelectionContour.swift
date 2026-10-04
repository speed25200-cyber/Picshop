import Foundation

/// The selection's outline for the marching ants (W2, M3): marching squares at a threshold, then Douglas–Peucker.
///
/// Paths are closed (the first point is not repeated at the end) and in the raster's pixel space: x 0…width,
/// y 0…height, row 0 at the top, pixel centres at (i + 0.5, j + 0.5). Each path keeps the inside on its left as it
/// is walked in that y-down space, so outer outlines and holes turn opposite ways and an even-odd fill of all of
/// them is the selection. The raster is read as if surrounded by an unselected border, so every path closes.
///
/// Off the main thread: a 1536 × 1152 selection is about two million cells, a few milliseconds. What is drawn
/// every frame goes through the bounded `paths(_:threshold:tolerance:minimumExtent:maximumPoints:)`.
public enum SelectionContour {
    /// The outlines of the pixels at or above `threshold`, simplified to `tolerance` pixels.
    public static func paths(_ raster: GrayRaster, threshold: UInt8 = 128, tolerance: Double = 0.75) -> [[PSPoint]] {
        guard raster.isValid else { return [] }
        let rings = trace(raster, threshold: threshold)
        let epsilon = tolerance.isFinite ? max(0, tolerance) : 0
        return rings.compactMap { ring in
            let simplified = simplifyClosed(ring, tolerance: epsilon)
            return simplified.count >= 3 ? simplified : nil
        }
    }

    /// The outlines bounded for drawing every frame (the marching ants): outlines under `minimumExtent` pixels
    /// across are dropped (a colour range's speckle), the tolerance doubles (up to 16 px) while the total is over
    /// `maximumPoints`, the largest outline is always kept and the others, largest first, while they fit; an
    /// outline over the budget on its own keeps every k-th point.
    public static func paths(_ raster: GrayRaster, threshold: UInt8 = 128, tolerance: Double = 0.75, minimumExtent: Double,
                             maximumPoints: Int) -> [[PSPoint]] {
        guard raster.isValid, maximumPoints >= 3 else { return [] }
        let rings = trace(raster, threshold: threshold).filter { extent(of: $0) >= minimumExtent }
        guard !rings.isEmpty else { return [] }
        var epsilon = tolerance.isFinite ? max(0, tolerance) : 0
        func simplified(_ epsilon: Double) -> [[PSPoint]] {
            rings.compactMap { ring in
                let simple = simplifyClosed(ring, tolerance: epsilon)
                return simple.count >= 3 ? simple : nil
            }
        }
        var outlines = simplified(epsilon)
        while outlines.reduce(0, { $0 + $1.count }) > maximumPoints, epsilon < 16 {
            epsilon = epsilon > 0 ? epsilon * 2 : 1
            outlines = simplified(epsilon)
        }
        var kept: [[PSPoint]] = []
        var total = 0
        for (index, outline) in outlines.enumerated() {
            if index == 0 {
                var largest = outline
                if largest.count > maximumPoints {
                    let step = Int((Double(largest.count) / Double(maximumPoints)).rounded(.up))
                    largest = stride(from: 0, to: largest.count, by: step).map { largest[$0] }
                }
                kept.append(largest)
                total += largest.count
            } else if total + outline.count <= maximumPoints {
                kept.append(outline)
                total += outline.count
            }
        }
        return kept
    }

    /// The larger side of a ring's bounding box, in pixels.
    static func extent(of ring: [PSPoint]) -> Double {
        guard let first = ring.first else { return 0 }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in ring {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return max(maxX - minX, maxY - minY)
    }

    /// Paths in pixel space as normalised points of the raster (0…1, top-left origin).
    public static func normalized(_ paths: [[PSPoint]], width: Int, height: Int) -> [[PSPoint]] {
        guard width > 0, height > 0 else { return [] }
        let w = Double(width), h = Double(height)
        return paths.map { path in path.map { PSPoint(x: $0.x / w, y: $0.y / h) } }
    }

    /// The signed area of a closed path (positive: counter-clockwise in a y-up frame, so clockwise on screen).
    public static func signedArea(_ path: [PSPoint]) -> Double {
        guard path.count >= 3 else { return 0 }
        var twice = 0.0
        for index in path.indices {
            let a = path[index], b = path[(index + 1) % path.count]
            twice += a.x * b.y - b.x * a.y
        }
        return twice / 2
    }

    // MARK: - Marching squares

    /// Closed rings of crossing points, one per outline, unsimplified.
    static func trace(_ raster: GrayRaster, threshold: UInt8) -> [[PSPoint]] {
        let width = raster.width, height = raster.height
        // Samples on a padded grid: (i, j) for i in 0...width + 1, j in 0...height + 1, the border unselected.
        // Sample (i, j) is pixel (i − 1, j − 1), at (i − 0.5, j − 0.5) in pixel space.
        let columns = width + 2, rows = height + 2
        let iso = Double(threshold) - 0.5
        let bytes = raster.bytes
        @inline(__always) func value(_ i: Int, _ j: Int) -> Double {
            guard i >= 1, i <= width, j >= 1, j <= height else { return 0 }
            return Double(bytes[(j - 1) * width + (i - 1)])
        }
        @inline(__always) func inside(_ i: Int, _ j: Int) -> Bool { value(i, j) > iso }
        // Edge ids: horizontal edge (i, j)–(i + 1, j) is 2·(j·columns + i); vertical (i, j)–(i, j + 1) is that + 1.
        @inline(__always) func horizontal(_ i: Int, _ j: Int) -> Int { 2 * (j * columns + i) }
        @inline(__always) func vertical(_ i: Int, _ j: Int) -> Int { 2 * (j * columns + i) + 1 }
        func point(on edge: Int) -> PSPoint {
            let cell = edge / 2
            let i = cell % columns, j = cell / columns
            let isVertical = edge % 2 == 1
            let (i1, j1) = isVertical ? (i, j + 1) : (i + 1, j)
            let v0 = value(i, j), v1 = value(i1, j1)
            let t = v1 != v0 ? ((iso - v0) / (v1 - v0)).clamped(to: 0...1) : 0.5
            let x0 = Double(i) - 0.5, y0 = Double(j) - 0.5
            return isVertical ? PSPoint(x: x0, y: y0 + t) : PSPoint(x: x0 + t, y: y0)
        }

        // Directed segments: next[start edge] = end edge, inside on the left of start → end (y down).
        var next: [Int: Int] = [:]
        func add(_ from: Int, _ to: Int, inside reference: PSPoint) {
            let a = point(on: from), b = point(on: to)
            let dx = b.x - a.x, dy = b.y - a.y
            // Left of travel in y-down space is (dy, −dx).
            let side = dy * (reference.x - a.x) - dx * (reference.y - a.y)
            if side >= 0 { next[from] = to } else { next[to] = from }
        }

        // Only rows and columns that can hold a crossing: skip the all-outside border quickly per cell.
        for j in 0..<(rows - 1) {
            for i in 0..<(columns - 1) {
                let a = inside(i, j), b = inside(i + 1, j), c = inside(i + 1, j + 1), d = inside(i, j + 1)
                let code = (a ? 8 : 0) | (b ? 4 : 0) | (c ? 2 : 0) | (d ? 1 : 0)
                guard code != 0, code != 15 else { continue }
                let top = horizontal(i, j), bottom = horizontal(i, j + 1)
                let left = vertical(i, j), right = vertical(i + 1, j)
                // Corner positions in pixel space.
                let pa = PSPoint(x: Double(i) - 0.5, y: Double(j) - 0.5), pb = PSPoint(x: Double(i) + 0.5, y: Double(j) - 0.5)
                let pc = PSPoint(x: Double(i) + 0.5, y: Double(j) + 0.5), pd = PSPoint(x: Double(i) - 0.5, y: Double(j) + 0.5)
                let middle = PSPoint(x: Double(i), y: Double(j))
                switch code {
                // One corner differs from the other three: the segment cuts that corner off.
                case 8, 7: add(left, top, inside: a ? pa : pc)
                case 4, 11: add(top, right, inside: b ? pb : pd)
                case 2, 13: add(right, bottom, inside: c ? pc : pa)
                case 1, 14: add(bottom, left, inside: d ? pd : pb)
                // Two neighbours inside: the segment splits the cell in halves.
                case 12, 3: add(left, right, inside: a ? pa : pd)
                case 6, 9: add(top, bottom, inside: b ? pb : pa)
                // Saddles: the centre decides whether the two inside corners join.
                case 10, 5:
                    let centre = (value(i, j) + value(i + 1, j) + value(i + 1, j + 1) + value(i, j + 1)) / 4
                    let joined = centre > iso
                    if code == 10 {
                        // a and c inside.
                        if joined {
                            add(top, right, inside: middle)
                            add(bottom, left, inside: middle)
                        } else {
                            add(left, top, inside: pa)
                            add(right, bottom, inside: pc)
                        }
                    } else {
                        // b and d inside.
                        if joined {
                            add(left, top, inside: middle)
                            add(right, bottom, inside: middle)
                        } else {
                            add(top, right, inside: pb)
                            add(bottom, left, inside: pd)
                        }
                    }
                default:
                    break
                }
            }
        }

        // Link the segments into rings.
        var rings: [[PSPoint]] = []
        var remaining = next
        // Sorted start edges: the same raster always gives the same rings in the same order.
        for startEdge in next.keys.sorted() where remaining[startEdge] != nil {
            var ring: [PSPoint] = []
            var edge = startEdge
            while let to = remaining.removeValue(forKey: edge) {
                ring.append(point(on: edge))
                edge = to
                if edge == startEdge { break }
            }
            if ring.count >= 3 { rings.append(ring) }
        }
        // A stable order: larger outlines first.
        return rings.sorted { abs(signedArea($0)) > abs(signedArea($1)) }
    }

    // MARK: - Douglas–Peucker

    /// A closed ring simplified to `tolerance`: split at its first point and the point farthest from it, each half
    /// simplified as an open polyline, then joined.
    static func simplifyClosed(_ ring: [PSPoint], tolerance: Double) -> [PSPoint] {
        guard ring.count > 3, tolerance > 0 else { return ring }
        let first = ring[0]
        var farthest = 0
        var best = -1.0
        for (index, point) in ring.enumerated() {
            let distance = point.distance(to: first)
            if distance > best {
                best = distance
                farthest = index
            }
        }
        guard farthest > 0 else { return [first] }
        let firstHalf = simplifyOpen(Array(ring[0...farthest]), tolerance: tolerance)
        let secondHalf = simplifyOpen(Array(ring[farthest...]) + [first], tolerance: tolerance)
        // Both halves share their ends: drop the duplicates.
        return Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())
    }

    /// Douglas–Peucker on an open polyline, iterative (no recursion depth to worry about on long outlines).
    static func simplifyOpen(_ points: [PSPoint], tolerance: Double) -> [PSPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let range = stack.popLast() {
            let (first, last) = range
            guard last - first > 1 else { continue }
            var index = first
            var maxDistance = -1.0
            for candidate in (first + 1)..<last {
                let distance = segmentDistance(points[candidate], points[first], points[last])
                if distance > maxDistance {
                    maxDistance = distance
                    index = candidate
                }
            }
            if maxDistance > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// The distance from `p` to the segment a–b.
    static func segmentDistance(_ p: PSPoint, _ a: PSPoint, _ b: PSPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamped(to: 0...1)
        return PSPoint(x: a.x + t * dx, y: a.y + t * dy).distance(to: p)
    }
}
