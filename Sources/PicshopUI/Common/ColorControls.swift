#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import PicshopCore

/// Pro colour: an eight-band HSL mixer and three colour wheels (shadows,
/// midtones, highlights), shared by the photo and video editors. Values
/// stream to the editor while a control moves; one undo step per gesture.
struct ColorControls: View {
    var mixer: ColorMixer
    var grade: ColorGrade
    var onMixer: (ColorMixer) -> Void
    var onGrade: (ColorGrade) -> Void
    var onBegin: (String) -> Void
    var onEnd: () -> Void
    /// An imported `.cube` look; the LUT tab appears when `onImportLUT` is set.
    var lut: LUTReference? = nil
    var onImportLUT: ((URL) -> Void)? = nil
    var onLUTIntensity: ((Double) -> Void)? = nil
    var onRemoveLUT: (() -> Void)? = nil
    /// A second action for the look, e.g. "Apply to every clip".
    var lutExtra: (title: String, run: () -> Void)? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case mixer, wheels, lut
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mixer: return L("Mixer")
            case .wheels: return L("Wheels")
            case .lut: return L("LUT")
            }
        }
        var symbol: String {
            switch self {
            case .mixer: return "circle.hexagongrid"
            case .wheels: return "circle.circle"
            case .lut: return "cube.transparent"
            }
        }
    }

    @State private var mode: Mode? = .mixer
    @State private var band: ColorMixer.Band = .red
    @State private var importsLUT = false

    var body: some View {
        VStack(spacing: 12) {
            ModeSegments(modes: onImportLUT == nil ? [.mixer, .wheels] : Mode.allCases, selection: $mode, title: { $0.title }, symbol: { $0.symbol })
            switch mode {
            case .wheels: wheels.transition(.opacity)
            case .lut: lutControls.transition(.opacity)
            default: mixerControls.transition(.opacity)
            }
        }
        .animation(PSMotion.standard, value: mode)
        .fileImporter(isPresented: $importsLUT, allowedContentTypes: [UTType(filenameExtension: "cube", conformingTo: .data) ?? .data, .plainText]) { result in
            if case .success(let url) = result { onImportLUT?(url) }
        }
    }

    // MARK: LUT

    private var lutControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lut {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent.fill").font(.system(size: 17, weight: .medium)).foregroundStyle(PSTheme.accent)
                    Text(lut.title).font(.subheadline.weight(.medium)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                    Spacer()
                    Button { Haptics.tap(); onRemoveLUT?() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30).background(Circle().fill(PanelChipStyle.fill))
                    }
                    .buttonStyle(PSPressStyle(scale: 0.9)).foregroundStyle(PSTheme.textSecondary)
                    .accessibilityLabel(L("Remove the LUT"))
                }
                ParameterSlider(title: L("Intensity"), value: Binding(get: { lut.intensity }, set: { onLUTIntensity?($0) }), range: 0.05...1, bipolar: false) { editing in
                    if editing { onBegin(L("LUT Intensity")) } else { onEnd() }
                }
                HStack(spacing: 8) {
                    PanelChip(title: L("Another LUT"), symbol: "square.and.arrow.down") { importsLUT = true }
                    if let lutExtra { PanelChip(title: lutExtra.title, symbol: "square.stack.3d.down.right") { lutExtra.run() } }
                    Spacer(minLength: 0)
                }
            } else {
                Button { Haptics.tap(); importsLUT = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cube.transparent").font(.system(size: 20, weight: .regular)).foregroundStyle(PSTheme.textPrimary)
                            .frame(width: 44, height: 44).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Import a LUT")).font(.subheadline.weight(.semibold)).foregroundStyle(PSTheme.textPrimary)
                            Text(L("A .cube look from Resolve, Premiere or a LUT pack.")).font(.footnote).foregroundStyle(PSTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(PSTheme.textTertiary)
                    }
                    .padding(8)
                    .background(PanelChipStyle.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PSPressStyle(scale: 0.97))
            }
        }
    }

    // MARK: Mixer

    private var mixerControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(ColorMixer.Band.allCases) { item in
                    let selected = item == band
                    let touched = ColorMixer.Channel.allCases.contains { abs(mixer[item, $0]) > 0.0005 }
                    Button {
                        Haptics.tick()
                        withAnimation(PSMotion.quick) { band = item }
                    } label: {
                        Circle()
                            .fill(Self.swatch(item))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75))
                            .padding(4)
                            .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
                            .overlay(alignment: .bottom) {
                                Circle().fill(PSTheme.accent).frame(width: 4, height: 4).offset(y: 6).opacity(touched ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PSPressStyle(scale: 0.9))
                    .accessibilityLabel(psPrefersFrench ? item.frenchName : item.englishName)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.bottom, 4)
            ForEach(ColorMixer.Channel.allCases) { channel in
                DialSlider(value: binding(channel), range: -1...1, neutral: 0, label: Self.name(channel), units: 100, onEditingChanged: { editing in
                    if editing { onBegin("Colour Mixer") } else { onEnd() }
                })
            }
        }
    }

    private func binding(_ channel: ColorMixer.Channel) -> Binding<Double> {
        Binding(
            get: { mixer[band, channel] },
            set: { value in
                var next = mixer
                next[band, channel] = value
                onMixer(next)
            }
        )
    }

    static func name(_ channel: ColorMixer.Channel) -> String {
        switch channel {
        case .hue: return L("Hue")
        case .saturation: return L("Saturation")
        case .luminance: return L("Luminance")
        }
    }

    static func swatch(_ band: ColorMixer.Band) -> Color {
        let rgb = ColorEngine.rgb(fromHSL: (band.centerHue, 0.85, 0.52))
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    // MARK: Wheels

    private var wheels: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ColorGrade.Range.allCases) { range in
                    VStack(spacing: 8) {
                        ColorWheelControl(wheel: grade[range]) { wheel in
                            var next = grade
                            next[range] = wheel
                            onGrade(next)
                        } onEditing: { editing in
                            if editing { onBegin("Colour Grading") } else { onEnd() }
                        }
                        Text(Self.name(range)).font(.caption2.weight(.medium)).textCase(.uppercase).tracking(0.4).foregroundStyle(PSTheme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        LuminanceSlider(value: grade[range].luminance) { value in
                            var next = grade
                            var wheel = next[range]
                            wheel.luminance = value
                            next[range] = wheel
                            onGrade(next)
                        } onEditing: { editing in
                            if editing { onBegin("Colour Grading") } else { onEnd() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PanelChip(title: L("Teal & orange"), symbol: "film") { apply(.tealAndOrange) }
                    PanelChip(title: L("Golden hour"), symbol: "sun.max") {
                        apply(ColorGrade(shadows: ColorWheel(hue: 28, amount: 0.2), midtones: ColorWheel(hue: 38, amount: 0.25), highlights: ColorWheel(hue: 45, amount: 0.35, luminance: 0.05)))
                    }
                    PanelChip(title: L("Nordic"), symbol: "snowflake") {
                        apply(ColorGrade(shadows: ColorWheel(hue: 210, amount: 0.35, luminance: 0.05), midtones: ColorWheel(hue: 200, amount: 0.12), highlights: ColorWheel(hue: 190, amount: 0.1)))
                    }
                    PanelChip(title: L("Bleach"), symbol: "drop.halffull") {
                        apply(ColorGrade(shadows: ColorWheel(hue: 160, amount: 0.25, luminance: -0.1), midtones: ColorWheel(), highlights: ColorWheel(hue: 50, amount: 0.15, luminance: 0.1)))
                    }
                    PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !grade.isNeutral) { apply(.neutral) }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func apply(_ preset: ColorGrade) {
        onBegin("Colour Grading")
        onGrade(preset)
        onEnd()
        Haptics.confirm()
    }

    static func name(_ range: ColorGrade.Range) -> String {
        switch range {
        case .shadows: return L("Shadows")
        case .midtones: return L("Midtones")
        case .highlights: return L("Highlights")
        }
    }
}

/// A colour wheel: the hue ring around, white at the centre, and a puck you
/// drag — its angle is the tint, its distance from the centre how much.
/// Double tap to reset.
struct ColorWheelControl: View {
    var wheel: ColorWheel
    var onChange: (ColorWheel) -> Void
    var onEditing: (Bool) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let angle = Angle.degrees(-wheel.hue)
            let puck = CGPoint(x: center.x + cos(CGFloat(angle.radians)) * radius * 0.86 * CGFloat(wheel.amount),
                               y: center.y + sin(CGFloat(angle.radians)) * radius * 0.86 * CGFloat(wheel.amount))
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: stride(from: 0.0, through: 360.0, by: 30).map { hue in
                        let rgb = ColorEngine.rgb(fromHSL: (-hue, 0.9, 0.5))
                        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
                    }, center: .center))
                    .opacity(0.9)
                Circle().fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.16).opacity(0)], center: .center, startRadius: 0, endRadius: radius * 0.95))
                Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.75)
                // Crosshair at the neutral point.
                Path { path in
                    path.move(to: CGPoint(x: center.x - 5, y: center.y)); path.addLine(to: CGPoint(x: center.x + 5, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - 5)); path.addLine(to: CGPoint(x: center.x, y: center.y + 5))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: dragging ? 18 : 14, height: dragging ? 18 : 14)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .position(puck)
                    .animation(PSMotion.quick, value: dragging)
            }
            .frame(width: side, height: side)
            .position(center)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            Haptics.soft(0.4)
                            onEditing(true)
                        }
                        let dx = value.location.x - center.x
                        let dy = value.location.y - center.y
                        let distance = min(1, sqrt(dx * dx + dy * dy) / (radius * 0.86))
                        var hue = -atan2(dy, dx) * 180 / .pi
                        if hue < 0 { hue += 360 }
                        onChange(ColorWheel(hue: Double(hue), amount: Double(distance), luminance: wheel.luminance))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditing(false)
                    }
            )
            .onTapGesture(count: 2) {
                Haptics.confirm()
                onEditing(true)
                onChange(ColorWheel(hue: wheel.hue, amount: 0, luminance: wheel.luminance))
                onEditing(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(L("Colour wheel"))
        .accessibilityValue("\(Int(wheel.hue))°, \(Int(wheel.amount * 100))%")
    }
}

