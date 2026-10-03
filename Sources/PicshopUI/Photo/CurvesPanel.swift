#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Curves: the RGB master and one curve per colour channel, up to 16 points
/// each, on a square graph with the picture's histogram behind it.
///
/// - Tap the curve to add a point there; drag a point (or anywhere: a new
///   point starts under the finger) to shape it. Double-tap a point, or drag
///   it out of the graph, to remove it. The two ends stay.
/// - Hit areas are 44 points; the readout shows input → output on 0–255.
/// - A drag is one undo step: the document moves once, when the finger lifts.
/// - Each point is a VoiceOver adjustable element (±1/255 of output).
struct CurvesPanel: View {
    @Bindable var session: PhotoEditorSession
    /// The curve under the finger until the gesture ends.
    @State private var liveCurve: ToneCurve?
    @State private var selected: Int?
    @State private var drag: Drag?
    @State private var lastTap: (index: Int, time: Date)?
    /// A finger is down on the graph (with or without a point to move).
    @State private var touching = false
    /// The session's drag hooks were opened by this gesture: one undo step when it ends.
    @State private var interacting = false

    private struct Drag {
        var index: Int
        var start: ToneCurve.Point
        /// Dragged out of the graph: the point goes when the finger lifts there.
        var isRemoving = false
        var moved = false
    }

    private static let hitRadius: CGFloat = 22
    private static let graphSide: CGFloat = 176

    private var tone: PhotoToneState { session.tone }
    private var curve: ToneCurve { liveCurve ?? session.userToneCurve }
    private var channel: ToneCurve.Channel { tone.channel }

    var body: some View {
        VStack(spacing: 10) {
            ModeSegments(modes: ToneCurve.Channel.allCases, selection: Binding(get: { tone.channel }, set: { tone.channel = $0 ?? .rgb }),
                         title: CurvesPanel.channelName, symbol: { _ in "" })
            graph
                .frame(width: Self.graphSide, height: Self.graphSide)
                .frame(maxWidth: .infinity)
            presets
        }
        .onChange(of: tone.channel) { _, _ in selected = nil }
        .onAppear {
            tone.panelDidAppear()
            tone.refreshInputHistogram(document: session.document, renderer: session.renderer)
        }
        .onDisappear { tone.panelDidDisappear() }
        .onChange(of: session.revision) { _, _ in
            tone.refreshInputHistogram(document: session.document, renderer: session.renderer)
            if let index = selected, index >= shownPoints(curve).count { selected = nil }
        }
    }

    static func channelName(_ channel: ToneCurve.Channel) -> String {
        switch channel {
        case .rgb: return L("RGB")
        case .red: return L("Red")
        case .green: return L("Green")
        case .blue: return L("Blue")
        }
    }

    /// The channel's points as the panel edits them: an untouched channel is the straight line.
    private func shownPoints(_ curve: ToneCurve) -> [ToneCurve.Point] {
        let points = curve.points(channel)
        return points == ToneCurve.linear ? ToneCurve.straight : points
    }

    // MARK: Graph

