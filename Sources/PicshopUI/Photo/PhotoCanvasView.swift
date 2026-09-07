#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreImage
import PicshopCore
import PicshopImaging

/// Metal-backed image view bridged into SwiftUI.
struct MetalCanvasRepresentable: UIViewRepresentable {
    var image: CIImage?
    var overlay: CIImage?
    var frame: CGRect

    func makeUIView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MetalCanvasView, context: Context) {
        view.image = image
        view.overlay = overlay
        view.imageFrame = frame
        view.setNeedsDisplay()
    }
}

/// Zoomable, pannable canvas with tap, brush and press-to-compare gestures
/// plus candidate highlight overlays.
struct PhotoCanvasView: View {
    @Bindable var session: PhotoEditorSession
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var currentStroke: [PSPoint] = []
    @State private var currentStrokeID: UUID?
    @GestureState private var isPressing = false

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let frame = imageFrame(in: container)
            ZStack {
                PSTheme.canvas
                MetalCanvasRepresentable(image: session.preview, overlay: session.selectionPreview, frame: frame)
                overlays(frame: frame)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(canvasGesture(frame: frame))
            .simultaneousGesture(compareGesture)
            .onChange(of: isPressing) { _, pressing in
                if session.activeTool != .erase, session.activeTool != .precise { session.showsOriginal = pressing }
            }
            .onChange(of: session.zoomRequest) { _, request in
                guard let request else { return }
                applyZoomRequest(request, container: container)
                session.zoomRequest = nil
            }
            .onChange(of: session.document.canvasSize) { _, _ in resetZoom() }
            .accessibilityLabel(L("Photo canvas"))
            .accessibilityHint(L("Double tap to reset zoom. Pinch to zoom."))
        }
    }

    // MARK: Layout

    private func imageFrame(in container: CGSize) -> CGRect {
        let aspect = CGFloat(max(0.05, session.document.aspectRatio))
        let inset: CGFloat = 12
        let available = CGSize(width: max(1, container.width - inset * 2), height: max(1, container.height - inset * 2))
        var size = CGSize(width: available.width, height: available.width / aspect)
        if size.height > available.height {
            size = CGSize(width: available.height * aspect, height: available.height)
        }
        size = CGSize(width: size.width * zoom, height: size.height * zoom)
        let origin = CGPoint(x: (container.width - size.width) / 2 + offset.width, y: (container.height - size.height) / 2 + offset.height)
        return CGRect(origin: origin, size: size)
    }

    private func normalized(_ location: CGPoint, in frame: CGRect) -> PSPoint? {
        guard frame.contains(location) else { return nil }
        return PSPoint(x: Double((location.x - frame.minX) / frame.width), y: Double((location.y - frame.minY) / frame.height))
    }

    private func resetZoom() {
        withAnimation(.spring(duration: 0.35)) {
            zoom = 1; steadyZoom = 1; offset = .zero; steadyOffset = .zero
        }
    }

    private func applyZoomRequest(_ request: PhotoEditorSession.ZoomRequest, container: CGSize) {
        withAnimation(.spring(duration: 0.4)) {
            if let target = request.target, let candidate = session.candidateOverlays.first(where: { $0.label == target.label }) ?? session.candidateOverlays.first {
                let box = candidate.boundingBox
                let scale = min(6, 0.8 / max(box.width, box.height))
                zoom = scale
                steadyZoom = scale
                let base = imageFrame(in: container)
                let center = CGPoint(x: base.minX + box.midX * base.width, y: base.minY + box.midY * base.height)
                offset = CGSize(width: container.width / 2 - center.x, height: container.height / 2 - center.y)
                steadyOffset = offset
            } else if let amount = request.amount {
                switch amount.mode {
                case .absolute: zoom = 1; offset = .zero
                case .multiplier: zoom = min(8, max(1, zoom * amount.value))
                case .relative: zoom = min(8, max(1, zoom + amount.value))
                }
                steadyZoom = zoom
                if zoom == 1 { offset = .zero }
                steadyOffset = offset
            }
        }
    }

    // MARK: Gestures

    private func canvasGesture(frame: CGRect) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                zoom = min(8, max(0.5, steadyZoom * value.magnification))
            }
            .onEnded { _ in
                if zoom < 1 { resetZoom() } else { steadyZoom = zoom }
            }
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let paints = session.activeTool == .erase || (session.activeTool == .precise && (session.preciseMode == .pixelBrush || session.preciseMode == .clone))
                if paints, session.pendingClarification == nil {
                    if let point = normalized(value.location, in: frame) {
                        if currentStroke.isEmpty { session.beginPreciseStroke(at: point) }
                        let id = currentStrokeID ?? UUID()
                        currentStrokeID = id
                        currentStroke.append(point)
                        let radius = session.activeTool == .precise ? session.pixelBrushRadius / zoom : session.brushRadius
                        session.brushStrokes = session.brushStrokes.filter { $0.id != id } + [BrushStroke(id: id, points: currentStroke, radius: radius, hardness: session.activeTool == .precise ? 1 : 0.6)]
                    }
                } else if session.activeTool == .precise, session.preciseMode == .lasso, session.pendingClarification == nil {
                    if let point = normalized(value.location, in: frame) { session.lassoPoints.append(point) }
                } else if zoom > 1 {
                    offset = CGSize(width: steadyOffset.width + value.translation.width, height: steadyOffset.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if !currentStroke.isEmpty {
                    currentStroke = []
                    currentStrokeID = nil
                    Haptics.tick()
                } else if session.activeTool == .precise, session.preciseMode == .lasso, session.lassoPoints.count >= 3 {
                    session.commitLasso()
                } else {
                    steadyOffset = offset
                }
            }
        let tap = SpatialTapGesture()
            .onEnded { value in
                if let point = normalized(value.location, in: frame) {
                    Haptics.tap()
                    session.tapCanvas(at: point)
                }
            }
        let doubleTap = TapGesture(count: 2).onEnded { resetZoom() }
        return doubleTap.exclusively(before: tap).simultaneously(with: magnify).simultaneously(with: drag)
    }

    private var compareGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isPressing) { value, state, _ in
                if case .second = value { state = true }
            }
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(frame: CGRect) -> some View {
        let strokes = session.brushStrokes
        let candidates = session.candidateOverlays
        let lasso = session.lassoPoints
        let paintColor = session.activeTool == .precise && session.preciseMode == .pixelBrush ? Color(cgColor: session.paintColor.cgColor).opacity(0.9) : PSTheme.danger.opacity(0.45)
        let showsGrid = zoom >= 6 && session.activeTool == .precise
        let cloneSource = session.activeTool == .precise && session.preciseMode == .clone ? session.cloneSource : nil
        Canvas { context, _ in
            // Pixel grid (loupe) when zoomed far in.
            if showsGrid {
                let pixelsWide = max(1, session.document.canvasSize.width)
                let step = frame.width / pixelsWide
                if step >= 8 {
                    var grid = Path()
                    var x = frame.minX
                    while x <= frame.maxX { grid.move(to: CGPoint(x: x, y: frame.minY)); grid.addLine(to: CGPoint(x: x, y: frame.maxY)); x += step }
                    var y = frame.minY
                    while y <= frame.maxY { grid.move(to: CGPoint(x: frame.minX, y: y)); grid.addLine(to: CGPoint(x: frame.maxX, y: y)); y += step }
                    context.stroke(grid, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
            }
            // Lasso outline.
            if lasso.count > 1 {
                var path = Path()
                let points = lasso.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(PSTheme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            if let cloneSource {
                let center = CGPoint(x: frame.minX + cloneSource.x * frame.width, y: frame.minY + cloneSource.y * frame.height)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(PSTheme.warning), lineWidth: 2)
                context.stroke(Path { $0.move(to: CGPoint(x: center.x - 14, y: center.y)); $0.addLine(to: CGPoint(x: center.x + 14, y: center.y)); $0.move(to: CGPoint(x: center.x, y: center.y - 14)); $0.addLine(to: CGPoint(x: center.x, y: center.y + 14)) }, with: .color(PSTheme.warning), lineWidth: 1.5)
            }
            // Brush strokes.
            for stroke in strokes {
                let radius = CGFloat(stroke.radius) * max(frame.width, frame.height)
                var path = Path()
                let points = stroke.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                if points.count == 1, let first = points.first {
                    path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(path, with: .color(paintColor))
                } else if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .color(paintColor), style: StrokeStyle(lineWidth: max(1, radius * 2), lineCap: .round, lineJoin: .round))
                }
            }
            // Candidate boxes.
            for (index, candidate) in candidates.enumerated() {
                let rect = CGRect(x: frame.minX + candidate.boundingBox.minX * frame.width, y: frame.minY + candidate.boundingBox.minY * frame.height,
                                  width: candidate.boundingBox.width * frame.width, height: candidate.boundingBox.height * frame.height)
                let path = Path(roundedRect: rect, cornerRadius: 10)
                context.stroke(path, with: .color(PSTheme.accent), lineWidth: 2.5)
                context.fill(path, with: .color(PSTheme.accent.opacity(0.12)))
                let badge = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 26, height: 26)
                context.fill(Path(ellipseIn: badge), with: .color(PSTheme.accent))
                context.draw(Text("\(index + 1)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.black), at: CGPoint(x: badge.midX, y: badge.midY))
            }
        }
        .overlay(alignment: .top) {
            if session.showsOriginal {
                GlassChip(L("Original"), systemImage: "eye")
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }
}
#endif
