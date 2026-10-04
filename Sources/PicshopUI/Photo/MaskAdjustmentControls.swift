#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// What the selected mask does (W2): a dial for every adjustment but vignette, in Réglages' order and with their
/// French names (« Chaleur », « Luminosité », « Nuance », « Teint »…), then « Quantité », « Couleur » (one wheel),
/// « Courbe » (Curves' graph and presets) and « TSL » (the colour mixer's bands). A voice edit to any of them shows
/// here, and every control is in MaskPanelInventory.
///
/// The dials are Réglages' carousel and ruler: a drag re-evaluates the dragged ring and the dial only (the ring
/// reads `session.dial`, group "mask"), and is one undo step.
struct MaskAdjustmentControls: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment

    @State private var centered: AdjustmentParameter?
    @State private var parameter: AdjustmentParameter = .exposure

    private var expanded: Set<String> { session.maskState.expanded }

    var body: some View {
        VStack(spacing: PSSpacing.medium) {
            ParameterCarousel(parameters: MaskAccessibility.dialOrder, centered: $centered) { item in
                MaskRing(session: session, adjustment: adjustment, parameter: item, isSelected: item == parameter)
            }
            MaskDial(session: session, adjustment: adjustment, parameter: parameter)
            InspectorSliderRow(label: L("Amount"), value: adjustment.amount, range: 0...1, neutral: 1, controlID: "masks.amount",
                               format: { "\(Int(($0 * 100).rounded())) %" },
                               onBegin: { session.beginMaskInteraction() },
                               onChange: { session.setMaskAmount($0) },
                               onEnd: { session.endMaskInteraction() })
            section("color", title: L("Colour"), isSet: !(adjustment.grade?.isNeutral ?? true)) {
                MaskColorRow(session: session, adjustment: adjustment)
            }
            section("curve", title: L("Curve"), isSet: !(adjustment.curve?.isIdentity ?? true)) {
                MaskCurveRow(session: session, adjustment: adjustment)
            }
            section("hsl", title: L("HSL"), isSet: !(adjustment.mixer?.isNeutral ?? true)) {
                BandMixerControls(mixer: adjustment.mixer ?? .neutral,
                                  onMixer: { session.setMaskMixer($0) },
                                  onBegin: { _ in session.beginMaskInteraction() },
                                  onEnd: { session.endMaskInteraction() },
                                  label: PhotoEditorSession.masksLabel)
            }
        }
        .onChange(of: centered) { _, value in
            guard let value, value != parameter else { return }
            Haptics.tick()
            parameter = value
        }
        .onAppear { centered = parameter }
    }

    /// A collapsible row: its title (a yellow dot when it changes the picture) and, opened, its controls.
    @ViewBuilder
    private func section<Content: View>(_ id: String, title: String, isSet: Bool, @ViewBuilder content: () -> Content) -> some View {
        let isOpen = expanded.contains(id)
        VStack(spacing: PSSpacing.small) {
            Button {
                Haptics.tick()
                withAnimation(PSSpring.quick) {
                    if isOpen { session.maskState.expanded.remove(id) } else { session.maskState.expanded.insert(id) }
                }
            } label: {
                HStack(spacing: PSSpacing.small) {
                    Text(title).font(PSFontRole.inspectorLabel).foregroundStyle(Color.psTextPrimary)
                    if isSet {
                        Circle().fill(Color.psValueAccent).frame(width: PSMetrics.modifiedDot, height: PSMetrics.modifiedDot)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: PSSpacing.small)
                    Image(systemName: "chevron.down")
                        .font(PSFont.glyph(.micro, weight: .semibold))
                        .foregroundStyle(Color.psTextTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(minHeight: PSMetrics.control)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? L("Expanded") : L("Collapsed"))
            if isOpen {
                content().transition(.opacity)
            }
        }
    }
}

/// One ring of the mask's carousel: the dragged one reads the value under the finger, the others the mask.
private struct MaskRing: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment
    let parameter: AdjustmentParameter
    let isSelected: Bool

    var body: some View {
        let dial = session.dial
        let isDragged = dial.group == "mask" && dial.parameter == parameter
        let value = isDragged ? dial.value : adjustment.adjustments[parameter]
        ValueRing(parameter: parameter, value: value, isSelected: isSelected, isDragging: isDragged)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AdjustPanel.name(parameter))
            .accessibilityValue(ValueRing.formatted(value))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("masks.dial.\(parameter.rawValue)")
    }
}

/// The ruler dial of the mask's chosen parameter: owns the dragged value, reloads from the mask when the parameter,
/// the mask or the document changes (an undo, a voice edit).
private struct MaskDial: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment
    let parameter: AdjustmentParameter
    @State private var value: Double = 0

    var body: some View {
        DialSlider(value: $value, range: parameter.range, neutral: 0, label: AdjustPanel.name(parameter), onEditingChanged: { editing in
            if editing { session.beginMaskDial(parameter) } else { session.endMaskInteraction() }
        })
        .onChange(of: value) { _, newValue in
            if abs(newValue - adjustment.adjustments[parameter]) > 0.0005 {
                session.setMaskDial(parameter, value: newValue)
            }
        }
        .onChange(of: parameter) { _, parameter in value = adjustment.adjustments[parameter] }
        .onChange(of: adjustment.id) { _, _ in value = adjustment.adjustments[parameter] }
        .onChange(of: session.revision) { _, _ in
            guard session.dial.parameter == nil else { return }
            let current = adjustment.adjustments[parameter]
            if abs(current - value) > 0.0005 { value = current }
        }
        .onAppear { value = adjustment.adjustments[parameter] }
        .accessibilityIdentifier("masks.dial")
    }
}

