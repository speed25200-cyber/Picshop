#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Levels, per channel: the picture's histogram with the input black point,
/// midtones (gamma) and white point under it, and the output black and white
/// points below. Auto sets the black and white points from the histogram
/// (0.1 % clipped) and adapts the midtones, tone only. 'Show clipping' paints
/// crushed shadows blue and blown highlights red on the picture.
///
/// A handle drag is one undo step; each handle is a VoiceOver adjustable element
/// (±1 on 0–255, ±0.05 of gamma).
struct LevelsPanel: View {
    @Bindable var session: PhotoEditorSession
    /// The levels under the finger until the gesture ends.
    @State private var liveLevels: Levels?
    @State private var dragStart: Levels.Channel?
    @State private var active: Handle?

    enum Handle: CaseIterable { case inBlack, gamma, inWhite, outBlack, outWhite }

    private var tone: PhotoToneState { session.tone }
    private var levels: Levels { liveLevels ?? session.levels }
    private var channel: ToneCurve.Channel { tone.channel }
    private var values: Levels.Channel { levels[channel] }

    var body: some View {
        VStack(spacing: 8) {
            ModeSegments(modes: ToneCurve.Channel.allCases, selection: Binding(get: { tone.channel }, set: { tone.channel = $0 ?? .rgb }),
                         title: CurvesPanel.channelName, symbol: { _ in "" })
            GeometryReader { proxy in
                let width = proxy.size.width
                VStack(spacing: 4) {
                    histogram
                        .frame(height: 62)
                    inputTrack(width: width)
                        .frame(height: 30)
                    outputTrack(width: width)
                        .frame(height: 26)
                }
            }
            .frame(height: 62 + 30 + 26 + 8)
            .padding(.horizontal, 10)
            readout
            chips
        }
        .onAppear {
            tone.panelDidAppear()
            tone.refreshInputHistogram(document: session.document, renderer: session.renderer)
        }
        .onDisappear { tone.panelDidDisappear() }
        .onChange(of: session.revision) { _, _ in
            tone.refreshInputHistogram(document: session.document, renderer: session.renderer)
        }
    }

    // MARK: Histogram and tracks

