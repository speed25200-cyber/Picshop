import Foundation
import PicshopCore
import PicshopIntent

/// What the Masques empty state's « Détectés » row offers for a photo (W2).
public struct MaskSuggestions: Sendable, Equatable {
    public var hasSubject: Bool
    /// 0…1: the sky tile shows above 0.3.
    public var skyProbability: Double
    public var personCount: Int
    public var hasFaceParts: Bool
    /// Portrait semantic mattes the asset carries (hair, bodySkin).
    public var mattes: Set<MaskRegion>

    public init(hasSubject: Bool = false, skyProbability: Double = 0, personCount: Int = 0, hasFaceParts: Bool = false, mattes: Set<MaskRegion> = []) {
        self.hasSubject = hasSubject
        self.skyProbability = skyProbability
        self.personCount = personCount
        self.hasFaceParts = hasFaceParts
        self.mattes = mattes
    }

    public static let none = MaskSuggestions()
}

#if canImport(Vision) && canImport(CoreImage)
import Vision
import CoreImage
import CoreGraphics
import ImageIO

// W2 AI masks (D8–D10). Every provider reads the analysis image, which renders without local adjustments (D2),
// and writes an immutable 8-bit raster at that size (1536 px on the longest side) through MaskStore, with unit
// corners and `stateKey` = the base state key, so the mask list can offer « Mettre à jour » when the picture moves.
// A missing model throws `PicshopError.modelUnavailable(<id>)` (the handlers turn it into the download offer); a
// region that is not there throws `objectNotFound`.
extension VisionPhotoServices {
    // MARK: - PhotoAIServices: AI masks

    public func aiMask(_ request: AIMaskRequest, in document: PhotoDocument) async throws -> AIMaskResult {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let signpost = PSSignpost.begin("mask.ai")
        defer { PSSignpost.end(signpost) }
        let image = try await analysisImage(for: document)
        switch request {
        case .subject:
            let bytes = try Detector(image: image, maskStore: maskStore, embedding: nil).subjectMaskBytes()
            return try saved(bytes, image: image, origin: .subject, label: nil, document: document)
        case .background:
            let bytes = try Detector(image: image, maskStore: maskStore, embedding: nil).subjectMaskBytes()
            return try saved(bytes.map { 255 - $0 }, image: image, origin: .background, label: nil, document: document)
        case .people:
            guard let bytes = Detector(image: image, maskStore: maskStore, embedding: nil).personMaskBytes() else { throw PicshopError.objectNotFound("people") }
            return try saved(bytes, image: image, origin: .people, label: nil, document: document)
        case .person(let index):
            return try await personMask(index, image: image, document: document)
        case .personPart(let region, let person):
            return try await personPart(region, person: person, image: image, document: document)
        case .candidates(let list, let target):
            return try await candidatesMask(list, target: target, image: image, document: document)
        case .object(let target):
            return try await objectMask(target, image: image, document: document)
        case .sceneObject(let number):
            guard let map = try await sceneMap(in: document), let object = map.object(id: "o\(number)") else { throw PicshopError.objectNotFound("object") }
            return try await boxMask(object.box, label: object.label, exactPath: nil, image: image, document: document)
        case .box(let rect, let label):
            return try await boxMask(rect.clampedToUnit(), label: label, exactPath: nil, image: image, document: document)
        case .points(let prompts, let label):
            return try await pointsMask(prompts, label: label, image: image, document: document)
        case .sky:
            return try await skyMask(image: image, document: document)
        case .vegetation:
            return try regionMask(.grass, origin: .vegetation, label: "vegetation", image: image, document: document)
        case .water:
            return try regionMask(.water, origin: .water, label: "water", image: image, document: document)
        }
    }

