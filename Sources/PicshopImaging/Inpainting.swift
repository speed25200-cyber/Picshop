#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import PicshopCore

/// Fills the masked region of an RGBA8 bitmap with plausible content.
public protocol Inpainter: Sendable {
    var name: String { get }
    /// Preferred working resolution (longest side). The pipeline resamples crops to this.
    var preferredLongestSide: Int { get }
    /// `mask` is 8-bit (255 = fill). Returns RGBA8 of the same size.
    func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8]
}

/// Text-guided synthesis inside a mask (Stable Diffusion or similar).
public protocol GenerativeFillEngine: Sendable {
    var name: String { get }
    var preferredLongestSide: Int { get }
    /// Returns RGBA8 of the same size; pixels outside the mask are replaced by the pipeline anyway.
    func generate(rgba: [UInt8], mask: [UInt8], width: Int, height: Int, prompt: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [UInt8]
}

/// Orchestrates cropping, resampling, running an `Inpainter` and compositing
/// the result back so only the masked pixels change.
public final class InpaintingPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var neural: (any Inpainter)?
    private var generative: (any GenerativeFillEngine)?
    private let fallback: any Inpainter
    private var loading: Task<Void, Never>?

    public init(neural: (any Inpainter)? = nil, fallback: any Inpainter = PatchMatchInpainter()) {
        self.neural = neural
        self.fallback = fallback
    }

    /// Registers the task that loads the engines. A fill or a generation that
    /// arrives while it runs waits for it, so an erase never silently falls back
    /// to the patch-based engine just because the model had not finished loading.
    public func setLoading(_ task: Task<Void, Never>?) {
        lock.lock()
        loading = task
        lock.unlock()
    }

    private func waitForEngines() async {
        let task = lock.withLock { loading }
        await task?.value
    }

    public func setNeural(_ inpainter: (any Inpainter)?) {
        lock.lock()
        neural = inpainter
        lock.unlock()
    }

    public var activeInpainter: any Inpainter {
        lock.lock()
        defer { lock.unlock() }
        return neural ?? fallback
    }

    public func setGenerative(_ engine: (any GenerativeFillEngine)?) {
        lock.lock()
        generative = engine
        lock.unlock()
    }

    public var hasGenerativeEngine: Bool {
        lock.lock()
        defer { lock.unlock() }
        return generative != nil
    }

