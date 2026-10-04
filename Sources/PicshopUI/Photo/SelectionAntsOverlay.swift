#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import PicshopCore
import PicshopImaging

/// The selection's marching ants, in every photo tool (W2): the outline traced by `SelectionContour` (off the main
/// thread, through the selection's corners), stroked in white and black one-point dashes that move at 12 points a
/// second. Flat strokes, no glass. Paused under Reduce Motion and while a finger is on the canvas (drawing, pinching
/// or panning, as one plain line); hidden while cropping and while the original shows.
struct SelectionAntsOverlay: View {
    let session: PhotoEditorSession
    let frame: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = session.selectionState
        if FeatureFlags.isOn(.aiSelection), !state.contour.isEmpty, !session.isCropping, !session.showsOriginal {
            // The outline was built once in unit space (bounded off the main thread): a zoom or a pan only scales it.
            let path = state.contourPath.applying(CGAffineTransform(a: frame.width, b: 0, c: 0, d: frame.height, tx: frame.minX, ty: frame.minY))
            let interacting = session.app.performance.isCanvasInteracting
            let paused = reduceMotion || interacting
            // PicshopUI declares its own TimelineView (Video): SwiftUI's is always qualified.
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate * 12).truncatingRemainder(dividingBy: 8)
                Canvas { context, _ in
                    if interacting {
                        // A finger on the canvas (a stroke, a pinch, a pan): one plain line, restroked cheaply per frame.
                        context.stroke(path, with: .color(Color.psActionPrimary), lineWidth: 1)
                    } else {
                        context.stroke(path, with: .color(Color.psOnAction), style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase + 4))
                        context.stroke(path, with: .color(Color.psActionPrimary), style: StrokeStyle(lineWidth: 1, dash: [4, 4], dashPhase: phase))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The outline in view points (closed subpaths).
    static func path(_ contour: [[PSPoint]], in frame: CGRect) -> Path {
        var path = Path()
        for ring in contour {
            guard let first = ring.first else { continue }
            path.move(to: CGPoint(x: frame.minX + CGFloat(first.x) * frame.width, y: frame.minY + CGFloat(first.y) * frame.height))
            for point in ring.dropFirst() {
                path.addLine(to: CGPoint(x: frame.minX + CGFloat(point.x) * frame.width, y: frame.minY + CGFloat(point.y) * frame.height))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// Outside Sélection, while a selection exists: « Sélection · 12 % ✕ » on the canvas. A tap opens Sélection, ✕
/// deselects (one step).
struct SelectionChip: View {
    let session: PhotoEditorSession

    var body: some View {
        if FeatureFlags.isOn(.aiSelection), let selection = session.document.selection, session.activeTool != .select, !session.isCropping {
            let percent = Int((selection.coverage * 100).rounded())
            HStack(spacing: PSSpacing.small) {
                Button {
                    Haptics.tap()
                    session.activeTool = .select
                } label: {
                    HStack(spacing: PSSpacing.xSmall) {
                        Image(systemName: "lasso").font(PSFont.glyph(.micro))
                        Text(String(format: L("Selection · %d %%"), max(1, percent)))
                            .font(.footnote.weight(.medium).monospacedDigit())
                    }
                    .foregroundStyle(Color.psTextPrimary)
                    .padding(.leading, PSSpacing.medium)
                    .frame(minHeight: PSMetrics.chip)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PSPressStyle(scale: 0.96))
                .accessibilityLabel(String(format: L("Selection, %d percent of the picture"), max(1, percent)))
                .accessibilityHint(L("Opens Selection."))
                Button {
                    Haptics.tap()
                    session.deselect()
                } label: {
                    Image(systemName: "xmark")
                        .font(PSFont.glyph(.micro, weight: .semibold))
                        .foregroundStyle(Color.psTextSecondary)
                        .frame(width: PSMetrics.chip, height: PSMetrics.chip)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PSPressStyle(scale: 0.9))
                .accessibilityLabel(L("Deselect"))
                .accessibilityIdentifier("select.chip.deselect")
            }
            .psGlass(interactive: true, variant: .clear)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}
#endif