    private var histogram: some View {
        let bins = tone.inputHistogram.map { HistogramPlot.bins($0, for: channel) }
        let tint = HistogramPlot.tint(channel)
        let black = values.inBlack, white = values.inWhite
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if let bins {
                context.fill(HistogramPlot.area(bins, in: rect), with: .color(tint.opacity(0.42)))
            }
            // What the input points cut off, dimmed.
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width * CGFloat(black), height: size.height)), with: .color(.black.opacity(0.35)))
            context.fill(Path(CGRect(x: size.width * CGFloat(white), y: 0, width: size.width * CGFloat(1 - white), height: size.height)), with: .color(.black.opacity(0.35)))
        }
        .background(Color.psFillControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Histogram"))
        .accessibilityValue(HistogramPlot.clippingDescription(tone.inputHistogram))
    }

    /// Where the midtones handle sits: the input value that comes out at middle grey.
    static func gammaPosition(_ channel: Levels.Channel) -> Double {
        channel.inBlack + (channel.inWhite - channel.inBlack) * pow(0.5, channel.gamma.clamped(to: Levels.Channel.gammaRange))
    }

    private func inputTrack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            track
            handle(.inBlack, at: values.inBlack, fill: .black, width: width)
            handle(.gamma, at: Self.gammaPosition(values), fill: Color(white: 0.5), width: width)
            handle(.inWhite, at: values.inWhite, fill: .white, width: width)
        }
    }

    private func outputTrack(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            track
            handle(.outBlack, at: values.outBlack, fill: .black, width: width)
            handle(.outWhite, at: values.outWhite, fill: .white, width: width)
        }
    }

    /// The black-to-white bar the handles sit under.
    private var track: some View {
        Capsule().fill(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
            .frame(height: 6)
            .overlay(Capsule().strokeBorder(Color.psHairline, lineWidth: 1))
    }

    /// A triangle handle under the track, in a 44-point hit area.
    private func handle(_ kind: Handle, at value: Double, fill: Color, width: CGFloat) -> some View {
        let isActive = active == kind
        return Triangle()
            .fill(fill)
            .overlay(Triangle().stroke(isActive ? Color.psValueAccent : Color.white.opacity(0.8), lineWidth: isActive ? 2 : 1))
            .frame(width: 14, height: 12)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: CGFloat(value) * width, y: 14)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in move(kind, by: Double(drag.translation.width / max(1, width))) }
                    .onEnded { _ in finish() }
            )
            .accessibilityElement()
            .accessibilityLabel(Self.name(kind))
            .accessibilityValue(Self.formatted(kind, values))
            .accessibilityAdjustableAction { direction in
                nudge(kind, up: direction == .increment)
            }
    }

    static func name(_ kind: Handle) -> String {
        switch kind {
        case .inBlack: return L("Black point")
        case .gamma: return L("Midtones")
        case .inWhite: return L("White point")
        case .outBlack: return L("Output black")
        case .outWhite: return L("Output white")
        }
    }

    static func formatted(_ kind: Handle, _ channel: Levels.Channel) -> String {
        switch kind {
        case .inBlack: return "\(level(channel.inBlack))"
        case .gamma: return String(format: "%.2f", channel.gamma)
        case .inWhite: return "\(level(channel.inWhite))"
        case .outBlack: return "\(level(channel.outBlack))"
        case .outWhite: return "\(level(channel.outWhite))"
        }
    }

    static func level(_ value: Double) -> Int { Int((value * 255).rounded()) }

    // MARK: Editing

    /// `delta` is the drag so far, as a fraction of the track.
    private func move(_ kind: Handle, by delta: Double) {
        if dragStart == nil {
            dragStart = values
            active = kind
            session.beginInteraction(label: "Levels")
            Haptics.tick()
        }
        guard let start = dragStart else { return }
        var next = start
        let gap = 2.0 / 255
        switch kind {
        case .inBlack:
            next.inBlack = (start.inBlack + delta).clamped(to: 0...(start.inWhite - gap))
        case .inWhite:
            next.inWhite = (start.inWhite + delta).clamped(to: (start.inBlack + gap)...1)
        case .gamma:
            // The handle marks the input that comes out at middle grey.
            let span = start.inWhite - start.inBlack
            let position = (Self.gammaPosition(start) + delta).clamped(to: (start.inBlack + span * 0.005)...(start.inWhite - span * 0.005))
            let fraction = (position - start.inBlack) / max(1e-6, span)
            next.gamma = ((log(fraction) / log(0.5)) * 100).rounded() / 100
            next.gamma = next.gamma.clamped(to: Levels.Channel.gammaRange)
        case .outBlack:
            next.outBlack = (start.outBlack + delta).clamped(to: 0...1)
        case .outWhite:
            next.outWhite = (start.outWhite + delta).clamped(to: 0...1)
        }
        var updated = levels
        updated[channel] = next
        liveLevels = updated
        session.setLevels(updated)
    }

    private func finish() {
        if dragStart != nil { session.endInteraction() }
        dragStart = nil
        active = nil
        liveLevels = nil
    }

    /// VoiceOver's adjust: one level (or 0.05 of gamma), committed at once.
    private func nudge(_ kind: Handle, up: Bool) {
        var next = values
        let step = (up ? 1.0 : -1.0) / 255
        switch kind {
        case .inBlack: next.inBlack = (next.inBlack + step).clamped(to: 0...(next.inWhite - 2.0 / 255))
        case .inWhite: next.inWhite = (next.inWhite + step).clamped(to: (next.inBlack + 2.0 / 255)...1)
        case .gamma: next.gamma = (next.gamma + (up ? 0.05 : -0.05)).clamped(to: Levels.Channel.gammaRange)
        case .outBlack: next.outBlack = (next.outBlack + step).clamped(to: 0...1)
        case .outWhite: next.outWhite = (next.outWhite + step).clamped(to: 0...1)
        }
        var updated = levels
        updated[channel] = next
        session.setLevels(updated)
    }

    // MARK: Readout and actions

    private var readout: some View {
        let changed = !values.isIdentity
        return HStack(spacing: 12) {
            Text(L("Input")).font(.caption2.weight(.medium)).textCase(.uppercase).foregroundStyle(Color.psTextSecondary)
            Text(verbatim: "\(Self.level(values.inBlack))  \(String(format: "%.2f", values.gamma))  \(Self.level(values.inWhite))")
                .font(PSFontRole.valueReadout)
                .foregroundStyle(changed ? Color.psValueAccent : Color.psTextPrimary)
            Spacer(minLength: 8)
            Text(L("Output")).font(.caption2.weight(.medium)).textCase(.uppercase).foregroundStyle(Color.psTextSecondary)
            Text(verbatim: "\(Self.level(values.outBlack))  \(Self.level(values.outWhite))")
                .font(PSFontRole.valueReadout)
                .foregroundStyle(changed ? Color.psValueAccent : Color.psTextPrimary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PanelChip(title: L("Auto"), symbol: "wand.and.stars") { session.autoTone() }
                PanelChip(title: L("Show clipping"), symbol: "exclamationmark.triangle", isActive: tone.showsClipping) {
                    tone.showsClipping.toggle()
                }
                PanelChip(title: L("Histogram"), symbol: "chart.bar.fill", isActive: tone.showsHistogramCard) {
                    withAnimation(PSMotion.quick) { tone.showsHistogramCard.toggle() }
                }
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !session.levels.isIdentity) {
                    session.resetLevels()
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// A small upward triangle (the Levels handles).
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
#endif
