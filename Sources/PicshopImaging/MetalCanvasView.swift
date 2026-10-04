#if canImport(Metal) && canImport(CoreImage)
import Foundation
import Metal
import CoreImage
import CoreGraphics

/// Where and how the canvas draws: placement math and render target setup, shared
/// by `MetalCanvasView` and the tests that check the on-screen orientation.
public enum CanvasPlacement {
    /// Maps `imageExtent` (Core Image space) onto `frame` (points, top-left origin) inside a
    /// drawable of `drawableSize` pixels, whose Core Image origin is bottom-left.
    public static func transform(imageExtent: CGRect, frame: CGRect, drawableSize: CGSize, scale: CGFloat) -> CGAffineTransform {
        let sx = frame.width * scale / imageExtent.width
        let sy = frame.height * scale / imageExtent.height
        let originX = frame.minX * scale
        let originY = drawableSize.height - (frame.maxY * scale)
        return CGAffineTransform(translationX: -imageExtent.minX, y: -imageExtent.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: originX, y: originY))
    }

    /// A render destination configured exactly like the canvas's drawable.
    ///
    /// Flipped: unflipped, Core Image writes its y = 0 row into texture row 0, which
    /// Metal shows at the top of the screen, so every photo appeared upside down with
    /// its reading order kept. `OrientationTests` reads the texture back to prove it.
    public static func destination(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm, commandBuffer: MTLCommandBuffer?,
                                   texture: @escaping () -> MTLTexture) -> CIRenderDestination {
        let destination = CIRenderDestination(width: width, height: height, pixelFormat: pixelFormat, commandBuffer: commandBuffer, mtlTextureProvider: texture)
        destination.colorSpace = RenderContext.colorSpace
        destination.isFlipped = true
        return destination
    }
}

/// Where the render loop hands finished frames, straight to the screen (MetalCanvasView).
/// `generation` increases with every render request, so a late frame never replaces a newer one.
@MainActor public protocol CanvasSink: AnyObject {
    func present(_ image: CIImage, generation: Int)
    /// The mask or selection overlay for the frame of that generation (nil clears it). W2, D17: drawn over the
    /// image and under the W1 `overlay`; never baked into the preview.
    func presentOverlay(_ overlay: CIImage?, generation: Int)
}

public extension CanvasSink {
    func presentOverlay(_ overlay: CIImage?, generation: Int) {}
}
#endif

#if canImport(UIKit) && canImport(MetalKit)
import Foundation
import UIKit
import MetalKit
import CoreImage
import PicshopCore

