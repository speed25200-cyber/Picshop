import Foundation
import PicshopCore
import PicshopIntent
#if canImport(Vision) && canImport(CoreImage)
import Vision
import CoreImage
import CoreGraphics
import NaturalLanguage

/// Grounds natural-language targets ("the dog on the left", "the power lines",
/// "that guy") in pixels using Apple's on-device Vision models, and produces
/// the masks the editor needs. Implements `PhotoAIServices` for the executor.
///
/// Strategy per target category:
/// - people → `VNDetectHumanRectanglesRequest` + person segmentation, split per instance
/// - faces → `VNDetectFaceRectanglesRequest`
/// - animals → `VNRecognizeAnimalsRequest`
/// - text / logos / watermarks / table data → accurate `VNRecognizeTextRequest`, one box per
///   word, filtered by a `VisionTextQuery` (all text, numbers only, or a literal match); tight
///   masks for data and table text, padded ones for the rest
/// - everything else → foreground instance masks + per-instance `VNClassifyImageRequest`,
///   matched against the vocabulary and, for unknown nouns, word embeddings.
/// - "that" / tap → the instance under the tap point, or salient objects.
public final class VisionPhotoServices: PhotoAIServices, @unchecked Sendable {
    public static let analysisLongestSide = 1536
    /// Text is read at a higher resolution so small table figures are found.
    public static let textAnalysisLongestSide = MaskStore.maximumSide

    private let renderer: PhotoRenderer
    private let store: ProjectStore
    private let projectID: UUID
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    private var analysisCache: [Int: (documentHash: Int, image: CGImage)] = [:]
    private let cacheLock = NSLock()

    public init(renderer: PhotoRenderer, store: ProjectStore, projectID: UUID) {
        self.renderer = renderer
        self.store = store
        self.projectID = projectID
    }

    private var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    // MARK: - Analysis image

    /// The current edited base image (so removals after a crop line up) at analysis resolution.
    func analysisImage(for document: PhotoDocument, longestSide: Int = VisionPhotoServices.analysisLongestSide) async throws -> CGImage {
        let key = document.baseLayer.map { layer in
            var hasher = Hasher()
            hasher.combine(layer.edits.operations.map(\.id))
            hasher.combine(layer.imageAsset?.relativePath)
            return hasher.finalize()
        } ?? 0
        let cachedImage: CGImage? = cacheLock.withLock {
            if let cached = analysisCache[longestSide], cached.documentHash == key { return cached.image }
            return nil
        }
        if let cachedImage { return cachedImage }
        let image = try await renderer.renderBase(document, options: PhotoRenderer.Options(targetLongestSide: Double(longestSide), allowExpensiveWork: true))
        guard let cg = ImageSupport.cgImage(from: image) else { throw PicshopError.renderFailed("analysis image") }
        cacheLock.withLock { analysisCache[longestSide] = (key, cg) }
        return cg
    }

    static func analysisSide(for target: ObjectTarget) -> Int {
        VisionTextQuery.isTextTarget(target) ? textAnalysisLongestSide : analysisLongestSide
    }

    // MARK: - PhotoAIServices

    public func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        let image = try await analysisImage(for: document, longestSide: Self.analysisSide(for: target))
        return try VisionGrounding.candidates(in: image, for: target, maskStore: maskStore, embedding: embedding, mergingText: true)
    }

    /// Text candidates for an explicit query, read at the text resolution. Pass them to
    /// `mask(for:query:in:)` with the same query.
    public func textCandidates(_ query: VisionTextQuery, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        let image = try await analysisImage(for: document, longestSide: Self.textAnalysisLongestSide)
        return try VisionGrounding.textCandidates(in: image, query: query, maskStore: maskStore, merging: true)
    }

    /// The main things in the picture, largest first, each named by the
    /// classifier so the UI can offer them as one-tap erase targets.
    public func namedObjects(in document: PhotoDocument, limit: Int = 6) async throws -> [ObjectCandidate] {
        let image = try await analysisImage(for: document)
        let detector = Detector(image: image, maskStore: maskStore, embedding: embedding)
        let instances = try detector.instanceList().sorted { $0.area > $1.area }.prefix(limit)
        var result: [ObjectCandidate] = []
        for instance in instances where instance.area > 0.004 {
            let crop = detector.croppedImage(masked: instance)
            let top = (try? detector.classify(crop))?.first
            let label = top.map { $0.identifier.lowercased().replacingOccurrences(of: "_", with: " ") } ?? "object"
            let path = try? detector.saveInstanceMask(instance)
            result.append(ObjectCandidate(label: label, boundingBox: instance.box, confidence: 0.5 + min(0.4, instance.area * 2), instanceIndex: instance.index, maskPath: path))
        }
        return result
    }

    public func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
        let query = VisionTextQuery.isTextTarget(target) ? VisionTextQuery(target: target) : nil
        return try await mask(for: candidates, label: target.label, text: query, in: document)
    }

    /// The mask for candidates from `textCandidates(_:in:)`: tight when the query is.
    public func mask(for candidates: [ObjectCandidate], query: VisionTextQuery, in document: PhotoDocument) async throws -> MaskReference {
        try await mask(for: candidates, label: "text", text: query, in: document)
    }

    private func mask(for candidates: [ObjectCandidate], label: String, text: VisionTextQuery?, in document: PhotoDocument) async throws -> MaskReference {
        // Data and table text is already a tight word mask: no growth, a hairline feather, so table rules survive the fill.
        let tight = text?.tight == true
        let image = try await analysisImage(for: document, longestSide: text == nil ? Self.analysisLongestSide : Self.textAnalysisLongestSide)
        let width = image.width, height = image.height
        var masks: [[UInt8]] = []
        for candidate in candidates {
            if let path = candidate.maskPath, let cg = try? ImageSupport.loadCGImage(at: store.url(for: path, in: projectID)) {
                let resized = ImageSupport.resized(cg, to: CGSize(width: width, height: height)) ?? cg
                masks.append(ImageSupport.grayBytes(from: resized))
            } else if tight {
                masks.append(MaskStore.rectanglesMask([candidate.boundingBox], width: width, height: height))
            } else {
                masks.append(MaskStore.rectangleMask(candidate.boundingBox.insetBy(dx: -0.01, dy: -0.01).clampedToUnit(), width: width, height: height))
            }
        }
        var union = MaskStore.union(masks)
        if !tight {
            // Grow slightly so shadows/halos around the object are covered by the fill.
            let growth = max(2, Int(Double(max(width, height)) * 0.008))
            union = MaskStore.dilated(union, width: width, height: height, radius: growth)
        }
        let box = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }
        let source: MaskSource = .object(label: label, boundingBox: box)
        return try maskStore.save(bytes: union, width: width, height: height, source: source, feather: tight ? 0.002 : 0.015)
    }

    public func subjectMask(in document: PhotoDocument) async throws -> MaskReference {
        let image = try await analysisImage(for: document)
        let detector = Detector(image: image, maskStore: maskStore, embedding: embedding)
        let bytes = try detector.subjectMaskBytes()
        return try maskStore.save(bytes: bytes, width: image.width, height: image.height, source: .subject, feather: 0.004)
    }

    public func describe(_ document: PhotoDocument) async throws -> SceneDescription {
        let image = try await analysisImage(for: document)
        let detector = Detector(image: image, maskStore: maskStore, embedding: embedding)
        var scene = SceneDescription()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = true
        let animals = VNRecognizeAnimalsRequest()
        let classify = VNClassifyImageRequest()
        try? handler.perform([humans, animals, classify])
        scene.people = (humans.results ?? []).filter { $0.confidence > 0.5 }.count
        if scene.people == 0 { scene.faces = (try? detector.faces().count) ?? 0 }
        scene.animals = (animals.results ?? []).compactMap { observation in
            observation.labels.max(by: { $0.confidence < $1.confidence }).flatMap { $0.confidence > 0.5 ? $0.identifier.lowercased() : nil }
        }
        let generic: Set<String> = ["structure", "material", "object", "outdoor", "indoor", "adult", "person", "people", "human", "face", "clothing", "furniture", "equipment", "device", "plant"]
        scene.labels = (classify.results ?? [])
            .filter { $0.confidence > 0.35 && !generic.contains($0.identifier.lowercased()) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)
            .map { $0.identifier.lowercased() }
        scene.hasText = detector.containsText()
        // Exposure and colourfulness from a coarse sample.
        let small = ImageSupport.resized(image, to: CGSize(width: 64, height: 64)) ?? image
        let bytes = ImageSupport.rgbaBytes(from: small)
        var luminance = 0.0, saturation = 0.0
        let count = max(1, small.width * small.height)
        for pixel in 0..<count {
            let r = Double(bytes[pixel * 4]) / 255, g = Double(bytes[pixel * 4 + 1]) / 255, b = Double(bytes[pixel * 4 + 2]) / 255
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b), minC = min(r, g, b)
            saturation += maxC > 0 ? (maxC - minC) / maxC : 0
        }
        scene.brightness = luminance / Double(count)
        scene.colourfulness = saturation / Double(count)
        return scene
    }

    public func horizonAngle(in document: PhotoDocument) async throws -> Double? {
        let image = try await analysisImage(for: document)
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return Double(observation.angle) * 180 / .pi
    }

    public func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? {
        let found = try await candidates(for: target, in: document)
        switch CandidateSelector.select(from: found, for: target) {
        case .single(let candidate):
            return padded(candidate.boundingBox, aspect: document.aspectRatio)
        case .multiple(let list):
            return padded(list.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }, aspect: document.aspectRatio)
        case .ambiguous(let list):
            return padded(list.first?.boundingBox ?? .unit, aspect: document.aspectRatio)
        case .none:
            return nil
        }
    }

    public func bestCrop(in document: PhotoDocument) async throws -> PSRect? {
        let image = try await analysisImage(for: document)
        let width = Double(image.width), height = Double(image.height)
        // The subject: the faces together, else the most salient region.
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, saliency])
        var subject: PSRect?
        if let found = faces.results, !found.isEmpty {
            subject = found.map { PSRect.fromVision($0.boundingBox).insetBy(dx: -0.03, dy: -0.06) }.reduce(PSRect.fromVision(found[0].boundingBox)) { $0.union($1) }.clampedToUnit()
        } else if let salient = saliency.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence }) {
            subject = PSRect.fromVision(salient.boundingBox).clampedToUnit()
        }
        if let box = subject, box.width > 0.85 || box.height > 0.85 { subject = nil }
        let candidates = CropCandidates.generate(subject: subject, imageAspect: width / max(1, height))
        // Vision's aesthetics model judges each framing; the whole picture is the one to beat.
        func crop(_ rect: PSRect) -> CGImage? {
            image.cropping(to: CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height).integral)
        }
        let baseline = await AestheticsRanker.scores(for: [image]).first ?? nil
        guard let baseline else { return nil }
        var best: (rect: PSRect, score: Double)?
        for rect in candidates.prefix(30) {
            guard let cropped = crop(rect) else { continue }
            let scored = await AestheticsRanker.scores(for: [cropped]).first ?? nil
            if let score = scored, score > (best?.score ?? -.infinity) { best = (rect, score) }
        }
        guard let best, best.score > baseline + 0.04 else { return nil }
        return best.rect
    }

    private func padded(_ box: PSRect, aspect: Double) -> PSRect {
        var rect = box.insetBy(dx: -box.width * 0.35, dy: -box.height * 0.35)
        // Keep the canvas aspect so the crop doesn't distort the composition.
        let boxAspect = (rect.width * aspect) / max(rect.height, 0.0001)
        if boxAspect > 1 {
            let newHeight = rect.width * aspect
            rect = PSRect(x: rect.minX, y: rect.midY - newHeight / 2, width: rect.width, height: newHeight)
        } else {
            let newWidth = rect.height / aspect
            rect = PSRect(x: rect.midX - newWidth / 2, y: rect.minY, width: newWidth, height: rect.height)
        }
        return rect.clampedToUnit()
    }
}

