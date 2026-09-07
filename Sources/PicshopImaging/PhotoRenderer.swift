#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import PicshopCore

/// Turns a `PhotoDocument` into a `CIImage` by replaying every layer's edit
/// stack. Expensive operations (inpainting, upscaling) are cached by operation
/// id and resolution so scrubbing sliders after an object removal stays
/// interactive.
public actor PhotoRenderer {
    public struct Options: Sendable {
        /// Longest side of the rendered canvas in pixels. `nil` renders at full resolution.
        public var targetLongestSide: Double?
        /// Show the untouched base image (before/after compare).
        public var showOriginal: Bool
        public var includeOverlays: Bool
        /// Skip expensive operations that are not cached yet (fast interactive preview).
        public var allowExpensiveWork: Bool

        public init(targetLongestSide: Double? = nil, showOriginal: Bool = false, includeOverlays: Bool = true, allowExpensiveWork: Bool = true) {
            self.targetLongestSide = targetLongestSide
            self.showOriginal = showOriginal
            self.includeOverlays = includeOverlays
            self.allowExpensiveWork = allowExpensiveWork
        }

        public static let preview = Options(targetLongestSide: 2048)
        public static let thumbnail = Options(targetLongestSide: 512, includeOverlays: true, allowExpensiveWork: false)
        public static let full = Options()
    }

    private let store: ProjectStore
    private let projectID: UUID
    private let inpainting: InpaintingPipeline
    private let upscaler: Upscaler
    private var sourceCache: [String: CIImage] = [:]
    private var operationCache: [String: CIImage] = [:]
    private var overlayCache: [String: CIImage] = [:]

    public init(store: ProjectStore, projectID: UUID, inpainting: InpaintingPipeline, upscaler: Upscaler = Upscaler()) {
        self.store = store
        self.projectID = projectID
        self.inpainting = inpainting
        self.upscaler = upscaler
    }

    public var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    /// Drops all cached intermediates (call when memory is tight or media changed).
    public func purgeCaches() {
        sourceCache.removeAll()
        operationCache.removeAll()
        overlayCache.removeAll()
    }

    public func purgeOperationCache(for operationIDs: Set<UUID>) {
        operationCache = operationCache.filter { key, _ in !operationIDs.contains { key.hasPrefix($0.uuidString) } }
    }

    // MARK: - Rendering

    public func render(_ document: PhotoDocument, options: Options = .preview) async throws -> CIImage {
        let timer = PSTimer("render")
        defer { timer.log(category: .imaging) }

        guard let base = document.baseLayer, let baseAsset = base.imageAsset else {
            throw PicshopError.renderFailed("document has no photo")
        }
        // Preview scale relative to the full-resolution original.
        let fullLongest = max(baseAsset.pixelSize.width, baseAsset.pixelSize.height)
        let scale = options.targetLongestSide.map { min(1, $0 / max(1, fullLongest)) } ?? 1

        let baseImage = try await renderImageLayer(base, asset: baseAsset, scale: scale, options: options)
        let canvasRect = CGRect(origin: .zero, size: baseImage.extent.size)
        var canvas = CIImage(color: document.backgroundColor.ciColor).cropped(to: canvasRect)
        canvas = composite(baseImage.transformed(by: CGAffineTransform(translationX: -baseImage.extent.minX, y: -baseImage.extent.minY)), over: canvas, layer: base, canvasRect: canvasRect, isBase: true)

        if options.showOriginal { return canvas }

        for layer in document.layers where layer.id != base.id && layer.isVisible {
            guard options.includeOverlays else { break }
            let rendered: CIImage?
            switch layer.content {
            case .image(let asset):
                rendered = try await renderImageLayer(layer, asset: asset, scale: scale, options: options)
            case .text(let element):
                rendered = overlayImage(key: "text-\(layer.id)-\(element.hashValue)-\(Int(canvasRect.width))") {
                    #if canImport(UIKit)
                    return TextRasterizer.image(for: element, canvasSize: canvasRect.size).map { CIImage(cgImage: $0) }
                    #else
                    return nil
                    #endif
                }
            case .shape(let shape):
                rendered = overlayImage(key: "shape-\(layer.id)-\(shape.hashValue)-\(Int(canvasRect.width))") {
                    #if canImport(UIKit)
                    return TextRasterizer.image(for: shape, canvasSize: canvasRect.size).map { CIImage(cgImage: $0) }
                    #else
                    return nil
                    #endif
                }
            case .fill(let color):
                rendered = CIImage(color: color.ciColor).cropped(to: canvasRect)
            case .adjustment(let adjustments):
                canvas = AdjustmentPipeline.apply(adjustments, toneCurve: .identity, to: canvas, scale: scale)
                rendered = nil
            }
            if let rendered {
                canvas = composite(rendered, over: canvas, layer: layer, canvasRect: canvasRect, isBase: false)
            }
        }
        return canvas.cropped(to: canvasRect)
    }

    /// Renders only the base photo with its edits (used by tools that need the pixels, e.g. segmentation).
    public func renderBase(_ document: PhotoDocument, options: Options = .preview) async throws -> CIImage {
        guard let base = document.baseLayer, let asset = base.imageAsset else { throw PicshopError.renderFailed("no photo") }
        let fullLongest = max(asset.pixelSize.width, asset.pixelSize.height)
        let scale = options.targetLongestSide.map { min(1, $0 / max(1, fullLongest)) } ?? 1
        let image = try await renderImageLayer(base, asset: asset, scale: scale, options: options)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    // MARK: - Layers

    private func source(for asset: MediaAsset, scale: Double) throws -> CIImage {
        let longest = max(asset.pixelSize.width, asset.pixelSize.height)
        let targetSide = Int((longest * scale).rounded())
        let key = "\(asset.relativePath)@\(targetSide)"
        if let cached = sourceCache[key] { return cached }
        let url = store.url(for: asset.relativePath, in: projectID)
        let image: CIImage
        if scale >= 0.999 {
            image = try ImageSupport.loadCIImage(at: url)
        } else {
            let cg = try ImageSupport.loadCGImage(at: url, maxPixelSize: targetSide)
            image = CIImage(cgImage: cg)
        }
        if sourceCache.count > 8 { sourceCache.removeAll() }
        sourceCache[key] = image
        return image
    }

    private func renderImageLayer(_ layer: Layer, asset: MediaAsset, scale: Double, options: Options) async throws -> CIImage {
        var image = try source(for: asset, scale: scale)
        // Actual ratio between this render and the original (thumbnail loader rounds).
        let effectiveScale = image.extent.width / max(1, asset.pixelSize.width)
        if options.showOriginal { return image }

        for operation in layer.edits.operations {
            image = try await apply(operation, to: image, layer: layer, scale: effectiveScale, options: options)
        }
        let look = layer.edits.resolvedLook
        let adjustments = AdjustmentPipeline.effectiveAdjustments(manual: layer.edits.resolvedAdjustments, look: look)
        let curve = layer.edits.resolvedToneCurve
        if !adjustments.isNeutral || !curve.isIdentity {
            image = AdjustmentPipeline.apply(adjustments, toneCurve: curve, to: image, scale: effectiveScale)
        }
        return image
    }

    private func apply(_ operation: EditOperation, to input: CIImage, layer: Layer, scale: Double, options: Options) async throws -> CIImage {
        let extent = input.extent
        let cacheKey = "\(operation.id.uuidString)@\(Int(extent.width))x\(Int(extent.height))"
        switch operation.kind {
        case .adjust, .adjustments, .toneCurve, .look, .autoEnhance:
            return input

        case .crop(let rect):
            let cropRect = rect.ciRect(in: extent).integral.intersection(extent)
            guard !cropRect.isEmpty else { return input }
            return input.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))

        case .rotate(let degrees):
            return rotated(input, degrees: degrees, cropToContent: false)

        case .straighten(let degrees):
            return rotated(input, degrees: degrees, cropToContent: true)

        case .flip(let axis):
            let transform = axis == .horizontal ? CGAffineTransform(scaleX: -1, y: 1) : CGAffineTransform(scaleX: 1, y: -1)
            let flipped = input.transformed(by: transform)
            return flipped.transformed(by: CGAffineTransform(translationX: -flipped.extent.minX, y: -flipped.extent.minY))

        case .perspective(let horizontal, let vertical):
            return perspective(input, horizontal: horizontal, vertical: vertical)

        case .removeObject(let mask):
            if let cached = operationCache[cacheKey] { return cached }
            guard options.allowExpensiveWork, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let result = try await inpainting.fill(image: input, mask: maskImage, boundingBox: mask.boundingBox, feather: mask.feather)
            operationCache[cacheKey] = result
            return result

        case .heal(let strokes):
            if let cached = operationCache[cacheKey] { return cached }
            guard options.allowExpensiveWork else { return input }
            let width = Int(extent.width), height = Int(extent.height)
            var bytes = [UInt8](repeating: 0, count: width * height)
            MaskStore.rasterize(strokes: strokes, width: width, height: height, into: &bytes)
            guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else { return input }
            let maskImage = CIImage(cgImage: cg)
            let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
            let result = try await inpainting.fill(image: input, mask: maskImage, boundingBox: box, feather: 0.01)
            operationCache[cacheKey] = result
            return result

        case .removeBackground(let mask):
            guard let mask, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            return AdjustmentPipeline.applyingAlpha(mask: maskImage, to: input)

        case .replaceBackground(let background, let mask):
            guard let mask, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let backdrop = BackgroundEffects.backdrop(for: background, original: input, scale: scale, store: store, projectID: projectID)
            return AdjustmentPipeline.blendWithMask(foreground: input, background: backdrop, mask: maskImage)

        case .blurBackground(let amount, let mask):
            guard let mask, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            return BackgroundEffects.portraitBlur(input, subjectMask: maskImage, amount: amount, scale: scale)

        case .selectiveAdjust(let mask, let adjustments):
            guard let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let adjusted = AdjustmentPipeline.apply(adjustments, toneCurve: .identity, to: input, scale: scale)
            return AdjustmentPipeline.blendWithMask(foreground: adjusted, background: input, mask: maskImage)

        case .upscale(let factor):
            if let cached = operationCache[cacheKey] { return cached }
            guard options.allowExpensiveWork else { return input }
            let result = try await upscaler.upscale(input, factor: factor)
            operationCache[cacheKey] = result
            return result

        case .denoise(let amount):
            let filter = CIFilter.noiseReduction()
            filter.inputImage = input
            filter.noiseLevel = Float(amount * 0.1)
            filter.sharpness = 0.4
            return filter.outputImage?.cropped(to: extent) ?? input

        case .sharpen(let amount):
            let filter = CIFilter.unsharpMask()
            filter.inputImage = input
            filter.radius = Float(2.5 * scale)
            filter.intensity = Float(amount * 1.5)
            return filter.outputImage?.cropped(to: extent) ?? input

        case .relight(let direction, let intensity):
            return BackgroundEffects.relight(input, direction: direction, intensity: intensity)
        }
    }

    // MARK: - Geometry

    private func rotated(_ image: CIImage, degrees: Double, cropToContent: Bool) -> CIImage {
        guard degrees != 0 else { return image }
        let radians = -degrees * .pi / 180 // our degrees are clockwise; Core Image rotates counter-clockwise
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: CGFloat(radians))
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        var rotated = image.transformed(by: transform)
        if cropToContent {
            // Largest axis-aligned rectangle with the original aspect that fits inside the rotated image.
            let angle = abs(radians.truncatingRemainder(dividingBy: .pi / 2))
            let w = extent.width, h = extent.height
            let sinA = abs(sin(angle)), cosA = abs(cos(angle))
            let scale = min(w / (w * cosA + h * sinA), h / (w * sinA + h * cosA))
            let cropSize = CGSize(width: w * scale, height: h * scale)
            let cropRect = CGRect(x: rotated.extent.midX - cropSize.width / 2, y: rotated.extent.midY - cropSize.height / 2, width: cropSize.width, height: cropSize.height).integral
            rotated = rotated.cropped(to: cropRect)
        }
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    private func perspective(_ image: CIImage, horizontal: Double, vertical: Double) -> CIImage {
        guard horizontal != 0 || vertical != 0 else { return image }
        let extent = image.extent
        let w = extent.width, h = extent.height
        var tl = CGPoint(x: extent.minX, y: extent.maxY)
        var tr = CGPoint(x: extent.maxX, y: extent.maxY)
        var bl = CGPoint(x: extent.minX, y: extent.minY)
        var br = CGPoint(x: extent.maxX, y: extent.minY)
        let hAmount = CGFloat(horizontal.clamped(to: -1...1)) * h * 0.15
        let vAmount = CGFloat(vertical.clamped(to: -1...1)) * w * 0.15
        if hAmount > 0 { tl.y -= hAmount; bl.y += hAmount } else { tr.y += hAmount; br.y -= hAmount }
        if vAmount > 0 { tl.x += vAmount; tr.x -= vAmount } else { bl.x -= vAmount; br.x += vAmount }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomLeft = bl
        filter.bottomRight = br
        guard let output = filter.outputImage else { return image }
        let cropped = output.cropped(to: output.extent.integral)
        return cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
    }

    // MARK: - Compositing

    private func overlayImage(key: String, make: () -> CIImage?) -> CIImage? {
        if let cached = overlayCache[key] { return cached }
        guard let image = make() else { return nil }
        if overlayCache.count > 32 { overlayCache.removeAll() }
        overlayCache[key] = image
        return image
    }

    private func composite(_ image: CIImage, over canvas: CIImage, layer: Layer, canvasRect: CGRect, isBase: Bool) -> CIImage {
        var placed = image
        if !isBase {
            // Fit inside the canvas, then apply the layer transform (normalised centre, scale, rotation, flips).
            let fit = min(canvasRect.width / max(1, image.extent.width), canvasRect.height / max(1, image.extent.height), 1)
            let scale = fit * layer.transform.scale
            var transform = CGAffineTransform.identity
            let cx = canvasRect.minX + layer.transform.center.x * canvasRect.width
            let cy = canvasRect.minY + (1 - layer.transform.center.y) * canvasRect.height
            transform = transform.translatedBy(x: cx, y: cy)
            transform = transform.rotated(by: CGFloat(-layer.transform.rotation * .pi / 180))
            transform = transform.scaledBy(x: scale * (layer.transform.isFlippedHorizontally ? -1 : 1), y: scale * (layer.transform.isFlippedVertically ? -1 : 1))
            transform = transform.translatedBy(x: -image.extent.midX, y: -image.extent.midY)
            placed = image.transformed(by: transform)
        }
        if let mask = layer.mask, let maskImage = maskStore.load(mask, fitting: placed.extent) {
            placed = AdjustmentPipeline.applyingAlpha(mask: maskImage, to: placed)
        }
        if layer.opacity < 1 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = placed
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity.clamped(to: 0...1)))
            placed = matrix.outputImage ?? placed
        }
        let filter: CIFilter & CICompositeOperation
        switch layer.blendMode {
        case .normal: filter = CIFilter.sourceOverCompositing()
        case .multiply: filter = CIFilter.multiplyBlendMode()
        case .screen: filter = CIFilter.screenBlendMode()
        case .overlay: filter = CIFilter.overlayBlendMode()
        case .softLight: filter = CIFilter.softLightBlendMode()
        case .hardLight: filter = CIFilter.hardLightBlendMode()
        case .darken: filter = CIFilter.darkenBlendMode()
        case .lighten: filter = CIFilter.lightenBlendMode()
        case .difference: filter = CIFilter.differenceBlendMode()
        case .luminosity: filter = CIFilter.luminosityBlendMode()
        case .color: filter = CIFilter.colorBlendMode()
        case .hue: filter = CIFilter.hueBlendMode()
        }
        filter.inputImage = placed
        filter.backgroundImage = canvas
        return (filter.outputImage ?? canvas).cropped(to: canvasRect)
    }
}
#endif