    /// Quick Selection: the region one stroke paints (normalised points, `radius` a fraction of the longest side),
    /// from SAM with the stroke's samples as positive prompts, else from the Lab-wand fallback (approximate). The
    /// caller combines it into the selection: added for a painting stroke, subtracted for an erasing one.
    public func quickSelectRegion(along points: [PSPoint], radius: Double, in document: PhotoDocument) async throws -> AIMaskResult {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let image = try await analysisImage(for: document)
        let aspect = Double(image.width) / Double(max(1, image.height))
        let prompts = SAMPrompting.prompts(along: points, radius: radius, aspect: aspect, erase: false)
        if let bytes = await samMask(image: image, document: document, prompts: prompts, box: nil) {
            return try saved(bytes, image: image, origin: .object, label: nil, document: document, usedModel: true)
        }
        let proxy = Self.sRGBBytes(image)
        let region = QuickSelectFallback.region(rgba: proxy, width: image.width, height: image.height, points: points, radius: radius)
        let edged = Self.guidedEdge(region, width: image.width, height: image.height, guide: image, radius: Self.edgeRadius(image), epsilon: 1e-3, threshold: false)
        return try saved(edged, image: image, origin: .object, label: nil, document: document, usedModel: false, approximate: true)
    }

    // MARK: - Providers

    private func personMask(_ index: Int, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        let people = personInstances(image: image, document: document)
        if index >= 1, index <= people.count {
            return try saved(people[index - 1].bytes, image: image, origin: .person, label: "\(index)", document: document)
        }
        // One person, or the instances request found none: person 1 is everyone (the people mask).
        if index == 1, people.count <= 1, let bytes = Detector(image: image, maskStore: maskStore, embedding: nil).personMaskBytes() {
            return try saved(bytes, image: image, origin: .person, label: "1", document: document)
        }
        throw PicshopError.objectNotFound("person")
    }

    private func personPart(_ region: MaskRegion, person: Int?, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        switch region {
        case .hair, .bodySkin:
            guard let bytes = matte(region, document: document, width: image.width, height: image.height), MaskStore.coverage(of: bytes) > 0.001 else {
                throw PicshopError.objectNotFound(region == .hair ? "hair" : "skin")
            }
            return try saved(bytes, image: image, origin: .matte, label: region.rawValue, document: document)
        case .face, .faceSkin, .eyes, .lips, .teeth:
            let part = region == .faceSkin ? "skin" : region.rawValue
            let parts = try Detector(image: image, maskStore: maskStore, embedding: nil).facePartMasks(part)
            guard !parts.isEmpty else { throw PicshopError.objectNotFound(region == .faceSkin ? "skin" : (region == .face ? "face" : part)) }
            let chosen: [[UInt8]]
            if let person {
                guard person >= 1, person <= parts.count else { throw PicshopError.objectNotFound("face") }
                chosen = [parts[person - 1].bytes]
            } else {
                chosen = parts.map(\.bytes)
            }
            // The landmark polygons, their edge snapped to the picture.
            let edged = Self.guidedEdge(MaskStore.union(chosen), width: image.width, height: image.height, guide: image,
                                        radius: max(2, 0.003 * Double(max(image.width, image.height))), epsilon: 1e-3, threshold: false)
            let label = person.map { "\(region.rawValue):\($0)" } ?? region.rawValue
            return try saved(edged, image: image, origin: .facePart, label: label, document: document)
        default:
            throw PicshopError.objectNotFound(region.rawValue)
        }
    }

    /// The legacy resolution's candidates (D8): exact landmark and instance masks as they are; candidates with only
    /// a box refined by SAM when it is available, else drawn as the legacy path draws them.
    private func candidatesMask(_ list: [ObjectCandidate], target: ObjectTarget, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        guard !list.isEmpty else { throw PicshopError.objectNotFound(target.label) }
        var legacy = list.filter { $0.maskPath != nil }
        var masks: [[UInt8]] = []
        var usedModel = false
        for candidate in list where candidate.maskPath == nil {
            if let bytes = await samMask(image: image, document: document, prompts: [], box: Self.padded(candidate.boundingBox)) {
                masks.append(bytes)
                usedModel = true
            } else {
                legacy.append(candidate)
            }
        }
        if !legacy.isEmpty {
            let reference = try await mask(for: legacy, target: target, in: document)
            masks.append(baked(reference, width: image.width, height: image.height))
        }
        let origin: RasterRef.Origin = Detector.faceParts.contains(target.label) ? .facePart : .object
        return try saved(MaskStore.union(masks), image: image, origin: origin, label: target.label, document: document, usedModel: usedModel)
    }