// MARK: - Grounding entry point

/// Stateless entry point shared by the photo services and the video pipeline.
public enum VisionGrounding {
    /// With `mergingText` (photos), a text query that selects all comes back as one candidate
    /// carrying the union mask. Video tracks each box, so it keeps one candidate per line or word.
    public static func candidates(in image: CGImage, for target: ObjectTarget, maskStore: MaskStore, embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english),
                                  mergingText: Bool = false) throws -> [ObjectCandidate] {
        let timer = PSTimer("ground \(target.label)")
        defer { timer.log(category: .imaging) }
        let detector = Detector(image: image, maskStore: maskStore, embedding: embedding)
        let entry = ObjectVocabulary.entry(forLabel: target.label)
        var candidates: [ObjectCandidate] = []

        switch entry?.category {
        case _ where Detector.faceParts.contains(target.label):
            candidates = try detector.faceParts(target.label)
        case _ where VisionTextQuery.isTextTarget(target):
            candidates = try detector.textCandidates(for: VisionTextQuery(target: target), merging: mergingText)
        case .person:
            if target.label == "face" {
                candidates = try detector.faces()
            } else if target.label == "hand" {
                candidates = try detector.instances(matching: entry, freeText: target.label)
            } else {
                candidates = try detector.people()
            }
        case .animal:
            candidates = try detector.animals(label: target.label)
            if candidates.isEmpty { candidates = try detector.instances(matching: entry, freeText: target.label) }
        case .blemish:
            if let point = target.point {
                candidates = [detector.spot(at: point, label: target.label)]
            }
        case .generic:
            if let point = target.point {
                candidates = try detector.instances(matching: nil, freeText: nil, near: point)
                if candidates.isEmpty { candidates = [detector.spot(at: point, label: "object", radius: 0.05)] }
            } else {
                candidates = try detector.salientObjects()
            }
        case .region:
            candidates = try detector.region(label: target.label)
        default:
            candidates = try detector.instances(matching: entry, freeText: entry == nil ? target.label : nil)
        }

        if !target.attributes.isEmpty {
            candidates = detector.boostByAttributes(candidates, attributes: target.attributes)
        }
        return candidates.sorted { $0.confidence > $1.confidence }
    }

    /// Text candidates for an explicit query (the target's own words are not read): one per
    /// line, word or occurrence, or, with `merging` and a query that selects all, one with
    /// every selected word.
    public static func textCandidates(in image: CGImage, query: VisionTextQuery, maskStore: MaskStore, merging: Bool = false) throws -> [ObjectCandidate] {
        try Detector(image: image, maskStore: maskStore, embedding: nil).textCandidates(for: query, merging: merging)
    }

    /// Magic-wand selection saved as a mask reference.
    public static func magicWandMask(in image: CGImage, seed: PSPoint, tolerance: Double, contiguous: Bool, maskStore: MaskStore) throws -> MaskReference {
        try magicWandSelection(in: wandAnalysis(of: image), seed: seed, tolerance: tolerance, contiguous: contiguous, maskStore: maskStore).reference
    }

    /// The pixels the wand reads: RGBA, at most 1536 px on the longest side. Read once
    /// per picture state and kept, so later taps skip the render and the readback.
    public struct WandAnalysis: Sendable {
        public let rgba: [UInt8]
        public let width: Int
        public let height: Int
    }

    /// A saved selection and its bytes (top-down, 255 = selected), so the canvas
    /// tint is built from memory rather than from the file just written.
    public struct SelectionResult: Sendable {
        public let reference: MaskReference
        public let bytes: [UInt8]
        public let width: Int
        public let height: Int
    }

    public static func wandAnalysis(of image: CGImage) -> WandAnalysis {
        let analysis = ImageSupport.resized(image, to: PSSize(width: Double(image.width), height: Double(image.height)).limited(toLongestSide: 1536).cgSize) ?? image
        return WandAnalysis(rgba: ImageSupport.rgbaBytes(from: analysis), width: analysis.width, height: analysis.height)
    }

    public static func magicWandSelection(in analysis: WandAnalysis, seed: PSPoint, tolerance: Double, contiguous: Bool, maskStore: MaskStore) throws -> SelectionResult {
        let bytes = Selection.magicWand(rgba: analysis.rgba, width: analysis.width, height: analysis.height, seed: (seed.x, seed.y), tolerance: tolerance, contiguous: contiguous)
        let cleaned = Selection.despeckled(bytes, width: analysis.width, height: analysis.height, minimumPixels: max(4, analysis.width * analysis.height / 20000))
        let reference = try maskStore.save(bytes: cleaned, width: analysis.width, height: analysis.height, source: .magicWand(seed, tolerance: tolerance), feather: 0.003)
        return SelectionResult(reference: reference, bytes: cleaned, width: analysis.width, height: analysis.height)
    }

    /// Lasso polygon saved as a mask reference.
    public static func lassoMask(imageSize: PSSize, points: [PSPoint], maskStore: MaskStore) throws -> MaskReference {
        try lassoSelection(imageSize: imageSize, points: points, maskStore: maskStore).reference
    }

    public static func lassoSelection(imageSize: PSSize, points: [PSPoint], maskStore: MaskStore) throws -> SelectionResult {
        let size = imageSize.limited(toLongestSide: 1536)
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let bytes = Selection.lasso(points: points.map { ($0.x, $0.y) }, width: width, height: height)
        let reference = try maskStore.save(bytes: bytes, width: width, height: height, source: .lasso(points), feather: 0.004)
        return SelectionResult(reference: reference, bytes: bytes, width: width, height: height)
    }

    /// Person/subject mask bytes for a frame (video portrait effects).
    public static func subjectMaskBytes(in image: CGImage, maskStore: MaskStore) throws -> [UInt8] {
        try Detector(image: image, maskStore: maskStore, embedding: nil).subjectMaskBytes()
    }

    /// Foreground instance masks overlapping a box (video mask refinement).
    public static func instanceMaskBytes(in image: CGImage, overlapping box: PSRect, maskStore: MaskStore) throws -> [UInt8]? {
        let detector = Detector(image: image, maskStore: maskStore, embedding: nil)
        let instances = try detector.instanceList()
        let matches = instances.filter { $0.box.iou(box) > 0.2 || box.contains($0.box.center) }
        guard !matches.isEmpty else { return nil }
        return MaskStore.union(matches.map(\.bytes))
    }
}

