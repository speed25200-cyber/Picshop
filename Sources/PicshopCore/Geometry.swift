import Foundation

/// Platform-independent 2D point. Mirrors `CGPoint` without pulling CoreGraphics
/// into the Linux-buildable core.
public struct PSPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PSPoint(x: 0, y: 0)

    public func distance(to other: PSPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func + (lhs: PSPoint, rhs: PSPoint) -> PSPoint { PSPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: PSPoint, rhs: PSPoint) -> PSPoint { PSPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    public static func * (lhs: PSPoint, rhs: Double) -> PSPoint { PSPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
}

/// Platform-independent 2D size.
public struct PSSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = PSSize(width: 0, height: 0)

    public var aspectRatio: Double { height == 0 ? 0 : width / height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Double { width * height }

    /// Returns a size that fits inside `bounds` while preserving aspect ratio.
    public func fitting(in bounds: PSSize) -> PSSize {
        guard !isEmpty, !bounds.isEmpty else { return .zero }
        let scale = min(bounds.width / width, bounds.height / height)
        return PSSize(width: width * scale, height: height * scale)
    }

    /// Returns a size whose longest side is at most `maxSide`.
    public func limited(toLongestSide maxSide: Double) -> PSSize {
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return self }
        let scale = maxSide / longest
        return PSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }
}

/// Platform-independent rectangle.
public struct PSRect: Hashable, Codable, Sendable {
    public var origin: PSPoint
    public var size: PSSize

    public init(origin: PSPoint, size: PSSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = PSPoint(x: x, y: y)
        size = PSSize(width: width, height: height)
    }

    public static let zero = PSRect(x: 0, y: 0, width: 0, height: 0)
    /// The unit rectangle (0,0)-(1,1) used for normalized coordinates.
    public static let unit = PSRect(x: 0, y: 0, width: 1, height: 1)

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var center: PSPoint { PSPoint(x: midX, y: midY) }
    public var area: Double { size.area }
    public var isEmpty: Bool { size.isEmpty }

    public func contains(_ point: PSPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersection(_ other: PSRect) -> PSRect {
        let x0 = max(minX, other.minX)
        let y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return PSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ other: PSRect) -> PSRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(minX, other.minX)
        let y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX)
        let y1 = max(maxY, other.maxY)
        return PSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func insetBy(dx: Double, dy: Double) -> PSRect {
        PSRect(x: minX + dx, y: minY + dy, width: width - 2 * dx, height: height - 2 * dy)
    }

    /// Intersection-over-union, a standard overlap metric for object candidates.
    public func iou(_ other: PSRect) -> Double {
        let inter = intersection(other).area
        let uni = area + other.area - inter
        return uni <= 0 ? 0 : inter / uni
    }

    /// Clamp a normalized rectangle to the unit square.
    public func clampedToUnit() -> PSRect {
        if minX >= 0, minY >= 0, maxX <= 1, maxY <= 1 { return self }
        let x0 = min(max(minX, 0), 1)
        let y0 = min(max(minY, 0), 1)
        let x1 = min(max(maxX, 0), 1)
        let y1 = min(max(maxY, 0), 1)
        return PSRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Scales a normalized rect (unit space) into pixel space of `size`.
    public func denormalized(in size: PSSize) -> PSRect {
        PSRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }

    /// Scales a pixel rect into unit space of `size`.
    public func normalized(in size: PSSize) -> PSRect {
        guard !size.isEmpty else { return .zero }
        return PSRect(x: minX / size.width, y: minY / size.height, width: width / size.width, height: height / size.height)
    }
}

/// Simple affine transform used for layer placement. Stored in normalized
/// canvas space so documents are resolution independent.
public struct LayerTransform: Hashable, Codable, Sendable {
    /// Center of the layer in normalized canvas coordinates (0...1).
    public var center: PSPoint
    /// Uniform scale relative to the layer's natural fit inside the canvas.
    public var scale: Double
    /// Rotation in degrees, clockwise.
    public var rotation: Double
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool

    public init(center: PSPoint = PSPoint(x: 0.5, y: 0.5), scale: Double = 1, rotation: Double = 0,
                isFlippedHorizontally: Bool = false, isFlippedVertically: Bool = false) {
        self.center = center
        self.scale = scale
        self.rotation = rotation
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
    }

    public static let identity = LayerTransform()
}

public enum FlipAxis: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical
}

public extension Double {
    /// Clamps the value into the given closed range.
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
