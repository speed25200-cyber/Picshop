#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopIntent

/// The older token names, kept so screens owned by other lanes compile
/// unchanged. Each one is an alias of a W1 token in PSTokens.swift, so the
/// whole app moves to the new values at once; new code uses the ShapeStyle
/// roles (`.psTextSecondary`, `.psFillControl` …), PSRadius, PSFontRole and
/// PSSpring directly.
///
/// The colour roles, one meaning each:
/// - **Neutral**: black canvas, near-black base, white text in four strengths, glass chrome.
/// - **Action** (white, black label): the only "do it" colour (Export, Done, Apply, Send).
/// - **Value** (yellow #FFD60A, black label): a value off neutral, the playhead,
///   modified dots, active handles. Never an action fill, never white text on it.
/// - **Intelligence** (blue → violet → pink → amber): only the orb, the Magic
///   glyph, the AI caption lane and the working shimmer.
///
/// Status colours (success, warning, danger) only ever report a status.
public enum PSTheme {
    // MARK: Value accent
    /// The value yellow (#FFD60A): values off neutral, never an action.
    public static let accent = Color.psValueAccent
    public static let accentSoft = Color.psValueAccentSoft
    /// Text and glyphs drawn on an accent fill.
    public static let onAccent = Color.psOnValueAccent
    @available(*, deprecated, message: "Yellow is never an action fill: use psActionPrimary, or psValueAccent for a value.")
    public static let accentGradient = LinearGradient(colors: [Color.psValueAccent, Color.psValueAccent], startPoint: .top, endPoint: .bottom)
    @available(*, deprecated, message: "Flat fills only.")
    public static let accentHighlight = LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .center)

    // MARK: Intelligence
    /// #4285FF, #996BFF, #F5619E, #FF9E4D (Display P3): the spectrum.
    public static let intelligence: [Color] = [
        Color(.displayP3, red: 0.26, green: 0.52, blue: 1.0),
        Color(.displayP3, red: 0.60, green: 0.42, blue: 1.0),
        Color(.displayP3, red: 0.96, green: 0.38, blue: 0.62),
        Color(.displayP3, red: 1.0, green: 0.62, blue: 0.30),
    ]
    /// The voice and Magic colour when a single colour is needed.
    public static let voice = Color(.displayP3, red: 0.60, green: 0.42, blue: 1.0)
    public static let voiceGradient = LinearGradient(colors: intelligence, startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let intelligenceAngular = AngularGradient(colors: intelligence + [intelligence[0]], center: .center)

    // MARK: Status
    public static let success = Color.psSuccess
    public static let warning = Color.psWarning
    public static let danger = Color.psDanger

    // MARK: Neutrals
    /// Behind the photo: true black.
    public static let canvas = Color.psCanvas
    /// Home, Settings, sheets, launch: #0A0A0C (psBase).
    public static let ink = Color.psBase
    /// #141417 (psRaised).
    public static let surface = Color.psRaised
    /// #1C1C20 (psElevated).
    public static let surfaceElevated = Color.psElevated
    /// Flat fill used where glass is too expensive (thermal minimal level): psElevated.
    public static let surfaceFlat = Color.psElevated
    public static let textPrimary = Color.psTextPrimary
    public static let textSecondary = Color.psTextSecondary
    /// 48 % (was 38 %, which failed AA at 13 points).
    public static let textTertiary = Color.psTextTertiary
    public static let textQuaternary = Color.psTextDisabled
    /// Separators on flat surfaces. Never on glass.
    public static let hairline = Color.psHairline
    /// Fill of a control that sits inside glass (chips, wells): no glass on glass.
    public static let fill = Color.psFillControl
    /// `fill` while pressed.
    public static let fillPressed = Color.psFillPressed
    /// The selected state of neutral controls: a lit thumb, not a colour.
    public static let selection = Color.psFillPressed
    @available(*, deprecated, message: "No edge-light gradients: flat surfaces take psHairline.")
    public static let strokeGradient = LinearGradient(colors: [Color.psHairline, Color.psHairline], startPoint: .top, endPoint: .bottom)
    @available(*, deprecated, message: "No sheens on cards.")
    public static let sheen = LinearGradient(colors: [Color.clear, Color.clear], startPoint: .top, endPoint: .bottom)

    // MARK: Action
    /// The one action colour (Export, Send, Done): white with a black label.
    public static let primary = Color.psActionPrimary
    /// Text and glyphs drawn on `primary`.
    public static let onPrimary = Color.psOnAction
    /// The Live console's End button (#FF453A).
    public static let liveEnd = Color.psDanger
    /// The assistant's caption line.
    public static let captionPrimary = Color.psTextPrimary
    /// The user's settled words (0.80 with Increase Contrast, applied in views).
    public static let captionSecondary = Color.psTextSecondary
    /// The user's still-changing words (0.60 with Increase Contrast, applied in views).
    public static let captionVolatile = Color(.sRGB, white: 1, opacity: 0.40)

    @available(*, deprecated, message: "Use PSRadius.")
    public static let cornerRadius: CGFloat = 22
    @available(*, deprecated, message: "Use PSRadius.floating.")
    public static let panelRadius: CGFloat = 30
    @available(*, deprecated, message: "Use PSSpacing.")
    public static let spacing: CGFloat = 12

    /// Colours of the mesh behind hero surfaces: the spectrum at 70 % saturation.
    @available(*, deprecated, message: "Use PSBackdrop.")
    public static let heroMesh: [Color] = [
        Color(red: 0.26, green: 0.34, blue: 0.62), Color(red: 0.35, green: 0.34, blue: 0.66), Color(red: 0.48, green: 0.31, blue: 0.62),
        Color(red: 0.34, green: 0.50, blue: 0.86), Color(red: 0.60, green: 0.51, blue: 0.96), Color(red: 0.80, green: 0.44, blue: 0.67),
        Color(red: 0.19, green: 0.24, blue: 0.44), Color(red: 0.62, green: 0.37, blue: 0.58), Color(red: 0.96, green: 0.61, blue: 0.50),
    ]
}

