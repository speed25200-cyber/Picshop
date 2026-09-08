#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Liquid Glass helpers. The system glass is used on iOS 26; the material
/// fallback keeps previews and older simulators rendering.
public extension View {
    @ViewBuilder
    func psGlass(tint: Color? = nil, interactive: Bool = false, shape: AnyShape = AnyShape(Capsule())) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func psGlassPanel(cornerRadius: CGFloat = PSTheme.panelRadius) -> some View {
        psCard(cornerRadius: cornerRadius)
    }

    /// Layered surface: glass, a top sheen, a lit edge and a soft drop shadow.
    /// The look of every panel, dock and card in the app.
    func psCard(cornerRadius: CGFloat = PSTheme.panelRadius, shadow: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    if #available(iOS 26.0, *) {
                        Color.clear.glassEffect(.regular, in: shape)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(PSTheme.sheen)
                }
            }
            .overlay(shape.strokeBorder(PSTheme.strokeGradient, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 18, y: 10)
    }

    /// Inset text-field surface: darker well with a faint edge.
    func psField<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Color.black.opacity(0.28)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// Solid accent fill for primary actions: gradient, top highlight, glow.
    func psAccentFill<S: Shape>(_ shape: S, glow: Bool = true) -> some View {
        background(shape.fill(PSTheme.accentGradient).overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))))
            .shadow(color: PSTheme.accent.opacity(glow ? 0.4 : 0), radius: 10, y: 4)
    }

    /// Gradient pill with a glow, for the selected state of docks and chips.
    func psActivePill<S: Shape>(_ shape: S, isActive: Bool, glow: Bool = true) -> some View {
        background {
            if isActive {
                shape.fill(PSTheme.accentGradient)
                    .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)))
                    .shadow(color: PSTheme.accent.opacity(glow ? 0.45 : 0), radius: 10, y: 4)
            }
        }
    }
}

@available(iOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
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
        }
        .buttonStyle(.plain)
        .psGlass(tint: nil, interactive: true, shape: AnyShape(Circle()))
        .psActivePill(Circle(), isActive: isActive)
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
            .background(Capsule().fill(PSTheme.accentGradient).overlay(Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))))
            .shadow(color: PSTheme.accent.opacity(0.4), radius: 14, y: 6)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
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
    }
}
#endif
