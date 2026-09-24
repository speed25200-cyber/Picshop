#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopIntent

/// Adjustments the way Photos does them: one row of round controls that
/// snaps the chosen one to the centre, each ring showing its value in
/// yellow, and the ruler dial underneath. Scroll to choose, drag to set.
///
/// A drag re-evaluates only the dial and the ring being dragged: the dial's
/// value lives in its own leaf, and the dragged ring reads `session.dial`
/// while the document stays as it was until the drag ends.
struct AdjustPanel: View {
    @Bindable var session: PhotoEditorSession
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
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let selected = session.selectedParameter
        VStack(spacing: 12) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(Self.order) { parameter in
                            AdjustRing(session: session, parameter: parameter, isSelected: selected == parameter)
                                .id(parameter)
                                .onTapGesture {
                                    Haptics.tick()
                                    withAnimation(PSMotion.standard) { centered = parameter }
                                }
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

            AdjustDial(session: session, parameter: selected)

            HStack(spacing: 8) {
                PanelChip(title: L("Auto"), symbol: "wand.and.stars", tint: PSTheme.voice) { session.perform(EditIntent(action: .autoEnhance)) }
                PanelChip(title: L("Portrait light"), symbol: "lightbulb.max") { session.perform(EditIntent(action: .relight)) }
                Spacer()
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: session.modifiedTools.contains(.adjust)) {
                    session.apply(.adjustments(.neutral), label: L("Reset"))
                }
            }
        }
        .onChange(of: centered) { _, parameter in
            guard let parameter, parameter != session.selectedParameter else { return }
            Haptics.tick()
            session.selectedParameter = parameter
        }
        .onChange(of: session.selectedParameter) { _, parameter in
            if centered != parameter { withAnimation(PSMotion.standard) { centered = parameter } }
        }
        .onAppear { centered = session.selectedParameter }
    }

    static func name(_ parameter: AdjustmentParameter) -> String {
        psPrefersFrench ? parameter.frenchName : parameter.englishName
    }
}

/// The ruler dial for one parameter. Owns the dragged value, so a drag
/// re-evaluates this leaf and the dial, not the panel. It reloads from the
/// document when the parameter or the document changes.
private struct AdjustDial: View {
    let session: PhotoEditorSession
    let parameter: AdjustmentParameter
    @State private var value: Double = 0

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        DialSlider(value: $value, range: parameter.range, neutral: 0, label: AdjustPanel.name(parameter), onEditingChanged: { editing in
            if editing { session.beginSliderInteraction(parameter) } else { session.endSliderInteraction() }
        })
        .onChange(of: value) { _, newValue in
            if abs(newValue - session.adjustmentValue(parameter)) > 0.0005 {
                session.setAdjustment(parameter, value: newValue)
            }
        }
        .onChange(of: parameter) { _, parameter in value = session.adjustmentValue(parameter) }
        .onChange(of: session.revision) { _, _ in
            // Undo, a voice edit or Reset: follow the document unless a drag is under way.
            guard session.dial.parameter == nil else { return }
            let current = session.adjustmentValue(parameter)
            if abs(current - value) > 0.0005 { value = current }
        }
        .onAppear { value = session.adjustmentValue(parameter) }
    }
}

/// One ring in the carousel. The ring under the dial reads the dial's live
/// value while it is dragged; the others read the document.
private struct AdjustRing: View {
    let session: PhotoEditorSession
    let parameter: AdjustmentParameter
    let isSelected: Bool

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let dial = session.dial
        let isDragged = dial.parameter == parameter
        let value = isDragged ? dial.value : session.adjustmentValue(parameter)
        ValueRing(parameter: parameter, value: value, isSelected: isSelected, isDragging: isDragged)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AdjustPanel.name(parameter))
            .accessibilityValue(ValueRing.formatted(value))
            .accessibilityAddTraits(.isButton)
    }
}

/// One round control: the parameter's glyph inside a ring that fills in
/// yellow with the value (clockwise up, counter-clockwise down). The chosen
/// one grows a white outline and shows its number.
struct ValueRing: View {
    let parameter: AdjustmentParameter
    let value: Double
    let isSelected: Bool
    /// Under the finger: no numeric animation, each tick would start one.
    var isDragging = false

    private var isSet: Bool { abs(value) > 0.0005 }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(isSelected ? 0.14 : 0.08))
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 2)
            if isSet {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, abs(value))))
                    .stroke(PSTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: value < 0 ? -1 : 1)
            }
            if isSelected && isSet {
                Text(Self.formatted(value)).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(PSTheme.accent)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
            } else {
                Image(systemName: parameter.symbolName)
                    .font(.system(size: 17, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isSet ? PSTheme.accent : PSTheme.textSecondary))
            }
        }
        .frame(width: 46, height: 46)
        .overlay(Circle().strokeBorder(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5).padding(-4))
        .animation(PSMotion.quick, value: isSelected)
        .animation(isDragging ? nil : PSMotion.numeric, value: value)
        .padding(.vertical, 6)
        .contentShape(Circle())
    }

    static func formatted(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
}
#endif
