#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Blocking progress overlay for long operations: a small glass tile in the
/// centre, the rest of the screen dimmed but still visible.
struct ProgressHUD: View {
    var title: String
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(PSTheme.hairline, lineWidth: 4).frame(width: 46, height: 46)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                            .stroke(PSTheme.accentGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 46, height: 46)
                            .animation(PSMotion.numeric, value: progress)
                        Text("\(Int(progress * 100))").font(PSFont.mono(12)).foregroundStyle(PSTheme.textPrimary).contentTransition(.numericText())
                    } else {
                        ProgressView().tint(PSTheme.textPrimary).controlSize(.regular)
                    }
                }
                Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).multilineTextAlignment(.center).lineLimit(2)
                if let onCancel {
                    Button(L("Cancel"), action: onCancel).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(minWidth: 168)
            .psCard(cornerRadius: PSRadius.panel)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

/// Transient message at the top of the editor, shaped like a Dynamic Island pill.
struct ToastView: View {
    let text: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = PSTheme.success

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(text).font(PSFont.body(14)).foregroundStyle(PSTheme.textPrimary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .psCard(cornerRadius: 24, shadow: true)
        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .top)))
    }
}

/// Horizontal value slider with a centred zero for bipolar parameters.
struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var bipolar = true
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
                Spacer()
                Text(value >= 0 && bipolar ? "+\(Int((value * 100).rounded()))" : "\(Int((value * 100).rounded()))")
                    .font(PSFont.mono(12)).foregroundStyle(PSTheme.textPrimary)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
                if !editing { Haptics.tick() }
            }
            .tint(PSTheme.accent)
        }
    }
}

/// Section title used on the library and settings screens.
struct SectionTitle: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(PSFont.title(22)).foregroundStyle(PSTheme.textPrimary).tracking(-0.4)
            if let count {
                Text("\(count)").font(PSFont.mono(12)).foregroundStyle(PSTheme.textTertiary).contentTransition(.numericText())
            }
            Spacer()
        }
    }
}

extension View {
    /// Applies a transform when a condition is met.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
#endif
