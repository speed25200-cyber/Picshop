#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreImage
import PicshopCore
import PicshopImaging

/// Metal-backed image view bridged into SwiftUI.
struct MetalCanvasRepresentable: UIViewRepresentable {
    var image: CIImage?
    var overlay: CIImage?
    var frame: CGRect
    var maxFrameRate: Int = 120
    var maxContentScale: CGFloat = UIScreen.main.scale

    func makeUIView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView()
        view.isUserInteractionEnabled = false
        return view
    }

    /// SwiftUI calls this for every state change in the editor; only touch the
    /// Metal view (and trigger a GPU pass) when something it draws changed.
    func updateUIView(_ view: MetalCanvasView, context: Context) {
        var dirty = false
        if view.image !== image { view.image = image; dirty = true }
        if view.overlay !== overlay { view.overlay = overlay; dirty = true }
        if view.imageFrame != frame { view.imageFrame = frame; dirty = true }
        if view.maxFrameRate != maxFrameRate { view.maxFrameRate = maxFrameRate }
        if view.maxContentScale != maxContentScale { view.maxContentScale = maxContentScale }
        if dirty { view.setNeedsDisplay() }
    }
}

/// Zoomable, pannable canvas. Hosts the crop frame, text handles, brush
/// strokes, selection outlines and candidate highlights.
struct PhotoCanvasView: View {
    @Bindable var session: PhotoEditorSession
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var currentStroke: [PSPoint] = []
    @State private var currentStrokeID: UUID?
    @State private var cursor: CGPoint?
    @State private var textDragStart: PSPoint?
    @State private var textRotationStart: Double = 0
    @State private var textSizeStart: Double = 0
    @GestureState private var isPressing = false