// MARK: - Detector

/// Runs Vision requests against one analysis image and turns results into
/// candidates with saved per-instance masks.
final class Detector {
    let image: CGImage
    let maskStore: MaskStore
    let embedding: NLEmbedding?
    let handler: VNImageRequestHandler
    let width: Int
    let height: Int
    private var instanceObservation: VNInstanceMaskObservation??
    private var personSegmentation: [UInt8]??
    private var recognizedWords: [VisionWord]?

    init(image: CGImage, maskStore: MaskStore, embedding: NLEmbedding?) {
        self.image = image
        self.maskStore = maskStore
        self.embedding = embedding
        handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        width = image.width
        height = image.height
    }

    // MARK: Instances

    func foregroundInstances() throws -> VNInstanceMaskObservation? {
        if let cached = instanceObservation { return cached }
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        let result = request.results?.first
        instanceObservation = .some(result)
        return result
    }

    struct Instance {
        let index: Int
        let bytes: [UInt8]
        let box: PSRect
        let area: Double
    }

    func instanceList() throws -> [Instance] {
        guard let observation = try foregroundInstances() else { return [] }
        var instances: [Instance] = []
        for index in observation.allInstances {
            let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler)
            let bytes = MaskStore.bytes(from: buffer, width: width, height: height)
            let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
            let area = MaskStore.coverage(of: bytes)
            guard area > 0.0005 else { continue }
            instances.append(Instance(index: index, bytes: bytes, box: box, area: area))
        }
        return instances
    }

    /// Person segmentation of the whole image (cached), nil when nobody is in it.
    func personMaskBytes() -> [UInt8]? {
        if let cached = personSegmentation { return cached }
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler.perform([segmentation])
        var result: [UInt8]?
        if let buffer = segmentation.results?.first?.pixelBuffer {
            let bytes = MaskStore.bytes(from: buffer, width: width, height: height)
            if MaskStore.coverage(of: bytes) > 0.005 { result = bytes }
        }
        personSegmentation = .some(result)
        return result
    }

    /// Vision's foreground instances merge an object with the person holding or
    /// touching it (a laptop and the man typing on it). For anything that is not
    /// a person, take the person back out of the instance so "erase the laptop"
    /// never erases the user.
    func withoutPeople(_ instance: Instance, keeping point: PSPoint? = nil) -> Instance {
        guard let person = personMaskBytes() else { return instance }
        var overlap = 0
        var area = 0
        for index in instance.bytes.indices {
            if instance.bytes[index] > 127 {
                area += 1
                if person[index] > 127 { overlap += 1 }
            }
        }
        guard area > 0 else { return instance }
        let ratio = Double(overlap) / Double(area)
        // Nothing to do when the person barely touches the object; the instance IS the person when it is all overlap.
        guard ratio > 0.12, ratio < 0.985 else { return instance }
        let grown = MaskStore.dilated(person, width: width, height: height, radius: max(2, min(width, height) / 150))
        var bytes = instance.bytes
        for index in bytes.indices where grown[index] > 127 { bytes[index] = 0 }
        let remaining = MaskStore.coverage(of: bytes)
        guard remaining > 0.0005 else { return instance }
        if let point {
            let x = min(width - 1, max(0, Int(point.x * Double(width))))
            let y = min(height - 1, max(0, Int(point.y * Double(height))))
            // The tap landed on the person: they asked for the person after all.
            if bytes[y * width + x] < 128 { return instance }
        }
        return Instance(index: instance.index, bytes: bytes, box: MaskStore.boundingBox(of: bytes, width: width, height: height), area: remaining)
    }

    /// Connected components of a mask, largest first, ignoring specks.
    func components(of instance: Instance, minimumArea: Double = 0.0005) -> [Instance] {
        let count = width * height
        var labels = [Int32](repeating: 0, count: count)
        var next: Int32 = 1
        var areas: [Int32: Int] = [:]
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        for start in 0..<count where instance.bytes[start] > 127 && labels[start] == 0 {
            let label = next
            next += 1
            var area = 0
            labels[start] = label
            stack.append(start)
            while let index = stack.popLast() {
                area += 1
                let x = index % width, y = index / width
                if x > 0 { let n = index - 1; if labels[n] == 0, instance.bytes[n] > 127 { labels[n] = label; stack.append(n) } }
                if x < width - 1 { let n = index + 1; if labels[n] == 0, instance.bytes[n] > 127 { labels[n] = label; stack.append(n) } }
                if y > 0 { let n = index - width; if labels[n] == 0, instance.bytes[n] > 127 { labels[n] = label; stack.append(n) } }
                if y < height - 1 { let n = index + width; if labels[n] == 0, instance.bytes[n] > 127 { labels[n] = label; stack.append(n) } }
            }
            areas[label] = area
        }
        let threshold = Int(minimumArea * Double(count))
        let kept = areas.filter { $0.value >= threshold }.sorted { $0.value > $1.value }.prefix(6)
        return kept.map { label, area in
            var bytes = [UInt8](repeating: 0, count: count)
            for index in 0..<count where labels[index] == label { bytes[index] = instance.bytes[index] }
            return Instance(index: instance.index, bytes: bytes, box: MaskStore.boundingBox(of: bytes, width: width, height: height), area: Double(area) / Double(count))
        }
    }

    /// Foreground instances scored against a vocabulary entry (or free text via embeddings).
    ///
    /// Vision merges an object with the person touching it into one instance. For
    /// non-person targets the person is cut out, the remainder is split into
    /// connected pieces and each piece is classified on its own, so "the laptop"
    /// ends up being the laptop and not the desk, the papers or the man behind it.
    func instances(matching entry: ObjectVocabulary.Entry?, freeText: String?, near point: PSPoint? = nil) throws -> [ObjectCandidate] {
        let instances = try instanceList()
        var candidates: [ObjectCandidate] = []
        let excludesPeople = entry?.category != .person
        for original in instances {
            if let point, !original.box.insetBy(dx: -0.03, dy: -0.03).contains(point) { continue }
            let refined = excludesPeople ? withoutPeople(original, keeping: point) : original
            let touchedPerson = refined.area < original.area * 0.999
            let pieces: [Instance] = touchedPerson ? components(of: refined) : [refined]
            var scored: [(instance: Instance, score: Double, label: String)] = []
            for piece in pieces {
                if let point, pieces.count > 1, !piece.box.insetBy(dx: -0.03, dy: -0.03).contains(point) { continue }
                let classifications = try classify(croppedImage(masked: piece))
                var score: Double = point != nil ? 0.9 : 0
                var label = entry?.label ?? (freeText ?? "object")
                if let entry {
                    score = max(score, termScore(classifications, terms: entry.classifierTerms))
                } else if let freeText {
                    let semantic = semanticScore(classifications, phrase: freeText)
                    score = max(score, semantic.score)
                    if semantic.score > 0.3, let best = semantic.identifier { label = freeText.isEmpty ? best : freeText }
                }
                scored.append((piece, score, label))
            }
            var accepted = scored.filter { point != nil || $0.score >= CandidateSelector.minimumConfidence }
            if accepted.isEmpty, touchedPerson, entry != nil, let best = scored.max(by: { $0.score < $1.score }), best.score >= CandidateSelector.minimumConfidence * 0.6 {
                // The pieces are small once the person is gone; keep the most plausible one.
                accepted = [best]
            }
            for item in accepted {
                let path = try saveInstanceMask(item.instance)
                candidates.append(ObjectCandidate(label: item.label, boundingBox: item.instance.box, confidence: min(1, item.score), instanceIndex: item.instance.index, maskPath: path))
            }
        }
        return candidates
    }

    func salientObjects() throws -> [ObjectCandidate] {
        let instances = try instanceList()
        return try instances.map { instance in
            let path = try saveInstanceMask(instance)
            return ObjectCandidate(label: "object", boundingBox: instance.box, confidence: 0.5 + min(0.4, instance.area * 2), instanceIndex: instance.index, maskPath: path)
        }
    }

    // MARK: People / faces / animals / text

    func people() throws -> [ObjectCandidate] {
        let rectangles = VNDetectHumanRectanglesRequest()
        rectangles.upperBodyOnly = false
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([rectangles, segmentation])
        guard let humans = rectangles.results, !humans.isEmpty else { return [] }
        let personMask: [UInt8]? = segmentation.results?.first.map { MaskStore.bytes(from: $0.pixelBuffer, width: width, height: height) }
        let instances = try instanceList()
        var candidates: [ObjectCandidate] = []
        for human in humans {
            let box = PSRect.fromVision(human.boundingBox)
            // Prefer the foreground instance overlapping this person for a clean silhouette,
            // otherwise cut the person-segmentation mask to the rectangle.
            var bytes: [UInt8]
            if let instance = instances.max(by: { $0.box.iou(box) < $1.box.iou(box) }), instance.box.iou(box) > 0.35 {
                bytes = instance.bytes
            } else if let personMask {
                bytes = personMask
                let rectMask = MaskStore.rectangleMask(box.insetBy(dx: -0.02, dy: -0.02).clampedToUnit(), width: width, height: height)
                for i in bytes.indices { bytes[i] = min(bytes[i], rectMask[i]) }
            } else {
                bytes = MaskStore.rectangleMask(box, width: width, height: height)
            }
            let coverage = MaskStore.coverage(of: bytes)
            guard coverage > 0.0003 else { continue }
            let reference = try maskStore.save(bytes: bytes, width: width, height: height, source: .object(label: "person", boundingBox: box), feather: 0.01)
            candidates.append(ObjectCandidate(label: "person", boundingBox: MaskStore.boundingBox(of: bytes, width: width, height: height), confidence: Double(human.confidence), maskPath: reference.relativePath))
        }
        return candidates
    }

    func faces() throws -> [ObjectCandidate] {
        let request = VNDetectFaceRectanglesRequest()
        try handler.perform([request])
        return (request.results ?? []).map { face in
            let box = PSRect.fromVision(face.boundingBox).insetBy(dx: -0.02, dy: -0.04).clampedToUnit()
            return ObjectCandidate(label: "face", boundingBox: box, confidence: Double(face.confidence))
        }
    }

    /// Parts of a face drawn from Vision's landmarks, so a retouch touches only them.
    static let faceParts: Set<String> = ["eyes", "teeth", "lips", "skin"]

    /// One candidate per face: its eyes, the teeth inside the lips, the lips, or
    /// the skin (the face oval without eyes, brows and mouth).
    func faceParts(_ label: String) throws -> [ObjectCandidate] {
        let request = VNDetectFaceLandmarksRequest()
        try handler.perform([request])
        let size = CGSize(width: width, height: height)
        var candidates: [ObjectCandidate] = []
        for face in request.results ?? [] {
            guard let landmarks = face.landmarks else { continue }
            func outline(_ region: VNFaceLandmarkRegion2D?) -> [PSPoint] {
                guard let region else { return [] }
                return region.pointsInImage(imageSize: size).map { PSPoint(x: Double($0.x) / Double(width), y: 1 - Double($0.y) / Double(height)) }
            }
            var include: [[PSPoint]] = []
            var exclude: [[PSPoint]] = []
            switch label {
            case "eyes":
                include = [outline(landmarks.leftEye), outline(landmarks.rightEye)]
            case "teeth":
                include = [outline(landmarks.innerLips)]
            case "lips":
                include = [outline(landmarks.outerLips)]
                exclude = [outline(landmarks.innerLips)]
            default:
                // The face oval, a little taller than Vision's box to take in the forehead.
                let box = PSRect.fromVision(face.boundingBox)
                include = [PolygonRaster.ellipse(center: PSPoint(x: box.midX, y: box.midY - box.height * 0.06), radiusX: box.width * 0.5, radiusY: box.height * 0.6)]
                exclude = [outline(landmarks.leftEye), outline(landmarks.rightEye), outline(landmarks.leftEyebrow), outline(landmarks.rightEyebrow), outline(landmarks.outerLips)]
            }
            include = include.filter { $0.count >= 3 }
            guard !include.isEmpty else { continue }
            var bytes = PolygonRaster.fill(include, width: width, height: height)
            // Landmarks sit on the inner edge of the eyes and the teeth; grow a touch.
            let grow = max(1, Int(Double(max(width, height)) * (label == "skin" ? 0.006 : 0.0025)))
            if label != "skin" { bytes = MaskStore.dilated(bytes, width: width, height: height, radius: grow) }
            let holes = exclude.filter { $0.count >= 3 }
            if !holes.isEmpty {
                // Features cut out generously so the skin retouch never softens an eyelash.
                let cut = MaskStore.dilated(PolygonRaster.fill(holes, width: width, height: height), width: width, height: height, radius: grow)
                for index in bytes.indices where cut[index] > 0 { bytes[index] = 0 }
            }
            guard MaskStore.coverage(of: bytes) > 0.00002 else { continue }
            let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
            let reference = try maskStore.save(bytes: bytes, width: width, height: height, source: .object(label: label, boundingBox: box), feather: label == "skin" ? 0.02 : 0.004)
            candidates.append(ObjectCandidate(label: label, boundingBox: box, confidence: Double(face.confidence), maskPath: reference.relativePath))
        }
        return candidates
    }

    func animals(label: String) throws -> [ObjectCandidate] {
        let request = VNRecognizeAnimalsRequest()
        try handler.perform([request])
        let instances = try instanceList()
        var candidates: [ObjectCandidate] = []
        for observation in request.results ?? [] {
            let identifiers = observation.labels.map { ($0.identifier.lowercased(), Double($0.confidence)) }
            let wanted: Double
            switch label {
            case "dog": wanted = identifiers.first { $0.0 == "dog" }?.1 ?? 0
            case "cat": wanted = identifiers.first { $0.0 == "cat" }?.1 ?? 0
            default: wanted = identifiers.map(\.1).max() ?? 0
            }
            guard wanted > 0.2 else { continue }
            let box = PSRect.fromVision(observation.boundingBox)
            if let instance = instances.max(by: { $0.box.iou(box) < $1.box.iou(box) }), instance.box.iou(box) > 0.3 {
                let path = try saveInstanceMask(instance)
                candidates.append(ObjectCandidate(label: label, boundingBox: instance.box, confidence: wanted, instanceIndex: instance.index, maskPath: path))
            } else {
                candidates.append(ObjectCandidate(label: label, boundingBox: box, confidence: wanted * 0.8))
            }
        }
        return candidates
    }

    /// Recognised words, one box per word: accurate mode, French and English, no language
    /// correction (so "87,3" or "GPT-4o" stay literal) and small text included. Cached.
    func words() throws -> [VisionWord] {
        if let recognizedWords { return recognizedWords }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.006
        try handler.perform([request])
        var words: [VisionWord] = []
        // Top line first, so lines come in reading order.
        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        for (line, observation) in observations.enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            let lineBox = PSRect.fromVision(observation.boundingBox)
            for token in string.split(whereSeparator: { $0.isWhitespace }) {
                // Accurate mode boxes each word; fall back to the line when Vision has no box for it.
                let wordBox = (try? candidate.boundingBox(for: token.startIndex..<token.endIndex)).map { PSRect.fromVision($0.boundingBox) }
                let box = wordBox.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? lineBox
                words.append(VisionWord(text: String(token), box: box, line: line, confidence: Double(candidate.confidence)))
            }
        }
        recognizedWords = words
        return words
    }

    /// Candidates for a text query. A tight query (data, literal words, table text) boxes each
    /// word grown by 15 % of its height, so the rules of a table between cells survive the fill;
    /// other text (watermarks, dates, captions) keeps the padded line box, so its shadow or
    /// outline goes too. With `merging`, a query that selects all gives one candidate carrying
    /// the union mask (nothing to ask); otherwise one per line, word or occurrence.
    func textCandidates(for query: VisionTextQuery, merging: Bool) throws -> [ObjectCandidate] {
        let words = try self.words()
        let groups = query.matches(in: words)
        guard !groups.isEmpty else { return [] }
        func union(_ rects: [PSRect]) -> PSRect { rects.reduce(PSRect.zero) { $0.union($1) } }
        func text(_ group: [Int]) -> String { group.map { words[$0].text }.joined(separator: " ") }
        func holes(_ group: [Int]) -> [PSRect] {
            guard query.tight else { return [union(group.map { words[$0].box }).insetBy(dx: -0.008, dy: -0.012).clampedToUnit()] }
            return group.map { words[$0].maskBox(imageWidth: width, imageHeight: height) }
        }
        if merging, query.selectsAll {
            let selected = groups.flatMap { $0 }
            // Loose holes get the 1 % margin `mask(for:)` gives a candidate without a mask file.
            let rects = groups.flatMap(holes).map { query.tight ? $0 : $0.insetBy(dx: -0.01, dy: -0.01).clampedToUnit() }
            let box = union(rects)
            let bytes = MaskStore.rectanglesMask(rects, width: width, height: height)
            let reference = try maskStore.save(bytes: bytes, width: width, height: height, source: .object(label: "text", boundingBox: box), feather: query.tight ? 0.002 : 0.015)
            return [ObjectCandidate(label: groups.count == 1 ? text(selected) : "text", boundingBox: box, confidence: 0.95, maskPath: reference.relativePath)]
        }
        // No mask files: `mask(for:)` fills each box as is when tight, padded and grown otherwise.
        return groups.map { group in
            let confidence = group.map { words[$0].confidence }.min() ?? 0.5
            return ObjectCandidate(label: text(group), boundingBox: union(holes(group)), confidence: max(0.5, confidence))
        }
    }

    /// Whether the picture holds sizeable text (fast pass, for scene descriptions).
    func containsText() -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? handler.perform([request])
        return (request.results ?? []).contains { observation in
            let box = PSRect.fromVision(observation.boundingBox).insetBy(dx: -0.008, dy: -0.012).clampedToUnit()
            return box.width * box.height > 0.004
        }
    }

    func spot(at point: PSPoint, label: String, radius: Double = 0.025) -> ObjectCandidate {
        let bytes = MaskStore.circleMask(center: point, radius: radius, width: width, height: height)
        let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
        let reference = try? maskStore.save(bytes: bytes, width: width, height: height, source: .point(point), feather: 0.02)
        return ObjectCandidate(label: label, boundingBox: box, confidence: 0.95, maskPath: reference?.relativePath)
    }

    // MARK: Regions

    /// Sky / background / grass / water masks via heuristics and segmentation.
    func region(label: String) throws -> [ObjectCandidate] {
        var bytes: [UInt8]
        switch label {
        case "background":
            let subject = try subjectMaskBytes()
            bytes = subject.map { 255 - $0 }
        case "sky", "grass", "water":
            let small = ImageSupport.resized(image, to: PSSize(width: Double(width), height: Double(height)).limited(toLongestSide: 640).cgSize) ?? image
            let kind: RegionMask.Kind = label == "sky" ? .sky : (label == "grass" ? .grass : .water)
            let smallMask = RegionMask.mask(kind: kind, rgba: ImageSupport.rgbaBytes(from: small), width: small.width, height: small.height)
            guard RegionMask.coverage(smallMask) > 0.01, let cg = ImageSupport.grayImage(width: small.width, height: small.height, bytes: smallMask),
                  let resized = ImageSupport.resized(cg, to: CGSize(width: width, height: height)) else { return [] }
            bytes = ImageSupport.grayBytes(from: resized)
            // Never paint over people/animals inside the region.
            if let observation = try? foregroundInstances(), !observation.allInstances.isEmpty,
               let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                let foreground = MaskStore.bytes(from: buffer, width: width, height: height)
                for i in bytes.indices where foreground[i] > 127 { bytes[i] = 0 }
            }
        default:
            return []
        }
        let coverage = MaskStore.coverage(of: bytes)
        guard coverage > 0.005 else { return [] }
        let reference = try maskStore.save(bytes: bytes, width: width, height: height, source: .region(label), feather: 0.006)
        return [ObjectCandidate(label: label, boundingBox: reference.boundingBox, confidence: min(1, 0.6 + coverage), maskPath: reference.relativePath)]
    }

    // MARK: Subject

    func subjectMaskBytes() throws -> [UInt8] {
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler.perform([segmentation])
        if let buffer = segmentation.results?.first?.pixelBuffer {
            let bytes = MaskStore.bytes(from: buffer, width: width, height: height)
            if MaskStore.coverage(of: bytes) > 0.01 { return bytes }
        }
        if let observation = try foregroundInstances(), !observation.allInstances.isEmpty {
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return MaskStore.bytes(from: buffer, width: width, height: height)
        }
        throw PicshopError.objectNotFound("subject")
    }

    // MARK: Attributes

    func boostByAttributes(_ candidates: [ObjectCandidate], attributes: [String]) -> [ObjectCandidate] {
        let colors = attributes.compactMap { PSColor.named($0) }
        guard !colors.isEmpty else { return candidates }
        let pixels = ImageSupport.rgbaBytes(from: image)
        return candidates.map { candidate in
            var copy = candidate
            let box = candidate.boundingBox.denormalized(in: PSSize(width: Double(width), height: Double(height)))
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            let x0 = max(0, Int(box.minX)), x1 = min(width - 1, Int(box.maxX))
            let y0 = max(0, Int(box.minY)), y1 = min(height - 1, Int(box.maxY))
            guard x1 > x0, y1 > y0 else { return copy }
            let stepX = max(1, (x1 - x0) / 24), stepY = max(1, (y1 - y0) / 24)
            for y in stride(from: y0 + (y1 - y0) / 4, to: y1 - (y1 - y0) / 4, by: stepY) {
                for x in stride(from: x0 + (x1 - x0) / 4, to: x1 - (x1 - x0) / 4, by: stepX) {
                    let i = (y * width + x) * 4
                    r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
                }
            }
            guard n > 0 else { return copy }
            let mean = PSColor(red: r / n / 255, green: g / n / 255, blue: b / n / 255)
            let distance = colors.map { color in
                let dr = color.red - mean.red, dg = color.green - mean.green, db = color.blue - mean.blue
                return (dr * dr + dg * dg + db * db).squareRoot()
            }.min() ?? 1
            copy.confidence = min(1, candidate.confidence * (1.25 - distance * 0.6))
            return copy
        }
    }

    // MARK: Classification helpers

    func croppedImage(masked instance: Instance) -> CGImage {
        let box = instance.box.insetBy(dx: -0.02, dy: -0.02).clampedToUnit().denormalized(in: PSSize(width: Double(width), height: Double(height))).cgRect.integral
        return image.cropping(to: box) ?? image
    }

    func classify(_ crop: CGImage) throws -> [(identifier: String, confidence: Double)] {
        let request = VNClassifyImageRequest()
        let cropHandler = VNImageRequestHandler(cgImage: crop, orientation: .up, options: [:])
        try cropHandler.perform([request])
        return (request.results ?? []).prefix(40).map { ($0.identifier.lowercased(), Double($0.confidence)) }
    }

    func termScore(_ classifications: [(identifier: String, confidence: Double)], terms: [String]) -> Double {
        var best = 0.0
        for (identifier, confidence) in classifications {
            for term in terms {
                if identifier == term { best = max(best, confidence) }
                else if identifier.contains(term) || term.contains(identifier) { best = max(best, confidence * 0.8) }
            }
        }
        // Vision confidences for the right class are often modest; rescale so a clear top-3 hit reads as "confident".
        return min(1, best * 1.6)
    }

    func semanticScore(_ classifications: [(identifier: String, confidence: Double)], phrase: String) -> (score: Double, identifier: String?) {
        let words = phrase.split(separator: " ").map(String.init)
        var best = 0.0
        var bestIdentifier: String?
        for (identifier, confidence) in classifications.prefix(15) {
            let idWords = identifier.replacingOccurrences(of: "_", with: " ").split(separator: " ").map(String.init)
            var similarity = 0.0
            for word in words {
                for idWord in idWords {
                    if word == idWord { similarity = max(similarity, 1) }
                    else if let embedding, embedding.contains(word), embedding.contains(idWord) {
                        let distance = embedding.distance(between: word, and: idWord)
                        similarity = max(similarity, max(0, 1 - distance / 1.2))
                    }
                }
            }
            let score = similarity * (0.4 + confidence)
            if score > best { best = score; bestIdentifier = identifier }
        }
        return (min(1, best), bestIdentifier)
    }

    func saveInstanceMask(_ instance: Instance) throws -> String {
        let reference = try maskStore.save(bytes: instance.bytes, width: width, height: height, source: .object(label: "instance", boundingBox: instance.box), feather: 0.01)
        return reference.relativePath
    }
}
#endif

