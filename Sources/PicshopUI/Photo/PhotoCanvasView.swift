#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreImage
import Observation
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

// MARK: - Viewport and stroke (leaf state)

/// Zoom and pan of the canvas. Only the stage (the frame driver's content)
/// and its overlay leaves read it, so a pinch never re-evaluates the canvas's
/// own body, the editor or the dock. Gestures write it and read it at event time.
@MainActor
@Observable
final class CanvasViewport {
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    /// The values a gesture started from.
    @ObservationIgnored var steadyZoom: CGFloat = 1
    @ObservationIgnored var steadyOffset: CGSize = .zero

    /// The picture's frame on `stage`: fitted, then zoomed about the stage's centre and panned.
    func imageFrame(in stage: CGRect, aspect: Double) -> CGRect {
        let fitted = CanvasGeometry.fitted(in: stage, aspect: aspect)
        let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        return CGRect(origin: CGPoint(x: stage.midX - size.width / 2 + offset.width, y: stage.midY - size.height / 2 + offset.height), size: size)
    }

    func reset() {
        zoom = 1
        steadyZoom = 1
        offset = .zero
        steadyOffset = .zero
    }
}

/// The brush or lasso stroke under the finger. The path grows point by point
/// in view coordinates (points closer than 1.5 pt are skipped); only the leaf
/// that draws it reads it. The session gets the whole stroke once, at the end.
@MainActor
@Observable
final class StrokeInProgress {
    private(set) var path = Path()
    /// Under the finger while painting.
    var cursor: CGPoint?
    @ObservationIgnored private(set) var points: [PSPoint] = []
    @ObservationIgnored private(set) var id = UUID()
    @ObservationIgnored private(set) var isLasso = false
    /// Radius in view points, fixed for the stroke.
    @ObservationIgnored private(set) var radius: CGFloat = 0
    @ObservationIgnored private var lastViewPoint: CGPoint?

    var isEmpty: Bool { points.isEmpty }

    func begin(lasso: Bool, radius: CGFloat) {
        id = UUID()
        isLasso = lasso
        self.radius = radius
        points = []
        lastViewPoint = nil
        path = Path()
    }

    /// Adds a point unless it is within 1.5 pt of the previous one.
    func append(_ point: PSPoint, at location: CGPoint) {
        if let last = lastViewPoint {
            let dx = location.x - last.x, dy = location.y - last.y
            guard dx * dx + dy * dy >= 1.5 * 1.5 else { return }
            path.addLine(to: location)
        } else {
            path.move(to: location)
        }
        lastViewPoint = location
        points.append(point)
    }

    func reset() {
        points = []
        lastViewPoint = nil
        if !path.isEmpty { path = Path() }
        if cursor != nil { cursor = nil }
    }
}

/// Layout arithmetic shared by the canvas's body, its stage and its gestures.
enum CanvasGeometry {
    /// Where the picture may go: the canvas less the chrome and the margins.
    static func stage(in container: CGSize, layout: CanvasLayout) -> CGRect {
        let top = layout.top + layout.vertical
        let height = container.height - layout.top - layout.bottom - layout.vertical * 2
        return CGRect(x: layout.side, y: top, width: max(1, container.width - layout.side * 2), height: max(1, height))
    }

