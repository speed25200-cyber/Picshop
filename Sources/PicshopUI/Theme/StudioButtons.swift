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
}

/// A round studio button: 44 points in bars, 52 in the dock. At `.minimal`
/// effects it becomes a flat disc and the layout never moves.
public struct PSCircleButton: View {
    let systemImage: String
    let size: CGFloat
    let kind: PSButtonKind
    let label: String
    let action: () -> Void
    @Environment(\.psEffects) private var effects

    public init(systemImage: String, size: CGFloat = PSMetrics.barButton, kind: PSButtonKind = .glass, accessibilityLabel: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.size = size
        self.kind = kind
        self.label = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Group {
            if effects == .minimal {
                Button(action: tap) {
                    glyph.background(Circle().fill(flatFill))
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
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    private var glyph: some View {
        Image(systemName: systemImage)
            .font(.system(size: (size * 0.39).rounded(), weight: .medium))
            .foregroundStyle(glyphColor)
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
    }

    private var glyphColor: Color {
        switch kind {
        case .glass: return PSTheme.textPrimary
        case .prominent: return PSTheme.onPrimary
        case .danger: return .white
        }
    }

    private var flatFill: Color {
        switch kind {
        case .glass: return PSTheme.surfaceFlat
        case .prominent: return PSTheme.primary
        case .danger: return PSTheme.liveEnd
        }
    }

    private func tap() {
        Haptics.tap()
        action()
    }
}

/// A capsule studio button (Export, Send, the empty-state actions): 44 points
/// tall by default, `.subheadline` semibold.
public struct PSCapsuleButton: View {
    let title: String
    let systemImage: String?
    let height: CGFloat
    let kind: PSButtonKind
    let action: () -> Void
    @Environment(\.psEffects) private var effects

    public init(_ title: String, systemImage: String? = nil, height: CGFloat = PSMetrics.barButton, kind: PSButtonKind = .prominent, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.height = height
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        Group {
            if effects == .minimal {
                Button(action: tap) {
                    content
                        .padding(.horizontal, 16)
                        .frame(height: height)
                        .background(Capsule().fill(flatFill))
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
        .foregroundStyle(labelColor)
        .lineLimit(1)
    }

    private var labelColor: Color {
        switch kind {
        case .glass: return PSTheme.textPrimary
        case .prominent: return PSTheme.onPrimary
        case .danger: return .white
        }
    }

    private var flatFill: Color {
        switch kind {
        case .glass: return PSTheme.surfaceFlat
        case .prominent: return PSTheme.primary
        case .danger: return PSTheme.liveEnd
        }
    }

    private func tap() {
        Haptics.confirm()
        action()
    }
}

extension View {
    /// The Ask field and idea chips: interactive regular glass in a capsule;
    /// a flat fill with a hairline at `.minimal` effects.
    func psGlassField() -> some View {
        psGlass(interactive: true, shape: AnyShape(Capsule()))
    }
}
#endif