// MARK: - Text queries (pure Swift, tested on every platform)

/// A word found by text recognition; `box` is normalised with a top-left origin.
public struct VisionWord: Hashable, Sendable {
    public var text: String
    public var box: PSRect
    /// Index of the recognised line the word belongs to, top line first.
    public var line: Int
    public var confidence: Double

    public init(text: String, box: PSRect, line: Int, confidence: Double = 1) {
        self.text = text
        self.box = box
        self.line = line
        self.confidence = confidence
    }

    /// The box grown by `padding` × its height on every side (at least 1.5 px) in an
    /// `imageWidth` × `imageHeight` picture: a hole tight enough to spare nearby table rules.
    public func maskBox(imageWidth: Int, imageHeight: Int, padding: Double = 0.15) -> PSRect {
        let width = Double(max(1, imageWidth)), height = Double(max(1, imageHeight))
        let pixels = max(1.5, padding * box.height * height)
        return box.insetBy(dx: -pixels / width, dy: -pixels / height).clampedToUnit()
    }
}

/// Which recognised words a text target means: all of them, the numbers and data values
/// only, or the words matching a phrase; optionally only those in the picture's main table
/// or inside a region.
public struct VisionTextQuery: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Every word.
        case all
        /// Numbers and data values ("12.3", "1,234", "45%", "70B"), not labels such as "GPT-4o".
        case numeric
        /// Words equal to the phrase, ignoring case, accents and surrounding punctuation.
        case matching(String)
    }

    public var kind: Kind
    /// Normalised, top-left-origin region the words' centres must lie in; nil = anywhere.
    public var region: PSRect?
    /// Every selected word is meant: photos get them as one candidate, so nothing is asked.
    public var selectsAll: Bool
    /// Only the words of the picture's main table (see `tableWords(in:)`), or every word when none is found.
    public var withinTable: Bool

    public init(kind: Kind = .all, region: PSRect? = nil, selectsAll: Bool = false, withinTable: Bool = false) {
        self.kind = kind
        self.region = region
        self.selectsAll = selectsAll
        self.withinTable = withinTable
    }

    /// Holes hug the glyphs (data, literal words, table text) so the rules between cells survive
    /// the fill. Other text (watermarks, dates, captions) is padded and grown like an object, so
    /// its shadow, glow or outline goes too.
    public var tight: Bool { kind != .all || withinTable }
}

