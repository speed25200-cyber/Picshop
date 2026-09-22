#if canImport(AVFoundation) && canImport(CoreImage)
import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import PicshopCore
import PicshopImaging

/// Draws every frame of the composition: per-clip geometry and colour,
/// transitions between the A/B tracks, and text overlays. All work runs on
/// the GPU through the shared Core Image context.
public final class PicshopCompositor: NSObject, AVVideoCompositing {
    private let context = RenderContext.shared
    private let queue = DispatchQueue(label: "com.picshop.compositor", qos: .userInteractive)
    private var overlayCache: [String: CIImage] = [:]
    private var captionCache: [String: CIImage] = [:]
    private var cancelled = false

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func cancelAllPendingVideoCompositionRequests() {
        queue.sync { cancelled = true }
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            cancelled = false
            guard let instruction = request.videoCompositionInstruction as? PicshopCompositionInstruction else {
                request.finish(with: PicshopError.renderFailed("unexpected instruction"))
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: PicshopError.renderFailed("no output buffer"))
                return
            }
            let time = CMTimeGetSeconds(request.compositionTime)
            let renderSize = request.renderContext.size
            let image = compose(instruction, request: request, time: time, renderSize: renderSize)
            context.render(image, to: output, bounds: CGRect(origin: .zero, size: renderSize), colorSpace: RenderContext.colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    // MARK: - Frame composition

    func compose(_ instruction: PicshopCompositionInstruction, request: AVAsynchronousVideoCompositionRequest, time: Double, renderSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let background = CIImage(color: instruction.backgroundColor.ciColor).cropped(to: canvas)
        var frame = background

        if let buffer = request.sourceFrame(byTrackID: instruction.primary.trackID) {
            frame = Self.render(clip: instruction.primary, buffer: buffer, canvas: canvas, time: time).composited(over: background)
        }
        if let secondary = instruction.secondary, let transition = instruction.transition, let buffer = request.sourceFrame(byTrackID: secondary.trackID) {
            let incoming = Self.render(clip: secondary, buffer: buffer, canvas: canvas, time: time).composited(over: background)
            let start = CMTimeGetSeconds(instruction.timeRange.start)
            let duration = max(0.001, CMTimeGetSeconds(instruction.timeRange.duration))
            let progress = ((time - start) / duration).clamped(to: 0...1)
            frame = Self.transition(transition.kind, from: frame, to: incoming, progress: progress, canvas: canvas)
        }

        for overlay in instruction.overlays where overlay.span.contains(time) {
            guard let image = overlayImage(overlay, renderSize: renderSize) else { continue }
            var alpha = 1.0
            if overlay.fadeIn > 0 { alpha = min(alpha, (time - overlay.span.start) / overlay.fadeIn) }
            if overlay.fadeOut > 0 { alpha = min(alpha, (overlay.span.end - time) / overlay.fadeOut) }
            frame = AdjustmentPipeline.blend(image, over: frame, alpha: alpha.clamped(to: 0...1))
        }
        if let captions = instruction.captions, let cue = captions.cue(at: time), let image = captionImage(cue, track: captions, time: time, renderSize: renderSize) {
            frame = image.composited(over: frame)
        }
        return frame.cropped(to: canvas)
    }

    /// The caption for this instant, cached per spoken word.
    private func captionImage(_ cue: CaptionCue, track: CaptionTrack, time: Double, renderSize: CGSize) -> CIImage? {
        #if canImport(UIKit)
        let active = cue.activeWordIndex(at: time)
        let key = "\(cue.id)-\(active ?? -1)-\(track.style.rawValue)-\(track.verticalPosition)-\(track.scale)-\(track.textColor.hashValue)-\(track.highlightColor.hashValue)-\(Int(renderSize.width))"
        if let cached = captionCache[key] { return cached }
        guard let image = CaptionRasterizer.placedImage(for: cue, activeWord: active, track: track, canvasSize: renderSize) else { return nil }
        if captionCache.count > 48 { captionCache.removeAll() }
        captionCache[key] = image
        return image
        #else
        return nil
        #endif
    }

    /// Applies orientation, crop, rotation, flip, framing and colour to one source frame.
    static func render(clip: ClipRenderParameters, buffer: CVPixelBuffer, canvas: CGRect, time: Double = 0) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        image = image.transformed(by: clip.preferredTransform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if let crop = clip.crop {
            let rect = crop.ciRect(in: image.extent).integral.intersection(image.extent)
            if !rect.isEmpty {
                image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            }
        }
        if clip.rotation != 0 {
            let radians = -clip.rotation * .pi / 180
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(radians)).translatedBy(x: -center.x, y: -center.y)
            image = image.transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if clip.flipHorizontal {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
        }

        if let motion = clip.motion, !motion.isEmpty, image.extent.width > 1, image.extent.height > 1 {
            // Animated framing: the window of the source the virtual camera sees, scaled to fill.
            let width = image.extent.width, height = image.extent.height
            let framing = motion.sample(at: time - clip.timelineStart)
            let window = ClipMotion.window(focus: framing.focus, zoom: framing.zoom, sourceAspect: Double(width / height), outputAspect: Double(canvas.width / max(1, canvas.height)))
            let rect = CGRect(x: window.minX * width, y: (1 - window.maxY) * height, width: window.width * width, height: window.height * height)
            let scale = canvas.width / max(1, rect.width)
            image = image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
                .transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
                .cropped(to: canvas)
        } else {
            // Fit or fill the canvas.
            let sx = canvas.width / max(1, image.extent.width)
            let sy = canvas.height / max(1, image.extent.height)
            let scale = clip.fill ? max(sx, sy) : min(sx, sy)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = canvas.midX - image.extent.midX
            let dy = canvas.midY - image.extent.midY
            image = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
            if clip.fill { image = image.cropped(to: canvas) }
        }

        let look: (preset: FilterPreset, intensity: Double)? = clip.look == .original ? nil : (clip.look, clip.lookIntensity)
        let adjustments = AdjustmentPipeline.effectiveAdjustments(manual: clip.adjustments, look: look)
        let curve = clip.look.toneCurve
        if !adjustments.isNeutral || !curve.isIdentity {
            let referenceScale = canvas.width / 1920
            image = AdjustmentPipeline.apply(adjustments, toneCurve: curve, to: image, scale: referenceScale)
        }
        if let match = clip.colorMatch {
            image = ColorCube.shared.apply(match, to: image)
        }
        if clip.colorMixer != nil || clip.colorGrade != nil {
            image = ColorCube.shared.apply(mixer: clip.colorMixer, grade: clip.colorGrade, to: image)
        }
        return image
    }

    static func transition(_ kind: TransitionKind, from: CIImage, to: CIImage, progress: Double, canvas: CGRect) -> CIImage {
        let p = progress
        switch kind {
        case .none:
            return p < 0.5 ? from : to
        case .crossDissolve:
            return AdjustmentPipeline.blend(to, over: from, alpha: p)
        case .fadeToBlack, .fadeToWhite:
            let color = kind == .fadeToBlack ? CIColor.black : CIColor.white
            let solid = CIImage(color: color).cropped(to: canvas)
            if p < 0.5 { return AdjustmentPipeline.blend(solid, over: from, alpha: p * 2) }
            return AdjustmentPipeline.blend(to, over: solid, alpha: (p - 0.5) * 2)
        case .slideLeft, .slideRight:
            let direction: CGFloat = kind == .slideLeft ? -1 : 1
            let eased = easeInOut(p)
            let outgoing = from.transformed(by: CGAffineTransform(translationX: direction * canvas.width * eased, y: 0))
            let incoming = to.transformed(by: CGAffineTransform(translationX: -direction * canvas.width * (1 - eased), y: 0))
            return incoming.composited(over: outgoing).cropped(to: canvas)
        case .wipeLeft:
            let width = canvas.width * easeInOut(p)
            let revealed = to.cropped(to: CGRect(x: canvas.minX, y: canvas.minY, width: width, height: canvas.height))
            return revealed.composited(over: from).cropped(to: canvas)
        case .zoom:
            let scale = 1 + 0.35 * easeInOut(p)
            let center = CGPoint(x: canvas.midX, y: canvas.midY)
            let zoomed = from.transformed(by: CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: scale, y: scale).translatedBy(x: -center.x, y: -center.y)).cropped(to: canvas)
            return AdjustmentPipeline.blend(to, over: zoomed, alpha: p)
        case .blur:
            let radius = sin(p * .pi) * 24
            let blurredFrom = from.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: canvas)
            let blurredTo = to.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: canvas)
            return AdjustmentPipeline.blend(blurredTo, over: blurredFrom, alpha: p)
        }
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func overlayImage(_ overlay: TimelineOverlay, renderSize: CGSize) -> CIImage? {
        let key = "\(overlay.id)-\(overlay.content.hashValue)-\(Int(renderSize.width))"
        if let cached = overlayCache[key] { return cached }
        var image: CIImage?
        switch overlay.content {
        case .text(let element):
            #if canImport(UIKit)
            if let cg = TextRasterizer.image(for: element, canvasSize: renderSize) {
                let raster = CIImage(cgImage: cg)
                let cx = element.center.x * renderSize.width
                let cy = (1 - element.center.y) * renderSize.height
                var transform = CGAffineTransform(translationX: cx, y: cy)
                transform = transform.rotated(by: CGFloat(-element.rotation * .pi / 180))
                transform = transform.translatedBy(x: -raster.extent.midX, y: -raster.extent.midY)
                image = raster.transformed(by: transform)
            }
            #endif
        case .shape(let shape, let center):
            #if canImport(UIKit)
            if let cg = TextRasterizer.image(for: shape, canvasSize: renderSize) {
                let raster = CIImage(cgImage: cg)
                image = raster.transformed(by: CGAffineTransform(translationX: center.x * renderSize.width - raster.extent.midX, y: (1 - center.y) * renderSize.height - raster.extent.midY))
            }
            #endif
        case .image:
            image = nil
        }
        if overlayCache.count > 24 { overlayCache.removeAll() }
        if let image { overlayCache[key] = image }
        return image
    }
}
#endif