/// A thin horizontal slider for a wheel's brightness.
struct LuminanceSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    var onEditing: (Bool) -> Void
    @State private var start: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = CGFloat((value + 1) / 2) * width
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Color(white: 0.1), Color(white: 0.9)], startPoint: .leading, endPoint: .trailing)).frame(height: 4)
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: 8).offset(x: width / 2)
                Circle().fill(abs(value) > 0.0005 ? PSTheme.accent : Color.white).frame(width: 12, height: 12)
                    .offset(x: x - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if start == nil {
                            start = value
                            onEditing(true)
                        }
                        let next = (Double(drag.location.x / max(1, width)) * 2 - 1).clamped(to: -1...1)
                        onChange(abs(next) < 0.04 ? 0 : next)
                    }
                    .onEnded { _ in
                        start = nil
                        onEditing(false)
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(L("Luminance"))
        .accessibilityValue("\(Int(value * 100))")
    }
}
/// Copies a `.cube` file into the project after checking it is a 3D LUT.
enum LUTImporter {
    static func save(_ url: URL, store: ProjectStore, projectID: UUID) throws -> LUTReference {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw CubeLUT.ParseError.missingSize }
        let lut = try CubeLUT.parse(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
        try store.createPackage(for: projectID)
        let name = "lut-\(UUID().uuidString.prefix(8)).cube"
        try text.write(to: store.mediaURL(for: projectID).appendingPathComponent(name), atomically: true, encoding: .utf8)
        return LUTReference(relativePath: "\(Project.mediaDirectory)/\(name)", title: lut.title)
    }
}
#endif