public extension VisionTextQuery {
    /// Nouns that ask for the values: "les données", "chiffres", "the numbers".
    static let numericNouns: Set<String> = [
        "donnee", "donnees", "chiffre", "chiffres", "nombre", "nombres", "valeur", "valeurs", "score", "scores", "pourcentage", "pourcentages",
        "numero", "numeros", "resultat", "resultats", "statistique", "statistiques", "stats", "data", "number", "numbers", "digit", "digits",
        "figure", "figures", "value", "values", "percentage", "percentages", "result", "results",
    ]

    /// The plural or collective ones, which mean every value rather than one to pick.
    static let collectiveNumericNouns: Set<String> = [
        "donnees", "chiffres", "nombres", "valeurs", "scores", "pourcentages", "numeros", "resultats", "statistiques", "stats",
        "data", "numbers", "digits", "figures", "values", "percentages", "results",
    ]

    /// Nouns that put the words in a table: "les données du tableau", "the numbers in the grid".
    static let tableNouns: Set<String> = [
        "tableau", "tableaux", "tableur", "grille", "colonne", "colonnes", "cellule", "cellules",
        "table", "tables", "spreadsheet", "grid", "column", "columns", "cell", "cells",
    ]

    /// Whether the target means writing in the picture: the vocabulary's text label, or an
    /// unknown label naming data or a word ("donnees tableau", "mot total").
    static func isTextTarget(_ target: ObjectTarget) -> Bool {
        if let entry = ObjectVocabulary.entry(forLabel: target.label) { return entry.category == .text }
        // "figure" also names a face or a silhouette; only an explicit text target reads it as a number.
        return tokens(of: target.label).contains { (numericNouns.contains($0) && !$0.hasPrefix("figure")) || wordMarkers.contains($0) }
    }

