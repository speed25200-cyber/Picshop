#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

// The W1 design tokens: semantic colour roles, radii, glyph sizes, type roles,
// layout metrics and springs. White is the only action colour; yellow marks
// values, never actions. The older names in DesignSystem.swift are aliases of
// these, so screens move to the new values without edits. E5 owns this file.
//
// Scripts/lint-design-tokens.py counts literal radii, white/black opacities and
// `.system(size:)` fonts outside Theme: use these instead.

public extension ShapeStyle where Self == Color {
    /// #000000: behind the picture.
    static var psCanvas: Color { Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1) }
    /// #0A0A0C: Home, Settings, sheets, launch.
    static var psBase: Color { Color(.sRGB, red: 10 / 255, green: 10 / 255, blue: 12 / 255, opacity: 1) }
    /// #141417
    static var psRaised: Color { Color(.sRGB, red: 20 / 255, green: 20 / 255, blue: 23 / 255, opacity: 1) }
    /// #1C1C20
    static var psElevated: Color { Color(.sRGB, red: 28 / 255, green: 28 / 255, blue: 32 / 255, opacity: 1) }
    /// #26262B: menus and popovers above elevated surfaces.
    static var psOverlay: Color { Color(.sRGB, red: 38 / 255, green: 38 / 255, blue: 43 / 255, opacity: 1) }
    /// #1E1E21: the neutral surround for judging colour.
    static var psGraphite: Color { Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 33 / 255, opacity: 1) }
    /// White at 95 %.
    static var psTextPrimary: Color { Color(.sRGB, white: 1, opacity: 0.95) }
    /// White at 62 % (7.6:1 on psBase).
    static var psTextSecondary: Color { Color(.sRGB, white: 1, opacity: 0.62) }
    /// White at 48 % (AA at 13 points on psBase).
    static var psTextTertiary: Color { Color(.sRGB, white: 1, opacity: 0.48) }
    /// White at 24 %: disabled labels.
    static var psTextDisabled: Color { Color(.sRGB, white: 1, opacity: 0.24) }
    /// White: the only "do it" fill (Export, Done, Apply).
    static var psActionPrimary: Color { Color(.sRGB, white: 1, opacity: 1) }
    /// Black: labels on psActionPrimary.
    static var psOnAction: Color { Color(.sRGB, white: 0, opacity: 1) }
    /// #FFD60A: values off neutral, playhead, modified dots, active handles. Never an action fill.
    static var psValueAccent: Color { Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 1) }
    /// #FFD60A at 16 %: the soft ground of a value chip.
    static var psValueAccentSoft: Color { Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 0.16) }
    /// Black: text on psValueAccent.
    static var psOnValueAccent: Color { Color(.sRGB, white: 0, opacity: 1) }
    /// White at 10 %: flat controls inside glass.
    static var psFillControl: Color { Color(.sRGB, white: 1, opacity: 0.10) }
    /// White at 16 %.
    static var psFillPressed: Color { Color(.sRGB, white: 1, opacity: 0.16) }
    /// White at 6 %: wells (text fields, the strip behind thumbnails).
    static var psFillWell: Color { Color(.sRGB, white: 1, opacity: 0.06) }
    /// White at 8 %.
    static var psHairline: Color { Color(.sRGB, white: 1, opacity: 0.08) }
    /// White at 14 %: separators that must read on glass edges and tracks.
    static var psStrokeStrong: Color { Color(.sRGB, white: 1, opacity: 0.14) }
    /// Black at 35 %: the scrim under clear-glass badges over media.
    static var psScrim: Color { Color(.sRGB, white: 0, opacity: 0.35) }
    /// Black at 45 %: badges drawn flat over a picture (a video's length).
    static var psBadgeGround: Color { Color(.sRGB, white: 0, opacity: 0.45) }
    /// #30D158: status only.
    static var psSuccess: Color { Color(.sRGB, red: 48 / 255, green: 209 / 255, blue: 88 / 255, opacity: 1) }
    /// #FF9F0A: status only.
    static var psWarning: Color { Color(.sRGB, red: 1, green: 159 / 255, blue: 10 / 255, opacity: 1) }
    /// #FF453A: status, and Live's End.
    static var psDanger: Color { Color(.sRGB, red: 1, green: 69 / 255, blue: 58 / 255, opacity: 1) }
}

