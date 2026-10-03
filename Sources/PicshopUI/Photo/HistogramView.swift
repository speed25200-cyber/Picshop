#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Histogram drawing shared by the card and the Curves and Levels graphs.
enum HistogramPlot {
    /// Bin heights 0…1. The tallest bin away from the two ends sets the scale, so a clipped
    /// black or white spike does not flatten the rest (the spike is cut at the top).
    static func heights(_ bins: [UInt32]) -> [Double] {
        guard bins.count > 2 else { return bins.map { _ in 0 } }
        let peak = Double(bins[1..<(bins.count - 1)].max() ?? 0)
        guard peak > 0 else { return bins.map { $0 > 0 ? 1 : 0 } }
        return bins.map { min(1, Double($0) / peak) }
    }

    /// A filled silhouette of `bins` in `rect` (bottom edge at the base).
    static func area(_ bins: [UInt32], in rect: CGRect) -> Path {
        let values = heights(bins)
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (index, value) in values.enumerated() {
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(value) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// The top edge only, for the luma line.
    static func line(_ bins: [UInt32], in rect: CGRect) -> Path {
        let values = heights(bins)
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(value) * rect.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let green = Color(red: 0.2, green: 0.85, blue: 0.4)
    static let blue = Color(red: 0.25, green: 0.5, blue: 1)

    /// The bins a channel tab shows: luma for RGB.
    static func bins(_ histogram: Histogram, for channel: ToneCurve.Channel) -> [UInt32] {
        switch channel {
        case .rgb: return histogram.luma
        case .red: return histogram.red
        case .green: return histogram.green
        case .blue: return histogram.blue
        }
    }

    static func tint(_ channel: ToneCurve.Channel) -> Color {
        switch channel {
        case .rgb: return .white
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }

    /// "Shadows 1.2 %, highlights 0 %" for VoiceOver.
    static func clippingDescription(_ histogram: Histogram?) -> String {
        guard let clipping = histogram?.clipping else { return L("No histogram yet") }
        return String(format: L("Shadows clipped %@, highlights clipped %@"),
                      percent(clipping.shadows), percent(clipping.highlights))
    }

    static func percent(_ fraction: Double) -> String {
        (fraction).formatted(.percent.precision(.fractionLength(0...1)))
    }
}

/// The live histogram card over the canvas (128 × 56): R, G and B filled at 55 % and
/// added together (white where they all pile up), the luma line, and yellow triangles
/// at the top corners when more than 0.5 % of the picture is crushed or blown. A tap
/// cycles RGB, luma, and off. E5 places it.
struct HistogramCard: View {
    let state: PhotoToneState

    init(state: PhotoToneState) {
        self.state = state
    }

    var body: some View {
        let histogram = state.histogram
        let mode = state.cardMode
        Canvas { context, size in
            let plot = CGRect(x: 6, y: 8, width: size.width - 12, height: size.height - 14)
            guard let histogram else { return }
            if mode == .rgb {
                context.blendMode = .plusLighter
                context.fill(HistogramPlot.area(histogram.red, in: plot), with: .color(HistogramPlot.red.opacity(0.55)))
                context.fill(HistogramPlot.area(histogram.green, in: plot), with: .color(HistogramPlot.green.opacity(0.55)))
                context.fill(HistogramPlot.area(histogram.blue, in: plot), with: .color(HistogramPlot.blue.opacity(0.55)))
                context.blendMode = .normal
                context.stroke(HistogramPlot.line(histogram.luma, in: plot), with: .color(.white.opacity(0.85)), lineWidth: 1)
            } else {
                context.fill(HistogramPlot.area(histogram.luma, in: plot), with: .color(.white.opacity(0.55)))
                context.stroke(HistogramPlot.line(histogram.luma, in: plot), with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
            let clipping = histogram.clipping
            let accent = Color.psValueAccent
            if clipping.shadows > Histogram.Clipping.warningFraction {
                var triangle = Path()
                triangle.move(to: CGPoint(x: 4, y: 3))
                triangle.addLine(to: CGPoint(x: 12, y: 3))
                triangle.addLine(to: CGPoint(x: 4, y: 11))
                triangle.closeSubpath()
                context.fill(triangle, with: .color(accent))
            }
            if clipping.highlights > Histogram.Clipping.warningFraction {
                var triangle = Path()
                triangle.move(to: CGPoint(x: size.width - 4, y: 3))
                triangle.addLine(to: CGPoint(x: size.width - 12, y: 3))
                triangle.addLine(to: CGPoint(x: size.width - 4, y: 11))
                triangle.closeSubpath()
                context.fill(triangle, with: .color(accent))
            }
        }
        .frame(width: 128, height: 56)
        .background(Color.psRaised.opacity(0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.psHairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            Haptics.tick()
            withAnimation(PSMotion.quick) { state.cycleCard() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Histogram"))
        .accessibilityValue(HistogramPlot.clippingDescription(histogram))
        .accessibilityHint(L("Double-tap to switch between colour, luminance and hidden."))
        .accessibilityAddTraits(.isButton)
    }
}
#endif