/// Displays a `CIImage` through Metal with pinch-to-zoom quality scaling.
/// The SwiftUI editor wraps this view; all drawing happens on the GPU through
/// the canvas's own `CIContext` (`RenderContext.interactive`).
///
/// Frames arrive two ways: settled frames through SwiftUI (`image`), and frames
/// under a moving finger straight from the frame pump (`present(_:generation:)`),
/// which skips SwiftUI's update pass. Either way a frame older than the one on
/// screen is dropped. At most `maxInFlightFrames` command buffers are queued: when
/// the GPU is busy (the local model, Vision) a frame is skipped and redrawn when
/// one completes, instead of blocking the main thread on the next drawable.
public final class MetalCanvasView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let context = RenderContext.interactive
    private let frameBudget = FrameBudget()

    /// The image to display, in Core Image coordinates (origin bottom-left).
    public var image: CIImage? {
        didSet { setNeedsDisplay() }
    }

    /// Generation of `image`: a frame with a lower one never replaces it.
    public private(set) var displayedGeneration = 0

    /// Optional overlay drawn on top (masks preview, clipping warnings, candidate highlights).
    public var overlay: CIImage? {
        didSet { setNeedsDisplay() }
    }

    /// The mask or selection overlay (W2, D17), separate from `overlay`, which SwiftUI reassigns on every pass.
    /// Set through `presentOverlay(_:generation:)` only, so a settled overlay never replaces a newer interactive one.
    public private(set) var maskOverlay: CIImage? {
        didSet { setNeedsDisplay() }
    }

    /// Generation of `maskOverlay`.
    public private(set) var maskOverlayGeneration = 0

    /// Placement of the image inside the view (points, top-left origin).
    public var imageFrame: CGRect = .zero {
        didSet { setNeedsDisplay() }
    }

    /// The canvas surround: true black; graphite (#1E1E21) while a tone, colour or mask panel is open (W2, D18).
    public var backgroundClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1) {
        didSet {
            clearColor = backgroundClearColor
            setNeedsDisplay()
        }
    }

    /// Command buffers allowed in the GPU queue at once.
    public var maxInFlightFrames: Int {
        get { frameBudget.limit }
        set { frameBudget.limit = max(1, newValue) }
    }

    /// Called on the main actor when a frame reaches the glass: its generation and
    /// the time it was presented (touch-to-photon ends here).
    public var onPresented: (@MainActor (_ generation: Int, _ presentedTime: CFTimeInterval) -> Void)?

    /// A frame was skipped for lack of a free command buffer: drawn when one completes.
    private var skippedFrame = false

    /// Caps the drawable resolution: 3× panels render at 2× when the phone is hot.
    public var maxContentScale: CGFloat = UIScreen.main.scale {
        didSet {
            let scale = min(UIScreen.main.scale, max(1, maxContentScale))
            if contentScaleFactor != scale {
                contentScaleFactor = scale
                setNeedsDisplay()
            }
        }
    }

    /// Frame-rate ceiling; drawing is on demand (the frame pump's display link applies the
    /// governor's cap), so this only bounds bursts of redraws.
    public var maxFrameRate: Int = 120 {
        didSet { preferredFramesPerSecond = max(30, maxFrameRate) }
    }

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        clearColor = backgroundClearColor
        backgroundColor = .black
        isOpaque = true
        autoResizeDrawable = true
        presentsWithTransaction = false
        contentScaleFactor = UIScreen.main.scale
        preferredFramesPerSecond = max(60, UIScreen.main.maximumFramesPerSecond)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `image` if it is not older than the frame on screen. The SwiftUI path
    /// passes the same generation again with a recomposed image (a split compare).
    @discardableResult
    public func show(_ image: CIImage?, generation: Int) -> Bool {
        guard generation >= displayedGeneration else { return false }
        displayedGeneration = generation
        if self.image !== image { self.image = image }
        return true
    }

    public override func draw(_ rect: CGRect) {
        // No free command buffer: skip rather than block on the drawable; redrawn on completion.
        guard frameBudget.reserve() else {
            skippedFrame = true
            return
        }
        guard let drawable = currentDrawable, let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameBudget.release()
            return
        }
        let signpost = PSSignpost.begin("canvas.draw")
        defer { PSSignpost.end(signpost) }
        let scale = contentScaleFactor
        let drawableSize = CGSize(width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
        let destination = CanvasPlacement.destination(width: Int(drawableSize.width), height: Int(drawableSize.height), pixelFormat: colorPixelFormat, commandBuffer: commandBuffer) { [drawable] in
            drawable.texture
        }

        // Clear.
        let background = CIImage(color: CIColor(red: backgroundClearColor.red, green: backgroundClearColor.green, blue: backgroundClearColor.blue)).cropped(to: CGRect(origin: .zero, size: drawableSize))
        var composed = background
        if let image, imageFrame.width > 0, imageFrame.height > 0 {
            // Map the image extent into the drawable (points → pixels, flip y for Metal/CI origin).
            var placed = image.transformed(by: CanvasPlacement.transform(imageExtent: image.extent, frame: imageFrame, drawableSize: drawableSize, scale: scale))
            // The mask or selection overlay (D17) over the picture, then the SwiftUI overlay on top. Each is placed by
            // its own extent onto the same frame, so a settled overlay at another size still lines up.
            if let maskOverlay, !maskOverlay.extent.isEmpty, !maskOverlay.extent.isInfinite {
                let placedMask = maskOverlay.transformed(by: CanvasPlacement.transform(imageExtent: maskOverlay.extent, frame: imageFrame, drawableSize: drawableSize, scale: scale))
                placed = placedMask.composited(over: placed)
            }
            if let overlay {
                let placedOverlay = overlay.transformed(by: CanvasPlacement.transform(imageExtent: overlay.extent, frame: imageFrame, drawableSize: drawableSize, scale: scale))
                placed = placedOverlay.composited(over: placed)
            }
            composed = placed.composited(over: background)
        }
        do {
            try context.startTask(toRender: composed, to: destination)
        } catch {
            PSLog.error("canvas render failed: \(error)", category: .imaging)
        }
        let generation = displayedGeneration
        #if targetEnvironment(simulator)
        // The simulator's drawables have no presented handler: the GPU completion stands in.
        let presentsOnCompletion = onPresented != nil
        #else
        if onPresented != nil {
            drawable.addPresentedHandler { [weak self] presented in
                let time = presented.presentedTime
                Task { @MainActor [weak self] in self?.onPresented?(generation, time) }
            }
        }
        let presentsOnCompletion = false
        #endif
        let budget = frameBudget
        commandBuffer.addCompletedHandler { [weak self] buffer in
            budget.release()
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            PSSignpost.event("canvas.gpu", String(format: "%.2f ms", gpu * 1000))
            Task { @MainActor [weak self] in
                self?.redrawSkippedFrame()
                if presentsOnCompletion { self?.onPresented?(generation, CACurrentMediaTime()) }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func redrawSkippedFrame() {
        guard skippedFrame else { return }
        skippedFrame = false
        setNeedsDisplay()
    }
}

/// How many command buffers the canvas has queued; reserved on the main thread,
/// released from Metal's completion thread.
final class FrameBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = 0
    private var maximum = 2

    var limit: Int {
        get { lock.withLock { maximum } }
        set { lock.withLock { maximum = newValue } }
    }

    var count: Int { lock.withLock { queued } }

    func reserve() -> Bool {
        lock.withLock {
            guard queued < maximum else { return false }
            queued += 1
            return true
        }
    }

    func release() {
        lock.withLock { queued = max(0, queued - 1) }
    }
}

extension MetalCanvasView: CanvasSink {
    /// A frame straight from the pump: on screen at the next display refresh, unless
    /// a newer one is already there.
    public func present(_ image: CIImage, generation: Int) {
        show(image, generation: generation)
    }

    /// The mask overlay of the frame of that generation, unless a newer one is already set; `draw(_:)` puts it
    /// over the image and under `overlay`.
    public func presentOverlay(_ overlay: CIImage?, generation: Int) {
        guard generation >= maskOverlayGeneration else { return }
        maskOverlayGeneration = generation
        if maskOverlay !== overlay { maskOverlay = overlay }
    }
}
#endif