/// The older radius names (the scale itself is in PSTokens.swift).
public extension PSRadius {
    /// The processing HUD tile and two-line strips: a card.
    static let hud: CGFloat = PSRadius.card
    /// The inline ToolPanel card, concentric with the display at a 10-point inset.
    static let toolPanel: CGFloat = PSRadius.floating
    @available(*, deprecated, renamed: "thumb")
    static let small: CGFloat = 12
    @available(*, deprecated, renamed: "tile")
    static let medium: CGFloat = 16
    @available(*, deprecated, renamed: "card")
    static let large: CGFloat = 22
    @available(*, deprecated, renamed: "floating")
    static let panel: CGFloat = 30
    @available(*, deprecated, renamed: "floating")
    static let sheet: CGFloat = 36
    @available(*, deprecated, renamed: "tile")
    static let toolTile: CGFloat = 14
    @available(*, deprecated, renamed: "tile")
    static let projectCell: CGFloat = 14
    @available(*, deprecated, renamed: "card")
    static let onboardingCard: CGFloat = 20
}

/// Spacing scale on a 4-point grid: 4, 8, 12, 16, 20, 24, 32.
public enum PSSpacing {
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    /// 20.
    public static let mediumLarge: CGFloat = 20
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
    /// Home and settings page margin.
    public static let page: CGFloat = 20
    /// Between Home sections.
    public static let section: CGFloat = 28
    /// Editor dock and panel distance from the screen edges.
    public static let editorInset: CGFloat = 12
    /// Inner padding of a floating panel.
    public static let panel: CGFloat = 16

    // Studio.
    /// The dock's and the top bar's distance from the screen sides.
    public static let editorSide: CGFloat = 16
    /// Between the idea row and the composer.
    public static let dockGap: CGFloat = 10
    /// Between the idea row and the Live console.
    public static let consoleGap: CGFloat = 12
    /// Between the captions and the idea row.
    public static let captionGap: CGFloat = 10
}

