#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// A gradient fill's stops (W3, D9; the `gradientStops` custom row of `fillLayer`): the gradient drawn over the
/// checkerboard, a 44-point target per stop. Drag a stop to move it, drag it off the bar to remove it (two stay at
/// least), tap the bar to add one with the colour there; the selected stop's colour is edited in the well below. A drag
/// is one undo step on the `.fillLayer` snapshot; the bar follows the finger from its own copy of the stops.
struct GradientEditor: View {
    let session: PhotoEditorSession
    let layerID: UUID
    let gradient: GradientFill

    @State private var live: [GradientStop]?
    @State private var selected = 0
    @State private var dragged: Int?
    @State private var removing = false
    @State private var width: CGFloat = 1

    private static let barHeight: CGFloat = 28
    private static let target: CGFloat = 44

    private var stops: [GradientStop] { live ?? gradient.stops }

    var body: some View {
        let current = stops
        VStack(alignment: .leading, spacing: PSSpacing.small) {
            ZStack(alignment: .topLeading) {
                bar(current)
                    .frame(height: Self.barHeight)
                    .padding(.horizontal, Self.target / 2)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in addStop(at: value.location.x - Self.target / 2) })
                ForEach(Array(current.enumerated()), id: \.offset) { index, stop in
                    handle(stop, index: index)
                        .position(x: Self.target / 2 + CGFloat(stop.location) * width, y: Self.barHeight + Self.target / 2 - 6)
                }
            }
            .frame(height: Self.barHeight + Self.target)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - Self.target } action: { width = max(1, $0) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Gradient stops"))
            .accessibilityIdentifier("layers.fill.stops")
            if current.indices.contains(selected) {
                InspectorColorRow(label: String(format: L("Stop %d"), selected + 1), color: current[selected].color, supportsOpacity: true,
                                  controlID: "layers.fill.stops") { color in
                    var edited = gradient.stops
                    guard edited.indices.contains(selected) else { return }
                    edited[selected].color = color
                    session.setGradientStops(edited, layerID: layerID)
                }
            }
        }
    }

    private func bar(_ stops: [GradientStop]) -> some View {
        let shape = RoundedRectangle(cornerRadius: PSRadius.tiny, style: .continuous)
        return ZStack {
            LayerCheckerboard()
            LinearGradient(stops: stops.sorted { $0.location < $1.location }
                .map { Gradient.Stop(color: Color(psColor: $0.color), location: CGFloat($0.location)) },
                           startPoint: .leading, endPoint: .trailing)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.psStrokeStrong, lineWidth: 1))
    }

    private func handle(_ stop: GradientStop, index: Int) -> some View {
        let isSelected = index == selected
        let isLeaving = dragged == index && removing
        return VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.psActionPrimary : Color.psTextSecondary)
            Circle()
                .fill(Color(psColor: stop.color))
                .overlay(Circle().strokeBorder(isSelected ? Color.psActionPrimary : Color.psStrokeStrong, lineWidth: 2))
                .frame(width: 22, height: 22)
        }
        .frame(width: Self.target, height: Self.target)
        .contentShape(Rectangle())
        .opacity(isLeaving ? 0.3 : 1)
        .scaleEffect(dragged == index ? 1.15 : 1)
        .animation(PSSpring.quick, value: dragged)
        .gesture(dragGesture(index))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: L("Stop %d"), index + 1))
        .accessibilityValue("\(Int((stop.location * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            var edited = gradient.stops
            guard edited.indices.contains(index) else { return }
            edited[index].location = (edited[index].location + (direction == .increment ? 0.05 : -0.05)).clamped(to: 0...1)
            session.setGradientStops(edited, layerID: layerID)
        }
    }

    /// Moves a stop with the finger; past 44 points below the bar it is removed on release.
    private func dragGesture(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragged == nil {
                    guard session.beginGradientDrag(layerID) else { return }
                    dragged = index
                    selected = index
                    live = gradient.stops
                    Haptics.tick()
                }
                guard dragged == index, var edited = live, edited.indices.contains(index) else { return }
                let canRemove = edited.count > 2
                let leaving = canRemove && value.translation.height > Self.target
                if leaving != removing {
                    removing = leaving
                    Haptics.tick()
                }
                let start = gradient.stops.indices.contains(index) ? gradient.stops[index].location : 0
                edited[index].location = (start + Double(value.translation.width / width)).clamped(to: 0...1)
                live = edited
                var applied = edited
                if leaving { applied.remove(at: index) }
                session.setGradientStops(applied, layerID: layerID)
            }
            .onEnded { _ in
                guard dragged == index else { return }
                if removing {
                    selected = 0
                }
                dragged = nil
                removing = false
                live = nil
                session.endInteraction()
            }
    }

    /// A tap on the bar: a stop there with the gradient's colour at that point (one step; 8 at most).
    private func addStop(at x: CGFloat) {
        guard gradient.stops.count < 8 else { return }
        let location = Double(x / width).clamped(to: 0...1)
        var edited = gradient.stops
        edited.append(GradientStop(location: location, color: gradient.color(at: location)))
        edited.sort { $0.location < $1.location }
        Haptics.tick()
        session.setGradientStops(edited, layerID: layerID)
        selected = edited.firstIndex { $0.location == location } ?? 0
    }
}

extension PhotoEditorSession {
    /// A stop drag begins on a gradient fill: one step on the `.fillLayer` snapshot (refused by a content lock).
    func beginGradientDrag(_ layerID: UUID) -> Bool {
        guard layerAllows(.content, on: layerID) else { return false }
        beginInteraction(label: "Fill Layer", scope: .fillLayer(layerID))
        return true
    }

    /// The gradient's stops (2…8), on the dragged copy during a drag, else one step.
    func setGradientStops(_ stops: [GradientStop], layerID: UUID) {
        guard stops.count >= 2, case .gradientFill? = document.layer(id: layerID)?.content else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        interactiveEdit(label: "Fill Layer") { document in
            guard case .gradientFill(var gradient)? = document.layer(id: layerID)?.content else { return }
            gradient.stops = stops.sorted { $0.location < $1.location }
            document.applyLayerEdit(.gradient(gradient), to: layerID)
        }
    }

    /// The gradient's centre (canvas-normalised) or angle from the on-canvas handles, on the dragged copy.
    func setGradientGeometry(center: PSPoint? = nil, angle: Double? = nil, layerID: UUID) {
        guard case .gradientFill? = document.layer(id: layerID)?.content else { return }
        if interaction == nil, !layerAllows(.content, on: layerID) { return }
        interactiveEdit(label: "Fill Layer") { document in
            guard case .gradientFill(var gradient)? = document.layer(id: layerID)?.content else { return }
            if let center { gradient.center = PSPoint(x: center.x.clamped(to: 0...1), y: center.y.clamped(to: 0...1)) }
            if let angle { gradient.angle = LayerTransformFigures.normalizedDegrees(angle) }
            document.applyLayerEdit(.gradient(gradient), to: layerID)
        }
    }
}
#endif
