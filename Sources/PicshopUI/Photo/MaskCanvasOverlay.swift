#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PicshopCore
import PicshopImaging

/// The Masques and Sélection layer of the canvas (W2): the selected gradient's handles, the brush cursor (outer
/// circle the size, inner circle the hardness), the frame being drawn around an object, and Quick Selection's
/// prompt dots. Drawing only: the canvas's own gesture asks the session which handle a touch grabs
/// (`MaskHandleGeometry`), so pinch and pan are never blocked. A leaf: it reads the live handle, the cursor and
/// the box, never the history.
struct MaskCanvasOverlay: View {
    let session: PhotoEditorSession
    let stroke: StrokeInProgress
    let frame: CGRect

    var body: some View {
        let placement = MaskHandleGeometry.Placement(frame: PSRect(frame))
        ZStack {
            if session.activeTool == .masks {
                MaskHandles(session: session, placement: placement)
                MaskBrushCursor(session: session, stroke: stroke, placement: placement)
            }
            if session.activeTool == .select {
                QuickPromptDots(session: session, frame: frame)
            }
            BoxDragOutline(state: session.selectionState, frame: frame)
        }
        .allowsHitTesting(false)
    }
}

/// The gradient's handles: a linear gradient's three lines (full, centre, none) with their knobs; a radial's
/// ellipse, its dashed feather ellipse, four edge knobs, the rotation knob and the centre. The knob under the
/// finger is yellow (an active handle). VoiceOver adjusts them (grow or shrink, move along the axis).
private struct MaskHandles: View {
    let session: PhotoEditorSession
    let placement: MaskHandleGeometry.Placement

    var body: some View {
        if let handle = session.handleComponent {
            let component = handle.component
            let live = session.maskState.liveComponent
            let kind = live?.id == component.id ? live!.kind : component.kind
            let active = session.maskState.handleDrag?.handle
            Canvas { context, _ in
                switch kind {
                case .linear(let spec): Self.drawLinear(spec, active: active, placement: placement, in: &context)
                case .radial(let spec): Self.drawRadial(spec, active: active, placement: placement, in: &context)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Self.label(kind))
            .accessibilityHint(L("Swipe up or down to adjust."))
            .accessibilityAdjustableAction { direction in
                session.nudgeHandles(by: direction == .increment ? 1 : -1)
            }
            .accessibilityIdentifier(Self.isLinear(kind) ? "masks.handles.linear" : "masks.handles.radial")
        }
    }

    private static func isLinear(_ kind: MaskComponent.Kind) -> Bool {
        if case .linear = kind { return true }
        return false
    }

    private static func label(_ kind: MaskComponent.Kind) -> String {
        MaskAccessibility.componentName(kind, language: psPrefersFrench ? .fr : .en)
    }

    private static func knob(_ position: PSPoint, active: Bool, radius: CGFloat = 7, in context: inout GraphicsContext) {
        let center = position.cgPoint
        let r = active ? radius + 2 : radius
        let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.fill(dot, with: .color(active ? Color.psValueAccent : Color.psActionPrimary))
        context.stroke(dot, with: .color(Color.psScrim), lineWidth: 1)
    }

    static func drawLinear(_ spec: LinearGradientSpec, active: MaskHandleGeometry.Handle?, placement: MaskHandleGeometry.Placement,
                           in context: inout GraphicsContext) {
        for line in MaskHandleGeometry.lines(spec, in: placement) {
            var path = Path()
            path.move(to: line.from.cgPoint)
            path.addLine(to: line.to.cgPoint)
            let isCenter = line.handle == .linearCenter
            // A shadow line under each, so they read on light and dark pictures.
            context.stroke(path, with: .color(Color.psScrim), style: StrokeStyle(lineWidth: isCenter ? 2.5 : 3))
            context.stroke(path, with: .color(line.handle == active ? Color.psValueAccent : Color.psActionPrimary),
                           style: StrokeStyle(lineWidth: isCenter ? 1.5 : 1, dash: isCenter ? [] : [6, 4]))
        }
        for knob in MaskHandleGeometry.knobs(spec, in: placement) {
            Self.knob(knob.position, active: knob.handle == active, radius: knob.handle == .linearCenter ? 8 : 6, in: &context)
        }
    }

    static func drawRadial(_ spec: RadialGradientSpec, active: MaskHandleGeometry.Handle?, placement: MaskHandleGeometry.Placement,
                           in context: inout GraphicsContext) {
        func closed(_ points: [PSPoint]) -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first.cgPoint)
            for point in points.dropFirst() { path.addLine(to: point.cgPoint) }
            path.closeSubpath()
            return path
        }
        let outline = closed(MaskHandleGeometry.ellipse(spec, in: placement))
        context.stroke(outline, with: .color(Color.psScrim), lineWidth: 3)
        context.stroke(outline, with: .color(Color.psActionPrimary), lineWidth: 1.5)
        let feather = spec.feather.isFinite ? spec.feather.clamped(to: 0...1) : 0
        if feather > 0.01 {
            let inner = closed(MaskHandleGeometry.ellipse(spec, scale: 1 - feather, in: placement))
            context.stroke(inner, with: .color(Color.psActionPrimary), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        let knobs = MaskHandleGeometry.knobs(spec, in: placement)
        // The rotation knob hangs on a short stem from the top edge.
        if let top = knobs.first(where: { $0.handle == .radialNegativeY }), let rotation = knobs.first(where: { $0.handle == .radialRotation }) {
            var stem = Path()
            stem.move(to: top.position.cgPoint)
            stem.addLine(to: rotation.position.cgPoint)
            context.stroke(stem, with: .color(Color.psActionPrimary), lineWidth: 1)
        }
        for knob in knobs {
            switch knob.handle {
            case .radialCenter:
                let center = knob.position.cgPoint
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - 9, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 9, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - 9)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 9))
                context.stroke(cross, with: .color(Color.psScrim), lineWidth: 3)
                context.stroke(cross, with: .color(knob.handle == active ? Color.psValueAccent : Color.psActionPrimary), lineWidth: 1.5)
            case .radialRotation:
                Self.knob(knob.position, active: knob.handle == active, radius: 6, in: &context)
            case .radialFeather:
                Self.knob(knob.position, active: knob.handle == active, radius: 5, in: &context)
            default:
                Self.knob(knob.position, active: knob.handle == active, in: &context)
            }
        }
    }
}

