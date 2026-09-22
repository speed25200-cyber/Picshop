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
            let placed: CIImage?
            switch overlay.content {
            case .video(_, let transform, _):
                if let source = instruction.overlaySources[overlay.id], let buffer = request.sourceFrame(byTrackID: source.trackID) {
                    var media = CIImage(cvPixelBuffer: buffer).transformed(by: source.preferredTransform)
                    media = media.transformed(by: CGAffineTransform(translationX: -media.extent.minX, y: -media.extent.minY))
                    placed = Self.place(media, transform: transform, key: overlay.chromaKey, canvas: canvas)
                } else {
                    placed = nil
                }
            case .image(_, let transform):
                placed = overlayPicture(overlay, url: instruction.overlayImageURLs[overlay.id]).map { Self.place($0, transform: transform, key: overlay.chromaKey, canvas: canvas) }
            default:
                placed = overlayImage(overlay, renderSize: renderSize)
            }
            guard var image = placed else { continue }
            var entrance = 1.0
            if let animation = overlay.animation {
                let state = animation.state(at: time, span: overlay.span)
                if state != .rest {
                    let anchor = overlay.anchorPoint
                    image = Self.animate(image, state: state, around: CGPoint(x: anchor.x * canvas.width, y: (1 - anchor.y) * canvas.height), canvas: canvas)
                }
                entrance = state.opacity
            }
            if let adjustment = overlay.keyframeAdjustment(at: time) {
                // Hand-set keyframes: the overlay eases between the places it was given.
                var state = TextAnimation.State()
                state.scale = adjustment.scale
                state.offsetX = adjustment.offset.x
                state.offsetY = adjustment.offset.y
                let anchor = overlay.anchorPoint
                image = Self.animate(image, state: state, around: CGPoint(x: anchor.x * canvas.width, y: (1 - anchor.y) * canvas.height), canvas: canvas)
            }
            if let tracking = overlay.tracking, !tracking.isEmpty {
                // Attached to a moving subject: shifted by how far it has moved since the overlay was placed.
                let shift = tracking.offset(at: time)
                image = image.transformed(by: CGAffineTransform(translationX: shift.x * canvas.width, y: -shift.y * canvas.height))
            }
            var alpha = (overlay.opacity ?? 1.0) * entrance
            if overlay.fadeIn > 0 { alpha = min(alpha, (time - overlay.span.start) / overlay.fadeIn) }
            if overlay.fadeOut > 0 { alpha = min(alpha, (overlay.span.end - time) / overlay.fadeOut) }
            frame = AdjustmentPipeline.blend(image, over: frame, alpha: alpha.clamped(to: 0...1))
        }
        if let captions = instruction.captions, let cue = captions.cue(at: time), let image = captionImage(cue, track: captions, time: time, renderSize: renderSize) {
            frame = image.composited(over: frame)
        }
        return frame.cropped(to: canvas)
    }

    /// One instant of an overlay's entrance: revealed, sharpened, scaled and lifted into place.
    static func animate(_ image: CIImage, state: TextAnimation.State, around center: CGPoint, canvas: CGRect) -> CIImage {
        var result = image
        if state.reveal < 0.999 {
            let extent = image.extent
            let edge = max(8, extent.width * 0.1)
            let front = extent.minX - edge + (extent.width + edge) * CGFloat(state.reveal)
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: front, y: 0)
            gradient.point1 = CGPoint(x: front + edge, y: 0)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            if let mask = gradient.outputImage?.cropped(to: extent) {
                result = result.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
            }
        }
        if state.blur > 0.01 {
            result = result.applyingGaussianBlur(sigma: state.blur * 0.012 * Double(max(canvas.width, canvas.height)))
        }
        if abs(state.scale - 1) > 0.0005 || abs(state.offsetY) > 0.0005 || abs(state.offsetX) > 0.0005 {
            let scale = CGFloat(state.scale)
            let transform = CGAffineTransform(translationX: center.x + CGFloat(state.offsetX) * canvas.width, y: center.y - CGFloat(state.offsetY) * canvas.height)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y)
            result = result.transformed(by: transform)
        }
        return result.cropped(to: canvas)
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
        if let url = clip.lutURL, clip.lutIntensity > 0.001 {
            image = ColorCube.shared.apply(lutAt: url, intensity: clip.lutIntensity, to: image)
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

    /// Places a picture or a video frame over the canvas: keyed, scaled to its
    /// share of the frame width, rotated, rounded like a picture-in-picture.
    static func place(_ media: CIImage, transform: LayerTransform, key: ChromaKey?, canvas: CGRect) -> CIImage {
        var image = media
        if let key { image = ColorCube.shared.apply(key, to: image) }
        let width = max(1, image.extent.width), height = max(1, image.extent.height)
        if key == nil, transform.scale < 0.98 {
            // Rounded corners read as a window over the picture.
            let radius = min(width, height) * 0.06
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = image.extent
            shape.radius = Float(radius)
            shape.color = .white
            if let mask = shape.outputImage {
                image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
            }
        }
        let scale = canvas.width * CGFloat(max(0.05, transform.scale)) / width
        var affine = CGAffineTransform(translationX: canvas.minX + CGFloat(transform.center.x) * canvas.width, y: canvas.minY + CGFloat(1 - transform.center.y) * canvas.height)
        affine = affine.rotated(by: CGFloat(-transform.rotation * .pi / 180))
        affine = affine.scaledBy(x: scale * (transform.isFlippedHorizontally ? -1 : 1), y: scale * (transform.isFlippedVertically ? -1 : 1))
        affine = affine.translatedBy(x: -image.extent.midX, y: -image.extent.midY)
        return image.transformed(by: affine).cropped(to: canvas)
    }

    private var pictureCache: [UUID: CIImage] = [:]

    /// A picture overlay's pixels, decoded once.
    private func overlayPicture(_ overlay: TimelineOverlay, url: URL?) -> CIImage? {
        if let cached = pictureCache[overlay.id] { return cached }
        guard let url, let cg = try? ImageSupport.loadCGImage(at: url, maxPixelSize: 2048) else { return nil }
        let image = CIImage(cgImage: cg)
        if pictureCache.count > 12 { pictureCache.removeAll() }
        pictureCache[overlay.id] = image
        return image
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
        case .image, .video:
            image = nil
        }
        if overlayCache.count > 24 { overlayCache.removeAll() }
        if let image { overlayCache[key] = image }
        return image
    }
}
#endif