    /// Vision's grounding (with the attribute boost) → its box → SAM.
    private func objectMask(_ target: ObjectTarget, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        let found = try await candidates(for: target, in: document)
        switch CandidateSelector.select(from: found, for: target) {
        case .single(let candidate):
            return try await boxMask(candidate.boundingBox, label: target.label, exactPath: candidate.maskPath, image: image, document: document)
        case .multiple(let list):
            return try await candidatesMask(list, target: target, image: image, document: document)
        case .ambiguous(let list):
            guard let first = list.first else { throw PicshopError.objectNotFound(target.label) }
            return try await boxMask(first.boundingBox, label: target.label, exactPath: first.maskPath, image: image, document: document)
        case .none:
            throw PicshopError.objectNotFound(target.label)
        }
    }

    /// SAM's box prompt; without SAM, the candidate's own mask or the foreground instances overlapping the box;
    /// with neither, the model offer (never a padded rectangle).
    private func boxMask(_ box: PSRect, label: String?, exactPath: String?, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        guard box.width > 0, box.height > 0 else { throw PicshopError.objectNotFound(label ?? "object") }
        if let bytes = await samMask(image: image, document: document, prompts: [], box: Self.padded(box)) {
            return try saved(bytes, image: image, origin: .object, label: label, document: document, usedModel: true)
        }
        if let exactPath, let bytes = rasterBytes(atPath: exactPath, width: image.width, height: image.height) {
            return try saved(bytes, image: image, origin: .object, label: label, document: document)
        }
        if let bytes = try VisionGrounding.instanceMaskBytes(in: image, overlapping: box, maskStore: maskStore) {
            return try saved(bytes, image: image, origin: .object, label: label, document: document)
        }
        throw PicshopError.modelUnavailable(SAMSegmenter.modelID)
    }

    /// SAM's point prompts; without SAM, the Lab-wand fallback around each point (approximate).
    private func pointsMask(_ prompts: [MaskPrompt], label: String?, image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        guard prompts.contains(where: \.isPositive) else { throw PicshopError.objectNotFound(label ?? "object") }
        if let bytes = await samMask(image: image, document: document, prompts: prompts, box: nil) {
            return try saved(bytes, image: image, origin: .object, label: label, document: document, usedModel: true)
        }
        let rgba = Self.sRGBBytes(image)
        var mask: [UInt8]? = nil
        for prompt in prompts {
            mask = QuickSelectFallback.stroke(rgba: rgba, width: image.width, height: image.height, points: [prompt.point],
                                              radius: Self.fallbackRadius, erase: !prompt.isPositive, base: mask)
        }
        let edged = Self.guidedEdge(mask ?? [], width: image.width, height: image.height, guide: image, radius: Self.edgeRadius(image), epsilon: 1e-3, threshold: false)
        return try saved(edged, image: image, origin: .object, label: label, document: document, usedModel: false, approximate: true)
    }

    /// The sky heuristic (`SkyMask`) on a 640 px proxy with the foreground instances and, when a depth map already
    /// exists for this state, its far 35 %; then the GPU guided edge at 1536 and the softened threshold.
    private func skyMask(image: CGImage, document: PhotoDocument) async throws -> AIMaskResult {
        let proxy = Self.proxy(image, longestSide: SkyMask.workingSide)
        let detector = Detector(image: image, maskStore: maskStore, embedding: nil)
        let fullForeground = foregroundBytes(detector)
        let foreground = fullForeground.map { Self.resampledNearest($0, width: image.width, height: image.height, toWidth: proxy.width, toHeight: proxy.height) }
        let depth = await availableDepth(for: document, width: proxy.width, height: proxy.height)
        let result = SkyMask.estimate(rgba: proxy.rgba, width: proxy.width, height: proxy.height, foreground: foreground, depth: depth, refineEdge: false)
        guard !result.isEmpty else { throw PicshopError.objectNotFound("sky") }
        let full = Self.resized(result.mask, width: proxy.width, height: proxy.height, toWidth: image.width, toHeight: image.height)
        var edged = Self.guidedEdge(full, width: image.width, height: image.height, guide: image, radius: Self.edgeRadius(image), epsilon: 1e-3, threshold: true)
        // The edge may have crept back over a foreground object: the objects stay out at full resolution.
        if let fullForeground { for index in edged.indices where fullForeground[index] > 127 { edged[index] = 0 } }
        guard MaskStore.coverage(of: edged) >= SkyMask.minimumCoverage else { throw PicshopError.objectNotFound("sky") }
        return try saved(edged, image: image, origin: .sky, label: nil, document: document, approximate: result.isApproximate)
    }

