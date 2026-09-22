#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Adjustments the way Photos does them: one row of round controls that
/// snaps the chosen one to the centre, each ring showing its value in
/// yellow, and the ruler dial underneath. Scroll to choose, drag to set.
struct AdjustPanel: View {
    @Bindable var session: PhotoEditorSession
    @State private var value: Double = 0
    @State private var centered: AdjustmentParameter?

    /// Photos' order: light first, then colour, then detail and effects.
    static let order: [AdjustmentParameter] = [
        .exposure, .brightness, .highlights, .shadows, .contrast, .whites, .blacks,
        .saturation, .vibrance, .temperature, .tint, .skinTone, .hue,
        .sharpness, .clarity, .noiseReduction, .vignette, .grain, .fade,
    ]

    private let itemSize: CGFloat = 46
    private let spacing: CGFloat = 14

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(Self.order) { parameter in
                            ValueRing(parameter: parameter, value: session.adjustmentValue(parameter), isSelected: session.selectedParameter == parameter)
                                .id(parameter)
                                .onTapGesture {
                                    Haptics.tick()
                                    withAnimation(PSMotion.standard) { centered = parameter }
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Self.name(parameter))
                                .accessibilityValue(String(Int((session.adjustmentValue(parameter) * 100).rounded())))
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, max(0, (proxy.size.width - itemSize) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centered, anchor: .center)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(height: itemSize + 12)

            DialSlider(value: $value, range: session.selectedParameter.range, neutral: 0, label: Self.name(session.selectedParameter)) { editing in
                if editing { session.beginSliderInteraction(session.selectedParameter) } else { session.endSliderInteraction() }
            }

            HStack(spacing: 8) {
                PanelChip(title: L("Auto"), symbol: "wand.and.stars", tint: PSTheme.voice) { session.perform(EditIntent(action: .autoEnhance)) }
                PanelChip(title: L("Portrait light"), symbol: "lightbulb.max") { session.perform(EditIntent(action: .relight)) }
                Spacer()
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !session.document.activeAdjustments.isNeutral) {
                    session.apply(.adjustments(.neutral), label: L("Reset"))
                    value = 0
                }
            }
        }
        .onChange(of: value) { _, newValue in
            if abs(newValue - session.adjustmentValue(session.selectedParameter)) > 0.0005 {
                session.setAdjustment(session.selectedParameter, value: newValue)
            }
        }
        .onChange(of: centered) { _, parameter in
            guard let parameter, parameter != session.selectedParameter else { return }
            Haptics.tick()
            session.selectedParameter = parameter
        }
        .onChange(of: session.selectedParameter) { _, parameter in
            value = session.adjustmentValue(parameter)
            if centered != parameter { withAnimation(PSMotion.standard) { centered = parameter } }
        }
        .onChange(of: session.history.present.modifiedAt) { _, _ in
            let current = session.adjustmentValue(session.selectedParameter)
            if abs(current - value) > 0.0005 { value = current }
        }
        .onAppear {
            value = session.adjustmentValue(session.selectedParameter)
            centered = session.selectedParameter
        }
    }

    static func name(_ parameter: AdjustmentParameter) -> String {
        psPrefersFrench ? parameter.frenchName : parameter.englishName
    }
}

/// One round control: the parameter's glyph inside a ring that fills in
/// yellow with the value (clockwise up, counter-clockwise down). The chosen
/// one grows a white outline and shows its number.
struct ValueRing: View {
    let parameter: AdjustmentParameter
    let value: Double
    let isSelected: Bool

    private var isSet: Bool { abs(value) > 0.0005 }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(isSelected ? 0.14 : 0.06))
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
            if isSet {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, abs(value))))
                    .stroke(PSTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: value < 0 ? -1 : 1)
            }
            if isSelected && isSet {
                Text(Self.formatted(value)).font(PSFont.mono(12).weight(.semibold)).foregroundStyle(PSTheme.accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
            } else {
                Image(systemName: parameter.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : (isSet ? PSTheme.accent : PSTheme.textSecondary))
            }
        }
        .frame(width: 46, height: 46)
        .overlay(Circle().strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5).padding(-4))
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(PSMotion.quick, value: isSelected)
        .animation(PSMotion.numeric, value: value)
        .padding(.vertical, 6)
        .contentShape(Circle())
    }

    static func formatted(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
}
#endif
