#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// The luminance and depth range editor (W2): a low and a high thumb on one track, drawn over a 64-bin histogram of
/// the picture's luminance (its 256-point proxy, without local adjustments) or of the depth map; the trapezoid the
/// range makes on top; « Adoucir » for its feather; an eyedropper that sets the range to the tapped value ± 0.1;
/// and « Afficher la carte », the map itself in black and white on the canvas. Thumb and hit maths are
/// MaskHandleGeometry's (Linux-tested); a drag is one undo step.
struct RangeMaskControls: View {
    let session: PhotoEditorSession
    let component: MaskComponent

    /// The range under the finger until the drag ends.
    @State private var live: (low: Double, high: Double)?
    @State private var thumb: MaskHandleGeometry.RangeThumb?
    @State private var trackWidth: CGFloat = 1

    private static let trackHeight: CGFloat = 64

    private var spec: (low: Double, high: Double, feather: Double, isDepth: Bool)? {
        switch component.kind {
        case .luminanceRange(let range): return (range.low, range.high, range.feather, false)
        case .depthRange(let range): return (range.low, range.high, range.feather, true)
        default: return nil
        }
    }

    var body: some View {
        if let spec {
            let low = live?.low ?? spec.low, high = live?.high ?? spec.high
            VStack(spacing: PSSpacing.small) {
                HStack(spacing: PSSpacing.small) {
                    Text(spec.isDepth ? L("Depth range") : L("Luminance range"))
                        .font(PSFontRole.inspectorLabel)
                        .foregroundStyle(Color.psTextSecondary)
                    Spacer(minLength: PSSpacing.small)
                    PanelChip(title: L("Eyedropper"), symbol: "eyedropper", isActive: session.maskState.rangeEyedropper) {
                        session.maskState.rangeEyedropper.toggle()
                    }
                    .accessibilityIdentifier("masks.range.eyedropper")
                    PanelChip(title: L("Show the map"), symbol: "square.fill.on.square", isActive: session.maskState.showsRangeMap) {
                        session.maskState.showsRangeMap.toggle()
                        session.requestPreview()
                    }
                    .accessibilityIdentifier("masks.range.preview.map")
                }
                track(low: low, high: high, feather: spec.feather, isDepth: spec.isDepth)
                HStack {
                    Text(spec.isDepth ? L("Far") : L("Dark"))
                    Spacer()
                    Text(verbatim: "\(Int((low * 100).rounded())) – \(Int((high * 100).rounded()))")
                        .font(PSFontRole.inspectorValue)
                        .foregroundStyle(Color.psValueAccent)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(spec.isDepth ? L("Near") : L("Bright"))
                }
                .font(.caption2)
                .foregroundStyle(Color.psTextTertiary)
                InspectorSliderRow(label: L("Soften"), value: spec.feather, range: 0...0.5, neutral: 0, controlID: "masks.range.smoothness",
                                   format: { "\(Int(($0 * 200).rounded()))" },
                                   onBegin: { session.beginRangeDrag() },
                                   onChange: { session.setRange(component.id, low: spec.low, high: spec.high, feather: $0) },
                                   onEnd: { session.endRangeDrag() })
                if session.maskState.rangeEyedropper {
                    Text(L("Tap the picture: the range centres on that tone."))
                        .font(.footnote)
                        .foregroundStyle(Color.psTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task(id: component.id) { session.loadRangeHistogram() }
        }
    }

    private func track(low: Double, high: Double, feather: Double, isDepth: Bool) -> some View {
        let bins = session.maskState.rangeHistogram
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            // The histogram.
            if !bins.isEmpty {
                let barWidth = rect.width / CGFloat(bins.count)
                var bars = Path()
                for (index, height) in bins.enumerated() {
                    let h = CGFloat(height) * (rect.height - 8)
                    bars.addRect(CGRect(x: CGFloat(index) * barWidth, y: rect.height - h, width: max(1, barWidth - 1), height: h))
                }
                context.fill(bars, with: .color(Color.psStrokeStrong))
            }
            // The range's trapezoid, as the mask will select.
            var curve = Path()
            let samples = 96
            for index in 0...samples {
                let x = Double(index) / Double(samples)
                let value = MaskMath.trapezoid(x, low: low, high: high, feather: feather)
                let point = CGPoint(x: rect.width * CGFloat(x), y: rect.height - CGFloat(value) * (rect.height - 4) - 2)
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(Color.psValueAccent), lineWidth: 1.5)
            // The selected band.
            let band = CGRect(x: rect.width * CGFloat(low), y: 0, width: rect.width * CGFloat(max(0, high - low)), height: rect.height)
            context.fill(Path(band), with: .color(Color.psValueAccentSoft))
            // The thumbs.
            for (value, isActive) in [(low, thumb == .low), (high, thumb == .high)] {
                let x = CGFloat(MaskHandleGeometry.thumbX(value, trackWidth: Double(rect.width)))
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: rect.height))
                context.stroke(line, with: .color(isActive ? Color.psValueAccent : Color.psActionPrimary), lineWidth: 2)
                let knob = Path(ellipseIn: CGRect(x: x - 7, y: rect.height - 14, width: 14, height: 14))
                context.fill(knob, with: .color(isActive ? Color.psValueAccent : Color.psActionPrimary))
                context.stroke(knob, with: .color(Color.psScrim), lineWidth: 1)
            }
        }
        .frame(height: Self.trackHeight)
        .background(Color.psFillWell, in: RoundedRectangle(cornerRadius: PSRadius.thumb, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = max(1, $0) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let width = Double(trackWidth)
                    if thumb == nil {
                        guard let grabbed = MaskHandleGeometry.hitThumb(at: Double(drag.startLocation.x), low: low, high: high, trackWidth: width) else { return }
                        thumb = grabbed
                        Haptics.tick()
                        session.beginRangeDrag()
                    }
                    guard let thumb else { return }
                    let range = MaskHandleGeometry.draggedRange(low: live?.low ?? low, high: live?.high ?? high, thumb: thumb,
                                                                to: Double(drag.location.x), trackWidth: width)
                    live = range
                    session.setRange(component.id, low: range.low, high: range.high, feather: feather)
                }
                .onEnded { _ in
                    guard thumb != nil else { return }
                    thumb = nil
                    live = nil
                    session.endRangeDrag()
                }
        )
        .accessibilityElement()
        .accessibilityLabel(isDepth ? L("Depth range") : L("Luminance range"))
        .accessibilityValue("\(Int((low * 100).rounded())) – \(Int((high * 100).rounded()))")
        .accessibilityAdjustableAction { direction in
            // Moves the whole range by 5 %.
            let step = direction == .increment ? 0.05 : -0.05
            let width = high - low
            let newLow = (low + step).clamped(to: 0...(1 - width))
            session.setRange(component.id, low: newLow, high: newLow + width, feather: feather)
        }
        .accessibilityIdentifier("masks.range.low")
    }
}
#endif