    /// The picture at zoom 1, fitted and centred on `stage`.
    static func fitted(in stage: CGRect, aspect: Double) -> CGRect {
        let ratio = CGFloat(max(0.05, aspect))
        var size = CGSize(width: stage.width, height: stage.width / ratio)
        if size.height > stage.height {
            size = CGSize(width: stage.height * ratio, height: stage.height)
        }
        return CGRect(x: stage.midX - size.width / 2, y: stage.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The four bands of `bounds` around `hole` (the picture), for the ambient wash.
    static func bands(around hole: CGRect, in bounds: CGRect) -> [CGRect] {
        let cut = hole.intersection(bounds)
        guard !cut.isNull, cut.width > 0.5, cut.height > 0.5 else { return [bounds] }
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: cut.minY - bounds.minY),
            CGRect(x: bounds.minX, y: cut.maxY, width: bounds.width, height: bounds.maxY - cut.maxY),
            CGRect(x: bounds.minX, y: cut.minY, width: cut.minX - bounds.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: bounds.maxX - cut.maxX, height: cut.height),
        ].filter { $0.width > 0.5 && $0.height > 0.5 }
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
        guard let split = session.compareSplit, PhotoCanvasView.canSplitCompare(session), !session.isCropping, !session.showsOriginal,
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

// MARK: - Canvas

/// Zoomable, pannable canvas. Hosts the crop frame, text handles, brush
/// strokes, selection outlines and candidate highlights.
///
/// The canvas runs under the studio's bars, full screen: the picture is fitted
/// between them (`studioEdges`), with no margin at the sides, and glides when
/// a panel opens or closes. Its body reads only coarse state; zoom and pan live
/// in `CanvasViewport`, the stroke under the finger in `StrokeInProgress`, and
/// everything that follows the frame is drawn by `CanvasStage`, the one view
/// the layout animation rebuilds. Around the picture, a blurred wash of the
/// photo fills the dead space, except while colour is being judged.
///
/// Press and hold the picture (0.25 s) to see the original.
struct PhotoCanvasView: View {
    @Bindable var session: PhotoEditorSession
    @State private var viewport = CanvasViewport()
    @State private var stroke = StrokeInProgress()
    @State private var textDragStart: PSPoint?
    @State private var textRotationStart: Double = 0
    @State private var textSizeStart: Double = 0
    /// A tiny, blurred, darkened copy of the photo for the ambient fill.
    @State private var ambient: UIImage?
    /// The area being worked on, while work runs (from the selection), blurred once.
    @State private var workingMask: UIImage?
    /// The hold on the picture set `showsOriginal`, so its release clears it.
    @State private var holdShowsOriginal = false
    @GestureState private var isPressing = false
    @Environment(\.psEffects) private var effects
    @Environment(\.studioEdges) private var studioEdges

    /// Room above and below the picture. None at the sides, so a photo that
    /// fills the width runs edge to edge, as in Photos. While cropping, the
    /// handles' grab zone, so a grab near a corner never lands on a bar button.
    private var verticalMargin: CGFloat { session.isCropping ? CropOverlay.grabRadius : 8 }
    /// Side room while cropping, so the corner handles stay clear of the display edges.
    private var horizontalMargin: CGFloat { session.isCropping ? 20 : 0 }

    /// The split compare lines pixels up, so it is offered only while the frame is the original one.
    /// Read from the mirrors, never from the history.
    static func canSplitCompare(_ session: PhotoEditorSession) -> Bool {
        session.canUndo && !session.modifiedTools.contains(.crop)
    }

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        GeometryReader { proxy in
            let chrome = studioEdges.insets(over: proxy.frame(in: .global))
            let target = CanvasLayout(top: chrome.top, bottom: chrome.bottom, side: horizontalMargin, vertical: verticalMargin)
            let container = proxy.size
            // Only the stage is rebuilt along the animation, so the picture,
            // its overlays and the crop frame glide together.
            Color.clear
                .modifier(CanvasLayoutAnimation(layout: target) { layout in
                    CanvasStage(session: session, viewport: viewport, stroke: stroke, layout: layout, container: container,
                                ambient: ambient, workingMask: workingMask, onResetZoom: resetZoom)
                })
                .animation(session.hasRenderedPreview ? PSMotion.standard : nil, value: target)
                .contentShape(Rectangle())
                .gesture(canvasGesture(container: container, layout: target), including: session.isCropping ? .subviews : .all)
                .simultaneousGesture(compareGesture)
                .simultaneousGesture(textRotationGesture, including: session.manipulatesOverlays ? .all : .none)
                .onChange(of: session.zoomRequest) { _, request in
                    guard let request else { return }
                    applyZoomRequest(request, container: container, layout: target)
                    session.zoomRequest = nil
                }
        }
        .clipped()
        .onChange(of: isPressing) { _, pressing in
            if pressing {
                guard comparesOnHold else { return }
                Haptics.soft(0.6)
                holdShowsOriginal = true
                session.showsOriginal = true
            } else if holdShowsOriginal {
                holdShowsOriginal = false
                session.showsOriginal = false
            }
        }
        .onChange(of: session.previewAspectRatio) { _, _ in resetZoom() }
        .onChange(of: session.activeTool) { _, tool in if tool == .crop { resetZoom() } }
        .task(id: "\(session.lookThumbnailKey)|\(session.hasRenderedPreview)") { await renderAmbient() }
        .task(id: session.isProcessing) { await renderWorkingMask() }
    }

    /// Before/after works everywhere but while framing, painting or moving text and shapes.
    private var comparesOnHold: Bool {
        guard !session.isCropping else { return false }
        switch session.activeTool {
        case .erase, .precise, .text, .shapes: return false
        default: return true
        }
    }

    // MARK: Ambient

    /// Rasterises the photo at 64 points whenever its pixels change: blurred,
    /// a touch more saturated, darkened towards the edges and dimmed to 24 %
    /// over black, all in Core Image, so the view draws a plain image.
    private func renderAmbient() async {
        guard effects != .minimal, session.hasRenderedPreview else { return }
        // Let the render for this state land first.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let preview = session.preview, preview.extent.width > 1, preview.extent.height > 1 else { return }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            let scale = 64 / max(preview.extent.width, preview.extent.height)
            let small = preview.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let extent = small.extent
            var wash = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: extent)
            wash = wash.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
            let radius = max(extent.width, extent.height)
            if let vignette = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius0": radius * 0.23,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0.4, green: 0.4, blue: 0.4),
            ])?.outputImage?.cropped(to: extent) {
                wash = wash.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: vignette])
            }
            // 24 % over black is the colour times 0.24: no blending at draw time.
            wash = wash.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.24, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.24, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.24, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            return ImageSupport.cgImage(from: wash.cropped(to: extent))
        }.value
        guard !Task.isCancelled, let image else { return }
        withAnimation(PSMotion.standard) { ambient = UIImage(cgImage: image) }
    }

    /// The selection as a small, pre-blurred image, to shape the working shimmer. Off the main thread.
    private func renderWorkingMask() async {
        guard session.isProcessing, let selection = session.selectionPreview,
              selection.extent.width > 1, selection.extent.height > 1 else {
            if workingMask != nil { workingMask = nil }
            return
        }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let scale = min(1, 256 / max(selection.extent.width, selection.extent.height))
            let small = selection.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: small.extent)
            return ImageSupport.cgImage(from: blurred)
        }.value
        guard !Task.isCancelled else { return }
        workingMask = image.map { UIImage(cgImage: $0) }
    }

    // MARK: Zoom

    /// The picture's frame now, for a gesture: read at event time, never in the body.
    private func currentFrame(container: CGSize, layout: CanvasLayout) -> CGRect {
        viewport.imageFrame(in: CanvasGeometry.stage(in: container, layout: layout), aspect: session.previewAspectRatio)
    }

    private func normalized(_ location: CGPoint, in frame: CGRect) -> PSPoint? {
        guard frame.contains(location) else { return nil }
        return PSPoint(x: Double((location.x - frame.minX) / frame.width), y: Double((location.y - frame.minY) / frame.height))
    }

    private func resetZoom() {
        withAnimation(.spring(duration: 0.35)) { viewport.reset() }
    }

    /// Double-tap zoom: 2.5× with the tapped point held under the finger,
    /// the way Photos does it. The image is centred on the stage at
    /// zoom 1, so the tap's vector from the centre scales by (1 − z).
    private func zoomIn(at location: CGPoint, stage: CGRect) {
        let scale: CGFloat = 2.5
        let vector = CGSize(width: location.x - stage.midX, height: location.y - stage.midY)
        Haptics.soft()
        withAnimation(.spring(duration: 0.35)) {
            viewport.zoom = scale
            viewport.steadyZoom = scale
            viewport.offset = CGSize(width: vector.width * (1 - scale), height: vector.height * (1 - scale))
            viewport.steadyOffset = viewport.offset
        }
    }

    private func applyZoomRequest(_ request: PhotoEditorSession.ZoomRequest, container: CGSize, layout: CanvasLayout) {
        let stage = CanvasGeometry.stage(in: container, layout: layout)
        withAnimation(.spring(duration: 0.4)) {
            if let target = request.target, let candidate = session.candidateOverlays.first(where: { $0.label == target.label }) ?? session.candidateOverlays.first {
                let box = candidate.boundingBox
                let scale = min(6, 0.8 / max(box.width, box.height))
                viewport.zoom = scale
                viewport.steadyZoom = scale
                let base = CanvasGeometry.fitted(in: stage, aspect: session.previewAspectRatio)
                let center = CGPoint(x: base.minX + box.midX * base.width, y: base.minY + box.midY * base.height)
                viewport.offset = CGSize(width: (stage.midX - center.x) * scale, height: (stage.midY - center.y) * scale)
                viewport.steadyOffset = viewport.offset
            } else if let amount = request.amount {
                switch amount.mode {
                case .absolute: viewport.zoom = 1; viewport.offset = .zero
                case .multiplier: viewport.zoom = min(8, max(1, viewport.zoom * amount.value))
                case .relative: viewport.zoom = min(8, max(1, viewport.zoom + amount.value))
                }
                viewport.steadyZoom = viewport.zoom
                if viewport.zoom == 1 { viewport.offset = .zero }
                viewport.steadyOffset = viewport.offset
            }
        }
    }

    // MARK: Gestures

    private var paintsWithBrush: Bool {
        session.activeTool == .erase || (session.activeTool == .precise && (session.preciseMode == .pixelBrush || session.preciseMode == .clone))
    }

    private var drawsLasso: Bool {
        session.activeTool == .precise && session.preciseMode == .lasso
    }

    private func canvasGesture(container: CGSize, layout: CanvasLayout) -> some Gesture {
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
                    viewport.zoom = min(8, max(0.5, viewport.steadyZoom * value.magnification))
                }
            }
            .onEnded { _ in
                if session.manipulatedTextLayerID != nil {
                    session.endTextInteraction()
                } else if viewport.zoom < 1 {
                    resetZoom()
                } else {
                    viewport.steadyZoom = viewport.zoom
                }
            }
        let drag = DragGesture(minimumDistance: 2)
            .onChanged { value in
                let frame = currentFrame(container: container, layout: layout)
                let point = normalized(value.location, in: frame)
                if session.manipulatesOverlays, session.pendingClarification == nil {
                    if textDragStart == nil {
                        guard let start = normalized(value.startLocation, in: frame), let layer = session.overlayLayer(at: start) else {
                            if viewport.zoom > 1 { pan(by: value.translation) }
                            return
                        }
                        textDragStart = session.overlayGeometry(for: layer)?.center
                        session.beginTextInteraction(layer.id)
                    }
                    guard let origin = textDragStart else { return }
                    let dx = Double(value.translation.width / frame.width), dy = Double(value.translation.height / frame.height)
                    session.updateManipulatedText(center: PSPoint(x: origin.x + dx, y: origin.y + dy))
                } else if paintsWithBrush, session.pendingClarification == nil {
                    stroke.cursor = value.location
                    guard let point else { return }
                    if stroke.isEmpty {
                        session.beginPreciseStroke(at: point)
                        stroke.begin(lasso: false, radius: CGFloat(brushRadius) * max(frame.width, frame.height))
                    }
                    stroke.append(point, at: value.location)
                } else if drawsLasso, session.pendingClarification == nil {
                    guard let point else { return }
                    if stroke.isEmpty { stroke.begin(lasso: true, radius: 0) }
                    stroke.append(point, at: value.location)
                } else if viewport.zoom > 1 {
                    pan(by: value.translation)
                }
            }
            .onEnded { _ in
                if textDragStart != nil {
                    textDragStart = nil
                    if session.manipulatedTextLayerID != nil { session.endTextInteraction() }
                } else if !stroke.isEmpty {
                    finishStroke()
                } else {
                    stroke.cursor = nil
                    viewport.steadyOffset = viewport.offset
                }
            }
        let tap = SpatialTapGesture()
            .onEnded { value in
                let frame = currentFrame(container: container, layout: layout)
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
            if viewport.zoom > 1.01 || session.isCropping {
                resetZoom()
            } else {
                zoomIn(at: value.location, stage: CanvasGeometry.stage(in: container, layout: layout))
            }
        }
        return doubleTap.exclusively(before: tap).simultaneously(with: magnify).simultaneously(with: drag)
    }

    /// The brush radius as a fraction of the picture's longest side (the pixel brush follows the zoom).
    private var brushRadius: Double {
        session.activeTool == .precise ? session.pixelBrushRadius / Double(viewport.zoom) : session.brushRadius
    }

    private func pan(by translation: CGSize) {
        viewport.offset = CGSize(width: viewport.steadyOffset.width + translation.width, height: viewport.steadyOffset.height + translation.height)
    }

    /// Hands the finished stroke to the session: a brush stroke, or the lasso's points.
    private func finishStroke() {
        let points = stroke.points
        if stroke.isLasso {
            session.lassoPoints.append(contentsOf: points)
            stroke.reset()
            if session.lassoPoints.count >= 3 { session.commitLasso() }
        } else {
            let hardness = session.activeTool == .precise ? 1.0 : 0.6
            session.brushStrokes.append(BrushStroke(id: stroke.id, points: points, radius: brushRadius, hardness: hardness))
            stroke.reset()
            Haptics.tick()
        }
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

    /// Press and hold the picture for a quarter second: the original.
    private var compareGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isPressing) { value, state, _ in
                if case .second = value { state = true }
            }
    }
}