    /// The query a text target's own words ask for: a literal match for quoted text,
    /// "le mot X" / "the word X" or "la valeur 87,3"; the numbers when they name data
    /// ("toutes les données du tableau", "the numbers"); otherwise every word. Plural data
    /// nouns take every number unless a position, an ordinal or a tap narrows them; a
    /// singular one ("le numéro", "the score") and everything else only when the target
    /// says "all". A table noun keeps the words to the table.
    init(target: ObjectTarget) {
        let phrase = Self.tokens(of: target.originalPhrase)
        let words = phrase + Self.tokens(of: target.label)
        let saysAll = target.matchesAll || words.contains { Self.allWords.contains($0) }
        let withinTable = words.contains { Self.tableNouns.contains($0) }
        if let literal = Self.quotedText(in: target.originalPhrase) ?? Self.literal(in: phrase) {
            self.init(kind: .matching(literal), selectsAll: saysAll, withinTable: withinTable)
        } else if words.contains(where: { Self.numericNouns.contains($0) }) {
            let narrowed = target.spatialHint != nil || target.ordinal != nil || target.point != nil
            let collective = words.contains { Self.collectiveNumericNouns.contains($0) }
            self.init(kind: .numeric, selectsAll: saysAll || (collective && !narrowed), withinTable: withinTable)
        } else {
            self.init(kind: .all, selectsAll: saysAll, withinTable: withinTable)
        }
    }

