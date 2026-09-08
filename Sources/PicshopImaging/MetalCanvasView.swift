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
        let destination = CIRenderDestination(width: Int(drawableSize.width), height: Int(drawableSize.height), pixelFormat: colorPixelFormat, commandBuffer: commandBuffer) { [drawable] in
            drawable.texture
        }
        destination.colorSpace = RenderContext.colorSpace
        destination.isFlipped = false

        // Clear.
        let background = CIImage(color: CIColor(red: backgroundClearColor.red, green: backgroundClearColor.green, blue: backgroundClearColor.blue)).cropped(to: CGRect(origin: .zero, size: drawableSize))
        var composed = background
        if let image, imageFrame.width > 0, imageFrame.height > 0 {
            // Map the image extent into the drawable (points → pixels, flip y for Metal/CI origin).
            let sx = imageFrame.width * scale / image.extent.width
            let sy = imageFrame.height * scale / image.extent.height
            let originX = imageFrame.minX * scale
            let originY = drawableSize.height - (imageFrame.maxY * scale)
            var transform = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            transform = transform.concatenating(CGAffineTransform(scaleX: sx, y: sy))
            transform = transform.concatenating(CGAffineTransform(translationX: originX, y: originY))
            var placed = image.transformed(by: transform)
            if let overlay {
                let placedOverlay = overlay.transformed(by: CGAffineTransform(translationX: -overlay.extent.minX, y: -overlay.extent.minY)
                    .concatenating(CGAffineTransform(scaleX: imageFrame.width * scale / overlay.extent.width, y: imageFrame.height * scale / overlay.extent.height))
                    .concatenating(CGAffineTransform(translationX: originX, y: originY)))
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
