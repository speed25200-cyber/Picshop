#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Liquid Glass surfaces and the handful of controls built from them.
///
/// Chrome is system glass, untouched: no hand-drawn strokes, shadows or
/// clipping on top of it, so the system's own rim light, refraction and
/// shadow show. Neighbouring pieces sit in a `PSGlassContainer` so they melt
/// into each other and morph. Controls inside glass use a plain fill
/// (`psChipFill`), never glass on glass. Every surface reads `psEffects`:
/// at `.minimal` (a hot phone) glass becomes a flat fill and the layout
/// never moves.
public extension View {
    /// Glass in `shape`. `.clear` is for controls floating over the photo;
    /// `.regular` (the default) for panels, docks and bars.
    @ViewBuilder
    func psGlass(tint: Color? = nil, interactive: Bool = false, shape: AnyShape = AnyShape(Capsule()), variant: PSGlassVariant = .regular) -> some View {
        modifier(PSGlassModifier(tint: tint, interactive: interactive, shape: shape, variant: variant))
    }

    @ViewBuilder
    func psGlassPanel(cornerRadius: CGFloat = PSTheme.panelRadius) -> some View {
        psCard(cornerRadius: cornerRadius)
    }

    /// A floating panel: system glass in a continuous rounded rectangle. The
    /// content is kept inside the shape. `shadow` is kept for existing call
    /// sites; the glass draws its own.
    func psCard(cornerRadius: CGFloat = PSTheme.panelRadius, shadow: Bool = true, variant: PSGlassVariant = .regular) -> some View {
        modifier(PSCardModifier(cornerRadius: cornerRadius, variant: variant))
    }

    /// Inset text-field surface: a darker well, no edge.
    func psField<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(Color.white.opacity(0.08)))
    }

    /// A control inside glass (chip, well): a plain fill, white when selected
    /// (the Photos filter-chip idiom; use black content on it).
    func psChipFill<S: Shape>(_ shape: S, isSelected: Bool = false) -> some View {
        background(shape.fill(isSelected ? Color.white : PSTheme.fill))
    }

    /// Edit-accent fill (the yellow "Done"): flat, like Photos. Content on it
    /// should use `PSTheme.onAccent`. `glow` is kept for existing call sites.
    func psAccentFill<S: Shape>(_ shape: S, glow: Bool = true) -> some View {
        background(shape.fill(PSTheme.accent))
    }

    /// The selected state of a neutral control: a lit thumb behind the label.
    func psActivePill<S: Shape>(_ shape: S, isActive: Bool, glow: Bool = true) -> some View {
        modifier(PSActivePillModifier(shape: AnyShape(shape), isActive: isActive))
    }

    /// Press feedback for any tappable view: a soft scale.
    func psPressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(PSPressStyle(scale: scale))
    }

    /// Intelligence-spectrum foreground for Magic glyphs and titles.
    func psIntelligenceForeground() -> some View {
        foregroundStyle(LinearGradient(colors: PSTheme.intelligence, startPoint: .leading, endPoint: .trailing))
    }
}

/// Which system glass a surface uses.
public enum PSGlassVariant: Sendable {
    /// Panels, docks, bars: frosted enough for text over anything.
    case regular
    /// Small controls floating over the photo: the picture shows through.
    case clear

    var glass: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

@available(iOS 26.0, *)
func psMakeGlass(tint: Color?, interactive: Bool, variant: PSGlassVariant = .regular) -> Glass {
    var glass = variant.glass
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

struct PSGlassModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let shape: AnyShape
    var variant: PSGlassVariant = .regular
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        if effects == .minimal {
            content.background(shape.fill(PSTheme.surfaceFlat)).overlay(shape.stroke(PSTheme.hairline, lineWidth: 1))
        } else {
            content.glassEffect(psMakeGlass(tint: tint, interactive: interactive, variant: variant), in: shape)
        }
    }
}

struct PSCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    var variant: PSGlassVariant = .regular
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The content is clipped, never the glass, so its rim stays whole.
        if effects == .minimal {
            content.clipShape(shape)
                .background(shape.fill(PSTheme.surfaceFlat))
                .overlay(shape.strokeBorder(PSTheme.hairline, lineWidth: 1))
        } else {
            content.clipShape(shape).glassEffect(variant.glass, in: shape)
        }
    }
}

struct PSActivePillModifier: ViewModifier {
    let shape: AnyShape
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background {
            if isActive { shape.fill(PSTheme.selection) }
        }
    }
}

/// Button style with the app's press feedback.
public struct PSPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    public init(scale: CGFloat = 0.96) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(PSMotion.quick, value: configuration.isPressed)
    }
}

/// Groups glass elements so they blend and morph together.
public struct PSGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}