/// « Couleur »: one wheel (hue and amount) written to the three ColorGrade wheels, as Lightroom's mask colour.
private struct MaskColorRow: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment
    /// The wheel under the finger until the gesture ends.
    @State private var live: ColorWheel?

    var body: some View {
        let wheel = live ?? adjustment.grade?.midtones ?? ColorWheel()
        HStack(alignment: .center, spacing: PSSpacing.large) {
            ColorWheelControl(wheel: wheel) { next in
                live = next
                session.setMaskColor(hue: next.hue, amount: next.amount)
            } onEditing: { editing in
                if editing {
                    session.beginMaskInteraction()
                } else {
                    session.endMaskInteraction()
                    live = nil
                }
            }
            .frame(width: 112, height: 112)
            .accessibilityIdentifier("masks.color.wheel")
            VStack(alignment: .leading, spacing: PSSpacing.small) {
                InspectorSliderRow(label: L("Strength"), value: wheel.amount, range: 0...1, neutral: 0, controlID: "masks.color.amount",
                                   format: { "\(Int(($0 * 100).rounded())) %" },
                                   onBegin: { session.beginMaskInteraction() },
                                   onChange: { session.setMaskColor(hue: wheel.hue, amount: $0) },
                                   onEnd: { session.endMaskInteraction() })
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: wheel.amount > 0.0005) {
                    session.setMaskColor(hue: wheel.hue, amount: 0)
                }
            }
        }
    }
}

/// « Courbe »: Curves' graph on the mask's own curve (all four channels), and the presets row.
private struct MaskCurveRow: View {
    let session: PhotoEditorSession
    let adjustment: LocalAdjustment
    @State private var channel: ToneCurve.Channel? = .rgb

    var body: some View {
        let curve = adjustment.curve ?? .identity
        let shown = channel ?? .rgb
        VStack(spacing: PSSpacing.small) {
            ModeSegments(modes: ToneCurve.Channel.allCases, selection: $channel, title: CurvesPanel.channelName, symbol: { _ in "" })
            CurveGraph(curve: curve, channel: shown, histogram: nil, side: 150,
                       onBegin: { session.beginMaskInteraction() },
                       onChange: { session.setMaskCurve($0) },
                       onEnd: { session.endMaskInteraction() })
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("masks.curve.points")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PSSpacing.small) {
                    ForEach(ToneCurve.Preset.allCases.filter { $0 != .linear }) { preset in
                        PanelChip(title: psPrefersFrench ? preset.frenchName : preset.englishName) {
                            var next = curve
                            next.setPoints(preset.points(strength: 0.5), for: shown)
                            session.setMaskCurve(next)
                            Haptics.confirm()
                        }
                        .accessibilityIdentifier("masks.curve.preset.\(preset.rawValue)")
                    }
                    PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !curve.isIdentity) {
                        session.setMaskCurve(nil)
                    }
                    .accessibilityIdentifier("masks.curve.preset.linear")
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// An inspector row you can scrub: drag across it to set the value (the row's width is the whole range), double
/// tap for neutral, VoiceOver adjusts by a twentieth. A drag is one undo step (onBegin … onEnd); the row shows the
/// value under the finger until it ends.
struct InspectorSliderRow: View {
    let label: String
    let value: Double
    var range: ClosedRange<Double>
    var neutral: Double = 0
    /// The MaskPanelInventory id (the row's accessibility identifier).
    var controlID: String
    var format: (Double) -> String
    var onBegin: () -> Void = {}
    let onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    @State private var dragStart: Double?
    @State private var live: Double?
    @State private var width: CGFloat = 1

    private var span: Double { max(1e-9, range.upperBound - range.lowerBound) }

    var body: some View {
        let shown = live ?? value
        InspectorRow(label: label, value: format(shown), fraction: (shown - range.lowerBound) / span,
                     neutral: (neutral - range.lowerBound) / span)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        if dragStart == nil {
                            // A mostly vertical drag is the panel's scroll, not the row's.
                            guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                            dragStart = value
                            Haptics.prepare()
                            onBegin()
                        }
                        guard let start = dragStart else { return }
                        var next = (start + Double(drag.translation.width / width) * span).clamped(to: range)
                        // Neutral catches the value as it passes.
                        if abs(next - neutral) < span * 0.015 { next = neutral }
                        if (live ?? start) != neutral, next == neutral { Haptics.confirm() }
                        live = next
                        onChange(next)
                    }
                    .onEnded { _ in
                        guard dragStart != nil else { return }
                        dragStart = nil
                        live = nil
                        onEnd()
                    }
            )
            .onTapGesture(count: 2) {
                Haptics.confirm()
                onBegin()
                onChange(neutral)
                onEnd()
            }
            .accessibilityAdjustableAction { direction in
                let step = span / 20
                onChange((value + (direction == .increment ? step : -step)).clamped(to: range))
            }
            .accessibilityIdentifier(controlID)
    }
}
#endif
