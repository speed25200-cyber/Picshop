#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// The one value control (ux-spec §4.6). It replaces InspectorRow, InspectorSliderRow, ParameterSlider, the system
/// Slider in sheets and LuminanceSlider once their screens move to UX 2.0.
///
/// ```
///  Exposition                                  +0,30
///  ───────────────────────●━━━━━━━━━━│        track 4 pt, thumb 24 pt, fill from neutral (yellow)
/// ```
/// - The value is monospaced, yellow off neutral; a tap on it opens a numeric entry (stepper, min/max, ✓).
/// - Drag the thumb (absolute) or anywhere on the track (relative); hold still 0.5 s while dragging for the fine
///   mode (×0.25, « Réglage fin »). A double tap resets (twin: « Réinitialiser » in the panel's row B).
/// - Haptics: selection per unit step, medium at neutral, rigid at the limits.
/// - VoiceOver: adjustable by one step; custom action « Saisir une valeur ».
///
/// Bind it to a leaf's state, never to a session mirror read by the editor's body: only this view and its binding
/// should re-evaluate per frame while dragging.
struct PSSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double
    /// One unit (haptic tick, VoiceOver step, the entry's stepper); a hundredth of the range by default.
    var step: Double?
    var controlID: String
    var format: (Double) -> String
    var onEditingChanged: ((Bool) -> Void)?

    @State private var drag: DragState?
    @State private var showsEntry = false
    @State private var lastTick = 0

    init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, neutral: Double = 0, step: Double? = nil,
         controlID: String = "", format: @escaping (Double) -> String = PSSlider.signed, onEditingChanged: ((Bool) -> Void)? = nil) {
        self.label = label
        _value = value
        self.range = range
        self.neutral = neutral
        self.step = step
        self.controlID = controlID
        self.format = format
        self.onEditingChanged = onEditingChanged
    }

    /// « +0,30 », « −0,15 », « 0,00 » in the person's locale (true minus sign).
    static func signed(_ value: Double) -> String {
        let magnitude = abs(value).formatted(.number.precision(.fractionLength(2)))
        if value > 0.0049 { return "+" + magnitude }
        if value < -0.0049 { return "\u{2212}" + magnitude }
        return magnitude
    }

    /// « 42 % » for 0…1 values.
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    private var unit: Double { step ?? max((range.upperBound - range.lowerBound) / 100, .ulpOfOne) }
    private var isOffNeutral: Bool { abs(value - neutral) > unit / 2 }

    var body: some View {
        VStack(spacing: PSSpacing.xSmall) {
            header
            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(value + unit, haptic: false)
            case .decrement: set(value - unit, haptic: false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text(L("Enter a value"))) { showsEntry = true }
        .uxProbe(id: controlID.isEmpty ? "slider.\(label)" : controlID)
        .sheet(isPresented: $showsEntry) {
            PSSliderEntrySheet(label: label, value: $value, range: range, step: unit, format: format, onEditingChanged: onEditingChanged)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PSSpacing.small) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.psTextSecondary)
                .lineLimit(1)
            if drag?.isFine == true {
                Text(L("Fine adjustment"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.psOnValueAccent)
                    .padding(.horizontal, PSSpacing.xSmall + 2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.psValueAccent))
                    .transition(.opacity)
            }
            Spacer(minLength: PSSpacing.small)
            Button {
                showsEntry = true
            } label: {
                Text(format(value))
                    .font(PSFontRole.valueReadout)
                    .foregroundStyle(isOffNeutral ? Color.psValueAccent : Color.psTextPrimary)
                    .contentTransition(.numericText())
                    .frame(minHeight: PSMetrics.hitMinimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PSPressStyle(scale: 0.95))
        }
        .animation(PSSpring.quick, value: drag?.isFine == true)
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - PSMetrics.sliderThumb)
            let x = position(of: value, width: width)
            let neutralX = position(of: neutral, width: width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.psFillControl)
                    .frame(height: PSMetrics.sliderTrack)
                    .padding(.horizontal, PSMetrics.sliderThumb / 2)
                Capsule()
                    .fill(Color.psValueAccent)
                    .frame(width: abs(x - neutralX), height: PSMetrics.sliderTrack)
                    .offset(x: PSMetrics.sliderThumb / 2 + min(x, neutralX))
                    .opacity(isOffNeutral ? 1 : 0)
                Circle()
                    .fill(Color.psActionPrimary)
                    .frame(width: PSMetrics.sliderThumb, height: PSMetrics.sliderThumb)
                    .shadow(color: Color.psScrim, radius: 2, y: 1)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
            // twin: panel.reset
            .onTapGesture(count: 2) { reset() }
        }
        .frame(height: PSMetrics.hitMinimum)
    }

    private func position(of value: Double, width: CGFloat) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span) * width
    }

    private struct DragState {
        var startValue: Double
        var startX: CGFloat
        /// Started on the thumb: the value follows the finger.
        var isAbsolute: Bool
        var lastX: CGFloat
        var lastMove: Date
        var isFine = false
        var anchorValue: Double = 0
        var anchorX: CGFloat = 0
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let thumbCentre = position(of: value, width: width) + PSMetrics.sliderThumb / 2
                var state = drag ?? DragState(startValue: value, startX: gesture.startLocation.x,
                                              isAbsolute: abs(gesture.startLocation.x - thumbCentre) <= PSMetrics.hitMinimum / 2,
                                              lastX: gesture.startLocation.x, lastMove: Date())
                if drag == nil {
                    lastTick = Int(((value - neutral) / unit).rounded())
                    Haptics.prepare()
                    onEditingChanged?(true)
                }
                let now = Date()
                if abs(gesture.location.x - state.lastX) > 1.5 {
                    if !state.isFine, now.timeIntervalSince(state.lastMove) >= 0.5 {
                        state.isFine = true
                        state.anchorValue = value
                        state.anchorX = state.lastX
                        Haptics.tick()
                    }
                    state.lastMove = now
                    state.lastX = gesture.location.x
                }
                let span = range.upperBound - range.lowerBound
                let next: Double
                if state.isFine {
                    next = state.anchorValue + Double((gesture.location.x - state.anchorX) / width) * span * 0.25
                } else if state.isAbsolute {
                    next = range.lowerBound + Double((gesture.location.x - PSMetrics.sliderThumb / 2) / width) * span
                } else {
                    next = state.startValue + Double((gesture.location.x - state.startX) / width) * span
                }
                drag = state
                set(next, haptic: true)
            }
            .onEnded { _ in
                drag = nil
                onEditingChanged?(false)
            }
    }

    private func set(_ proposed: Double, haptic: Bool) {
        let clamped = min(max(proposed, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        guard haptic else { return }
        let tick = Int(((clamped - neutral) / unit).rounded())
        guard tick != lastTick else { return }
        lastTick = tick
        if clamped == range.lowerBound || clamped == range.upperBound {
            Haptics.heavy()
        } else if tick == 0 {
            Haptics.confirm()
        } else {
            Haptics.tick()
        }
    }

    private func reset() {
        Haptics.confirm()
        onEditingChanged?(true)
        withAnimation(PSSpring.quick) { value = min(max(neutral, range.lowerBound), range.upperBound) }
        onEditingChanged?(false)
    }
}

/// Typing a value (§4.6): the field, a stepper, the range, and ✓.
private struct PSSliderEntrySheet: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onEditingChanged: ((Bool) -> Void)?

    @State private var draft: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(label, value: $draft, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .font(PSFontRole.valueReadout)
                    Stepper(value: $draft, in: range, step: step) {
                        Text(format(draft))
                            .font(PSFontRole.valueReadout)
                    }
                } footer: {
                    Text(String(format: L("From %@ to %@"), format(range.lowerBound), format(range.upperBound)))
                }
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L("Close"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onEditingChanged?(true)
                        value = min(max(draft, range.lowerBound), range.upperBound)
                        onEditingChanged?(false)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(L("OK"))
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { draft = value }
    }
}
#endif