/// Round glass button used across toolbars: the system `.glass` button in a
/// circle. `isActive` makes it `.glassProminent` in white with a dark glyph
/// (play, the primary action of a bar). `tint` colours the glyph of an
/// inactive button.
public struct GlassIconButton: View {
    let systemName: String
    let label: String
    var tint: Color?
    var isActive: Bool = false
    var size: CGFloat = 44
    var variant: PSGlassVariant = .regular
    let action: () -> Void
    @Environment(\.psEffects) private var effects

    public init(_ systemName: String, label: String, tint: Color? = nil, isActive: Bool = false, size: CGFloat = 44, variant: PSGlassVariant = .regular, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tint = tint
        self.isActive = isActive
        self.size = size
        self.variant = variant
        self.action = action
    }

    public var body: some View {
        Group {
            if effects == .minimal {
                Button(action: tap) {
                    glyph.background(Circle().fill(isActive ? Color.white : PSTheme.surfaceFlat))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
            } else if isActive {
                Button(action: tap) { glyph }
                    .buttonStyle(.glassProminent)
                    .tint(.white)
            } else if variant == .clear {
                Button(action: tap) {
                    glyph.glassEffect(psMakeGlass(tint: nil, interactive: true, variant: .clear), in: .circle)
                }
                .buttonStyle(PSPressStyle(scale: 0.94))
            } else {
                Button(action: tap) { glyph }
                    .buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.circle)
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    private var glyph: some View {
        Image(systemName: systemName)
            .font(.system(size: (size * 0.39).rounded(), weight: .medium))
            .foregroundStyle(isActive ? Color.black : (tint ?? PSTheme.textPrimary))
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
    }

    private func tap() {
        Haptics.tap()
        action()
    }
}

/// Small glass label chip for status over the canvas ("Original", "2.0×").
public struct GlassChip: View {
    let text: String
    var systemImage: String?
    var tint: Color?
    var variant: PSGlassVariant = .regular

    public init(_ text: String, systemImage: String? = nil, tint: Color? = nil, variant: PSGlassVariant = .regular) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.variant = variant
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(tint ?? PSTheme.textSecondary) }
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(PSTheme.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .psGlass(variant: variant)
    }
}

/// The one prominent action of a screen: the system `.glassProminent`
/// button in white with dark text, full width.
public struct PrimaryButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        PSSystemButton(configuration: configuration, kind: .primary)
    }
}

/// A secondary full-width action: the system `.glass` button.
public struct SecondaryButtonStyle: PrimitiveButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        PSSystemButton(configuration: configuration, kind: .secondary)
    }
}

/// A Magic action: a `.glass` button whose label icon is painted with the
/// spectrum (a MagicGlyph) and whose title stays white. Give it a `Label`
/// (usually `systemImage: "sparkles"`) so the glyph leads.
public struct MagicButtonStyle: PrimitiveButtonStyle {
    var compact = false
    public init(compact: Bool = false) { self.compact = compact }
    public func makeBody(configuration: Configuration) -> some View {
        PSSystemButton(configuration: configuration, kind: compact ? .magicCompact : .magic)
    }
}

/// The body shared by the app's button styles: a system glass button, or a
/// flat capsule at `.minimal` effects.
struct PSSystemButton: View {
    enum Kind { case primary, secondary, magic, magicCompact }

    let configuration: PrimitiveButtonStyleConfiguration
    let kind: Kind
    @Environment(\.psEffects) private var effects

    var body: some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(kind == .magicCompact ? PSFont.headline(13) : PSFont.headline())
                .modifier(PSMagicLabelModifier(isMagic: kind == .magic || kind == .magicCompact))
                .foregroundStyle(kind == .primary ? Color.black : PSTheme.textPrimary)
                .frame(maxWidth: kind == .magicCompact ? nil : .infinity)
        }
        if effects == .minimal {
            button.buttonStyle(PSFlatButtonStyle(fill: kind == .primary ? Color.white : PSTheme.surfaceFlat, compact: kind == .magicCompact))
        } else if kind == .primary {
            button.buttonStyle(.glassProminent).tint(.white).controlSize(.large)
        } else {
            button.buttonStyle(.glass).controlSize(kind == .magicCompact ? .regular : .large)
        }
    }
}

/// Paints a Magic label's icon with the spectrum; the title stays neutral.
struct PSMagicLabelModifier: ViewModifier {
    var isMagic: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isMagic { content.labelStyle(PSMagicLabelStyle()) } else { content }
    }
}

struct PSMagicLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.fontWeight(.medium).psIntelligenceForeground()
            configuration.title
        }
    }
}

/// Flat capsule for the `.minimal` effects level.
struct PSFlatButtonStyle: ButtonStyle {
    var fill: Color
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, compact ? 8 : 15)
            .padding(.horizontal, compact ? 14 : 16)
            .background(Capsule().fill(fill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(PSMotion.quick, value: configuration.isPressed)
    }
}
#endif
