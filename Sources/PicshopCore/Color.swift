import Foundation

/// Device-independent sRGB color with alpha.
public struct PSColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
        self.alpha = alpha.clamped(to: 0...1)
    }

    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        if value.count == 6 {
            self.init(red: Double((number >> 16) & 0xFF) / 255,
                      green: Double((number >> 8) & 0xFF) / 255,
                      blue: Double(number & 0xFF) / 255)
        } else {
            self.init(red: Double((number >> 24) & 0xFF) / 255,
                      green: Double((number >> 16) & 0xFF) / 255,
                      blue: Double((number >> 8) & 0xFF) / 255,
                      alpha: Double(number & 0xFF) / 255)
        }
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public static let white = PSColor(red: 1, green: 1, blue: 1)
    public static let black = PSColor(red: 0, green: 0, blue: 0)
    public static let clear = PSColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let red = PSColor(red: 1, green: 0.23, blue: 0.19)
    public static let orange = PSColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = PSColor(red: 1, green: 0.8, blue: 0)
    public static let green = PSColor(red: 0.2, green: 0.78, blue: 0.35)
    public static let blue = PSColor(red: 0, green: 0.48, blue: 1)
    public static let purple = PSColor(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = PSColor(red: 1, green: 0.18, blue: 0.33)
    public static let gray = PSColor(red: 0.56, green: 0.56, blue: 0.58)
    public static let brown = PSColor(red: 0.64, green: 0.52, blue: 0.37)
    public static let teal = PSColor(red: 0.35, green: 0.78, blue: 0.98)

    /// Recognizes colour names in English and French ("rouge", "bleu ciel", "dark gray"...).
    public static func named(_ name: String) -> PSColor? {
        let key = name.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let table: [String: PSColor] = [
            "white": .white, "blanc": .white, "blanche": .white,
            "black": .black, "noir": .black, "noire": .black,
            "red": .red, "rouge": .red,
            "orange": .orange,
            "yellow": .yellow, "jaune": .yellow,
            "green": .green, "vert": .green, "verte": .green,
            "blue": .blue, "bleu": .blue, "bleue": .blue,
            "purple": .purple, "violet": .purple, "violette": .purple, "mauve": .purple,
            "pink": .pink, "rose": .pink,
            "gray": .gray, "grey": .gray, "gris": .gray, "grise": .gray,
            "brown": .brown, "marron": .brown, "brun": .brown,
            "teal": .teal, "turquoise": .teal, "cyan": .teal,
            "transparent": .clear, "clear": .clear,
        ]
        if let direct = table[key] { return direct }
        // Handle qualifiers such as "light blue", "bleu clair", "dark green", "vert fonce".
        let words = key.split(separator: " ").map(String.init)
        guard let base = words.compactMap({ table[$0] }).first else { return nil }
        let lighten = words.contains { ["light", "clair", "claire", "pale", "pastel"].contains($0) }
        let darken = words.contains { ["dark", "fonce", "foncee", "sombre", "deep"].contains($0) }
        if lighten { return base.blended(with: .white, fraction: 0.45) }
        if darken { return base.blended(with: .black, fraction: 0.4) }
        return base
    }

    public func blended(with other: PSColor, fraction: Double) -> PSColor {
        let t = fraction.clamped(to: 0...1)
        return PSColor(red: red + (other.red - red) * t,
                       green: green + (other.green - green) * t,
                       blue: blue + (other.blue - blue) * t,
                       alpha: alpha + (other.alpha - alpha) * t)
    }

    public func withAlpha(_ value: Double) -> PSColor {
        var copy = self
        copy.alpha = value.clamped(to: 0...1)
        return copy
    }

    /// Relative luminance (Rec. 709) — used to pick readable text colours.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}