public extension Color {
    /// A palette colour (sRGB) from PicshopCore. Labelled, so `Color(.white)` stays UIColor's.
    init(psColor color: PSColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// Corner radii: six values plus capsules and concentric shapes. A shape
/// inside another is concentric: its radius is the parent's minus the inset.
public enum PSRadius {
    /// 6: tiny thumbnails.
    public static let tiny: CGFloat = 6
    /// 10: rectangular chips, page thumbnails, the histogram card.
    public static let thumb: CGFloat = 10
    /// 14: tiles and project cells.
    public static let tile: CGFloat = 14
    /// 20: cards and sheet cards.
    public static let card: CGFloat = 20
    /// 28: hero cards.
    public static let hero: CGFloat = 28
    /// 34: floating panels (the inspector, ToolPanel), concentric with the display at a 10-point inset.
    public static let floating: CGFloat = 34
    /// iPhone display corners, for the intelligence glow.
    public static let display: CGFloat = 58

    /// The radius of a shape nested `inset` points inside one of `radius`.
    public static func concentric(_ radius: CGFloat, inset: CGFloat) -> CGFloat { max(0, radius - inset) }
}

/// The five SF Symbol point sizes.
public enum PSGlyph: CGFloat {
    /// Inline and micro.
    case micro = 13
    /// Chips.
    case chip = 15
    /// 44-point bar buttons.
    case bar = 17
    /// 52-point dock buttons and the tool rail.
    case dock = 20
    /// Outils tiles.
    case tile = 22
}

public extension PSFont {
    /// A symbol at one of the five glyph sizes; medium in chrome.
    static func glyph(_ size: PSGlyph, weight: Font.Weight = .medium) -> Font {
        .system(size: size.rawValue, weight: weight)
    }

    /// A symbol sized for a round button `diameter` points wide (39 % of it).
    static func glyph(diameter: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: (diameter * 0.39).rounded(), weight: weight)
    }
}

/// Type roles beyond the system text styles (all follow Dynamic Type).
public enum PSFontRole {
    /// SF Pro Rounded 15 semibold with monospaced digits; yellow when off neutral.
    public static var valueReadout: Font { .system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit() }
    /// SF Pro Rounded 17 semibold: the value shown over the canvas while dragging.
    public static var dragHUD: Font { .system(.body, design: .rounded, weight: .semibold).monospacedDigit() }
    /// SF Mono 12 medium.
    public static var timecode: Font { .system(.caption, design: .monospaced, weight: .medium) }
    /// SF Pro Expanded 28 semibold (tracking −0.4 on the Text).
    public static var wordmark: Font { .system(.title, design: .default, weight: .semibold).width(.expanded) }
    /// The wordmark's tracking.
    public static let wordmarkTracking: CGFloat = -0.4
    /// An inspector row's label (secondary colour).
    public static var inspectorLabel: Font { .subheadline }
    /// An inspector row's value, right-aligned.
    public static var inspectorValue: Font { .subheadline.monospacedDigit().weight(.medium) }
    /// A sticky group header in the inspector.
    public static var groupHeader: Font { .footnote.weight(.semibold) }
}

/// Layout metrics of the W1 workspace.
public extension PSMetrics {
    /// The top bar's height (44-point buttons, 4 points of air).
    static let topBar: CGFloat = 48
    /// A tool-rail item.
    static let railItem: CGFloat = 44
    /// The rail's glass capsule: the items plus 4 points around them.
    static let railHeight: CGFloat = 52
    /// The inspector's compact height.
    static let inspectorCompact: CGFloat = 148
    /// The inspector's medium height, as a share of the screen.
    static let inspectorMediumShare: CGFloat = 0.46
    /// An inspector row: label line plus a 2-point track.
    static let inspectorRow: CGFloat = 52
    /// The histogram card.
    static let histogramCard = CGSize(width: 128, height: 56)
    /// A modified tool's dot.
    static let modifiedDot: CGFloat = 5
    /// The lockup's mark on Home and in Settings.
    static let lockupMark: CGFloat = 22
    /// Home's grid cells: the smallest side and the gap.
    static let gridCellMinimum: CGFloat = 108
    static let gridSpacing: CGFloat = 4
    /// The library strip's thumbnails.
    static let stripThumbnail: CGFloat = 64
}

/// The springs every animation uses. Spatial motion is always a spring, so it
/// can be interrupted and keeps its velocity.
public enum PSSpring {
    /// 0.16 s, no bounce: a control under the finger.
    public static var press: Animation { .spring(duration: 0.16, bounce: 0) }
    /// 0.22 s, snappy: toggles, colour.
    public static var quick: Animation { .snappy(duration: 0.22) }
    /// 0.36 s, bounce 0.06: panels, layout.
    public static var standard: Animation { .spring(duration: 0.36, bounce: 0.06) }
    /// 0.48 s, bounce 0.14: sheets, hero, zoom.
    public static var emphasized: Animation { .spring(duration: 0.48, bounce: 0.14) }
    /// 0.42 s, bounce 0.16: glass morphs.
    public static var morph: Animation { .spring(duration: 0.42, bounce: 0.16) }
    /// Follows the finger.
    public static var follow: Animation { .interactiveSpring(response: 0.2, dampingFraction: 0.88, blendDuration: 0.08) }
    /// Numbers ticking.
    public static var numeric: Animation { .snappy(duration: 0.16) }
    /// Opacity only.
    public static var fade: Animation { .easeOut(duration: 0.2) }
    /// 1.2 s: the backdrop's palette cross-fade.
    public static var paletteFade: Animation { .smooth(duration: 1.2) }

    /// A release that carries the gesture's velocity (points per second) over the
    /// `distance` left to travel: panel detents, swipe-down to close.
    public static func release(velocity: CGFloat, distance: CGFloat) -> Animation {
        let travel = abs(distance) > 1 ? distance : (distance < 0 ? -1 : 1)
        return .interpolatingSpring(stiffness: 260, damping: 28, initialVelocity: Double(velocity / travel))
    }
}
#endif
