import Foundation

/// Text placed on a photo or video frame. Metrics are relative to the canvas so
/// the same element renders identically at preview and export resolution.
public struct TextElement: Hashable, Codable, Sendable, Identifiable {
    public enum Alignment: String, Codable, Sendable, CaseIterable {
        case leading, center, trailing
    }

    public enum Style: String, Codable, Sendable, CaseIterable {
        case plain
        case outlined
        case shadowed
        case pill
        case banner
        case neon
    }

    public enum Placement: String, Codable, Sendable, CaseIterable {
        case top, center, bottom, topLeading, topTrailing, bottomLeading, bottomTrailing

        public var center: PSPoint {
            switch self {
            case .top: return PSPoint(x: 0.5, y: 0.12)
            case .center: return PSPoint(x: 0.5, y: 0.5)
            case .bottom: return PSPoint(x: 0.5, y: 0.86)
            case .topLeading: return PSPoint(x: 0.22, y: 0.12)
            case .topTrailing: return PSPoint(x: 0.78, y: 0.12)
            case .bottomLeading: return PSPoint(x: 0.22, y: 0.86)
            case .bottomTrailing: return PSPoint(x: 0.78, y: 0.86)
            }
        }
    }

    public var id: UUID
    public var text: String
    public var fontName: String
    /// Font size as a fraction of the canvas height.
    public var relativeSize: Double
    public var color: PSColor
    public var alignment: Alignment
    public var style: Style
    public var center: PSPoint
    public var rotation: Double
    public var opacity: Double
    public var letterSpacing: Double
    public var lineSpacing: Double
    /// Maximum width as a fraction of the canvas width before wrapping.
    public var maxRelativeWidth: Double

    public init(id: UUID = UUID(), text: String, fontName: String = "SFProRounded-Bold", relativeSize: Double = 0.06,
                color: PSColor = .white, alignment: Alignment = .center, style: Style = .shadowed,
                center: PSPoint = Placement.bottom.center, rotation: Double = 0, opacity: Double = 1,
                letterSpacing: Double = 0, lineSpacing: Double = 1.1, maxRelativeWidth: Double = 0.85) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.relativeSize = relativeSize
        self.color = color
        self.alignment = alignment
        self.style = style
        self.center = center
        self.rotation = rotation
        self.opacity = opacity
        self.letterSpacing = letterSpacing
        self.lineSpacing = lineSpacing
        self.maxRelativeWidth = maxRelativeWidth
    }
}
