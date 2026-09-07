#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Design tokens. Dark, cinematic surface with a single accent so the photo
/// is always the brightest thing on screen.
public enum PSTheme {
    public static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    public static let accentSoft = Color(red: 0.36, green: 0.55, blue: 1.0).opacity(0.22)
    public static let voice = Color(red: 0.62, green: 0.42, blue: 1.0)
    public static let success = Color(red: 0.3, green: 0.85, blue: 0.5)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.2)
    public static let danger = Color(red: 1.0, green: 0.32, blue: 0.3)
    public static let canvas = Color(red: 0.04, green: 0.04, blue: 0.05)
    public static let surface = Color(red: 0.09, green: 0.09, blue: 0.11)
    public static let surfaceElevated = Color(red: 0.14, green: 0.14, blue: 0.17)
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.62)
    public static let hairline = Color.white.opacity(0.08)

    public static let cornerRadius: CGFloat = 22
    public static let panelRadius: CGFloat = 28
    public static let spacing: CGFloat = 12

    public static let voiceGradient = LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0), Color(red: 0.72, green: 0.4, blue: 1.0), Color(red: 1.0, green: 0.45, blue: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

public enum PSFont {
    public static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    public static func headline(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    public static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    public static func caption(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    public static func mono(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
}

/// Haptic vocabulary used consistently across the app.
@MainActor
public enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    public static var isEnabled = true

    public static func tap() { guard isEnabled else { return }; light.impactOccurred(intensity: 0.7) }
    public static func tick() { guard isEnabled else { return }; selection.selectionChanged() }
    public static func confirm() { guard isEnabled else { return }; medium.impactOccurred() }
    public static func heavy() { guard isEnabled else { return }; rigid.impactOccurred() }
    public static func success() { guard isEnabled else { return }; notification.notificationOccurred(.success) }
    public static func warning() { guard isEnabled else { return }; notification.notificationOccurred(.warning) }
    public static func error() { guard isEnabled else { return }; notification.notificationOccurred(.error) }
    public static func prepare() { light.prepare(); medium.prepare(); selection.prepare() }
}

/// Localised string lookup for the UI package's catalogue.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
#endif