    /// Text-guided fill. Same crop/composite strategy as `fill`, with the generative engine.
    public func generate(image: CIImage, mask: CIImage, boundingBox: PSRect, prompt: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CIImage {
        await waitForEngines()
        let engine = lock.withLock { generative }
        guard let engine else { throw PicshopError.modelUnavailable("Generative Fill") }
        return try await process(image: image, mask: mask, boundingBox: boundingBox, feather: 0.015, contextMargin: 1.0, workingSide: engine.preferredLongestSide) { rgba, maskBytes, width, height in
            try await engine.generate(rgba: rgba, mask: maskBytes, width: width, height: height, prompt: prompt, progress: progress)
        }
    }

    /// - Parameters:
    ///   - image: the layer image (any extent, bottom-left origin)
    ///   - mask: white where content must be synthesised, same extent as `image`
    ///   - boundingBox: normalised (top-left origin) box of the mask, used to crop work
    public func fill(image: CIImage, mask: CIImage, boundingBox: PSRect, feather: Double) async throws -> CIImage {
        let timer = PSTimer("inpaint")
        defer { timer.log(category: .imaging) }
        await waitForEngines()
        let inpainter = activeInpainter
        return try await process(image: image, mask: mask, boundingBox: boundingBox, feather: feather, contextMargin: 0.75, workingSide: inpainter.preferredLongestSide) { rgba, maskBytes, width, height in
            try await inpainter.inpaint(rgba: rgba, mask: maskBytes, width: width, height: height)
        }
    }

    private func process(image: CIImage, mask: CIImage, boundingBox: PSRect, feather: Double, contextMargin: CGFloat, workingSide: Int,
                         worker: ([UInt8], [UInt8], Int, Int) async throws -> [UInt8]) async throws -> CIImage {
        let extent = image.extent

        // Context crop: the mask box plus generous margin so the filler sees surrounding texture.
        let box = (boundingBox.isEmpty ? PSRect.unit : boundingBox).ciRect(in: extent)
        let margin = max(96, max(box.width, box.height) * contextMargin)
        let crop = box.insetBy(dx: -margin, dy: -margin).intersection(extent).integral
        guard !crop.isEmpty else { return image }

        // Working resolution.
        let longest = max(crop.width, crop.height)
        let workScale = min(1, CGFloat(workingSide) / longest)
        let workWidth = max(32, Int((crop.width * workScale).rounded()))
        let workHeight = max(32, Int((crop.height * workScale).rounded()))
        let workRect = CGRect(x: 0, y: 0, width: workWidth, height: workHeight)

        let context = RenderContext.shared
        let croppedImage = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)).transformed(by: CGAffineTransform(scaleX: workScale, y: workScale))
        let croppedMask = mask.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)).transformed(by: CGAffineTransform(scaleX: workScale, y: workScale))

        var rgba = [UInt8](repeating: 0, count: workWidth * workHeight * 4)
        rgba.withUnsafeMutableBytes { buffer in
            context.render(croppedImage, toBitmap: buffer.baseAddress!, rowBytes: workWidth * 4, bounds: workRect, format: .RGBA8, colorSpace: RenderContext.colorSpace)
        }
        var maskBytes = [UInt8](repeating: 0, count: workWidth * workHeight)
        maskBytes.withUnsafeMutableBytes { buffer in
            context.render(croppedMask, toBitmap: buffer.baseAddress!, rowBytes: workWidth, bounds: workRect, format: .R8, colorSpace: nil)
        }
        if !RenderContext.bitmapIsTopDown {
            rgba = MaskStore.flippedVertically(rgba, width: workWidth * 4, height: workHeight)
            maskBytes = MaskStore.flippedVertically(maskBytes, width: workWidth, height: workHeight)
        }
        // Harden and slightly grow the hole so anti-aliased edges are fully replaced.
        for index in maskBytes.indices { maskBytes[index] = maskBytes[index] > 100 ? 255 : 0 }
        maskBytes = MaskStore.dilated(maskBytes, width: workWidth, height: workHeight, radius: max(1, workWidth / 200))
        guard maskBytes.contains(where: { $0 > 0 }) else { return image }

        let filledBytes = try await worker(rgba, maskBytes, workWidth, workHeight)
        guard let filledCG = ImageSupport.rgbaImage(width: workWidth, height: workHeight, bytes: filledBytes) else {
            throw PicshopError.renderFailed("inpaint output")
        }
        var filled = CIImage(cgImage: filledCG)
        if !RenderContext.bitmapIsTopDown {
            filled = filled.transformed(by: CGAffineTransform(scaleX: 1, y: -1)).transformed(by: CGAffineTransform(translationX: 0, y: filled.extent.height))
        }
        // Back to crop resolution and position.
        let upscale = 1 / workScale
        if upscale > 1.001 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = filled
            lanczos.scale = Float(upscale)
            lanczos.aspectRatio = 1
            filled = lanczos.outputImage ?? filled.transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
        }
        filled = filled.transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY)).cropped(to: crop)

        // Composite at full resolution: the synthesised pixels replace the hole (grown by the
        // same amount the worker saw), everything else stays the untouched original. The seam is
        // anti-aliased by a sub-3px blur only — wide feathers would blend a resampled copy of the
        // surroundings back over sharp edges and read as a smear.
        let growPixels = max(2, CGFloat(max(1, workWidth / 200)) / workScale)
        let hardMask = CIFilter.colorThreshold()
        hardMask.inputImage = mask.cropped(to: crop)
        hardMask.threshold = 0.4
        let grown = CIFilter.morphologyMaximum()
        grown.inputImage = hardMask.outputImage?.clampedToExtent() ?? mask.cropped(to: crop)
        grown.radius = Float(growPixels)
        let seam = min(2.5, max(0.8, feather * max(extent.width, extent.height) * 0.05))
        let blendMask = (grown.outputImage ?? mask).cropped(to: crop).clampedToExtent().applyingGaussianBlur(sigma: seam).cropped(to: crop)
        let blended = AdjustmentPipeline.blendWithMask(foreground: filled, background: image.cropped(to: crop), mask: blendMask)
        return blended.composited(over: image).cropped(to: extent)
    }
}

/// Exemplar-based inpainting (PatchMatch nearest-neighbour field with
/// coarse-to-fine reconstruction). Runs entirely on the CPU, needs no model
/// download, and produces convincing fills for backgrounds with texture or
/// structure. It is the always-available fallback behind the neural inpainter.
public struct PatchMatchInpainter: Inpainter {
    public let name = "PatchMatch"
    public let preferredLongestSide: Int
    public let patchRadius: Int
    public let iterationsPerLevel: [Int]

    public init(preferredLongestSide: Int = 1024, patchRadius: Int = 3, iterationsPerLevel: [Int] = [6, 5, 4, 3, 3, 2, 2]) {
        self.preferredLongestSide = preferredLongestSide
        self.patchRadius = patchRadius
        self.iterationsPerLevel = iterationsPerLevel
    }

    public func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        let radius = patchRadius
        let iterations = iterationsPerLevel
        return await Task.detached(priority: .userInitiated) {
            PatchMatchCore.inpaint(rgba: rgba, mask: mask, width: width, height: height, patchRadius: radius, iterationsPerLevel: iterations)
        }.value
    }
}

#endif
