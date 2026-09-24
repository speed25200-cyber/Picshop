#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

// The controls that sit inside a ToolPanel: a plain fill, never glass on glass.

/// Sub-mode picker: the system segmented control, whose thumb is Liquid
/// Glass on iOS 26. Text only; `symbol` is kept for existing call sites.
struct ModeSegments<Mode: Hashable & Identifiable>: View {
    let modes: [Mode]
    @Binding var selection: Mode?
    var title: (Mode) -> String
    var symbol: (Mode) -> String

    var body: some View {
        Picker(selection: $selection) {
            ForEach(modes) { mode in
                Text(title(mode)).tag(Optional(mode))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Dial

/// Photos' ruler dial. Drag to change the value with haptic ticks, double tap
/// to reset. The value reads above the centre mark and turns yellow as soon
/// as it leaves neutral. While dragging, only this view and whatever reads the
/// binding re-evaluate: bind it to a leaf's state, never to a session mirror.
struct DialSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var neutral: Double = 0
    var label: String? = nil
    /// Number of dial units across the full range (ticks are drawn per unit).
    var units: Double = 100
    var format: (Double) -> String = { value in
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var dragStartValue: Double?
    @State private var lastTick: Int = 0
    @State private var isDragging = false

    private var pointsPerUnit: CGFloat { 7 }
    private var unitValue: Double { (range.upperBound - range.lowerBound) / units }
    private var isNeutralValue: Bool { abs(value - neutral) < 0.0001 }

    var body: some View {
        VStack(spacing: 4) {
            // The value sits centred over the marker, the name small on the left, as in Photos.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label ?? "")
                    .font(.caption2.weight(.medium)).textCase(.uppercase).tracking(0.4)
                    .foregroundStyle(PSTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(format(value))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isNeutralValue ? PSTheme.textPrimary : PSTheme.accent)
                    .contentTransition(.numericText())
                    // No numeric animation under the finger: each tick would start one.
                    .animation(isDragging ? nil : PSMotion.numeric, value: value)
                    .scaleEffect(isDragging ? 1.08 : 1)
                    .animation(PSMotion.quick, value: isDragging)
                    .fixedSize()
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            GeometryReader { proxy in
                let width = proxy.size.width
                let centerX = width / 2
                let markerColor = isNeutralValue ? Color.white : PSTheme.accent
                Canvas(rendersAsynchronously: true) { context, size in
                    let offset = CGFloat((value - range.lowerBound) / unitValue) * pointsPerUnit
                    let count = Int(units)
                    let neutralIndex = Int(((neutral - range.lowerBound) / unitValue).rounded())
                    var minor = Path()
                    var major = Path()
                    for index in 0...count {
                        let x = centerX - offset + CGFloat(index) * pointsPerUnit
                        guard x >= -2, x <= size.width + 2 else { continue }
                        let isMajor = index % 10 == 0
                        let height: CGFloat = isMajor ? 16 : 9
                        if index == neutralIndex {
                            // The neutral point: a dot above the ticks, like Photos.
                            context.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height / 2 - 14, width: 4, height: 4)), with: .color(.white.opacity(0.9)))
                        }
                        if isMajor {
                            major.move(to: CGPoint(x: x, y: size.height / 2 - height / 2 + 3))
                            major.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2 + 3))
                        } else {
                            minor.move(to: CGPoint(x: x, y: size.height / 2 - height / 2 + 3))
                            minor.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2 + 3))
                        }
                    }
                    let fade = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.7), Color.white.opacity(0.7), Color.white.opacity(0.0)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))
                    context.stroke(minor, with: fade, lineWidth: 1)
                    context.stroke(major, with: fade, lineWidth: 1.6)
                    var marker = Path()
                    marker.move(to: CGPoint(x: centerX, y: 2))
                    marker.addLine(to: CGPoint(x: centerX, y: size.height - 2))
                    context.stroke(marker, with: .color(markerColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            if dragStartValue == nil {
                                dragStartValue = value
                                lastTick = Int((value / unitValue).rounded())
                                isDragging = true
                                Haptics.prepare()
                                onEditingChanged?(true)
                            }
                            guard let start = dragStartValue else { return }
                            let delta = -Double(drag.translation.width / pointsPerUnit) * unitValue
                            let next = (start + delta).clamped(to: range)
                            value = next
                            let tick = Int((next / unitValue).rounded())
                            if tick != lastTick {
                                lastTick = tick
                                if abs(next - neutral) < unitValue / 2 { Haptics.confirm() } else { Haptics.tick() }
                            }
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            isDragging = false
                            onEditingChanged?(false)
                        }
                )
                .onTapGesture(count: 2) {
                    Haptics.confirm()
                    onEditingChanged?(true)
                    withAnimation(PSMotion.quick) { value = neutral }
                    onEditingChanged?(false)
                }
            }
            .frame(height: 32)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = unitValue * 5
            switch direction {
            case .increment: value = (value + step).clamped(to: range)
            case .decrement: value = (value - step).clamped(to: range)
            @unknown default: break
            }
        }
    }
}

