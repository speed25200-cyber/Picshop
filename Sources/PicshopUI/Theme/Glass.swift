#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Liquid Glass surfaces and the handful of controls built from them.
///
/// Chrome is system glass (iOS 26), grouped in containers so neighbouring
/// pieces melt into each other and morph when they change. Every surface
/// reads `psEffects`: when the phone runs hot, shadows go first, then glass
/// becomes a flat fill — the layout never moves.
public extension View {
    @ViewBuilder
    func psGlass(tint: Color? = nil, interactive: Bool = false, shape: AnyShape = AnyShape(Capsule())) -> some View {
        modifier(PSGlassModifier(tint: tint, interactive: interactive, shape: shape))
    }

    @ViewBuilder
    func psGlassPanel(cornerRadius: CGFloat = PSTheme.panelRadius) -> some View {
        psCard(cornerRadius: cornerRadius)
    }

    /// A floating panel: glass, a faint lit edge and a soft shadow.
    func psCard(cornerRadius: CGFloat = PSTheme.panelRadius, shadow: Bool = true) -> some View {
        modifier(PSCardModifier(cornerRadius: cornerRadius, shadow: shadow))
    }

    /// Inset text-field surface: darker well with a faint edge.
    func psField<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(Color.white.opacity(0.07)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Edit-accent fill (the yellow "Done"). Content on it should use `PSTheme.onAccent`.
    func psAccentFill<S: Shape>(_ shape: S, glow: Bool = true) -> some View {
        modifier(PSAccentFillModifier(shape: AnyShape(shape), glow: glow))
    }

    /// The selected state of a neutral control: a lit glass thumb behind the label.
    func psActivePill<S: Shape>(_ shape: S, isActive: Bool, glow: Bool = true) -> some View {
        modifier(PSActivePillModifier(shape: AnyShape(shape), isActive: isActive))
    }

    /// Press feedback for any tappable view: a soft scale, spring-driven.
    func psPressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(PSPressStyle(scale: scale))
    }

    /// Intelligence-spectrum foreground for Magic glyphs and titles.
    func psIntelligenceForeground() -> some View {
        foregroundStyle(LinearGradient(colors: PSTheme.intelligence, startPoint: .leading, endPoint: .trailing))
    }
}

@available(iOS 26.0, *)
func psMakeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

struct PSGlassModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let shape: AnyShape
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        if effects == .minimal {
            content.background(shape.fill(PSTheme.surfaceFlat)).overlay(shape.stroke(PSTheme.hairline, lineWidth: 1))
        } else {
            if #available(iOS 26.0, *) {
                content.glassEffect(psMakeGlass(tint: tint, interactive: interactive), in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
    }
}

struct PSCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let shadow: Bool
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if effects == .minimal {
                content.background(shape.fill(PSTheme.surfaceFlat))
            } else if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(shape.fill(.ultraThinMaterial))
            }
        }
        .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 0.75))
        .clipShape(shape)
        .shadow(color: .black.opacity(shadow && effects == .rich ? 0.32 : 0), radius: 24, y: 12)
    }
}

struct PSAccentFillModifier: ViewModifier {
    let shape: AnyShape
    let glow: Bool
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        content
            .background(shape.fill(PSTheme.accentGradient).overlay(shape.fill(PSTheme.accentHighlight)))
            .shadow(color: PSTheme.accent.opacity(glow && effects == .rich ? 0.35 : 0), radius: 10, y: 3)
    }
}

struct PSActivePillModifier: ViewModifier {
    let shape: AnyShape
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                shape.fill(PSTheme.selection)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)))
                    .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.75))
            }
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

/// Groups glass elements so they morph/blend together on iOS 26.
public struct PSGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Round glass button used across toolbars. `isActive` makes it prominent:
/// a white disc with a dark glyph (play, the primary action of a bar).
public struct GlassIconButton: View {
    let systemName: String
    let label: String
    var tint: Color?
    var isActive: Bool = false
    var size: CGFloat = 44
    let action: () -> Void

    public init(_ systemName: String, label: String, tint: Color? = nil, isActive: Bool = false, size: CGFloat = 44, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.tint = tint
        self.isActive = isActive
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background {
                    if isActive { Circle().fill(Color.white) }
                }
                .contentShape(Circle())
                .modifier(ConditionalGlass(enabled: !isActive, shape: AnyShape(Circle())))
        }
        .buttonStyle(PSPressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// Glass only where it is wanted (a prominent disc is solid).
struct ConditionalGlass: ViewModifier {
    let enabled: Bool
    let shape: AnyShape

    func body(content: Content) -> some View {
        if enabled { content.psGlass(interactive: true, shape: shape) } else { content }
    }
}

/// Small rounded label chip.
public struct GlassChip: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    public init(_ text: String, systemImage: String? = nil, tint: Color? = nil) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(tint ?? PSTheme.textPrimary) }
            Text(text)
        }
        .font(PSFont.caption(13))
        .foregroundStyle(PSTheme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .psGlass()
    }
}

/// The one prominent action of a screen: a white capsule with dark text.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PSFont.headline())
            .foregroundStyle(Color.black)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().fill(LinearGradient(colors: [.clear, Color.black.opacity(0.06)], startPoint: .top, endPoint: .bottom)))
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(PSMotion.quick, value: configuration.isPressed)
    }
}

public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PSFont.headline())
            .foregroundStyle(PSTheme.textPrimary)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .psGlass(interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(PSMotion.quick, value: configuration.isPressed)
    }
}

/// A Magic action: an iridescent capsule for the things the AI does.
public struct MagicButtonStyle: ButtonStyle {
    var compact = false
    public init(compact: Bool = false) { self.compact = compact }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? PSFont.headline(13) : PSFont.headline())
            .foregroundStyle(.white)
            .padding(.vertical, compact ? 8 : 15)
            .padding(.horizontal, compact ? 14 : 0)
            .frame(maxWidth: compact ? nil : .infinity)
            .background {
                Capsule().fill(LinearGradient(colors: PSTheme.intelligence, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().fill(PSTheme.accentHighlight).opacity(0.6))
            }
            .shadow(color: PSTheme.voice.opacity(0.35), radius: 12, y: 4)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(PSMotion.quick, value: configuration.isPressed)
    }
}
#endif