    /// Groups of word indices the query selects, in reading order: one per line for `.all`,
    /// one per word for `.numeric`, one per occurrence for `.matching`.
    func matches(in words: [VisionWord]) -> [[Int]] {
        let table = Self.table(in: words)
        let pool = withinTable ? (table?.words ?? Array(words.indices)) : Array(words.indices)
        let inside = pool.filter { index in region.map { $0.contains(words[index].box.center) } ?? true }
        switch kind {
        case .all:
            var lines: [[Int]] = []
            for index in inside {
                if let last = lines.last?.last, words[last].line == words[index].line {
                    lines[lines.count - 1].append(index)
                } else {
                    lines.append([index])
                }
            }
            return lines
        case .numeric:
            // In a table, a number that is part of a name ("Llama 3.1 70B", "Opus 4.5") or of a
            // column title is not data. Every value means the whole data cells (dashes, notes
            // under the values, superscripts); one to pick is one of the numbers.
            let tableWords = Set(table?.words ?? [])
            let data = selectsAll ? Set(table?.data ?? []) : Self.dataWords(in: words)
            return inside.filter { tableWords.contains($0) ? data.contains($0) : Self.isNumeric(words[$0].text) }.map { [$0] }
        case .matching(let phrase):
            let wanted = phrase.split(whereSeparator: { $0.isWhitespace }).map { Self.folded(String($0)) }.filter { !$0.isEmpty }
            guard !wanted.isEmpty else { return [] }
            let allowed = Set(inside)
            let folded = words.map { Self.folded($0.text) }
            var groups: [[Int]] = []
            var start = 0
            while start + wanted.count <= words.count {
                let span = Array(start..<(start + wanted.count))
                let sameLine = span.allSatisfy { allowed.contains($0) && words[$0].line == words[start].line }
                if sameLine, zip(span, wanted).allSatisfy({ folded[$0.0] == $0.1 }) {
                    groups.append(span)
                    start += wanted.count
                } else {
                    start += 1
                }
            }
            return groups
        }
    }

    /// Numbers and data values: at least as many digits as letters, or a lone percent sign
    /// ("12.3", "1,234", "45%", "−3", "(±0.4)", "70B", "%"); not "GPT-4o", "GSM8K" or "N/A".
    static func isNumeric(_ token: String) -> Bool {
        var digits = 0, letters = 0, percent = false
        for character in token {
            if character.isNumber {
                digits += 1
            } else if character.isLetter {
                letters += 1
            } else if character == "%" || character == "‰" {
                percent = true
            }
        }
        return digits > 0 ? digits >= letters : percent && letters == 0
    }

    /// Words split into cells: runs of words on one recognised line with less than 0.6 of a
    /// word's height between them ("Llama 3.1 70B", "86.1 ± 0.4"). Two words with the same box
    /// (Vision gave the line's box for both) are kept apart, since where a cell ends is unknown.
    static func cells(in words: [VisionWord]) -> [[Int]] {
        let heights = words.map(\.box.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return words.indices.map { [$0] } }
        let gapLimit = 0.6 * heights[heights.count / 2]
        var cells: [[Int]] = []
        for line in Set(words.map(\.line)).sorted() {
            var cell: [Int] = []
            for index in words.indices.filter({ words[$0].line == line }).sorted(by: { words[$0].box.minX < words[$1].box.minX }) {
                if let last = cell.last, words[last].box == words[index].box || words[index].box.minX - words[last].box.maxX > gapLimit {
                    cells.append(cell)
                    cell = []
                }
                cell.append(index)
            }
            if !cell.isEmpty { cells.append(cell) }
        }
        return cells
    }

    /// Words that are data: numbers in a cell holding no word with letters, with the signs
    /// between them ("86.1 ± 0.4"). Not the version or size in a name ("Llama 3.1 70B"),
    /// nor a caption's number ("Table 2: Results").
    static func dataWords(in words: [VisionWord]) -> Set<Int> {
        var data = Set<Int>()
        for cell in cells(in: words) {
            let texts = cell.map { words[$0].text }
            guard texts.contains(where: isNumeric), texts.allSatisfy({ isNumeric($0) || !$0.contains(where: \.isLetter) }) else { continue }
            data.formUnion(cell)
        }
        return data
    }

    /// A cell's words that mark an empty or unavailable value: "—", "–", "-", "n/a".
    static func isPlaceholder(_ token: String) -> Bool {
        let letters = folded(token)
        return letters.isEmpty ? token.contains { "—–-−‒―".contains($0) } : letters == "n/a"
    }

    /// The picture's main table, as ascending word indices: `words` holds everything from the
    /// column titles to the last row (titles, row labels, data cells), `data` only the words of
    /// the data cells: the values with their signs and superscripts, the dashes of empty cells
    /// and the notes under a value ("with tools", "partial").
    struct Table: Hashable, Sendable {
        var words: [Int]
        var data: [Int]
    }

    /// Indices (ascending) of every word of the picture's main table (see `table(in:)`).
    static func tableWords(in words: [VisionWord]) -> [Int]? {
        table(in: words)?.words
    }