    private let margin: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let frame = imageFrame(in: container)
            ZStack {
                PSTheme.canvas
                MetalCanvasRepresentable(image: session.preview, overlay: session.selectionPreview, frame: frame,
                                         maxFrameRate: session.app.performance.maxFrameRate, maxContentScale: session.app.performance.maxContentScale)
                overlays(frame: frame, container: container)
                    .allowsHitTesting(false)
                if let rect = session.cropRect {
                    CropOverlay(frame: frame, rect: Binding(get: { rect }, set: { session.cropRect = $0 }), aspect: cropAspectValue)
                }
                if zoom > 1.01, !session.isCropping {
                    ZoomBadge(zoom: zoom) { resetZoom() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                }
                if session.activeTool == nil, session.history.canUndo, !session.isProcessing, session.pendingClarification == nil {
                    CompareButton(isShowingOriginal: session.showsOriginal) { session.showsOriginal = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(12)
                        .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(PSMotion.standard, value: session.activeTool == nil && session.history.canUndo && !session.isProcessing)
            .animation(PSMotion.quick, value: zoom > 1.01)
            .contentShape(Rectangle())
            .gesture(canvasGesture(frame: frame, container: container), including: session.isCropping ? .subviews : .all)
            .simultaneousGesture(compareGesture)
            .simultaneousGesture(textRotationGesture, including: session.manipulatesOverlays ? .all : .none)
            .onChange(of: isPressing) { _, pressing in
                if session.activeTool != .erase, session.activeTool != .precise, session.activeTool != .text, !session.isCropping {
                    session.showsOriginal = pressing
                }
            }
            .onChange(of: session.zoomRequest) { _, request in
                guard let request else { return }
                applyZoomRequest(request, container: container)
                session.zoomRequest = nil
            }
            .onChange(of: session.document.canvasSize) { _, _ in resetZoom() }
            .onChange(of: session.activeTool) { _, tool in if tool == .crop { resetZoom() } }
            .accessibilityLabel(L("Photo canvas"))
            .accessibilityHint(L("Double tap to zoom in or back out. Pinch to zoom."))
        }
        .clipped()
    }

    private var cropAspectValue: Double? {
        switch session.cropAspect {
        case .free: return nil
        case .original: return session.document.baseLayer?.imageAsset?.pixelSize.aspectRatio
        default: return session.cropAspect.value
        }
    }

    // MARK: Layout

    private func imageFrame(in container: CGSize) -> CGRect {
        let aspect = CGFloat(max(0.05, session.previewAspectRatio))
        let available = CGSize(width: max(1, container.width - margin * 2), height: max(1, container.height - margin * 2))
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

    private func viewPoint(_ point: PSPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func viewRect(_ rect: PSRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
    }

    private func resetZoom() {
        withAnimation(.spring(duration: 0.35)) {
            zoom = 1; steadyZoom = 1; offset = .zero; steadyOffset = .zero
        }
    }

    /// Double-tap zoom: 2.5× with the tapped point held under the finger,
    /// the way Photos does it. The image is centred in the container at
    /// zoom 1, so the tap's vector from the centre scales by (1 − z).
    private func zoomIn(at location: CGPoint, container: CGSize) {
        let scale: CGFloat = 2.5
        let center = CGPoint(x: container.width / 2, y: container.height / 2)
        let vector = CGSize(width: location.x - center.x, height: location.y - center.y)
        Haptics.soft()
        withAnimation(.spring(duration: 0.35)) {
            zoom = scale; steadyZoom = scale
            offset = CGSize(width: vector.width * (1 - scale), height: vector.height * (1 - scale))
            steadyOffset = offset
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

    private var paintsWithBrush: Bool {
        session.activeTool == .erase || (session.activeTool == .precise && (session.preciseMode == .pixelBrush || session.preciseMode == .clone))
    }

    private func canvasGesture(frame: CGRect, container: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                if session.manipulatesOverlays, let id = session.manipulatedTextLayerID ?? session.selectedOverlayLayerID {
                    if session.manipulatedTextLayerID == nil {
                        session.beginTextInteraction(id)
                        textSizeStart = session.document.layers.first(where: { $0.id == id }).flatMap { session.overlayGeometry(for: $0)?.size } ?? 0.06
                    }
                    if let layer = session.document.layers.first(where: { $0.id == id }), let geometry = session.overlayGeometry(for: layer) {
                        let target = textSizeStart * Double(value.magnification)
                        session.updateManipulatedText(scale: target / max(0.001, geometry.size))
                    }
                } else {
                    zoom = min(8, max(0.5, steadyZoom * value.magnification))
                }
            }
            .onEnded { _ in
                if session.manipulatedTextLayerID != nil {
                    session.endTextInteraction()
                } else if zoom < 1 {
                    resetZoom()
                } else {
                    steadyZoom = zoom
                }
            }
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let point = normalized(value.location, in: frame)
                cursor = value.location
                if session.manipulatesOverlays, session.pendingClarification == nil {
                    if textDragStart == nil {
                        guard let start = normalized(value.startLocation, in: frame), let layer = session.overlayLayer(at: start) else {
                            if zoom > 1 { offset = CGSize(width: steadyOffset.width + value.translation.width, height: steadyOffset.height + value.translation.height) }
                            return
                        }
                        textDragStart = session.overlayGeometry(for: layer)?.center
                        session.beginTextInteraction(layer.id)
                    }
                    guard let origin = textDragStart else { return }
                    let dx = Double(value.translation.width / frame.width), dy = Double(value.translation.height / frame.height)
                    session.updateManipulatedText(center: PSPoint(x: origin.x + dx, y: origin.y + dy))
                } else if paintsWithBrush, session.pendingClarification == nil {
                    if let point {
                        if currentStroke.isEmpty { session.beginPreciseStroke(at: point) }
                        let id = currentStrokeID ?? UUID()
                        currentStrokeID = id
                        currentStroke.append(point)
                        let radius = session.activeTool == .precise ? session.pixelBrushRadius / zoom : session.brushRadius
                        session.brushStrokes = session.brushStrokes.filter { $0.id != id } + [BrushStroke(id: id, points: currentStroke, radius: radius, hardness: session.activeTool == .precise ? 1 : 0.6)]
                    }
                } else if session.activeTool == .precise, session.preciseMode == .lasso, session.pendingClarification == nil {
                    if let point { session.lassoPoints.append(point) }
                } else if zoom > 1 {
                    offset = CGSize(width: steadyOffset.width + value.translation.width, height: steadyOffset.height + value.translation.height)
                }
            }
            .onEnded { _ in
                cursor = nil
                if textDragStart != nil {
                    textDragStart = nil
                    if session.manipulatedTextLayerID != nil { session.endTextInteraction() }
                } else if !currentStroke.isEmpty {
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
                    if session.manipulatesOverlays, let layer = session.overlayLayer(at: point) {
                        session.selectLayer(layer.id)
                    } else if session.activeTool == .shapes {
                        session.addShape(session.shapeKindToAdd, at: point)
                    } else {
                        session.tapCanvas(at: point)
                    }
                }
            }
        let doubleTap = SpatialTapGesture(count: 2).onEnded { value in
            if zoom > 1.01 || session.isCropping {
                resetZoom()
            } else {
                zoomIn(at: value.location, container: container)
            }
        }
        return doubleTap.exclusively(before: tap).simultaneously(with: magnify).simultaneously(with: drag)
    }

    private var textRotationGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                guard session.manipulatesOverlays, let id = session.manipulatedTextLayerID ?? session.selectedOverlayLayerID else { return }
                if session.manipulatedTextLayerID == nil {
                    session.beginTextInteraction(id)
                    textRotationStart = session.document.layers.first(where: { $0.id == id }).flatMap { session.overlayGeometry(for: $0)?.rotation } ?? 0
                }
                session.updateManipulatedText(rotation: textRotationStart + value.rotation.degrees)
            }
            .onEnded { _ in
                if session.manipulatedTextLayerID != nil { session.endTextInteraction() }
            }
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
    private func overlays(frame: CGRect, container: CGSize) -> some View {
        let strokes = session.brushStrokes
        let candidates = session.candidateOverlays
        let lasso = session.lassoPoints
        let paintColor = session.activeTool == .precise && session.preciseMode == .pixelBrush ? Color(cgColor: session.paintColor.cgColor).opacity(0.9) : PSTheme.danger.opacity(0.45)
        let showsGrid = zoom >= 6 && session.activeTool == .precise
        let cloneSource = session.activeTool == .precise && session.preciseMode == .clone ? session.cloneSource : nil
        let brushRadiusPoints = CGFloat(session.activeTool == .precise ? session.pixelBrushRadius : session.brushRadius) * max(frame.width, frame.height)
        let overlayLayers = session.activeTool == .text ? session.document.textLayers : (session.activeTool == .shapes ? session.document.shapeLayers : [])
        let textBoxes: [(UUID, PSRect, Double, Bool)] = overlayLayers.compactMap { layer -> (UUID, PSRect, Double, Bool)? in
            guard let bounds = session.overlayBounds(for: layer), let geometry = session.overlayGeometry(for: layer) else { return nil }
            return (layer.id, bounds, geometry.rotation, session.document.selectedLayerID == layer.id)
        }
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
                let points = lasso.map { viewPoint($0, in: frame) }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(PSTheme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            if let cloneSource {
                let center = viewPoint(cloneSource, in: frame)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(PSTheme.warning), lineWidth: 2)
                context.stroke(Path { $0.move(to: CGPoint(x: center.x - 14, y: center.y)); $0.addLine(to: CGPoint(x: center.x + 14, y: center.y)); $0.move(to: CGPoint(x: center.x, y: center.y - 14)); $0.addLine(to: CGPoint(x: center.x, y: center.y + 14)) }, with: .color(PSTheme.warning), lineWidth: 1.5)
            }
            // Brush strokes.
            for stroke in strokes {
                let radius = CGFloat(stroke.radius) * max(frame.width, frame.height)
                var path = Path()
                let points = stroke.points.map { viewPoint($0, in: frame) }
                if points.count == 1, let first = points.first {
                    path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
                    context.fill(path, with: .color(paintColor))
                } else if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .color(paintColor), style: StrokeStyle(lineWidth: max(1, radius * 2), lineCap: .round, lineJoin: .round))
                }
            }
            // Brush cursor: under the finger while painting, or centred while the size dial is dragged.
            if paintsWithBrush, let cursorPoint = cursor ?? (session.showsBrushPreview ? CGPoint(x: container.width / 2, y: container.height / 2) : nil) {
                let r = max(3, brushRadiusPoints)
                let circle = Path(ellipseIn: CGRect(x: cursorPoint.x - r, y: cursorPoint.y - r, width: r * 2, height: r * 2))
                context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                context.stroke(circle, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            }
            // Text layer handles.
            for (_, bounds, rotation, selected) in textBoxes {
                let rect = viewRect(bounds, in: frame)
                var path = Path(roundedRect: rect, cornerRadius: 6)
                if rotation != 0 {
                    let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: CGFloat(rotation * .pi / 180)).translatedBy(x: -rect.midX, y: -rect.midY)
                    path = path.applying(transform)
                }
                context.stroke(path, with: .color(selected ? PSTheme.accent : Color.white.opacity(0.5)), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 4]))
                if selected {
                    for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                        var dot = Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10))
                        if rotation != 0 {
                            dot = dot.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: CGFloat(rotation * .pi / 180)).translatedBy(x: -rect.midX, y: -rect.midY))
                        }
                        context.fill(dot, with: .color(.white))
                        context.stroke(dot, with: .color(PSTheme.accent), lineWidth: 2)
                    }
                }
            }
            // Candidate boxes.
            for (index, candidate) in candidates.enumerated() {
                let rect = viewRect(candidate.boundingBox, in: frame)
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
                    .padding(.top, 10)
                    .transition(.opacity)
            } else if zoom > 1.05 {
                GlassChip(String(format: "%.1f×", Double(zoom)), systemImage: "plus.magnifyingglass")
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: session.showsOriginal)
    }
}

