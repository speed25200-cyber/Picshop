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

/// The picture itself. Its own view because a new frame arrives up to sixty
/// times a second while a dial is dragged: read in the canvas's body, every
/// one of those would rebuild the crop frame, the handles and the gestures.
private struct CanvasSurface: View {
    let session: PhotoEditorSession
    let frame: CGRect

    /// The edited picture, or — during a split compare — the original on the left of the line.
    private var displayed: CIImage? {
        guard let split = session.compareSplit, session.canSplitCompare, !session.isCropping, !session.showsOriginal,
              let edited = session.preview, let original = session.originalPreview,
              original.extent.width > 0, original.extent.height > 0 else { return session.preview }
        let extent = edited.extent
        let fitted = original
            .transformed(by: CGAffineTransform(scaleX: extent.width / original.extent.width, y: extent.height / original.extent.height))
        let aligned = fitted.transformed(by: CGAffineTransform(translationX: extent.minX - fitted.extent.minX, y: extent.minY - fitted.extent.minY))
        let cut = CGRect(x: extent.minX, y: extent.minY, width: extent.width * CGFloat(split.clamped(to: 0...1)), height: extent.height)
        return aligned.cropped(to: cut).composited(over: edited)
    }

    var body: some View {
        MetalCanvasRepresentable(image: displayed, overlay: session.selectionPreview, frame: frame,
                                 maxFrameRate: session.app.performance.maxFrameRate,
                                 maxContentScale: session.app.performance.maxContentScale)
    }
}

/// Zoomable, pannable canvas. Hosts the crop frame, text handles, brush
/// strokes, selection outlines and candidate highlights.
///
/// In an edge-to-edge editor the canvas runs under the bars: the picture is
/// fitted between them (`editorChromeEdges`), with no margin at the sides, and
/// glides when a panel opens or closes. Around it, a blurred wash of the photo
/// fills the dead space, except while colour is being judged.
struct PhotoCanvasView: View {
    @Bindable var session: PhotoEditorSession
    /// What floats above the bottom chrome (the voice strip). The picture
    /// makes room for it only while a question needs the photo in view.
    var floatingBottomInset: CGFloat = 0
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
    /// A tiny, blurred copy of the photo for the ambient fill.
    @State private var ambient: UIImage?
    /// The area being worked on, while work runs (from the selection).
    @State private var workingMask: UIImage?
    @GestureState private var isPressing = false
    @Environment(\.psEffects) private var effects
    @Environment(\.psReducedMotion) private var reducedMotion
    @Environment(\.editorChromeEdges) private var chromeEdges

    /// Room above and below the picture. None at the sides, so a photo that
    /// fills the width runs edge to edge, as in Photos. While cropping, the
    /// handles' grab zone, so a grab near a corner never lands on a bar button.
    private var verticalMargin: CGFloat { session.isCropping ? CropOverlay.grabRadius : 8 }
    /// Side room while cropping, so the corner handles stay clear of the display edges.
    private var horizontalMargin: CGFloat { session.isCropping ? 20 : 0 }

    var body: some View {
        GeometryReader { proxy in
            let chrome = chromeEdges?.insets(over: proxy.frame(in: .global)) ?? EdgeInsets()
            let asks = session.pendingClarification != nil
            let target = CanvasLayout(top: chrome.top, bottom: chrome.bottom + (asks ? floatingBottomInset : 0), side: horizontalMargin, vertical: verticalMargin)
            // The whole canvas is rebuilt along the animation, so the picture,
            // its overlays and the crop frame glide together.
            Color.clear
                .modifier(CanvasLayoutAnimation(layout: target) { layout in
                    canvas(container: proxy.size, layout: layout)
                })
                .animation(session.hasRenderedPreview ? PSMotion.standard : nil, value: target)
        }
        .clipped()
        .task(id: "\(session.lookThumbnailKey)|\(session.hasRenderedPreview)") { await renderAmbient() }
        .task(id: session.isProcessing) { renderWorkingMask() }
    }

