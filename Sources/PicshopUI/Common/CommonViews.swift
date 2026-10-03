#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Blocking progress overlay for long, non-cancellable work (export,
/// import): a glass tile in the centre and nothing else, so the picture stays
/// fully visible. Touches are still held off the screen below.
///
/// `.intelligence` (AI work) draws a spectrum ring and a shimmering title;
/// `.neutral` (export, import) stays white.
struct ProgressHUD: View {
    enum Tone { case intelligence, neutral }

    var title: String
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil
    var tone: Tone = .intelligence

    var body: some View {
        ZStack {
            // Invisible, but it catches touches while the work runs.
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
            VStack(spacing: PSSpacing.medium) {
                ring
                if tone == .intelligence {
                    ShimmerText(title, font: PSFont.control(selected: true))
                        .multilineTextAlignment(.center)
                } else {
                    Text(title).font(PSFont.control(selected: true)).foregroundStyle(Color.psTextPrimary)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                if let onCancel {
                    Button(L("Cancel"), action: onCancel).font(PSFont.footnote()).foregroundStyle(Color.psTextSecondary)
                }
            }
            .padding(.horizontal, PSSpacing.xLarge)
            .padding(.vertical, PSSpacing.mediumLarge)
            .frame(minWidth: 168, maxWidth: 280)
            .psCard(cornerRadius: PSRadius.card)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.psStrokeStrong, lineWidth: 3.5)
            if let progress {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, min(1, progress))))
                    .stroke(ringStyle, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(PSMotion.numeric, value: progress)
                Text("\(Int(progress * 100))").font(PSFont.rounded(13)).foregroundStyle(Color.psTextPrimary).contentTransition(.numericText())
            } else if tone == .intelligence {
                MagicGlyph(size: 18).symbolEffect(.pulse)
            } else {
                ProgressView().tint(Color.psTextPrimary)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var ringStyle: AnyShapeStyle {
        tone == .intelligence
            ? AnyShapeStyle(AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center))
            : AnyShapeStyle(Color.psTextPrimary)
    }
}

/// Transient message under the top bar: a 44-point glass capsule, like a
/// Dynamic Island notice.
struct ToastView: View {
    let text: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = Color.psSuccess
    /// When set, the toast offers a one-tap follow-up right there, like Undo in Mail after an archive.
    var action: Action? = nil

    struct Action {
        let title: String
        let symbol: String
        let run: () -> Void
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(PSFont.glyph(.bar))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(text).font(PSFont.control()).foregroundStyle(Color.psTextPrimary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let action {
                Button {
                    Haptics.tap()
                    action.run()
                } label: {
                    // Concentric with the toast: 44 − 2 × 6.
                    Label(action.title, systemImage: action.symbol)
                        .font(PSFont.control(selected: true))
                        .foregroundStyle(Color.psTextPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .psChipFill(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PSPressStyle(scale: 0.94))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, action == nil ? 18 : 6)
        .padding(.vertical, 6)
        .frame(minHeight: PSMetrics.control)
        .psGlass()
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Horizontal value slider with a centred zero for bipolar parameters.
@available(*, deprecated, message: "Use DialSlider, or InspectorRow in the inspector.")
struct ParameterSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var bipolar = true
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(PSFont.footnote()).foregroundStyle(Color.psTextSecondary)
                Spacer()
                Text(value >= 0 && bipolar ? "+\(Int((value * 100).rounded()))" : "\(Int((value * 100).rounded()))")
                    .font(PSFont.mono(12)).foregroundStyle(Color.psTextPrimary)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
                if !editing { Haptics.tick() }
            }
            .tint(Color.psValueAccent)
        }
    }
}

/// Section title used on the library and settings screens.
struct SectionTitle: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(PSFont.section()).foregroundStyle(Color.psTextPrimary)
            if let count {
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(Color.psTextTertiary).contentTransition(.numericText())
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
