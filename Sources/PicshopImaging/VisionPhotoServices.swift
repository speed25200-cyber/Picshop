#if canImport(Vision) && canImport(CoreImage)
import Foundation
import Vision
import CoreImage
import CoreGraphics
import NaturalLanguage
import PicshopCore
import PicshopIntent

/// Grounds natural-language targets ("the dog on the left", "the power lines",
/// "that guy") in pixels using Apple's on-device Vision models, and produces
/// the masks the editor needs. Implements `PhotoAIServices` for the executor.
///
/// Strategy per target category:
/// - people → `VNDetectHumanRectanglesRequest` + person segmentation, split per instance
/// - faces → `VNDetectFaceRectanglesRequest`
/// - animals → `VNRecognizeAnimalsRequest`
/// - text / logos / watermarks → `VNRecognizeTextRequest`
/// - everything else → foreground instance masks + per-instance `VNClassifyImageRequest`,
///   matched against the vocabulary and, for unknown nouns, word embeddings.
/// - "that" / tap → the instance under the tap point, or salient objects.
public final class VisionPhotoServices: PhotoAIServices, @unchecked Sendable {
    public static let analysisLongestSide = 1536

    private let renderer: PhotoRenderer
    private let store: ProjectStore
    private let projectID: UUID
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    private var analysisCache: (documentHash: Int, image: CGImage)?
    private let cacheLock = NSLock()

    public init(renderer: PhotoRenderer, store: ProjectStore, projectID: UUID) {
        self.renderer = renderer
        self.store = store
        self.projectID = projectID
    }

    private var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    // MARK: - Analysis image

    /// The current edited base image (so removals after a crop line up) at analysis resolution.
    func analysisImage(for document: PhotoDocument) async throws -> CGImage {
        let key = document.baseLayer.map { layer in
            var hasher = Hasher()
            hasher.combine(layer.edits.operations.map(\.id))
            hasher.combine(layer.imageAsset?.relativePath)
            return hasher.finalize()
        } ?? 0
        let cachedImage: CGImage? = cacheLock.withLock {
            if let cached = analysisCache, cached.documentHash == key { return cached.image }
            return nil
        }
        if let cachedImage { return cachedImage }
        let image = try await renderer.renderBase(document, options: PhotoRenderer.Options(targetLongestSide: Double(Self.analysisLongestSide), allowExpensiveWork: true))
        guard let cg = ImageSupport.cgImage(from: image) else { throw PicshopError.renderFailed("analysis image") }
        cacheLock.withLock { analysisCache = (key, cg) }
        return cg
    }

    // MARK: - PhotoAIServices

    public func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        let image = try await analysisImage(for: document)
        return try VisionGrounding.candidates(in: image, for: target, maskStore: maskStore, embedding: embedding)
    }

    public func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
        let image = try await analysisImage(for: document)
        let width = image.width, height = image.height
        var masks: [[UInt8]] = []
        for candidate in candidates {
            if let path = candidate.maskPath, let cg = try? ImageSupport.loadCGImage(at: store.url(for: path, in: projectID)) {
                let resized = ImageSupport.resized(cg, to: CGSize(width: width, height: height)) ?? cg
                masks.append(ImageSupport.grayBytes(from: resized))
            } else {
                masks.append(MaskStore.rectangleMask(candidate.boundingBox.insetBy(dx: -0.01, dy: -0.01).clampedToUnit(), width: width, height: height))
            }
        }
        var union = MaskStore.union(masks)
        // Grow slightly so shadows/halos around the object are covered by the fill.
        let growth = max(2, Int(Double(max(width, height)) * 0.008))
        union = MaskStore.dilated(union, width: width, height: height, radius: growth)
        let box = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }
        let source: MaskSource = .object(label: target.label, boundingBox: box)
        return try maskStore.save(bytes: union, width: width, height: height, source: source, feather: 0.015)
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
        scene.hasText = ((try? detector.text()) ?? []).contains { $0.boundingBox.width * $0.boundingBox.height > 0.004 }
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
    public static func candidates(in image: CGImage, for target: ObjectTarget, maskStore: MaskStore, embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)) throws -> [ObjectCandidate] {
        let timer = PSTimer("ground \(target.label)")
        defer { timer.log(category: .imaging) }
        let detector = Detector(image: image, maskStore: maskStore, embedding: embedding)
        let entry = ObjectVocabulary.entry(forLabel: target.label)
        var candidates: [ObjectCandidate] = []

        switch entry?.category {
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
        case .text:
            candidates = try detector.text()
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

    /// Magic-wand selection saved as a mask reference.
    public static func magicWandMask(in image: CGImage, seed: PSPoint, tolerance: Double, contiguous: Bool, maskStore: MaskStore) throws -> MaskReference {
        let analysis = ImageSupport.resized(image, to: PSSize(width: Double(image.width), height: Double(image.height)).limited(toLongestSide: 1536).cgSize) ?? image
        let bytes = Selection.magicWand(rgba: ImageSupport.rgbaBytes(from: analysis), width: analysis.width, height: analysis.height, seed: (seed.x, seed.y), tolerance: tolerance, contiguous: contiguous)
        let cleaned = Selection.despeckled(bytes, width: analysis.width, height: analysis.height, minimumPixels: max(4, analysis.width * analysis.height / 20000))
        return try maskStore.save(bytes: cleaned, width: analysis.width, height: analysis.height, source: .magicWand(seed, tolerance: tolerance), feather: 0.003)
    }

    /// Lasso polygon saved as a mask reference.
    public static func lassoMask(imageSize: PSSize, points: [PSPoint], maskStore: MaskStore) throws -> MaskReference {
        let size = imageSize.limited(toLongestSide: 1536)
        let bytes = Selection.lasso(points: points.map { ($0.x, $0.y) }, width: Int(size.width), height: Int(size.height))
        return try maskStore.save(bytes: bytes, width: Int(size.width), height: Int(size.height), source: .lasso(points), feather: 0.004)
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

    func text() throws -> [ObjectCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try handler.perform([request])
        return (request.results ?? []).map { observation in
            let box = PSRect.fromVision(observation.boundingBox).insetBy(dx: -0.008, dy: -0.012).clampedToUnit()
            let string = observation.topCandidates(1).first?.string ?? "text"
            return ObjectCandidate(label: string, boundingBox: box, confidence: max(0.5, Double(observation.confidence)))
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