    private var graph: some View {
        let points = shownPoints(curve)
        let histogram = tone.inputHistogram
        let side = Self.graphSide
        let shownCurve = curve
        let currentChannel = channel
        let hidden = drag?.isRemoving == true ? drag?.index : nil
        let selectedIndex = selected
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                // Quarters.
                var grid = Path()
                for step in 1...3 {
                    let offset = CGFloat(step) / 4
                    grid.move(to: CGPoint(x: rect.width * offset, y: 0)); grid.addLine(to: CGPoint(x: rect.width * offset, y: rect.height))
                    grid.move(to: CGPoint(x: 0, y: rect.height * offset)); grid.addLine(to: CGPoint(x: rect.width, y: rect.height * offset))
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                if let histogram {
                    context.fill(HistogramPlot.area(HistogramPlot.bins(histogram, for: currentChannel), in: rect),
                                 with: .color(HistogramPlot.tint(currentChannel).opacity(0.18)))
                }
                var diagonal = Path()
                diagonal.move(to: CGPoint(x: 0, y: rect.height)); diagonal.addLine(to: CGPoint(x: rect.width, y: 0))
                context.stroke(diagonal, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                // The other channels' curves, faint, when they bend.
                for other in ToneCurve.Channel.allCases where other != currentChannel && !shownCurve.isIdentity(other) {
                    context.stroke(Self.path(shownCurve.points(other), in: rect), with: .color(HistogramPlot.tint(other).opacity(0.35)), lineWidth: 1)
                }
                let edited = points.enumerated().filter { $0.offset != hidden }.map(\.element)
                context.stroke(Self.path(edited, in: rect), with: .color(HistogramPlot.tint(currentChannel)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for (index, point) in points.enumerated() where index != hidden {
                    let center = Self.location(of: point, side: rect.width)
                    let isSelected = index == selectedIndex
                    let radius: CGFloat = isSelected ? 7 : 5
                    let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(isSelected ? Color.psValueAccent : .black))
                    context.stroke(dot, with: .color(isSelected ? .black : .white), lineWidth: 1.5)
                }
            }
            .background(Color.psFillControl, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture(side: side))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Curves"))
            .accessibilityValue(Self.channelName(currentChannel))
            .accessibilityHint(L("Tap the curve to add a point, drag it to shape the tones."))

            readout(points: points)
                .padding(8)
                .allowsHitTesting(false)

            // One adjustable element per point for VoiceOver (44-point frames, invisible).
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Color.clear
                    .frame(width: 44, height: 44)
                    .position(Self.location(of: point, side: side))
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(String(format: L("Curve point %d"), index + 1))
                    .accessibilityValue(String(format: L("Input %d, output %d"), Self.level(point.input), Self.level(point.output)))
                    .accessibilityAdjustableAction { direction in
                        nudge(index, by: direction == .increment ? 1.0 / 255 : -1.0 / 255)
                    }
            }
        }
    }

    @ViewBuilder
    private func readout(points: [ToneCurve.Point]) -> some View {
        if let index = drag?.index ?? selected, index < points.count {
            let point = points[index]
            Text(verbatim: "\(Self.level(point.input)) → \(Self.level(point.output))")
                .font(PSFontRole.valueReadout)
                .foregroundStyle(abs(point.input - point.output) > 0.5 / 255 ? Color.psValueAccent : Color.psTextPrimary)
                .contentTransition(.numericText())
        }
    }

    static func level(_ value: Double) -> Int { Int((value * 255).rounded()) }

