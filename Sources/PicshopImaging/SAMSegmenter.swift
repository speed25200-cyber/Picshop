#if canImport(CoreML) && canImport(Vision) && canImport(CoreImage)
import Foundation
import CoreML
import Vision
import CoreGraphics
import PicshopCore
import PicshopIntent

/// SAM 2.1 tiny on the device (W2, D9): object by tap, box or Quick Selection stroke.
///
/// - The three pinned packages (image encoder, prompt encoder, mask decoder) load from `ModelManager`'s compiled
///   copies after the broker admits them (`ModelResidency.admit(.sam, …)`), and register so the broker can unload
///   them (`noteLoaded`); predictions are marked busy so they are never evicted mid-run.
/// - The analysis image (1536 px) is stretched to the encoder's 1024 × 1024 (scaleFill). Its outputs
///   (`image_embedding` [1,256,64,64], `feats_s0` [1,32,256,256], `feats_s1` [1,64,128,128]) are kept for the last
///   two picture states (`projectID|baseStateKey`, ≈ 8 MB each), so a second tap encodes nothing.
/// - Prompts (`points` [1,N,2], `labels` [1,N], N ≤ 12) go in as Float32 arrays, as sam2-studio feeds them, with a
///   Float16 retry if Core ML rejects them; the decoder's best mask (`scores`) is upsampled, passed through a sigmoid,
///   despeckled and kept where it touches the prompts (`SAMPrompting`).
/// - Compute units: CPU and Neural Engine on a device, CPU only in the simulator, and whatever a test forces.
public actor SAMSegmenter {
    public static let shared = SAMSegmenter()
    /// The descriptor id of the pinned packages (`ModelManager`, offers, errors).
    public static let modelID = MaskModelCatalog.samTiny.id

    /// Where a compiled package is (`<id>/compiled/<package>.mlmodelc`), nil when it is not installed.
    public typealias Locator = @Sendable (_ package: String) async -> URL?

    /// The installed packages, through `ModelManager.shared`.
    public static let installedPackages: Locator = { package in
        await ModelManager.shared.compiledPackageURL(for: SAMSegmenter.modelID, package: package)
    }

    /// A decoded mask at the analysis size.
    public struct Output: Sendable, Equatable {
        /// 8-bit, row 0 at the top.
        public var bytes: [UInt8]
        public var width: Int
        public var height: Int
        /// The decoder's own score for the mask it chose.
        public var score: Double
    }

    private struct Models {
        let encoder: MLModel
        let prompt: MLModel
        let decoder: MLModel
    }

    private struct Embedding {
        let image: MLMultiArray
        let s0: MLMultiArray
        let s1: MLMultiArray
    }

    private let locate: Locator
    private var models: Models?
    private var loading: Task<Void, Error>?
    private var embeddings: [(key: String, value: Embedding)] = []
    private static let embeddingCapacity = 2
    /// Image encodings run since the segmenter was made (tests: a second prompt on a state encodes nothing).
    public private(set) var encodeCount = 0

    public init(locate: @escaping Locator = SAMSegmenter.installedPackages) {
        self.locate = locate
    }

    // MARK: - Compute units

    private final class UnitsBox: @unchecked Sendable {
        let lock = NSLock()
        var units: MLComputeUnits?
    }

    private static let unitsBox = UnitsBox()

    /// Test-only: forces the compute units (the macOS CI VM has no Neural Engine). Set before the first load.
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

    // MARK: - Availability and loading

    /// The three packages, in the encoder, prompt encoder, decoder order.
    static func packages() -> (encoder: String, prompt: String, decoder: String) {
        let names = MaskModelCatalog.samTiny.packages
        let encoder = names.first { $0.contains("ImageEncoder") } ?? names[0]
        let prompt = names.first { $0.contains("PromptEncoder") } ?? names[min(1, names.count - 1)]
        let decoder = names.first { $0.contains("MaskDecoder") } ?? names[names.count - 1]
        return (encoder, prompt, decoder)
    }

    /// Whether the three packages are installed and compiled.
    public func isInstalled() async -> Bool {
        let names = Self.packages()
        for package in [names.encoder, names.prompt, names.decoder] where await locate(package) == nil { return false }
        return true
    }

    public var isLoaded: Bool { models != nil }

    /// Loads the packages once the broker admits them; concurrent callers wait for the same load. Throws
    /// `modelUnavailable("sam21-tiny")` when they are not installed or the broker refuses.
    public func load(priority: ModelPriority) async throws {
        if models != nil { return }
        if let loading {
            try await loading.value
            return
        }
        let task = Task { try await self.performLoad(priority: priority) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(priority: ModelPriority) async throws {
        let names = Self.packages()
        guard let encoderURL = await locate(names.encoder), let promptURL = await locate(names.prompt), let decoderURL = await locate(names.decoder) else {
            throw PicshopError.modelUnavailable(Self.modelID)
        }
        let bytes = ModelBrokerPolicy.estimatedBytes(.sam)
        guard await ModelResidency.admit(.sam, bytes: bytes, priority: priority) else { throw PicshopError.modelUnavailable(Self.modelID) }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        let signpost = PSSignpost.begin("sam.load")
        let loaded: Models
        do {
            loaded = Models(encoder: try MLModel(contentsOf: encoderURL, configuration: configuration),
                            prompt: try MLModel(contentsOf: promptURL, configuration: configuration),
                            decoder: try MLModel(contentsOf: decoderURL, configuration: configuration))
        } catch {
            PSSignpost.end(signpost)
            PSLog.error("SAM failed to load: \(error)", category: .models)
            throw PicshopError.modelUnavailable(Self.modelID)
        }
        PSSignpost.end(signpost)
        models = loaded
        await ModelResidency.noteLoaded(.sam, bytes: bytes, unload: { [weak self] in await self?.unload() })
    }

    /// Drops the models and the kept encodings: the broker's eviction (for another model, an export, a memory warning
    /// or the background through `releaseIdle`), the app's memory warning and background, the last editor closed.
    public func unload() async {
        guard models != nil else { return }
        models = nil
        embeddings.removeAll()
        await ModelResidency.noteUnloaded(.sam)
    }

    // MARK: - Segmenting

    /// Loads if needed and encodes `image` for `key` ahead of the first tap (the Masques and Sélection tools call
    /// it 300 ms after opening).
    public func prepare(image: CGImage, key: String, priority: ModelPriority = .preload) async throws {
        try await load(priority: priority)
        guard let models else { throw PicshopError.modelUnavailable(Self.modelID) }
        await ModelResidency.markBusy(.sam, true)
        defer { Task { await ModelResidency.markBusy(.sam, false) } }
        _ = try embedding(for: image, key: key, models: models)
    }

    /// The mask SAM gives for `prompts` and `box` (normalised, top-left) on `image` (the analysis image of the state
    /// `key`), at the image's size.
    public func segment(image: CGImage, key: String, prompts: [MaskPrompt], box: PSRect?, priority: ModelPriority = .userWaiting) async throws -> Output {
        let encoded = SAMPrompting.encode(prompts, box: box)
        guard !encoded.isEmpty, encoded.hasPositive else { throw PicshopError.objectNotFound("object") }
        try await load(priority: priority)
        guard let models else { throw PicshopError.modelUnavailable(Self.modelID) }
        let signpost = PSSignpost.begin("sam.segment", "\(encoded.count) prompts")
        await ModelResidency.markBusy(.sam, true)
        defer {
            PSSignpost.end(signpost)
            Task { await ModelResidency.markBusy(.sam, false) }
        }
        let embedding = try embedding(for: image, key: key, models: models)
        let prompt = try promptEmbeddings(encoded, model: models.prompt)
        let inputs: [String: Any] = [
            "image_embedding": embedding.image,
            "sparse_embedding": prompt.sparse,
            "dense_embedding": prompt.dense,
            "feats_s0": embedding.s0,
            "feats_s1": embedding.s1,
        ]
        let output = try models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let masks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            throw PicshopError.renderFailed("SAM decoder output")
        }
        let scoreValues = MLShapedArray<Float>(converting: scores).scalars
        let best = SAMPrompting.bestMask(scores: scoreValues)
        let shape = masks.shape.map(\.intValue)
        let side = shape.last ?? 256
        let maskValues = MLShapedArray<Float>(converting: masks).scalars
        let plane = side * side
        guard maskValues.count >= (best + 1) * plane else { throw PicshopError.renderFailed("SAM mask shape \(shape)") }
        let logits = Array(maskValues[(best * plane)..<((best + 1) * plane)])
        let width = image.width, height = image.height
        let raw = SAMPrompting.maskBytes(fromLogits: logits, side: side, width: width, height: height)
        let cleaned = SAMPrompting.cleaned(raw, width: width, height: height, anchors: SAMPrompting.anchors(prompts, box: box), box: box)
        return Output(bytes: cleaned, width: width, height: height, score: Double(scoreValues.indices.contains(best) ? scoreValues[best] : 0))
    }

    /// The same from top-down RGBA8 bytes in sRGB, for callers that hand over plain values (tests).
    func segment(rgba: [UInt8], width: Int, height: Int, key: String, prompts: [MaskPrompt], box: PSRect?) async throws -> Output {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let image = ImageSupport.rgbaImage(width: width, height: height, bytes: rgba, colorSpace: space) else {
            throw PicshopError.renderFailed("SAM input")
        }
        return try await segment(image: image, key: key, prompts: prompts, box: box)
    }

    // MARK: - Steps

    private func embedding(for image: CGImage, key: String, models: Models) throws -> Embedding {
        if let index = embeddings.firstIndex(where: { $0.key == key }) {
            let entry = embeddings.remove(at: index)
            embeddings.append(entry)
            return entry.value
        }
        guard let constraint = models.encoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw PicshopError.renderFailed("SAM encoder input")
        }
        let signpost = PSSignpost.begin("sam.encode")
        defer { PSSignpost.end(signpost) }
        let value = try MLFeatureValue(cgImage: image, constraint: constraint,
                                       options: [MLFeatureValue.ImageOption.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let output = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
        guard let embedded = output.featureValue(for: "image_embedding")?.multiArrayValue,
              let s0 = output.featureValue(for: "feats_s0")?.multiArrayValue,
              let s1 = output.featureValue(for: "feats_s1")?.multiArrayValue else {
            throw PicshopError.renderFailed("SAM encoder output")
        }
        encodeCount += 1
        let entry = Embedding(image: embedded, s0: s0, s1: s1)
        embeddings.append((key, entry))
        if embeddings.count > Self.embeddingCapacity { embeddings.removeFirst(embeddings.count - Self.embeddingCapacity) }
        return entry
    }

    /// The prompt encoder's embeddings, from Float32 arrays, or Float16 ones if Core ML rejects those.
    private func promptEmbeddings(_ encoded: SAMPrompting.Encoded, model: MLModel) throws -> (sparse: MLMultiArray, dense: MLMultiArray) {
        do {
            return try runPrompt(encoded, model: model, dataType: .float32)
        } catch {
            PSLog.info("SAM prompt encoder rejected Float32 inputs (\(error)); retrying in Float16", category: .models)
            return try runPrompt(encoded, model: model, dataType: .float16)
        }
    }

    private func runPrompt(_ encoded: SAMPrompting.Encoded, model: MLModel, dataType: MLMultiArrayDataType) throws -> (sparse: MLMultiArray, dense: MLMultiArray) {
        let count = encoded.count
        let points = try MLMultiArray(shape: [1, NSNumber(value: count), 2], dataType: dataType)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: dataType)
        for index in 0..<count {
            points[[0, NSNumber(value: index), 0]] = NSNumber(value: encoded.coordinates[index * 2])
            points[[0, NSNumber(value: index), 1]] = NSNumber(value: encoded.coordinates[index * 2 + 1])
            labels[[0, NSNumber(value: index)]] = NSNumber(value: encoded.labels[index])
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels]))
        guard let sparse = output.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = output.featureValue(for: "dense_embeddings")?.multiArrayValue else {
            throw PicshopError.renderFailed("SAM prompt encoder output")
        }
        return (sparse, dense)
    }
}
#endif
