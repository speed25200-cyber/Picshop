#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Blocking progress overlay for long operations.
struct ProgressHUD: View {
    var title: String
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(PSTheme.accent)
                        .frame(width: 180)
                    Text("\(Int(progress * 100))%").font(PSFont.mono()).foregroundStyle(PSTheme.textSecondary)
                } else {
                    ProgressView().tint(PSTheme.textPrimary)
                }
                Text(title).font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                if let onCancel {
                    Button(L("Cancel"), action: onCancel).font(PSFont.caption(13)).foregroundStyle(PSTheme.textSecondary)
                }
            }
            .padding(24)
            .psGlassPanel(cornerRadius: 24)
        }
        .transition(.opacity)
    }
}

/// Transient message at the top of the editor.
struct ToastView: View {
    let text: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = PSTheme.success

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(PSFont.body(14)).foregroundStyle(PSTheme.textPrimary).lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .psGlass()
        .transition(.move(edge: .top).combined(with: .opacity))
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

extension View {
    /// Applies a transform when a condition is met.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
#endif