    /// Vegetation and water: `RegionMask` on the proxy, minus the foreground instances, with the guided edge.
    private func regionMask(_ kind: RegionMask.Kind, origin: RasterRef.Origin, label: String, image: CGImage, document: PhotoDocument) throws -> AIMaskResult {
        let proxy = Self.proxy(image, longestSide: SkyMask.workingSide)
        let small = RegionMask.mask(kind: kind, rgba: proxy.rgba, width: proxy.width, height: proxy.height)
        guard RegionMask.coverage(small) >= 0.01 else { throw PicshopError.objectNotFound(label) }
        var full = Self.resized(small, width: proxy.width, height: proxy.height, toWidth: image.width, toHeight: image.height)
        let foreground = foregroundBytes(Detector(image: image, maskStore: maskStore, embedding: nil))
        if let foreground { for index in full.indices where foreground[index] > 127 { full[index] = 0 } }
        var edged = Self.guidedEdge(full, width: image.width, height: image.height, guide: image, radius: Self.edgeRadius(image), epsilon: 1e-3, threshold: true)
        if let foreground { for index in edged.indices where foreground[index] > 127 { edged[index] = 0 } }
        guard MaskStore.coverage(of: edged) >= 0.01 else { throw PicshopError.objectNotFound(label) }
        return try saved(edged, image: image, origin: origin, label: nil, document: document, approximate: true)
    }

    // MARK: - Depth (D10)

    public func depthMap(in document: PhotoDocument) async throws -> RasterRef {
        try await depthMap(in: document, priority: .interactive)
    }

    /// The depth map of this state: cached on disk (`masks/depth-<baseStateKey>.png`), else the camera's disparity
    /// when the base has no geometry, else Depth Anything V2 Small on the analysis image.
    func depthMap(in document: PhotoDocument, priority: ModelPriority) async throws -> RasterRef {
        guard Self.masksEnabled else { throw PicshopError.unsupportedOperation("Masks") }
        let key = document.baseStateKey
        if let cached = maskCacheLock.withLock({ Self.lookup(key, in: &depthCache) }), maskStore.exists(cached) { return cached }
        if let existing = maskStore.existingDepth(stateKey: key) {
            maskCacheLock.withLock { Self.store(existing, for: key, in: &depthCache) }
            return existing
        }
        let raster: RasterRef
        if document.baseLayer?.edits.hasGeometry == false, let disparity = await maskRenderer.disparityValues(for: document) {
            raster = try maskStore.saveDepth(values: DepthMath.normalized(disparity.values), width: disparity.width, height: disparity.height, stateKey: key)
        } else {
            guard FeatureFlags.isOn(.depthModel) else { throw PicshopError.modelUnavailable(DepthEstimator.modelID) }
            let image = try await analysisImage(for: document)
            let depth = try await DepthEstimator.shared.estimate(image, priority: priority)
            raster = try maskStore.saveDepth(values: depth.values, width: depth.width, height: depth.height, stateKey: key)
        }
        maskCacheLock.withLock { Self.store(raster, for: key, in: &depthCache) }
        return raster
    }

    /// The depth already available for this state, without running the model, at `width` × `height`.
    func availableDepth(for document: PhotoDocument, width: Int, height: Int) async -> [Float]? {
        let key = document.baseStateKey
        if let raster = maskStore.existingDepth(stateKey: key), let raw = maskStore.loadRaw(raster) {
            let extent = raw.extent.integral
            guard let values = ImageSupport.rawGrayValues(of: raw, rect: extent) else { return nil }
            return DepthMath.resampled(values, width: Int(extent.width), height: Int(extent.height), toWidth: width, toHeight: height)
        }
        guard document.baseLayer?.edits.hasGeometry == false, let disparity = await maskRenderer.disparityValues(for: document) else { return nil }
        return DepthMath.resampled(DepthMath.normalized(disparity.values), width: disparity.width, height: disparity.height, toWidth: width, toHeight: height)
    }

    // MARK: - Visual grounding (D13)

