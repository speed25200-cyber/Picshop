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
    public static func destination(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm, commandBuffer: MTLCommandBuffer?,
                                   texture: @escaping () -> MTLTexture) -> CIRenderDestination {
        let destination = CIRenderDestination(width: width, height: height, pixelFormat: pixelFormat, commandBuffer: commandBuffer, mtlTextureProvider: texture)
        destination.colorSpace = RenderContext.colorSpace
        destination.isFlipped = false
        return destination
    }
}
#endif

#if canImport(UIKit) && canImport(MetalKit)
import Foundation
import UIKit
import MetalKit
import CoreImage
import PicshopCore

/// Displays a `CIImage` through Metal with pinch-to-zoom quality scaling.
/// The SwiftUI editor wraps this view; all drawing happens on the GPU via the
/// shared `CIContext`, so full-resolution previews stay at 120 Hz.
public final class MetalCanvasView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let context = RenderContext.shared

    /// The image to display, in Core Image coordinates (origin bottom-left).
    public var image: CIImage? {
        didSet { setNeedsDisplay() }
    }

    /// Optional overlay drawn on top (masks preview, candidate highlights).
    public var overlay: CIImage? {
        didSet { setNeedsDisplay() }
    }

    /// Placement of the image inside the view (points, top-left origin).
    public var imageFrame: CGRect = .zero {
        didSet { setNeedsDisplay() }
    }

    public var backgroundClearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)

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

    /// Frame-rate ceiling; drawing is on demand, so this only bounds bursts of redraws.
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

    public override func draw(_ rect: CGRect) {
        guard let drawable = currentDrawable, let commandQueue, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
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
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
#endif
