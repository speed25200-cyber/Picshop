#if canImport(CoreML) && canImport(CoreImage)
import Foundation
import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics
import PicshopCore

/// Generic runner for image-in / image-out Core ML models (inpainting,
/// super-resolution). Input/output names and sizes are discovered from the
/// model description so converted models need no code changes.
public final class CoreMLImageModel: @unchecked Sendable {
    public struct ImageInput: Sendable {
        public let name: String
        public let width: Int
        public let height: Int
        public let pixelFormat: OSType
    }

    public let model: MLModel
    public let imageInputs: [ImageInput]
    public let outputName: String
    public let outputIsImage: Bool

    public init(compiledModelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        var inputs: [ImageInput] = []
        for (name, description) in model.modelDescription.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
            if let constraint = description.imageConstraint {
                inputs.append(ImageInput(name: name, width: constraint.pixelsWide, height: constraint.pixelsHigh, pixelFormat: constraint.pixelFormatType))
            } else if let multi = description.multiArrayConstraint, multi.shape.count >= 3 {
                let shape = multi.shape.map { $0.intValue }
                inputs.append(ImageInput(name: name, width: shape[shape.count - 1], height: shape[shape.count - 2], pixelFormat: 0))
            }
        }
        imageInputs = inputs
        guard let output = model.modelDescription.outputDescriptionsByName.first else {
            throw PicshopError.modelUnavailable("model has no outputs")
        }
        outputName = output.key
        outputIsImage = output.value.imageConstraint != nil
    }

    /// Input that carries the colour image (first non-mask input).
    public var colorInput: ImageInput? {
        imageInputs.first { !$0.name.lowercased().contains("mask") } ?? imageInputs.first
    }

    public var maskInput: ImageInput? {
        imageInputs.first { $0.name.lowercased().contains("mask") }
    }

    /// Runs the model on an RGBA8 bitmap (+ optional 8-bit mask) and returns RGBA8 at the model's output size.
    public func predict(rgba: [UInt8], mask: [UInt8]?, width: Int, height: Int) throws -> (rgba: [UInt8], width: Int, height: Int) {
        guard let colorInput else { throw PicshopError.modelUnavailable("model has no image input") }
        var features: [String: MLFeatureValue] = [:]
        guard let source = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba) else { throw PicshopError.renderFailed("input bitmap") }
        let resized = ImageSupport.resized(source, to: CGSize(width: colorInput.width, height: colorInput.height)) ?? source
        features[colorInput.name] = try featureValue(for: resized, input: colorInput, isMask: false)

        if let maskInput {
            let maskBytes = mask ?? [UInt8](repeating: 0, count: width * height)
            guard let maskImage = ImageSupport.grayImage(width: width, height: height, bytes: maskBytes) else { throw PicshopError.renderFailed("mask bitmap") }
            let resizedMask = ImageSupport.resized(maskImage, to: CGSize(width: maskInput.width, height: maskInput.height)) ?? maskImage
            features[maskInput.name] = try featureValue(for: resizedMask, input: maskInput, isMask: true)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output = try model.prediction(from: provider)
        guard let value = output.featureValue(for: outputName) else { throw PicshopError.renderFailed("model output") }
        if let buffer = value.imageBufferValue {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cg = ImageSupport.cgImage(from: image) else { throw PicshopError.renderFailed("model output image") }
            return (ImageSupport.rgbaBytes(from: cg), cg.width, cg.height)
        }
        if let array = value.multiArrayValue {
            return try rgbaBytes(from: array)
        }
        throw PicshopError.renderFailed("unsupported model output")
    }

    private func featureValue(for image: CGImage, input: ImageInput, isMask: Bool) throws -> MLFeatureValue {
        if input.pixelFormat != 0 {
            let buffer = try pixelBuffer(from: image, format: input.pixelFormat, width: input.width, height: input.height)
            return MLFeatureValue(pixelBuffer: buffer)
        }
        // Multi-array input: (1, C, H, W) float32 in 0…1.
        let channels = isMask ? 1 : 3
        let array = try MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: input.height), NSNumber(value: input.width)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: channels * input.width * input.height)
        if isMask {
            let bytes = ImageSupport.grayBytes(from: image)
            for i in 0..<(input.width * input.height) { pointer[i] = Float(bytes[i]) / 255 }
        } else {
            let bytes = ImageSupport.rgbaBytes(from: image)
            let plane = input.width * input.height
            for i in 0..<plane {
                pointer[i] = Float(bytes[i * 4]) / 255
                pointer[plane + i] = Float(bytes[i * 4 + 1]) / 255
                pointer[plane * 2 + i] = Float(bytes[i * 4 + 2]) / 255
            }
        }
        return MLFeatureValue(multiArray: array)
    }

    private func rgbaBytes(from array: MLMultiArray) throws -> (rgba: [UInt8], width: Int, height: Int) {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 3 else { throw PicshopError.renderFailed("model output shape") }
        let width = shape[shape.count - 1]
        let height = shape[shape.count - 2]
        let channels = shape[shape.count - 3]
        let plane = width * height
        var bytes = [UInt8](repeating: 255, count: plane * 4)
        let pointer = array.dataPointer
        func value(_ index: Int) -> Float {
            switch array.dataType {
            case .float32: return pointer.bindMemory(to: Float.self, capacity: plane * channels)[index]
            case .double: return Float(pointer.bindMemory(to: Double.self, capacity: plane * channels)[index])
            case .float16:
                #if arch(arm64)
                let half = pointer.bindMemory(to: UInt16.self, capacity: plane * channels)[index]
                return Float(Float16(bitPattern: half))
                #else
                return 0
                #endif
            default: return 0
            }
        }
        // Detect 0…255 vs 0…1 ranges.
        var maxValue: Float = 0
        for i in stride(from: 0, to: min(plane * channels, 4096), by: 7) { maxValue = max(maxValue, value(i)) }
        let scale: Float = maxValue > 1.5 ? 1 : 255
        for i in 0..<plane {
            for c in 0..<min(3, channels) {
                let v = value(c * plane + i) * scale
                bytes[i * 4 + c] = UInt8(max(0, min(255, v.rounded())))
            }
            if channels == 1 {
                bytes[i * 4 + 1] = bytes[i * 4]
                bytes[i * 4 + 2] = bytes[i * 4]
            }
        }
        return (bytes, width, height)
    }

    private func pixelBuffer(from image: CGImage, format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PicshopError.renderFailed("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let isGray = format == kCVPixelFormatType_OneComponent8
        let space = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = isGray ? CGImageAlphaInfo.none.rawValue
            : format == kCVPixelFormatType_32BGRA ? (CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            : format == kCVPixelFormatType_32ARGB ? CGImageAlphaInfo.premultipliedFirst.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: bitmapInfo) else {
            throw PicshopError.renderFailed("pixel buffer context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

/// Neural inpainter (LaMa) running through `CoreMLImageModel`.
public final class CoreMLInpainter: Inpainter {
    public let name = "LaMa"
    public let preferredLongestSide: Int
    private let model: CoreMLImageModel

    public init(compiledModelURL: URL) throws {
        model = try CoreMLImageModel(compiledModelURL: compiledModelURL)
        preferredLongestSide = model.colorInput.map { max($0.width, $0.height) } ?? 512
    }

    public func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        let model = self.model
        return try await Task.detached(priority: .userInitiated) {
            let result = try model.predict(rgba: rgba, mask: mask, width: width, height: height)
            guard let cg = ImageSupport.rgbaImage(width: result.width, height: result.height, bytes: result.rgba),
                  let resized = ImageSupport.resized(cg, to: CGSize(width: width, height: height)) else {
                throw PicshopError.renderFailed("inpaint resize")
            }
            var output = ImageSupport.rgbaBytes(from: resized)
            // Keep original pixels outside the mask exactly.
            for i in 0..<(width * height) where mask[i] < 128 {
                output[i * 4] = rgba[i * 4]
                output[i * 4 + 1] = rgba[i * 4 + 1]
                output[i * 4 + 2] = rgba[i * 4 + 2]
                output[i * 4 + 3] = rgba[i * 4 + 3]
            }
            return output
        }.value
    }
}

/// Enlarges images. Uses the neural super-resolution model when installed,
/// otherwise Lanczos resampling with edge-aware sharpening.
public struct Upscaler: Sendable {
    public var modelURL: URL?

    public init(modelURL: URL? = nil) {
        self.modelURL = modelURL
    }

    public func upscale(_ image: CIImage, factor: Double) async throws -> CIImage {
        let factor = factor.clamped(to: 1...4)
        if let modelURL, let neural = try? CoreMLImageModel(compiledModelURL: modelURL), let input = neural.colorInput {
            return try await neuralUpscale(image, model: neural, tile: input.width, factor: factor)
        }
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = image
        lanczos.scale = Float(factor)
        lanczos.aspectRatio = 1
        guard let scaled = lanczos.outputImage else { return image }
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = scaled
        sharpen.radius = Float(1.2 * factor)
        sharpen.intensity = 0.45
        return (sharpen.outputImage ?? scaled).cropped(to: scaled.extent.integral)
    }

    /// Tiles the image through a fixed-size super-resolution network.
    private func neuralUpscale(_ image: CIImage, model: CoreMLImageModel, tile: Int, factor: Double) async throws -> CIImage {
        guard let source = ImageSupport.cgImage(from: image) else { return image }
        let width = source.width, height = source.height
        let overlap = 16
        let modelScale: Int = {
            // Probe the model's native scale from the output description when available.
            if let output = model.model.modelDescription.outputDescriptionsByName.first?.value.imageConstraint {
                return max(1, output.pixelsWide / max(1, tile))
            }
            return 4
        }()
        let outWidth = width * modelScale, outHeight = height * modelScale
        var output = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        let bytes = ImageSupport.rgbaBytes(from: source)
        let step = tile - overlap * 2
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let x0 = max(0, min(x - overlap, width - tile))
                let y0 = max(0, min(y - overlap, height - tile))
                let tw = min(tile, width - x0), th = min(tile, height - y0)
                var patch = [UInt8](repeating: 0, count: tile * tile * 4)
                for py in 0..<th {
                    for px in 0..<tw {
                        let si = ((y0 + py) * width + (x0 + px)) * 4
                        let di = (py * tile + px) * 4
                        patch[di] = bytes[si]; patch[di + 1] = bytes[si + 1]; patch[di + 2] = bytes[si + 2]; patch[di + 3] = 255
                    }
                }
                let result = try model.predict(rgba: patch, mask: nil, width: tile, height: tile)
                let scaleX = Double(result.width) / Double(tile)
                for py in 0..<(th * modelScale) {
                    let oy = y0 * modelScale + py
                    guard oy < outHeight else { continue }
                    for px in 0..<(tw * modelScale) {
                        let ox = x0 * modelScale + px
                        guard ox < outWidth else { continue }
                        let sx = min(result.width - 1, Int(Double(px) * scaleX / Double(modelScale)))
                        let sy = min(result.height - 1, Int(Double(py) * scaleX / Double(modelScale)))
                        let si = (sy * result.width + sx) * 4
                        let di = (oy * outWidth + ox) * 4
                        output[di] = result.rgba[si]; output[di + 1] = result.rgba[si + 1]; output[di + 2] = result.rgba[si + 2]; output[di + 3] = 255
                    }
                }
                x += step
            }
            y += step
            try Task.checkCancellation()
        }
        guard let cg = ImageSupport.rgbaImage(width: outWidth, height: outHeight, bytes: output) else { return image }
        var result = CIImage(cgImage: cg)
        let target = factor / Double(modelScale)
        if abs(target - 1) > 0.01 {
            result = result.transformed(by: CGAffineTransform(scaleX: target, y: target))
        }
        return result
    }
}
#endif
