import Foundation

/// Fills polygons into an 8-bit mask (255 inside), for shapes that come as
/// outlines — the eyes, lips and face of Vision's face landmarks.
public enum PolygonRaster {
    /// `polygons` are in normalised coordinates, top-left origin. Even-odd
    /// fill across all of them, sampled at pixel centres; row 0 is the top.
    public static func fill(_ polygons: [[PSPoint]], width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: max(0, width * height))
        guard width > 0, height > 0 else { return bytes }
        let edges: [(x0: Double, y0: Double, x1: Double, y1: Double)] = polygons.filter { $0.count >= 3 }.flatMap { polygon in
            polygon.indices.map { index -> (x0: Double, y0: Double, x1: Double, y1: Double) in
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                return (a.x * Double(width), a.y * Double(height), b.x * Double(width), b.y * Double(height))
            }
        }
        guard !edges.isEmpty else { return bytes }
        let top = max(0, Int(edges.map { min($0.y0, $0.y1) }.min()!.rounded(.down)))
        let bottom = min(height - 1, Int(edges.map { max($0.y0, $0.y1) }.max()!.rounded(.up)))
        guard top <= bottom else { return bytes }
        for row in top...bottom {
            let y = Double(row) + 0.5
            var crossings: [Double] = []
            for edge in edges where (edge.y0 <= y && edge.y1 > y) || (edge.y1 <= y && edge.y0 > y) {
                crossings.append(edge.x0 + (y - edge.y0) * (edge.x1 - edge.x0) / (edge.y1 - edge.y0))
            }
            crossings.sort()
            var index = 0
            while index + 1 < crossings.count {
                let from = max(0, Int((crossings[index] - 0.5).rounded(.up)))
                let to = min(width - 1, Int((crossings[index + 1] - 0.5).rounded(.down)))
                if from <= to {
                    for column in from...to { bytes[row * width + column] = 255 }
                }
                index += 2
            }
        }
        return bytes
    }

    /// An ellipse as a polygon, for shapes Vision gives only as a box.
    public static func ellipse(center: PSPoint, radiusX: Double, radiusY: Double, segments: Int = 48) -> [PSPoint] {
        (0..<max(8, segments)).map { index in
            let angle = Double(index) / Double(max(8, segments)) * 2 * .pi
            return PSPoint(x: center.x + cos(angle) * radiusX, y: center.y + sin(angle) * radiusY)
        }
    }
}