// MARK: - Stage

/// Everything that follows the picture's frame: the Metal surface, the
/// ambient bands, the working shimmer, the overlays, the crop frame, the
/// badges. Rebuilt along a layout animation and on every zoom or pan step;
/// the canvas's own body is not.
private struct CanvasStage: View {
    let session: PhotoEditorSession
    let viewport: CanvasViewport
    let stroke: StrokeInProgress
    let layout: CanvasLayout
    let container: CGSize
    let ambient: UIImage?
    let workingMask: UIImage?
    let onResetZoom: () -> Void

    @Environment(\.psEffects) private var effects
    @Environment(\.psReducedMotion) private var reducedMotion

    var body: some View {
        #if DEBUG
        let _ = ViewTrace.changes(Self.self)
        #endif
        let stage = CanvasGeometry.stage(in: container, layout: layout)
        let frame = viewport.imageFrame(in: stage, aspect: session.previewAspectRatio)
        let zoomed = viewport.zoom > 1.01
        ZStack {
            PSTheme.canvas
            // The Metal surface is opaque edge to edge: the wash and the
            // placeholder go above it, the wash in four bands around the picture.
            CanvasSurface(session: session, frame: frame)
            AmbientBands(image: ambient, frame: frame, container: container, isVisible: showsAmbient)
            PictureAccessibility(session: session, frame: frame)
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
            CommittedStrokes(session: session, frame: frame)
            CanvasOverlays(session: session, frame: frame, stage: stage, container: container, zoom: viewport.zoom)
            LiveStroke(session: session, stroke: stroke, frame: frame, stage: stage)
            if let split = session.compareSplit, PhotoCanvasView.canSplitCompare(session), !session.isCropping {
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
            if zoomed, !session.isCropping {
                ZoomBadge(zoom: viewport.zoom, onReset: onResetZoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, layout.top + 12)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
            if session.showsOriginal {
                GlassChip(L("Original"), systemImage: "eye.fill", variant: .clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, layout.top + 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(PSMotion.standard, value: session.hasRenderedPreview)
        .animation(.easeOut(duration: 0.35), value: session.isProcessing)
        .animation(PSMotion.quick, value: zoomed)
        .animation(.easeOut(duration: 0.2), value: session.showsOriginal)
    }

    private var cropAspectValue: Double? {
        switch session.cropAspect {
        case .free: return nil
        case .original: return session.document.baseLayer?.imageAsset?.pixelSize.aspectRatio
        default: return session.cropAspect.value
        }
    }

    /// Colour is judged against neutral black: the wash leaves while adjusting,
    /// grading or picking a look, and while cropping.
    private var showsAmbient: Bool {
        guard effects != .minimal, session.hasRenderedPreview, !session.isCropping else { return false }
        switch session.activeTool {
        case .adjust, .color, .looks: return false
        default: return true
        }
    }
}

/// The picture for VoiceOver: what it is, and its two actions (the original, Undo).
private struct PictureAccessibility: View {
    let session: PhotoEditorSession
    let frame: CGRect

    var body: some View {
        Color.clear
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(L("Photo canvas"))
            .accessibilityAddTraits(.isImage)
            .accessibilityHint(L("Double tap to zoom in or back out. Pinch to zoom."))
            .accessibilityAction(named: Text(session.showsOriginal ? L("Show the edits") : L("Show original"))) {
                session.showsOriginal.toggle()
                UIAccessibility.post(notification: .announcement, argument: session.showsOriginal ? L("Original shown") : L("Edits shown"))
            }
            .accessibilityAction(named: Text(L("Undo"))) {
                session.undo()
            }
    }
}

/// The dead space around the picture: the ambient image in up to four
/// rectangular bands, each a clipped layer (no mask, no offscreen pass).
private struct AmbientBands: View {
    let image: UIImage?
    let frame: CGRect
    let container: CGSize
    let isVisible: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                let bounds = CGRect(origin: .zero, size: container)
                ForEach(Array(CanvasGeometry.bands(around: frame, in: bounds).enumerated()), id: \.offset) { _, band in
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: container.width, height: container.height)
                        .offset(x: -band.minX, y: -band.minY)
                        .frame(width: band.width, height: band.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: band.minX, y: band.minY)
                }
            }
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .opacity(isVisible ? 1 : 0)
        .animation(PSMotion.standard, value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Strokes already handed to the session, in their own Canvas: it redraws
/// only when the strokes (or the frame) change.
private struct CommittedStrokes: View {
    let session: PhotoEditorSession
    let frame: CGRect

    var body: some View {
        let strokes = session.brushStrokes
        let color = CanvasOverlays.paintColor(session)
        Canvas { context, _ in
            for stroke in strokes {
                let radius = CGFloat(stroke.radius) * max(frame.width, frame.height)
                let points = stroke.points.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
                if points.count == 1, let first = points.first {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                } else if let first = points.first {
                    var path = Path()
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, radius * 2), lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The stroke under the finger and the brush cursor: the only view that
/// reads `StrokeInProgress`, so painting redraws this layer and nothing else.
private struct LiveStroke: View {
    let session: PhotoEditorSession
    let stroke: StrokeInProgress
    let frame: CGRect
    let stage: CGRect

    var body: some View {
        let path = stroke.path
        let cursor = stroke.cursor
        let brushes = session.activeTool == .erase || (session.activeTool == .precise && (session.preciseMode == .pixelBrush || session.preciseMode == .clone))
        let preview = session.showsBrushPreview
        let brushRadius = CGFloat(session.activeTool == .precise ? session.pixelBrushRadius : session.brushRadius) * max(frame.width, frame.height)
        let color = CanvasOverlays.paintColor(session)
        Canvas { context, _ in
            if !path.isEmpty {
                if stroke.isLasso {
                    context.stroke(path, with: .color(PSTheme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                } else {
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(1, stroke.radius * 2), lineCap: .round, lineJoin: .round))
                }
            }
            // Brush cursor: under the finger while painting, or centred while the size dial is dragged.
            if brushes, let point = cursor ?? (preview ? CGPoint(x: stage.midX, y: stage.midY) : nil) {
                let r = max(3, brushRadius)
                let circle = Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
                context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                context.stroke(circle, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Grid, lasso, clone source, focus reticle, text and shape handles, the
/// picked object and the numbered candidates.
private struct CanvasOverlays: View {
    let session: PhotoEditorSession
    let frame: CGRect
    let stage: CGRect
    let container: CGSize
    let zoom: CGFloat

    static func paintColor(_ session: PhotoEditorSession) -> Color {
        session.activeTool == .precise && session.preciseMode == .pixelBrush ? Color(cgColor: session.paintColor.cgColor).opacity(0.9) : PSTheme.danger.opacity(0.45)
    }

    var body: some View {
        let candidates = session.candidateOverlays
        let lasso = session.lassoPoints
        let showsGrid = zoom >= 6 && session.activeTool == .precise
        let pixelsWide = max(1, session.document.canvasSize.width)
        let cloneSource = session.activeTool == .precise && session.preciseMode == .clone ? session.cloneSource : nil
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
            // Lasso corners placed by taps.
            if lasso.count > 1 {
                var path = Path()
                let points = lasso.map { viewPoint($0) }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(PSTheme.accent), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            if let cloneSource {
                let center = viewPoint(cloneSource)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(PSTheme.warning), lineWidth: 2)
                context.stroke(Path { $0.move(to: CGPoint(x: center.x - 14, y: center.y)); $0.addLine(to: CGPoint(x: center.x + 14, y: center.y)); $0.move(to: CGPoint(x: center.x, y: center.y - 14)); $0.addLine(to: CGPoint(x: center.x, y: center.y + 14)) }, with: .color(PSTheme.warning), lineWidth: 1.5)
            }
            // Focus reticle, like the Camera app's.
            if let focusReticle {
                let center = viewPoint(focusReticle)
                let side: CGFloat = 64
                let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                context.stroke(Path(rect), with: .color(PSTheme.accent), lineWidth: 1.5)
                for (from, to) in [(CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY + 6)), (CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY - 6)),
                                   (CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.minX + 6, y: rect.midY)), (CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX - 6, y: rect.midY))] {
                    context.stroke(Path { $0.move(to: from); $0.addLine(to: to) }, with: .color(PSTheme.accent), lineWidth: 1.5)
                }
            }
            // Text layer handles.
            for (_, bounds, rotation, selected) in textBoxes {
                let rect = viewRect(bounds)
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
                let rect = viewRect(selection.boundingBox).insetBy(dx: -4, dy: -4)
                let path = Path(roundedRect: rect, cornerRadius: 14)
                context.fill(path, with: .color(.white.opacity(0.06)))
                context.stroke(path, with: .linearGradient(Gradient(colors: PSTheme.intelligence), startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)), lineWidth: 2.5)
            }
            // Candidate boxes, numbered like the choice chips.
            for (index, candidate) in candidates.enumerated() {
                let rect = viewRect(candidate.boundingBox)
                let path = Path(roundedRect: rect, cornerRadius: 10)
                context.stroke(path, with: .color(.white), lineWidth: 2.5)
                context.fill(path, with: .color(.white.opacity(0.10)))
                let badge = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: 26, height: 26)
                context.fill(Path(ellipseIn: badge), with: .color(.white))
                context.draw(Text(verbatim: "\(index + 1)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.black), at: CGPoint(x: badge.midX, y: badge.midY))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay {
            if let selection {
                let rect = viewRect(selection.boundingBox)
                // Above the object when there is room, else below it.
                let y = rect.minY > stage.minY + 44 ? rect.minY - 34 : min(stage.maxY - 22, rect.maxY + 34)
                MagicSelectionBar(session: session, candidate: selection)
                    .position(x: min(max(rect.midX, 130), container.width - 130), y: y)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(PSMotion.quick, value: selection?.id)
    }

    private func viewPoint(_ point: PSPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func viewRect(_ rect: PSRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
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

/// The frame driver: rebuilds only the stage at every step of a layout
/// change, so the Metal picture (which cannot animate its own frame) moves
/// with its overlays while the canvas's body, gestures included, stays put.
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
/// the selection (its mask pre-blurred off the main thread), the picked
/// object, or a soft band sweeping the whole photo.
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
            // The spectrum wraps round without a seam, so it needs no blur; the
            // mask arrives already blurred from Core Image.
            AngularGradient(colors: PSTheme.intelligence + [PSTheme.intelligence[0]], center: .center,
                            angle: .degrees(time.truncatingRemainder(dividingBy: 4) * 90))
                .opacity(mask == nil && region == nil ? 0.5 : 0.85)
                .mask { shape(size: proxy.size, time: time) }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shape(size: CGSize, time: Double) -> some View {
        if let mask {
            Image(uiImage: mask).resizable()
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