    private func canvas(container: CGSize, layout: CanvasLayout) -> some View {
        let stage = stageRect(in: container, layout: layout)
        let frame = imageFrame(in: stage)
        return ZStack {
            PSTheme.canvas
            // The Metal surface is opaque edge to edge: the wash and the
            // placeholder go above it, the wash with the picture cut out.
            CanvasSurface(session: session, frame: frame)
            ambientFill(container: container, frame: frame)
            if !session.hasRenderedPreview {
                // A slow first render must read as loading, never as a black screen.
                ZStack {
                    Rectangle().fill(PSTheme.surfaceElevated)
                    ProgressView().tint(PSTheme.textTertiary)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .transition(.opacity)
            }
            if session.isProcessing, !session.isCropping {
                WorkingShimmer(mask: workingMask, region: session.magicSelection?.boundingBox,
                               animated: effects != .minimal && !reducedMotion)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if frame.minY < layout.top - 1, !session.isCropping {
                // A zoomed picture reaches under the top bar: a light scrim keeps the glass legible.
                LinearGradient(colors: [Color.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: layout.top + 48)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            overlays(frame: frame, container: container, stage: stage, top: layout.top)
                .allowsHitTesting(false)
            if let split = session.compareSplit, session.canSplitCompare, !session.isCropping {
                SplitCompareLine(frame: frame, split: split) { session.compareSplit = $0 }
                    .transition(.opacity)
            }
            if let rect = session.cropRect {
                CropOverlay(frame: frame, rect: Binding(get: { rect }, set: { session.cropRect = $0 }), aspect: cropAspectValue,
                            pixelSize: session.document.canvasSize, denseGrid: session.straightenPreview != 0)
            }
            CanvasHint(tool: session.isProcessing ? nil : session.activeTool)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, layout.top + 12)
                .padding(.horizontal, 24)
                .allowsHitTesting(false)
            if zoom > 1.01, !session.isCropping {
                ZoomBadge(zoom: zoom) { resetZoom() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, layout.top + 12)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
            // Comparing matters most while an adjustment panel is open, so the
            // button is offered whenever there is something to compare. Only
            // the crop overlay, which owns the canvas, hides it.
            if session.history.canUndo, !session.isCropping, !session.isProcessing, session.pendingClarification == nil {
                HStack(spacing: 8) {
                    if session.canSplitCompare {
                        Button {
                            Haptics.tap()
                            session.compareSplit = session.compareSplit == nil ? 0.5 : nil
                        } label: {
                            Image(systemName: "square.split.2x1").font(.system(size: 15, weight: .medium))
                                .foregroundStyle(session.compareSplit == nil ? PSTheme.textPrimary : Color.black)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(Color.white).opacity(session.compareSplit == nil ? 0 : 1))
                                .psGlass(interactive: true, shape: AnyShape(Circle()), variant: .clear)
                        }
                        .buttonStyle(PSPressStyle(scale: 0.9))
                        .accessibilityLabel(L("Before and after, side by side"))
                    }
                    CompareButton(isShowingOriginal: session.showsOriginal) { session.showsOriginal = $0 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.bottom, layout.bottom + 12 + floatingBottomInset)
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .animation(PSMotion.standard, value: session.hasRenderedPreview)
        .animation(PSMotion.standard, value: session.history.canUndo && !session.isCropping && !session.isProcessing)
        .animation(.easeOut(duration: 0.35), value: session.isProcessing)
        .animation(PSMotion.quick, value: zoom > 1.01)
        .animation(PSMotion.standard, value: floatingBottomInset)
        .contentShape(Rectangle())
        .gesture(canvasGesture(frame: frame, container: container, stage: stage), including: session.isCropping ? .subviews : .all)
        .simultaneousGesture(compareGesture)
        .simultaneousGesture(textRotationGesture, including: session.manipulatesOverlays ? .all : .none)
        .onChange(of: isPressing) { _, pressing in
            if session.activeTool != .erase, session.activeTool != .precise, session.activeTool != .text, !session.isCropping {
                session.showsOriginal = pressing
            }
        }
        .onChange(of: session.zoomRequest) { _, request in
            guard let request else { return }
            applyZoomRequest(request, stage: stage)
            session.zoomRequest = nil
        }
        .onChange(of: session.document.canvasSize) { _, _ in resetZoom() }
        .onChange(of: session.activeTool) { _, tool in if tool == .crop { resetZoom() } }
        .accessibilityLabel(L("Photo canvas"))
        .accessibilityHint(L("Double tap to zoom in or back out. Pinch to zoom."))
    }

    private var cropAspectValue: Double? {
        switch session.cropAspect {
        case .free: return nil
        case .original: return session.document.baseLayer?.imageAsset?.pixelSize.aspectRatio
        default: return session.cropAspect.value
        }
    }

    // MARK: Ambient

    /// Colour is judged against neutral black: the wash leaves while adjusting,
    /// grading or picking a look, and while cropping.
    private var showsAmbient: Bool {
        guard effects != .minimal, session.hasRenderedPreview, !session.isCropping else { return false }
        switch session.activeTool {
        case .adjust, .color, .looks: return false
        default: return true
        }
    }

    private func ambientFill(container: CGSize, frame: CGRect) -> some View {
        ZStack {
            if let ambient {
                Image(uiImage: ambient)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: container.width, height: container.height)
                    .clipped()
                    .saturation(1.1)
                    .opacity(0.24)
                RadialGradient(colors: [.clear, Color.black.opacity(0.6)], center: .center, startRadius: 120, endRadius: 520)
            }
        }
        .frame(width: container.width, height: container.height)
        .mask {
            // Everything but the picture (even-odd: the frame is a hole).
            Path { path in
                path.addRect(CGRect(origin: .zero, size: container))
                path.addRect(frame)
            }
            .fill(style: FillStyle(eoFill: true))
        }
        .opacity(showsAmbient ? 1 : 0)
        .animation(PSMotion.standard, value: showsAmbient)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Rasterises the photo at 64 points, already blurred, whenever its pixels change.
    private func renderAmbient() async {
        guard effects != .minimal, session.hasRenderedPreview else { return }
        // Let the render for this state land first.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let preview = session.preview, preview.extent.width > 1, preview.extent.height > 1 else { return }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            let scale = 64 / max(preview.extent.width, preview.extent.height)
            let small = preview.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
            return ImageSupport.cgImage(from: blurred)
        }.value
        guard !Task.isCancelled, let image else { return }
        withAnimation(PSMotion.standard) { ambient = UIImage(cgImage: image) }
    }

    /// The selection, as a small image, to shape the working shimmer.
    private func renderWorkingMask() {
        guard session.isProcessing, let selection = session.selectionPreview,
              selection.extent.width > 1, selection.extent.height > 1 else { workingMask = nil; return }
        let scale = min(1, 256 / max(selection.extent.width, selection.extent.height))
        let small = selection.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        workingMask = ImageSupport.cgImage(from: small).map { UIImage(cgImage: $0) }
    }

    // MARK: Layout

    /// Where the picture may go: the canvas less the chrome and the margins.
    private func stageRect(in container: CGSize, layout: CanvasLayout) -> CGRect {
        let top = layout.top + layout.vertical
        let height = container.height - layout.top - layout.bottom - layout.vertical * 2
        return CGRect(x: layout.side, y: top, width: max(1, container.width - layout.side * 2), height: max(1, height))
    }

    private func imageFrame(in stage: CGRect) -> CGRect {
        let aspect = CGFloat(max(0.05, session.previewAspectRatio))
        var size = CGSize(width: stage.width, height: stage.width / aspect)
        if size.height > stage.height {
            size = CGSize(width: stage.height * aspect, height: stage.height)
        }
        size = CGSize(width: size.width * zoom, height: size.height * zoom)
        let origin = CGPoint(x: stage.midX - size.width / 2 + offset.width, y: stage.midY - size.height / 2 + offset.height)
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
    /// the way Photos does it. The image is centred on the stage at
    /// zoom 1, so the tap's vector from the centre scales by (1 − z).
    private func zoomIn(at location: CGPoint, stage: CGRect) {
        let scale: CGFloat = 2.5
        let center = CGPoint(x: stage.midX, y: stage.midY)
        let vector = CGSize(width: location.x - center.x, height: location.y - center.y)
        Haptics.soft()
        withAnimation(.spring(duration: 0.35)) {
            zoom = scale; steadyZoom = scale
            offset = CGSize(width: vector.width * (1 - scale), height: vector.height * (1 - scale))
            steadyOffset = offset
        }
    }

    private func applyZoomRequest(_ request: PhotoEditorSession.ZoomRequest, stage: CGRect) {
        withAnimation(.spring(duration: 0.4)) {
            if let target = request.target, let candidate = session.candidateOverlays.first(where: { $0.label == target.label }) ?? session.candidateOverlays.first {
                let box = candidate.boundingBox
                let scale = min(6, 0.8 / max(box.width, box.height))
                zoom = scale
                steadyZoom = scale
                let base = imageFrame(in: stage)
                let center = CGPoint(x: base.minX + box.midX * base.width, y: base.minY + box.midY * base.height)
                offset = CGSize(width: stage.midX - center.x, height: stage.midY - center.y)
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

    private func canvasGesture(frame: CGRect, container: CGSize, stage: CGRect) -> some Gesture {
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
                zoomIn(at: value.location, stage: stage)
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
    private func overlays(frame: CGRect, container: CGSize, stage: CGRect, top: CGFloat) -> some View {
        let strokes = session.brushStrokes
        let candidates = session.candidateOverlays
        let lasso = session.lassoPoints
        let paintColor = session.activeTool == .precise && session.preciseMode == .pixelBrush ? Color(cgColor: session.paintColor.cgColor).opacity(0.9) : PSTheme.danger.opacity(0.45)
        let showsGrid = zoom >= 6 && session.activeTool == .precise
        let cloneSource = session.activeTool == .precise && session.preciseMode == .clone ? session.cloneSource : nil
        let brushRadiusPoints = CGFloat(session.activeTool == .precise ? session.pixelBrushRadius : session.brushRadius) * max(frame.width, frame.height)
        let focusReticle = session.activeTool == .focus ? session.focusPoint : nil
        let selection = session.activeTool == .magic ? session.magicSelection : nil
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
            // Focus reticle, like the Camera app's.
            if let focusReticle {
                let center = viewPoint(focusReticle, in: frame)
                let side: CGFloat = 64
                let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                context.stroke(Path(rect), with: .color(PSTheme.accent), lineWidth: 1.5)
                for (from, to) in [(CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY + 6)), (CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY - 6)),
                                   (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX + 6, y: rect.midY)), (CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX - 6, y: rect.midY))] {
                    context.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(PSTheme.accent), lineWidth: 1.5)
                }
            }
            // Brush cursor: under the finger while painting, or centred while the size dial is dragged.
            if paintsWithBrush, let cursorPoint = cursor ?? (session.showsBrushPreview ? CGPoint(x: stage.midX, y: stage.midY) : nil) {
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
            // The object picked in the Magic tool, ringed in the intelligence colours.
            if let selection {
                let rect = viewRect(selection.boundingBox, in: frame).insetBy(dx: -4, dy: -4)
                let path = Path(roundedRect: rect, cornerRadius: 14)
                context.fill(path, with: .color(.white.opacity(0.06)))
                context.stroke(path, with: .linearGradient(Gradient(colors: PSTheme.intelligence), startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 2.5)
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
        .overlay {
            if let selection {
                let rect = viewRect(selection.boundingBox, in: frame)
                // Above the object when there is room, else below it.
                let y = rect.minY > stage.minY + 44 ? rect.minY - 34 : min(stage.maxY - 22, rect.maxY + 34)
                MagicSelectionBar(session: session, candidate: selection)
                    .position(x: min(max(rect.midX, 130), container.width - 130), y: y)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(PSMotion.quick, value: selection?.id)
        .overlay(alignment: .top) {
            // The zoom factor has its own badge; only the original needs saying.
            if session.showsOriginal {
                GlassChip(L("Original"), systemImage: "eye")
                    .padding(.top, top + 12)
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
    /// Canvas size in pixels, for the live size readout.
    var pixelSize: PSSize = .zero
    /// A finer grid while the picture is being levelled.
    var denseGrid = false

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    @State private var activeHandle: Handle?
    @State private var startRect: PSRect = .unit
    private let minimum = 0.06
    /// How far from an edge a touch still grabs it.
    static let grabRadius: CGFloat = 30
    private let grab = CropOverlay.grabRadius

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
                if denseGrid || activeHandle != nil {
                    // Fine grid: horizons and verticals are easy to align against it.
                    var fine = Path()
                    for i in 1..<9 where i % 3 != 0 {
                        let x = crop.minX + crop.width * CGFloat(i) / 9
                        let y = crop.minY + crop.height * CGFloat(i) / 9
                        fine.move(to: CGPoint(x: x, y: crop.minY)); fine.addLine(to: CGPoint(x: x, y: crop.maxY))
                        fine.move(to: CGPoint(x: crop.minX, y: y)); fine.addLine(to: CGPoint(x: crop.maxX, y: y))
                    }
                    context.stroke(fine, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                }
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
            // Live size readout, so a crop for a 1080p frame or a print is exact.
            if pixelSize.width > 0, crop.width > 90, crop.height > 40 {
                let width = Int((rect.width * pixelSize.width).rounded()), height = Int((rect.height * pixelSize.height).rounded())
                Text("\(width) × \(height)")
                    .font(PSFont.mono(11)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: crop.midX, y: crop.minY + 18)
                    .opacity(activeHandle == nil ? 0.8 : 1)
                    .allowsHitTesting(false)
                    .contentTransition(.numericText())
            }
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
/// The actions for an object picked on the canvas: erase it, move it,
/// or put it in the middle — floating beside it, on glass.
struct MagicSelectionBar: View {
    @Bindable var session: PhotoEditorSession
    let candidate: ObjectCandidate

    var body: some View {
        HStack(spacing: 2) {
            button(L("Erase"), symbol: "eraser") { session.erase(candidate) }
            Menu {
                Button { session.move(candidate, degrees: 180) } label: { Label(L("Move left"), systemImage: "arrow.left") }
                Button { session.move(candidate, degrees: 0) } label: { Label(L("Move right"), systemImage: "arrow.right") }
                Button { session.move(candidate, degrees: 90) } label: { Label(L("Move up"), systemImage: "arrow.up") }
                Button { session.move(candidate, degrees: -90) } label: { Label(L("Move down"), systemImage: "arrow.down") }
                Button { session.move(candidate, degrees: nil) } label: { Label(L("Centre it"), systemImage: "scope") }
                Divider()
                Button { session.blur(candidate) } label: { Label(L("Blur it"), systemImage: "drop.halffull") }
            } label: {
                label(L("Move"), symbol: "arrow.up.and.down.and.arrow.left.and.right")
            }
            button(L("Close"), symbol: "xmark") { session.magicSelection = nil }
        }
        .padding(4)
        .psGlass(interactive: true)
        .disabled(session.isProcessing)
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.magic()
            action()
        } label: {
            label(title, symbol: symbol)
        }
        .buttonStyle(PSPressStyle(scale: 0.92))
    }

    private func label(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(PSTheme.textSecondary)
            Text(title).font(.subheadline)
        }
        .foregroundStyle(PSTheme.textPrimary)
        .padding(.horizontal, 12).frame(height: 36)
        .contentShape(Capsule())
    }
}
/// The line of a before/after split: drag it anywhere across the picture.
struct SplitCompareLine: View {
    let frame: CGRect
    let split: Double
    var onChange: (Double) -> Void

    var body: some View {
        let x = frame.minX + frame.width * CGFloat(split)
        ZStack {
            Rectangle().fill(Color.white).frame(width: 2, height: frame.height)
                .shadow(color: .black.opacity(0.35), radius: 3)
                .position(x: x, y: frame.midY)
            Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 34, height: 34).background(Circle().fill(Color.white)).shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .position(x: x, y: frame.midY)
            HStack {
                Text(L("Before")).font(PSFont.label(11)).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.45)))
                Spacer()
                Text(L("After")).font(PSFont.label(11)).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.45)))
            }
            .foregroundStyle(.white)
            .frame(width: max(0, frame.width - 16))
            .position(x: frame.midX, y: frame.minY + 18)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle().size(width: 60, height: frame.height).offset(x: x - 30, y: frame.minY))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onChange(Double((value.location.x - frame.minX) / max(1, frame.width)).clamped(to: 0...1)) }
        )
        .accessibilityElement()
        .accessibilityLabel(L("Before and after"))
        .accessibilityValue("\(Int(split * 100)) %")
        .accessibilityAdjustableAction { direction in
            onChange((split + (direction == .increment ? 0.1 : -0.1)).clamped(to: 0...1))
        }
    }
}
/// The room the chrome leaves the picture: what the canvas animates when a
/// panel opens or closes.
struct CanvasLayout: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    /// Margin at each side.
    var side: CGFloat
    /// Margin above and below the picture.
    var vertical: CGFloat = 8
}

/// Rebuilds the canvas at every step of a layout change, so the Metal
/// picture (which cannot animate its own frame) moves with its overlays.
private struct CanvasLayoutAnimation<Result: View>: ViewModifier, Animatable {
    var layout: CanvasLayout
    let build: (CanvasLayout) -> Result

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(layout.top, AnimatablePair(layout.bottom, AnimatablePair(layout.side, layout.vertical))) }
        set {
            layout = CanvasLayout(top: newValue.first, bottom: newValue.second.first,
                                  side: newValue.second.second.first, vertical: newValue.second.second.second)
        }
    }

    func body(content: Content) -> some View {
        build(layout)
    }
}

/// Work in progress drawn on the picture itself instead of a blocking HUD:
/// the intelligence spectrum turning slowly over the area being changed —
/// the selection, the picked object, or a soft band sweeping the whole photo.
struct WorkingShimmer: View {
    /// The selection as an image; its alpha shapes the shimmer.
    var mask: UIImage?
    /// A normalised, top-left rectangle, when there is no mask.
    var region: PSRect?
    var animated: Bool