/// The mask brush's cursor: the outer circle is the brush, the inner one where its hardness ends. Under the finger
/// while painting, at the centre while the size slider moves.
private struct MaskBrushCursor: View {
    let session: PhotoEditorSession
    let stroke: StrokeInProgress
    let placement: MaskHandleGeometry.Placement

    var body: some View {
        if session.paintsMask || session.showsBrushPreview {
            let settings = session.maskState.brush
            let cursor = stroke.cursor ?? (session.showsBrushPreview ? CGPoint(x: placement.frame.midX, y: placement.frame.midY) : nil)
            let radius = CGFloat(MaskHandleGeometry.brushCursorRadius(settings.size, in: placement))
            Canvas { context, _ in
                guard let cursor else { return }
                let outer = max(3, radius)
                let inner = outer * CGFloat(settings.hardness)
                let outerCircle = Path(ellipseIn: CGRect(x: cursor.x - outer, y: cursor.y - outer, width: outer * 2, height: outer * 2))
                context.stroke(outerCircle, with: .color(Color.psScrim), lineWidth: 2.5)
                context.stroke(outerCircle, with: .color(settings.erase ? Color.psDanger : Color.psActionPrimary), lineWidth: 1.5)
                if inner > 2, inner < outer - 1 {
                    let innerCircle = Path(ellipseIn: CGRect(x: cursor.x - inner, y: cursor.y - inner, width: inner * 2, height: inner * 2))
                    context.stroke(innerCircle, with: .color(Color.psActionPrimary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if settings.erase {
                    var minus = Path()
                    minus.move(to: CGPoint(x: cursor.x - 5, y: cursor.y)); minus.addLine(to: CGPoint(x: cursor.x + 5, y: cursor.y))
                    context.stroke(minus, with: .color(Color.psActionPrimary), lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Quick Selection's prompts: white dots add, red ones remove.
private struct QuickPromptDots: View {
    let session: PhotoEditorSession
    let frame: CGRect

    var body: some View {
        let prompts = session.selectionState.mode == .quick ? session.selectionState.quickPrompts : []
        if !prompts.isEmpty {
            Canvas { context, _ in
                for prompt in prompts {
                    let center = CGPoint(x: frame.minX + CGFloat(prompt.point.x) * frame.width, y: frame.minY + CGFloat(prompt.point.y) * frame.height)
                    let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                    context.fill(dot, with: .color(prompt.isPositive ? Color.psActionPrimary : Color.psDanger))
                    context.stroke(dot, with: .color(Color.psScrim), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The frame being drawn around an object (Objet, in Masques and Sélection).
private struct BoxDragOutline: View {
    let state: PhotoSelectionState
    let frame: CGRect

    var body: some View {
        if let box = state.boxDrag {
            let rect = CGRect(x: frame.minX + CGFloat(box.minX) * frame.width, y: frame.minY + CGFloat(box.minY) * frame.height,
                              width: CGFloat(box.width) * frame.width, height: CGFloat(box.height) * frame.height)
            Canvas { context, _ in
                let path = Path(rect)
                context.stroke(path, with: .color(Color.psScrim), lineWidth: 3)
                context.stroke(path, with: .color(Color.psActionPrimary), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .accessibilityHidden(true)
        }
    }
}

/// A two-finger drag (UIKit's pan with two touches): pans the canvas while a mask or selection tool owns the
/// one-finger drag. Reports the translation since it began, and when it begins and ends.
struct TwoFingerPan: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.cancelsTouchesInView = false
        // Pinch (SwiftUI's magnify) keeps working alongside it.
        recognizer.delegate = context.coordinator
        return recognizer
    }

    /// Lets the pan recognise together with the canvas's other gestures.
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began:
            onBegan()
        case .changed:
            onChanged(CGSize(width: translation.x, height: translation.y))
        case .ended, .cancelled, .failed:
            onEnded()
        default:
            break
        }
    }
}
#endif
