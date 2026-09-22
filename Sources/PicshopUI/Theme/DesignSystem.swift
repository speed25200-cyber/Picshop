#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Design tokens.
///
/// Three colour roles, and only three, so the picture is always the most
/// vivid thing on screen:
/// - **Neutral**: black ground, white text in four strengths, glass chrome.
/// - **Edit accent** (warm yellow, like Photos): a value that differs from
///   neutral, the playhead, the primary "Done". Never decoration.
/// - **Intelligence** (the iridescent blue → violet → pink → amber spectrum):
///   reserved for things the AI does — the Magic tools, the voice, the glow
///   around the screen while it listens or works.
public enum PSTheme {
    // MARK: Edit accent
    /// Photos' edit yellow as rendered on dark surfaces.
    public static let accent = Color(red: 1.0, green: 0.80, blue: 0.04)
    public static let accentSoft = Color(red: 1.0, green: 0.80, blue: 0.04).opacity(0.18)
    /// Text and glyphs drawn on an accent fill.
    public static let onAccent = Color.black
    public static let accentGradient = LinearGradient(colors: [Color(red: 1.0, green: 0.85, blue: 0.20), Color(red: 1.0, green: 0.74, blue: 0.0)], startPoint: .top, endPoint: .bottom)
    /// Highlight laid on top of accent fills (light from above).
    public static let accentHighlight = LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)

    // MARK: Intelligence
    public static let intelligence: [Color] = [
        Color(red: 0.24, green: 0.55, blue: 1.0),
        Color(red: 0.58, green: 0.40, blue: 1.0),
        Color(red: 0.98, green: 0.36, blue: 0.64),
        Color(red: 1.0, green: 0.56, blue: 0.24),
    ]
    /// The voice and Magic colour when a single colour is needed.
    public static let voice = Color(red: 0.62, green: 0.44, blue: 1.0)
    public static let voiceGradient = LinearGradient(colors: intelligence, startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let intelligenceAngular = AngularGradient(colors: intelligence + [intelligence[0]], center: .center)

    // MARK: Status
    public static let success = Color(red: 0.19, green: 0.82, blue: 0.35)
    public static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
    public static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)

    // MARK: Neutrals
    public static let canvas = Color.black
    /// Ground behind non-canvas screens (library, settings, onboarding).
    public static let ink = Color(red: 0.02, green: 0.02, blue: 0.03)
    public static let surface = Color(red: 0.08, green: 0.08, blue: 0.09)
    public static let surfaceElevated = Color(red: 0.13, green: 0.13, blue: 0.14)
    /// Flat fill used where glass is too expensive (thermal minimal level).
    public static let surfaceFlat = Color(red: 0.11, green: 0.11, blue: 0.12)
    public static let textPrimary = Color.white
    public static let textSecondary = Color.white.opacity(0.62)
    public static let textTertiary = Color.white.opacity(0.38)
    public static let textQuaternary = Color.white.opacity(0.22)
    public static let hairline = Color.white.opacity(0.09)
    /// The selected state of neutral controls: a lit glass thumb, not a colour.
    public static let selection = Color.white.opacity(0.16)
    /// Edge light on cards: brighter at the top, fading down.
    public static let strokeGradient = LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
    /// Sheen laid over card surfaces.
    public static let sheen = LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0.0)], startPoint: .top, endPoint: .bottom)

    public static let cornerRadius: CGFloat = PSRadius.large
    public static let panelRadius: CGFloat = PSRadius.panel
    public static let spacing: CGFloat = PSSpacing.medium

    /// Colours of the mesh behind hero surfaces: the intelligence spectrum, deepened.
    public static let heroMesh: [Color] = [
        Color(red: 0.10, green: 0.22, blue: 0.62), Color(red: 0.22, green: 0.20, blue: 0.66), Color(red: 0.42, green: 0.18, blue: 0.62),
        Color(red: 0.12, green: 0.34, blue: 0.86), Color(red: 0.44, green: 0.32, blue: 0.96), Color(red: 0.80, green: 0.28, blue: 0.62),
        Color(red: 0.08, green: 0.16, blue: 0.44), Color(red: 0.62, green: 0.26, blue: 0.56), Color(red: 0.96, green: 0.46, blue: 0.30),
    ]
}

/// Corner radii, concentric by construction: a child radius is the parent
/// radius minus the padding between them.
public enum PSRadius {
    public static let small: CGFloat = 12
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 22
    public static let panel: CGFloat = 30
    public static let sheet: CGFloat = 36
    /// iPhone display corners, for the intelligence glow.
    public static let display: CGFloat = 58
}

/// Spacing scale (4-point grid).
public enum PSSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
    public static let page: CGFloat = 20
}

/// Motion vocabulary. Every animation in the app is one of these springs, so
/// panels, chips and the dock all move with the same weight.
public enum PSMotion {
    /// Taps, toggles, colour changes.
    public static let quick = Animation.spring(duration: 0.24, bounce: 0.0)
    /// Panels, docks, layout changes.
    public static let standard = Animation.spring(duration: 0.4, bounce: 0.12)
    /// Hero moments: a sheet arriving, a card expanding, a mode morphing.
    public static let emphasized = Animation.spring(duration: 0.55, bounce: 0.2)
    /// Follows the finger.
    public static let interactive = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.1)
    /// Numbers ticking.
    public static let numeric = Animation.snappy(duration: 0.16)
    /// Things that appear from nothing (toasts, badges).
    public static let appear = Animation.spring(duration: 0.45, bounce: 0.28)
}

/// SF Pro throughout, tight tracking on large sizes, monospaced digits for
/// every number that changes.
public enum PSFont {
    public static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .default) }
    public static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .default) }
    public static func headline(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold, design: .default) }
    public static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .regular, design: .default) }
    public static func caption(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .default) }
    public static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .semibold, design: .default) }
    public static func mono(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium, design: .default).monospacedDigit() }
    /// Timecodes: true monospace so frames never jitter.
    public static func timecode(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
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
    /// A little flourish for AI results: two soft taps like a heartbeat.
    public static func magic() {
        guard isEnabled else { return }
        softImpact.impactOccurred(intensity: 0.55)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { softImpact.impactOccurred(intensity: 0.9) }
    }
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

/// Whether the interface speaks French (for enum names that carry both languages).
var psPrefersFrench: Bool { Locale.current.language.languageCode?.identifier == "fr" }
#endif
