#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore

/// The smart guides engaged this frame (W3, D10): 1-point yellow lines (a value colour: where the layer snapped) over
/// the canvas, never under glass. Reads `layerState.guides` only, written at the drag's rate when they change; the
/// rigid snap haptic is the session's (throttled to 16 ms).
struct SmartGuidesOverlay: View {
    let session: PhotoEditorSession
    let frame: CGRect

    var body: some View {
        let guides = session.layerState.guides
        if !guides.isEmpty {
            Canvas { context, _ in
                for guide in guides {
                    var path = Path()
                    switch guide.axis {
                    case .vertical:
                        let x = frame.minX + CGFloat(guide.line.value) * frame.width
                        path.move(to: CGPoint(x: x, y: frame.minY + CGFloat(guide.span.lowerBound) * frame.height))
                        path.addLine(to: CGPoint(x: x, y: frame.minY + CGFloat(guide.span.upperBound) * frame.height))
                    case .horizontal:
                        let y = frame.minY + CGFloat(guide.line.value) * frame.height
                        path.move(to: CGPoint(x: frame.minX + CGFloat(guide.span.lowerBound) * frame.width, y: y))
                        path.addLine(to: CGPoint(x: frame.minX + CGFloat(guide.span.upperBound) * frame.width, y: y))
                    }
                    context.stroke(path, with: .color(.psValueAccent), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