/// Control heights.
public enum PSMetrics {
    /// Chips inside panels.
    public static let chip: CGFloat = 34
    /// Icon buttons, segmented controls, toasts: the minimum touch target.
    public static let control: CGFloat = 44
    /// Full-width buttons.
    public static let largeButton: CGFloat = 52
    @available(*, deprecated, message: "Unused: dock buttons are dockButton.")
    public static let mic: CGFloat = 56
    @available(*, deprecated, message: "Unused: the dock is sized by its content.")
    public static let dock: CGFloat = 64
    /// Horizontal padding of a chip (12 with a leading glyph).
    public static let chipPadding: CGFloat = 14

    // Studio: the editor shell, the Live dock and the orb.
    /// Round buttons of the top bar.
    public static let barButton: CGFloat = 44
    /// Round buttons of the dock (Outils, mute, keyboard, End).
    public static let dockButton: CGFloat = 52
    /// The Ask field.
    public static let composerHeight: CGFloat = 52
    /// The Ask field on compact screens (667 points tall).
    public static let composerHeightCompact: CGFloat = 48
    /// Idea chips.
    public static let ideaChip: CGFloat = 40
    /// The orb at rest, next to the Ask field.
    public static let orbComposer: CGFloat = 52
    /// The orb in the Live console.
    public static let orbConsole: CGFloat = 76
    /// The orb in the Live console on compact screens.
    public static let orbConsoleCompact: CGFloat = 64
    /// The orb in a ToolPanel header.
    public static let orbMini: CGFloat = 36
    /// The orb on Home's empty state.
    public static let orbHero: CGFloat = 120
    /// The orb on the onboarding pages.
    public static let orbOnboarding: CGFloat = 160
    /// The Live console row.
    public static let consoleHeight: CGFloat = 76
    /// Tiles in the Outils sheet (76 × 84, the symbol on a 76 × 60 plate).
    public static let toolTile: CGFloat = 76
    /// Small pills over media (the Live brain pill).
    public static let badge: CGFloat = 30
}

/// Motion vocabulary: the older names, now the PSSpring values (PSTokens.swift),
/// plus the orb's and the captions' own timings.
public enum PSMotion {
    /// Taps, toggles, colour changes.
    public static let quick = PSSpring.quick
    /// Panels, docks, layout changes.
    public static let standard = PSSpring.standard
    /// Hero moments: a sheet arriving, a card expanding, a mode morphing.
    public static let emphasized = PSSpring.emphasized
    /// Follows the finger.
    public static let interactive = PSSpring.follow
    /// Numbers ticking.
    public static let numeric = PSSpring.numeric
    /// Things that appear from nothing (toasts, badges).
    public static let appear = Animation.spring(duration: 0.4, bounce: 0.1)
    /// A result dissolving in over the previous picture.
    public static let dissolve = Animation.easeOut(duration: 0.35)

    // Studio.
    /// The dock morphing between the composer and the Live console.
    public static let morph = PSSpring.morph
    /// The orb leaving `.off` (0.6 to 1).
    public static let bloom = Animation.spring(duration: 0.55, bounce: 0.22)
    /// The orb's palette and scale moving between Live states.
    public static let orbState = Animation.smooth(duration: 0.6)
    /// Idea chips arriving or being replaced.
    public static let ideas = Animation.smooth(duration: 0.45)
    /// A caption line settling in.
    public static let captionWord = Animation.easeOut(duration: 0.18)
    /// The orb springing back after a barge-in dip.
    public static let bargeIn = Animation.spring(duration: 0.22, bounce: 0.35)
}