    /// A unit point in the graph (top-left origin, y up in value).
    static func location(of point: ToneCurve.Point, side: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(point.input) * side, y: CGFloat(1 - point.output) * side)
    }

    static func path(_ points: [ToneCurve.Point], in rect: CGRect) -> Path {
        let samples = CurveSpline.table(points, count: 129)
        var path = Path()
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: rect.width * CGFloat(index) / 128, y: rect.height * (1 - CGFloat(value)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    // MARK: Gestures

    private func dragGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !touching {
                    touching = true
                    begin(at: value.startLocation, side: side)
                }
                guard var current = drag else { return }
                let translation = value.translation
                if abs(translation.width) > 3 || abs(translation.height) > 3 { current.moved = true }
                guard current.moved else { return }
                let dx = Double(translation.width / side), dy = Double(-translation.height / side)
                var points = shownPoints(liveCurve ?? session.userToneCurve)
                guard current.index < points.count else { return }
                let isEnd = current.index == 0 || current.index == points.count - 1
                // Out of the graph by more than a finger: the point is on its way out.
                let outside = value.location.x < -30 || value.location.x > side + 30 || value.location.y < -30 || value.location.y > side + 30
                current.isRemoving = outside && !isEnd && points.count > 2
                let low = current.index > 0 ? points[current.index - 1].input + 0.01 : 0
                let high = current.index < points.count - 1 ? points[current.index + 1].input - 0.01 : 1
                let input = (current.start.input + dx).clamped(to: min(low, high)...max(low, high))
                points[current.index] = ToneCurve.Point(input, (current.start.output + dy).clamped(to: 0...1))
                drag = current
                apply(points, inGesture: true)
            }
            .onEnded { _ in end() }
    }

    /// Picks the point under the finger, or adds one on the curve there.
    private func begin(at location: CGPoint, side: CGFloat) {
        var points = shownPoints(curve)
        let nearest = points.indices.min { distance(points[$0], location, side) < distance(points[$1], location, side) }
        if let nearest, distance(points[nearest], location, side) <= Self.hitRadius {
            drag = Drag(index: nearest, start: points[nearest])
            selected = nearest
            Haptics.tick()
            return
        }
        guard points.count < ToneCurve.maxPoints else {
            Haptics.warning()
            return
        }
        let input = Double(location.x / side).clamped(to: 0...1)
        guard !points.contains(where: { abs($0.input - input) < 0.01 }) else { return }
        let point = ToneCurve.Point(input, CurveSpline.evaluate(points, at: input))
        let index = points.firstIndex { $0.input > input } ?? points.count
        points.insert(point, at: index)
        drag = Drag(index: index, start: point, moved: true)
        selected = index
        apply(points, inGesture: true)
        Haptics.tick()
    }

    private func end() {
        let finished = drag
        var points = shownPoints(liveCurve ?? session.userToneCurve)
        if let finished, finished.index < points.count {
            if finished.isRemoving {
                points.remove(at: finished.index)
                selected = nil
                apply(points, inGesture: true)
                Haptics.confirm()
            } else if !finished.moved {
                // A tap on a point: twice in a row removes it (not an end).
                let now = Date()
                if let last = lastTap, last.index == finished.index, now.timeIntervalSince(last.time) < 0.35,
                   finished.index > 0, finished.index < points.count - 1 {
                    points.remove(at: finished.index)
                    selected = nil
                    lastTap = nil
                    apply(points, inGesture: true)
                    Haptics.confirm()
                } else {
                    lastTap = (finished.index, now)
                }
            }
        }
        if interacting { session.endInteraction() }
        interacting = false
        touching = false
        drag = nil
        liveCurve = nil
    }

    private func distance(_ point: ToneCurve.Point, _ location: CGPoint, _ side: CGFloat) -> CGFloat {
        let center = Self.location(of: point, side: side)
        return hypot(center.x - location.x, center.y - location.y)
    }

    /// The channel's new points into the live curve and the session: inside a gesture, a frame of
    /// one undo step (the hooks open on the first change); outside, one step at once.
    private func apply(_ points: [ToneCurve.Point], inGesture: Bool) {
        var next = liveCurve ?? session.userToneCurve
        next.setPoints(points, for: channel)
        if inGesture {
            if !interacting {
                session.beginInteraction(label: "Curves")
                interacting = true
            }
            liveCurve = next
        }
        session.setToneCurve(next)
    }

    /// VoiceOver's adjust: one step of output, committed at once.
    private func nudge(_ index: Int, by delta: Double) {
        var points = shownPoints(curve)
        guard index < points.count else { return }
        points[index] = ToneCurve.Point(points[index].input, (points[index].output + delta).clamped(to: 0...1))
        var next = curve
        next.setPoints(points, for: channel)
        session.setToneCurve(next)
    }

    // MARK: Presets

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([ToneCurve.Preset.sCurve, .strongS, .matte, .fade, .brighten, .darken, .invert]) { preset in
                    PanelChip(title: psPrefersFrench ? preset.frenchName : preset.englishName) { applyPreset(preset) }
                }
                PanelChip(title: L("Histogram"), symbol: "chart.bar.fill", isActive: tone.showsHistogramCard) {
                    withAnimation(PSMotion.quick) { tone.showsHistogramCard.toggle() }
                }
                PanelChip(title: L("Reset"), symbol: "arrow.counterclockwise", isEnabled: !session.userToneCurve.isIdentity) {
                    selected = nil
                    session.resetToneCurve()
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// A preset on the channel being edited, at half strength: one step.
    private func applyPreset(_ preset: ToneCurve.Preset) {
        var next = session.userToneCurve
        next.setPoints(preset.points(strength: 0.5), for: channel)
        selected = nil
        session.setToneCurve(next)
        Haptics.confirm()
    }
}
#endif