    var body: some View {
        if animated {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                layer(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            layer(time: 0)
        }
    }

    private func layer(time: Double) -> some View {
        GeometryReader { proxy in
            AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center,
                            angle: .degrees(time.truncatingRemainder(dividingBy: 4) * 90))
                .opacity(mask == nil && region == nil ? 0.5 : 0.85)
                .blur(radius: 6)
                .mask { shape(size: proxy.size, time: time) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shape(size: CGSize, time: Double) -> some View {
        if let mask {
            Image(uiImage: mask).resizable().blur(radius: 3)
        } else if let region {
            let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                              width: region.width * size.width, height: region.height * size.height)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .blur(radius: 8)
                .opacity(0.6)
        } else {
            let phase = (time / 1.8).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3
            LinearGradient(stops: [
                .init(color: .clear, location: max(0, min(1, phase - 0.25))),
                .init(color: .white, location: max(0, min(1, phase))),
                .init(color: .clear, location: max(0, min(1, phase + 0.25))),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .opacity(0.5)
        }
    }
}

/// A tool's how-to, said once on the picture rather than in the panel: a
/// small glass note that fades after a few seconds and never comes back.
struct CanvasHint: View {
    let tool: PhotoEditorSession.Tool?
    /// Tools whose hint has been seen, comma-separated.
    @AppStorage("hint.canvas.seen") private var seen = ""
    @State private var visible: PhotoEditorSession.Tool?

    static func text(for tool: PhotoEditorSession.Tool) -> String? {
        switch tool {
        case .erase: return L("Tap an object to erase it, paint over it, or say “efface le poteau à droite”.")
        case .looks: return L("Pick a look, then tune its intensity.")
        case .text: return L("Drag the text to move it, pinch to resize, twist to rotate.")
        case .shapes: return L("Tap the canvas to place a shape. Drag to move, pinch to resize, twist to rotate.")
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            if let visible, let text = Self.text(for: visible) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(PSTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .psGlass(shape: AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous)), variant: .clear)
                    .transition(.opacity)
            }
        }
        .animation(PSMotion.standard, value: visible)
        .task(id: tool) {
            visible = nil
            guard let tool, Self.text(for: tool) != nil, !seenTools.contains(tool.rawValue) else { return }
            // After the panel has settled.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            visible = tool
            seen = (seenTools + [tool.rawValue]).joined(separator: ",")
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            visible = nil
        }
    }

    private var seenTools: [String] { seen.split(separator: ",").map(String.init) }
}
#endif