/// SF Pro on Dynamic Type text styles, so optical sizes, tracking and the
/// user's text size all apply. The sized functions keep their signatures:
/// a size that matches a text style (at the default text size) becomes that
/// style; any other size stays fixed. 10 and 10.5 round up to `caption2`,
/// 14 to `subheadline`.
///
/// Weights are regular, medium and semibold; bold only for large titles.
/// No manual tracking except on uppercase micro labels (`psMicroLabel()`).
public enum PSFont {
    /// 34 bold (`largeTitle`); other sizes stay fixed.
    public static func display(_ size: CGFloat = 34) -> Font { font(size, .bold) }
    /// Bold from 22 points (`title2`, `title`), semibold below (`title3`).
    public static func title(_ size: CGFloat = 28) -> Font { font(size, size >= 22 ? .bold : .semibold) }
    public static func headline(_ size: CGFloat = 17) -> Font { font(size, .semibold) }
    public static func body(_ size: CGFloat = 15) -> Font { font(size, .regular) }
    /// Regular; medium below 12 points so small text holds on glass.
    public static func caption(_ size: CGFloat = 12) -> Font { font(size, size < 12 ? .medium : .regular) }
    public static func label(_ size: CGFloat = 11) -> Font { font(size, .medium) }
    public static func mono(_ size: CGFloat = 13) -> Font { font(size, .medium).monospacedDigit() }
    /// Timecodes: true monospace at a fixed size so rulers never reflow.
    public static func timecode(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .monospaced) }

    // MARK: Semantic styles
    /// 34 bold.
    public static func largeTitle() -> Font { .largeTitle.weight(.bold) }
    /// 20 semibold: section titles.
    public static func section() -> Font { .title3.weight(.semibold) }
    /// 16 regular.
    public static func callout() -> Font { .callout }
    /// 15: chips, toasts, control labels; medium when selected.
    public static func control(selected: Bool = false) -> Font { .subheadline.weight(selected ? .medium : .regular) }
    /// 13 regular.
    public static func footnote() -> Font { .footnote }
    /// 11 medium, the smallest text in the app.
    public static func micro() -> Font { .caption2.weight(.medium) }
    /// Numeric badges and the dial's value bubble: SF Pro Rounded, fixed size.
    public static func rounded(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }

    /// The text style drawn at `size` points at the default text size.
    static func textStyle(for size: CGFloat) -> Font.TextStyle? {
        switch size {
        case 34: return .largeTitle
        case 28: return .title
        case 22: return .title2
        case 20: return .title3
        case 17: return .body
        case 16: return .callout
        case 14...15: return .subheadline
        case 13: return .footnote
        case 12: return .caption
        case 10...11: return .caption2
        default: return nil
        }
    }

    private static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        if let style = textStyle(for: size) { return .system(style, design: .default, weight: weight) }
        return .system(size: size, weight: weight, design: .default)
    }
}

public extension View {
    /// An uppercase micro label (the dial's parameter name): the only text
    /// that is tracked by hand.
    func psMicroLabel() -> some View {
        font(PSFont.micro()).textCase(.uppercase).tracking(0.4).foregroundStyle(PSTheme.textSecondary)
    }
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

    /// When the last Live haptic played (system uptime), for the 300 ms spacing.
    private static var lastLiveHaptic: TimeInterval = -1

    /// Picshop Live's haptics. At most one every 300 ms; respects `isEnabled`.
    public static func live(_ haptic: LiveHaptic) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard lastLiveHaptic < 0 || now - lastLiveHaptic >= 0.3 else { return }
        lastLiveHaptic = now
        switch haptic {
        case .liveStart:
            medium.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { softImpact.impactOccurred(intensity: 0.5) }
        case .liveEnd:
            softImpact.impactOccurred(intensity: 0.4)
        case .bargeIn:
            rigid.impactOccurred(intensity: 0.45)
        case .actionStarted:
            softImpact.impactOccurred(intensity: 0.5)
        case .actionApplied:
            magic()
        case .problem:
            notification.notificationOccurred(.warning)
        }
    }
}

#if DEBUG
/// Launch with `-PSPrintChanges` to log why the studio's main views re-evaluate
/// (`_printChanges`): a dial drag should list only the dragged ring and the dial.
enum ViewTrace {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-PSPrintChanges")

    /// Call as `let _ = ViewTrace.changes(Self.self)` first in a body.
    @MainActor static func changes<V: View>(_ view: V.Type) {
        if isOn { V._printChanges() }
    }
}
#endif

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