/// Crop frame with draggable corners and edges, thirds grid and dimmed
/// surroundings. Coordinates are normalised to the image frame.
struct CropOverlay: View {
    let frame: CGRect
    @Binding var rect: PSRect
    var aspect: Double?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    @State private var activeHandle: Handle?
    @State private var startRect: PSRect = .unit
    private let minimum = 0.06
    private let grab: CGFloat = 30

    var body: some View {
        let crop = viewRect(rect)
        ZStack {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000))
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // Grid + border.
            Canvas { context, _ in
                var grid = Path()
                for i in 1..<3 {
                    let x = crop.minX + crop.width * CGFloat(i) / 3
                    let y = crop.minY + crop.height * CGFloat(i) / 3
                    grid.move(to: CGPoint(x: x, y: crop.minY)); grid.addLine(to: CGPoint(x: x, y: crop.maxY))
                    grid.move(to: CGPoint(x: crop.minX, y: y)); grid.addLine(to: CGPoint(x: crop.maxX, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(activeHandle == nil ? 0.35 : 0.7)), lineWidth: 0.5)
                context.stroke(Path(crop), with: .color(.white), lineWidth: 1.5)
                // Corner brackets.
                let arm: CGFloat = 22
                var corners = Path()
                corners.move(to: CGPoint(x: crop.minX, y: crop.minY + arm)); corners.addLine(to: CGPoint(x: crop.minX, y: crop.minY)); corners.addLine(to: CGPoint(x: crop.minX + arm, y: crop.minY))
                corners.move(to: CGPoint(x: crop.maxX - arm, y: crop.minY)); corners.addLine(to: CGPoint(x: crop.maxX, y: crop.minY)); corners.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + arm))
                corners.move(to: CGPoint(x: crop.maxX, y: crop.maxY - arm)); corners.addLine(to: CGPoint(x: crop.maxX, y: crop.maxY)); corners.addLine(to: CGPoint(x: crop.maxX - arm, y: crop.maxY))
                corners.move(to: CGPoint(x: crop.minX + arm, y: crop.maxY)); corners.addLine(to: CGPoint(x: crop.minX, y: crop.maxY)); corners.addLine(to: CGPoint(x: crop.minX, y: crop.maxY - arm))
                context.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                // Edge pips.
                let pip: CGFloat = 26
                var pips = Path()
                pips.move(to: CGPoint(x: crop.midX - pip / 2, y: crop.minY)); pips.addLine(to: CGPoint(x: crop.midX + pip / 2, y: crop.minY))
                pips.move(to: CGPoint(x: crop.midX - pip / 2, y: crop.maxY)); pips.addLine(to: CGPoint(x: crop.midX + pip / 2, y: crop.maxY))
                pips.move(to: CGPoint(x: crop.minX, y: crop.midY - pip / 2)); pips.addLine(to: CGPoint(x: crop.minX, y: crop.midY + pip / 2))
                pips.move(to: CGPoint(x: crop.maxX, y: crop.midY - pip / 2)); pips.addLine(to: CGPoint(x: crop.maxX, y: crop.midY + pip / 2))
                context.stroke(pips, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .allowsHitTesting(false)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if activeHandle == nil {
                                activeHandle = handle(at: value.startLocation, crop: crop)
                                startRect = rect
                                Haptics.tick()
                            }
                            guard let activeHandle else { return }
                            let dx = Double(value.translation.width / frame.width)
                            let dy = Double(value.translation.height / frame.height)
                            rect = resized(startRect, handle: activeHandle, dx: dx, dy: dy)
                        }
                        .onEnded { _ in
                            activeHandle = nil
                            Haptics.confirm()
                        }
                )
        }
        .animation(.interactiveSpring(), value: rect)
    }

    private func viewRect(_ r: PSRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
    }

    private func handle(at point: CGPoint, crop: CGRect) -> Handle {
        let nearLeft = abs(point.x - crop.minX) < grab, nearRight = abs(point.x - crop.maxX) < grab
        let nearTop = abs(point.y - crop.minY) < grab, nearBottom = abs(point.y - crop.maxY) < grab
        let insideX = point.x > crop.minX - grab && point.x < crop.maxX + grab
        let insideY = point.y > crop.minY - grab && point.y < crop.maxY + grab
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _) where insideY: return .left
        case (_, true, _, _) where insideY: return .right
        case (_, _, true, _) where insideX: return .top
        case (_, _, _, true) where insideX: return .bottom
        default: return .move
        }
    }

    /// Applies a drag to one handle, keeping the opposite side anchored and
    /// honouring the locked aspect ratio (in image-pixel terms).
    private func resized(_ start: PSRect, handle: Handle, dx: Double, dy: Double) -> PSRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if handle == .move {
            let w = start.width, h = start.height
            minX = (start.minX + dx).clamped(to: 0...(1 - w)); minY = (start.minY + dy).clamped(to: 0...(1 - h))
            return PSRect(x: minX, y: minY, width: w, height: h)
        }
        switch handle {
        case .topLeft: minX += dx; minY += dy
        case .top: minY += dy
        case .topRight: maxX += dx; minY += dy
        case .right: maxX += dx
        case .bottomRight: maxX += dx; maxY += dy
        case .bottom: maxY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .left: minX += dx
        case .move: break
        }
        minX = minX.clamped(to: 0...(maxX - minimum)); maxX = maxX.clamped(to: (minX + minimum)...1)
        minY = minY.clamped(to: 0...(maxY - minimum)); maxY = maxY.clamped(to: (minY + minimum)...1)
        guard let aspect, frame.width > 0, frame.height > 0 else { return PSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        // Normalised aspect: (w * frameW) / (h * frameH) == aspect.
        let frameAspect = Double(frame.width / frame.height)
        let ratio = aspect / frameAspect // height units per width unit
        var width = maxX - minX, height = maxY - minY
        let drivesWidth: Bool
        switch handle {
        case .left, .right: drivesWidth = true
        case .top, .bottom: drivesWidth = false
        default: drivesWidth = abs(dx) >= abs(dy)
        }
        if drivesWidth { height = width / ratio } else { width = height * ratio }
        // Anchor the side opposite to the handle.
        let anchorsLeft = [Handle.topRight, .right, .bottomRight, .top, .bottom].contains(handle)
        let anchorsTop = [Handle.bottomLeft, .bottom, .bottomRight, .left, .right].contains(handle)
        var result = PSRect(x: anchorsLeft ? start.minX : start.maxX - width, y: anchorsTop ? start.minY : start.maxY - height, width: width, height: height)
        if handle == .top || handle == .bottom { result.origin.x = start.midX - width / 2 }
        if handle == .left || handle == .right { result.origin.y = start.midY - height / 2 }
        // Keep inside the image, shrinking if needed.
        if result.width > 1 || result.height > 1 {
            let scale = min(1 / result.width, 1 / result.height)
            result.size = PSSize(width: result.width * scale, height: result.height * scale)
        }
        result.origin.x = result.origin.x.clamped(to: 0...(1 - result.width))
        result.origin.y = result.origin.y.clamped(to: 0...(1 - result.height))
        return result
    }
}
#endif
