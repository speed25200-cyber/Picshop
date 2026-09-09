#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Design tokens. A deep, quiet ground with one system-blue accent, so the
/// photo is always the brightest and most saturated thing on screen — the
/// same rule Apple's own photo apps follow.
public enum PSTheme {
    /// iOS system blue as rendered on dark surfaces.
    public static let accent = Color(red: 0.10, green: 0.53, blue: 1.0)
    public static let accentSoft = Color(red: 0.10, green: 0.53, blue: 1.0).opacity(0.20)
    public static let voice = Color(red: 0.64, green: 0.44, blue: 1.0)
    public static let success = Color(red: 0.20, green: 0.84, blue: 0.47)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.16)
    public static let danger = Color(red: 1.0, green: 0.33, blue: 0.31)
    public static let canvas = Color.black
    /// Deep ground behind non-canvas screens (library, settings, onboarding).
    public static let ink = Color(red: 0.03, green: 0.03, blue: 0.05)
    public static let surface = Color(red: 0.09, green: 0.09, blue: 0.11)
    public static let surfaceElevated = Color(red: 0.14, green: 0.14, blue: 0.17)
    /// Flat fill used where glass is too expensive (thermal minimal level).
    public static let surfaceFlat = Color(red: 0.12, green: 0.12, blue: 0.14)
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.64)
    public static let textTertiary = Color.white.opacity(0.42)
    public static let hairline = Color.white.opacity(0.08)
    /// Edge light on cards: brighter at the top, fading down.
    public static let strokeGradient = LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
    /// Sheen laid over card surfaces.
    public static let sheen = LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    /// Active-state fill for docks, segments and chips.
    public static let accentGradient = LinearGradient(colors: [Color(red: 0.22, green: 0.60, blue: 1.0), Color(red: 0.52, green: 0.44, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Highlight laid on top of accent fills (light from above).
    public static let accentHighlight = LinearGradient(colors: [Color.white.opacity(0.26), .clear], startPoint: .top, endPoint: .center)

    public static let cornerRadius: CGFloat = PSRadius.large
    public static let panelRadius: CGFloat = PSRadius.panel
    public static let spacing: CGFloat = PSSpacing.medium

    public static let voiceGradient = LinearGradient(colors: [Color(red: 0.22, green: 0.58, blue: 1.0), Color(red: 0.70, green: 0.42, blue: 1.0), Color(red: 1.0, green: 0.46, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Colours of the mesh behind hero surfaces.
    public static let heroMesh: [Color] = [
        Color(red: 0.16, green: 0.50, blue: 1.0), Color(red: 0.30, green: 0.46, blue: 1.0), Color(red: 0.62, green: 0.40, blue: 1.0),
        Color(red: 0.12, green: 0.44, blue: 0.98), Color(red: 0.42, green: 0.42, blue: 1.0), Color(red: 0.80, green: 0.40, blue: 0.90),
        Color(red: 0.10, green: 0.36, blue: 0.86), Color(red: 0.34, green: 0.30, blue: 0.86), Color(red: 0.96, green: 0.48, blue: 0.62),
    ]
}

/// Corner radii, concentric by construction: a child radius is the parent
/// radius minus the padding between them.
public enum PSRadius {
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 22
    public static let panel: CGFloat = 28
    public static let sheet: CGFloat = 34
}

/// Spacing scale (4-point grid).
public enum PSSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let page: CGFloat = 20
}

/// Motion vocabulary. Every animation in the app is one of these springs, so
/// panels, chips and the dock all move with the same weight.
public enum PSMotion {
    /// Taps, toggles, colour changes.
    public static let quick = Animation.spring(duration: 0.22, bounce: 0.0)
    /// Panels, docks, layout changes.
    public static let standard = Animation.spring(duration: 0.36, bounce: 0.16)
    /// Hero moments: a sheet arriving, a card expanding.
    public static let emphasized = Animation.spring(duration: 0.5, bounce: 0.24)
    /// Follows the finger.
    public static let interactive = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.1)
    /// Numbers ticking.
    public static let numeric = Animation.snappy(duration: 0.16)
}

/// SF Pro for titles and body (tight, editorial), SF Rounded for small labels
/// and numbers so they read like system dials.
public enum PSFont {
    public static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .default) }
    public static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .default) }
    public static func headline(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .default) }
    public static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .regular, design: .default) }
    public static func caption(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    public static func mono(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .rounded).monospacedDigit() }
}

/// Haptic vocabulary used consistently across the app.
@MainActor
public enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    public static var isEnabled = true

    public static func tap() { guard isEnabled else { return }; light.impactOccurred(intensity: 0.7) }
    public static func tick() { guard isEnabled else { return }; selection.selectionChanged() }
    public static func soft(_ intensity: CGFloat = 0.6) { guard isEnabled else { return }; softImpact.impactOccurred(intensity: intensity) }
    public static func confirm() { guard isEnabled else { return }; medium.impactOccurred() }
    public static func heavy() { guard isEnabled else { return }; rigid.impactOccurred() }
    public static func success() { guard isEnabled else { return }; notification.notificationOccurred(.success) }
    public static func warning() { guard isEnabled else { return }; notification.notificationOccurred(.warning) }
    public static func error() { guard isEnabled else { return }; notification.notificationOccurred(.error) }
    public static func prepare() { light.prepare(); medium.prepare(); selection.prepare(); softImpact.prepare() }
}

/// Localised string lookup for the UI package's catalogue.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// Localises a key that is only known at runtime (enum display names). Such
/// keys are listed in DYNAMIC_KEYS of Scripts/generate_strings.py.
public func LD(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .module)
}
#endif
