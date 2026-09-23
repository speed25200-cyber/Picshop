#if canImport(CoreImage)
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import PicshopCore
#if os(iOS)
import os
#endif

/// How much memory the process may still use before the system reclaims it.
public enum MemoryBudget {
    /// Below this, heavy jobs purge caches first and work a step smaller.
    public static let lowThreshold = 700 * 1_048_576

    /// Bytes still available to the app; nil where the system does not say (macOS).
    public static var availableBytes: Int? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? Int(available) : nil
        #else
        return nil
        #endif
    }

    public static var isLow: Bool { availableBytes.map { $0 < lowThreshold } ?? false }

    /// "812 MB", or "?" where unknown.
    public static var availableDescription: String {
        availableBytes.map { "\($0 / 1_048_576) MB" } ?? "?"
    }
}

/// Where the imaging layer reports its heavy steps (erase, upscale…) for the
/// crash breadcrumbs kept by the app. Thread-safe.
public enum ImagingBreadcrumbs {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (String) -> Void)?
    }

    private static let box = Box()

    public static func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        box.lock.lock()
        box.handler = handler
        box.lock.unlock()
    }

    public static func note(_ message: String) {
        box.lock.lock()
        let handler = box.handler
        box.lock.unlock()
        handler?(message)
    }
}

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
        /// The picture on screen: the expensive results it uses survive memory trimming.
        public var isDisplayed: Bool

        public init(targetLongestSide: Double? = nil, showOriginal: Bool = false, includeOverlays: Bool = true, allowExpensiveWork: Bool = true, isDisplayed: Bool = false) {
            self.targetLongestSide = targetLongestSide
            self.showOriginal = showOriginal
            self.includeOverlays = includeOverlays
            self.allowExpensiveWork = allowExpensiveWork
            self.isDisplayed = isDisplayed
        }

        public static let preview = Options(targetLongestSide: 2048, isDisplayed: true)
        public static let thumbnail = Options(targetLongestSide: 512, includeOverlays: true, allowExpensiveWork: false)
        public static let full = Options()
    }

    private let store: ProjectStore
    private let projectID: UUID
    private let inpainting: InpaintingPipeline
    private let upscaler: Upscaler
    private var sourceCache: [String: CIImage] = [:]
    private var operationCache: [String: CIImage] = [:]
    /// Least recently used first: a hit moves its key to the end.
    private var operationOrder: [String] = []
    /// Keys the last settled on-screen render used: never trimmed, so a memory
    /// warning does not make the open photo redo its erases.
    private var displayedKeys: Set<String> = []
    private var displayGeneration = 0
    private var overlayCache: [String: CIImage] = [:]
    /// Results of the expensive operations (erase, generate, upscale, denoise)
    /// are worth keeping so undo and a panel change do not re-run a neural
    /// model, but not forever: unbounded, a long session grew until the system
    /// started reclaiming memory, and everything stuttered. Least recently used out first.
    private static let operationCacheLimit = 24
    /// Expensive results being computed, keyed like `operationCache`: a second render of
    /// the same step (compare, a panel, the analysis image) awaits the running job instead
    /// of starting another PatchMatch or neural pass.
    private var inFlight: [String: Task<CIImage, Error>] = [:]
    /// Renders currently awaiting each job; the job is cancelled when the last one leaves.
    private var inFlightWaiters: [String: Set<UUID>] = [:]

    public init(store: ProjectStore, projectID: UUID, inpainting: InpaintingPipeline, upscaler: Upscaler = Upscaler()) {
        self.store = store
        self.projectID = projectID
        self.inpainting = inpainting
        self.upscaler = upscaler
    }

    public var maskStore: MaskStore { MaskStore(store: store, projectID: projectID) }

    /// Cache keys one render read or produced.
    private final class KeyLog {
        var keys: Set<String> = []
    }

    private func cacheOperation(_ image: CIImage, for key: String) {
        operationCache[key] = image
        touch(key)
        evict(downTo: Self.operationCacheLimit) { _ in false }
    }

    /// Marks a cached result as just used.
    private func touch(_ key: String) {
        if let index = operationOrder.lastIndex(of: key) { operationOrder.remove(at: index) }
        operationOrder.append(key)
    }

    /// Drops least recently used results until `limit` remain, those matching
    /// `preferring` first; what is on screen stays.
    private func evict(downTo limit: Int, preferring first: (String) -> Bool) {
        let candidates = operationOrder.filter { !displayedKeys.contains($0) }
        let ranked = candidates.filter(first) + candidates.filter { !first($0) }
        var excess = operationOrder.count - limit
        for key in ranked where excess > 0 {
            operationCache[key] = nil
            excess -= 1
        }
        operationOrder.removeAll { operationCache[$0] == nil }
    }

    /// Drops all cached intermediates (call when memory is tight or media changed).
    /// Jobs still running finish for the renders awaiting them.
    public func purgeCaches() {
        sourceCache.removeAll()
        operationCache.removeAll()
        operationOrder.removeAll()
        displayedKeys.removeAll()
        overlayCache.removeAll()
        disparityCache.removeAll()
    }

    /// Memory warning: drops what is cheap to rebuild and the least recently used
    /// expensive results, other sizes (export, analysis) first. The results the
    /// picture on screen uses always stay, so its erases are not redone.
    public func trimForMemoryPressure(keepingRecent keep: Int = 4) {
        sourceCache.removeAll()
        overlayCache.removeAll()
        disparityCache.removeAll()
        let displayedSizes = Set(displayedKeys.compactMap(Self.sizeSuffix(ofKey:)))
        evict(downTo: keep) { key in Self.sizeSuffix(ofKey: key).map { !displayedSizes.contains($0) } ?? true }
        RenderContext.shared.clearCaches()
    }

    /// "WxH" of a cache key ("<uuid>@WxH").
    private static func sizeSuffix(ofKey key: String) -> Substring? {
        key.lastIndex(of: "@").map { key[key.index(after: $0)...] }
    }

    /// Whether an expensive step is being computed right now.
    public var hasHeavyWorkInFlight: Bool { !inFlight.isEmpty }

    public func purgeOperationCache(for operationIDs: Set<UUID>) {
        operationCache = operationCache.filter { key, _ in !operationIDs.contains { key.hasPrefix($0.uuidString) } }
        operationOrder = operationOrder.filter { operationCache[$0] != nil }
        displayedKeys = displayedKeys.filter { operationCache[$0] != nil }
    }

    // MARK: - Rendering

    public func render(_ document: PhotoDocument, options: Options = .preview) async throws -> CIImage {
        let timer = PSTimer("render")
        defer { timer.log(category: .imaging) }
        // A settled on-screen render records the results it uses; the newest one to finish wins.
        let log = options.isDisplayed && options.allowExpensiveWork && !options.showOriginal ? KeyLog() : nil
        if log != nil { displayGeneration += 1 }
        let generation = displayGeneration

        guard let base = document.baseLayer, let baseAsset = base.imageAsset else {
            throw PicshopError.renderFailed("document has no photo")
        }
        // Preview scale relative to the full-resolution original.
        let fullLongest = max(baseAsset.pixelSize.width, baseAsset.pixelSize.height)
        let scale = options.targetLongestSide.map { min(1, $0 / max(1, fullLongest)) } ?? 1

        let baseImage = try await renderImageLayer(base, asset: baseAsset, scale: scale, options: options, log: log)
        let canvasRect = CGRect(origin: .zero, size: baseImage.extent.size)
        var canvas = CIImage(color: document.backgroundColor.ciColor).cropped(to: canvasRect)
        canvas = composite(baseImage.transformed(by: CGAffineTransform(translationX: -baseImage.extent.minX, y: -baseImage.extent.minY)), over: canvas, layer: base, canvasRect: canvasRect, isBase: true)

        if options.showOriginal { return canvas }

        for layer in document.layers where layer.id != base.id && layer.isVisible {
            guard options.includeOverlays else { break }
            let rendered: CIImage?
            switch layer.content {
            case .image(let asset):
                rendered = try await renderImageLayer(layer, asset: asset, scale: scale, options: options, log: log)
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
        if let log, generation == displayGeneration { displayedKeys = log.keys }
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

    private var disparityCache: [String: CIImage?] = [:]

    /// The capture's disparity map (Portrait photos), oriented like the image and scaled to `extent`.
    private func disparityMap(for asset: MediaAsset, fitting extent: CGRect) -> CIImage? {
        let entry: CIImage?
        if let cached = disparityCache[asset.relativePath] {
            entry = cached
        } else {
            let url = store.url(for: asset.relativePath, in: projectID)
            entry = CIImage(contentsOf: url, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
            disparityCache[asset.relativePath] = entry
        }
        guard let disparity = entry, disparity.extent.width > 1 else { return nil }
        let scaled = disparity.transformed(by: CGAffineTransform(scaleX: extent.width / disparity.extent.width, y: extent.height / disparity.extent.height))
        return scaled.transformed(by: CGAffineTransform(translationX: extent.minX - scaled.extent.minX, y: extent.minY - scaled.extent.minY))
    }

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

    private func renderImageLayer(_ layer: Layer, asset: MediaAsset, scale: Double, options: Options, log: KeyLog? = nil) async throws -> CIImage {
        var image = try source(for: asset, scale: scale)
        // Actual ratio between this render and the original (thumbnail loader rounds).
        let effectiveScale = image.extent.width / max(1, asset.pixelSize.width)
        if options.showOriginal { return image }

        // Focus from the camera's depth map happens on the capture itself, before any other edit.
        if let lens = layer.edits.resolvedLensBlur, !layer.edits.hasGeometry, let disparity = disparityMap(for: asset, fitting: image.extent) {
            image = LensBlur.apply(to: image, disparity: disparity, focus: lens.focus, aperture: lens.aperture)
        }
        for operation in layer.edits.operations {
            image = try await apply(operation, to: image, layer: layer, scale: effectiveScale, options: options, log: log)
        }
        let look = layer.edits.resolvedLook
        let adjustments = AdjustmentPipeline.effectiveAdjustments(manual: layer.edits.resolvedAdjustments, look: look)
        let curve = layer.edits.resolvedToneCurve
        if !adjustments.isNeutral || !curve.isIdentity {
            image = AdjustmentPipeline.apply(adjustments, toneCurve: curve, to: image, scale: effectiveScale)
        }
        // Colour work after tone, as in a grading suite: match, then mixer and wheels in one LUT.
        if let match = layer.edits.resolvedColorMatch {
            image = ColorCube.shared.apply(match, to: image)
        }
        let mixer = layer.edits.resolvedColorMixer
        let grade = layer.edits.resolvedColorGrade
        if mixer != nil || grade != nil {
            image = ColorCube.shared.apply(mixer: mixer, grade: grade, to: image)
        }
        // An imported look sits on top, as the last node of a grade.
        if let lut = layer.edits.resolvedLUT {
            image = ColorCube.shared.apply(lutAt: store.url(for: lut.relativePath, in: projectID), intensity: lut.intensity, to: image)
        }
        return image
    }

    // MARK: - Expensive work

    /// The result for `key` when it is cached or being computed, else the same
    /// operation's result at another size, scaled. A larger result stands in for a
    /// smaller one at no loss; a smaller one only while interacting (no expensive work).
    private func reusedResult(key: String, operationID: UUID, extent: CGRect, options: Options, log: KeyLog?) async throws -> CIImage? {
        if let cached = operationCache[key] {
            touch(key)
            log?.keys.insert(key)
            return cached
        }
        if options.allowExpensiveWork {
            // The same step is running, at this size or a larger one: wait for it rather than start another.
            let running = inFlight[key].map { (key: key, value: $0) }
                ?? inFlight.first { Self.isResult(of: operationID, key: $0.key, reusableFor: extent, allowUpscale: false) }
            if let running {
                do {
                    let image = try await join(running.value, key: running.key)
                    if running.key == key {
                        log?.keys.insert(key)
                        return image
                    }
                } catch let error as CancellationError {
                    // Abandoned by every other render: this one computes it below.
                    if Task.isCancelled { throw error }
                }
            }
        }
        return scaledResult(of: operationID, to: extent, allowUpscale: !options.allowExpensiveWork, log: log)
    }

    /// Input size encoded in a cache key ("<uuid>@WxH").
    private static func inputSize(inKey key: String) -> CGSize? {
        guard let at = key.lastIndex(of: "@") else { return nil }
        let parts = key[key.index(after: at)...].split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func isResult(of operationID: UUID, key: String, reusableFor extent: CGRect, allowUpscale: Bool) -> Bool {
        guard key.hasPrefix(operationID.uuidString + "@"), let size = inputSize(inKey: key) else { return false }
        guard extent.width > 0, extent.height > 0 else { return false }
        // Same framing only: a result for a different crop is not this one resized.
        guard abs(size.width / size.height - extent.width / extent.height) < 0.01 else { return false }
        return allowUpscale || size.width >= extent.width - 0.5
    }

    private func scaledResult(of operationID: UUID, to extent: CGRect, allowUpscale: Bool, log: KeyLog?) -> CIImage? {
        var best: (key: String, size: CGSize, image: CIImage)?
        for key in operationOrder where Self.isResult(of: operationID, key: key, reusableFor: extent, allowUpscale: allowUpscale) {
            guard let image = operationCache[key], let size = Self.inputSize(inKey: key) else { continue }
            let resultExtent = image.extent
            guard !resultExtent.isInfinite, resultExtent.width.isFinite, resultExtent.height.isFinite, resultExtent.width > 0, resultExtent.height > 0 else { continue }
            if best.map({ size.width > $0.size.width }) ?? true { best = (key, size, image) }
        }
        guard let best else { return nil }
        touch(best.key)
        log?.keys.insert(best.key)
        let sx = extent.width / best.size.width, sy = extent.height / best.size.height
        let source = best.image.extent
        // Most steps keep their input's frame; an expand grows it by the same ratio.
        let keepsFrame = abs(source.width - best.size.width) < 0.5 && abs(source.height - best.size.height) < 0.5
        let target = keepsFrame
            ? extent
            : CGRect(x: (source.minX * sx).rounded(), y: (source.minY * sy).rounded(), width: (source.width * sx).rounded(), height: (source.height * sy).rounded())
        guard target.width >= 1, target.height >= 1 else { return nil }
        let transform = CGAffineTransform(translationX: target.minX, y: target.minY)
            .scaledBy(x: target.width / source.width, y: target.height / source.height)
            .translatedBy(x: -source.minX, y: -source.minY)
        return best.image.transformed(by: transform).cropped(to: target)
    }

    /// Computes an expensive result once for every render that asks for it and caches it.
    /// A job that everyone stopped waiting for is cancelled and never cached.
    private func runExpensive(key: String, step: String, log: KeyLog?, work: @escaping @Sendable () async throws -> CIImage) async throws -> CIImage {
        log?.keys.insert(key)
        var attempts = 0
        while true {
            attempts += 1
            let job: Task<CIImage, Error>
            if let running = inFlight[key] {
                job = running
            } else {
                relieveMemoryIfNeeded(before: step)
                ImagingBreadcrumbs.note("\(step) started · \(MemoryBudget.availableDescription) free")
                job = Task<CIImage, Error> {
                    let image = try await work()
                    try Task.checkCancellation()
                    return image
                }
                inFlight[key] = job
            }
            do {
                return try await join(job, key: key)
            } catch let error as CancellationError {
                // Abandoned by the renders that were waiting just before this one joined: start again once.
                guard !Task.isCancelled, attempts < 2 else { throw error }
            }
        }
    }

    private func join(_ job: Task<CIImage, Error>, key: String) async throws -> CIImage {
        let token = UUID()
        inFlightWaiters[key, default: []].insert(token)
        let outcome = await withTaskCancellationHandler {
            await job.result
        } onCancel: {
            Task { await self.leave(key, token: token, cancelling: job) }
        }
        leave(key, token: token, cancelling: nil)
        switch outcome {
        case .success(let image):
            if inFlight[key] == job {
                inFlight[key] = nil
                cacheOperation(image, for: key)
                ImagingBreadcrumbs.note("step finished · \(MemoryBudget.availableDescription) free")
            }
            return image
        case .failure(let error):
            if inFlight[key] == job { inFlight[key] = nil }
            throw error
        }
    }

    private func leave(_ key: String, token: UUID, cancelling job: Task<CIImage, Error>?) {
        inFlightWaiters[key]?.remove(token)
        if inFlightWaiters[key]?.isEmpty == true { inFlightWaiters[key] = nil }
        guard let job, inFlightWaiters[key] == nil, inFlight[key] == job else { return }
        // The render that replaces a cancelled one usually asks for the same step right
        // away (a slider settled, a panel opened): give it a moment to join first.
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.cancelIfAbandoned(job, key: key)
        }
    }

    private func cancelIfAbandoned(_ job: Task<CIImage, Error>, key: String) {
        guard inFlightWaiters[key] == nil, inFlight[key] == job else { return }
        job.cancel()
        inFlight[key] = nil
        ImagingBreadcrumbs.note("step cancelled")
    }

    /// Before a heavy job: when the system is short of memory, free what can be rebuilt.
    private func relieveMemoryIfNeeded(before step: String) {
        guard MemoryBudget.isLow else { return }
        PSLog.info("low memory before \(step) (\(MemoryBudget.availableDescription)): trimming caches", category: .imaging)
        trimForMemoryPressure()
    }

    private func apply(_ operation: EditOperation, to input: CIImage, layer: Layer, scale: Double, options: Options, log: KeyLog?) async throws -> CIImage {
        let extent = input.extent
        // An unbounded or non-finite extent would trap in the Int conversions below.
        guard !extent.isInfinite, extent.width.isFinite, extent.height.isFinite else { return input }
        let cacheKey = "\(operation.id.uuidString)@\(Int(extent.width))x\(Int(extent.height))"
        switch operation.kind {
        case .adjust, .adjustments, .toneCurve, .look, .autoEnhance, .colorMixer, .colorGrade, .colorMatch, .lut:
            return input

        case .lensBlur(let focus, let aperture, let mask):
            // Done with the depth map at the source when there is one; the subject mask is the fallback.
            guard layer.edits.resolvedLensBlur?.focus == focus else { return input }
            if !layer.edits.hasGeometry, let asset = layer.imageAsset, disparityMap(for: asset, fitting: extent) != nil { return input }
            guard let mask, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            return LensBlur.apply(to: input, subjectMask: maskImage, focus: focus, aperture: aperture)

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

        case .expand(let placement):
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard placement.width > 0.05, placement.height > 0.05 else { return input }
            let canvas = CGRect(x: 0, y: 0, width: (extent.width / placement.width).rounded(), height: (extent.height / placement.height).rounded())
            let origin = CGPoint(x: (placement.minX * canvas.width).rounded(), y: ((1 - placement.maxY) * canvas.height).rounded())
            let placed = input.transformed(by: CGAffineTransform(translationX: origin.x - extent.minX, y: origin.y - extent.minY))
            // Edge pixels stretched outwards: a seed the filler continues, and the live preview meanwhile.
            let seed = placed.clampedToExtent().cropped(to: canvas)
            guard options.allowExpensiveWork else {
                return placed.composited(over: seed.clampedToExtent().applyingGaussianBlur(sigma: 0.02 * max(canvas.width, canvas.height)).cropped(to: canvas))
            }
            let hole = CIImage(color: .white).cropped(to: canvas)
            let keep = CIImage(color: .black).cropped(to: placed.extent.insetBy(dx: 2, dy: 2))
            let mask = keep.composited(over: hole)
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "expand", log: log) {
                if inpainting.hasGenerativeEngine {
                    return try await inpainting.generate(image: seed, mask: mask, boundingBox: .unit, prompt: "seamless continuation of the scene, same light, same style")
                }
                return try await inpainting.fill(image: seed, mask: mask, boundingBox: .unit, feather: 0.01)
            }

        case .blurRegion(let mask, let amount):
            guard let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let sigma = max(4, 0.025 * max(extent.width, extent.height) * amount)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
            let soft = maskImage.clampedToExtent().applyingGaussianBlur(sigma: max(1, 2 * scale)).cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: blurred, background: input, mask: soft)

        case .moveObject(let mask, let offset):
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            // The object lifted with a soft edge, carried to its new place.
            let edge = maskImage.clampedToExtent().applyingGaussianBlur(sigma: max(0.8, 1.4 * scale)).cropped(to: extent)
            let lifted = AdjustmentPipeline.applyingAlpha(mask: edge, to: input)
            let moved = lifted.transformed(by: CGAffineTransform(translationX: offset.x * extent.width, y: -offset.y * extent.height)).cropped(to: extent)
            // While a slider moves, the object is shown at its new place over the untouched picture.
            guard options.allowExpensiveWork else { return moved.composited(over: input) }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "move", log: log) {
                let filled = try await inpainting.fill(image: input, mask: maskImage, boundingBox: mask.boundingBox, feather: mask.feather)
                return moved.composited(over: filled)
            }

        case .removeObject(let mask):
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "erase", log: log) {
                try await inpainting.fill(image: input, mask: maskImage, boundingBox: mask.boundingBox, feather: mask.feather)
            }

        case .heal(let strokes):
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork else { return input }
            let width = Int(extent.width), height = Int(extent.height)
            var bytes = [UInt8](repeating: 0, count: width * height)
            MaskStore.rasterize(strokes: strokes, width: width, height: height, into: &bytes)
            guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else { return input }
            let maskImage = CIImage(cgImage: cg)
            let box = MaskStore.boundingBox(of: bytes, width: width, height: height)
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "heal", log: log) {
                try await inpainting.fill(image: input, mask: maskImage, boundingBox: box, feather: 0.01)
            }

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
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork else { return input }
            let upscaler = self.upscaler
            return try await runExpensive(key: cacheKey, step: "upscale", log: log) {
                try await upscaler.upscale(input, factor: factor)
            }

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

        case .generativeFill(let mask, let prompt):
            let reused = try await reusedResult(key: cacheKey, operationID: operation.id, extent: extent, options: options, log: log)
            if let reused { return reused }
            guard options.allowExpensiveWork, let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            let inpainting = self.inpainting
            return try await runExpensive(key: cacheKey, step: "generate", log: log) {
                try await inpainting.generate(image: input, mask: maskImage, boundingBox: mask.boundingBox, prompt: prompt)
            }

        case .recolor(let mask, let color, let strength):
            guard let maskImage = maskStore.load(mask, fitting: extent) else { return input }
            return BackgroundEffects.recolor(input, mask: maskImage, color: color, strength: strength)

        case .cloneStamp(let strokes, let offset):
            let width = Int(extent.width), height = Int(extent.height)
            var bytes = [UInt8](repeating: 0, count: width * height)
            MaskStore.rasterize(strokes: strokes, width: width, height: height, into: &bytes)
            guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else { return input }
            let maskImage = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: 1.5 * scale).cropped(to: extent)
            // Source pixels come from the image shifted by the (normalised) offset; y flips because CI is bottom-up.
            let shifted = input.transformed(by: CGAffineTransform(translationX: -CGFloat(offset.x) * extent.width, y: CGFloat(offset.y) * extent.height)).clampedToExtent().cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: shifted, background: input, mask: maskImage)

        case .pixelPaint(let strokes, let color):
            let width = Int(extent.width), height = Int(extent.height)
            var bytes = [UInt8](repeating: 0, count: width * height)
            MaskStore.rasterize(strokes: strokes, width: width, height: height, into: &bytes)
            guard let cg = ImageSupport.grayImage(width: width, height: height, bytes: bytes) else { return input }
            let maskImage = CIImage(cgImage: cg)
            let paint = CIImage(color: color.ciColor).cropped(to: extent)
            return AdjustmentPipeline.blendWithMask(foreground: paint, background: input, mask: maskImage)
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
