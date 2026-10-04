#if canImport(CoreML) && canImport(Vision) && canImport(CoreImage)
import Foundation
import CoreML
import Vision
import CoreGraphics
import CoreVideo
import PicshopCore

/// Depth Anything V2 Small on the device (W2, D10), for depth-range masks when the photo has no camera disparity.
///
/// - Input `image` 518 × 392 RGB (scaleFill); a portrait picture is turned 90° clockwise first and its depth
///   turned back after (`DepthMath`).
/// - Output `depth` (GRAY_FLOAT16, larger = nearer), normalised between its 1st and 99th percentile to 0 (far) …
///   1 (near).
/// - Transient: the broker admits it (`.interactive`), it loads, infers and unloads at once. Results are cached
///   on disk per picture state by the caller (`masks/depth-<baseStateKey>.png`), so a depth range drawn again never
///   runs the model; and on 6 GB phones (or 8 GB ones with the 4B model loaded) nothing else is safe anyway (D12).
public actor DepthEstimator {
    public static let shared = DepthEstimator()
    public static let modelID = MaskModelCatalog.depthSmall.id

    public typealias Locator = @Sendable (_ package: String) async -> URL?

    public static let installedPackages: Locator = { package in
        await ModelManager.shared.compiledPackageURL(for: DepthEstimator.modelID, package: package)
    }

    private let locate: Locator
    /// Inferences run since the estimator was made (tests).
    public private(set) var inferenceCount = 0

    public init(locate: @escaping Locator = DepthEstimator.installedPackages) {
        self.locate = locate
    }

    private final class UnitsBox: @unchecked Sendable {
        let lock = NSLock()
        var units: MLComputeUnits?
    }

    private static let unitsBox = UnitsBox()

    /// Test-only: forces the compute units (the macOS CI VM has no Neural Engine).
    static var computeUnitsOverride: MLComputeUnits? {
        get { unitsBox.lock.withLock { unitsBox.units } }
        set { unitsBox.lock.withLock { unitsBox.units = newValue } }
    }

    static var computeUnits: MLComputeUnits {
        if let forced = computeUnitsOverride { return forced }
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .cpuAndNeuralEngine
        #endif
    }

    static var package: String { MaskModelCatalog.depthSmall.packages.first ?? "DepthAnythingV2SmallF16" }

    public func isInstalled() async -> Bool {
        await locate(Self.package) != nil
    }

    /// The depth of `image`, 0 far … 1 near, at the model's size (518 × 392, or 392 × 518 for a portrait picture),
    /// row 0 at the top. Throws `modelUnavailable("depth-anything-v2-small")` when the model is not installed or the
    /// broker refuses it.
    public func estimate(_ image: CGImage, priority: ModelPriority = .interactive) async throws -> (values: [Float], width: Int, height: Int) {
        guard let url = await locate(Self.package) else { throw PicshopError.modelUnavailable(Self.modelID) }
        let bytes = ModelBrokerPolicy.estimatedBytes(.depth)
        guard await ModelResidency.admit(.depth, bytes: bytes, priority: priority) else { throw PicshopError.modelUnavailable(Self.modelID) }
        let signpost = PSSignpost.begin("depth.estimate")
        defer { PSSignpost.end(signpost) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            PSLog.error("depth model failed to load: \(error)", category: .models)
            throw PicshopError.modelUnavailable(Self.modelID)
        }
        // Transient: nothing for the broker to evict, so the unload closure has nothing to do.
        await ModelResidency.noteLoaded(.depth, bytes: bytes, unload: {})
        await ModelResidency.markBusy(.depth, true)
        do {
            let result = try infer(model: model, image: image)
            await ModelResidency.markBusy(.depth, false)
            await ModelResidency.noteUnloaded(.depth)
            return result
        } catch {
            await ModelResidency.markBusy(.depth, false)
            await ModelResidency.noteUnloaded(.depth)
            throw error
        }
    }

    /// The same from top-down RGBA8 bytes in sRGB, for callers that hand over plain values (tests).
    func estimate(rgba: [UInt8], width: Int, height: Int) async throws -> (values: [Float], width: Int, height: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: space) else {
            throw PicshopError.renderFailed("depth input")
        }
        return try await estimate(image)
    }

    private func infer(model: MLModel, image: CGImage) throws -> (values: [Float], width: Int, height: Int) {
        let portrait = DepthMath.needsRotation(width: image.width, height: image.height)
        let input = portrait ? (Self.rotatedClockwise(image) ?? image) : image
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw PicshopError.renderFailed("depth input")
        }
        let value = try MLFeatureValue(cgImage: input, constraint: constraint,
                                       options: [MLFeatureValue.ImageOption.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
        inferenceCount += 1
        guard let feature = output.featureValue(for: "depth") else { throw PicshopError.renderFailed("depth output") }
        var plane: (values: [Float], width: Int, height: Int)
        if let buffer = feature.imageBufferValue, let read = Self.values(of: buffer) {
            plane = read
        } else if let array = feature.multiArrayValue {
            let shape = array.shape.map(\.intValue)
            let width = shape.last ?? 0, height = shape.count >= 2 ? shape[shape.count - 2] : 0
            plane = (MLShapedArray<Float>(converting: array).scalars, width, height)
        } else {
            throw PicshopError.renderFailed("depth output type")
        }
        if portrait {
            plane = (DepthMath.rotatedCounterClockwise(plane.values, width: plane.width, height: plane.height), plane.height, plane.width)
        }
        return (DepthMath.normalized(plane.values), plane.width, plane.height)
    }

    /// A one-component pixel buffer's samples (half, float or 8-bit), row 0 at the top.
    static func values(of buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { values[y * width + x] = DepthMath.float(fromHalf: row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) / 255 }
            }
        default:
            return nil
        }
        return (values, width, height)
    }

    /// `image` turned 90° clockwise (its top-left corner lands top-right).
    static func rotatedClockwise(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Graphics is y-up: a clockwise quarter turn is −90°, then up by the new height.
        context.translateBy(x: 0, y: CGFloat(width))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
#endif