    /// The box (normalised, top-left) of what `phrase` names, from the installed vision-language model
    /// (`VisualGrounding.current`) on a 512 px JPEG of the analysis image, within 6 s; nil without one.
    public func groundBox(_ phrase: String, in document: PhotoDocument) async -> PSRect? {
        guard let grounder = VisualGrounding.current, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let image = try? await analysisImage(for: document),
              let jpeg = LiveMediaEncoder.jpeg(from: image, maxPixel: 512) else { return nil }
        let language = NormalizedUtterance(phrase).language
        let data = jpeg.data
        let box = await Deadline.race(.seconds(6)) { await grounder.box(for: phrase, imageJPEG: data, language: language) }
        guard let clamped = box?.clampedToUnit(), clamped.width > 0.002, clamped.height > 0.002 else { return nil }
        return clamped
    }

    // MARK: - Models ahead of time

    /// Admits (ModelResidency, priority .preload) and loads SAM (and encodes this state), or Depth, off the main actor.
    public func prepareMaskModels(_ clients: Set<ModelClient>, for document: PhotoDocument) async {
        guard Self.masksEnabled else { return }
        if clients.contains(.sam), FeatureFlags.isOn(.samModel) {
            let installed = await SAMSegmenter.shared.isInstalled()
            var image: CGImage?
            if installed { image = try? await analysisImage(for: document) }
            if let image {
                do {
                    try await SAMSegmenter.shared.prepare(image: image, key: samKey(document), priority: .preload)
                } catch {
                    PSLog.info("SAM not prepared: \(error)", category: .imaging)
                }
            }
        }
        if clients.contains(.depth), FeatureFlags.isOn(.depthModel) {
            let installed = await DepthEstimator.shared.isInstalled()
            if installed { _ = try? await depthMap(in: document, priority: .preload) }
        }
    }

    // MARK: - Masques empty state

    /// The Masques empty state's « Détectés » row: people (instances), faces, the subject, the sky and the mattes,
    /// once per base state.
    public func maskSuggestions(in document: PhotoDocument) async -> MaskSuggestions {
        let key = document.baseStateKey
        if let cached = maskCacheLock.withLock({ Self.lookup(key, in: &suggestionCache) }) { return cached }
        guard Self.masksEnabled, let image = try? await analysisImage(for: document) else { return .none }
        let people = personInstances(image: image, document: document)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        let faceCount = faces.results?.count ?? 0
        let detector = Detector(image: image, maskStore: maskStore, embedding: nil)
        let hasForeground = !people.isEmpty || ((try? detector.foregroundInstances())?.allInstances.isEmpty == false)
        let proxy = Self.proxy(image, longestSide: SkyMask.workingSide)
        let sky = SkyMask.estimate(rgba: proxy.rgba, width: proxy.width, height: proxy.height, refineEdge: false)
        let skyProbability = sky.isEmpty ? 0 : sky.confidence * min(1, sky.coverage / 0.08)
        let suggestions = MaskSuggestions(hasSubject: hasForeground, skyProbability: skyProbability, personCount: max(people.count, min(faceCount, 4)),
                                          hasFaceParts: faceCount > 0, mattes: availableMattes(document))
        maskCacheLock.withLock { Self.store(suggestions, for: key, in: &suggestionCache) }
        return suggestions
    }

    /// Up to 4 face thumbnails, left to right (person 1…4), for « Personne… ».
    public func personThumbnails(in document: PhotoDocument, side: Int) async -> [CGImage] {
        guard Self.masksEnabled, side > 0, let image = try? await analysisImage(for: document) else { return [] }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let request = VNDetectFaceRectanglesRequest()
        try? handler.perform([request])
        let faces = (request.results ?? []).map { PSRect.fromVision($0.boundingBox) }.sorted { $0.minX < $1.minX }.prefix(4)
        let width = Double(image.width), height = Double(image.height)
        return faces.compactMap { face in
            // A square around the face with some room, in pixels.
            let span = max(face.width * width, face.height * height) * 1.6
            let rect = CGRect(x: face.midX * width - span / 2, y: face.midY * height - span / 2, width: span, height: span)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isNull, rect.width >= 4, rect.height >= 4, let crop = image.cropping(to: rect) else { return nil }
            return ImageSupport.resized(crop, to: CGSize(width: side, height: side))
        }
    }

    // MARK: - Helpers

