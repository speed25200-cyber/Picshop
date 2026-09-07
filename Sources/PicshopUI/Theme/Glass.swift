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
        psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
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
                .foregroundStyle(isActive ? Color.black : PSTheme.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .psGlass(tint: isActive ? (tint ?? PSTheme.accent) : nil, interactive: true, shape: AnyShape(Circle()))
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
        .foregroundStyle(tint == nil ? PSTheme.textPrimary : Color.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .psGlass(tint: tint)
    }
}

public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PSFont.headline())
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(PSTheme.accent, in: Capsule())
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