// MARK: - Chips

/// The fill of a control inside a panel: never glass on glass.
enum PanelChipStyle {
    static let fill = Color.white.opacity(0.10)
    static let height: CGFloat = 34
}

/// Small chip button used inside panels: 34 points, a quiet white capsule,
/// a monochrome glyph; white with black text when selected (the Photos
/// filter-chip idiom). `tint` marks the glyph of a special action: the
/// spectrum for `PSTheme.voice` (the AI does it), yellow for
/// `PSTheme.accent` (it finishes something), red text for `PSTheme.danger`.
struct PanelChip: View {
    let title: String
    var symbol: String? = nil
    var tint: Color? = nil
    var isActive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button { Haptics.tap(); action() } label: {
            HStack(spacing: 6) {
                if let symbol {
                    if tint == PSTheme.voice, !isActive {
                        MagicGlyph(size: 15, symbol: symbol)
                    } else {
                        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(glyphColor)
                    }
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(isActive ? .medium : .regular))
            .foregroundStyle(textColor)
            .padding(.leading, symbol == nil ? 14 : 12).padding(.trailing, 14)
            .frame(minHeight: PanelChipStyle.height)
            .background(Capsule().fill(isActive ? Color.white : PanelChipStyle.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(PSMotion.quick, value: isActive)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var textColor: Color {
        if isActive { return .black }
        return tint == PSTheme.danger ? PSTheme.danger : PSTheme.textPrimary
    }

    private var glyphColor: Color {
        if isActive { return .black }
        if tint == PSTheme.accent || tint == PSTheme.danger { return tint ?? PSTheme.textSecondary }
        return PSTheme.textSecondary
    }
}

/// Icon-only chip with a caption underneath, for action rows: the same
/// quiet fill as `PanelChip`, white with black content when selected.
struct IconChip: View {
    let title: String
    let symbol: String
    var isActive = false
    var isEnabled = true
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button { Haptics.tap(); action() } label: {
            VStack(spacing: 4) {
                Group {
                    if tint == PSTheme.voice, !isActive {
                        MagicGlyph(size: 17, symbol: symbol)
                    } else {
                        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isActive ? Color.black : (tint == PSTheme.accent ? PSTheme.accent : PSTheme.textPrimary))
                    }
                }
                .frame(height: 21)
                Text(title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(isActive ? Color.black : PSTheme.textSecondary)
            }
            .frame(width: 68, height: 52)
            .background(shape.fill(isActive ? Color.white : PanelChipStyle.fill))
            .contentShape(shape)
        }
        .buttonStyle(PSPressStyle(scale: 0.97))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(PSMotion.quick, value: isActive)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Round colour swatch.
struct ColorSwatch: View {
    let color: PSColor
    var isSelected: Bool
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button { Haptics.tick(); action() } label: {
            Circle().fill(Color(cgColor: color.cgColor))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
                .scaleEffect(isSelected ? 1.06 : 1)
                .animation(PSMotion.quick, value: isSelected)
        }
        .buttonStyle(PSPressStyle(scale: 0.88))
        .accessibilityLabel(color.hexString)
    }
}
#endif
