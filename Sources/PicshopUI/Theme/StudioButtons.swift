#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// What a studio button is for.
public enum PSButtonKind: Sendable {
    /// Secondary actions: the system `.glass` button.
    case glass
    /// The one primary action of an area (Export, Send, Done): white prominent glass, black label.
    case prominent
    /// Ending something (the Live console's End): prominent glass tinted `liveEnd`, white glyph.
    case danger

    var foreground: Color {
        switch self {
        case .glass: return PSTheme.textPrimary
        case .prominent: return PSTheme.onPrimary
        case .danger: return .white
        }
    }

    var flatFill: Color {
        switch self {
        case .glass: return PSTheme.surfaceFlat
        case .prominent: return PSTheme.primary
        case .danger: return PSTheme.liveEnd
        }
    }
}

/// A round studio button: 44 points in bars, 52 in the dock. At `.minimal`
/// effects, or with Reduce Transparency, it becomes a flat disc and the layout
/// never moves. Plays `Haptics.tap`; callers add none.
public struct PSCircleButton: View {
    let systemImage: String
    let size: CGFloat
    let kind: PSButtonKind
    let label: String
    let action: () -> Void
    @Environment(\.psEffects) private var effects
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(systemImage: String, size: CGFloat = PSMetrics.barButton, kind: PSButtonKind = .glass, accessibilityLabel: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.size = size
        self.kind = kind
        self.label = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Group {
            if effects == .minimal || reduceTransparency {
                Button(action: tap) {
                    glyph.background(Circle().fill(kind.flatFill))
                        .overlay(Circle().strokeBorder(kind == .glass ? PSTheme.hairline : .clear, lineWidth: 1))
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
            } else {
                switch kind {
                case .glass:
                    Button(action: tap) { glyph }
                        .buttonStyle(.glass)
                case .prominent:
                    Button(action: tap) { glyph }
                        .buttonStyle(.glassProminent)
                        .tint(PSTheme.primary)
                case .danger:
                    Button(action: tap) { glyph }
                        .buttonStyle(.glassProminent)
                        .tint(PSTheme.liveEnd)
                }
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(size >= PSMetrics.dockButton ? .large : .regular)
        .frame(width: size, height: size)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: systemImage)
        }
    }

    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: (size * 0.39).rounded(), weight: kind == .glass ? .medium : .semibold))
            .foregroundStyle(kind.foreground)
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
    }

    private func tap() {
        Haptics.tap()
        action()
    }
}

/// A capsule studio button (Export, Send, the empty-state actions): 44 points
/// tall by default, `.subheadline` semibold. Plays `Haptics.confirm`.
public struct PSCapsuleButton: View {
    let title: String
    let systemImage: String?
    let height: CGFloat
    let kind: PSButtonKind
    let action: () -> Void
    @Environment(\.psEffects) private var effects
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(_ title: String, systemImage: String? = nil, height: CGFloat = PSMetrics.barButton, kind: PSButtonKind = .prominent, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.height = height
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        Group {
            if effects == .minimal || reduceTransparency {
                Button(action: tap) {
                    content
                        .padding(.horizontal, 16)
                        .frame(height: height)
                        .background(Capsule().fill(kind.flatFill))
                        .overlay(Capsule().strokeBorder(kind == .glass ? PSTheme.hairline : .clear, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
            } else {
                switch kind {
                case .glass:
                    Button(action: tap) { content.frame(maxHeight: .infinity) }
                        .buttonStyle(.glass)
                case .prominent:
                    Button(action: tap) { content.frame(maxHeight: .infinity) }
                        .buttonStyle(.glassProminent)
                        .tint(PSTheme.primary)
                case .danger:
                    Button(action: tap) { content.frame(maxHeight: .infinity) }
                        .buttonStyle(.glassProminent)
                        .tint(PSTheme.liveEnd)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .frame(height: height)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(kind.foreground)
        .lineLimit(1)
    }

    private func tap() {
        Haptics.confirm()
        action()
    }
}

/// The white action inside a panel or a sheet (Done, Apply, OK): a flat white
/// shape with a black label, since glass never sits on glass.
struct PSPanelPrimaryButton: View {
    let title: String?
    let systemImage: String?
    var height: CGFloat = 36
    var isEnabled = true
    let action: () -> Void

    /// A round, icon-only primary (the panel's Done): `height` wide too.
    init(systemImage: String, size: CGFloat = PSMetrics.barButton, accessibilityLabel: String, action: @escaping () -> Void) {
        self.title = nil
        self.systemImage = systemImage
        self.height = size
        self.accessibilityText = accessibilityLabel
        self.action = action
    }

    /// A capsule with a title and an optional leading symbol.
    init(_ title: String, systemImage: String? = nil, height: CGFloat = 36, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.height = height
        self.isEnabled = isEnabled
        self.accessibilityText = title
        self.action = action
    }

    private var accessibilityText: String

    var body: some View {
        Button {
            Haptics.confirm()
            action()
        } label: {
            label
        }
        .buttonStyle(PSPressStyle(scale: 0.94))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var label: some View {
        if let title {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PSTheme.onPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(Capsule().fill(PSTheme.primary))
            .contentShape(Capsule())
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: (height * 0.36).rounded(), weight: .bold))
                .foregroundStyle(PSTheme.onPrimary)
                .frame(width: height, height: height)
                .background(Circle().fill(PSTheme.primary))
                .contentShape(Circle())
        }
    }
}

extension View {
    /// The Ask field and idea chips: interactive regular glass in a capsule;
    /// a flat fill with a hairline at `.minimal` effects or with Reduce Transparency.
    func psGlassField() -> some View {
        psGlass(interactive: true, shape: AnyShape(Capsule()))
    }
}
#endif
