#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// Transform mode's handles on the canvas (W3, D10; §7.4): the layer's quad (a 1-point white line inside a 1-point
/// black one), white 10-point squares at the corners, capsules on the edges, the rotation knob and the pivot, drawn by
/// one `Canvas` whose inputs are the view quad only, so it invalidates at the drag's rate while the picture itself
/// moves through the frame pump. Touches go to the canvas's gesture (`transformHandle(at:frame:)`); the handles are
/// VoiceOver adjustable elements (« Largeur 120 % », ±5 % or ±5°).
struct LayerTransformOverlay: View {
    let session: PhotoEditorSession
    let frame: CGRect

    var body: some View {
        let state = session.layerState
        let quad = state.mode == .transform ? state.liveQuad : []
        if quad.count == 4 {
            let viewQuad = quad.map { CGPoint(x: frame.minX + CGFloat($0.x) * frame.width, y: frame.minY + CGFloat($0.y) * frame.height) }
            let handles = TransformHandles.handles(viewQuad: viewQuad.map { PSPoint(x: Double($0.x), y: Double($0.y)) })
            ZStack {
                Canvas { context, _ in
                    Self.draw(viewQuad, handles: handles, in: &context)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                TransformHandleElements(session: session, handles: handles)
            }
        }
    }

    /// The quad, its handles, the knob's stem and the pivot.
    static func draw(_ quad: [CGPoint], handles: [TransformHandle], in context: inout GraphicsContext) {
        var outline = Path()
        outline.addLines(quad)
        outline.closeSubpath()
        context.stroke(outline, with: .color(.psCanvas), lineWidth: 3)
        context.stroke(outline, with: .color(.psActionPrimary), lineWidth: 1)
        for handle in handles {
            let point = CGPoint(x: handle.position.x, y: handle.position.y)
            switch handle.kind {
            case .corner:
                let square = Path(CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                context.fill(square, with: .color(.psActionPrimary))
                context.stroke(square, with: .color(.psCanvas), lineWidth: 1)
            case .edge(let index):
                let a = quad[index], b = quad[(index + 1) % 4]
                let angle = atan2(b.y - a.y, b.x - a.x)
                var capsule = Path(roundedRect: CGRect(x: -8, y: -3, width: 16, height: 6), cornerSize: CGSize(width: 3, height: 3))
                capsule = capsule.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: point.x, y: point.y)))
                context.fill(capsule, with: .color(.psActionPrimary))
                context.stroke(capsule, with: .color(.psCanvas), lineWidth: 1)
            case .rotate:
                let top = CGPoint(x: (quad[0].x + quad[1].x) / 2, y: (quad[0].y + quad[1].y) / 2)
                var stem = Path()
                stem.move(to: top)
                stem.addLine(to: point)
                context.stroke(stem, with: .color(.psActionPrimary), lineWidth: 1)
                let knob = Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                context.fill(knob, with: .color(.psActionPrimary))
                context.stroke(knob, with: .color(.psCanvas), lineWidth: 1)
                let arrow = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                context.stroke(arrow, with: .color(.psCanvas), lineWidth: 1.5)
            case .pivot:
                var cross = Path()
                cross.move(to: CGPoint(x: point.x - 6, y: point.y))
                cross.addLine(to: CGPoint(x: point.x + 6, y: point.y))
                cross.move(to: CGPoint(x: point.x, y: point.y - 6))
                cross.addLine(to: CGPoint(x: point.x, y: point.y + 6))
                context.stroke(cross, with: .color(.psCanvas), lineWidth: 3)
                context.stroke(cross, with: .color(.psActionPrimary), lineWidth: 1)
            case .inside:
                break
            }
        }
    }
}

/// The handles as VoiceOver elements: a corner or an edge adjusts the size by ±5 %, the knob the rotation by ±5°.
private struct TransformHandleElements: View {
    let session: PhotoEditorSession
    let handles: [TransformHandle]

