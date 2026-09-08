#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Liquid Glass helpers. The system glass is used on iOS 26; the material
/// fallback keeps previews and older simulators rendering. Every surface
/// reads `psEffects`, so when the phone runs hot the glow and shadows go
/// first and the layout never changes.
public extension View {
    @ViewBuilder
    func psGlass(tint: Color? = nil, interactive: Bool = false, shape: AnyShape = AnyShape(Capsule())) -> some View {
        modifier(PSGlassModifier(tint: tint, interactive: interactive, shape: shape))
    }

    @ViewBuilder
    func psGlassPanel(cornerRadius: CGFloat = PSTheme.panelRadius) -> some View {
        psCard(cornerRadius: cornerRadius)
    }

    /// Layered surface: glass, a top sheen, a lit edge and a soft drop shadow.
    /// The look of every panel, dock and card in the app.
    func psCard(cornerRadius: CGFloat = PSTheme.panelRadius, shadow: Bool = true) -> some View {
        modifier(PSCardModifier(cornerRadius: cornerRadius, shadow: shadow))
    }

    /// Inset text-field surface: darker well with a faint edge.
    func psField<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(Color.black.opacity(0.28)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// Solid accent fill for primary actions: gradient, top highlight, glow.
    func psAccentFill<S: Shape>(_ shape: S, glow: Bool = true) -> some View {
        modifier(PSAccentFillModifier(shape: AnyShape(shape), glow: glow))
    }

    /// Gradient pill with a glow, for the selected state of docks and chips.
    func psActivePill<S: Shape>(_ shape: S, isActive: Bool, glow: Bool = true) -> some View {
        modifier(PSActivePillModifier(shape: AnyShape(shape), isActive: isActive, glow: glow))
    }

    /// Press feedback for any tappable view: a soft scale and dim, spring-driven.
    func psPressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(PSPressStyle(scale: scale))
    }
}

@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
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
                content.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
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
        content
            .background {
                ZStack {
                    if effects == .minimal {
                        shape.fill(PSTheme.surfaceFlat)
                    } else {
                        if #available(iOS 26.0, *) {
                            Color.clear.glassEffect(.regular, in: shape)
                        } else {
                            shape.fill(.ultraThinMaterial)
                        }
                        shape.fill(PSTheme.sheen)
                    }
                }
            }
            .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(shadow && effects == .rich ? 0.35 : 0), radius: 18, y: 10)
    }
}

struct PSAccentFillModifier: ViewModifier {
    let shape: AnyShape
    let glow: Bool
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        content
            .background(shape.fill(PSTheme.accentGradient).overlay(shape.fill(PSTheme.accentHighlight)))
            .shadow(color: PSTheme.accent.opacity(glow && effects == .rich ? 0.4 : 0), radius: 10, y: 4)
    }
}

struct PSActivePillModifier: ViewModifier {
    let shape: AnyShape
    let isActive: Bool
    let glow: Bool
    @Environment(\.psEffects) private var effects

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                shape.fill(PSTheme.accentGradient)
                    .overlay(shape.fill(PSTheme.accentHighlight))
                    .shadow(color: PSTheme.accent.opacity(glow && effects == .rich ? 0.45 : 0), radius: 10, y: 4)
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

/// Rounded glass button used across toolbars.
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
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : PSTheme.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .psGlass(tint: nil, interactive: true, shape: AnyShape(Circle()))
                .psActivePill(Circle(), isActive: isActive)
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
        .accessibilityLabel(label)
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
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(PSFont.caption(13))
        .foregroundStyle(tint == nil ? PSTheme.textPrimary : Color.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .psGlass(tint: nil)
        .psActivePill(Capsule(), isActive: tint != nil, glow: false)
    }
}

public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PSFont.headline())
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .psAccentFill(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
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
#endif