    /// The picture's main table, found from its values alone so that row labels of any number
    /// of lines, notes under the values and empty cells never cut it:
    /// - rows are the values (numbers, dashes) sharing a band half a value high;
    /// - a table is a run of such rows whose values line up in columns, each row at most 2.5
    ///   times the usual row spacing below the previous one; the run with the most numbers
    ///   wins, and needs two rows with numbers, so a status bar ("9:41", "87%") or a page
    ///   number is never a table;
    /// - its data columns are the x-clusters of the values, grown to the gutters between them;
    /// - the column titles are the lines in those columns just above the first row (with the
    ///   lines stacked on them), and the table ends under the last row and the lines stacked
    ///   under its values.
    /// Data cells are the cells lying in one data column between the titles and the end: the
    /// titles, the row labels (left of the columns), a caption above and the footnotes below
    /// (they span the columns or are further away) are not.
    static func table(in words: [VisionWord]) -> Table? {
        let cellList = cells(in: words)
        guard !cellList.isEmpty else { return nil }
        let boxes = cellList.map { cell in cell.dropFirst().reduce(words[cell[0]].box) { $0.union(words[$1].box) } }
        let data = dataWords(in: words)
        // Values: numbers in data cells, and the dashes of empty cells (they keep a row of a
        // model without results in the table, but never make a table on their own).
        var values: [(index: Int, cell: Int, number: Bool)] = []
        for (cell, members) in cellList.enumerated() {
            let placeholder = members.allSatisfy { isPlaceholder(words[$0].text) }
            for index in members {
                if data.contains(index), isNumeric(words[index].text) {
                    values.append((index, cell, true))
                } else if placeholder {
                    values.append((index, cell, false))
                }
            }
        }
        let valueHeights = values.filter(\.number).map { words[$0.index].box.height }.filter { $0 > 0 }.sorted()
        guard !valueHeights.isEmpty else { return nil }
        let height = valueHeights[valueHeights.count / 2]

        struct Band {
            var cells: [Int] = []
            var numbers = 0
            var count = 0
            var midY: Double
            var minY: Double
            var maxY: Double
        }
        var bands: [Band] = []
        for value in values.sorted(by: { words[$0.index].box.midY < words[$1.index].box.midY }) {
            let box = words[value.index].box
            if var band = bands.last, abs(box.midY - band.midY) <= height / 2 {
                band.midY = (band.midY * Double(band.count) + box.midY) / Double(band.count + 1)
                band.minY = min(band.minY, box.minY)
                band.maxY = max(band.maxY, box.maxY)
                band.count += 1
                band.numbers += value.number ? 1 : 0
                if !band.cells.contains(value.cell) { band.cells.append(value.cell) }
                bands[bands.count - 1] = band
            } else {
                bands.append(Band(cells: [value.cell], numbers: value.number ? 1 : 0, count: 1, midY: box.midY, minY: box.minY, maxY: box.maxY))
            }
        }
        func aligned(_ cells: [Int], _ others: [Int]) -> Bool {
            cells.contains { cell in others.contains { boxes[cell].minX < boxes[$0].maxX && boxes[$0].minX < boxes[cell].maxX } }
        }
        // The usual row spacing: between consecutive rows sharing a column, leaving out lines
        // stacked in one cell when there are rows further apart. The lower median, so a page
        // number that happens to line up with a column does not stretch it.
        let spacings = zip(bands, bands.dropFirst()).filter { aligned($0.cells, $1.cells) }.map { $1.midY - $0.midY }
        let rowSpacings = spacings.filter { $0 >= 1.5 * height }
        let usable = (rowSpacings.isEmpty ? spacings : rowSpacings).sorted()
        guard !usable.isEmpty else { return nil }
        let pitch = usable[(usable.count - 1) / 2]

        var best: [Int] = [], bestNumbers = 0
        var run: [Int] = [], runCells: [Int] = []
        func finishRun() {
            let numbers = run.reduce(0) { $0 + bands[$1].numbers }
            if run.filter({ bands[$0].numbers > 0 }).count >= 2, numbers > bestNumbers {
                best = run
                bestNumbers = numbers
            }
            run = []
            runCells = []
        }
        for (index, band) in bands.enumerated() {
            if let last = run.last, band.midY - bands[last].midY > 2.5 * pitch || !aligned(band.cells, runCells) {
                finishRun()
            }
            run.append(index)
            runCells += band.cells
        }
        finishRun()
        guard let firstBand = best.first.map({ bands[$0] }), let lastBand = best.last.map({ bands[$0] }) else { return nil }

        // Data columns: the values' x-extents merged where they overlap, grown to the gutters.
        var columns: [(minX: Double, maxX: Double)] = []
        for box in Set(best.flatMap { bands[$0].cells }).map({ boxes[$0] }).sorted(by: { $0.minX < $1.minX }) {
            if let last = columns.last, box.minX < last.maxX {
                columns[columns.count - 1].maxX = max(last.maxX, box.maxX)
            } else {
                columns.append((box.minX, box.maxX))
            }
        }
        let gutters = zip(columns, columns.dropFirst()).map { $1.minX - $0.maxX }.sorted()
        let gutter = gutters.isEmpty ? 2 * height : gutters[gutters.count / 2]
        let zones: [(minX: Double, maxX: Double)] = columns.indices.map { index in
            (index == 0 ? columns[index].minX - gutter / 2 : (columns[index - 1].maxX + columns[index].minX) / 2,
             index == columns.count - 1 ? columns[index].maxX + gutter / 2 : (columns[index].maxX + columns[index + 1].minX) / 2)
        }
        /// A cell centred in a data column and not reaching into the next one: not a row label,
        /// nor a caption or a footnote running across the columns.
        func inColumn(_ cell: Int) -> Bool {
            let box = boxes[cell]
            return zones.contains { box.midX >= $0.minX && box.midX <= $0.maxX && box.minX >= $0.minX - gutter / 2 && box.maxX <= $0.maxX + gutter / 2 }
        }
        let stack = 0.8 * height

        // Column titles: the lines in the columns just above the first row, and those stacked on them.
        let titles = cellList.indices.filter { inColumn($0) && boxes[$0].midY < firstBand.minY && firstBand.minY - boxes[$0].maxY <= pitch }
            .sorted { boxes[$0].maxY > boxes[$1].maxY }
        var titleTop: Double?, titleBottom: Double?
        if let lowest = titles.first {
            var top = boxes[lowest].minY
            for cell in titles where boxes[cell].maxY >= top - stack { top = min(top, boxes[cell].minY) }
            titleTop = top
            titleBottom = boxes[lowest].maxY
        }
        // The end: under the last row, and the lines stacked under it (the notes under its
        // values; for the whole table, its label's last lines too).
        func end(_ include: (Int) -> Bool) -> Double {
            var bottom = lastBand.maxY
            for cell in cellList.indices.sorted(by: { boxes[$0].minY < boxes[$1].minY }) where include(cell) {
                let box = boxes[cell]
                guard box.midY > lastBand.midY, box.midY <= lastBand.midY + pitch / 2, box.minY <= bottom + stack else { continue }
                bottom = max(bottom, box.maxY)
            }
            return bottom
        }
        let dataTop = titleBottom ?? firstBand.minY - height / 2
        let dataBottom = end(inColumn)
        let top = titleTop ?? dataTop
        let bottom = max(dataBottom, end { _ in true })

        let dataCells = cellList.indices.filter { inColumn($0) && boxes[$0].midY > dataTop && boxes[$0].midY <= dataBottom }
        let tableWords = words.indices.filter { words[$0].box.midY >= top && words[$0].box.midY <= bottom }
        return Table(words: tableWords, data: dataCells.flatMap { cellList[$0] }.sorted())
    }
}

extension VisionTextQuery {
    /// Words that introduce the literal text to erase: "le mot Total", "the word Total".
    static let wordMarkers: Set<String> = ["mot", "mots", "word", "words", "terme", "termes", "term", "terms"]
    static let allWords: Set<String> = ["tout", "tous", "toute", "toutes", "all", "every", "everything", "each", "chaque"]
    /// Words around a literal that are not part of it: articles, places, containers, "all".
    static let stopWords: Set<String> = {
        var words = ObjectVocabulary.fillerWords.union(VisionTextQuery.allWords).union(VisionTextQuery.numericNouns).union(VisionTextQuery.wordMarkers)
        words.formUnion(["tableau", "tableaux", "table", "tables", "grille", "grid", "colonne", "colonnes", "column", "columns", "ligne", "lignes",
                         "row", "rows", "cellule", "cellules", "cell", "cells", "case", "cases", "texte", "text", "page", "document", "ecran", "screen",
                         "capture", "screenshot", "et", "ou", "and", "or", "avec", "with", "en", "au", "aux", "a"])
        for hint in SpatialHint.allCases {
            for alias in hint.aliases { words.formUnion(alias.split(separator: " ").map(String.init)) }
        }
        return words
    }()

    /// Lower-cased, accent-free and without surrounding punctuation; a comma between digits
    /// reads as a point ("Été:" → "ete", "87,3" → "87.3", "l’été" → "l'ete").
    static func folded(_ token: String) -> String {
        let characters = Array(token.normalizedForMatching)
        guard let first = characters.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = characters.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        var out = ""
        for index in first...last {
            let character = characters[index]
            let decimalComma = character == "," && characters[index - 1].isNumber && characters[index + 1].isNumber
            out.append(decimalComma ? "." : character)
        }
        return out
    }

    /// Folded words of a phrase, split on spaces and apostrophes ("l'image" → "l", "image").
    static func tokens(of phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0.isWhitespace || $0 == "'" || $0 == "’" }).map { Self.folded(String($0)) }.filter { !$0.isEmpty }
    }

    /// Text between quotes: « Total », "Total", “Total” or ‘Total’.
    static func quotedText(in phrase: String) -> String? {
        let pairs: [(Character, Character)] = [("«", "»"), ("“", "”"), ("\"", "\""), ("‘", "’")]
        for (opening, closing) in pairs {
            guard let start = phrase.firstIndex(of: opening) else { continue }
            let rest = phrase[phrase.index(after: start)...]
            guard let end = rest.firstIndex(of: closing) else { continue }
            let inner = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { return inner }
        }
        return nil
    }

    /// The literal after "mot" / "word" ("le mot total du tableau" → "total"), or the number
    /// right after a data noun ("la valeur 87,3" → "87.3"). `words` are folded.
    static func literal(in words: [String]) -> String? {
        if let index = words.firstIndex(where: { wordMarkers.contains($0) }) {
            let rest = words[(index + 1)...].filter { !stopWords.contains($0) }
            if !rest.isEmpty { return rest.joined(separator: " ") }
        }
        if let index = words.firstIndex(where: { numericNouns.contains($0) }), index + 1 < words.count,
           words[index + 1].contains(where: { $0.isNumber }), isNumeric(words[index + 1]) {
            return words[index + 1]
        }
        return nil
    }
}