    static var masksEnabled: Bool { FeatureFlags.isOn(.masks) || FeatureFlags.isOn(.aiSelection) }

    /// The SAM encoding's key: this project's base state (tonal edits leave it alone, D9).
    func samKey(_ document: PhotoDocument) -> String { "\(projectKey)|\(document.baseStateKey)" }

    /// SAM's mask on the analysis image, nil when SAM is off, not installed or refused (the callers fall back).
    func samMask(image: CGImage, document: PhotoDocument, prompts: [MaskPrompt], box: PSRect?) async -> [UInt8]? {
        guard FeatureFlags.isOn(.samModel), await SAMSegmenter.shared.isInstalled() else { return nil }
        do {
            let output = try await SAMSegmenter.shared.segment(image: image, key: samKey(document), prompts: prompts, box: box)
            return output.width == image.width && output.height == image.height ? output.bytes : nil
        } catch {
            PSLog.info("SAM did not answer, Vision fallback: \(error)", category: .imaging)
            return nil
        }
    }

    /// Saves bytes at the analysis size as this state's raster.
    func saved(_ bytes: [UInt8], image: CGImage, origin: RasterRef.Origin, label: String?, document: PhotoDocument,
               usedModel: Bool = false, approximate: Bool = false) throws -> AIMaskResult {
        let raster = try maskStore.saveRaster(bytes: bytes, width: image.width, height: image.height, origin: origin, label: label,
                                              stateKey: document.baseStateKey)
        return AIMaskResult(raster: raster, coverage: MaskStore.coverage(of: bytes), usedModel: usedModel, isApproximate: approximate)
    }

    /// The people of this state, left to right (cached per base state).
    func personInstances(image: CGImage, document: PhotoDocument) -> [PersonInstances.Instance] {
        let key = document.baseStateKey
        if let cached = maskCacheLock.withLock({ Self.lookup(key, in: &personCache) }) { return cached }
        let people = (try? PersonInstances.instances(in: image)) ?? []
        maskCacheLock.withLock { Self.store(people, for: key, in: &personCache) }
        return people
    }