    var body: some View {
        let language: OpLanguage = psPrefersFrench ? .fr : .en
        let figures = session.layerState.transform.figures
        ZStack {
            ForEach(Array(handles.enumerated()), id: \.offset) { _, handle in
                if LayerAccessibility.isAdjustable(handle.kind) {
                    Color.clear
                        .frame(width: TransformHandles.hitRadius * 2, height: TransformHandles.hitRadius * 2)
                        .position(x: handle.position.x, y: handle.position.y)
                        .accessibilityElement()
                        .accessibilityLabel(LayerAccessibility.handleName(handle.kind, language: language))
                        .accessibilityValue(LayerAccessibility.handleValue(handle.kind, figures: figures, language: language))
                        .accessibilityAdjustableAction { direction in
                            session.adjustHandle(handle.kind, increment: direction == .increment)
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A gradient fill's on-canvas handles (Calques open on a gradient layer): its centre, and its angle on a knob 64
/// points out. A drag is one step on the `.fillLayer` snapshot.
struct GradientHandlesOverlay: View {
    let session: PhotoEditorSession
    let frame: CGRect

    @State private var liveCenter: PSPoint?
    @State private var liveAngle: Double?

    private static let reach: CGFloat = 64

    var body: some View {
        if session.activeTool == .layers, session.layerState.mode == .select, let layer = session.document.selectedLayer,
           case .gradientFill(let gradient) = layer.content {
            let center = liveCenter ?? gradient.center
            let angle = liveAngle ?? gradient.angle
            let point = CGPoint(x: frame.minX + CGFloat(center.x) * frame.width, y: frame.minY + CGFloat(center.y) * frame.height)
            let radians = angle * .pi / 180
            let knob = CGPoint(x: point.x + Self.reach * CGFloat(cos(radians)), y: point.y - Self.reach * CGFloat(sin(radians)))
            ZStack {
                Path { path in
                    path.move(to: point)
                    path.addLine(to: knob)
                }
                .stroke(Color.psActionPrimary, lineWidth: 1)
                .shadow(color: Color.psScrim, radius: 1)
                .allowsHitTesting(false)
                handle(diameter: 16)
                    .position(point)
                    .gesture(centerDrag(layerID: layer.id))
                    .accessibilityLabel(L("Gradient centre"))
                handle(diameter: 12)
                    .position(knob)
                    .gesture(angleDrag(layerID: layer.id, center: point))
                    .accessibilityLabel(L("Gradient angle"))
                    .accessibilityValue(LayerAccessibility.degrees(angle, language: psPrefersFrench ? .fr : .en))
                    .accessibilityAdjustableAction { direction in
                        session.setGradientGeometry(angle: angle + (direction == .increment ? 5 : -5), layerID: layer.id)
                    }
            }
            .accessibilityIdentifier("layers.fill.handles")
        }
    }

    private func handle(diameter: CGFloat) -> some View {
        Circle()
            .fill(Color.psActionPrimary)
            .overlay(Circle().strokeBorder(Color.psCanvas, lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .frame(width: PSMetrics.control, height: PSMetrics.control)
            .contentShape(Rectangle())
    }

    private func centerDrag(layerID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if liveCenter == nil {
                    guard session.beginGradientDrag(layerID) else { return }
                }
                let center = PSPoint(x: Double((value.location.x - frame.minX) / max(1, frame.width)),
                                     y: Double((value.location.y - frame.minY) / max(1, frame.height)))
                liveCenter = center
                session.setGradientGeometry(center: center, layerID: layerID)
            }
            .onEnded { _ in
                guard liveCenter != nil else { return }
                liveCenter = nil
                session.endInteraction()
            }
    }

    private func angleDrag(layerID: UUID, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if liveAngle == nil {
                    guard session.beginGradientDrag(layerID) else { return }
                }
                var degrees = Double(atan2(-(value.location.y - center.y), value.location.x - center.x)) * 180 / .pi
                // 15° snaps, as the transform's rotation.
                let snap = TransformHandles.rotationSnap(degrees)
                if snap.snapped { degrees = snap.degrees }
                liveAngle = degrees
                session.setGradientGeometry(angle: degrees, layerID: layerID)
            }
            .onEnded { _ in
                guard liveAngle != nil else { return }
                liveAngle = nil
                session.endInteraction()
            }
    }
}
#endif
