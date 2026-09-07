import Foundation

/// Coordinate conversions for PDF pages. Markups are stored in the page's
/// *base* space (unrotated, normalised, top-left origin); the viewer shows the
/// page rotated by `rotation` degrees clockwise.
public enum PDFGeometry {
    /// Displayed (normalised, top-left origin) → base (normalised, top-left origin).
    public static func basePoint(fromDisplayed p: PSPoint, rotation: Int) -> PSPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return PSPoint(x: p.y, y: 1 - p.x)
        case 180: return PSPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return PSPoint(x: 1 - p.y, y: p.x)
        default: return p
        }
    }

    /// Base → displayed.
    public static func displayedPoint(fromBase p: PSPoint, rotation: Int) -> PSPoint {
        switch ((rotation % 360) + 360) % 360 {
        case 90: return PSPoint(x: 1 - p.y, y: p.x)
        case 180: return PSPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return PSPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    public static func baseRect(fromDisplayed r: PSRect, rotation: Int) -> PSRect {
        bounding([basePoint(fromDisplayed: PSPoint(x: r.minX, y: r.minY), rotation: rotation),
                  basePoint(fromDisplayed: PSPoint(x: r.maxX, y: r.maxY), rotation: rotation)])
    }

    public static func displayedRect(fromBase r: PSRect, rotation: Int) -> PSRect {
        bounding([displayedPoint(fromBase: PSPoint(x: r.minX, y: r.minY), rotation: rotation),
                  displayedPoint(fromBase: PSPoint(x: r.maxX, y: r.maxY), rotation: rotation)])
    }

    static func bounding(_ points: [PSPoint]) -> PSRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return PSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Base normalised (top-left origin) → PDF points (bottom-left origin) for a page of `size` points.
    public static func pagePoints(fromBase r: PSRect, size: PSSize) -> PSRect {
        PSRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    /// PDF points (bottom-left origin) → base normalised (top-left origin).
    public static func baseNormalized(fromPagePoints r: PSRect, size: PSSize) -> PSRect {
        guard !size.isEmpty else { return .zero }
        return PSRect(x: r.minX / size.width, y: 1 - r.maxY / size.height, width: r.width / size.width, height: r.height / size.height).clampedToUnit()
    }
}
