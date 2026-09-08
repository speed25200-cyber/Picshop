// Generative Fill: text-guided synthesis inside a selection, powered by Apple's
// Core ML Stable Diffusion runtime. Compiles only when the ml-stable-diffusion
// package is linked (see project.yml); the resources are downloaded from the
// model server as "sd-generative-fill.zip" (docs/MODELS.md).
#if canImport(StableDiffusion) && canImport(CoreML)
import Foundation
import CoreML
import CoreGraphics
import StableDiffusion
import PicshopCore
import PicshopImaging

/// Masked image-to-image: the crop around the selection is re-imagined from the
/// prompt with a strength that keeps the surrounding composition; the pipeline
/// composites the result back only inside the mask.
public final class StableDiffusionFillEngine: GenerativeFillEngine, @unchecked Sendable {
    public let name = "Stable Diffusion"
    public let preferredLongestSide = 512

    private let resourcesURL: URL
    private let lock = NSLock()
    private var pipeline: StableDiffusionPipeline?

    public init(resourcesURL: URL) {
        self.resourcesURL = resourcesURL
    }

    private func loadedPipeline() throws -> StableDiffusionPipeline {
        lock.lock()
        defer { lock.unlock() }
        if let pipeline { return pipeline }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let pipeline = try StableDiffusionPipeline(resourcesAt: resourcesURL, controlNet: [], configuration: configuration, disableSafety: false, reduceMemory: true)
        try pipeline.loadResources()
        self.pipeline = pipeline
        return pipeline
    }

    public func generate(rgba: [UInt8], mask: [UInt8], width: Int, height: Int, prompt: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [UInt8] {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.generateSync(rgba: rgba, mask: mask, width: width, height: height, prompt: prompt, progress: progress)
        }.value
    }

    /// Pads the crop to a square (edge-extended) so the network never sees a stretched image.
    private func squared(_ image: CGImage) -> (CGImage, CGRect)? {
        let side = max(image.width, image.height)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let origin = CGPoint(x: (side - image.width) / 2, y: (side - image.height) / 2)
        // Edge extension: draw the image stretched to the full square first, then the true image centred.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
        guard let result = context.makeImage() else { return nil }
        return (result, CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
    }

    private func generateSync(rgba: [UInt8], mask: [UInt8], width: Int, height: Int, prompt: String, progress: @escaping @Sendable (Double) -> Void) throws -> [UInt8] {
        let pipeline = try loadedPipeline()
        guard let source = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba),
              let (padded, contentRect) = squared(source),
              let square = ImageSupport.resized(padded, to: CGSize(width: 512, height: 512)) else {
            throw PicshopError.renderFailed("generative input")
        }
        var configuration = StableDiffusionPipeline.Configuration(prompt: prompt)
        configuration.negativePrompt = "blurry, low quality, deformed, watermark, text"
        configuration.startingImage = square
        configuration.strength = 0.82
        configuration.stepCount = 24
        configuration.guidanceScale = 7.5
        configuration.seed = UInt32.random(in: 0...UInt32.max)
        configuration.schedulerType = .dpmSolverMultistepScheduler
        let steps = Double(configuration.stepCount)
        let images = try pipeline.generateImages(configuration: configuration) { state in
            progress(Double(state.step) / steps)
            return !Task.isCancelled
        }
        guard let generated = images.compactMap({ $0 }).first,
              let paddedBack = ImageSupport.resized(generated, to: CGSize(width: padded.width, height: padded.height)),
              let cropped = paddedBack.cropping(to: contentRect),
              let resized = ImageSupport.resized(cropped, to: CGSize(width: width, height: height)) else {
            throw PicshopError.renderFailed("generation produced no image")
        }
        var output = ImageSupport.rgbaBytes(from: resized)
        for i in 0..<(width * height) where mask[i] < 128 {
            output[i * 4] = rgba[i * 4]; output[i * 4 + 1] = rgba[i * 4 + 1]; output[i * 4 + 2] = rgba[i * 4 + 2]; output[i * 4 + 3] = 255
        }
        progress(1)
        return output
    }
}
#endif