    /// Every foreground instance at the analysis size (255 = an object), nil when there is none.
    func foregroundBytes(_ detector: Detector) -> [UInt8]? {
        guard let observation = try? detector.foregroundInstances(), !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: detector.handler) else { return nil }
        return MaskStore.bytes(from: buffer, width: detector.width, height: detector.height)
    }

    /// A legacy mask (any size, feathered and inverted as stored) baked into raw bytes at `width` × `height`.
    func baked(_ reference: MaskReference, width: Int, height: Int) -> [UInt8] {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let raw = ImageSupport.rawMaskImage(at: maskStore.url(for: reference)) else { return [UInt8](repeating: 0, count: width * height) }
        var image = MaskComponentImages.placed(raw, corners: RasterRef.unitCorners, extent: rect)
        if reference.isInverted { image = MaskComponentImages.inverted(image) }
        if reference.feather > 0 {
            image = image.clampedToExtent().applyingGaussianBlur(sigma: reference.feather * Double(max(width, height)) * 0.5).cropped(to: rect)
        }
        return ImageSupport.rawGrayBytes(of: image, rect: rect) ?? [UInt8](repeating: 0, count: width * height)
    }

    /// A mask file (8-bit) resampled to `width` × `height` as raw bytes.
    func rasterBytes(atPath path: String, width: Int, height: Int) -> [UInt8]? {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let raw = ImageSupport.rawMaskImage(at: maskStore.store.url(for: path, in: maskStore.projectID)) else { return nil }
        return ImageSupport.rawGrayBytes(of: MaskComponentImages.placed(raw, corners: RasterRef.unitCorners, extent: rect), rect: rect)
    }

    /// The portrait semantic matte (hair or skin) at `width` × `height`, when the asset has one and the base has no
    /// geometry (verify the CIImageOption names on Xcode 26).
    func matte(_ region: MaskRegion, document: PhotoDocument, width: Int, height: Int) -> [UInt8]? {
        guard let base = document.baseLayer, !base.edits.hasGeometry, let asset = base.imageAsset else { return nil }
        let url = maskStore.store.url(for: asset.relativePath, in: maskStore.projectID)
        let option: CIImageOption = region == .hair ? .auxiliarySemanticSegmentationHairMatte : .auxiliarySemanticSegmentationSkinMatte
        guard let matte = CIImage(contentsOf: url, options: [option: true, .applyOrientationProperty: true]) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let atOrigin = matte.transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
        return ImageSupport.rawGrayBytes(of: MaskComponentImages.placed(atOrigin, corners: RasterRef.unitCorners, extent: rect), rect: rect)
    }

    /// The mattes the asset carries (and the base can use: no geometry).
    func availableMattes(_ document: PhotoDocument) -> Set<MaskRegion> {
        guard let base = document.baseLayer, !base.edits.hasGeometry, let asset = base.imageAsset,
              let source = CGImageSourceCreateWithURL(maskStore.store.url(for: asset.relativePath, in: maskStore.projectID) as CFURL, nil) else { return [] }
        var found: Set<MaskRegion> = []
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte) != nil { found.insert(.hair) }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte) != nil { found.insert(.bodySkin) }
        return found
    }

    /// A box grown by 2 % on each side, so SAM sees the object's edge.
    static func padded(_ box: PSRect) -> PSRect {
        box.insetBy(dx: -box.width * 0.02, dy: -box.height * 0.02).clampedToUnit()
    }

    /// The Quick Selection fallback's brush radius for single points (2 % of the longest side).
    static let fallbackRadius = 0.02

    /// The guided edge's radius: 8 px at 1536.
    static func edgeRadius(_ image: CGImage) -> Double {
        8 * Double(max(image.width, image.height)) / 1536
    }

    /// Top-down RGBA8 in gamma sRGB (what Lab and the heuristics read).
    static func sRGBBytes(_ image: CGImage) -> [UInt8] {
        ImageSupport.rgbaBytes(from: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
    }

    /// A ≤ `longestSide` copy's sRGB bytes.
    static func proxy(_ image: CGImage, longestSide: Int) -> (rgba: [UInt8], width: Int, height: Int) {
        let size = PSSize(width: Double(image.width), height: Double(image.height)).limited(toLongestSide: Double(longestSide))
        let small = ImageSupport.resized(image, to: size.cgSize) ?? image
        return (sRGBBytes(small), small.width, small.height)
    }

    /// Bytes resampled bilinearly on the GPU (raw values).
    static func resized(_ bytes: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        guard width > 0, height > 0, let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes, colorSpace: RenderContext.maskColorSpace) else {
            return [UInt8](repeating: 0, count: toWidth * toHeight)
        }
        let rect = CGRect(x: 0, y: 0, width: toWidth, height: toHeight)
        let placed = MaskComponentImages.placed(ImageSupport.rawMaskImage(cg), corners: RasterRef.unitCorners, extent: rect)
        return ImageSupport.rawGrayBytes(of: placed, rect: rect) ?? [UInt8](repeating: 0, count: toWidth * toHeight)
    }

    /// Nearest-neighbour resampling (binary masks).
    static func resampledNearest(_ bytes: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        guard width > 0, height > 0, bytes.count >= width * height else { return [UInt8](repeating: 0, count: toWidth * toHeight) }
        var out = [UInt8](repeating: 0, count: toWidth * toHeight)
        for y in 0..<toHeight {
            let sy = min(height - 1, y * height / max(1, toHeight))
            for x in 0..<toWidth {
                out[y * toWidth + x] = bytes[sy * width + min(width - 1, x * width / max(1, toWidth))]
            }
        }
        return out
    }

    /// The guided-filter edge (GPU) of `bytes` against the picture, optionally re-thresholded at 0.5 ± 0.1.
    static func guidedEdge(_ bytes: [UInt8], width: Int, height: Int, guide: CGImage, radius: Double, epsilon: Double, threshold: Bool) -> [UInt8] {
        guard width > 0, height > 0, bytes.count == width * height,
              let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes, colorSpace: RenderContext.maskColorSpace) else { return bytes }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var refined = EdgeRefine.guided(ImageSupport.rawMaskImage(cg), guide: CIImage(cgImage: guide), radius: radius, epsilon: epsilon)
        if threshold { refined = MaskComponentImages.line(refined, slope: 5, bias: -2) }
        return ImageSupport.rawGrayBytes(of: refined, rect: rect) ?? bytes
    }
}
#endif
